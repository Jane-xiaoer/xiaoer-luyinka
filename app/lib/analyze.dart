// 在这台设备上整理：逐字稿 → 切场景、认类别（时间地点人物事件）→ 每段按它那一类的模板写成笔记。
// 模型用设置里选的（小耳提供 / 自己的 key）；云端只负责转写，不经手整理结果。
import 'dart:convert';

import 'library.dart';
import 'note_doc.dart';
import 'llm.dart';
import 'store.dart';
import 'templates.dart';

typedef Chat = Future<String> Function(String system, String user);

const windowChars = 6000; // 一次喂给模型的转写长度（约 15 分钟连续说话）
const noteChars = 40000; // 一段最多喂这么多字（约 2 小时）
const minNoteChars = 150; // 太短的段不单独整理

class Analyzer {
  final Library lib;
  final Chat chat;
  Analyzer(this.lib, this.chat);

  factory Analyzer.of(Library lib, Llm llm) => Analyzer(lib, (s, u) => llm.chat(s, u));

  /// 一条录音的转写结果（{start, lines:[[钟点, 文字]]}）→ 场景（带笔记 body）。
  Future<List<Map<String, dynamic>>> run(String stem, Map<String, dynamic> res, {void Function(int done, int total)? progress}) async {
    final lines = [for (final x in (res['lines'] as List? ?? const [])) List<String>.from(x)];
    if (lines.isEmpty) return [];
    final t0 = startOf(res, lines);
    final secs = [for (final l in lines) _offset(t0, l[0])];
    final subjects = await lib.subjects();
    final vocab = lib.vocab(), people = lib.people(), fixes = lib.fixes();
    // iPhone 语音备忘录上起的标题（常常就是地点）：当线索给模型
    final memo = (res['memo'] ?? '').toString().trim();
    var raw = <Map<String, dynamic>>[];
    final marked = hasSpeakerMarks(lines);
    final aliases = aliasMap(lib.peopleEntries()); // 人员名单的叫法 → 名字：拆出来的「归谁」「人物」统一成名单上的名字
    // 现场会议我记的笔记（11-13）：切段时只当参考，按时间给这一窗的；没时间的行不进切段（技术总监：别让模型照笔记切碎）
    final notes = '${res['notes'] ?? ''}';
    final nmeta = metaOf(notes, res['notes_meta']);
    for (final (w, (lo, hi)) in windows(lines).indexed) {
      final mine = notes.trim().isEmpty ? '' : notesForModel(notes, nmeta, from: secs[lo] - 1, to: secs[hi] + 60);
      final user = [
        if (memo.isNotEmpty) '（这条录音在 iPhone 上的标题：「$memo」，可当地点、事件的线索）',
        if (mine.isNotEmpty) '（我开会时在这一截记的笔记，只当参考，帮你看出我在意什么；切场景还是按场合，「☐」开头的是我自己记的待办，不用再拆：\n$mine\n）',
        for (var i = lo; i <= hi; i++) feedLine(lines[i], marked),
      ].join('\n');
      for (final s in parseScenes(await chat(cutPrompt(subjects, vocab: vocab, people: people, fixes: fixes), user))) {
        var a = _clamp(t0, s['start'], secs[lo], secs[hi]), b = _clamp(t0, s['end'], secs[lo], secs[hi]);
        if (b < a) (a, b) = (b, a);
        raw.add(s
          ..['_a'] = a
          ..['_b'] = b
          ..['_w'] = w);
      }
    }
    raw.sort((x, y) => (x['_a'] as double).compareTo(y['_a'] as double));
    raw = joinWindows(raw);
    // 录音后半截只剩电视声、嗯啊时，模型常常整截不提，下面又会把最后一段一直算到录音结束：
    // 最后一段结束后隔了好久才又有字，那一截单独算杂音，别并进最后一段。
    if (raw.isNotEmpty) {
      final b = raw.last['_b'] as double;
      final k = secs.indexWhere((x) => x > b);
      if (k >= 0 && secs[k] - b >= joinGap) {
        raw.add({'_a': secs[k], '_b': secs.last, 'category': noiseCat, 'title': '无有效内容', 'event': ''});
      }
    }
    // 钟点只标每句的开头：最后一段按上面算会停在最后一句开口的时刻（整条只有一句时就成了 09:30–09:30），
    // 云端给了录音总长就让最后一段一直算到录音结束。
    final total = (res['seconds'] as num?)?.toDouble();
    final out = <Map<String, dynamic>>[];
    for (final (i, s) in raw.indexed) {
      final a = s['_a'] as double;
      var b = s['_b'] as double;
      if (i == raw.length - 1 && total != null && total > b) b = total;
      final next = i + 1 < raw.length ? raw[i + 1]['_a'] as double : double.infinity;
      final until = next > b + 1 ? next : b + 1;
      final start = t0.add(Duration(seconds: a.round())), end = t0.add(Duration(seconds: b.round()));
      var cat = catKey((s['category'] ?? '').toString());
      if (cat != noiseCat && !cats.any((c) => c.key == cat)) cat = '多人群聊';
      final text = [for (final (j, l) in lines.indexed) if (secs[j] >= a && secs[j] < until) l];
      out.add({
        'id': '${_stamp(start)}-lyk',
        'recording': stem,
        'offset': a,
        'start': _iso(start),
        'end': _iso(end),
        'category': cat,
        'title': _str(s['title'], 30),
        'event': _str(s['event']),
        'place': _str(s['place']),
        'people': {for (final x in _strs(s['people'])) aliases[x] ?? x}.toList(),
        'subject': cat == '现场调研' ? _str(s['subject'], 24) : '',
        'reminders': uniqTodos(_pairs(s['reminders'], 'when')),
        'actions': dedupeActions(uniqTodos([for (final a in tidyActions(s['actions'], text, solo: soloCats.contains(cat))) {...a, 'who': aliases['${a['who']}'] ?? a['who']}]), _pairs(s['reminders'], 'when')),
        'text': text,
        'body': '',
      });
    }
    final mine = lib.fixesFor(stem); // 这条录音我纠正过的：记住，不让模型重猜
    if (mine.isNotEmpty) {
      final ids = {for (final s in out) '${s['id']}'};
      for (final s in out) {
        for (final k in const ['actions', 'reminders']) {
          s[k] = applyFixes(List<Map<String, dynamic>>.from(s[k] as List), mine, sceneId: '${s['id']}', sceneIds: ids, list: k);
        }
      }
    }
    var done = 0;
    _res = res;
    _cut = out;
    try {
      for (final s in out) {
        progress?.call(done++, out.length);
        s['body'] = await note(Scene(s, stem));
      }
    } finally {
      _res = null;
      _cut = const [];
    }
    return out;
  }

  /// 这一段时间里我记的笔记（现场会议 / 随手记）：读这条录音的索引；整理途中（run）用正在切的段算范围。
  Map<String, dynamic>? _res;
  List<Map<String, dynamic>> _cut = const [];
  String _myNotes(Scene s) {
    if (!s.stem.startsWith('live') && !s.stem.startsWith('memo')) return '';
    Map<String, dynamic>? res = _res;
    var scenes = _cut;
    if (res == null) {
      try {
        final f = lib.data(s.stem);
        if (!f.existsSync()) return '';
        res = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()));
        scenes = [for (final x in (res['scenes'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
      } catch (_) {
        return '';
      }
    }
    final i = scenes.indexWhere((x) => x['id'] == s.id);
    final real = [for (final x in scenes) if (x['category'] != noiseCat) x['id']];
    final to = i >= 0 && i + 1 < scenes.length ? ((scenes[i + 1]['offset'] as num?)?.toDouble() ?? double.infinity) : double.infinity;
    return myNotesIn(res, s.offset, to, first: real.isNotEmpty && real.first == s.id);
  }

  /// 一段 → 按它那一类的模板写成的笔记（Markdown）。太短 / 杂音返回空。
  Future<String> note(Scene s) async {
    final cat = catKey(s.category);
    final text = [for (final l in s.text) '[${l[0]}] ${l[1]}'].join('\n');
    if (cat == noiseCat || text.length < minNoteChars) return '';
    final head = [
      '时间：${s.d['start'].toString().substring(0, 16).replaceAll('T', ' ')}–${s.d['end'].toString().substring(11, 16)}',
      if (s.place.isNotEmpty) '地点：${s.place}',
      if (s.people.isNotEmpty) '人物：${s.people.join('、')}',
      '事件：${s.event}',
      if (s.subject.isNotEmpty) '调研对象：${s.subject}',
    ].join('\n');
    var user = '## 这一段\n$head\n\n## 转写\n${text.length > noteChars ? text.substring(0, noteChars) : text}';
    final mine = _myNotes(s);
    if (mine.isNotEmpty) {
      user += '\n\n## 我当时记的笔记（这一段的）\n$mine\n\n'
          '（这是我自己边听边记的，是我觉得重要的：整理时以它为主线，我记的观点、判断、倾向都要留着，不要改成中立；'
          '转写只用来补全我没记全的细节、改错字。「☐」开头的是我的待办，照样列进待办。）';
    }
    if (cat == '现场调研' && s.subject.isNotEmpty) {
      final before = await lib.subjectHistory(s.subject, except: s.id);
      if (before.isNotEmpty) user += '\n\n## 以前对「${s.subject}」的调研记录（当背景，用来对比，不要抄进这次的关键信息）\n$before';
    }
    final out = await chat(notePrompt(await lib.template(cat), vocab: lib.vocab()), user);
    return out.replaceAll(RegExp(r'^```(markdown|md)?\s*|\s*```$'), '').trim();
  }
}

/// [from]-[to] 秒里我记的笔记；[first] 是第一段时另带上没记时间的行（不含「带上没做完的」）。
String myNotesIn(Map<String, dynamic> res, double from, double to, {bool first = false}) {
  final notes = '${res['notes'] ?? ''}';
  if (notes.trim().isEmpty) return '';
  final meta = metaOf(notes, res['notes_meta']);
  final timed = notesForModel(notes, meta, from: from, to: to);
  if (!first) return timed;
  final untimed = [
    for (final (j, l) in notes.split('\n').indexed)
      if (j < meta.length && meta[j].at == null && meta[j].src != 'carry' && l.trim().isNotEmpty)
        stripInline(l.replaceFirst(RegExp(r'^#{1,2} '), '')),
  ].join('\n');
  return [timed, untimed].where((x) => x.isNotEmpty).join('\n');
}

/// 开录时刻（墙上时间）：云端给的 start，没有就用第一行的钟点配今天。
DateTime startOf(Map<String, dynamic> res, List<List<String>> lines) {
  final s = (res['start'] ?? '').toString();
  if (s.length >= 19) return DateTime.parse(s.substring(0, 19));
  final now = DateTime.now();
  final p = lines.first[0].split(':').map(int.parse).toList();
  return DateTime(now.year, now.month, now.day, p[0], p[1], p.length > 2 ? p[2] : 0);
}

/// 按字数把逐字稿切成几窗（行号区间，含两头）。
List<(int, int)> windows(List<List<String>> lines, [int limit = windowChars]) {
  final out = <(int, int)>[];
  var lo = 0, n = 0;
  for (var i = 0; i < lines.length; i++) {
    n += lines[i][1].length + 12;
    if (n >= limit && i > lo) {
      out.add((lo, i));
      lo = i + 1;
      n = 0;
    }
  }
  if (lo < lines.length) out.add((lo, lines.length - 1));
  return out;
}

List<Map<String, dynamic>> parseScenes(String raw) {
  final m = RegExp(r'\{[\s\S]*\}').firstMatch(raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), ''));
  if (m == null) throw FormatException('模型没给 JSON：${raw.length > 200 ? raw.substring(0, 200) : raw}');
  final j = jsonDecode(m.group(0)!);
  final l = j is Map ? j['scenes'] : null;
  if (l is! List) throw const FormatException('JSON 里没有 scenes');
  return [for (final s in l) if (s is Map) Map<String, dynamic>.from(s)];
}

double _offset(DateTime t0, String clock) {
  final p = clock.split(':').map(int.tryParse).toList();
  if (p.length < 2 || p.any((x) => x == null)) return 0;
  final s = p[0]! * 3600 + p[1]! * 60 + (p.length > 2 ? p[2]! : 0);
  return ((s - (t0.hour * 3600 + t0.minute * 60 + t0.second)) % 86400).toDouble(); // 跨午夜也对
}

/// 模型抄回来的钟点 → 录音内秒数（抄错了就夹在这一窗里）。
double _clamp(DateTime t0, Object? clock, double lo, double hi) {
  final c = (clock ?? '').toString();
  if (!RegExp(r'^\d{1,2}:\d\d(:\d\d)?$').hasMatch(c)) return lo;
  final v = _offset(t0, c);
  return v < lo ? lo : (v > hi ? hi : v);
}

/// 两条待办说的是不是一回事：去掉标点空白后，两字一组的片段重合一半以上。
bool sameTodo(String a, String b) {
  Set<String> grams(String t) {
    final c = t.replaceAll(RegExp(r'[\s，。、,.（）()]'), '');
    return {for (var i = 0; i + 1 < c.length; i++) c.substring(i, i + 2)};
  }

  final x = grams(a), y = grams(b);
  if (x.isEmpty || y.isEmpty) return a == b;
  return x.intersection(y).length / (x.length < y.length ? x.length : y.length) >= 0.5;
}

/// 模型常把同一件事同时放进「行动」和「提醒」：跟某条提醒说的是一回事的行动去掉。
List<Map<String, dynamic>> dedupeActions(List<Map<String, dynamic>> actions, List<Map<String, dynamic>> reminders) =>
    [for (final a in actions) if (!reminders.any((r) => sameTodo(a['text'], r['text']))) a];

/// 同一件事只留一条（先出现的那条；后面重复的打过勾就把勾带上）。
List<Map<String, dynamic>> uniqTodos(List<Map<String, dynamic>> todos) {
  final out = <Map<String, dynamic>>[];
  for (final t in todos) {
    final i = out.indexWhere((o) => sameTodo('${o['text']}', '${t['text']}'));
    if (i < 0) {
      out.add(Map<String, dynamic>.from(t));
    } else if (t['done'] == true) {
      out[i]['done'] = true;
    }
  }
  return out;
}

/// 两段的类别是不是同一个场合：一样，或者一个开会一个我的分享（会上我讲方案也是这场会）。杂音不跟谁合。
bool sameOccasion(String a, String b) {
  final x = catKey(a), y = catKey(b);
  if (x == noiseCat || y == noiseCat) return false;
  return x == y || {x, y}.containsAll(const ['开会', '我的分享']);
}

/// 几段合起来的类别：取最前面那段的；最前面是我的分享、后面有开会就算开会。全是杂音还是杂音。
String mergedCategory(Iterable<String> categories) {
  final l = [for (final c in categories) catKey(c)].where((c) => c != noiseCat).toList();
  if (l.isEmpty) return noiseCat;
  return l.first == '我的分享' && l.contains('开会') ? '开会' : l.first;
}

const joinGap = 300.0; // 窗口边界两边的段隔得比这还久（秒），就不当成同一场

/// 逐字稿太长时是分几窗切的，窗口边界会把一场会硬切开：边界两边类别是同一个场合、
/// 人物有交集（有一边没认出人也算）、时间接得上，就合成一段。[raw] 按 _a 排好，每段带 _a/_b（秒）和 _w（第几窗）。
List<Map<String, dynamic>> joinWindows(List<Map<String, dynamic>> raw) {
  final out = <Map<String, dynamic>>[];
  for (final s in raw) {
    final p = out.lastOrNull;
    if (p != null &&
        s['_w'] == (p['_w'] as int) + 1 &&
        sameOccasion('${p['category'] ?? ''}', '${s['category'] ?? ''}') &&
        (s['_a'] as double) - (p['_b'] as double) <= joinGap &&
        _peopleMeet(_strs(p['people']), _strs(s['people']))) {
      final cat = mergedCategory(['${p['category']}', '${s['category']}']);
      final lead = catKey('${p['category']}') == cat ? p : s;
      out.last = {
        ...p,
        '_b': (s['_b'] as double) > (p['_b'] as double) ? s['_b'] : p['_b'],
        '_w': s['_w'],
        'category': cat,
        'title': lead['title'],
        'event': _joinText([p['event'], s['event']]),
        'place': _str(p['place']).isNotEmpty ? p['place'] : s['place'],
        'people': _union([p['people'], s['people']]),
        'subject': _str(p['subject']).isNotEmpty ? p['subject'] : s['subject'],
        'actions': [..._list(p['actions']), ..._list(s['actions'])],
        'reminders': [..._list(p['reminders']), ..._list(s['reminders'])],
      };
    } else {
      out.add(s);
    }
  }
  return out;
}

/// 手动合并：同一条录音里按时间排好、挨着的几段（中间夹的杂音也算进来）→ 一段。
/// id、录音位置跟最前面那段；类别见 [mergedCategory]；标题取类别跟合并后一样的第一段；
/// 人物取并集，待办合并去重，逐字稿按顺序接起来。body 清空，等按新类别的模板重新整理。不改动传进来的段。
Map<String, dynamic> mergeScenes(List<Map<String, dynamic>> parts) {
  final real = [for (final p in parts) if (catKey('${p['category'] ?? ''}') != noiseCat) p];
  if (real.isEmpty) throw ArgumentError('没有能合并的段');
  final cat = mergedCategory([for (final p in real) '${p['category']}']);
  final lead = real.firstWhere((p) => catKey('${p['category']}') == cat, orElse: () => real.first);
  String endOf(Map p) => '${p['end']}';
  final end = parts.map(endOf).reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  List<Map<String, dynamic>> todos(String k) =>
      [for (final p in real) for (final t in _list(p[k])) if (t is Map) Map<String, dynamic>.from(t)];
  final reminders = uniqTodos(todos('reminders'));
  return {
    ...real.first,
    'start': parts.first['start'],
    'end': end,
    'offset': parts.first['offset'] ?? real.first['offset'],
    'category': cat,
    'title': lead['title'] ?? '',
    'event': _joinText([for (final p in real) p['event']]),
    'place': real.map((p) => _str(p['place'])).firstWhere((x) => x.isNotEmpty, orElse: () => ''),
    'people': _union([for (final p in real) p['people']]),
    'subject': cat == '现场调研' ? real.map((p) => _str(p['subject'])).firstWhere((x) => x.isNotEmpty, orElse: () => '') : '',
    'reminders': reminders,
    'actions': dedupeActions(uniqTodos(todos('actions')), reminders),
    'text': [for (final p in parts) for (final l in _list(p['text'])) List<String>.from(l)],
    'body': '',
  };
}

bool _peopleMeet(List<String> a, List<String> b) => a.isEmpty || b.isEmpty || a.any(b.contains);

List _list(Object? x) => x is List ? x : const [];

List<String> _union(Iterable<Object?> lists) => [
      ...{for (final l in lists) ..._strs(l)},
    ];

String _joinText(Iterable<Object?> xs) {
  final l = [
    ...{for (final x in xs) if (_str(x).isNotEmpty) _str(x)},
  ];
  if (l.length < 2) return l.join();
  return '${l.map((x) => x.replaceAll(RegExp(r'[。；;.\s]+$'), '')).join('；')}。';
}

String _pad(int n) => n.toString().padLeft(2, '0');
String _iso(DateTime t) => '${t.year}-${_pad(t.month)}-${_pad(t.day)}T${_pad(t.hour)}:${_pad(t.minute)}:${_pad(t.second)}';
String _stamp(DateTime t) => '${t.year}${_pad(t.month)}${_pad(t.day)}-${_pad(t.hour)}${_pad(t.minute)}${_pad(t.second)}';

String _str(Object? x, [int? max]) {
  final s = (x ?? '').toString().trim();
  return max != null && s.length > max ? s.substring(0, max) : s;
}

List<String> _strs(Object? xs) => xs is List ? [for (final x in xs) if ('$x'.trim().isNotEmpty) '$x'.trim()] : [];

/// 说「我们提供 / 给你们 / 发给你」的是给东西的一方（多半甲方），兜底不清他的「别人」。
final _provides = RegExp(r'提供|给你|发给|发你');

/// 单数的「我」（后面不是「们」）。
final _singularI = RegExp(r'我(?!们)');

/// 逐字稿行首的说话人标注（「练：……」「我：……」，用户亲手标的或按声纹认出来的）。没标就是 null。
final _speakerMark = RegExp(r'^([^\s：:，。,、]{1,8})：');

/// 这条录音认过人没有：有「我：」开头的行（现场会议亲手标过 / 声纹认出了我）。
bool hasSpeakerMarks(List<List<String>> lines) => lines.any((l) => l[1].startsWith('我：'));

/// 喂给模型的一行。认过人的录音里，没标说话人的行补上「？：」——那是没认出的人，不是我。
/// 不补的话，模型看到「我我联系李航」里的「我」就当成录音卡主人要去做（2026-11-04 #244 就是这么错的）。
/// 只改喂给模型的，存下来的逐字稿不动。
String feedLine(List<String> l, bool marked) =>
    '[${l[0]}] ${marked && _speakerMark.firstMatch(l[1]) == null ? '？：' : ''}${l[1]}';

/// 这件事出自哪一行：钟点一样的那行；对不上就取它之前最近的一行。没钟点 / 找不到就是 null。
/// 给了 [what]（拆出来的那件事）时再核一下：模型偶尔把钟点抄成前后的行（11-04 回放 5 次错 2 次），
/// 那一行跟这件事几乎不沾边、这一段里另有一行明显说的就是它，就改用那一行。
List<String>? sourceLine(String t, List<List<String>> lines, {String what = ''}) {
  List<String>? byClock;
  if (RegExp(r'^\d{1,2}:\d\d(:\d\d)?$').hasMatch(t)) {
    final key = (t.split(':').length == 2 ? '$t:00' : t).padLeft(8, '0');
    for (final l in lines) {
      final c = l[0].padLeft(8, '0');
      if (c == key) {
        byClock = l;
        break;
      }
      if (c.compareTo(key) < 0) byClock = l;
    }
  }
  if (what.isEmpty) return byClock;
  final want = _grams(what);
  double score(List<String> l) => want.isEmpty ? 0 : want.intersection(_grams(l[1])).length / want.length;
  if (byClock != null && score(byClock) >= 0.3) return byClock;
  List<String>? best;
  var top = 0.0;
  for (final l in lines) {
    final s = score(l);
    if (s > top) (best, top) = (l, s);
  }
  return top >= 0.4 ? best : byClock;
}

Set<String> _grams(String t) {
  final c = t.replaceAll(RegExp(r'[\s，。、,.（）()！？!?：:“”"]'), '');
  return {for (var i = 0; i + 1 < c.length; i++) c.substring(i, i + 2)};
}

/// 我的纠正「记住」：同一条录音重新整理时，按 .xiaoer/纠正.jsonl 里这条录音的纠正，把对应的那件事改回我选的。
/// 找对应：出处钟点相差 60 秒以内，再挑内容最像的那件（两字片段重合最多）；同一钟点只有一件、字面不像也算。
/// 一件事可以有几条纠正（先改归属、再换项目），按写入先后都套上，同一种的后写的算数。改了的带 fixed，模型下次怎么猜都不影响。
/// - owner：who 改成我选的人（「我」或别人的名字；别人的照样留着，算「别人答应的事」）
/// - not_mine_task：不进我的待办（dismissed），who 原来是「我」/ 空的改成「别人」
/// - not_task：不算一件事（dismissed）
/// - project：换到我选的项目（project）
List<Map<String, dynamic>> applyFixes(List<Map<String, dynamic>> actions, List<Map<String, dynamic>> fixes,
    {String? sceneId, Set<String> sceneIds = const {}, String list = 'actions'}) {
  final out = [for (final a in actions) Map<String, dynamic>.from(a)];
  // 只认这个列表（行动 / 提醒）的纠正；记了是哪一段的，那一段还在就只套那一段（不串到同一条录音的别的段），
  // 那一段没了（重新切过场景、段号变了）才在整条录音里找
  fixes = [
    for (final f in fixes)
      if ('${f['list'] ?? 'actions'}' == list &&
          (f['scene'] == null || f['scene'] == sceneId || !sceneIds.contains('${f['scene']}')))
        f,
  ];
  double? secs(Object? t) {
    final m = RegExp(r'^(\d{1,2}):(\d\d)(?::(\d\d))?$').firstMatch('${t ?? ''}');
    return m == null ? null : int.parse(m[1]!) * 3600.0 + int.parse(m[2]!) * 60 + int.parse(m[3] ?? '0');
  }

  final claimed = <int, List<int>>{}; // 第几件事 → 套在它上面的纠正（按写入先后）
  for (final (fi, f) in fixes.indexed) {
    final ft = secs(f['t']);
    final want = _grams('${f['text'] ?? ''}');
    // 没钟点的纠正（旧数据里有的事没钟点）：整条录音里按内容找，要字面很像（下面 0.6）才算
    final near = [
      for (final (i, a) in out.indexed)
        if (a['from'] != 'note' && (ft == null || (secs(a['t']) != null && (secs(a['t'])! - ft).abs() <= 60))) i,
    ];
    int? best;
    var top = 0.0;
    for (final i in near) {
      final got = _grams('${out[i]['text']}');
      final s = want.isEmpty ? 0.0 : want.intersection(got).length / want.length;
      if (s > top) (best, top) = (i, s);
    }
    if (ft == null && top < 0.6) continue;
    if (ft != null && top < 0.25 && f['scene'] != sceneId) best = null; // 别的段 / 没记段的：字面得沾边
    // 同一钟点只有一件、字面不像也算：只限纠正记的正是这一段
    final sameClock = [for (final i in near) if (ft != null && f['scene'] != null && f['scene'] == sceneId && secs(out[i]['t']) == ft) i];
    if (best == null && sameClock.length == 1) best = sameClock.single;
    if (best == null) continue;
    (claimed[best] ??= []).add(fi);
  }
  for (final MapEntry(key: i, value: fis) in claimed.entries) {
    final a = out[i];
    for (final fi in fis) {
      final fix = fixes[fi]['fix'] is Map ? fixes[fi]['fix'] as Map : const {};
      switch ('${fix['kind']}') {
        case 'owner':
          a['who'] = '${fix['who'] ?? ''}';
          a.remove('dismissed');
          a['fixed'] = 'owner';
        case 'not_mine_task':
          if ('${a['who'] ?? ''}' == '我' || '${a['who'] ?? ''}'.isEmpty) a['who'] = '别人';
          a['dismissed'] = true;
          a['fixed'] = 'not_mine_task';
        case 'not_task':
          a['dismissed'] = true;
          a['fixed'] = 'not_task';
        case 'project':
          a['project'] = '${fix['project'] ?? ''}';
          continue; // 换项目不算确认
        default:
          continue;
      }
      a['confirmed'] = true;
    }
  }
  return out;
}

/// 人员名单 → 叫法到名字的对照（「阿西」→「阿星」「练总」→「练」）。名字本身不放进去；两个人用了同一个叫法就谁都不换。
Map<String, String> aliasMap(List<PersonEntry> people) {
  final m = <String, String>{}, dup = <String>{};
  // 叫法等于名单上任何一个人的名字（给李航补了「李总」、名单上另有一个李总）、或者是保留词，都不换：不能把别人的事串过去
  final names = {for (final p in people) p.name, '我', '别人', '我们', '你', '你们'};
  for (final p in people) {
    for (final a in p.aliases) {
      if (a.isEmpty || names.contains(a)) continue;
      if (m.containsKey(a) && m[a] != p.name) dup.add(a);
      m[a] = p.name;
    }
  }
  for (final d in dup) {
    m.remove(d);
  }
  return m;
}

/// 只有我一个人在说的类别：这里拆出来的事，模型没写归谁就是我的（回放里偶尔会空着）。
const soloCats = {'自言自语', '个人感悟'};

/// 模型拆出来的行动 → 去空、补上 speaker（谁说的）和 said（原话那一句）。
/// who = 这件事归谁去做（「我」= 录音卡主人；人名；说不清留空），由模型按上下文判断。
/// speaker 不信模型：以逐字稿行首的标注为准，没标就是空（没认出是谁）。「谁说的」≠「归谁」：
/// 别人说「我去对接」归他，别人说「你们做个样板」归我，所以两样分开存。
List<Map<String, dynamic>> tidyActions(Object? xs, List<List<String>> lines, {bool solo = false}) => [
      for (final a in _pairs(xs, 'who'))
        () {
          final src = sourceLine('${a['t']}', lines, what: '${a['text']}');
          final text = src?[1] ?? '';
          final m = _speakerMark.firstMatch(text);
          final said = (m == null ? text : text.substring(m.end)).trim();
          return {
            ...a,
            if (src != null) 't': src[0], // 钟点跟着出处走：点它就从这句播
            if (solo && '${a['who']}'.isEmpty) 'who': '我',
            // 没认出的人明说「我们来做 / 我们按你的来」、又没说单数「我」：可能是我这边的同事，别信「别人」，留空交给我确认
            // （11-04 22:41:05 回放 3/3 判成别人）。原话里没有「我们」的（如甲方说要交资料）不动
            if (m == null && a['who'] == '别人' && said.contains('我们') && !_singularI.hasMatch(said) && !_provides.hasMatch(said)) 'who': '',
            'speaker': m?.group(1) ?? '',
            'said': said.length > 80 ? '${said.substring(0, 80)}…' : said,
          };
        }(),
    ];

List<Map<String, dynamic>> _pairs(Object? xs, String extra) => [
      if (xs is List)
        for (final x in xs)
          if (x is Map && '${x['text'] ?? ''}'.trim().isNotEmpty)
            {'t': '${x['t'] ?? ''}', 'text': '${x['text']}'.trim(), extra: '${x[extra] ?? ''}'.trim()}
          else if (x is String && x.trim().isNotEmpty)
            {'t': '', 'text': x.trim(), extra: ''},
    ];
