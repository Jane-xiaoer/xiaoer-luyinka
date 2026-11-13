// 随手记 + 会后笔记卡：新建、写、待办进待办、标题跟第一行、md 在 随手记/、按天里有、不会被重新整理清空、删掉；
// 会后在卡里改笔记会存、待办里打勾卡里跟着变。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/note_doc.dart';
import 'package:luyinka/note_store.dart';
import 'package:luyinka/notes_card.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';
import 'package:luyinka/todos.dart';

void main() {
  late Directory tmp;
  late Store store;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('memo');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await store.lib.ensure();
    await Directory('${tmp.path}/app/raw').create(recursive: true);
  });
  tearDown(() async {
    await store.save();
    await tmp.delete(recursive: true);
  });

  test('随手记：写了待办进待办，标题跟第一行，md 在 随手记/，按天里有', () async {
    final s = await store.newMemo(DateTime(2026, 11, 13, 9, 30));
    expect(sourceOf(s.stem), '随手记');
    expect(showsNotes(store, s), isTrue);
    const text = '# 想到的\n☐ 给周总回电话\n· 旁白要软一点';
    await store.putNotes(s.stem, text, metaOf(text, null)..forEach((m) => m.src = 'me'));
    final now = store.scenes.single;
    expect(now.title, '想到的');
    expect(now.category, '自言自语');
    expect([for (final t in todosOf(store.scenes)) '${t.text}|${t.who}|${rawOf(t)['confirmed']}'], ['给周总回电话|我|true']);
    expect(store.days.keys, contains('2026-11-13'));
    final md = File('${store.lib.memoDir.path}/2026-11-13 0930 想到的.md').readAsStringSync();
    expect(md, contains('- [ ] 给周总回电话'));
    // 类别文件夹里不另存一份
    expect(Directory('${store.lib.path}/自言自语').existsSync() ? Directory('${store.lib.path}/自言自语').listSync() : [], isEmpty);
  });

  test('随手记、只有笔记的会：重新整理不会把它清空', () async {
    final s = await store.newMemo(DateTime(2026, 11, 13, 9, 30));
    await store.putNotes(s.stem, '☐ 甲', [LineMeta('a')]);
    final sy = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai',
        chat: (_, _) async => '{"scenes":[]}');
    await sy.reanalyze(s.stem);
    expect(store.scenes.single.actions.single['text'], '甲');
    // 就算排进了整理队列也不动
    store.recs[s.stem] = Rec(s.stem, 0, 'transcribed')..deletedOnCard = true;
    await sy.run(fromCard: false);
    expect(store.scenes.single.actions.single['text'], '甲');
  });

  test('删掉随手记：索引、md、时间线都没了', () async {
    final s = await store.newMemo(DateTime(2026, 11, 13, 9, 30));
    await store.putNotes(s.stem, '要记的', [LineMeta('a')]);
    await store.dropRecording(s.stem);
    await store.lib.deleteMemoFile(s.stem, DateTime(2026, 11, 13, 9, 30));
    expect(store.scenes, isEmpty);
    expect(store.result(s.stem).existsSync(), isFalse);
    expect(store.lib.memoDir.listSync(), isEmpty);
  });

  testWidgets('会后笔记卡：改了自动存、待办里打勾卡里跟着变', (tester) async {
    late Scene s;
    await tester.runAsync(() async {
      s = await store.newMemo(DateTime(2026, 11, 13, 9, 30));
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: MyNotesCard(scene: s, store: store)))));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '☐ 发报价');
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() async => Future.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(store.readResult(s.stem)!['notes'], '☐ 发报价');
    expect(find.textContaining('1 条在「待办」'), findsOneWidget);

    // 失焦后，在待办里打勾 → 卡里那行变 ☑
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.runAsync(() async => store.setTodoDone(todosOf(store.scenes).single, true));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() async => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('点了随手记什么都没写就走：这条和 md 都不留', (tester) async {
    late Scene s;
    await tester.runAsync(() async {
      s = await store.newMemo(DateTime(2026, 11, 13, 9, 30));
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: MyNotesCard(scene: s, store: store)))));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() async => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(store.scenes, isEmpty);
    expect(store.result(s.stem).existsSync(), isFalse);
  });
}
