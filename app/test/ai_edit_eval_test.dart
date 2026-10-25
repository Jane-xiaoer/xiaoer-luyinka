// 手动评估（平时跳过）：用真模型试「问问小耳」能不能照我的话改记录。在沙盒里复制一段真录音，不碰真资料。
// AI_EDIT_EVAL="<state.json 路径>|<一条录音的 .xiaoer json 路径>" flutter test test/ai_edit_eval_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/actions.dart';
import 'package:luyinka/analyze.dart';
import 'package:luyinka/ask.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/llm.dart';
import 'package:luyinka/search.dart';
import 'package:luyinka/store.dart';

void main() {
  final env = Platform.environment['AI_EDIT_EVAL'];
  test('真模型：改类别 / 改标题人物 / 只是提问不乱改', () async {
    final [statePath, recPath] = env!.split('|');
    final settings = Map<String, dynamic>.from(jsonDecode(File(statePath).readAsStringSync())['settings']);
    final tmp = await Directory.systemTemp.createTemp('aieval');
    final lib = Library(Directory('${tmp.path}/资料'));
    await lib.ensure();
    final store = Store(Directory('${tmp.path}/app'))..lib = lib;
    final stem = recPath.split('/').last.replaceAll('.json', '');
    await store.putResult(stem, Map<String, dynamic>.from(jsonDecode(File(recPath).readAsStringSync())));
    final cloud = Cloud((settings['cloud'] as String?) ?? 'https://luyinka.xiaoeromia.com:8443', token: settings['token'] as String?);
    final llm = Llm(cloud, () => Map<String, dynamic>.from(settings['llm'] ?? {}));
    final note = Analyzer.of(lib, llm).note;
    final focus = store.scenes.firstWhere((s) => s.category == '个人感悟');

    Future<(String, List<EditOp>)> ask(String q) async {
      final a = await llm.chatMessages(
          buildAskMessages(scenes: store.scenes, focus: store.sceneById(focus.id), all: store.scenes, question: q),
          temperature: 0.5);
      final r = parseEdits(parseFound(a).$1);
      stderr.writeln('\n【问】$q\n【答】${r.$1}\n【操作】${r.$2.map((o) => jsonEncode(o.j)).join('  ')}');
      return r;
    }

    final (_, q0) = await ask('这段讲了什么？');
    expect(q0, isEmpty, reason: '只是提问，不该改');

    final (_, q1) = await ask('这段其实是我去听的一个讲座，不是个人感悟，帮我改一下');
    expect(q1.map((o) => (o.op, o.id, o.j['to'])), [('category', focus.id, '听课讲座')]);
    final r1 = await applyEdits(store, q1, note);
    stderr.writeln('【结果】$r1');
    expect(store.sceneById(focus.id)!.category, '听课讲座');
    expect(File('${lib.path}/${Library.noteRel(store.sceneById(focus.id)!)}').existsSync(), isTrue);

    final (_, q2) = await ask('标题改成「AI 做硬件讲座」，人物加上主讲人老王');
    expect(q2.single.op, 'edit');
    final r2 = await applyEdits(store, q2, note);
    stderr.writeln('【结果】$r2');
    expect(store.sceneById(focus.id)!.title, contains('讲座'));
    expect(store.sceneById(focus.id)!.people, contains('老王'));
    stderr.writeln('\n【改完的笔记】\n${File('${lib.path}/${Library.noteRel(store.sceneById(focus.id)!)}').readAsStringSync().substring(0, 600)}');
  }, skip: env == null, timeout: const Timeout(Duration(minutes: 5)));
}
