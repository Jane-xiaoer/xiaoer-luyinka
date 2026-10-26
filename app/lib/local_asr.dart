// 录音卡 / 录音豆的录音在本机转写（Mac）：比传云端快得多（M5 上 1 小时几分钟，云端 1 核要半小时多，还得先上传），
// 云端当备用（本机模型没下好、转写出错、手机上）。出来的结果跟云端 /v1/recordings 的 result 一模一样：
//   {recording, start, seconds, lines: [[钟点, 文字]], scenes: []}，外加播放用的 录音/<录音>.m4a。
// 步骤也跟云端一样：原文件 → Ogg Opus（卡上是裸 Opus 帧，豆子拉下来已经是 Ogg）→ 16k 单声道 wav（系统自带的 afconvert）
// → 切句 + SenseVoice（跟现场会议同一套模型，在单独的 isolate 里跑）→ 相邻句子并成一行（隔 < 2 秒、最长 30 秒 / 120 字）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'live.dart' show LiveModels;

const _rate = 16000;
const _cardFrame = 40; // 卡上一帧 40 字节（16k 单声道 Opus，20ms）

class LocalAsr {
  final LiveModels models;
  LocalAsr(this.models);

  /// 现在能在本机转：Mac 上、模型下好了（第一次开现场会议、或后台自动下）
  bool get ready => Platform.isMacOS && models.ready;

  /// 转一条：[raw] 是拉下来的原文件，[stem] 是录音名（开录时刻从名字里认）。结果见文件开头；[m4a] 写播放用的原声。
  Future<Map<String, dynamic>> transcribe(
    File raw,
    String stem,
    File m4a, {
    void Function(int percent)? progress,
    String Function(String)? fix,
  }) async {
    final tmp = await Directory.systemTemp.createTemp('luyinka-asr');
    try {
      final bytes = await raw.readAsBytes();
      final isOgg = bytes.length >= 4 && ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'OggS';
      final ogg = isOgg ? raw : File('${tmp.path}/a.ogg');
      if (!isOgg) await ogg.writeAsBytes(cardOgg(bytes));
      final wav = File('${tmp.path}/a.wav');
      await _run(['-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', ogg.path, wav.path]);
      await m4a.parent.create(recursive: true);
      await _run(['-f', 'm4af', '-d', 'aac', '-b', '48000', wav.path, m4a.path]);
      final pcm = _wavSamples(await wav.readAsBytes());
      final segs = await _recognize(pcm, progress);
      final start = startOf(stem);
      String clock(double sec) {
        if (start == null) return _hms(Duration(milliseconds: (sec * 1000).round()));
        final t = start.add(Duration(milliseconds: (sec * 1000).round()));
        return '${_p2(t.hour)}:${_p2(t.minute)}:${_p2(t.second)}';
      }

      final lines = [
        for (final (s, text) in mergeLines(segs)) [clock(s), fix == null ? text : fix(text)],
      ];
      return {
        'recording': stem,
        'start': start == null ? '' : isoWithOffset(start),
        'seconds': double.parse((pcm.length / _rate).toStringAsFixed(1)),
        'lines': lines,
        'scenes': [],
        'asr': 'local',
      };
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  Future<void> _run(List<String> args) async {
    final r = await Process.run('/usr/bin/afconvert', args);
    if (r.exitCode != 0) throw Exception('音频转换没成功：${r.stderr}');
  }

  Future<List<(double, double, String)>> _recognize(Int16List pcm, void Function(int)? progress) async {
    final from = ReceivePort();
    final done = Completer<List<(double, double, String)>>();
    final out = <(double, double, String)>[];
    from.listen((m) {
      if (m is int) {
        progress?.call(m);
      } else if (m is List) {
        out.add((m[0] as double, m[1] as double, m[2] as String));
      } else if (m == 'done') {
        done.complete(out);
      } else if (m is String) {
        done.completeError(Exception(m));
      }
    });
    final threads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4).toString();
    final iso = await Isolate.spawn(_fileMain, [
      from.sendPort,
      [models.model.path, models.tokens.path, models.vad.path, threads],
      TransferableTypedData.fromList([pcm.buffer.asUint8List()]),
    ], errorsAreFatal: true);
    try {
      return await done.future;
    } finally {
      from.close();
      iso.kill();
    }
  }
}

/// 识别一整条：切句 → 每句出字。发回 [开始秒, 结束秒, 文字]，进度（0–100 的 int），最后 'done'；出错发错误文字。
void _fileMain(List<Object> args) {
  final out = args[0] as SendPort;
  final paths = args[1] as List<String>;
  try {
    so.initBindings();
    final pcm = Int16List.view((args[2] as TransferableTypedData).materialize());
    final vad = so.VoiceActivityDetector(
      config: so.VadModelConfig(
        sileroVad: so.SileroVadModelConfig(
          model: paths[2],
          threshold: 0.5,
          minSilenceDuration: 0.5,
          minSpeechDuration: 0.25,
          windowSize: 512,
          maxSpeechDuration: 20,
        ),
        sampleRate: _rate,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 60,
    );
    final rec = so.OfflineRecognizer(
      so.OfflineRecognizerConfig(
        model: so.OfflineModelConfig(
          senseVoice: so.OfflineSenseVoiceModelConfig(model: paths[0], language: 'zh', useInverseTextNormalization: true),
          tokens: paths[1],
          numThreads: int.parse(paths[3]),
          debug: false,
        ),
      ),
    );
    void drain() {
      while (!vad.isEmpty()) {
        final seg = vad.front();
        vad.pop();
        final s = rec.createStream();
        s.acceptWaveform(samples: seg.samples, sampleRate: _rate);
        rec.decode(s);
        final text = rec.getResult(s).text.trim();
        s.free();
        if (text.isNotEmpty) out.send([seg.start / _rate, (seg.start + seg.samples.length) / _rate, text]);
      }
    }

    var last = -1;
    final f = Float32List(512);
    for (var i = 0; i + 512 <= pcm.length; i += 512) {
      for (var k = 0; k < 512; k++) {
        f[k] = pcm[i + k] / 32768.0;
      }
      vad.acceptWaveform(f);
      drain();
      final pct = i * 100 ~/ pcm.length;
      if (pct != last) {
        last = pct;
        out.send(pct);
      }
    }
    vad.flush();
    drain();
    vad.free();
    rec.free();
    out.send('done');
  } catch (e) {
    out.send('本机识别出错：$e');
  }
}

/// 相邻句子并成一行（跟云端 to_markdown 一样）：隔 < [gap] 秒就并，一行最长 [maxSec] 秒 / [maxChars] 字。返回 (开始秒, 文字)。
List<(double, String)> mergeLines(
  List<(double, double, String)> segs, {
  double gap = 2.0,
  double maxSec = 30,
  int maxChars = 120,
}) {
  final out = <(double, String)>[];
  final para = <(double, double, String)>[];
  void flush() {
    if (para.isNotEmpty) out.add((para.first.$1, para.map((s) => s.$3).join()));
    para.clear();
  }

  for (final s in segs) {
    if (para.isNotEmpty &&
        (s.$1 - para.last.$2 > gap ||
            s.$2 - para.first.$1 > maxSec ||
            para.fold<int>(0, (a, x) => a + x.$3.length) + s.$3.length > maxChars)) {
      flush();
    }
    para.add(s);
  }
  flush();
  return out;
}

/// 开录时刻（本地墙上时间）：卡上「2026-10-18 07.40.00」、豆子「bean20261024110629」。认不出是 null。
DateTime? startOf(String stem) {
  final card = RegExp(r'^(\d{4})-(\d\d)-(\d\d) (\d\d)\.(\d\d)\.(\d\d)').firstMatch(stem);
  final bean = RegExp(r'^bean(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)').firstMatch(stem);
  final m = card ?? bean;
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}

/// 2026-10-24T11:06:29-04:00（跟云端给的一样带时区）
String isoWithOffset(DateTime t) {
  final o = t.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final a = o.abs();
  return '${t.year}-${_p2(t.month)}-${_p2(t.day)}T${_p2(t.hour)}:${_p2(t.minute)}:${_p2(t.second)}'
      '$sign${_p2(a.inHours)}:${_p2(a.inMinutes % 60)}';
}

/// 卡上的裸 Opus 帧（每帧 40 字节）→ Ogg Opus（跟云端 opus_ogg.raw_to_ogg 一样，granule 按每包 TOC 算）。
Uint8List cardOgg(Uint8List raw, {int frameBytes = _cardFrame}) {
  final frames = [
    for (var i = 0; i + frameBytes <= raw.length; i += frameBytes) Uint8List.sublistView(raw, i, i + frameBytes),
  ];
  const serial = 0x4C594B41;
  final out = BytesBuilder(copy: false);
  final head = BytesBuilder()
    ..add(ascii.encode('OpusHead'))
    ..add([1, 1, 0x38, 0x01]) // 版本 1、单声道、预跳 312
    ..add(_le32(_rate))
    ..add([0, 0, 0]);
  final tags = BytesBuilder()
    ..add(ascii.encode('OpusTags'))
    ..add(_le32(7))
    ..add(ascii.encode('luyinka'))
    ..add(_le32(0));
  out.add(_page(serial, 0, 0, [head.toBytes()], 2));
  out.add(_page(serial, 1, 0, [tags.toBytes()], 0));
  var seq = 2, granule = 0;
  for (var k = 0; k < frames.length; k += 50) {
    final chunk = frames.sublist(k, k + 50 < frames.length ? k + 50 : frames.length);
    for (final f in chunk) {
      granule += tocSamples48k(f);
    }
    out.add(_page(serial, seq++, granule, chunk, k + 50 >= frames.length ? 4 : 0));
  }
  if (frames.isEmpty) out.add(_page(serial, seq, 0, [], 4));
  return out.toBytes();
}

/// RFC 6716 §3.1：这一包解码后的 48k 采样数
int tocSamples48k(Uint8List p) {
  if (p.isEmpty) return 0;
  final config = p[0] >> 3;
  final frame = config < 12
      ? const [480, 960, 1920, 2880][config & 3]
      : config < 16
      ? const [480, 960][config & 1]
      : const [120, 240, 480, 960][config & 3];
  final code = p[0] & 3;
  final n = code == 0 ? 1 : (code < 3 ? 2 : (p.length > 1 ? p[1] & 0x3F : 1));
  return frame * n;
}

Uint8List _page(int serial, int seq, int granule, List<Uint8List> packets, int flag) {
  final segs = <int>[];
  for (final p in packets) {
    var n = p.length;
    while (n >= 255) {
      segs.add(255);
      n -= 255;
    }
    segs.add(n);
  }
  final b = BytesBuilder()
    ..add(ascii.encode('OggS'))
    ..add([0, flag])
    ..add(_le64(granule))
    ..add(_le32(serial))
    ..add(_le32(seq))
    ..add(_le32(0))
    ..add([segs.length, ...segs]);
  for (final p in packets) {
    b.add(p);
  }
  final page = b.toBytes();
  final crc = _crc(page);
  page.setRange(22, 26, _le32(crc));
  return page;
}

final _table = List<int>.generate(256, (i) {
  var r = i << 24;
  for (var k = 0; k < 8; k++) {
    r = (r & 0x80000000) != 0 ? ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF : (r << 1) & 0xFFFFFFFF;
  }
  return r;
});

int _crc(Uint8List d) {
  var c = 0;
  for (final b in d) {
    c = ((c << 8) & 0xFFFFFFFF) ^ _table[((c >> 24) ^ b) & 0xFF];
  }
  return c;
}

List<int> _le32(int v) => [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF];
List<int> _le64(int v) => [for (var i = 0; i < 8; i++) (v >> (8 * i)) & 0xFF];

Int16List _wavSamples(Uint8List wav) {
  // 找 data 块（afconvert 写的 wav 前面可能有别的块）
  var i = 12;
  while (i + 8 <= wav.length) {
    final id = ascii.decode(wav.sublist(i, i + 4), allowInvalid: true);
    final n = ByteData.sublistView(wav, i + 4, i + 8).getUint32(0, Endian.little);
    if (id == 'data') {
      final end = (i + 8 + n).clamp(0, wav.length);
      return Int16List.fromList(Int16List.view(Uint8List.fromList(wav.sublist(i + 8, end)).buffer));
    }
    i += 8 + n + (n & 1);
  }
  throw Exception('wav 里没有声音数据');
}

String _p2(int n) => n.toString().padLeft(2, '0');
String _hms(Duration d) => '${_p2(d.inHours)}:${_p2(d.inMinutes % 60)}:${_p2(d.inSeconds % 60)}';
