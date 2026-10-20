// 端到端（默认跳过，LIVE=1 才跑）：假卡 → Syncer 拉卡 → 真云端转写 → 真模型整理（走云端 /v1/llm 中转，和 App 默认一样）→ 资料文件夹。
//   LIVE=1 flutter test test/e2e_fake_card_test.dart
// 录音素材：test/fixtures/make_fake_recordings.py 生成（macOS say 合成 → 卡的裸 Opus），默认在 /tmp/luyinka-fake-card。
// 资料文件夹默认留在 /tmp/luyinka-e2e/资料（可以拿去装进模拟器看），摘要写在 /tmp/luyinka-e2e/summary.md。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

import 'fake_card.dart';

const cloudBase = String.fromEnvironment('LUYINKA_CLOUD', defaultValue: 'https://luyinka.xiaoeromia.com:8443');

/// 记下上传过的任务 id 和叫删过的，用来事后核对云端真删了。
class RecordingCloud extends Cloud {
  final uploaded = <String, String>{}; // 录音名 → 任务 id
  final deleted = <String>[];
  RecordingCloud(super.base);

  @override
  Future<String> upload(String name, Uint8List raw, String tz) async {
    final id = await super.upload(name, raw, tz);
    uploaded[name] = id;
    return id;
  }

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    await super.delete(id);
  }
}

// 三段各自「合理」的类别
const expected = {
  'note20261019-093000': {'开会'},
  'note20261019-123000': {'个人感悟', '自言自语'},
  'note20261019-160000': {'打电话', '商务洽谈'},
};

void main() {
  final live = Platform.environment['LIVE'] == '1';
  final src = Directory(Platform.environment['FAKE_CARD_DIR'] ?? '/tmp/luyinka-fake-card');
  final out = Directory(Platform.environment['E2E_DIR'] ?? '/tmp/luyinka-e2e');

  test('假卡 → 真云端 → 真模型 → 资料文件夹', () async {
    if (!src.existsSync() || src.listSync().whereType<File>().where((f) => f.path.endsWith('.opus')).length < 3) {
      final r = await Process.run('python3', ['test/fixtures/make_fake_recordings.py', src.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    }
    if (out.existsSync()) out.deleteSync(recursive: true);
    final store = Store(Directory('${out.path}/app'))..lib = Library(Directory('${out.path}/资料'));
    await Directory('${out.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
    store.settings['deleteAfter'] = true;

    final card = FakeCard({
      for (final stem in expected.keys) FakeCard.deviceName(stem): File('${src.path}/$stem.opus').readAsBytesSync(),
    });
    final cloud = RecordingCloud(cloudBase);
    final syncer = Syncer(store, cloud, card.connect, card.scan, () => 'Asia/Shanghai');

    final t0 = DateTime.now();
    while (true) {
      await syncer.run();
      final st = {for (final r in store.recs.values) r.stem: '${r.stage}${r.stage == 'processing' ? ' ${r.progress}%' : ''}${r.error == null ? '' : ' (${r.error})'}'};
      // ignore: avoid_print
      print('${DateTime.now().difference(t0).inSeconds}s ${syncer.card.error ?? ''} $st');
      if (store.recs.length == 3 && store.recs.values.every((r) => r.stage == 'done')) break;
      if (store.recs.values.any((r) => r.stage == 'error')) fail('云端转写出错：$st');
      if (DateTime.now().difference(t0) > const Duration(minutes: 20)) fail('20 分钟还没整理完：$st');
      await Future.delayed(const Duration(seconds: 10));
    }
    await syncer.run(); // 整理完的下一轮才删卡上文件（同步后删卡上录音）
    await store.save();

    final summary = StringBuffer('# 假卡端到端 · ${DateTime.now()} · 用时 ${DateTime.now().difference(t0).inSeconds} 秒\n\n');
    for (final stem in expected.keys) {
      final scenes = store.scenes.where((s) => s.stem == stem).toList()..sort((a, b) => a.start.compareTo(b.start));
      final res = store.readResult(stem)!;
      final all = [for (final l in res['lines'] as List) (l as List)[1]].join();
      summary
        ..writeln('## $stem（${(res['seconds'] ?? '?')} 秒，开录 ${res['start']}）\n')
        ..writeln('转写前 100 字：${all.length > 100 ? all.substring(0, 100) : all}\n')
        ..writeln('分出来的段：');
      for (final s in scenes) {
        summary.writeln('- [${s.category}] ${s.title} · ${s.event}${s.people.isEmpty ? '' : ' · 人物：${s.people.join('、')}'}');
      }
      summary.writeln();

      expect(all.length, greaterThan(100), reason: '$stem 转写太少');
      expect(scenes, isNotEmpty, reason: '$stem 没分出段');
      expect(scenes.last.end.difference(scenes.first.start).inSeconds, greaterThan((res['seconds'] as num) - 5),
          reason: '$stem 的段应该一直算到录音结束');
      expect(scenes.any((s) => expected[stem]!.contains(s.category)), isTrue,
          reason: '$stem 分成了 ${scenes.map((s) => s.category).toList()}，期望 ${expected[stem]}');
      for (final s in scenes) {
        expect(File(s.d['file'] as String).existsSync(), isTrue, reason: '${s.title} 笔记文件');
      }
      expect(store.lib.transcript(stem).readAsStringSync(), contains('**['));
      final m4a = store.audio(stem);
      expect(m4a.lengthSync(), greaterThan(10000), reason: '$stem 录音 m4a');
      expect(String.fromCharCodes(m4a.readAsBytesSync().sublist(4, 8)), 'ftyp');
      expect(store.raw(stem).existsSync(), isFalse, reason: '传完的原文件应该删掉');
    }
    expect(File('${store.lib.path}/每日/2026-10-19.md').readAsStringSync(), contains('[开会]'));

    // 云端：三条都叫删了，再查也确实没了
    expect(cloud.uploaded, hasLength(3));
    expect(cloud.deleted.toSet(), cloud.uploaded.values.toSet());
    for (final id in cloud.uploaded.values) {
      await expectLater(cloud.job(id), throwsA(isA<CloudError>().having((e) => e.status, 'status', 404)));
    }
    // 卡上：设置了同步后删，三份都删了
    expect(card.files, isEmpty);
    expect(card.deleted, hasLength(3));
    expect(store.recs.values.every((r) => r.deletedOnCard), isTrue);

    final note = store.scenes.firstWhere((s) => s.category == '开会');
    summary
      ..writeln('## 一篇笔记全文：${note.d['file']}\n')
      ..writeln('```markdown\n${File(note.d['file'] as String).readAsStringSync()}\n```');
    File('${out.path}/summary.md').writeAsStringSync(summary.toString());
    // ignore: avoid_print
    print(summary);
  }, skip: live ? false : '要连真云端：LIVE=1 才跑', timeout: const Timeout(Duration(minutes: 25)));
}
