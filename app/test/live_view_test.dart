// 现场会议界面：双击一句进笔记以后，原话列表停在原地，不跳回最前面。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/live.dart';
import 'package:luyinka/live_view.dart';
import 'package:luyinka/store.dart';

void main() {
  testWidgets('双击进笔记：列表不跳', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('liveview');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    final live = LiveSession(store, Directory('${tmp.path}/app'), () async {}, shareMemory: false)
      ..stem = 'live20261024-150000'
      ..started = DateTime(2026, 10, 24, 15)
      ..state = LiveState.paused;
    for (var i = 0; i < 80; i++) {
      live.lines.add(LiveLine(DateTime(2026, 10, 24, 15, i ~/ 60, i % 60), '第$i句话'));
    }
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LiveView(live: live))));
    await tester.pumpAndSettle();

    final list = find.descendant(of: find.byKey(const PageStorageKey('live-lines')), matching: find.byType(Scrollable)).first;
    final pos = tester.state<ScrollableState>(list).position;
    pos.jumpTo(pos.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final before = pos.pixels;
    expect(before, greaterThan(500));

    final target = find.text('第40句话');
    expect(target, findsOneWidget);
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(target);
    await tester.pumpAndSettle();

    expect(live.notes, contains('第40句话'));
    expect(tester.state<ScrollableState>(list).position.pixels, closeTo(before, 1));
    await tester.pump(const Duration(seconds: 1)); // 等存草稿的计时器跑完
  });

  testWidgets('拖选一段 → 手边冒出「添加笔记」→ 加进去，列表也不跳', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('liveview');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    final live = LiveSession(store, Directory('${tmp.path}/app'), () async {}, shareMemory: false)
      ..stem = 'live20261024-150000'
      ..started = DateTime(2026, 10, 24, 15)
      ..state = LiveState.paused;
    for (var i = 0; i < 80; i++) {
      live.lines.add(LiveLine(DateTime(2026, 10, 24, 15, i ~/ 60, i % 60), '这是第$i句比较长的一句原话'));
    }
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LiveView(live: live))));
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byKey(const PageStorageKey('live-lines')), matching: find.byType(Scrollable)).first;
    final pos = tester.state<ScrollableState>(list).position;
    pos.jumpTo(pos.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final before = pos.pixels;

    final line = find.text('这是第40句比较长的一句原话');
    final r = tester.getRect(line);
    final g = await tester.startGesture(r.centerLeft + const Offset(2, 0), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await g.moveTo(r.center);
    await tester.pump();
    await g.moveTo(r.centerRight - const Offset(2, 0));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    final chip = find.text('添加笔记');
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(live.notes, contains('句比较长'));
    expect(tester.state<ScrollableState>(list).position.pixels, closeTo(before, 1));
    await tester.pump(const Duration(seconds: 1));
  });
}
