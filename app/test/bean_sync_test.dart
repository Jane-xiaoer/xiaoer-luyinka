// 录音豆：选了才拉（或开自动拉）；拉下来包成 Ogg、标「已拉」交给 Syncer；正在录的 / 空的 / 拉过的跳过；
// 断了下次接着拉；只有录音卡里原稿和转写都存好的才能从豆子上删；不在旁边 / 暂停了什么都不做。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/bean/client.dart';
import 'package:luyinka/bean/protocol.dart';
import 'package:luyinka/bean/sync.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';

/// 假录音豆：拉的时候按块写（每块 160 字节，内容是块号）；[cutAfter] 块后「断开」。
class FakeBean implements BeanConn {
  final List<BeanFile> list;
  int? cutAfter;
  final pulled = <int>[], deleted = <int>[];
  bool? recordingOn;
  FakeBean(this.list, {this.cutAfter});

  @override
  Future<BeanInfo?> info() async =>
      BeanInfo('04.82', 'sn', 100, 80, false, 7550976, 7499674);
  @override
  Future<List<BeanFile>> files() async => [
    for (final f in list)
      if (!deleted.contains(f.id)) f,
  ];
  @override
  Future<int> pull(
    BeanFile f,
    File part, {
    void Function(int frames, int totalFrames)? progress,
  }) async {
    pulled.add(f.id);
    final have = await part.exists() ? await part.length() ~/ frameBytes : 0;
    final total = f.frames;
    final end = cutAfter == null ? total : (have + cutAfter!).clamp(0, total);
    final sink = part.openWrite(mode: FileMode.append);
    for (var i = have; i < end; i++) {
      sink.add(Uint8List(frameBytes)..fillRange(0, frameBytes, i & 0xFF));
      progress?.call(i + 1, total);
    }
    await sink.close();
    return end - have;
  }

  @override
  Future<bool?> delete(int id) async {
    deleted.add(id);
    return true;
  }

  @override
  Future<bool?> setRecording(bool on) async {
    recordingOn = on;
    return true;
  }

  @override
  Future<void> close() async {}
}

Future<void> idle(BeanSyncer s) async {
  await Future.delayed(const Duration(milliseconds: 30));
  while (s.busy) {
    await Future.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory tmp;
  late Store store;
  var after = 0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bean');
    store = Store(Directory('${tmp.path}/app'))
      ..lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
    store.settings['beanMac'] = '7ce9131d41c9';
    after = 0;
  });
  tearDown(() async {
    await store.save();
    await tmp.delete(recursive: true);
  });

  BeanSyncer syncer(FakeBean b, {bool here = true}) => BeanSyncer(
    store,
    () async => after++,
    find: (_) async => here ? b : null,
    scan: () async => [],
  );

  test('连上只读状态和列表，不自动拉；点「拉到录音卡」才拉那一条', () async {
    final a = BeanFile(1776234093, 160 * 300),
        b = BeanFile(1776234500, 160 * 300);
    final bean = FakeBean([
      a,
      b,
      BeanFile(1776498911, 1100),
      BeanFile(1792849165, recordingSize),
    ]);
    final s = syncer(bean);
    await s.run();
    expect(bean.pulled, isEmpty);
    expect(s.files.length, 4);
    expect(s.info?.battery, 100);

    s.pull(b);
    await idle(s);
    expect(bean.pulled, [b.id]);
    final r = store.recs[b.stem]!;
    expect(r.stage, 'pulled');
    expect(r.noStream, isTrue); // Ogg 不分段，拉完一次传
    expect(
      String.fromCharCodes(
        (await store.raw(b.stem).readAsBytes()).sublist(0, 4),
      ),
      'OggS',
    );
    expect(s.queue, isEmpty);
    expect(after, 1);
    s.dispose();
  });

  test('全部同步：能拉的都拉（正在录的、空的不拉）；开了自动拉也一样', () async {
    final a = BeanFile(1776234093, 160 * 30),
        b = BeanFile(1776234500, 160 * 30);
    final bean = FakeBean([
      a,
      b,
      BeanFile(1776498911, 1100),
      BeanFile(1792849165, recordingSize),
    ]);
    final s = syncer(bean);
    await s.run(); // 先读到列表
    s.pullAll();
    await idle(s);
    expect(bean.pulled, [a.id, b.id]);

    final c = BeanFile(1776234900, 160 * 30);
    bean.list.add(c);
    s.setAuto(true);
    await idle(s);
    expect(bean.pulled, [a.id, b.id, c.id]);
    s.dispose();
  });

  test('断了：留着「拉取中」，下一轮从断的地方接着拉，拉全了才交出去', () async {
    final f = BeanFile(1776234093, 20 * 100);
    final bean = FakeBean([f], cutAfter: 40);
    final s = syncer(bean);
    s.setAuto(true);
    await idle(s);
    expect(store.recs[f.stem]!.stage, 'pulling');
    expect(store.recs[f.stem]!.got, 40 * frameBytes);
    expect(after, 0);
    await s.run(); // 80
    await s.run(); // 100
    expect(store.recs[f.stem]!.stage, 'pulled');
    expect(after, 1);
    // 三轮接起来正好 100 块：Ogg 最后一页的 granule = 100 × 960
    final ogg = await store.raw(f.stem).readAsBytes();
    var last = -1;
    for (var i = 0; i + 4 <= ogg.length; i++) {
      if (ogg[i] == 0x4F &&
          ogg[i + 1] == 0x67 &&
          ogg[i + 2] == 0x67 &&
          ogg[i + 3] == 0x53)
        last = i;
    }
    expect(
      ByteData.sublistView(ogg, last + 6, last + 14).getInt64(0, Endian.little),
      100 * 960,
    );
    s.dispose();
  });

  test('安全删除：只删录音卡里原稿和转写都存好、也整理完的；删前再核对', () async {
    final saved = BeanFile(1776234093, 160 * 30),
        notYet = BeanFile(1776234500, 160 * 30),
        half = BeanFile(1776234900, 160 * 30);
    final bean = FakeBean([saved, notYet, half]);
    final s = syncer(bean);
    await s.run();
    // saved：整理完 + 原稿 + 转写都在
    store.recs[saved.stem] = Rec(saved.stem, saved.frames * frameBytes, 'done');
    await store.audio(saved.stem).create(recursive: true);
    await store.lib.transcript(saved.stem).create(recursive: true);
    // half：整理完了，但原稿不在
    store.recs[half.stem] = Rec(half.stem, half.frames * frameBytes, 'done');
    await store.lib.transcript(half.stem).create(recursive: true);

    expect(s.savedSafely(saved), isTrue);
    expect(s.savedSafely(notYet), isFalse);
    expect(s.savedSafely(half), isFalse);

    final n = await s.delete([saved, notYet, half]);
    expect(n, 1);
    expect(bean.deleted, [saved.id]);
    expect(s.files.map((f) => f.id), [notYet.id, half.id]);
    expect(store.audio(saved.stem).existsSync(), isTrue); // 录音卡里的不动
    s.dispose();
  });

  test('待你决定：能看文字；导入录音卡就交去整理；不要了就从豆子上删、本机也不留', () async {
    final keep = BeanFile(1776234093, 20 * 300),
        drop = BeanFile(1776234500, 20 * 300);
    final bean = FakeBean([keep, drop]);
    final s = syncer(bean);
    await s.run();
    for (final f in [keep, drop]) {
      store.recs[f.stem] = Rec(f.stem, f.frames * frameBytes, 'review');
      await store.putResult(f.stem, {
        'start': '2026-10-24T11:06:29',
        'lines': [
          ['11:06:29', '你好'],
        ],
        'scenes': [],
      });
      await store.lib.transcript(f.stem).create(recursive: true);
    }
    expect(s.reviewing(keep), isTrue);
    expect(s.lines(keep), [
      ['11:06:29', '你好'],
    ]);
    expect(await s.delete([keep, drop]), 0); // 还没导入：「清理已存好的」不碰

    await s.moveIn(keep);
    expect(store.recs[keep.stem]!.stage, 'transcribed');
    expect(after, 1);

    expect(await s.discard(drop), isTrue);
    expect(bean.deleted, [drop.id]);
    expect(store.recs.containsKey(drop.stem), isFalse);
    expect(store.lib.transcript(drop.stem).existsSync(), isFalse);
    expect(store.result(drop.stem).existsSync(), isFalse);
    expect(s.files.map((f) => f.id), [keep.id]);
    expect(await s.discard(keep), isFalse); // 已经导入的不能「不要了」
    s.dispose();
  });

  test('遥控录音：开始 / 停止', () async {
    final bean = FakeBean([]);
    final s = syncer(bean);
    expect(await s.setRecording(true), isTrue);
    expect(bean.recordingOn, isTrue);
    expect(await s.setRecording(false), isTrue);
    expect(bean.recordingOn, isFalse);
    s.dispose();
  });

  test('不在旁边 / 暂停了：什么都不做', () async {
    final f = BeanFile(1776234093, 160 * 30);
    final bean = FakeBean([f]);
    final away = syncer(bean, here: false)..setAuto(true);
    await idle(away);
    expect(bean.pulled, isEmpty);
    away.dispose();
    final paused = syncer(bean)..setOff(true);
    await paused.run();
    expect(await paused.delete([f]), 0);
    expect(bean.pulled, isEmpty);
    paused.dispose();
  });
}
