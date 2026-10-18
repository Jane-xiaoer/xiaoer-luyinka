import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'card/ble.dart';
import 'cloud.dart';
import 'home.dart';
import 'store.dart';
import 'sync.dart';
import 'theme.dart';

/// 云端地址：编译时 --dart-define=LUYINKA_CLOUD=… 可改，设置里也能改。
const defaultCloud = String.fromEnvironment('LUYINKA_CLOUD', defaultValue: 'https://luyinka.blitzer.studio:8443');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/luyinka');
  await dir.create(recursive: true);
  final store = Store(dir);
  await store.load();
  final cloud = Cloud((store.settings['cloud'] as String?) ?? defaultCloud, token: store.settings['token'] as String?);
  final syncer = Syncer(store, cloud, () async {
    final link = await BleLink.find(preferId: store.settings['device'] as String?);
    if (link != null) store.settings['device'] = link.id;
    return link;
  }, deviceTimezone);
  runApp(LuyinkaApp(store: store, syncer: syncer));
  syncer.start();
}

/// 设备时区的 IANA 名：Flutter 只给得出 UTC 偏移，按偏移挑常用的（国内 +8 = 上海）。
String deviceTimezone() {
  const known = {480: 'Asia/Shanghai', 540: 'Asia/Tokyo', 420: 'Asia/Bangkok', 0: 'UTC',
      -420: 'America/Los_Angeles', -480: 'America/Los_Angeles', -300: 'America/New_York', -240: 'America/New_York',
      60: 'Europe/Berlin', 120: 'Europe/Berlin'};
  return known[DateTime.now().timeZoneOffset.inMinutes] ?? 'Asia/Shanghai';
}

class LuyinkaApp extends StatelessWidget {
  final Store store;
  final Syncer syncer;
  const LuyinkaApp({super.key, required this.store, required this.syncer});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '小耳录音卡',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: Home(store: store, syncer: syncer),
      );
}
