// 界面：左栏「待办」「每周回顾」，中栏待办打勾进「已完成」，每周回顾的提示和生成按钮，个人感悟的「按主题整理观点库」。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

void main() {
  late Directory tmp;
  late Store store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('views');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
    await store.putResult('rec1', {
      'start': '2026-10-17T09:00:00',
      'scenes': [
        {
          'id': 'a', 'start': '2026-10-17T09:00:00', 'end': '2026-10-17T10:00:00', 'category': '开会', 'title': '周会',
          'event': '周会', 'people': [], 'text': [], 'body': '## 要点\n- x',
          'actions': [{'text': '把报价单发给王总', 'who': '我'}],
          'reminders': [{'text': '跟进合同', 'when': '下周三'}],
        },
        {
          'id': 'b', 'start': '2026-10-17T12:00:00', 'end': '2026-10-17T12:20:00', 'category': '个人感悟', 'title': '想法',
          'event': '想法', 'people': [], 'text': [], 'body': '## 感悟了什么\n- y', 'actions': [], 'reminders': [],
        },
      ],
    });
  });
  tearDown(() async {
    await store.save();
    await tmp.delete(recursive: true);
  });

  testWidgets('待办：分有时间 / 没时间，打勾进已完成；每周回顾：过完没生成有提示；个人感悟有按主题整理', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    // 播放器插件在测试里没有原生实现：它的通道一律回「成功」
    tester.binding.defaultBinaryMessenger.allMessagesHandler = (channel, handler, message) async =>
        channel.startsWith('xyz.luan/audioplayers') ? const StandardMethodCodec().encodeSuccessEnvelope(null) : handler?.call(message);
    addTearDown(() => tester.binding.defaultBinaryMessenger.allMessagesHandler = null);
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai');
    await tester.pumpWidget(MaterialApp(home: Home(store: store, syncer: syncer)));

    expect(find.text('待办'), findsOneWidget);
    expect(find.text('每周回顾'), findsOneWidget);
    expect(find.text('2'), findsWidgets); // 左栏待办数

    await tester.tap(find.text('待办'));
    await tester.pumpAndSettle();
    expect(find.text('有时间的'), findsOneWidget);
    expect(find.text('没时间的'), findsOneWidget);
    expect(find.text('跟进合同'), findsOneWidget);
    expect(find.text('下周三'), findsOneWidget);
    expect(find.text('谁去做：我'), findsOneWidget);
    expect(find.text('点一条待办'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    // 写文件是真 IO：每一步都让真时间走一下、再把测试里的微任务冲掉，直到写完
    for (var i = 0; i < 40 && find.text('已完成（1）').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('已完成（1）'), findsOneWidget);
    expect(find.text('有时间的'), findsNothing);
    expect(store.scenes.firstWhere((s) => s.id == 'a').reminders.single['done'], isTrue);

    // 点来源：右栏打开那段
    await tester.tap(find.text('10/17 09:00 · 周会 ›'));
    await tester.pumpAndSettle();
    expect(find.text('点一条待办'), findsNothing);

    await tester.tap(find.text('每周回顾'));
    await tester.pumpAndSettle();
    expect(find.text('这周还没回顾，点这里生成'), findsOneWidget);
    expect(find.text('生成这周回顾'), findsOneWidget);
    expect(find.text('10/12–10/18 这一周'), findsOneWidget);

    await tester.tap(find.text('按类别'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('个人感悟').first);
    await tester.pumpAndSettle();
    expect(find.text('按主题整理观点库'), findsOneWidget);
  });
}
