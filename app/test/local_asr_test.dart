// 录音本机转写：结果跟云端一样（钟点、按句并行、开录时刻带时区）；卡上的裸 Opus 包成 Ogg 系统能解；
// Syncer 先用本机，出错再传云端，本机转的时候不往云端传。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/live.dart' show LiveModels;
import 'package:luyinka/local_asr.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

/// 假的本机转写：不跑模型，直接给结果；[fail] 时抛错（看会不会改传云端）。
class FakeLocal extends LocalAsr {
  final bool fail;
  int calls = 0;
  FakeLocal(Directory d, {this.fail = false}) : super(LiveModels(d));
  @override
  bool get ready => true;
  @override
  Future<Map<String, dynamic>> transcribe(File raw, String stem, File m4a,
      {void Function(int percent)? progress, String Function(String)? fix}) async {
    calls++;
    if (fail) throw Exception('模型坏了');
    await m4a.parent.create(recursive: true);
    await m4a.writeAsBytes([1, 2, 3]);
    return {
      'recording': stem,
      'start': '2026-10-26T10:00:00+08:00',
      'seconds': 30.0,
      'lines': [
        ['10:00:00', fix == null ? '你好' : fix('你好')],
      ],
      'scenes': [],
    };
  }
}

class CountingCloud extends Cloud {
  int uploads = 0;
  CountingCloud() : super('http://127.0.0.1:9', token: 't');
  @override
  Future<String> upload(String name, Uint8List raw, String tz) async {
    uploads++;
    throw CloudError('云端没开（测试）');
  }
}

void main() {
  test('相邻句子并成一行：隔 2 秒以上 / 超 30 秒 / 超 120 字就另起', () {
    final m = mergeLines([
      (0.0, 3.0, '第一句。'),
      (3.5, 6.0, '第二句。'),
      (9.0, 10.0, '隔了三秒。'),
      (10.5, 41.0, '很长'),
    ]);
    expect(m, [(0.0, '第一句。第二句。'), (9.0, '隔了三秒。'), (10.5, '很长')]);
  });

  test('开录时刻：卡上的名字、豆子的名字；带时区', () {
    expect(startOf('2026-10-18 07.40.00'), DateTime(2026, 10, 18, 7, 40));
    expect(startOf('bean20261024110629'), DateTime(2026, 10, 24, 11, 6, 29));
    expect(startOf('live20261024-051943'), isNull);
    expect(isoWithOffset(DateTime(2026, 10, 24, 11, 6, 29)), startsWith('2026-10-24T11:06:29'));
    expect(isoWithOffset(DateTime(2026, 10, 24, 11, 6, 29)), matches(RegExp(r'[+-]\d\d:\d\d$')));
  });

  test('卡上的裸 Opus（30 秒）包成 Ogg：系统 afconvert 解得出、时长对', () async {
    final raw = File('test/fixtures/card_30s.raw').readAsBytesSync();
    expect(tocSamples48k(Uint8List.fromList([0x78, 0])), 960); // CELT 20ms
    final tmp = await Directory.systemTemp.createTemp('cardogg');
    final ogg = File('${tmp.path}/a.ogg')..writeAsBytesSync(cardOgg(raw));
    final r = await Process.run('/usr/bin/afinfo', [ogg.path]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final secs = double.parse(RegExp(r'estimated duration: ([\d.]+)').firstMatch('${r.stdout}')![1]!);
    expect(secs, closeTo(raw.length / 40 * 0.02, 0.1));
    await tmp.delete(recursive: true);
  }, skip: !Platform.isMacOS);

  group('Syncer：先本机、出错再传云端', () {
    late Directory tmp;
    late Store store;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('localsync');
      await Directory('${tmp.path}/app/raw').create(recursive: true);
      store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
      await store.lib.ensure();
      store.recs['2026-10-26 10.00.00'] = Rec('2026-10-26 10.00.00', 60, 'pulled');
      await store.raw('2026-10-26 10.00.00').writeAsBytes(Uint8List(60));
    });
    tearDown(() async {
      await store.save();
      await tmp.delete(recursive: true);
    });

    test('本机转好：存逐字稿、原声，删原文件，排进待整理；没往云端传', () async {
      final local = FakeLocal(tmp);
      final cloud = CountingCloud();
      final s = Syncer(store, cloud, (_) async => null, () async => [], () => 'Asia/Shanghai', local: local);
      await s.run(fromCard: false);
      final r = store.recs['2026-10-26 10.00.00']!;
      expect(local.calls, 1);
      expect(cloud.uploads, 0);
      expect(r.stage, anyOf('transcribed', 'analyzing', 'done')); // 整理那步没有模型会退回待整理
      expect(store.lib.transcript(r.stem).readAsStringSync(), contains('你好'));
      expect(store.audio(r.stem).existsSync(), isTrue);
      expect(store.raw(r.stem).existsSync(), isFalse);
      expect(store.readResult(r.stem)!['lines'], [
        ['10:00:00', '你好'],
      ]);
    });

    test('本机出错：改传云端（云端也没开就留着「已拉」，下轮再试），原文件还在', () async {
      final local = FakeLocal(tmp, fail: true);
      final cloud = CountingCloud();
      final s = Syncer(store, cloud, (_) async => null, () async => [], () => 'Asia/Shanghai', local: local);
      await s.run(fromCard: false);
      final r = store.recs['2026-10-26 10.00.00']!;
      expect(local.calls, 1);
      expect(cloud.uploads, 1);
      expect(r.stage, 'pulled');
      expect(r.error, contains('上传没成功'));
      expect(store.raw(r.stem).existsSync(), isTrue);
    });
  });
}
