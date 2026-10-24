// 横幅验收用的演示入口（不打进正式包）：本机云端 + 限速假卡（≈7KB/s，跟真卡蓝牙差不多）真跑一条长录音，
// 拉卡中 / 模拟卡住 / 转写中 / 整理中 / 出结果 各截一张 Mac 宽屏 + 手机窄屏。整理用假模型（每回一次话等几秒）。
//   flutter build macos --debug -t demo/banner_demo.dart \
//     --dart-define=DEMO_RAW=/tmp/luyinka-stream-e2e/note20261023-194438.opus --dart-define=DEMO_DIR=/tmp/luyinka-banner-demo
// 截图在 $DEMO_DIR/shots/，过程记在 $DEMO_DIR/demo.log。
// 编之前把 macos/Runner/Configs/AppInfo.xcconfig 临时改成别的 PRODUCT_NAME / PRODUCT_BUNDLE_IDENTIFIER
//（如 XiaoerLuyinkaBannerDemo / xyz.xiaoerai.luyinka.bannerdemo），编完改回来：同名同 ID 时，别处启动或按名字退出
// 小耳录音卡（正式版、别的工作区的调试版）会把这个演示一起关掉，跑了一半就没了。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/progress.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/theme.dart';

import '../test/fake_card.dart';

const rawPath = String.fromEnvironment('DEMO_RAW', defaultValue: '/tmp/luyinka-stream-e2e/note20261023-194438.opus');
const base = String.fromEnvironment('DEMO_DIR', defaultValue: '/tmp/luyinka-banner-demo');
const cloudUrl = String.fromEnvironment('DEMO_CLOUD', defaultValue: 'http://127.0.0.1:8790');
const bps = int.fromEnvironment('DEMO_BPS', defaultValue: 7000);

final t0 = DateTime.now();
final logFile = File('$base/demo.log');
void log(String s) {
  final line = '${(DateTime.now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1).padLeft(7)}s  $s';
  logFile.writeAsStringSync('$line\n', mode: FileMode.append);
}

final narrow = ValueNotifier(false);
final shotKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final run = Directory('$base/run');
  if (run.existsSync()) run.deleteSync(recursive: true);
  Directory('$base/shots').createSync(recursive: true);
  if (logFile.existsSync()) logFile.deleteSync();

  final stem = rawPath.split('/').last.replaceAll('.opus', '');
  final data = File(rawPath).readAsBytesSync();
  final store = Store(Directory('${run.path}/app'))..lib = Library(Directory('${run.path}/资料'));
  await Directory('${run.path}/app/raw').create(recursive: true);
  await store.lib.ensure();
  // 同一天早上、晚上各有一段已经整理好的（演示用的假内容），占位卡应该夹在它们中间
  final day = recDay(stem)!;
  await store.putResult('demo-$day', {
    'start': '${day}T09:00:00',
    'scenes': [
      _scene('m', '${day}T09:30:00', '${day}T10:20:00', '开会', '早上的产品周会', '对了这周的版本计划和分工。'),
      _scene('n', '${day}T21:10:00', '${day}T21:25:00', '个人感悟', '晚上散步时的想法', '想到录音卡的处理过程要让人看得见。'),
    ],
  });

  final card = FakeCard({FakeCard.deviceName(stem): data})
    ..bytesPerSec = bps
    ..dropAt = (data.length * 0.5 ~/ 40) * 40; // 拉到一半蓝牙断开，卡「拿走」，演示卡住
  var away = false;
  store.settings['device'] = card.id;
  store.settings['deviceName'] = '录音卡 · 演示';
  final cloud = Cloud(cloudUrl);
  final syncer = Syncer(store, cloud, (id) async => away ? null : card.connect(id), card.scan, () => 'America/Los_Angeles',
      chat: (s, u) async {
    await Future.delayed(const Duration(seconds: 6));
    if (s.contains('"scenes"')) {
      final clocks = RegExp(r'^\[(\d\d:\d\d:\d\d)\]', multiLine: true).allMatches(u).map((m) => m.group(1)!).toList();
      final mid = clocks[clocks.length ~/ 2];
      return jsonEncode({
        'scenes': [
          {'start': clocks.first, 'end': mid, 'category': '开会', 'title': '演示：长会议', 'event': '演示用的假整理结果。',
           'people': [], 'actions': [], 'reminders': []},
          {'start': mid, 'end': clocks.last, 'category': '多人群聊', 'title': '演示：会后闲聊', 'event': '演示用的假整理结果。',
           'people': [], 'actions': [], 'reminders': []},
        ]
      });
    }
    return '## 要点\n- 演示用的假模型写的笔记';
  });

  runApp(DemoApp(store: store, syncer: syncer));
  // 上一轮跑到一半被正常退出了（没崩溃记录）：记下是不是有人 / 系统叫它退出
  AppLifecycleListener(onExitRequested: () async {
    log('收到退出请求（窗口被关 / Cmd+Q / 系统要求）');
    return ui.AppExitResponse.exit;
  });
  log('开始：$stem ${data.length} 字节 ≈ ${(data.length / 2000 / 60).toStringAsFixed(1)} 分钟录音；卡限速 $bps B/s；拉到 ${card.dropAt} 字节断开');

  Rec? r() => store.recs[stem];
  String brief() {
    final x = r();
    if (x == null) return '还没看到这条';
    final a = activity(x, syncer.track(x), connected: syncer.card.connected, now: DateTime.now(), cloudError: syncer.card.error);
    return '${x.stage} got=${x.got}/${x.size} sent=${x.sent} progress=${x.progress} 连着=${syncer.card.connected} | ${a.headline}${a.stall == null ? '' : ' | ${a.stall}'}';
  }

  final ticker = Timer.periodic(const Duration(seconds: 15), (_) => log(brief()));
  Future<void> until(bool Function() ok, String what, {Duration max = const Duration(minutes: 40)}) async {
    final end = DateTime.now().add(max);
    while (!ok()) {
      if (DateTime.now().isAfter(end)) throw StateError('等「$what」超时');
      await Future.delayed(const Duration(milliseconds: 300));
    }
    log('到了：$what · ${brief()}');
  }

  try {
    syncer.start();
    await until(() => (r()?.got ?? 0) > data.length * 0.42 && (r()?.bps ?? 0) > 0, '拉卡 42%');
    await shoot('1-拉卡中');
    await until(() => r()?.stage == 'pulling' && !syncer.card.connected, '蓝牙断了');
    away = true;
    log('卡「拿走」了：之后每 30 秒重连都连不上');
    await until(() {
      final x = r()!;
      return activity(x, syncer.track(x), connected: syncer.card.connected, now: DateTime.now()).stall != null;
    }, '横幅判定卡住（5 分钟没进度）', max: const Duration(minutes: 8));
    await Future.delayed(const Duration(seconds: 11)); // 等横幅自己的 10 秒重算
    await shoot('2-模拟卡住');
    away = false;
    log('卡放回来了');
    await until(() => r()?.stage == 'processing', '云端转写');
    await Future.delayed(const Duration(seconds: 2));
    await shoot('3-转写中');
    await until(() => r()?.stage == 'analyzing', '整理中');
    // 分场景那几轮没有百分比：等到开始写笔记（有百分比）再截，最多等 2 分钟
    await until(() => r()?.stage != 'analyzing' || r()!.progress > 0, '整理有百分比', max: const Duration(minutes: 2))
        .catchError((_) {});
    await shoot('4-整理中');
    await until(() => r()?.stage == 'done', '出结果');
    await Future.delayed(const Duration(seconds: 2));
    await shoot('5-出结果');
    log('完成 ✅');
  } catch (e, st) {
    log('出错：$e\n$st');
  } finally {
    ticker.cancel();
    syncer.stop();
    await Future.delayed(const Duration(seconds: 1));
    exit(0);
  }
}

Map<String, dynamic> _scene(String id, String start, String end, String cat, String title, String event) => {
      'id': id, 'start': start, 'end': end, 'category': cat, 'title': title, 'event': event,
      'people': [], 'text': [], 'body': '## 要点\n- $event', 'actions': [], 'reminders': [],
    };

/// 宽屏、窄屏各截一张（App 自己把画面渲染成 PNG，不靠系统截屏）。
Future<void> shoot(String name) async {
  for (final n in [false, true]) {
    narrow.value = n;
    for (var attempt = 1;; attempt++) {
      await Future.delayed(const Duration(milliseconds: 800));
      // 窗口被别的窗口挡住时 macOS 不给 Flutter 出帧，截到的会是挡住之前那一帧：自己强制画一帧再截
      SchedulerBinding.instance.scheduleWarmUpFrame();
      await Future.delayed(const Duration(milliseconds: 400));
      final b = shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 2);
      // 窄屏那张一定是 800 像素宽（400 × 2）；对不上说明截到的是旧画面，重来
      if ((img.width == 800) != n) {
        log('截图 $name 第 $attempt 次拿到的是旧画面（宽 ${img.width}），重截');
        if (attempt < 6) continue;
      }
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      final f = File('$base/shots/$name-${n ? '手机窄屏' : 'Mac宽屏'}.png');
      await f.writeAsBytes(png!.buffer.asUint8List());
      log('截图 ${f.path}（${img.width}×${img.height}）');
      break;
    }
  }
  narrow.value = false;
}

class DemoApp extends StatelessWidget {
  final Store store;
  final Syncer syncer;
  const DemoApp({super.key, required this.store, required this.syncer});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: narrow,
        builder: (_, n, _) => MaterialApp(
          key: ValueKey(n),
          title: '小耳录音卡（横幅演示）',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          builder: (context, child) {
            if (!n) return RepaintBoundary(key: shotKey, child: child);
            final mq = MediaQuery.of(context);
            final size = Size(400, mq.size.height < 860 ? mq.size.height : 860);
            return ColoredBox(
              color: const Color(0xFF333333),
              child: Center(
                child: RepaintBoundary(
                  key: shotKey,
                  child: SizedBox.fromSize(
                    size: size,
                    child: MediaQuery(data: mq.copyWith(size: size, padding: EdgeInsets.zero), child: child!),
                  ),
                ),
              ),
            );
          },
          home: Home(store: store, syncer: syncer),
        ),
      );
}
