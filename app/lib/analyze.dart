// 在这台设备上整理：逐字稿 → 切场景、认类别（时间地点人物事件）→ 每段按它那一类的模板写成笔记。
// 模型用设置里选的（小耳提供 / 自己的 key）；云端只负责转写，不经手整理结果。
import 'dart:convert';

import 'library.dart';
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
    final vocab = lib.vocab();
    var raw = <Map<String, dynamic>>[];
    for (final (w, (lo, hi)) in windows(lines).indexed) {
      final user = [for (var i = lo; i <= hi; i++) '[${lines[i][0]}] ${lines[i][1]}'].join('\n');
      for (final s in parseScenes(await chat(cutPrompt(subjects, vocab: vocab), user))) {
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
        'people': _strs(s['people']),
        'subject': cat == '现场调研' ? _str(s['subject'], 24) : '',
        'reminders': uniqTodos(_pairs(s['reminders'], 'when')),
        'actions': dedupeActions(uniqTodos(_pairs(s['actions'], 'who')), _pairs(s['reminders'], 'when')),
        'text': [for (final (j, l) in lines.indexed) if (secs[j] >= a && secs[j] < until) l],
        'body': '',
      });
    }
    var done = 0;
    for (final s in out) {
      progress?.call(done++, out.length);
      s['body'] = await note(Scene(s, stem));
    }
    return out;
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
    if (cat == '现场调研' && s.subject.isNotEmpty) {
      final before = await lib.subjectHistory(s.subject, except: s.id);
      if (before.isNotEmpty) user += '\n\n## 以前对「${s.subject}」的调研记录（当背景，用来对比，不要抄进这次的关键信息）\n$before';
    }
    final out = await chat(notePrompt(await lib.template(cat), vocab: lib.vocab()), user);
    return out.replaceAll(RegExp(r'^```(markdown|md)?\s*|\s*```$'), '').trim();
  }
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

List<Map<String, dynamic>> _pairs(Object? xs, String extra) => [
      if (xs is List)
        for (final x in xs)
          if (x is Map && '${x['text'] ?? ''}'.trim().isNotEmpty)
            {'t': '${x['t'] ?? ''}', 'text': '${x['text']}'.trim(), extra: '${x[extra] ?? ''}'.trim()}
          else if (x is String && x.trim().isNotEmpty)
            {'t': '', 'text': x.trim(), extra: ''},
    ];
