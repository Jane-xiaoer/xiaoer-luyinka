// 边拉边传：按帧边界切段、蓝牙断了 / App 重启后接着传不重传、老云端照常一次性上传、进度说人话。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/home.dart' show pullLine;
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

import 'fake_card.dart';

const stem = 'note20261023-194438';
const part = frameBytes * 100; // 测试用小段：100 帧 = 4000 字节

/// 假云端：记下每次传段（第几段、那时这条录音在哪一步）、一次性上传和收尾。
class FakeCloud extends Cloud {
  final bool streams;
  final Store store;
  final parts = <String, List<Uint8List>>{};
  final puts = <(int, String)>[]; // (段号, 传的时候 App 里这条的 stage)
  final uploads = <String, Uint8List>{};
  final finished = <String, int>{};
  FakeCloud(this.store, {this.streams = true}) : super('http://fake', token: 't');

  @override
  Future<String> register() async => token = 't';
  @override
  Future<bool> canStream() async => streams;
  @override
  Future<String> openStream(String name, String tz) async {
    final id = 's${parts.length}';
    parts[id] = [];
    return id;
  }

  @override
  Future<int> putPart(String id, int seq, Uint8List bytes) async {
    final l = parts[id];
    if (l == null) throw CloudError('没有这条', 404);
    puts.add((seq, store.recs[stem]!.stage));
    if (seq == l.length) l.add(bytes);
    return l.length; // 已有的不重收、跳号了告诉 App 实际有几段（跟 server/app.py 一样）
  }

  @override
  Future<void> finish(String id, int n) async {
    if (n != parts[id]!.length) throw CloudError('段数对不上', 409);
    finished[id] = n;
  }

  @override
  Future<String> upload(String name, Uint8List raw, String tz) async {
    uploads[name] = raw;
    return 'u1';
  }

  @override
  Future<Map<String, dynamic>> job(String id) async => {
        'status': 'done',
        'progress': 100,
        'result': {'recording': stem, 'start': '', 'seconds': 1, 'lines': [], 'scenes': []},
      };
  @override
  Future<Uint8List> audio(String id) async => Uint8List(0);
  @override
  Future<void> delete(String id) async {}
}

void main() {
  late Directory tmp;
  final stores = <Store>[];
  final data = Uint8List.fromList([for (var i = 0; i < part * 3 + frameBytes * 31; i++) (i * 7 + i ~/ 40) & 0xFF]);

  Future<Store> openStore() async {
    final s = Store(Directory('${tmp.path}/app'));
    stores.add(s);
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    if (File('${tmp.path}/app/state.json').existsSync()) {
      await s.load(); // App 重启：从 state.json 读回来
    } else {
      s
        ..lib = Library(Directory('${tmp.path}/资料'))
        ..settings['library'] = '${tmp.path}/资料'
        ..settings['device'] = 'FA:KE:CA:RD:00:01';
      await s.lib.ensure();
    }
    return s;
  }

  setUp(() async => tmp = await Directory.systemTemp.createTemp('stream'));
  tearDown(() async {
    for (final s in stores) {
      // 同步那边存盘是排队异步的，等它写完再删临时目录。
      // 「重启前」「重启后」两个 Store 同时开在一个文件夹上、各排各的队，会抢同一个 state.json.tmp
      // （真 App 只有一个 Store，不会这样）：这里抢输了的那次改名不算测试失败。
      await s.save().catchError((_) {}, test: (e) => e is PathNotFoundException);
    }
    stores.clear();
    await tmp.delete(recursive: true);
  });

  test('按帧边界切段：没拉完只传满的段，拉完连尾巴一起传', () {
    expect(defaultPartBytes % frameBytes, 0);
    expect(defaultPartBytes, 1500000);
    expect(partsToSend(9999, 0, part), [(0, 4000), (4000, 8000)]);
    expect(partsToSend(9999, 2, part), isEmpty);
    expect(partsToSend(9999, 2, part, last: true), [(8000, 9999)]);
    expect(partsToSend(8000, 2, part, last: true), isEmpty); // 正好整段：没有空尾巴
    expect(partsToSend(12000, 1, part), [(4000, 8000), (8000, 12000)]);
    for (final (s, e) in partsToSend(1234567, 0, defaultPartBytes, last: true)) {
      expect(s % frameBytes, 0);
      expect(e == 1234567 || e % frameBytes == 0, isTrue);
    }
  });

  test('蓝牙断两次 + App 重启：接着拉、接着传，每段只传一次，拼起来就是原文件', () async {
    var store = await openStore();
    final card = FakeCard({FakeCard.deviceName(stem): data})..dropAt = part * 2 + 1000;
    final cloud = FakeCloud(store);
    var syncer = Syncer(store, cloud, card.connect, card.scan, () => 'America/Los_Angeles', partBytes: part);

    await syncer.run(); // 第一轮：拉到 9000 字节断了
    expect(store.recs[stem]!.stage, 'pulling');
    expect(store.raw(stem, part: true).lengthSync(), part * 2 + 1000);

    card.dropAt = part * 3 + 400;
    await syncer.run(); // 第二轮：一连上先把已拉到的 2 整段传了（拉卡还在进行），拉到 12400 又断了
    expect(store.recs[stem]!.stage, 'pulling');
    expect(store.recs[stem]!.sent, 2);
    expect(cloud.puts, [(0, 'pulling'), (1, 'pulling')]);
    await store.save();

    // App 重启：新的 Store / Syncer 从 state.json 读回「已传 2 段」，不重传
    store = await openStore();
    cloud.store.recs
      ..clear()
      ..addAll(store.recs);
    syncer = Syncer(store, cloud, card.connect, card.scan, () => 'America/Los_Angeles', partBytes: part);
    expect(store.recs[stem]!.stream, 's0');
    expect(store.recs[stem]!.sent, 2);
    await syncer.run();

    expect([for (final p in cloud.puts) p.$1], [0, 1, 2, 3], reason: '每段只传一次');
    expect(cloud.puts[2].$2, 'pulling', reason: '第 3 段也是边拉边传的');
    expect(cloud.finished, {'s0': 4});
    expect(cloud.uploads, isEmpty, reason: '没走一次性上传');
    expect(cloud.parts['s0']!.expand((x) => x).toList(), data, reason: '各段拼起来 = 卡上原文件');
    expect(cloud.parts['s0']!.take(3).every((p) => p.length == part), isTrue);
    expect(card.requests.map((r) => r.$2).toList(), [0, part * 2 + 1000, part * 3 + 400], reason: '蓝牙从断的地方续拉');
    final r = store.recs[stem]!;
    expect(r.stage, 'done');
    expect(r.progress, 0, reason: '做完了进度清零');
    expect(r.stream, isNull);
    expect(store.raw(stem).existsSync(), isFalse);
  });

  test('老云端（不会边拉边传）：拉完一次性上传整个文件', () async {
    final store = await openStore();
    final card = FakeCard({FakeCard.deviceName(stem): data});
    final cloud = FakeCloud(store, streams: false);
    await Syncer(store, cloud, card.connect, card.scan, () => 'Asia/Shanghai', partBytes: part).run();
    expect(cloud.puts, isEmpty);
    expect(cloud.uploads['$stem.'], data);
    expect(store.recs[stem]!.stage, 'done');
  });

  test('短录音（不满一段）：一次性上传', () async {
    final store = await openStore();
    final short = data.sublist(0, part - frameBytes);
    final card = FakeCard({FakeCard.deviceName(stem): short});
    final cloud = FakeCloud(store);
    await Syncer(store, cloud, card.connect, card.scan, () => 'Asia/Shanghai', partBytes: part).run();
    expect(cloud.parts, isEmpty);
    expect(cloud.uploads['$stem.'], short);
  });

  test('云端那条没了（被清掉）：重开一条从头传', () async {
    final store = await openStore();
    final card = FakeCard({FakeCard.deviceName(stem): data})..dropAt = part * 2 + 1000;
    final cloud = FakeCloud(store);
    final syncer = Syncer(store, cloud, card.connect, card.scan, () => 'Asia/Shanghai', partBytes: part);
    await syncer.run();
    store.recs[stem]!
      ..stream = 'gone'
      ..sent = 1;
    await syncer.run(); // 传段 404 → 重开；下一轮拉完时从头传
    expect(cloud.finished.length, 1);
    final id = cloud.finished.keys.single;
    expect(cloud.parts[id]!.expand((x) => x).toList(), data);
  });

  test('拉卡进度：已拉 / 总大小 · 按实测速度估还剩几分钟', () {
    final r = Rec(stem, 13600000, 'pulling')
      ..got = 3200000
      ..bps = 7000;
    expect(pullLine(r), '从卡上拉 3.2 / 13.6MB · 约剩 25 分钟');
    r.sent = 2;
    expect(pullLine(r), '从卡上拉 3.2 / 13.6MB · 约剩 25 分钟 · 已传云端 2 段');
    r.bps = 0;
    expect(pullLine(r), '从卡上拉 3.2 / 13.6MB · 已传云端 2 段');
  });
}
