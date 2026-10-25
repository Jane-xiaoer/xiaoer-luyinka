// 文稿开了 iCloud「优化存储」：有的文件被挪到云上，App 读它直接报错（不干等）。
// 这时同步照样起得来，页面照样画得出，读不出的那条先跳过、不当成做完了。（用读不了的文件模拟）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/card/view.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

void main() {
  test('索引读不出来：peekResult 当没有；同步照样起得来；待整理的不当成做完了', () async {
    final tmp = await Directory.systemTemp.createTemp('unread');
    final lib = Library(Directory('${tmp.path}/资料'));
    await lib.ensure();
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    final store = Store(Directory('${tmp.path}/app'))..lib = lib;
    await store.putResult('r1', {'start': '2026-10-18T14:00:00', 'lines': [], 'scenes': []});
    store.recs['r1'] = Rec('r1', 0, 'done');
    store.recs['r2'] = Rec('r2', 0, 'transcribed');
    await store.putResult('r2', {'start': '2026-10-18T15:00:00', 'lines': [], 'scenes': []});
    for (final s in ['r1', 'r2']) {
      await Process.run('chmod', ['000', store.result(s).path]);
    }
    expect(() => store.readResult('r1'), throwsA(anything));
    expect(store.peekResult('r1'), isNull);

    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai');
    syncer.start(); // 以前这里抛错，定时同步就再也起不来
    await syncer.run(fromCard: false);
    expect(store.recs['r2']!.stage, 'transcribed'); // 读不出 ≠ 做完了
    syncer.stop();
    for (final s in ['r1', 'r2']) {
      await Process.run('chmod', ['644', store.result(s).path]);
    }
    await store.save(); // 后台的保存先等它落盘，再收拾
    await Future.delayed(const Duration(milliseconds: 200));
    await tmp.delete(recursive: true);
  });

  testWidgets('录音卡页：有一条索引读不出来也画得出，那条照样列着', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('unread2');
    final lib = Library(Directory('${tmp.path}/资料'));
    await tester.runAsync(() async {
      await lib.ensure();
      await Directory('${tmp.path}/app/raw').create(recursive: true);
    });
    final store = Store(Directory('${tmp.path}/app'))..lib = lib;
    await tester.runAsync(() async {
      await store.putResult('2026-10-18 07.40.00', {'start': '2026-10-18T07:40:00', 'seconds': 60, 'lines': [['07:40:00', '你好']], 'scenes': []});
      await Process.run('chmod', ['000', store.result('2026-10-18 07.40.00').path]);
    });
    store.recs['2026-10-18 07.40.00'] = Rec('2026-10-18 07.40.00', 120000, 'done');
    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai');
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CardView(syncer: syncer, store: store, onOpen: (_) {}))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('卡上来的录音'), findsOneWidget);
    expect(find.textContaining('2026-10-18 07:40'), findsOneWidget);
    await tester.runAsync(() => Process.run('chmod', ['644', store.result('2026-10-18 07.40.00').path]));
  });
}
