// 长录音（三到五小时一场会，上千行逐字稿）点开右栏不能卡：逐字稿要按需画（只画看得见的那些行），
// 播放器每走一下不能把整篇逐字稿重画一遍。
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
  const n = 1000; // 五小时的会：云端一行最长 30 秒 / 120 字（实测 88 分钟 193 行），按 18 秒一行往多了算
  final sentence = '我应该是从房地产那个时代跨过来的，身边好多四十几岁的人对于我来干这个事情也是觉得比较就是不理解，' * 2;

  setUp(() async {
    SceneDetail.transcriptTab.value = false;
    tmp = await Directory.systemTemp.createTemp('long_scene');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await store.lib.ensure();
    String clock(int i) {
      final s = 9 * 3600 + i * 18;
      return '${(s ~/ 3600).toString().padLeft(2, '0')}:${(s ~/ 60 % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
    }
    await store.putResult('rec1', {
      'start': '2026-10-17T09:00:00',
      'scenes': [
        {
          'id': 'a', 'start': '2026-10-17T09:00:00', 'end': '2026-10-17T14:00:00', 'category': '开会',
          'title': '五小时的长会', 'event': '一直在开会', 'people': ['王总'],
          'body': '## 要点\n${List.generate(40, (i) => '- 第 $i 条要点：$sentence').join('\n')}',
          'text': [for (var i = 0; i < n; i++) [clock(i), '第 $i 句 $sentence']],
        },
      ],
    });
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<Player> mount(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.allMessagesHandler = (channel, handler, message) async =>
        channel.startsWith('xyz.luan/audioplayers') ? const StandardMethodCodec().encodeSuccessEnvelope(null) : handler?.call(message);
    addTearDown(() => tester.binding.defaultBinaryMessenger.allMessagesHandler = null);
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = Player();
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SceneDetail(scene: store.scenes.single, player: player, store: store))));
    await tester.pumpAndSettle();
    return player;
  }

  for (final tab in [false, true]) {
    testWidgets('${tab ? '逐字稿' : '笔记'}页：几百行逐字稿只画看得见的，翻到底也翻得动', (tester) async {
      SceneDetail.transcriptTab.value = tab;
      final player = await mount(tester);
      final built = find.textContaining(' 我应该是从房地产').evaluate().length;
      expect(built, lessThan(80), reason: '一屏只看得见几十行，别一口气把 $n 行全画出来（现在画了 $built 行）');

      // 播放器走一下：看得见的行重画就够了
      final sw = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        player.notifyListeners();
        await tester.pump();
      }
      debugPrint('${tab ? '逐字稿' : '笔记'}页 播放器 20 次刷新：${sw.elapsedMilliseconds}ms，画了 $built 行');

      // 一直往下拉，最后一句拉得到
      final last = find.textContaining('第 ${n - 1} 句');
      final sw2 = Stopwatch()..start();
      for (var i = 0; i < 400 && last.evaluate().isEmpty; i++) {
        final pos = tester.state<ScrollableState>(find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first).position;
        pos.jumpTo((pos.pixels + 3000).clamp(0, pos.maxScrollExtent));
        await tester.pump();
      }
      debugPrint('拉到底：${sw2.elapsedMilliseconds}ms');
      expect(find.textContaining('第 ${n - 1} 句'), findsOneWidget);
      final atEnd = find.textContaining(' 我应该是从房地产').evaluate().length;
      expect(atEnd, lessThan(80), reason: '拉到逐字稿那节也只画看得见的（现在画了 $atEnd 行）');
    });
  }
}
