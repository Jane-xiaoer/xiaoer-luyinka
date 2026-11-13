// 拉卡时「暂停」/「这条先不收」（Jane 11-13：「上传过程中增加一个暂停或者终止的按钮…录音的内容还是回到卡里，不要删除」）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

import 'fake_card.dart';

void main() {
  late Directory tmp;
  late Store store;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pauseskip');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
  });
  tearDown(() async {
    await store.save();
    await tmp.delete(recursive: true);
  });

  final data = List.generate(60000, (i) => i % 251);
  const stem = 'note20261113-093000';

  test('拉到一半点暂停：停下、拉了的留着；暂停着不拉；接着收从断的地方续，拉完一字不差', () async {
    final card = FakeCard({'$stem.': data})..bytesPerSec = 200000;
    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), card.connect, card.scan, () => 'Asia/Shanghai');
    final run = syncer.run();
    while ((store.recs[stem]?.got ?? 0) < 10000) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
    syncer.pause();
    await run;
    final part = store.raw(stem, part: true);
    expect(store.recs[stem]!.stage, 'pulling');
    final had = part.lengthSync();
    expect(had, inExclusiveRange(10000, data.length));
    expect(store.settings['paused'], isTrue);

    await syncer.run(); // 暂停着：不动
    expect(card.requests, hasLength(1));

    await syncer.resume();
    expect(store.recs[stem]!.stage, 'pulled');
    expect(store.raw(stem).readAsBytesSync(), data);
    expect(card.requests.last.$2, had); // 从断的地方续
    expect(card.files, hasLength(1)); // 卡上的没动
  });

  test('这条先不收：本机的清掉、卡上的不删（开了「整理完删卡上的」也不删）、以后不再拉；重新收能再收', () async {
    store.settings['deleteAfter'] = true;
    final card = FakeCard({'$stem.': data})..bytesPerSec = 200000;
    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), card.connect, card.scan, () => 'Asia/Shanghai');
    final run = syncer.run();
    while ((store.recs[stem]?.got ?? 0) < 10000) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
    await syncer.skip(store.recs[stem]!);
    await run;
    expect(store.recs[stem]!.stage, 'skipped');
    expect(store.raw(stem, part: true).existsSync(), isFalse);
    expect(store.raw(stem).existsSync(), isFalse);
    expect(store.pending, isEmpty); // 不在「处理中」里
    expect(card.files.keys, ['$stem.']);
    expect(card.deleted, isEmpty);

    final asked = card.requests.length;
    await syncer.run(); // 下一轮：不再拉这条
    expect(card.requests, hasLength(asked));
    expect(store.recs[stem]!.stage, 'skipped');

    card.bytesPerSec = null;
    await syncer.unskip(store.recs[stem]!);
    expect(store.recs[stem]!.stage, 'pulled');
    expect(store.raw(stem).readAsBytesSync(), data);
    expect(card.requests.last.$2, 0); // 从头收
  });

  test('已经转写出来（还没整理）点先不收：逐字稿、录音、索引都清掉，卡上的还在', () async {
    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai');
    await store.lib.writeTranscript(stem, '2026-11-13T09:30:00', [['09:30:00', '你好']]);
    await store.putResult(stem, {'start': '2026-11-13T09:30:00', 'lines': [['09:30:00', '你好']], 'scenes': []});
    await store.audio(stem).create(recursive: true);
    store.recs[stem] = Rec(stem, 100, 'transcribed');
    await syncer.skip(store.recs[stem]!);
    expect(store.recs[stem]!.stage, 'skipped');
    expect(store.result(stem).existsSync(), isFalse);
    expect(store.lib.transcript(stem).existsSync(), isFalse);
    expect(store.audio(stem).existsSync(), isFalse);
    expect(store.recs[stem]!.deletedOnCard, isFalse);
  });
}
