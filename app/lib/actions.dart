// 小耳动手改记录：改类别、改标题 / 事件 / 地点 / 人物、标成杂音、跟上一段合并、待办打勾。
// 两个入口走同一套：
//   1. 「问问小耳」的回答末尾带 [[改: {...}]]（一行一条），App 照着改；
//   2. 外面的程序（别的 AI、脚本、Obsidian 插件…）往 <资料>/.xiaoer/commands/ 放 .json，App 收进来照着改，
//      结果写到 .xiaoer/commands/done/ 同名文件里（见 [runCommandInbox]）。
// 一条操作：{"op": "category" | "edit" | "noise" | "merge" | "todo", "id": "段的 id", ...}
//   category：to（类别名，见 cats）、subject（改成现场调研时的调研对象，可省）
//   edit：title / event / place / people（数组）里要改的几项
//   noise：标成杂音（不再显示）；merge：跟同一条录音里的上一段合成一段
//   todo：index（第几条待办，从 0 数）、kind（actions 待办 / reminders 提醒，默认 actions）、done（true / false）
//   model（只认外面放进来的命令，对话里不行）：换整理 / 问答用的大模型 {"op":"model","base":"https://…/v1","model":"…","key":"…"}，
//     OpenAI 兼容接口；key 用完就从命令文件里抹掉
import 'dart:convert';
import 'dart:io';

import 'store.dart';
import 'templates.dart';
import 'todos.dart';

class EditOp {
  final Map<String, dynamic> j;
  EditOp(this.j);
  String get op => (j['op'] ?? '').toString();
  String get id => (j['id'] ?? '').toString();
}

/// 从回答里取出 [[改: {...}]]，返回（去掉这些行的回答, 操作）。写坏了的 JSON 也算一条（op 为空，执行时报看不懂）。
(String, List<EditOp>) parseEdits(String answer) {
  final ops = <EditOp>[];
  final re = RegExp(r'^\s*\[\[改[:：]\s*(\{.*\})\s*\]\]\s*$', multiLine: true);
  for (final m in re.allMatches(answer)) {
    try {
      final j = jsonDecode(m[1]!);
      ops.add(EditOp(j is Map ? Map<String, dynamic>.from(j) : {'raw': m[1]}));
    } catch (_) {
      ops.add(EditOp({'raw': m[1]})); // 写坏了：留着，执行时报「看不懂」，别悄悄吞掉
    }
  }
  return (answer.replaceAll(re, '').trim(), ops);
}

/// 照 [op] 改一段。返回一句说明（给人看）；做不了抛 [StateError]，说明原因。
/// [note]：按类别模板重新写笔记（Analyzer.note），改类别 / 合并时用。
Future<String> applyEdit(Store store, EditOp op, Future<String> Function(Scene) note, {bool fromOutside = false}) async {
  if (op.op.isEmpty) throw StateError('这条看不懂：${op.j['raw'] ?? jsonEncode(op.j)}');
  if (op.op == 'model') {
    if (!fromOutside) throw StateError('换模型要在设置里换，或让你的 AI 按「给AI的接口.md」放命令文件');
    final base = (op.j['base'] ?? '').toString().trim(), model = (op.j['model'] ?? '').toString().trim();
    final key = (op.j['key'] ?? '').toString().trim();
    if (!base.startsWith('http') || model.isEmpty || key.isEmpty) throw StateError('要给全 base（https://…/v1）、model、key');
    store.settings['llm'] = {
      'own': true,
      'provider': (op.j['provider'] ?? '自定义').toString(),
      'base': base,
      'model': model,
      'key': key,
    };
    await store.save();
    return '整理和问答改用你的模型：$model（$base）';
  }
  final s = store.sceneById(op.id);
  if (s == null) throw StateError('找不到 id 是 ${op.id} 的那一段');
  final name = '《${s.title}》';
  switch (op.op) {
    case 'category':
      final to = catKey((op.j['to'] ?? '').toString());
      if (to != noiseCat && !cats.any((c) => c.key == to)) {
        throw StateError('没有「$to」这个类别，能用的：${cats.map((c) => c.key).join('、')}');
      }
      if (to == s.category) return '$name 本来就是「${catFolder(to)}」';
      final from = s.category;
      await store.changeCategory(s, to, note, subject: (op.j['subject'] ?? '').toString());
      return to == noiseCat ? '$name 标成了杂音' : '$name 从「${catFolder(from)}」改成「${catFolder(to)}」，已按新模板重新整理';
    case 'noise':
      await store.changeCategory(s, noiseCat, note);
      return '$name 标成了杂音，列表里不再显示';
    case 'edit':
      final changed = <String>[];
      for (final k in const ['title', 'event', 'place']) {
        final v = op.j[k];
        if (v is String && v.trim().isNotEmpty && v.trim() != s.d[k]) {
          s.d[k] = v.trim();
          changed.add(const {'title': '标题', 'event': '事件', 'place': '地点'}[k]!);
        }
      }
      final people = op.j['people'];
      if (people is List) {
        s.d['people'] = [for (final p in people) p.toString().trim()]..removeWhere((p) => p.isEmpty);
        changed.add('人物');
      }
      if (changed.isEmpty) return '$name 没有要改的';
      await store.putScene(s);
      return '$name 改了${changed.join('、')}${s.title != name.substring(1, name.length - 1) ? '，现在叫《${s.title}》' : ''}';
    case 'merge':
      final m = await store.mergeWithPrevious(s, note);
      return '$name 跟上一段合成了一段《${m.title}》';
    case 'todo':
      final kind = op.j['kind'] == 'reminders' ? 'reminders' : 'actions';
      final i = (op.j['index'] as num?)?.toInt() ?? -1;
      final l = s.d[kind];
      if (l is! List || i < 0 || i >= l.length) throw StateError('$name 没有第 ${i + 1} 条${kind == 'reminders' ? '提醒' : '待办'}');
      final done = op.j['done'] != false;
      await store.setTodoDone(Todo(s, kind, i, text: '${(l[i] as Map)['text']}'), done);
      return '$name 的「${(l[i] as Map)['text']}」${done ? '打了勾' : '取消了勾'}';
    default:
      throw StateError('不认识的操作「${op.op}」');
  }
}

/// 一组操作挨个做，返回每条的结果（成功的说明 / 失败的原因，前面带 ✅ / ⚠️）。
Future<List<String>> applyEdits(Store store, List<EditOp> ops, Future<String> Function(Scene) note) async {
  final out = <String>[];
  for (final op in ops) {
    try {
      out.add('✅ ${await applyEdit(store, op, note)}');
    } catch (e) {
      out.add('⚠️ 没改成：${e is StateError ? e.message : e}');
    }
  }
  return out;
}

/// 外面放进来的命令：<资料>/.xiaoer/commands/*.json，内容是一条操作或操作数组（格式见文件开头）。
/// 做完把原文件挪到 commands/done/，旁边写同名 .result.json：[{"op":…, "ok": true/false, "message": "…"}]。
Future<int> runCommandInbox(Store store, Future<String> Function(Scene) note) async {
  final dir = Directory('${store.lib.path}/.xiaoer/commands');
  if (!await dir.exists()) return 0;
  final done = Directory('${dir.path}/done');
  var n = 0;
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    final results = <Map<String, dynamic>>[];
    try {
      final j = jsonDecode(await f.readAsString());
      final list = j is List ? j : [j];
      for (final x in list) {
        final op = EditOp(Map<String, dynamic>.from(x as Map));
        final shown = {...op.j, if (op.j.containsKey('key')) 'key': '（已抹掉）'};
        try {
          results.add({...shown, 'ok': true, 'message': await applyEdit(store, op, note, fromOutside: true)});
        } catch (e) {
          results.add({...shown, 'ok': false, 'message': e is StateError ? e.message : '$e'});
        }
      }
    } catch (e) {
      results.add({'ok': false, 'message': '读不懂这个文件：$e'});
    }
    await done.create(recursive: true);
    await File('${done.path}/${name.replaceAll(RegExp(r'\.json$'), '')}.result.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(results));
    // 原命令挪进 done/；里面要是带了 key（换模型），抹掉再存，别把 key 留在会同步的文稿里
    try {
      final j = jsonDecode(await f.readAsString());
      Object mask(Object? x) => x is Map ? {...x, if (x.containsKey('key')) 'key': '（已抹掉）'} : x as Object;
      await File('${done.path}/$name').writeAsString(
          const JsonEncoder.withIndent('  ').convert(j is List ? [for (final x in j) mask(x)] : mask(j)));
      await f.delete();
    } catch (_) {
      await f.rename('${done.path}/$name');
    }
    n++;
  }
  return n;
}
