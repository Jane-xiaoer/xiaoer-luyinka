import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/ask.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/llm.dart';
import 'package:luyinka/people.dart';
import 'package:luyinka/store.dart';

Scene sc(String id, String start, List<String> people,
        {List<Map<String, dynamic>> actions = const [], List<Map<String, dynamic>> reminders = const [], String body = ''}) =>
    Scene({
      'id': id, 'start': '$start:00', 'end': '${start.substring(0, 14)}59:00', 'category': '商务洽谈', 'title': '标题$id',
      'event': '事件$id', 'people': people, 'actions': actions, 'reminders': reminders, 'body': body,
      'text': [['10:00:00', '逐字稿原话$id']],
    }, 'stem');

void main() {
  test('人名轻度归一：去空格、全角转半角；王总和王总监不合并', () {
    expect(normPerson(' 王 总 '), '王总');
    expect(normPerson('Ｔｏｍ'), 'Tom');
    expect(personKey('ＴＯＭ'), personKey('tom'));
    expect(personKey('王总'), isNot(personKey('王总监')));
  });

  final all = [
    sc('c', '2026-10-20T10:00', ['王总', '小林'], actions: [
      {'text': '把合同模板发给王 总', 'who': '我'},
      {'text': '整理报价单', 'who': '小林'},
    ], reminders: [
      {'text': '下周一回复账期', 'when': '下周一'},
    ]),
    sc('b', '2026-10-19T10:00', ['王 总', '王总监'], reminders: [
      {'text': '给王总寄样品', 'when': '周五'},
    ]),
    sc('a', '2026-10-18T10:00', ['小林', '王总'], actions: [
      {'text': '催一下物流', 'who': '王总'},
    ]),
    sc('d', '2026-10-17T10:00', ['阿杰']),
  ];

  test('按人列表：出现次数多到少，带次数；同一段里重复只算一次', () {
    final p = peopleOf(all);
    expect([for (final x in p) '${x.name}${x.count}'], ['王总3', '小林2', '王总监1', '阿杰1']);
  });

  test('点一个人：跟他有关的段，新的在前', () {
    expect(scenesWith(all, '王总').map((s) => s.id), ['c', 'b', 'a']);
    expect(scenesWith(all.reversed.toList(), '王总').map((s) => s.id), ['c', 'b', 'a']);
    expect(scenesWith(all, '王总监').map((s) => s.id), ['b']);
  });

  test('往来小结的待办：who 或 text 提到他的才算', () {
    final t = todosWith(scenesWith(all, '王总'), '王总');
    expect(t.map((x) => x.text), ['把合同模板发给王 总', '给王总寄样品', '催一下物流']);
    expect(t[1].when, '周五');
    expect(t.map((x) => x.scene.id), ['c', 'b', 'a']);
  });

  test('见面前帮我准备：要求写全四项；资料只给笔记不给逐字稿', () {
    final p = prepPrompt('王总');
    for (final k in ['上次谈到哪', '王总在意什么', '我答应过什么', '这次可以聊什么', 'Markdown']) {
      expect(p, contains(k));
    }
    final mine = scenesWith(all, '王总');
    final sys = buildAskMessages(scenes: mine, all: all, question: p, lookup: '', withText: false).first['content']!;
    expect(sys, contains('标题c'));
    expect(sys, isNot(contains('逐字稿原话')));
    expect(sys, isNot(contains('## 可能相关的原文片段')));
    final typed = buildAskMessages(scenes: mine, all: all, question: '逐字稿原话a', lookup: '逐字稿原话a').first['content']!;
    expect(typed, contains('逐字稿原话')); // 平时照旧带
  });

  testWidgets('中栏按人：往来小结卡 + 段列表；「见面前帮我准备」只把笔记发给小耳', (tester) async {
    final llm = FakeLlm();
    final store = Store(Directory.systemTemp);
    final key = GlobalKey<AskBoxState>();
    final mine = scenesWith(all, '王总');
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PersonColumn(store: store, person: '王总', scenes: mine, selected: null, askKey: key, onPick: (_) {},
            onPrep: (n) => key.currentState!.quick(null, '见面前帮我准备：$n', prepPrompt(n), notesOnly: true)),
      ),
    ));
    expect(find.text('跟王总的往来'), findsOneWidget);
    expect(find.textContaining('最近一次：', findRichText: true), findsOneWidget);
    expect(find.text('还没兑现的待办（3）'), findsOneWidget);
    expect(find.byType(SceneRow), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('见面前帮我准备'));
    await tester.pumpAndSettle();
    final sent = llm.calls.single;
    expect(sent.last['content'], prepPrompt('王总'));
    expect(sent.first['content'], contains('标题b'));
    expect(sent.first['content'], isNot(contains('逐字稿原话')));
  });
}

class FakeLlm extends Llm {
  final calls = <List<Map<String, String>>>[];
  FakeLlm() : super(Cloud('http://localhost'), () => {});
  @override
  Future<String> chatMessages(List<Map<String, String>> messages, {double temperature = 0.2}) async {
    calls.add(messages);
    return '## 上次谈到哪\n- 好';
  }
}
