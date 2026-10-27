// 自动更新：版本号比大小、这台设备该下哪个包、提醒条有新版才出来、「以后再说」就收起。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/update.dart';

void main() {
  test('版本号按数字比，不按字面', () {
    expect(newer('1.2.10', '1.2.9'), isTrue);
    expect(newer('1.2.6', '1.2.5'), isTrue);
    expect(newer('1.3', '1.2.9'), isTrue);
    expect(newer('1.2.5', '1.2.5'), isFalse);
    expect(newer('1.2.4', '1.2.5'), isFalse);
    expect(newer('1.2.5.1', '1.2.5'), isTrue);
    expect(newer('', '1.2.5'), isFalse);
  });

  test('Mac 下 DMG；安卓 64 位下主流包，老手机下老手机包，没有老手机包就用主流包', () {
    final j = {
      'version': '1.2.6',
      'mac': {'url': '/download/a.dmg'},
      'android': {'url': '/download/a.apk'},
      'android_old': {'url': '/download/old.apk'},
    };
    expect(packageFor(j, mac: true)!['url'], '/download/a.dmg');
    expect(packageFor(j, mac: false)!['url'], '/download/a.apk');
    expect(packageFor(j, mac: false, arm64: false)!['url'], '/download/old.apk');
    expect(packageFor({'version': '1', 'android': {'url': 'x.apk'}}, mac: false, arm64: false)!['url'], 'x.apk');
    expect(packageFor({'version': '1', 'android': {'url': 'x.apk'}}, mac: true), isNull);
  });

  test('下载地址里的中文文件名能拿出来（M2 实测时这里抛过 Illegal percent encoding）', () {
    final url = Uri.parse('https://luyinka.xiaoeromia.com:8443')
        .resolve('/download/%E5%B0%8F%E8%80%B3%E5%BD%95%E9%9F%B3%E5%8D%A1-1.2.6.dmg');
    expect(fileNameOf(url), '小耳录音卡-1.2.6.dmg');
  });

  testWidgets('有新版才出提醒；点「以后再说」收起', (tester) async {
    final u = Updater.instance;
    u.latest = null;
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: UpdateBar())));
    expect(find.textContaining('有新版'), findsNothing);
    u.latest = {'version': '1.2.6', 'notes': '长会不卡了\n第二行'};
    u.later = false;
    u.notifyListeners();
    await tester.pump();
    expect(find.text('有新版 1.2.6'), findsOneWidget);
    expect(find.text('长会不卡了'), findsOneWidget);
    expect(find.text('现在更新'), findsOneWidget);
    await tester.tap(find.text('以后再说'));
    await tester.pump();
    expect(find.textContaining('有新版'), findsNothing);
  });
}
