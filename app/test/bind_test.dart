// 认卡：第一次只有一张就自动认它；好几张让用户选；认准以后只连这一张。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

void main() {
  late Store store;
  late List<String> asked; // connect 被要求连哪张
  late List<CardChoice> nearby;
  late int scans;

  Syncer make() => Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (id) async {
        asked.add(id);
        return null;
      }, () async {
        scans++;
        return nearby;
      }, () => 'Asia/Shanghai');

  setUp(() async {
    store = Store(await Directory.systemTemp.createTemp('bind'));
    asked = [];
    scans = 0;
    nearby = [];
  });

  test('只有一张：自动认它', () async {
    nearby = [CardChoice('A', '录音卡 · AAAA', -50)];
    await make().run();
    expect(store.settings['device'], 'A');
    expect(store.settings['deviceName'], '录音卡 · AAAA');
    expect(asked, ['A']);
  });

  test('好几张：不自动挑，等用户选', () async {
    nearby = [CardChoice('A', 'a', -50), CardChoice('B', 'b', -70)];
    final s = make();
    await s.run();
    expect(store.settings['device'], isNull);
    expect(s.card.choices.length, 2);
    expect(asked, isEmpty);
    s.bind(nearby[1]);
    await Future.delayed(Duration.zero);
    expect(store.settings['device'], 'B');
    expect(s.card.choices, isEmpty);
  });

  test('认准以后：只连自己的，别人的卡在旁边也不碰', () async {
    store.settings['device'] = 'A';
    nearby = [CardChoice('B', 'b', -40)];
    await make().run();
    expect(scans, 0);
    expect(asked, ['A']);
    expect(store.settings['device'], 'A');
  });
}
