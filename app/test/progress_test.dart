// 处理中横幅：文案按时长 / 阶段说人话，卡住了要说出来；时间线占位卡放在开录的时间上，出结果后换成笔记。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/live.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/progress.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

const long = 'note20261023-194438'; // 13.6MB ≈ 1.9 小时
final t0 = DateTime(2026, 10, 24, 3, 0);

Rec rec(String stage, {String stem = long, int size = 13600000, int got = 0, int progress = 0, int sent = 0, double bps = 0, String? error}) =>
    Rec(stem, size, stage)
      ..got = got
      ..progress = progress
      ..sent = sent
      ..bps = bps
      ..error = error;

/// 进这一步 [ago] 之前，上次有进度在 [idle] 之前。
Track track(Rec r, {Duration ago = Duration.zero, Duration? idle, int? p0}) =>
    Track(r.stage, t0.subtract(ago), p0 ?? r.progress, r.got, r.progress, r.sent)..moved = t0.subtract(idle ?? ago);

Activity act(Rec r, {Duration ago = Duration.zero, Duration? idle, int? p0, bool connected = true, String? cloudError, int others = 0}) =>
    activity(r, track(r, ago: ago, idle: idle, p0: p0), connected: connected, now: t0, cloudError: cloudError, others: others);

void main() {
  group('安心话按时长说', () {
    test('1.9 小时：要等一会儿，没坏', () {
      expect(comfortLine(rec('processing')), '这段录音约 1.9 小时，要等一会儿；App 开着就行，没坏，好了会自动出现在下面');
    });
    test('短录音：马上就好', () {
      expect(comfortLine(rec('processing', size: 600000)), '这段录音不长（约 5 分钟），马上就好');
    });
    test('不知道多长（不是卡上来的）：不报时长', () {
      expect(comfortLine(rec('transcribed', size: 0)), 'App 开着就行，没坏，好了会自动出现在下面');
    });
    test('后面还有排着的', () {
      expect(comfortLine(rec('pulling'), others: 2), endsWith('（后面还有 2 条排着）'));
    });
  });

  group('大字按阶段说', () {
    test('拉卡：百分比 + 按实测速度估剩多久 + 边拉边传', () {
      final a = act(rec('pulling', got: 3400000, bps: 7000, sent: 2), ago: const Duration(minutes: 8), idle: const Duration(seconds: 1));
      expect(a.step, 0);
      expect(a.headline, '正在从卡上拉 25% · 约剩 25 分钟'); // 10.2MB / 7KB/s ≈ 24.3 分钟
      expect(a.detail, '3.4 / 13.6MB · 云端已经在边收边转（已传 2 段）');
      expect(a.alsoNext, isTrue);
      expect(a.stall, isNull);
      expect(a.fraction, closeTo(0.25, 0.001));
    });
    test('拉卡：卡刚断开，先说在等它连上，还不算卡住', () {
      final a = act(rec('pulling', got: 6800000), connected: false, ago: const Duration(minutes: 10), idle: const Duration(minutes: 1));
      expect(a.headline, '等卡重新连上，接着拉（已拉 50%）');
      expect(a.stall, isNull);
    });
    test('传云端', () {
      expect(act(rec('uploading')).headline, '正在传到云端');
      expect(act(rec('uploading')).step, 1);
    });
    test('转写：按这一步实测的速度估剩多久', () {
      // 10 分钟从 0 走到 40%：剩 60% 约 15 分钟
      final a = act(rec('processing', progress: 40), ago: const Duration(minutes: 10), idle: const Duration(seconds: 30), p0: 0);
      expect(a.step, 1);
      expect(a.headline, '正在转写 40% · 约剩 15 分钟');
      expect(a.stall, isNull);
    });
    test('转写刚开始：还没测出速度，按录音时长粗估', () {
      final a = act(rec('processing', progress: 0));
      expect(a.headline, '正在转写 0% · 约剩 23 分钟'); // 6800 秒 × 0.2 ≈ 22.7 分钟
    });
    test('整理：先分场景（还没有百分比），再按段走', () {
      expect(act(rec('analyzing')).headline, '正在整理 · 先分场景');
      expect(act(rec('analyzing')).step, 2);
      final a = act(rec('analyzing', progress: 50), ago: const Duration(minutes: 2), idle: const Duration(seconds: 10), p0: 0);
      expect(a.headline, '正在整理 50% · 约剩 2 分钟');
    });
    test('等整理', () => expect(act(rec('transcribed')).headline, '逐字稿好了，等着整理'));
  });

  group('卡住判定', () {
    test('拉卡：卡不在旁边 5 分钟没数据 → 卡住了，说清在自动重连', () {
      final a = act(rec('pulling', got: 6800000), connected: false, ago: const Duration(minutes: 12), idle: const Duration(minutes: 6));
      expect(a.stall, startsWith('卡住了：卡不在旁边或蓝牙断了，6 分钟没拉到数据'));
      expect(a.stall, contains('每 30 秒自动重连'));
      expect(a.stall, contains('你可以'));
    });
    test('拉卡：一直有进度但超过预计 2 倍 → 说慢，不说断了', () {
      // 13.6MB 按 7KB/s 预计 ≈ 32 分钟，拉了 70 分钟
      final a = act(rec('pulling', got: 9000000, bps: 2000), ago: const Duration(minutes: 70), idle: const Duration(seconds: 3));
      expect(a.stall, startsWith('卡住了：拉得比平常慢很多（已经拉了 70 分钟）'));
    });
    test('拉卡：预计以内、一直有进度 → 不算卡住', () {
      expect(act(rec('pulling', got: 9000000, bps: 7000), ago: const Duration(minutes: 30), idle: const Duration(seconds: 3)).stall, isNull);
    });
    test('转写：4 分 59 秒没进度不算，5 分钟算', () {
      expect(act(rec('processing', progress: 30), ago: const Duration(minutes: 8), idle: const Duration(minutes: 4, seconds: 59)).stall, isNull);
      final a = act(rec('processing', progress: 30), ago: const Duration(minutes: 8), idle: const Duration(minutes: 5));
      expect(a.stall, startsWith('卡住了：云端 5 分钟没有进度'));
      expect(a.headline, '正在转写 30%', reason: '卡住时不再报约剩多久');
    });
    test('转写：连不上云端', () {
      final a = act(rec('processing', progress: 30), ago: const Duration(minutes: 8), idle: const Duration(minutes: 6), cloudError: 'SocketException');
      expect(a.stall, startsWith('卡住了：连不上云端'));
    });
    test('转写：超过预计 2 倍（1.9 小时录音预计 28 分钟，过了 60 分钟）', () {
      final a = act(rec('processing', progress: 70), ago: const Duration(minutes: 60), idle: const Duration(seconds: 20), p0: 0);
      expect(a.stall, startsWith('卡住了：云端转得比平常慢很多（已经 60 分钟）'));
    });
    test('传云端失败 → 马上说', () {
      expect(act(rec('pulled', error: '上传没成功')).stall, startsWith('卡住了：传不上云端'));
    });
    test('整理失败 → 说原因和什么时候重试', () {
      expect(act(rec('transcribed', error: '整理没成功，稍后自动再试：401')).stall, contains('3 分钟后自动重试'));
    });
    test('整理 5 分钟模型没回话', () {
      expect(act(rec('analyzing', progress: 20), ago: const Duration(minutes: 7), idle: const Duration(minutes: 5)).stall, startsWith('卡住了：整理 5 分钟没有进度'));
    });
    test('云端出错：不假装会自动好', () {
      final a = act(rec('error', error: '转写失败'));
      expect(a.stall, startsWith('出错了：转写失败'));
      expect(a.stall, contains('不会自动重试'));
    });
  });

  test('计时：换一步重新计，有进度记时刻，做完的拿掉', () {
    final tracks = <String, Track>{};
    final r = rec('pulling', got: 100);
    observe(tracks, [r], t0);
    expect(tracks[long]!.since, t0);
    r.got = 200;
    observe(tracks, [r], t0.add(const Duration(minutes: 1)));
    expect(tracks[long]!.moved, t0.add(const Duration(minutes: 1)));
    expect(tracks[long]!.since, t0);
    observe(tracks, [r], t0.add(const Duration(minutes: 3)));
    expect(tracks[long]!.moved, t0.add(const Duration(minutes: 1)), reason: '没进度不算动');
    r
      ..stage = 'processing'
      ..progress = 12;
    observe(tracks, [r], t0.add(const Duration(minutes: 4)));
    expect(tracks[long]!.stage, 'processing');
    expect(tracks[long]!.since, t0.add(const Duration(minutes: 4)));
    expect(tracks[long]!.p0, 12);
    r.stage = 'done';
    observe(tracks, [r], t0.add(const Duration(minutes: 5)));
    expect(tracks, isEmpty);
  });

  test('估剩多久：进转写时那一下跳（边拉边传前几段早转完了）不算速度', () {
    final tracks = <String, Track>{};
    final r = rec('processing', progress: 0);
    observe(tracks, [r], t0);
    r.progress = 58; // 第一次问云端：前几段早转完了
    observe(tracks, [r], t0.add(const Duration(seconds: 5)));
    r.progress = 65;
    final now = t0.add(const Duration(seconds: 65)); // 之后 60 秒走了 7%
    observe(tracks, [r], now);
    final a = activity(r, tracks[long]!, connected: false, now: now);
    expect(a.headline, '正在转写 65% · 约剩 5 分钟'); // 35% ÷ 每分钟 7% = 5 分钟；把跳算进去会说「不到 1 分钟」
  });

  test('估剩多久：才动了 1 个点不按速度算（会乱跳），按录音时长估', () {
    final tracks = <String, Track>{};
    final r = rec('processing', size: 4320040, progress: 0);
    observe(tracks, [r], t0);
    r.progress = 58;
    observe(tracks, [r], t0.add(const Duration(seconds: 3)));
    r.progress = 59;
    final now = t0.add(const Duration(seconds: 34));
    observe(tracks, [r], now);
    // 36 分钟录音 × 0.2 × 剩 41% ≈ 3 分钟；按「31 秒走 1%」算会说 22 分钟
    expect(activity(r, tracks[long]!, connected: false, now: now).headline, '正在转写 59% · 约剩 3 分钟');
  });

  test('横幅说哪一条：正在动的优先', () {
    expect(featured([rec('card', stem: 'a'), rec('transcribed', stem: 'b'), rec('processing', stem: 'c')])!.stem, 'c');
    expect(featured([rec('card', stem: 'a'), rec('pulling', stem: 'b')])!.stem, 'b');
    expect(featured([]), isNull);
  });

  test('占位卡：开录时间 + 在干嘛；日子里带上还在处理的那天', () {
    expect(recStart(long), DateTime(2026, 10, 23, 19, 44, 38));
    expect(recStart('口述-abc'), isNull);
    expect(placeholderLine(rec('processing', progress: 45)), '19:44 起的录音 · 正在转写 45%');
    expect(placeholderLine(rec('pulling', got: 3400000)), '19:44 起的录音 · 正在从卡上拉 25%');
    expect(placeholderLine(rec('analyzing', stem: '口述-abc')), '一段录音 · 正在整理 0%');
    expect(daysWithPending(['2026-10-22', '2026-10-20'], [rec('processing'), rec('analyzing', stem: '口述-abc')]),
        ['2026-10-23', '2026-10-22', '2026-10-20']);
  });

  group('界面', () {
    late Directory tmp;
    late Store store;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('banner');
      store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
      await Directory('${tmp.path}/app/raw').create(recursive: true);
      await store.lib.ensure();
      await store.putResult('note20261023-090000', {
        'start': '2026-10-23T09:00:00',
        'scenes': [
          {'id': 'a', 'start': '2026-10-23T09:00:00', 'end': '2026-10-23T10:00:00', 'category': '开会', 'title': '早上的周会',
           'event': '周会', 'people': [], 'text': [], 'body': '## 要点', 'actions': [], 'reminders': []},
          {'id': 'b', 'start': '2026-10-23T21:30:00', 'end': '2026-10-23T21:50:00', 'category': '个人感悟', 'title': '晚上的想法',
           'event': '想法', 'people': [], 'text': [], 'body': '## 想法', 'actions': [], 'reminders': []},
        ],
      });
    });
    tearDown(() async {
      await store.save();
      await tmp.delete(recursive: true);
    });

    for (final (name, size) in [('Mac 宽屏', const Size(1500, 1000)), ('手机窄屏', const Size(400, 860))]) {
      testWidgets('$name：横幅 + 时间线占位卡（排在早上和晚上那两段中间），出结果后都消失', (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
        tester.binding.defaultBinaryMessenger.allMessagesHandler = (channel, handler, message) async =>
            channel.startsWith('xyz.luan/audioplayers') ? const StandardMethodCodec().encodeSuccessEnvelope(null) : handler?.call(message);
        addTearDown(() => tester.binding.defaultBinaryMessenger.allMessagesHandler = null);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        store.recs[long] = rec('processing', progress: 45);
        final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai');
        await tester.pumpWidget(MaterialApp(
            home: Home(store: store, syncer: syncer, live: LiveSession(store, store.dir, () async {}, shareMemory: false))));
        await tester.pump();

        expect(find.byType(ProgressBanner), findsOneWidget);
        expect(find.text('正在转写 45% · 约剩 13 分钟'), findsOneWidget); // 刚开始没测出速度：6800 秒 × 0.2 × 55%
        expect(find.text('云端转写'), findsOneWidget);
        expect(find.text('这段录音约 1.9 小时，要等一会儿；App 开着就行，没坏，好了会自动出现在下面'), findsOneWidget);
        expect(find.text('19:44 起的录音 · 正在转写 45%'), findsOneWidget);
        double y(String s) => tester.getTopLeft(find.descendant(of: find.byType(DayColumn), matching: find.text(s))).dy;
        expect(y('早上的周会') < y('19:44 起的录音 · 正在转写 45%'), isTrue);
        expect(y('19:44 起的录音 · 正在转写 45%') < y('晚上的想法'), isTrue);

        store.recs[long]!.stage = 'done';
        await tester.runAsync(() => store.save());
        await tester.pump();
        expect(find.byType(ProgressBanner), findsNothing);
        expect(find.byType(PendingRow), findsNothing);
      });
    }
  });
}
