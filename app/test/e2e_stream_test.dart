// 端到端（默认跳过，STREAM_E2E=1 才跑）：限速假卡（约 7KB/s，跟真卡蓝牙差不多）→ Syncer 边拉边传 → 云端（本地起的一份或真云端）分段转写 → 接起来。
// 再把同一个文件用老接口一次性上传一遍，比两份逐字稿。
//   STREAM_E2E=1 LUYINKA_CLOUD=http://127.0.0.1:8790 STREAM_E2E_RAW=/tmp/luyinka-stream-e2e/note20261023-194438.opus \
//     flutter test test/e2e_stream_test.dart
// 时间线和比对结果写在 /tmp/luyinka-stream-e2e/summary.md。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

import 'fake_card.dart';

final env = Platform.environment;
final t0 = DateTime.now();
final timeline = <String>[];
void note(String s) {
  final line = '${(DateTime.now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1)}s  $s';
  timeline.add(line);
  // ignore: avoid_print
  print(line);
}

class LoggingCloud extends Cloud {
  final Rec Function() rec;
  LoggingCloud(super.base, this.rec);

  @override
  Future<String> openStream(String name, String tz) async {
    final id = await super.openStream(name, tz);
    note('开了一条边拉边传 $id（已拉 ${rec().got} 字节）');
    return id;
  }

  @override
  Future<int> putPart(String id, int seq, Uint8List bytes) async {
    note('传第 $seq 段 ${bytes.length} 字节（App 里这条：${rec().stage}，已拉 ${rec().got}/${rec().size}）');
    return super.putPart(id, seq, bytes);
  }

  @override
  Future<void> finish(String id, int parts) async {
    note('finish $parts 段');
    return super.finish(id, parts);
  }
}

int secsOf(String clock) {
  final p = clock.split(':').map(int.parse).toList();
  return p[0] * 3600 + p[1] * 60 + p[2];
}

/// 最长公共子序列占比（逐字比两份逐字稿有多接近）。
double similarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  var prev = Int32List(b.length + 1), cur = Int32List(b.length + 1);
  for (var i = 1; i <= a.length; i++) {
    final ca = a.codeUnitAt(i - 1);
    for (var j = 1; j <= b.length; j++) {
      cur[j] = ca == b.codeUnitAt(j - 1) ? prev[j - 1] + 1 : (prev[j] > cur[j - 1] ? prev[j] : cur[j - 1]);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return 2 * prev[b.length] / (a.length + b.length);
}

void main() {
  final live = env['STREAM_E2E'] == '1';
  final base = env['LUYINKA_CLOUD'] ?? 'http://127.0.0.1:8790';
  final rawPath = env['STREAM_E2E_RAW'] ?? '/tmp/luyinka-stream-e2e/note20261023-194438.opus';
  final out = Directory(env['STREAM_E2E_DIR'] ?? '/tmp/luyinka-stream-e2e/run');

  test('限速假卡 → 边拉边传 → 云端分段转写 → 跟一次性上传比', () async {
    final stem = rawPath.split('/').last.replaceAll('.opus', '');
    final data = File(rawPath).readAsBytesSync();
    if (out.existsSync()) out.deleteSync(recursive: true);
    final store = Store(Directory('${out.path}/app'))..lib = Library(Directory('${out.path}/资料'));
    await Directory('${out.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
    final card = FakeCard({FakeCard.deviceName(stem): data})..bytesPerSec = int.parse(env['STREAM_E2E_BPS'] ?? '7000');
    store.settings['device'] = card.id;
    final cloud = LoggingCloud(base, () => store.recs[stem]!);
    final syncer = Syncer(store, cloud, card.connect, card.scan, () => 'America/Los_Angeles',
        chat: (s, u) async => throw StateError('端到端只测转写，不整理'));

    note('开始：${data.length} 字节 ≈ ${(data.length / 2000 / 60).toStringAsFixed(1)} 分钟录音，卡限速 ${card.bytesPerSec} B/s，每段 $defaultPartBytes 字节');
    var pulledAt = -1.0;
    var progressWhilePulling = 0;
    final watch = Timer.periodic(const Duration(seconds: 15), (_) async {
      final r = store.recs[stem];
      if (r == null || r.stage != 'pulling' || r.stream == null) return;
      try {
        final j = await cloud.job(r.stream!);
        note('拉卡中查云端：${j['status']} 已收 ${j['parts']} 段 · 转写进度 ${j['progress']}%');
        if (store.recs[stem]!.stage == 'pulling' && (j['progress'] as num) > progressWhilePulling) {
          progressWhilePulling = (j['progress'] as num).toInt();
        }
      } catch (e) {
        note('查云端出错 $e');
      }
    });
    syncer.onChange = () {
      final r = store.recs[stem];
      if (r != null && r.stage != 'pulling' && pulledAt < 0 && r.got >= r.size && r.size > 0) {
        pulledAt = DateTime.now().difference(t0).inMilliseconds / 1000;
        note('从卡上拉完了（stage=${r.stage}）');
      }
    };
    while (true) {
      await syncer.run();
      final r = store.recs[stem]!;
      note('一轮结束：${r.stage} ${r.progress}%${r.error == null ? '' : ' (${r.error})'}');
      if (r.stage == 'transcribed' || r.stage == 'done') break;
      if (r.stage == 'error') fail('云端出错：${r.error}');
      if (DateTime.now().difference(t0) > const Duration(minutes: 40)) fail('40 分钟还没完');
      await Future.delayed(const Duration(seconds: 5));
    }
    watch.cancel();
    final doneAt = DateTime.now().difference(t0).inMilliseconds / 1000;
    final res = store.readResult(stem)!;
    final lines = [for (final l in res['lines'] as List) List<String>.from(l)];

    note('老接口一次性上传同一个文件做对照');
    final oneId = await cloud.upload('$stem.', data, 'America/Los_Angeles');
    Map<String, dynamic> one;
    while (true) {
      final j = await cloud.job(oneId);
      if (j['status'] == 'done') {
        one = Map<String, dynamic>.from(j['result']);
        break;
      }
      if (j['status'] == 'error') fail('一次性上传出错：${j['error']}');
      await Future.delayed(const Duration(seconds: 5));
    }
    final oneAt = DateTime.now().difference(t0).inMilliseconds / 1000;
    await cloud.delete(oneId);
    final oneLines = [for (final l in one['lines'] as List) List<String>.from(l)];

    final secs = [for (final l in lines) secsOf(l[0])];
    var back = 0;
    for (var i = 1; i < secs.length; i++) {
      if (secs[i] < secs[i - 1]) back++;
    }
    final a = lines.map((l) => l[1]).join(), b = oneLines.map((l) => l[1]).join();
    final sim = similarity(a, b);
    final firstPut = timeline.firstWhere((l) => l.contains('传第 0 段'));
    final summary = StringBuffer()
      ..writeln('# 边拉边传端到端 · ${DateTime.now()}')
      ..writeln()
      ..writeln('- 云端：$base')
      ..writeln('- 录音：${data.length} 字节 ≈ ${(data.length / 2000 / 60).toStringAsFixed(1)} 分钟；卡限速 ${card.bytesPerSec} B/s')
      ..writeln('- 第一段上传：$firstPut')
      ..writeln('- 从卡上拉完：${pulledAt.toStringAsFixed(1)}s')
      ..writeln('- 拉卡过程中云端转写进度最高：$progressWhilePulling%')
      ..writeln('- 边拉边传出逐字稿：${doneAt.toStringAsFixed(1)}s（拉完后 ${(doneAt - pulledAt).toStringAsFixed(1)}s）')
      ..writeln('- 对照：一次性上传同一文件，云端转写用了 ${(oneAt - doneAt).toStringAsFixed(1)}s')
      ..writeln('- 时长：边拉边传 ${res['seconds']}s / 一次性 ${one['seconds']}s；开录 ${res['start']} / ${one['start']}')
      ..writeln('- 行数：边拉边传 ${lines.length} / 一次性 ${oneLines.length}；字数 ${a.length} / ${b.length}；逐字相似度 ${(sim * 100).toStringAsFixed(1)}%')
      ..writeln('- 钟点倒退的行：$back；第一行 ${lines.first[0]}，最后一行 ${lines.last[0]}（一次性：${oneLines.first[0]} … ${oneLines.last[0]}）')
      ..writeln()
      ..writeln('## 时间线')
      ..writeln()
      ..writeln('```')
      ..writeAll(timeline, '\n')
      ..writeln('\n```');
    File('${out.parent.path}/summary.md').writeAsStringSync(summary.toString());
    // ignore: avoid_print
    print(summary);

    expect(firstPut, contains('pulling'), reason: '第一段在拉卡过程中就传了');
    expect(progressWhilePulling, greaterThan(0), reason: '拉完之前云端已经在转写');
    expect(res['seconds'], one['seconds']);
    expect(res['start'], one['start']);
    expect(back, 0, reason: '钟点一路往后');
    expect(secsOf(lines.last[0]) - secsOf(lines.first[0]), greaterThan((res['seconds'] as num) - 180));
    expect(sim, greaterThan(0.9));
    expect(store.audio(stem).lengthSync(), greaterThan(100000));
  }, skip: live ? false : '要连云端：STREAM_E2E=1 才跑', timeout: const Timeout(Duration(minutes: 45)));
}
