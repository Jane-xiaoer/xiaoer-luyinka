// 本机存储。App 自己的文件夹里只放同步进度；整理好的内容都在用户的资料文件夹（library.dart）。
//   <dir>/state.json            设置 + 每条录音的状态
//   <dir>/raw/<stem>.opus.part  正在从卡上拉的（断了接着拉）
//   <dir>/raw/<stem>.opus       拉完、还没传上云的（转写好就删）
//   <资料>/.xiaoer/<stem>.json   逐字稿 + 场景（App 的索引）  <资料>/录音/<stem>.m4a  播放用
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'drafts.dart';
import 'library.dart';
import 'templates.dart';

class Scene {
  final Map<String, dynamic> d;
  final String stem; // 属于哪条录音（播放、取全文用）
  Scene(this.d, this.stem);
  String get id => d['id'] ?? '';
  // 按录音当时的墙上时间显示（不换算成本机 / UTC）：只取 ISO 串的前 19 位
  DateTime get start => DateTime.parse(d['start'].toString().substring(0, 19));
  DateTime get end => DateTime.parse(d['end'].toString().substring(0, 19));
  String get category => catKey(d['category'] ?? '');
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
  String get subject => d['subject'] ?? ''; // 现场调研的对象
  String get body => d['body'] ?? ''; // 按类别模板整理好的笔记（Markdown）；旧版数据没有
  bool get noise => category == noiseCat;
  int get todo => actions.length + reminders.length;
  String get dayKey => d['start'].toString().substring(0, 10);
}

class Rec {
  String stem;
  int size;
  String stage; // card 在卡上 · pulling 拉取中 · pulled 已拉 · uploading · processing 云端转写 · transcribed 待整理 · analyzing 整理中 · done · error
  int got = 0; // 已拉字节
  int progress = 0; // 云端进度 0–100
  String? job;
  String? error;
  bool deletedOnCard = false;
  int tried = 0; // 上次整理失败的时间（ms），隔一会儿再试
  Rec(this.stem, this.size, this.stage);

  Map<String, dynamic> toJson() => {
        'stem': stem, 'size': size, 'stage': stage, 'got': got, 'progress': progress,
        'job': job, 'error': error, 'deletedOnCard': deletedOnCard, 'tried': tried,
      };
  static Rec fromJson(Map<String, dynamic> j) => Rec(j['stem'], j['size'] ?? 0, j['stage'] ?? 'card')
    ..got = j['got'] ?? 0
    ..progress = j['progress'] ?? 0
    ..job = j['job']
    ..error = j['error']
    ..deletedOnCard = j['deletedOnCard'] ?? false
    ..tried = j['tried'] ?? 0;
}

class Store extends ChangeNotifier {
  final Directory dir;
  Map<String, dynamic> settings = {};
  final Map<String, Rec> recs = {};
  final Map<String, List<Scene>> _scenes = {}; // stem → 场景
  Library? _lib;
  Library get lib => _lib!;
  set lib(Library l) => _lib = l;
  bool get hasLib => _lib != null;
  List<Draft>? _drafts;

  Store(this.dir);

  File get _state => File('${dir.path}/state.json');
  File raw(String stem, {bool part = false}) => File('${dir.path}/raw/$stem.opus${part ? '.part' : ''}');
  File result(String stem) => lib.data(stem);
  File audio(String stem) => lib.audio(stem);

  Future<void> load() async {
    await Directory('${dir.path}/raw').create(recursive: true);
    if (await _state.exists()) {
      final j = jsonDecode(await _state.readAsString());
      settings = Map<String, dynamic>.from(j['settings'] ?? {});
      for (final r in (j['recs'] as List? ?? [])) {
        final rec = Rec.fromJson(Map<String, dynamic>.from(r));
        recs[rec.stem] = rec;
      }
    }
    lib = Library(Directory((settings['library'] as String?) ?? (await Library.defaultDir()).path));
    await lib.ensure();
    await migrateOld(dir, lib);
    await reload();
  }

  /// 资料文件夹里的索引全读一遍（换了文件夹 / 外面删了文件后也用它）。
  Future<void> reload() async {
    _scenes.clear();
    _drafts = null;
    final d = Directory('${lib.path}/.xiaoer');
    if (await d.exists()) {
      for (final f in d.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
        try {
          await _loadScenes(f.uri.pathSegments.last.replaceAll(RegExp(r'\.json$'), ''));
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  Future<void> moveLibrary(String path) async {
    settings['library'] = path;
    lib = Library(Directory(path));
    await lib.ensure();
    await save();
    await reload();
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

  Map<String, dynamic>? readResult(String stem) {
    final f = result(stem);
    return f.existsSync() ? Map<String, dynamic>.from(jsonDecode(f.readAsStringSync())) : null;
  }

  /// 存一条录音的结果：索引 + 每段的笔记文件 + 那几天的时间线。
  Future<void> putResult(String stem, Map<String, dynamic> res) async {
    final scenes = [for (final s in (res['scenes'] as List? ?? const [])) Scene(Map<String, dynamic>.from(s), stem)];
    for (final s in scenes.where((s) => !s.noise)) {
      await lib.writeNote(s);
    }
    res['scenes'] = [for (final s in scenes) s.d];
    await result(stem).writeAsString(prettyJson(res));
    _scenes[stem] = scenes;
    for (final day in {for (final s in scenes) s.dayKey}) {
      await lib.writeDay(day, days[day] ?? []);
    }
    notifyListeners();
  }

  /// 改了一段（重新整理过）：写回索引和笔记。
  Future<void> putScene(Scene s) async {
    final res = readResult(s.stem);
    if (res == null) return;
    res['scenes'] = [for (final x in _scenes[s.stem] ?? <Scene>[]) x.id == s.id ? s.d : x.d];
    await putResult(s.stem, res);
  }

  /// 手动改一段的类别：换成 [cat]、按新类别的模板重新整理（[note] 就是 Analyzer.note），再写回。
  /// 笔记文件跟着挪到新类别的文件夹；改成杂音就删掉笔记文件。整理失败时这段原样不动，错误照抛。
  Future<void> changeCategory(Scene s, String cat, Future<String> Function(Scene) note, {String subject = ''}) async {
    final before = Map<String, dynamic>.from(s.d);
    final oldCat = s.category, oldSubject = s.subject;
    s.d['category'] = cat;
    s.d['subject'] = cat == '现场调研' ? subject.trim() : '';
    try {
      s.d['body'] = await note(s);
    } catch (_) {
      s.d
        ..clear()
        ..addAll(before);
      rethrow;
    }
    if (oldCat == '现场调研' && oldSubject.isNotEmpty && (cat != oldCat || s.subject != oldSubject)) {
      await lib.forget(s.id, subject: oldSubject);
    }
    if (oldCat == '个人感悟' && cat != oldCat) await lib.forget(s.id, ideas: true);
    if (cat == noiseCat) {
      final f = s.d.remove('file') as String?;
      if (f != null && await File(f).exists()) await File(f).delete();
    }
    await putScene(s);
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

  /// 成稿/ 里的文件（新的在前）。存了新的、或者要看外面改过的，先 [refreshDrafts]。
  List<Draft> get drafts => _drafts ??= hasLib ? listDrafts(lib) : [];

  void refreshDrafts() {
    _drafts = null;
    notifyListeners();
  }

  /// 正在路上的（还没出结果的）。
  List<Rec> get pending => recs.values.where((r) => r.stage != 'done').toList();

  /// 类别 → 这一类的场景（新的在前），按 cats 的顺序，没有的类别不出现。
  Map<String, List<Scene>> get byCategory {
    final out = <String, List<Scene>>{};
    for (final c in cats) {
      final l = scenes.where((s) => s.category == c.key).toList();
      if (l.isNotEmpty) out[c.key] = l;
    }
    final other = scenes.where((s) => !cats.any((c) => c.key == s.category)).toList();
    if (other.isNotEmpty) out['其他'] = other;
    return out;
  }
}
