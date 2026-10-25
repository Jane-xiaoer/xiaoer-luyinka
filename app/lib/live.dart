// 现场会议：开着 App 边开会边出逐字稿，右边自己记笔记；结束后当成一段录音收进录音卡
// （跟卡上来的一样排进「待整理」→ 切场景、出纪要；经纪人工作台再推飞书 / 小耳灵感）。
//
// 识别全在本机：silero VAD 切句 → SenseVoice（sherpa-onnx）出字，跑在单独的 isolate 里，说话时界面不卡。
// 模型第一次用时准备：Mac 上本机已有（实时逐字稿 / 录音卡命令行版下载过）就直接拷，没有再下载。
//
//   <App 目录>/models/sense-voice/{model.int8.onnx,tokens.txt}   <App 目录>/models/silero_vad.onnx
//   <App 目录>/live/draft.json   正在开的会（每句、每次改笔记都存）：App 崩了 / 被关了，下次打开接着来
//   <App 目录>/live/<录音>.pcm    正在录的原声（16k 单声道 16 位），结束时转成 录音/<录音>.m4a
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show sqrt;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show EventChannel, MethodChannel, PlatformException, rootBundle;
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'analyze.dart' show Chat;
import 'llm.dart';
import 'store.dart';
import 'templates.dart' show VocabEntry, fixWords, plainNotes;
import 'voices.dart';

const _rate = 16000;
const _vadWindow = 512;
const _maxGapPad = Duration(minutes: 30); // 暂停后接着录：中间补静音，原声和钟点才对得上；停太久就不补了

class LiveLine {
  final DateTime at;
  final DateTime? end; // 这句说完的时刻（旧草稿里没有）
  String text; // 词库改了会就地换掉听错的词
  String? speaker; // 谁说的；null = 不知道
  bool auto; // true = 小耳按声纹猜的（可能会随着你多标几句改过来）；false = 你亲手标的，不再动
  final Float32List? emb; // 这句的声纹（太短的句子没有）
  bool learned; // 这句已经让声纹库学过（或者轮过一次没学）：同一句不学第二次
  LiveLine(this.at, this.text, {this.end, this.speaker, this.auto = true, this.emb, this.learned = false});

  /// 存进录音卡 / 发给模型的那一行：标了人就带上「王总：」
  String get said => speaker == null ? text : '$speaker：$text';

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    if (end != null) 'end': end!.toIso8601String(),
    'text': text,
    if (speaker != null) 'who': speaker,
    if (!auto) 'auto': false,
    if (emb != null) 'emb': Voices.encode(emb!),
    if (learned) 'learned': true,
  };
  static LiveLine fromJson(Map<String, dynamic> j) => LiveLine(
    DateTime.parse(j['at']),
    j['text'] ?? '',
    end: j['end'] == null ? null : DateTime.tryParse(j['end']),
    speaker: j['who'],
    auto: j['auto'] ?? true,
    emb: j['emb'] == null ? null : Voices.decode(j['emb']),
    learned: j['learned'] ?? false,
  );
}

/// 一句话被停顿切成几小段（「可以继续。」「去编辑。」）：新的一段离上一句很近、像是同一个人、合起来不太长，
/// 就接到上一句后面成一整句（Jane：切得太碎，一个意思要记两次）。接不上返回 null。
/// [identify] 用合起来的声纹重新认人。
/// 单独一小段只有语气词（嗯、啊、呃……）：不显示
bool isFiller(String t) => RegExp(r'^[嗯啊呃哦唔额噢欸诶哈恩嘛呀，、。！？!?,.\s]*$').hasMatch(t);

const _joinMin = 0.6; // 相邻两段整句声纹：同一人 0.61–0.88，换人 0.21–0.30（2026-10-24 两人对话实测）

LiveLine? joinLines(LiveLine prev, LiveLine next, String? Function(Float32List) identify) {
  const gap = Duration(milliseconds: 1500), maxChars = 150, maxSpan = Duration(seconds: 60);
  if (prev.end == null || next.at.difference(prev.end!) > gap) return null;
  if (prev.text.length + next.text.length > maxChars) return null;
  if ((next.end ?? next.at).difference(prev.at) > maxSpan) return null;
  if (prev.speaker != null && next.speaker != null && prev.speaker != next.speaker) return null;
  // 得确认是同一个人才接（接错了两个人的话就粘成一句，标注也会被污染）：认出是同一人，或者两段声纹够像。
  // 例外：太短算不出声纹的小碎片（「可。」「这个。」），紧跟着就接上——就算偶尔是别人插的一句「对」，接错代价也小。
  final sameNamed = prev.speaker != null && prev.speaker == next.speaker;
  final sameVoice = prev.emb != null && next.emb != null && Voices.cosine(prev.emb!, next.emb!) >= _joinMin;
  final crumb = next.emb == null && next.text.length <= 6 && next.at.difference(prev.end!) <= const Duration(seconds: 1);
  if (!sameNamed && !sameVoice && !crumb) return null;
  if (!prev.auto && prev.speaker == null && next.speaker != null) return null; // 你说过「不知道是谁」的那句，别把认出来的人并进去
  // 声纹按时长加权平均（余弦只看方向，不用归一化）
  Float32List? emb = prev.emb ?? next.emb;
  if (prev.emb != null && next.emb != null && prev.emb!.length == next.emb!.length) {
    final wa = prev.end!.difference(prev.at).inMilliseconds.toDouble().clamp(1, 1e9);
    final wb = (next.end ?? next.at).difference(next.at).inMilliseconds.toDouble().clamp(1, 1e9);
    emb = Float32List.fromList([for (var i = 0; i < prev.emb!.length; i++) prev.emb![i] * wa + next.emb![i] * wb]);
  }
  final head = prev.text.endsWith('。') ? '${prev.text.substring(0, prev.text.length - 1)}，' : prev.text;
  final speaker = !prev.auto ? prev.speaker : (emb == null ? (prev.speaker ?? next.speaker) : identify(emb));
  return LiveLine(
    prev.at,
    '$head${next.text}',
    end: next.end,
    speaker: speaker,
    auto: prev.auto,
    emb: emb,
    learned: prev.learned && next.learned,
  );
}

/// 模型：本机有就拷，没有就下载（huggingface，连不上换国内镜像）。
class LiveModels {
  final Directory dir;
  LiveModels(Directory appDir) : dir = Directory('${appDir.path}/models');

  File get model => File('${dir.path}/sense-voice/model.int8.onnx');
  File get tokens => File('${dir.path}/sense-voice/tokens.txt');
  File get vad => File('${dir.path}/silero_vad.onnx');
  File get speaker => File('${dir.path}/campplus_zh.onnx'); // 声纹（认人）；没有也能录，只是不自动标人
  bool get ready => model.existsSync() && tokens.existsSync() && vad.existsSync();

  static const _hf = 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main';
  // 3D-Speaker 的 CAM++ 中文声纹模型（28MB）。国内先走镜像能下的 huggingface / hf-mirror，GitHub 兜底
  // （GitHub 的 release 名就是官方拼错的 recongition）
  static const _speakerName = '3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx';
  static const _speakerUrls = [
    'https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/$_speakerName',
    'https://hf-mirror.com/csukuangfj/speaker-embedding-models/resolve/main/$_speakerName',
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/$_speakerName',
  ];

  /// 声纹模型：下不下来不拦着录音，返回 false 让界面说一声。
  Future<bool> ensureSpeaker(void Function(String what, double? frac) progress) async {
    if (await speaker.exists()) return true;
    await dir.create(recursive: true);
    for (final url in _speakerUrls) {
      try {
        await _download(url, speaker, (p) => progress('下载认人用的声纹模型（只下一次）', p));
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// Mac 上别的工具（实时逐字稿）已经下好的同款听写模型
  List<String> _local(String name) {
    final home = Platform.environment['HOME'] ?? '';
    if (!Platform.isMacOS || home.isEmpty) return const [];
    return switch (name) {
      'model.int8.onnx' || 'tokens.txt' => [
        '$home/Library/Application Support/com.rtc.transcriber/models/official_sensevoice/$name',
        '$home/projects/RTC/asr_local/official_sensevoice/$name',
      ],
      _ => const [],
    };
  }

  Future<void> ensure(void Function(String what, double? frac) progress) async {
    await File('${model.parent.path}/.keep').create(recursive: true);
    if (!await vad.exists()) {
      // 切句模型随 App 带着（assets/models/），拷出来给原生库读
      final b = await rootBundle.load('assets/models/silero_vad.onnx');
      await File('${vad.path}.part').writeAsBytes(b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes));
      await File('${vad.path}.part').rename(vad.path);
    }
    for (final (f, urls) in [
      (tokens, ['https://huggingface.co/$_hf/tokens.txt', 'https://hf-mirror.com/$_hf/tokens.txt']),
      (model, ['https://huggingface.co/$_hf/model.int8.onnx', 'https://hf-mirror.com/$_hf/model.int8.onnx']),
    ]) {
      if (await f.exists()) continue;
      final name = f.uri.pathSegments.last;
      final local = _local(name).map(File.new).where((x) => x.existsSync()).firstOrNull;
      if (local != null) {
        progress('拷贝本机已有的识别模型', null);
        await local.copy('${f.path}.part');
        await File('${f.path}.part').rename(f.path);
        continue;
      }
      Object? last;
      for (final url in urls) {
        try {
          await _download(url, f, (p) => progress('下载识别模型（只下一次）', p));
          last = null;
          break;
        } catch (e) {
          last = e;
        }
      }
      if (last != null) throw Exception('识别模型没下载下来：$last');
    }
  }

  Future<void> _download(String url, File to, void Function(double?) progress) async {
    final client = http.Client();
    try {
      final r = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final part = File('${to.path}.part');
      final sink = part.openWrite();
      var got = 0;
      final total = r.contentLength;
      await for (final chunk in r.stream) {
        sink.add(chunk);
        got += chunk.length;
        progress(total == null || total == 0 ? null : got / total);
      }
      await sink.close();
      await part.rename(to.path);
    } finally {
      client.close();
    }
  }
}

/// 识别 isolate：收 Float32 样本，吐 {start: 样本序号, text}。
void _asrMain(List<Object> args) {
  final out = args[0] as SendPort;
  final paths = args[1] as List<String>; // model, tokens, vad, threads, 声纹模型（空 = 不认人）
  so.initBindings();
  final vad = so.VoiceActivityDetector(
    config: so.VadModelConfig(
      sileroVad: so.SileroVadModelConfig(
        model: paths[2],
        threshold: 0.5,
        // 0.8 会把两个人接话切进同一段（2026-10-24 两人对话没分清）；碎句由 joinLines 按声纹接回去
        minSilenceDuration: 0.5,
        minSpeechDuration: 0.25,
        windowSize: _vadWindow,
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
  final spk = paths[4].isEmpty
      ? null
      : so.SpeakerEmbeddingExtractor(config: so.SpeakerEmbeddingExtractorConfig(model: paths[4], numThreads: 1, debug: false));
  var pending = Float32List(0);

  /// 这一句的声纹：不到 0.8 秒的（嗯、对、好的）认不准，不算
  Float32List? voiceOf(Float32List samples) {
    if (spk == null || samples.length < _rate * 0.8) return null;
    final s = spk.createStream();
    s.acceptWaveform(samples: samples, sampleRate: _rate);
    s.inputFinished();
    final e = spk.isReady(s) ? spk.compute(s) : null;
    s.free();
    return e;
  }

  Float32List embed(Float32List samples) {
    final s = spk!.createStream();
    s.acceptWaveform(samples: samples, sampleRate: _rate);
    s.inputFinished();
    final e = spk.compute(s);
    s.free();
    return e;
  }

  void drain() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      // 一段里有人接话：先按声纹在换人处切开，每块分别出字、分别认人
      final cuts = spk == null ? const <int>[] : speakerCuts(seg.samples, embed);
      final bounds = [0, ...cuts, seg.samples.length];
      for (var i = 0; i + 1 < bounds.length; i++) {
        final part = Float32List.sublistView(seg.samples, bounds[i], bounds[i + 1]);
        final s = rec.createStream();
        s.acceptWaveform(samples: part, sampleRate: _rate);
        rec.decode(s);
        final text = rec.getResult(s).text.trim();
        s.free();
        if (text.isNotEmpty) {
          out.send({'start': seg.start + bounds[i], 'len': part.length, 'text': text, 'emb': voiceOf(part)});
        }
      }
    }
  }

  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  inbox.listen((msg) {
    if (msg is Float32List) {
      final all = Float32List(pending.length + msg.length)
        ..setAll(0, pending)
        ..setAll(pending.length, msg);
      var i = 0;
      for (; i + _vadWindow <= all.length; i += _vadWindow) {
        vad.acceptWaveform(Float32List.sublistView(all, i, i + _vadWindow));
      }
      pending = Float32List.fromList(Float32List.sublistView(all, i));
      drain();
    } else if (msg == 'flush') {
      vad.flush();
      drain();
      out.send('flushed');
    } else if (msg == 'stop') {
      vad.free();
      rec.free();
      spk?.free();
      inbox.close();
      Isolate.exit();
    }
  });
}

enum LiveState { idle, preparing, recording, paused, saving }

/// 麦克风和电脑声音对齐了再混：两路各自进来，节奏不一样（电脑声音一小块一小块、偶尔晚到），
/// 来一块混一块的话晚到的那下就成了空白，人声被切碎、识别不出字（2026-10-25 实测）。
/// 这里两路各攒着，取两边都有的那么长混出去；电脑声音停了（拖后超过 [maxLag]）就只出麦克风，
/// 电脑声音攒太多（麦克风停了）就丢旧的，别越拖越晚。
///
/// 不戴耳机时对方的声音从扬声器出来、又被麦克风录一遍（晚几十到上百毫秒），两遍叠着识别会丢字串字。
/// 所以电脑在出声（以及刚出完声的 [hang] 这么久）时把麦克风压低到 [duck]；你明显比回声响（同时说话）就不压。
class AudioMixer {
  final int maxLag;
  static const _block = 320; // 20ms 一小段判断
  static const hang = 16000 * 3 ~/ 10; // 电脑停声后还压 300ms（回声晚到）
  static const duck = 0.12;
  AudioMixer(this.maxLag);
  Int16List _mic = Int16List(0), _sys = Int16List(0);
  int _quiet = hang; // 电脑多久没出声了（采样数）
  double _sysLevel = 0; // 最近电脑声音有多响（RMS，慢慢回落）

  static double _rms(Int16List x, int from, int to) {
    if (to <= from) return 0;
    var e = 0.0;
    for (var i = from; i < to; i++) {
      e += x[i] * x[i];
    }
    return sqrt(e / (to - from));
  }

  static Int16List _cat(Int16List a, Int16List b) => Int16List(a.length + b.length)
    ..setAll(0, a)
    ..setAll(a.length, b);

  void addSys(Int16List x) {
    _sys = _cat(_sys, x);
    if (_sys.length > _mic.length + maxLag * 2) _sys = Int16List.fromList(_sys.sublist(_sys.length - maxLag));
  }

  /// 放进一块麦克风，拿出能混好的那段（可能是空的：等电脑声音跟上）
  Int16List addMic(Int16List x) {
    _mic = _cat(_mic, x);
    var n = _mic.length < _sys.length ? _mic.length : _sys.length;
    if (_mic.length - n > maxLag) n = _mic.length; // 电脑声音断了：不等了，没有的地方当静音
    final out = Int16List(n);
    for (var b = 0; b < n; b += _block) {
      final e = b + _block < n ? b + _block : n;
      final sysE = _rms(_sys, b, e < _sys.length ? e : _sys.length);
      final micE = _rms(_mic, b, e);
      if (sysE > 300) {
        _quiet = 0;
        _sysLevel = sysE > _sysLevel ? sysE : _sysLevel;
      } else {
        _quiet += e - b;
        _sysLevel *= 0.97;
      }
      // 电脑在出声 / 刚出完：麦克风多半是回声，压低；比回声响得多（你在说话）就不压
      final g = _quiet < hang && micE < _sysLevel * 1.5 ? duck : 1.0;
      for (var i = b; i < e; i++) {
        final v = (_mic[i] * g).round() + (i < _sys.length ? _sys[i] : 0);
        out[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
      }
    }
    _mic = Int16List.fromList(_mic.sublist(n));
    _sys = n >= _sys.length ? Int16List(0) : Int16List.fromList(_sys.sublist(n));
    return out;
  }
}

class LiveSession extends ChangeNotifier {
  final Store store;
  final Directory appDir;
  final LiveModels models;
  final Voices voices; // 声纹库：跨会议记得谁是谁
  bool speakerOff = false; // 声纹模型没下下来：这场不自动认人
  List<VocabEntry>? _vocab; // 词库：出字时把听错的换掉
  List<VocabEntry> get vocab => _vocab ??= store.lib.vocabEntries();
  final Future<void> Function() afterSave; // 收进录音卡后让同步器跑一轮（整理）
  final bool shareMemory; // 收进去时顺手写共享记忆（ccrag）；测试里关掉
  final Chat? chat; // 「顺一下」用的模型；测试时换成假的，平时用 App 里那一个（Llm.instance）
  LiveSession(this.store, this.appDir, this.afterSave, {this.shareMemory = true, this.chat})
    : models = LiveModels(appDir),
      voices = Voices(File('${appDir.path}/voices.json')) {
    _restore();
  }

  LiveState state = LiveState.idle;
  String title = '';
  String notes = '';
  final List<LiveLine> lines = [];
  DateTime? started; // 这场会开录的时刻（原声第 0 秒）
  String? stem;
  String? status; // 准备模型 / 出错时的一行字
  double? progress;
  double level = 0; // 0–1 音量，给界面画电平
  String? lastSaved; // 刚收进录音卡的那条（界面提示用）

  AudioRecorder? _rec; // 第一次开录才建：没录过音的时候不碰麦克风插件
  AudioRecorder get _recorder => _rec ??= AudioRecorder();
  StreamSubscription<Uint8List>? _mic;

  // ───────── 也录电脑声音（线上会议：腾讯会议 / 飞书 / Zoom…对方的声音）─────────
  static const _sysCh = MethodChannel('luyinka/sysaudio');
  static const _sysPcm = EventChannel('luyinka/sysaudio/pcm');
  StreamSubscription? _sys;
  AudioMixer? _mixer; // 开着「也录电脑声音」时：麦克风和电脑声音对齐了再混
  String? sysWhat; // 正在录的是什么（「腾讯会议」/「电脑里的所有声音」），界面上显示
  bool get withSystem => store.settings['liveSystemAudio'] == true;

  /// 开 / 关「也录电脑声音」。正在录的时候马上生效。
  Future<void> setWithSystem(bool v) async {
    store.settings['liveSystemAudio'] = v;
    await store.save();
    if (state == LiveState.recording) v ? await _startSys() : await _stopSys();
    notifyListeners();
  }

  Future<void> _startSys() async {
    if (_sys != null || !Platform.isMacOS) return;
    try {
      final mixer = _mixer = AudioMixer(_rate * 3 ~/ 10);
      _sys = _sysPcm.receiveBroadcastStream().listen((b) {
        final x = b as Uint8List;
        mixer.addSys(Int16List.view(Uint8List.fromList(x).buffer, 0, x.length ~/ 2));
      });
      sysWhat = await _sysCh.invokeMethod<String>('start');
    } catch (e) {
      await _stopSys();
      status = e is PlatformException ? (e.message ?? '录不了电脑声音') : '录不了电脑声音：$e';
    }
    notifyListeners();
  }

  Future<void> _stopSys() async {
    await _sys?.cancel();
    _sys = null;
    sysWhat = null;
    _mixer = null;
    if (Platform.isMacOS) {
      try {
        await _sysCh.invokeMethod('stop');
      } catch (_) {}
    }
  }
  StreamSubscription<Amplitude>? _amp;
  IOSink? _pcm;
  int _samples = 0; // 已写进原声的样本数：VAD 的 start 是从这一轮开录算的，要加上它
  int _roundBase = 0;
  DateTime? _pausedAt;
  Isolate? _iso;
  SendPort? _toAsr;
  ReceivePort? _fromAsr;
  Completer<void>? _flushed;
  Timer? _saveDraft;
  Timer? _silenceCheck;
  bool _heard = false; // 这一轮有没有收到过非 0 的声音
  int? _odd; // 上一块剩下的半个采样

  bool get active => state == LiveState.recording || state == LiveState.paused;
  Directory get _dir => Directory('${appDir.path}/live');
  File get _draft => File('${_dir.path}/draft.json');
  File _pcmFile(String s) => File('${_dir.path}/$s.pcm');
  Duration get elapsed => started == null ? Duration.zero : Duration(milliseconds: _samples * 1000 ~/ _rate);

  // ───────── 草稿 ─────────

  void _restore() {
    try {
      if (!_draft.existsSync()) return;
      final j = jsonDecode(_draft.readAsStringSync()) as Map<String, dynamic>;
      stem = j['stem'];
      title = j['title'] ?? '';
      notes = j['notes'] ?? '';
      started = DateTime.tryParse(j['started'] ?? '');
      lines.addAll([for (final x in (j['lines'] as List? ?? const [])) LiveLine.fromJson(Map<String, dynamic>.from(x))]);
      _samples = stem == null ? 0 : (_pcmFile(stem!).existsSync() ? _pcmFile(stem!).lengthSync() ~/ 2 : 0);
      _pausedAt = DateTime.tryParse(j['pausedAt'] ?? '') ?? DateTime.now();
      if (lines.isEmpty && notes.trim().isEmpty) {
        _reset(); // 什么都没留下（比如麦克风一直没声音）：不值得恢复，草稿和空录音一起清掉
        return;
      }
      if (stem != null && started != null) state = LiveState.paused; // 上次没收好：停在暂停，接着录或者收进去
      // 认人的规则可能改过、上次关 App 前可能刚标过人：没亲手标的句子按现在的声纹库重认一遍
      // 补学：这场里还没让声纹库学过的句子（比如开会时还没有自动学这个功能），有把握的学进去，每句只学一次
      var learnedAny = false;
      for (final l in lines) {
        if (l.learned || l.emb == null || !l.auto || l.end == null) continue;
        voices.learn(l.emb!, l.end!.difference(l.at).inMilliseconds / 1000);
        l.learned = learnedAny = true;
      }
      for (final l in lines) {
        if (l.auto && l.emb != null) l.speaker = voices.identify(l.emb!);
      }
      if (learnedAny) _persist(now: true);
    } catch (_) {}
  }

  void _persist({bool now = false}) {
    _saveDraft?.cancel();
    void write() {
      if (stem == null) return;
      try {
        _dir.createSync(recursive: true);
        final tmp = File('${_draft.path}.tmp');
        tmp.writeAsStringSync(
          jsonEncode({
            'stem': stem,
            'title': title,
            'notes': notes,
            'started': started?.toIso8601String(),
            'pausedAt': _pausedAt?.toIso8601String(),
            'lines': [for (final l in lines) l.toJson()],
          }),
        );
        tmp.renameSync(_draft.path);
      } catch (_) {}
    }

    if (now) {
      write();
    } else {
      _saveDraft = Timer(const Duration(milliseconds: 600), write);
    }
  }

  void setNotes(String v) {
    notes = v;
    _persist();
  }

  void setTitle(String v) {
    title = v;
    _persist();
    notifyListeners();
  }

  // ───────── 录 ─────────

  Future<void> start() async {
    if (state == LiveState.recording || state == LiveState.preparing || state == LiveState.saving) return;
    state = LiveState.preparing;
    status = null;
    notifyListeners();
    try {
      if (!await _recorder.hasPermission()) throw Exception('没有麦克风权限：去系统设置里允许「小耳录音卡」使用麦克风');
      if (!models.ready) {
        await models.ensure((what, frac) {
          status = what;
          progress = frac;
          notifyListeners();
        });
      }
      speakerOff = !await models.ensureSpeaker((what, frac) {
        status = what;
        progress = frac;
        notifyListeners();
      });
      status = '加载识别模型…';
      progress = null;
      notifyListeners();
      await _startAsr();
      final now = DateTime.now();
      if (stem == null) {
        stem = 'live${_stamp(now)}';
        started = now;
        title = title.isEmpty ? '现场会议 ${_hm(now)}' : title;
        _samples = 0;
      } else if (_pausedAt != null) {
        // 接着录：暂停那段补静音，原声里的秒数才对得上钟点
        final gap = now.difference(_pausedAt!);
        if (gap > Duration.zero && gap <= _maxGapPad) await _padSilence(gap);
      }
      await _dir.create(recursive: true);
      _pcm = _pcmFile(stem!).openWrite(mode: FileMode.append);
      _roundBase = _samples;
      // Mac 上不开回声消除 / 降噪 / 自动增益：插件会因此打开系统的语音处理（setVoiceProcessingEnabled），
      // 实测戴蓝牙耳机、或者别的程序也在用麦克风时，它只吐全 0 的静音（2026-10-24 录了 7 分钟空白）。
      final voice = Platform.isAndroid;
      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _rate,
          numChannels: 1,
          autoGain: voice,
          echoCancel: voice,
          noiseSuppress: voice,
        ),
      );
      _heard = false;
      _odd = null;
      _mic = stream.listen(_onAudio);
      if (withSystem) await _startSys();
      _silenceCheck?.cancel();
      _silenceCheck = Timer(const Duration(seconds: 4), () {
        if (state == LiveState.recording && !_heard) {
          status = '麦克风没有声音：看看系统设置 → 声音 → 输入，选对麦克风（戴着耳机就选耳机），再点「暂停」「接着录」';
          notifyListeners();
        }
      });
      _amp = _recorder.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
        level = ((a.current + 50) / 50).clamp(0.0, 1.0);
        notifyListeners();
      });
      _pausedAt = null;
      state = LiveState.recording;
      status = speakerOff ? '认人用的声纹模型没下载下来：这场照常出字，只是不会自动标是谁说的' : null;
      _persist(now: true);
    } catch (e) {
      await _stopAsr();
      state = stem == null ? LiveState.idle : LiveState.paused;
      status = e.toString().replaceFirst('Exception: ', '');
    }
    progress = null;
    notifyListeners();
  }

  Future<void> _padSilence(Duration gap) async {
    final n = gap.inMilliseconds * _rate ~/ 1000;
    final sink = _pcmFile(stem!).openWrite(mode: FileMode.append);
    const chunk = _rate * 10;
    for (var left = n; left > 0; left -= chunk) {
      sink.add(Uint8List((left < chunk ? left : chunk) * 2));
    }
    await sink.close();
    _samples += n;
  }

  void _onAudio(Uint8List chunk) {
    // 插件给的一块不保证 2 字节对齐、也不保证是整数个采样：拼上上一块剩的半个，拷到对齐的新缓冲再解析
    var bytes = chunk;
    if (_odd != null) {
      bytes = Uint8List(chunk.length + 1)
        ..[0] = _odd!
        ..setRange(1, chunk.length + 1, chunk);
      _odd = null;
    }
    if (bytes.length.isOdd) {
      _odd = bytes.last;
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    if (bytes.isEmpty) return;
    if (bytes.offsetInBytes.isOdd) bytes = Uint8List.fromList(bytes);
    var pcm = Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
    final mixer = _mixer;
    if (mixer != null) {
      // 混进电脑声音（对方说的话）：存下来的原声和识别都是两边都有的
      pcm = mixer.addMic(pcm);
      if (pcm.isEmpty) return;
      bytes = pcm.buffer.asUint8List();
    }
    _pcm?.add(bytes);
    _samples += pcm.length;
    final f = Float32List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      if (pcm[i] != 0) _heard = true;
      f[i] = pcm[i] / 32768.0;
    }
    if (_heard && status != null && status!.startsWith('麦克风没有声音')) status = null;
    _toAsr?.send(f);
    // 隔一会儿刷一下时长
    if (_samples % (_rate ~/ 2) < pcm.length) notifyListeners();
  }

  Future<void> _startAsr() async {
    if (_iso != null) return;
    _fromAsr = ReceivePort();
    final ready = Completer<SendPort>();
    _fromAsr!.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg == 'flushed') {
        _flushed?.complete();
      } else if (msg is Map) {
        final at = started!.add(Duration(milliseconds: (_roundBase + (msg['start'] as int)) * 1000 ~/ _rate));
        final emb = msg['emb'] as Float32List?;
        final end = at.add(Duration(milliseconds: (msg['len'] as int) * 1000 ~/ _rate));
        final text = fixWords(msg['text'] as String, vocab);
        if (isFiller(text)) return;
        final line = LiveLine(at, text, end: end, emb: emb, speaker: emb == null ? null : voices.identify(emb));
        // 认得特别有把握的长句，自己学进声纹库（越聊越准；只留最近 10 条，学错也会被顶掉）
        if (emb != null) {
          voices.learn(emb, end.difference(at).inMilliseconds / 1000);
          line.learned = true;
        }
        final joined = lines.isEmpty ? null : joinLines(lines.last, line, voices.identify);
        if (joined != null) {
          lines[lines.length - 1] = joined;
        } else {
          lines.add(line);
        }
        _persist();
        notifyListeners();
      }
    });
    final threads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4).toString();
    _iso = await Isolate.spawn(_asrMain, [
      _fromAsr!.sendPort,
      [models.model.path, models.tokens.path, models.vad.path, threads, speakerOff ? '' : models.speaker.path],
    ], errorsAreFatal: false);
    _toAsr = await ready.future.timeout(const Duration(minutes: 2));
  }

  /// 把还在 VAD 里的最后一句出完，再关 isolate。
  Future<void> _stopAsr() async {
    if (_toAsr != null) {
      _flushed = Completer();
      _toAsr!.send('flush');
      await _flushed!.future.timeout(const Duration(seconds: 30), onTimeout: () {});
      _toAsr!.send('stop');
    }
    _fromAsr?.close();
    _iso = null;
    _toAsr = null;
    _fromAsr = null;
  }

  Future<void> _stopMic() async {
    _silenceCheck?.cancel();
    await _stopSys();
    await _mic?.cancel();
    await _amp?.cancel();
    _mic = null;
    _amp = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _pcm?.flush();
    await _pcm?.close();
    _pcm = null;
    level = 0;
  }

  Future<void> pause() async {
    if (state != LiveState.recording) return;
    await _stopMic();
    await _stopAsr();
    _pausedAt = DateTime.now();
    state = LiveState.paused;
    _persist(now: true);
    notifyListeners();
  }

  // ───────── 词库 ─────────

  /// 存词库，并把这场已经出来的原话按新词库改一遍。返回改了几句。
  Future<int> saveVocab(List<VocabEntry> entries) async {
    await store.lib.saveVocab(entries);
    _vocab = store.lib.vocabEntries();
    var n = 0;
    for (final l in lines) {
      final t = fixWords(l.text, vocab);
      if (t != l.text) {
        l.text = t;
        n++;
      }
    }
    if (n > 0) _persist();
    notifyListeners();
    return n;
  }

  // ───────── 谁说的 ─────────

  /// 这场会里用过的人 + 声纹库里认得的人（这场用过的排前面）。
  List<String> get people {
    final here = <String>[];
    for (final l in lines.reversed) {
      if (l.speaker != null && !here.contains(l.speaker)) here.add(l.speaker!);
    }
    return [...here, ...voices.names.where((n) => !here.contains(n))];
  }

  /// 标「这几句是 [name] 说的」（null = 清掉）。标了就记下声纹，再把这场里没亲手标过的句子按新声纹重认一遍。
  void label(Iterable<int> idx, String? name) {
    final who = name?.trim();
    for (final i in idx) {
      if (i < 0 || i >= lines.length) continue;
      final l = lines[i]
        ..speaker = (who == null || who.isEmpty) ? null : who
        ..auto = false;
      if (l.speaker != null && l.emb != null) voices.add(l.speaker!, l.emb!);
    }
    for (final l in lines) {
      if (l.auto && l.emb != null) l.speaker = voices.identify(l.emb!);
    }
    _persist();
    notifyListeners();
  }

  /// 忘掉一个人的声纹（以后不再自动认他）。这场里已经标上的不动。
  void forgetVoice(String name) {
    voices.forget(name);
    for (final l in lines) {
      if (l.auto && l.emb != null) l.speaker = voices.identify(l.emb!);
    }
    notifyListeners();
  }

  // ───────── 顺一下 ─────────

  /// 拿这场的原话当背景，把我的笔记理顺（要求在 模板/会议笔记·顺一下.md）。[ask] 是这次额外说的话。
  /// 只返回结果，换不换进笔记由界面决定（要能撤回）。
  Future<String> polish({String ask = ''}) async {
    final llm = Llm.instance;
    final ask0 = chat ?? (llm == null ? null : (String s, String u) => llm.chat(s, u, temperature: 0.3));
    if (ask0 == null) throw Exception('小耳的整理模型还没准备好，稍等再试');
    final lib = store.lib;
    var said = [for (final l in lines) l.said].join('\n');
    if (said.length > 30000) said = '…（前面省略）\n${said.substring(said.length - 30000)}';
    final vocab = lib.vocab();
    final system = [lib.polishPrompt(), if (vocab.isNotEmpty) '\n## 常用词（转写听错时照这里改）\n$vocab'].join('\n');
    final user = [
      '## 会议标题\n$title',
      '## 我的笔记\n${notes.trim().isEmpty ? '（还没记）' : notes.trim()}',
      '## 会议原话（背景）\n${said.isEmpty ? '（还没有）' : said}',
      if (ask.trim().isNotEmpty) '## 这次我另外的要求（和上面冲突时以这条为准）\n${ask.trim()}',
    ].join('\n\n');
    final out = await ask0(system, user);
    return plainNotes(out);
  }

  // ───────── 收进录音卡 ─────────

  /// 结束：原话 + 笔记 + 原声收进录音卡，排进「待整理」。返回收进去的录音名。
  Future<String?> finish() async {
    if (!active) return null;
    if (state == LiveState.recording) await pause();
    final s = stem!;
    if (lines.isEmpty) {
      status = '这场会还没有识别出字，没收进去。可以接着录，或者「放弃」';
      notifyListeners();
      return null;
    }
    state = LiveState.saving;
    status = '收进录音卡…';
    notifyListeners();
    try {
      final lib = store.lib;
      final out = [
        for (final l in lines) [_hms(l.at), l.said],
      ];
      final res = <String, dynamic>{
        'start': _wallIso(started!),
        'lines': out,
        'seconds': elapsed.inMilliseconds / 1000,
        'title': title,
        'notes': notes.trim(),
        'source': '现场会议',
      };
      await _saveAudio(s);
      await lib.writeTranscript(s, res['start'], out);
      await lib.writeLiveNotes(s, title, started!, notes.trim());
      await store.putResult(s, {...res, 'scenes': []});
      store.recs[s] = Rec(s, 0, 'transcribed')..deletedOnCard = true;
      await store.save();
      if (shareMemory) unawaited(_toSharedMemory(res));
      lastSaved = s;
      _reset();
      status = null;
      notifyListeners();
      unawaited(afterSave());
      return s;
    } catch (e) {
      state = LiveState.paused;
      status = '没收进去：$e';
      notifyListeners();
      return null;
    }
  }

  /// 放弃这场（不收进录音卡）。
  Future<void> discard() async {
    if (state == LiveState.recording) await pause();
    final s = stem;
    if (s != null) {
      final f = _pcmFile(s);
      if (await f.exists()) await f.delete();
    }
    _reset();
    notifyListeners();
  }

  void _reset() {
    final s = stem;
    stem = null;
    started = null;
    title = '';
    notes = '';
    lines.clear();
    _samples = 0;
    _pausedAt = null;
    state = LiveState.idle;
    try {
      if (_draft.existsSync()) _draft.deleteSync();
      if (s != null && _pcmFile(s).existsSync()) _pcmFile(s).deleteSync();
    } catch (_) {}
  }

  /// 原声：pcm → wav →（Mac）m4a 放进 录音/。经纪人工作台按「有原声才算真录音」，这步不能省。
  Future<void> _saveAudio(String s) async {
    final pcm = _pcmFile(s);
    if (!await pcm.exists()) return;
    final wav = File('${_dir.path}/$s.wav');
    final n = await pcm.length();
    final head = ByteData(44)
      ..setUint32(0, 0x52494646) // RIFF
      ..setUint32(4, 36 + n, Endian.little)
      ..setUint32(8, 0x57415645) // WAVE
      ..setUint32(12, 0x666d7420) // fmt
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, _rate, Endian.little)
      ..setUint32(28, _rate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(36, 0x64617461) // data
      ..setUint32(40, n, Endian.little);
    final sink = wav.openWrite();
    sink.add(head.buffer.asUint8List());
    await sink.addStream(pcm.openRead());
    await sink.close();
    final m4a = store.audio(s);
    await m4a.parent.create(recursive: true);
    if (Platform.isMacOS) {
      // 16k 单声道的 AAC 码率上限低：64k 会报 Couldn't set audio converter property ('!dat')（2026-10-24 实测），32k 正好
      final r = await Process.run('/usr/bin/afconvert', ['-f', 'm4af', '-d', 'aac', '-b', '32000', wav.path, m4a.path]);
      if (r.exitCode != 0) throw Exception('原声转 m4a 没成功：${r.stderr}');
      await wav.delete();
    } else {
      // 安卓先存 wav（能听，经纪人工作台只在 Mac 上跑，用不到 m4a）
      await wav.rename('${m4a.parent.path}/$s.wav');
    }
  }

  /// 共享记忆（只在 Mac 上、装了 ccrag 才写）：标题、时间、我的笔记、逐字稿。失败不影响收进录音卡。
  Future<void> _toSharedMemory(Map<String, dynamic> res) async {
    if (!Platform.isMacOS) return;
    final home = Platform.environment['HOME'] ?? '';
    final ccrag = File('$home/.local/bin/ccrag');
    if (!await ccrag.exists()) return;
    var text = [for (final l in res['lines'] as List) '${l[0]} ${l[1]}'].join('\n');
    if (text.length > 12000) text = '${text.substring(0, 12000)}\n…（逐字稿过长已截断，全文在录音卡 逐字稿/）';
    final start = (res['start'] as String).substring(0, 16).replaceAll('T', ' ');
    final body =
        '会议时间：$start（${(res['seconds'] as num) ~/ 60} 分钟）\n来源：小耳录音卡 · 现场会议\n\n'
        '【我的笔记】\n${(res['notes'] as String).isEmpty ? '（没有笔记）' : res['notes']}\n\n【逐字稿】\n$text';
    try {
      await Process.run(
        ccrag.path,
        ['note', '会议：${res['title']}', body, '会议笔记', '会议 现场会议 ${res['title']}'],
        environment: {'PATH': '$home/.local/bin:/usr/bin:/bin'},
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _saveDraft?.cancel();
    _persist(now: true);
    _rec?.dispose();
    super.dispose();
  }
}

String _p(int n) => n.toString().padLeft(2, '0');
String _stamp(DateTime t) => '${t.year}${_p(t.month)}${_p(t.day)}-${_p(t.hour)}${_p(t.minute)}${_p(t.second)}';
String _hm(DateTime t) => '${_p(t.hour)}:${_p(t.minute)}';
String _hms(DateTime t) => '${_p(t.hour)}:${_p(t.minute)}:${_p(t.second)}';

/// 墙上时间 + 偏移（和云端给的 start 一个写法：2026-10-23T19:44:38-07:00）
String _wallIso(DateTime t) {
  final o = t.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final m = o.inMinutes.abs();
  return '${t.year}-${_p(t.month)}-${_p(t.day)}T${_hms(t)}$sign${_p(m ~/ 60)}:${_p(m % 60)}';
}

/// 自检（给远程测试机用，不开界面）：用和现场会议完全相同的识别线程、切句合并、声纹，把一段 16k 单声道 wav
/// 跑一遍，结果写进 [outDir]/selftest.json 后返回。模型也放在 [outDir] 里，不碰这台机器的录音卡资料。
/// 用法：`LUYINKA_LIVE_SELFTEST="录音.wav|输出目录"` 启动 App（main.dart 里接）。
Future<void> liveSelfTest(String wavPath, String outDir) async {
  final dir = Directory(outDir)..createSync(recursive: true);
  final log = File('${dir.path}/selftest.log').openWrite();
  void say(String s) => log.writeln('${DateTime.now().toIso8601String().substring(11, 19)} $s');
  final result = <String, dynamic>{'os': Platform.operatingSystemVersion, 'cpus': Platform.numberOfProcessors};
  try {
    final models = LiveModels(dir);
    final sw = Stopwatch()..start();
    var lastPct = -10;
    await models.ensure((what, frac) {
      final pct = frac == null ? -1 : (frac * 100).floor();
      if (pct >= lastPct + 10 || pct == -1) {
        lastPct = pct;
        say('$what ${pct < 0 ? '' : '$pct%'}');
      }
    });
    result['模型准备秒'] = sw.elapsedMilliseconds / 1000;
    sw.reset();
    final spk = await models.ensureSpeaker((what, frac) {});
    result['声纹模型'] = spk ? '有（${sw.elapsedMilliseconds / 1000} 秒）' : '没下下来';

    final bytes = File(wavPath).readAsBytesSync();
    final pcm = Int16List.view(bytes.buffer, 44, (bytes.length - 44) ~/ 2);
    result['音频秒'] = pcm.length / _rate;

    final from = ReceivePort();
    final ready = Completer<SendPort>();
    final done = Completer<void>();
    final t0 = DateTime(2026, 1, 1, 10);
    final lines = <LiveLine>[];
    final voices = Voices(File('${dir.path}/voices.json'));
    from.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg == 'flushed') {
        done.complete();
      } else if (msg is Map) {
        final at = t0.add(Duration(milliseconds: (msg['start'] as int) * 1000 ~/ _rate));
        final end = at.add(Duration(milliseconds: (msg['len'] as int) * 1000 ~/ _rate));
        final emb = msg['emb'] as Float32List?;
        if (isFiller(msg['text'] as String)) return;
        final line = LiveLine(at, msg['text'] as String, end: end, emb: emb, speaker: emb == null ? null : voices.identify(emb));
        final joined = lines.isEmpty ? null : joinLines(lines.last, line, voices.identify);
        joined != null ? lines[lines.length - 1] = joined : lines.add(line);
      }
    });
    final threads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4).toString();
    sw.reset();
    final iso = await Isolate.spawn(_asrMain, [
      from.sendPort,
      [models.model.path, models.tokens.path, models.vad.path, threads, spk ? models.speaker.path : ''],
    ]);
    final to = await ready.future.timeout(const Duration(minutes: 3));
    result['加载模型秒'] = sw.elapsedMilliseconds / 1000;
    sw.reset();
    // 像麦克风那样每次 0.1 秒一块，但不等真实时间：测的是处理速度（实时系数 < 1 才跟得上说话）
    for (var off = 0; off < pcm.length; off += 1600) {
      final end = (off + 1600).clamp(0, pcm.length);
      final f = Float32List(end - off);
      for (var i = off; i < end; i++) {
        f[i - off] = pcm[i] / 32768.0;
      }
      to.send(f);
    }
    to.send('flush');
    await done.future.timeout(const Duration(minutes: 30));
    final secs = sw.elapsedMilliseconds / 1000;
    to.send('stop');
    from.close();
    iso.kill();
    result['识别秒'] = secs;
    result['实时系数'] = double.parse((secs / (pcm.length / _rate)).toStringAsFixed(3));
    result['句数'] = lines.length;
    result['有声纹的句数'] = lines.where((l) => l.emb != null).length;
    result['内存峰值MB'] = ProcessInfo.maxRss ~/ (1024 * 1024);
    result['原话'] = [for (final l in lines) '${_hms(l.at)} ${l.text}'];
    result['ok'] = lines.isNotEmpty;
  } catch (e, st) {
    result['ok'] = false;
    result['error'] = '$e\n$st';
  }
  File('${dir.path}/selftest.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(result));
  say('完成 ok=${result['ok']}');
  await log.close();
}

/// 自检「也录电脑声音」：录 [secs] 秒电脑声音，麦克风当静音（每 100ms 一块），走 [AudioMixer] 混好存成 [wavPath]。
Future<void> systemAudioSelfTest(int secs, String wavPath) async {
  const ch = MethodChannel('luyinka/sysaudio');
  const ev = EventChannel('luyinka/sysaudio/pcm');
  final mixer = AudioMixer(_rate * 3 ~/ 10);
  final out = BytesBuilder();
  final sub = ev.receiveBroadcastStream().listen((b) {
    final x = b as Uint8List;
    mixer.addSys(Int16List.view(Uint8List.fromList(x).buffer, 0, x.length ~/ 2));
  });
  final what = await ch.invokeMethod<String>('start');
  final mic = Timer.periodic(const Duration(milliseconds: 100), (_) {
    out.add(mixer.addMic(Int16List(_rate ~/ 10)).buffer.asUint8List());
  });
  await Future.delayed(Duration(seconds: secs));
  mic.cancel();
  await sub.cancel();
  await ch.invokeMethod('stop');
  final pcm = out.takeBytes();
  final h = ByteData(44);
  void tag(int o, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, _rate, Endian.little)
    ..setUint32(28, _rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, pcm.length, Endian.little);
  File(wavPath).writeAsBytesSync([...h.buffer.asUint8List(), ...pcm]);
  stderr.writeln('录了 $what：${pcm.length ~/ 2 / _rate} 秒');
}
