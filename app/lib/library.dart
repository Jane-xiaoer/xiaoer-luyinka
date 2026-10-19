// 资料文件夹：整理好的东西都是普通文件，放在用户自己的设备上，不开 App 也能看、也能交给任何 AI / agent。
//   每日/2026-10-18.md                    这天的时间线（每段：钟点 · 类别 · 标题 · 事件）
//   会议纪要/2026-10-18 14.00 标题.md       按类别分文件夹，一段一个笔记（时间地点人物事件 + 按模板整理 + 逐字稿）
//   现场调研/按对象/某某公司.md              同一个调研对象的历次记录都追加在这（下次调研同一对象时当背景）
//   个人感悟/观点库.md                       历次感悟里的观点和演讲素材汇在一起（准备演讲时翻这一份）
//   逐字稿/<录音>.md                       整条录音的全文
//   录音/<录音>.m4a                        播放用
//   模板/<类别>.md                         各类别的整理方式，可以直接改
//   模板/一键按钮.md、模板/我的写作风格.md     「拿去用」按钮的要求、让小耳写东西时照着的口吻
//   成稿/2026-10-19 14.05 标题.md           对话里小耳写好、点了「存成稿」的东西
//   .xiaoer/<录音>.json                    App 用的索引（删了 App 里就看不到那条，但上面的文件还在）
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'store.dart';
import 'templates.dart';

class Library {
  Directory root;
  Library(this.root);

  static Future<Directory> defaultDir() async {
    if (Platform.isMacOS) return Directory('${Platform.environment['HOME']}/Documents/小耳录音卡');
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory(); // Android/data/<包名>/files：不用申请权限，连电脑能看到
      if (ext != null) return Directory('${ext.path}/小耳录音卡');
    }
    return Directory('${(await getApplicationDocumentsDirectory()).path}/小耳录音卡');
  }

  String get path => root.path;
  File data(String stem) => File('$path/.xiaoer/$stem.json');
  File audio(String stem) => File('$path/录音/$stem.m4a');
  File transcript(String stem) => File('$path/逐字稿/$stem.md');
  File templateFile(String cat) => File('$path/模板/$cat.md');
  Directory get subjectsDir => Directory('$path/现场调研/按对象');
  File subjectFile(String s) => File('${subjectsDir.path}/${safe(s)}.md');
  File get ideasFile => File('$path/个人感悟/观点库.md');
  File get quickActionsFile => File('$path/模板/一键按钮.md');
  File get styleFile => File('$path/模板/我的写作风格.md');

  Future<void> ensure() async {
    for (final d in ['.xiaoer', '录音', '逐字稿', '每日', '模板', '成稿']) {
      await Directory('$path/$d').create(recursive: true);
    }
    for (final e in defaultTemplates.entries) {
      final f = templateFile(e.key);
      if (!await f.exists()) await f.writeAsString('${e.value}\n');
    }
    if (!await quickActionsFile.exists()) await quickActionsFile.writeAsString(quickActionsMd(quickActions));
    if (!await styleFile.exists()) await styleFile.writeAsString(defaultStyle);
    final readme = File('$path/说明.md');
    if (!await readme.exists()) {
      await readme.writeAsString('''# 小耳录音卡 · 资料文件夹

这里是你录音卡整理出来的全部内容，都是普通文件，只存在这台设备上（录音卡同步完可以删，云端转写完就删）。
不开 App 也能看；也可以把整个文件夹交给任何 AI / agent。

- 每日/：每天的时间线
- 会议纪要/、我的分享/、商务洽谈/、现场调研/、听课讲座/、多人群聊/ …：按类别分好的笔记
- 现场调研/按对象/：同一个调研对象的历次记录
- 个人感悟/观点库.md：平时说出来的感悟、判断、演讲素材汇在一起，准备演讲时翻这一份
- 逐字稿/、录音/：全文和原声
- 模板/：每一类怎么整理。直接改这些 .md，下次整理就按你改过的来
- 模板/一键按钮.md：每一类下面「拿去用」按钮让小耳写什么；模板/我的写作风格.md：让小耳写文章、朋友圈时照着的口吻
- 成稿/：在对话里让小耳写好的文章、朋友圈、纪要消息，点「存成稿」存在这
''');
    }
  }

  Future<String> template(String cat) async {
    final f = templateFile(cat);
    if (await f.exists()) return (await f.readAsString()).trim();
    return defaultTemplates[cat] ?? defaultTemplates['自言自语']!;
  }

  (int, Map<String, List<(String, String)>>)? _qa;

  /// 一键按钮表：模板/一键按钮.md 认得出就用它，否则用默认表。按文件修改时间缓存，外面改了下次就生效。
  Map<String, List<(String, String)>> quickActionsTable() {
    final f = quickActionsFile;
    try {
      if (!f.existsSync()) return quickActions;
      final t = f.lastModifiedSync().millisecondsSinceEpoch;
      if (_qa?.$1 != t) _qa = (t, parseQuickActions(f.readAsStringSync()) ?? quickActions);
      return _qa!.$2;
    } catch (_) {
      return quickActions;
    }
  }

  /// 我的写作风格（去掉说明后的内容；没写就是空）。
  String writingStyle() {
    try {
      return styleFile.existsSync() ? cleanStyle(styleFile.readAsStringSync()) : '';
    } catch (_) {
      return '';
    }
  }

  Future<List<String>> subjects() async {
    if (!await subjectsDir.exists()) return [];
    return [
      for (final f in subjectsDir.listSync().whereType<File>())
        if (f.path.endsWith('.md')) f.uri.pathSegments.last.replaceAll(RegExp(r'\.md$'), ''),
    ]..sort();
  }

  /// 以前对这个对象的调研（取最近的一截，当背景喂给模型）。
  Future<String> subjectHistory(String subject, {String? except, int max = 8000}) async {
    final f = subjectFile(subject);
    if (subject.isEmpty || !await f.exists()) return '';
    var t = await f.readAsString();
    if (except != null) t = t.replaceAll(RegExp('<!-- $except -->[\\s\\S]*?<!-- /$except -->'), '');
    if (!t.contains('<!-- ')) return ''; // 只剩文件开头，没有别的调研
    return t.length > max ? t.substring(t.length - max) : t;
  }

  Future<void> writeTranscript(String stem, String start, List<List<String>> lines) async {
    await transcript(stem).writeAsString([
      '# $stem 逐字稿',
      '',
      if (start.isNotEmpty) '开录：${start.substring(0, 16).replaceAll('T', ' ')}',
      '',
      for (final l in lines) '**[${l[0]}]** ${l[1]}  ',
    ].join('\n'));
  }

  /// 一段的笔记文件（换了标题 / 类别就把旧文件删掉）。返回新文件路径。
  Future<String> writeNote(Scene s) async {
    final old = s.d['file'] as String?;
    final f = File('$path/${catFolder(s.category)}/${_day(s.start)} ${_hm(s.start, '.')} ${safe(s.title)}.md');
    if (old != null && old != f.path) {
      final o = File(old);
      if (await o.exists()) await o.delete();
    }
    await f.parent.create(recursive: true);
    await f.writeAsString(noteMd(s));
    s.d['file'] = f.path;
    if (catKey(s.category) == '现场调研' && s.subject.isNotEmpty) await _appendSubject(s);
    if (catKey(s.category) == '个人感悟' && s.body.isNotEmpty) await _appendIdeas(s);
    return f.path;
  }

  Future<void> _appendSubject(Scene s) async {
    final f = subjectFile(s.subject);
    await f.parent.create(recursive: true);
    var t = await f.exists() ? await f.readAsString() : '# 调研对象：${s.subject}\n\n同一个对象的历次调研，新的在后面。\n';
    final block = '<!-- ${s.id} -->\n## ${_day(s.start)} ${_hm(s.start)} ${s.title}\n\n${s.event}\n\n${s.body}\n<!-- /${s.id} -->';
    final re = RegExp('<!-- ${s.id} -->[\\s\\S]*?<!-- /${s.id} -->');
    t = re.hasMatch(t) ? t.replaceFirst(re, block) : '${t.trimRight()}\n\n$block\n';
    await f.writeAsString(t);
  }

  /// 观点库：每次感悟只收「感悟了什么」「对未来的判断」「演讲素材」三节（没有就收全文），按 id 覆盖。
  Future<void> _appendIdeas(Scene s) async {
    final f = ideasFile;
    await f.parent.create(recursive: true);
    var t = await f.exists() ? await f.readAsString() : '# 观点库\n\n平时说出来的感悟、对未来的判断、能拿去演讲的素材，新的在后面。\n';
    final keep = [
      for (final sec in s.body.split(RegExp(r'^## ', multiLine: true)))
        if (const ['感悟了什么', '对未来的判断', '演讲素材'].contains(sec.split('\n').first.trim())) '### ${sec.trim()}',
    ];
    final body = keep.isEmpty ? s.body.replaceAll(RegExp(r'^## ', multiLine: true), '### ') : keep.join('\n\n');
    final place = s.place.isEmpty ? '' : ' · ${s.place}';
    final block = '<!-- ${s.id} -->\n## ${_day(s.start)} ${_hm(s.start)}$place · ${s.title}\n\n$body\n<!-- /${s.id} -->';
    final re = RegExp('<!-- ${s.id} -->[\\s\\S]*?<!-- /${s.id} -->');
    t = re.hasMatch(t) ? t.replaceFirst(re, block) : '${t.trimRight()}\n\n$block\n';
    await f.writeAsString(t);
  }

  Future<void> writeDay(String day, List<Scene> scenes) async {
    final b = StringBuffer('# $day\n\n');
    for (final s in scenes) {
      final f = s.d['file'] as String?;
      final link = f == null ? '' : '（[笔记](<../${f.substring(path.length + 1)}>)）';
      b.writeln('- **${_hm(s.start)}–${_hm(s.end)}** [${catKey(s.category)}] ${s.title}$link');
      if (s.event.isNotEmpty) b.writeln('  ${s.event}');
      for (final t in [...s.actions, ...s.reminders]) {
        b.writeln('  - [ ] ${t['text']}${(t['when'] ?? '').toString().isNotEmpty ? '（${t['when']}）' : ''}');
      }
    }
    await File('$path/每日/$day.md').writeAsString(b.toString());
  }

  static String safe(String s) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '').trim();
    return t.isEmpty ? '未命名' : (t.length > 40 ? t.substring(0, 40) : t);
  }
}

/// 录音里的位置：秒 → 1:02:03 / 2:03。
String clockOf(double sec) {
  final s = sec.round(), h = s ~/ 3600, m = s % 3600 ~/ 60, x = s % 60;
  return h > 0 ? '$h:${_pad(m)}:${_pad(x)}' : '$m:${_pad(x)}';
}

String _day(DateTime t) => '${t.year}-${_pad(t.month)}-${_pad(t.day)}';
String _hm(DateTime t, [String sep = ':']) => '${_pad(t.hour)}$sep${_pad(t.minute)}';
String _pad(int n) => n.toString().padLeft(2, '0');

/// 一段 → 独立的 Markdown 笔记。
String noteMd(Scene s) {
  final mins = s.end.difference(s.start).inMinutes;
  final b = StringBuffer('# ${s.title}\n\n');
  b.writeln('- **时间**：${_day(s.start)} ${_hm(s.start)}–${_hm(s.end)}（${mins < 1 ? '不到 1' : mins} 分钟）');
  if (s.place.isNotEmpty) b.writeln('- **地点**：${s.place}');
  if (s.people.isNotEmpty) b.writeln('- **人物**：${s.people.join('、')}');
  b.writeln('- **类别**：${catKey(s.category)}');
  if (s.subject.isNotEmpty) b.writeln('- **调研对象**：${s.subject}');
  b.writeln('- **事件**：${s.event}');
  b.writeln('- **录音**：录音/${s.stem}.m4a，从 ${clockOf(s.offset)} 开始');
  b.writeln();
  final body = s.body.isNotEmpty ? s.body : legacyBody(s);
  if (body.isNotEmpty) b.writeln('$body\n');
  if (s.text.isNotEmpty) {
    b.writeln('## 逐字稿\n');
    for (final l in s.text) {
      b.writeln('**[${l[0]}]** ${l[1]}  ');
    }
  }
  return b.toString();
}

/// 旧版本（还没按类别整理）的场景：用原来的几项拼一份。
String legacyBody(Scene s) {
  final b = StringBuffer();
  void list(String head, Iterable<String> xs) {
    if (xs.isEmpty) return;
    b.writeln('## $head\n');
    for (final x in xs) {
      b.writeln('- $x');
    }
    b.writeln();
  }

  if (s.minutesMd.isNotEmpty) b.writeln('${s.minutesMd.replaceAllMapped(RegExp(r'^(#+) ', multiLine: true), (m) => '#${m[1]} ')}\n');
  list('核心观点', s.views);
  list('有价值的内容', s.valuable);
  list('值得记住的', s.memorable.map((m) => '「${m['text']}」'));
  list('下一步行动', s.actions.map((a) => '${a['text']}${(a['who'] ?? '') != '' ? '（${a['who']}）' : ''}'));
  list('提醒事项', s.reminders.map((r) => '${r['text']}${(r['when'] ?? '') != '' ? '（${r['when']}）' : ''}'));
  return b.toString().trim();
}

/// 旧版 App 的数据（应用支持目录里的 result/、audio/）搬进资料文件夹。
Future<void> migrateOld(Directory old, Library lib) async {
  for (final (from, to) in [('result', '.xiaoer'), ('audio', '录音')]) {
    final d = Directory('${old.path}/$from');
    if (!await d.exists()) continue;
    for (final f in d.listSync().whereType<File>()) {
      final dest = File('${lib.path}/$to/${f.uri.pathSegments.last}');
      if (!await dest.exists()) await f.copy(dest.path);
      await f.delete();
    }
  }
}

String prettyJson(Object o) => const JsonEncoder.withIndent(' ').convert(o);
