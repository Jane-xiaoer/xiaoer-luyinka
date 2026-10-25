// 录音豆页面：没连上也能看到豆子里有什么、每条走到哪一步。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/bean/protocol.dart';
import 'package:luyinka/bean/sync.dart';
import 'package:luyinka/bean/view.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';

void main() {
  testWidgets('每条录音的状态：正在录 / 空录音 / 还没拉 / 拉到本机 % / 云端转写 % / 整理好', (
    tester,
  ) async {
    final tmp = Directory.systemTemp.createTempSync('beanview');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = Store(Directory('${tmp.path}/app'))
      ..lib = Library(Directory('${tmp.path}/资料'));
    final ids = [
      1776000000,
      1776100000,
      1776200000,
      1776300000,
      1776400000,
      1792849165,
    ];
    store.settings['beanMac'] = '7ce9131d41c9';
    store.settings['beanFiles'] = [
      [ids[0], 1000], // 空录音
      [ids[1], 160 * 30000], // 还没拉
      [ids[2], 160 * 30000], // 拉到一半
      [ids[3], 160 * 30000], // 云端转写
      [ids[4], 160 * 30000], // 整理好（没有可看的段）
      [ids[5], recordingSize], // 正在录
    ];
    store.recs[BeanFile(ids[2], 0).stem] = Rec(
      BeanFile(ids[2], 0).stem,
      160 * 30000,
      'pulling',
    )..got = 160 * 15000;
    store.recs[BeanFile(ids[3], 0).stem] = Rec(
      BeanFile(ids[3], 0).stem,
      160 * 30000,
      'processing',
    )..progress = 42;
    store.recs[BeanFile(ids[4], 0).stem] = Rec(
      BeanFile(ids[4], 0).stem,
      160 * 30000,
      'done',
    );
    final bean = BeanSyncer(
      store,
      () async {},
      find: (_) async => null,
      scan: () async => [],
    );
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BeanView(bean: bean, store: store, onOpen: (_) {}),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('等着连…'), findsWidgets);
    expect(find.text('空录音，不拉'), findsNothing); // 空录音不显示
    expect(find.text('只在豆子里'), findsOneWidget);
    expect(find.textContaining('拉取中 50%'), findsOneWidget);
    expect(find.text('云端转写 42%'), findsOneWidget);
    expect(
      find.textContaining('原稿或转写不全，先别删'),
      findsOneWidget,
    ); // done 但没有原稿文件：不算已存好
    expect(find.text('录完再拉'), findsOneWidget);
    expect(find.text('拉下来看看'), findsOneWidget); // 只有「只在豆子里」那条有这个按钮
    expect(find.textContaining('已存好 0 · 处理中 3 · 只在豆子里 1'), findsOneWidget);
    expect(find.text('设备上的录音'), findsOneWidget);
    bean.dispose();
  });
}
