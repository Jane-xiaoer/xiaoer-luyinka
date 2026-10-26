import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'bean/sync.dart';
import 'card/ble.dart';
import 'cloud.dart';
import 'home.dart';
import 'live.dart';
import 'local_asr.dart';
import 'store.dart';
import 'sync.dart';
import 'theme.dart';

/// 云端地址：编译时 --dart-define=LUYINKA_CLOUD=… 可改，设置里也能改。
const defaultCloud = String.fromEnvironment('LUYINKA_CLOUD', defaultValue: 'https://luyinka.xiaoeromia.com:8443');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 远程测试机自检现场会议的识别（不开界面、不碰资料）：LUYINKA_LIVE_SELFTEST="<wav>|<输出目录>"
  final selftest = Platform.environment['LUYINKA_LIVE_SELFTEST'];
  if (selftest != null && selftest.contains('|')) {
    final [wav, out] = selftest.split('|');
    Cloud? cloud;
    if (Platform.environment['LUYINKA_SELFTEST_CLOUD'] == '1') {
      // 用云端识别自检：拿本机 App 登记过的云端身份
      final st = File('${(await getApplicationSupportDirectory()).path}/luyinka/state.json');
      final s = (jsonDecode(await st.readAsString()) as Map)['settings'] as Map;
      cloud = Cloud((s['cloud'] as String?) ?? defaultCloud, token: s['token'] as String?);
    }
    await liveSelfTest(wav, out, cloud: cloud);
    exit(0);
  }
  // 自检「也录电脑声音」（不开界面）：录 N 秒电脑声音，走跟现场会议一样的混音，存成 wav：LUYINKA_SYS_SELFTEST="<秒>|<wav>"
  final sys = Platform.environment['LUYINKA_SYS_SELFTEST'];
  if (sys != null && sys.contains('|')) {
    final [secs, wav] = sys.split('|');
    await systemAudioSelfTest(int.parse(secs), wav);
    exit(0);
  }
  // 自检录音本机转写（不开界面）：LUYINKA_LOCAL_ASR_TEST="<原文件>|<录音名>|<结果 json>"
  final asrTest = Platform.environment['LUYINKA_LOCAL_ASR_TEST'];
  if (asrTest != null && asrTest.contains('|')) {
    final [raw, stem, out] = asrTest.split('|');
    final appDir = Directory('${(await getApplicationSupportDirectory()).path}/luyinka');
    final sw = Stopwatch()..start();
    final res = await LocalAsr(LiveModels(appDir)).transcribe(File(raw), stem, File('$out.m4a'));
    res['用时秒'] = sw.elapsedMilliseconds / 1000;
    File(out).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(res));
    exit(0);
  }
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/luyinka');
  await dir.create(recursive: true);
  final store = Store(dir);
  await store.load();
  // 资料文件夹在 iCloud 上、有文件被挪到云上了：请系统在后台下载回来，下回来了再读一遍
  if (Platform.isMacOS) {
    const files = MethodChannel('luyinka/files');
    files.invokeMethod('download', store.lib.path).catchError((_) {});
    Timer.periodic(const Duration(minutes: 1), (_) {
      if (store.unreadable > 0) store.reload();
    });
  }
  final cloud = Cloud((store.settings['cloud'] as String?) ?? defaultCloud, token: store.settings['token'] as String?);
  final models = LiveModels(dir); // 现场会议和录音转写共用一套本机模型
  final syncer = Syncer(
    store,
    cloud,
    (id) async {
      final link = await BleLink.find(id);
      if (link != null) store.settings['deviceName'] ??= BleLink.label(link.device); // 旧版只记了 id
      return link;
    },
    () async => [for (final d in await BleLink.scan()) CardChoice(d.deviceId, BleLink.label(d), d.rssi)],
    deviceTimezone,
    local: LocalAsr(models),
  );
  // 现场会议：收进录音卡后让同步器跑一轮，把它排进整理
  final live = LiveSession(store, dir, () => syncer.run(fromCard: false));
  // 录音豆（安克 AI 录音豆 / 飞书版）：后台用蓝牙拉新录音，拉完交给 Syncer 转写整理
  final bean = BeanSyncer(store, () => syncer.run(fromCard: false));
  runApp(LuyinkaApp(store: store, syncer: syncer, live: live, bean: bean));
  syncer.start();
  // Mac：本机识别模型（约 240MB）后台悄悄下好，录音就能在本机转（快很多）；没下好之前照常传云端
  if (Platform.isMacOS && !models.ready) unawaited(models.ensure((_, _) {}).catchError((_) {}));
  bean.start();
}

/// 设备时区的 IANA 名：Flutter 只给得出 UTC 偏移，按偏移挑常用的（国内 +8 = 上海）。
String deviceTimezone() {
  const known = {
    480: 'Asia/Shanghai',
    540: 'Asia/Tokyo',
    420: 'Asia/Bangkok',
    0: 'UTC',
    -420: 'America/Los_Angeles',
    -480: 'America/Los_Angeles',
    -300: 'America/New_York',
    -240: 'America/New_York',
    60: 'Europe/Berlin',
    120: 'Europe/Berlin',
  };
  return known[DateTime.now().timeZoneOffset.inMinutes] ?? 'Asia/Shanghai';
}

class LuyinkaApp extends StatelessWidget {
  final Store store;
  final Syncer syncer;
  final LiveSession live;
  final BeanSyncer? bean;
  const LuyinkaApp({super.key, required this.store, required this.syncer, required this.live, this.bean});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '小耳录音卡',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: Home(store: store, syncer: syncer, live: live, bean: bean, askOwnKey: true),
  );
}
