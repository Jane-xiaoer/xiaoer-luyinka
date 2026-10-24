// 本机存储。App 自己的文件夹里只放同步进度；整理好的内容都在用户的资料文件夹（library.dart）。
//   <dir>/state.json            设置 + 每条录音的状态
//   <dir>/raw/<stem>.opus.part  正在从卡上拉的（断了接着拉）
//   <dir>/raw/<stem>.opus       拉完、还没传上云的（转写好就删）
//   <资料>/.xiaoer/<stem>.json   逐字稿 + 场景（App 的索引）  <资料>/录音/<stem>.m4a  播放用
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'analyze.dart';
import 'drafts.dart';
import 'library.dart';
import 'templates.dart';
import 'todos.dart';

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
  int get todo => [...actions, ...reminders].where((t) => t['done'] != true).length; // 还没打勾的
  String get dayKey => d['start'].toString().substring(0, 10);
}

class Rec {
  String stem;
  int size;
  String stage; // card 在卡上 · pulling 拉取中 · pulled 已拉 · uploading · processing 云端转写 · transcribed 待整理 · analyzing 整理中 · done · error
  int got = 0; // 已拉字节
  int progress = 0; // 云端进度 0–100
  String? job;
  String? stream; // 边拉边传：云端那条的 id（拉完 finish 后挪到 job）
  int sent = 0; // 边拉边传：已经传上去几段
  bool noStream = false; // 云端那条坏了：这条改回拉完一次性上传
  double bps = 0; // 这一轮从卡上拉的实测速度（字节/秒），不存
  String? error;
  bool deletedOnCard = false;
  int tried = 0; // 上次整理失败的时间（ms），隔一会儿再试
  Rec(this.stem, this.size, this.stage);

  Map<String, dynamic> toJson() => {
        'stem': stem, 'size': size, 'stage': stage, 'got': got, 'progress': progress,
        'job': job, 'error': error, 'deletedOnCard': deletedOnCard, 'tried': tried,
        if (stream != null) 'stream': stream,
        if (sent > 0) 'sent': sent,
        if (noStream) 'noStream': true,
      };
  static Rec fromJson(Map<String, dynamic> j) => Rec(j['stem'], j['size'] ?? 0, j['stage'] ?? 'card')
    ..got = j['got'] ?? 0
    ..progress = j['progress'] ?? 0
    ..job = j['job']
    ..stream = j['stream']
    ..sent = j['sent'] ?? 0
    ..noStream = j['noStream'] ?? false
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
  /// 重新切分 / 合并后不在了的段：笔记文件删掉，调研对象文件和观点库里它那块拿掉。
  Future<void> putResult(String stem, Map<String, dynamic> res) async {
    final before = [for (final s in _scenes[stem] ?? const <Scene>[]) (s.id, s.d['file'] as String?, s.category, s.subject, s.dayKey)];
    final scenes = [for (final s in (res['scenes'] as List? ?? const [])) Scene(Map<String, dynamic>.from(s), stem)];
    for (final s in scenes.where((s) => !s.noise)) {
      await lib.writeNote(s);
    }
    final files = {for (final s in scenes) s.d['file']};
    for (final (id, file, cat, subject, _) in before) {
      if (file != null && !files.contains(file) && file.startsWith('${lib.path}/') && await File(file).exists()) {
        await File(file).delete();
      }
      final now = scenes.where((s) => s.id == id).firstOrNull;
      if (cat == '现场调研' && subject.isNotEmpty && (now?.category != cat || now?.subject != subject)) {
        await lib.forget(id, subject: subject);
      }
      if (cat == '个人感悟' && now?.category != cat) await lib.forget(id, ideas: true);
    }
    res['scenes'] = [for (final s in scenes) s.d];
    await result(stem).writeAsString(prettyJson(res));
    _scenes[stem] = scenes;
    for (final day in {for (final s in scenes) s.dayKey, for (final b in before) b.$5}) {
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

  /// 给一条待办打勾 / 取消：记在那一条里（done: true），写回索引，每日/ 里的 [ ] 跟着变。
  Future<void> setTodoDone(Todo t, bool done) async {
    final l = t.scene.d[t.kind];
    if (l is! List || t.index >= l.length) return;
    final m = Map<String, dynamic>.from(l[t.index]);
    if (done) {
      m['done'] = true;
    } else {
      m.remove('done');
    }
    // 换成新列表而不是改原列表那一格：原列表可能带着更窄的类型（比如 List<Map<String, String>>），塞不进 bool
    t.scene.d[t.kind] = [for (final (i, x) in l.indexed) i == t.index ? m : x];
    await putScene(t.scene);
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

  /// 同一条录音里排在 [s] 前面最近的一段（不算杂音）；没有就是 null。
  Scene? previousOf(Scene s) => _ordered(s.stem).where((x) => !x.noise && x.start.isBefore(s.start)).lastOrNull;

  /// 跟上一段合并（见 [mergeSpan]）。返回合好的那段。
  Future<Scene> mergeWithPrevious(Scene s, Future<String> Function(Scene) note) {
    final p = previousOf(s);
    if (p == null) throw StateError('这段前面没有能合并的段');
    return mergeSpan(p, s, note);
  }

  /// 整条录音当一段：从第一段到最后一段（不算头尾的杂音）全合起来。
  Future<Scene> mergeRecording(String stem, Future<String> Function(Scene) note) {
    final real = _ordered(stem).where((x) => !x.noise).toList();
    if (real.length < 2) throw StateError('这条录音只有一段');
    return mergeSpan(real.first, real.last, note);
  }

  /// 同一条录音里从 [first] 到 [last] 这几段（中间夹的杂音也算）合成一段，按合并后类别的模板重新整理（[note] 就是 Analyzer.note），
  /// 再写回：旧笔记文件删掉、写新的，每日 / 观点库 / 调研对象跟着更新。整理失败时原样不动，错误照抛。
  Future<Scene> mergeSpan(Scene first, Scene last, Future<String> Function(Scene) note) async {
    final stem = first.stem;
    final all = _ordered(stem);
    final i = all.indexWhere((x) => x.id == first.id), j = all.indexWhere((x) => x.id == last.id);
    if (i < 0 || j <= i) throw StateError('要合并的段不在同一条录音里，或者顺序不对');
    final span = all.sublist(i, j + 1);
    final m = Scene(mergeScenes([for (final x in span) x.d]), stem);
    m.d['body'] = await note(m);
    final res = readResult(stem);
    if (res == null) throw StateError('找不到这条录音的索引');
    final gone = {for (final x in span) x.id};
    res['scenes'] = [
      for (final x in all)
        if (x.id == first.id) m.d else if (!gone.contains(x.id)) x.d,
    ];
    await putResult(stem, res);
    return _scenes[stem]!.firstWhere((x) => x.id == m.id);
  }

  List<Scene> _ordered(String stem) => [...?_scenes[stem]]..sort((a, b) => a.start.compareTo(b.start));

  /// 一条录音的所有段（含杂音），整条拷贝逐字稿用。
  List<Scene> scenesOf(String stem) => [...?_scenes[stem]];

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
