// 现场会议「这是谁？」：名单里选人（验收员芯写的复现，改成断言）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/live.dart';
import 'package:luyinka/live_view.dart';
import 'package:luyinka/store.dart';

Future<LiveSession> setup(WidgetTester tester) async {
  final tmp = Directory.systemTemp.createTempSync('liveview');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
  Directory('${tmp.path}/资料').createSync(recursive: true);
  store.lib.peopleFile.writeAsStringSync('# 人员名单\n\n- 周总周宁（周总周宁、周总）｜甲方｜春芽｜｜明川生物\n- 周立（周立）｜｜｜\n');
  final live = LiveSession(store, Directory('${tmp.path}/app'), () async {}, shareMemory: false)
    ..stem = 'live20261024-150000'
    ..started = DateTime(2026, 10, 24, 15)
    ..state = LiveState.paused;
  for (var i = 0; i < 3; i++) {
    live.lines.add(LiveLine(DateTime(2026, 10, 24, 15, 0, i), '第$i句话'));
  }
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: LiveView(live: live))));
  await tester.pumpAndSettle();
  await tester.tap(find.text('？').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('新的人…'));
  await tester.pumpAndSettle();
  return live;
}

void main() {
  testWidgets('打「周」：弹出名单上的人带公司；直接回车选高亮的那个，不存成「周」', (tester) async {
    final live = await setup(tester);
    await tester.enterText(find.byType(TextField).last, '周');
    await tester.pumpAndSettle();
    expect(find.text('周总周宁 · 明川生物'), findsOneWidget);
    expect(find.text('周立'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(live.lines.first.speaker, '周总周宁');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('点选下拉里的人', (tester) async {
    final live = await setup(tester);
    await tester.enterText(find.byType(TextField).last, '周');
    await tester.pumpAndSettle();
    await tester.tap(find.text('周立'));
    await tester.pumpAndSettle();
    expect(live.lines.first.speaker, '周立');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('名单外的人：打全名回车 / 点「好」照样存', (tester) async {
    final live = await setup(tester);
    await tester.enterText(find.byType(TextField).last, '王总');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(live.lines.first.speaker, '王总');
    await tester.pump(const Duration(seconds: 2));
  });
}
