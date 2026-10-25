// 小耳动手改记录：问问小耳的回答里带 [[改: …]] 照着改；外面放进 .xiaoer/commands/ 的命令也照着改。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/actions.dart';
import 'package:luyinka/analyze.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';

void main() {
  late Directory tmp;
  late Library lib;
  late Store store;
  final lines = [
    ['14:00:00', '今天这堂课讲品牌的三个层次'],
    ['14:02:00', '第一层是名字'],
  ];
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('actions');
    lib = Library(Directory('${tmp.path}/资料'));
    await lib.ensure();
    store = Store(Directory('${tmp.path}/app'))..lib = lib;
    await store.putResult('r1', {
      'start': '2026-10-18T14:00:00',
      'lines': lines,
      'scenes': [
        {'id': 's1', 'start': '2026-10-18T14:00:00', 'end': '2026-10-18T14:01:50', 'category': '个人感悟', 'title': '品牌想法',
         'event': '说品牌', 'people': [], 'text': lines.sublist(0, 1), 'body': '## 感悟了什么\n旧的',
         'actions': [{'text': '整理课件'}]},
        {'id': 's2', 'start': '2026-10-18T14:02:00', 'end': '2026-10-18T14:03:50', 'category': '个人感悟', 'title': '名字',
         'event': '讲名字', 'people': [], 'text': lines.sublist(1), 'body': '## 感悟了什么\n旧的'},
      ],
    });
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<String> note(s) => Analyzer(lib, (sys, u) async => '## 讲座要点\n- 新的').note(s);

  test('从回答里取出 [[改: …]]：正文去掉这些行，写坏的跳过', () {
    final (text, ops) = parseEdits('好的，这段是讲座，我改成「听课讲座」。\n'
        '[[改: {"op":"category","id":"s1","to":"听课讲座"}]]\n'
        '[[改： {"op":"edit","id":"s1","title":"品牌三层次讲座"}]]\n'
        '[[改: {坏的}]]');
    expect(text, '好的，这段是讲座，我改成「听课讲座」。');
    expect(ops.map((o) => o.op), ['category', 'edit', '']); // 写坏的那条也留着，执行时报「看不懂」
    expect(ops.first.j['to'], '听课讲座');
  });

  test('改类别：按新模板重新整理、笔记挪到新文件夹；改标题 / 人物；待办打勾', () async {
    final r = await applyEdits(store, [
      EditOp({'op': 'category', 'id': 's1', 'to': '听课讲座'}),
      EditOp({'op': 'edit', 'id': 's1', 'title': '品牌三层次讲座', 'people': ['王老师']}),
      EditOp({'op': 'todo', 'id': 's1', 'index': 0, 'done': true}),
    ], note);
    expect(r.every((x) => x.startsWith('✅')), isTrue, reason: '$r');
    final s = store.sceneById('s1')!;
    expect(s.category, '听课讲座');
    expect(s.title, '品牌三层次讲座');
    expect(s.people, ['王老师']);
    expect(s.actions.first['done'], true);
    final f = File('${lib.path}/听课讲座/2026-10-18 14.00 品牌三层次讲座.md');
    expect(f.existsSync(), isTrue);
    expect(s.body, isNot(contains('旧的'))); // 按新模板重新整理过
    expect(f.readAsStringSync(), startsWith('---\nid: "s1"\n类别: "听课讲座"'));
    expect(Directory('${lib.path}/个人感悟').listSync().whereType<File>().where((f) => f.path.contains('品牌')), isEmpty);
  });

  test('做不了的说清楚：找不到的段、没有的类别、写坏的', () async {
    final r = await applyEdits(store, [
      EditOp({'op': 'category', 'id': 'nope', 'to': '听课讲座'}),
      EditOp({'op': 'category', 'id': 's1', 'to': '瞎编的类别'}),
      ...parseEdits('[[改: {坏的}]]').$2,
    ], note);
    expect(r[0], contains('找不到'));
    expect(r[1], contains('没有「瞎编的类别」'));
    expect(r[2], contains('看不懂'));
    expect(store.sceneById('s1')!.category, '个人感悟');
  });

  test('跟上一段合并 / 标成杂音', () async {
    final r = await applyEdits(store, [EditOp({'op': 'merge', 'id': 's2'})], note);
    expect(r.single, startsWith('✅'));
    expect(store.scenesOf('r1').length, 1);
    final id = store.scenesOf('r1').single.id;
    await applyEdits(store, [EditOp({'op': 'noise', 'id': id})], note);
    expect(store.sceneById(id)!.noise, isTrue);
  });

  test('外面放进来的命令：照着改，原文件挪到 done/，旁边写结果', () async {
    final dir = Directory('${lib.path}/.xiaoer/commands')..createSync(recursive: true);
    File('${dir.path}/001.json').writeAsStringSync(jsonEncode([
      {'op': 'category', 'id': 's2', 'to': '听课讲座'},
      {'op': 'edit', 'id': 'nope', 'title': 'x'},
    ]));
    expect(await runCommandInbox(store, note), 1);
    expect(store.sceneById('s2')!.category, '听课讲座');
    expect(File('${dir.path}/001.json').existsSync(), isFalse);
    expect(File('${dir.path}/done/001.json').existsSync(), isTrue);
    final res = jsonDecode(File('${dir.path}/done/001.result.json').readAsStringSync()) as List;
    expect(res.map((x) => x['ok']), [true, false]);
  });
}
