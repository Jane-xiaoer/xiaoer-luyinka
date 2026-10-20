// 右栏详情的「笔记 | 逐字稿」切换和一键拷贝：点「逐字稿」直接看到拷贝按钮和全文，拷贝进剪贴板的字对；窄屏不溢出。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';

void main() {
  late Directory tmp;
  late Store store;

  setUp(() async {
    SceneDetail.transcriptTab.value = false;
    tmp = await Directory.systemTemp.createTemp('transcript_view');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await store.lib.ensure();
    await store.putResult('rec1', {
      'start': '2026-10-17T09:00:00',
      'scenes': [
        {
          'id': 'a', 'start': '2026-10-17T09:00:00', 'end': '2026-10-17T09:20:00', 'category': '开会',
          'title': '周会：讨论下个季度的报价和渠道安排', 'event': '和王总、李姐一起过了一遍报价单', 'people': ['王总', '李姐'],
          'place': '公司三楼会议室', 'body': '## 要点\n- 报价单本周发',
          'text': [
            ['09:00:05', '大家好，今天主要说报价'],
            ['09:00:30', '先看渠道那块'],
          ],
        },
        {
          'id': 'b', 'start': '2026-10-17T09:20:00', 'end': '2026-10-17T09:40:00', 'category': '开会', 'title': '复盘',
          'event': '复盘', 'people': [], 'body': '',
          'text': [
            ['09:20:10', '说说上周的问题'],
          ],
        },
      ],
    });
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<List<String>> mount(WidgetTester tester, double width) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    // 播放器插件在测试里没有原生实现：它的通道一律回「成功」
    tester.binding.defaultBinaryMessenger.allMessagesHandler = (channel, handler, message) async =>
        channel.startsWith('xyz.luan/audioplayers') ? const StandardMethodCodec().encodeSuccessEnvelope(null) : handler?.call(message);
    addTearDown(() => tester.binding.defaultBinaryMessenger.allMessagesHandler = null);
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = Player();
    addTearDown(player.dispose);
    final scene = store.scenes.firstWhere((s) => s.id == 'a');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SceneDetail(scene: scene, player: player, store: store))));
    await tester.pumpAndSettle();
    return copied;
  }

  testWidgets('点「逐字稿」：拷贝按钮和全文直接可见；拷贝 / 带时间 / 整条录音进剪贴板', (tester) async {
    final copied = await mount(tester, 1000);
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('带时间拷贝'), findsOneWidget); // 笔记页最底下那节也有
    await tester.tap(find.text('逐字稿').first);
    await tester.pumpAndSettle();
    expect(SceneDetail.transcriptTab.value, isTrue);
    expect(find.text('拷贝'), findsOneWidget);
    expect(find.text('带时间拷贝'), findsOneWidget);
    expect(find.text('整条录音'), findsOneWidget);
    expect(find.text('大家好，今天主要说报价'), findsOneWidget);
    expect(find.text('先看渠道那块'), findsOneWidget);
    for (final t in ['拷贝', '大家好，今天主要说报价']) {
      final r = tester.getRect(find.text(t));
      expect(r.bottom, lessThan(800), reason: '$t 不用往下翻就看得到');
    }

    await tester.tap(find.text('拷贝'));
    await tester.pump();
    expect(copied.last, '大家好，今天主要说报价\n先看渠道那块');
    expect(find.text('逐字稿复制好了（17 字）'), findsOneWidget);

    await tester.tap(find.text('带时间拷贝'));
    await tester.pump();
    expect(copied.last, '[09:00:05] 大家好，今天主要说报价\n[09:00:30] 先看渠道那块');

    await tester.tap(find.text('整条录音'));
    await tester.pump();
    expect(copied.last, '## 09:00 周会：讨论下个季度的报价和渠道安排\n\n大家好，今天主要说报价\n先看渠道那块\n\n## 09:20 复盘\n\n说说上周的问题');

    // 切换状态记住：换一段还是逐字稿页
    final player = Player();
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SceneDetail(scene: store.scenes.firstWhere((s) => s.id == 'b'), player: player, store: store))));
    await tester.pumpAndSettle();
    expect(find.text('说说上周的问题'), findsOneWidget);
    expect(find.text('拷贝'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('窄屏 360：笔记页和逐字稿页都不溢出', (tester) async {
    await mount(tester, 360);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('逐字稿').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('整条录音'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
