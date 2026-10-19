// 本机存储：每条录音的进度（拉到哪 / 传了没 / 云端好了没）+ 云端回来的场景。都在 App 自己的文件夹里。
//   <dir>/state.json            设置 + 每条录音的状态
//   <dir>/raw/<stem>.opus.part  正在从卡上拉的（断了接着拉）
//   <dir>/raw/<stem>.opus       拉完、还没传上云的
//   <dir>/result/<stem>.json    云端结果（场景 + 全文）
//   <dir>/audio/<stem>.m4a      播放用
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class Scene {
  final Map<String, dynamic> d;
  final String stem; // 属于哪条录音（播放、取全文用）
  Scene(this.d, this.stem);
  String get id => d['id'] ?? '';
  // 按录音当时的墙上时间显示（不换算成本机 / UTC）：只取 ISO 串的前 19 位
  DateTime get start => DateTime.parse(d['start'].toString().substring(0, 19));
  DateTime get end => DateTime.parse(d['end'].toString().substring(0, 19));
  String get category => d['category'] ?? '';
  String get title => d['title'] ?? '';
  String get event => d['event'] ?? '';
  String get place => d['place'] ?? '';
  double get offset => (d['offset'] as num?)?.toDouble() ?? 0;
  List<String> strs(String k) => List<String>.from(d[k] ?? const []);
  List<Map<String, dynamic>> pairs(String k) => List<Map<String, dynamic>>.from(d[k] ?? const []);
  List<String> get people => strs('people');
  List<String> get views => strs('views');
  List<String> get valuable => strs('valuable');
  List<Map<String, dynamic>> get memorable => pairs('memorable');
  List<Map<String, dynamic>> get actions => pairs('actions');
  List<Map<String, dynamic>> get reminders => pairs('reminders');
  List<List<String>> get text => [for (final x in (d['text'] as List? ?? const [])) List<String>.from(x)];
  // 开会 / 商业洽谈才有：云端单独整理的标准会议纪要（结构化 + 可直接复制的 Markdown）
  Map<String, dynamic>? get minutes => d['minutes'] == null ? null : Map<String, dynamic>.from(d['minutes']);
  String get minutesMd => d['minutes_md'] ?? '';
  bool get noise => category == '杂音';
  int get todo => actions.length + reminders.length;
  String get dayKey => d['start'].toString().substring(0, 10);
}

class Rec {
  String stem;
  int size;
  String stage; // card 在卡上 · pulling 拉取中 · pulled 已拉 · uploading · processing 云端处理 · done · error
  int got = 0; // 已拉字节
  int progress = 0; // 云端进度 0–100
  String? job;
  String? error;
  bool deletedOnCard = false;
  Rec(this.stem, this.size, this.stage);

  Map<String, dynamic> toJson() => {
        'stem': stem, 'size': size, 'stage': stage, 'got': got, 'progress': progress,
        'job': job, 'error': error, 'deletedOnCard': deletedOnCard,
      };
  static Rec fromJson(Map<String, dynamic> j) => Rec(j['stem'], j['size'] ?? 0, j['stage'] ?? 'card')
    ..got = j['got'] ?? 0
    ..progress = j['progress'] ?? 0
    ..job = j['job']
    ..error = j['error']
    ..deletedOnCard = j['deletedOnCard'] ?? false;
}

class Store extends ChangeNotifier {
  final Directory dir;
  Map<String, dynamic> settings = {};
  final Map<String, Rec> recs = {};
  final Map<String, List<Scene>> _scenes = {}; // stem → 场景

  Store(this.dir);

  File get _state => File('${dir.path}/state.json');
  File raw(String stem, {bool part = false}) => File('${dir.path}/raw/$stem.opus${part ? '.part' : ''}');
  File result(String stem) => File('${dir.path}/result/$stem.json');
  File audio(String stem) => File('${dir.path}/audio/$stem.m4a');

  Future<void> load() async {
    for (final d in ['raw', 'result', 'audio']) {
      await Directory('${dir.path}/$d').create(recursive: true);
    }
    if (await _state.exists()) {
      final j = jsonDecode(await _state.readAsString());
      settings = Map<String, dynamic>.from(j['settings'] ?? {});
      for (final r in (j['recs'] as List? ?? [])) {
        final rec = Rec.fromJson(Map<String, dynamic>.from(r));
        recs[rec.stem] = rec;
      }
    }
    for (final r in recs.values.where((r) => r.stage == 'done')) {
      await _loadScenes(r.stem);
    }
    notifyListeners();
  }

  Future<void> _saving = Future.value();

  /// 排队写：同步时会连着存好几次，并发写同一个临时文件会互相踩。
  Future<void> save() => _saving = _saving.catchError((_) {}).then((_) async {
        final tmp = File('${_state.path}.tmp');
        await tmp.writeAsString(jsonEncode({'settings': settings, 'recs': recs.values.map((r) => r.toJson()).toList()}));
        await tmp.rename(_state.path);
        notifyListeners();
      });

  Future<void> _loadScenes(String stem) async {
    final f = result(stem);
    if (!await f.exists()) return;
    final j = jsonDecode(await f.readAsString());
    _scenes[stem] = [for (final s in (j['scenes'] as List? ?? [])) Scene(Map<String, dynamic>.from(s), stem)];
  }

  Future<void> putResult(String stem, Map<String, dynamic> res) async {
    await result(stem).writeAsString(jsonEncode(res));
    await _loadScenes(stem);
  }

  /// 所有场景（不含杂音），新的在前。
  List<Scene> get scenes {
    final all = [for (final l in _scenes.values) ...l.where((s) => !s.noise)];
    all.sort((a, b) => b.start.compareTo(a.start));
    return all;
  }

  /// 日期 → 那天的场景（按时间正序），日期新的在前。
  Map<String, List<Scene>> get days {
    final out = <String, List<Scene>>{};
    for (final s in scenes) {
      out.putIfAbsent(s.dayKey, () => []).add(s);
    }
    for (final l in out.values) {
      l.sort((a, b) => a.start.compareTo(b.start));
    }
    return out;
  }

  /// 正在路上的（还没出结果的）。
  List<Rec> get pending => recs.values.where((r) => r.stage != 'done').toList();
}
