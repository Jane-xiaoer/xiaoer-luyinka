// 搜索：左栏的即时搜索（不用模型），和对话里小耳回的 [[找到: …]] 那一行的解析。
import 'store.dart';
import 'templates.dart';

/// 统一大小写和全角：英文转小写、全角字母数字和全角空格转半角。逐字转换，长度不变（高亮位置靠这个对齐）。
String fold(String s) {
  final out = StringBuffer();
  for (final c in s.runes) {
    var x = c;
    if (x == 0x3000) {
      x = 0x20;
    } else if (x >= 0xFF01 && x <= 0xFF5E) {
      x -= 0xFEE0;
    }
    if (x >= 0x41 && x <= 0x5A) x += 0x20;
    out.writeCharCode(x);
  }
  return out.toString();
}

/// 搜索词：空格（含全角空格）分开，都要出现。
List<String> searchTerms(String query) => fold(query).split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

/// Markdown 记号去掉，换行变空格，片段好看一点。
String _plain(String md) => md
    .replaceAll(RegExp(r'^\s*#+\s*', multiLine: true), '')
    .replaceAll(RegExp(r'\*\*|__|`'), '')
    .replaceAll(RegExp(r'^\s*[-*]\s+', multiLine: true), '')
    .replaceAll(RegExp(r'\s*\n\s*'), ' ');

class Snippet {
  final String text;
  final List<(int, int)> marks; // 命中词在 text 里的 [起, 止)
  const Snippet(this.text, this.marks);
}

class SearchHit {
  final Scene scene;
  final int tier; // 0 标题 / 事件命中，1 笔记或其他信息命中，2 只有逐字稿命中
  final Snippet snippet;
  const SearchHit(this.scene, this.tier, this.snippet);
}

/// 一段里能搜的字段，按显示片段时的优先顺序排：先笔记、逐字稿（看得到上下文），再事件、标题、其他。
List<(String, String)> _fields(Scene s) => [
      ('body', _plain(s.body)),
      ('text', s.text.map((l) => l.length > 1 ? l[1] : '').join(' ')),
      ('event', s.event),
      ('title', s.title),
      ('place', s.place),
      ('people', s.people.join('、')),
      ('subject', s.subject),
      ('category', '${s.category} ${catFolder(s.category)}'),
    ];

/// 在 [text] 里第一个命中处前后各取约 [around] 字，标出片段里所有命中词。
Snippet snippetOf(String text, List<String> terms, {int around = 30}) {
  final f = fold(text);
  var at = -1, len = 0;
  for (final t in terms) {
    final i = f.indexOf(t);
    if (i >= 0 && (at < 0 || i < at)) {
      at = i;
      len = t.length;
    }
  }
  if (at < 0) return Snippet(text.length > around * 2 ? '${text.substring(0, around * 2)}…' : text, const []);
  final from = (at - around).clamp(0, text.length);
  final to = (at + len + around).clamp(0, text.length);
  final pre = from > 0 ? '…' : '';
  final cut = text.substring(from, to);
  final fc = f.substring(from, to);
  final marks = <(int, int)>[];
  for (final t in terms) {
    for (var i = fc.indexOf(t); i >= 0; i = fc.indexOf(t, i + t.length)) {
      marks.add((i + pre.length, i + pre.length + t.length));
    }
  }
  marks.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final m in marks) {
    if (merged.isNotEmpty && m.$1 <= merged.last.$2) {
      merged[merged.length - 1] = (merged.last.$1, m.$2 > merged.last.$2 ? m.$2 : merged.last.$2);
    } else {
      merged.add(m);
    }
  }
  return Snippet('$pre$cut${to < text.length ? '…' : ''}', merged);
}

/// 在所有场景里搜：每个词都要在这段的某个字段里出现。标题 / 事件命中的在前，其次笔记，最后只有逐字稿命中的；同档新的在前。
List<SearchHit> searchScenes(List<Scene> scenes, String query) {
  final terms = searchTerms(query);
  if (terms.isEmpty) return const [];
  final hits = <SearchHit>[];
  for (final s in scenes) {
    final fields = _fields(s);
    final folded = [for (final (_, v) in fields) fold(v)];
    if (!terms.every((t) => folded.any((v) => v.contains(t)))) continue;
    bool hit(Set<String> names) => [
          for (final (i, (k, _)) in fields.indexed)
            if (names.contains(k)) folded[i]
        ].any((v) => terms.any(v.contains));
    final tier = hit({'title', 'event'}) ? 0 : (hit({'body', 'place', 'people', 'subject', 'category'}) ? 1 : 2);
    final show = [for (final (i, f) in fields.indexed) if (terms.any(folded[i].contains)) f.$2].first;
    hits.add(SearchHit(s, tier, snippetOf(show, terms)));
  }
  hits.sort((a, b) => a.tier != b.tier ? a.tier.compareTo(b.tier) : b.scene.start.compareTo(a.scene.start));
  return hits;
}

String _when(Scene s) => s.d['start'].toString().substring(0, 16).replaceFirst('T', ' ');

/// 给模型的「全部记录目录」：一段一行，不带笔记和逐字稿；[scenes] 新的在前，超过 [max] 字只留最近的。
String catalogBlock(List<Scene> scenes, {int max = 30000}) {
  final b = StringBuffer();
  for (final s in scenes) {
    final line = [s.id, _when(s), s.category, s.title, s.event, s.people.join('、'), s.place]
        .map((x) => x.replaceAll(RegExp(r'[\n|]'), ' '))
        .join(' | ');
    if (b.length + line.length + 1 > max) break;
    b.writeln(line);
  }
  return b.toString().trimRight();
}

final _found = RegExp(r'[ \t]*[`*]*\[\[\s*找到\s*[:：]([^\]]*)\]\][`*]*[ \t]*');

/// 拆出回答里的 [[找到: id1, id2]]：返回去掉这一行的回答 + id（去重，最多 [max] 个，最相关的在前）。
(String, List<String>) parseFound(String answer, {int max = 5}) {
  final ids = <String>[];
  for (final m in _found.allMatches(answer)) {
    for (final id in m.group(1)!.split(RegExp(r'[,，、;；\s]+'))) {
      final x = id.replaceAll(RegExp(r'''^["'`]+|["'`]+$'''), '');
      if (x.isNotEmpty && !ids.contains(x)) ids.add(x);
    }
  }
  if (ids.isEmpty && !_found.hasMatch(answer)) return (answer, const []);
  final clean = answer.replaceAll(_found, '').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return (clean, ids.length > max ? ids.sublist(0, max) : ids);
}

// ───────── 对话里找东西：按我这句话粗筛原文（不用模型）─────────

/// 找东西时常说、但跟内容无关的话：先拿掉再切词。
const _fillers = [
  '帮我找一下', '帮我找找', '帮我找出来', '帮我找', '帮我看看', '帮我', '找一下', '找出来', '找找', '有没有',
  '我哪次说过', '我哪天说过', '我那次说过', '我有一次说过', '有一次', '我说过', '说过', '我提到过', '提到过', '我提过', '提过',
  '我记得', '记得', '好像', '哪一次', '哪一段', '哪一天', '哪次', '哪段', '哪天', '那一次', '那一段', '那次', '那段', '那天',
  '那个', '这个', '一个', '的时候', '时候', '什么', '怎么', '是不是', '有关', '关于', '的事', '事情', '一下', '我们', '你们', '他们',
];
const _particles = '的了吗呢吧啊呀嘛么我你他她它';

/// 我这句话 → 粗筛用的词：去掉虚词后，英文 / 数字整词，中文取 2–4 字的片段。
List<String> roughTerms(String query) {
  var q = fold(query);
  for (final f in _fillers) {
    q = q.replaceAll(f, ' ');
  }
  final out = <String>{};
  for (final m in RegExp(r'[a-z0-9][a-z0-9._+-]*').allMatches(q)) {
    if (m[0]!.length >= 2) out.add(m[0]!);
  }
  for (final m in RegExp(r'[\u4e00-\u9fff]+').allMatches(q)) {
    final runs = m[0]!.split(RegExp('[$_particles]')).where((r) => r.length >= 2);
    for (final r in runs) {
      for (var n = 2; n <= 4; n++) {
        for (var i = 0; i + n <= r.length; i++) {
          out.add(r.substring(i, i + n));
        }
      }
    }
  }
  return out.toList();
}

class RoughHit {
  final Scene scene;
  final double score;
  final String snippet; // 命中处前后的原文
  const RoughHit(this.scene, this.score, this.snippet);
}

/// 一段里能粗筛的全部文字：标题、事件、人物、地点、对象、笔记、逐字稿。
String _roughText(Scene s) => [
      s.title, s.event, s.people.join('、'), s.place, s.subject, _plain(s.body),
      s.text.map((l) => l.length > 1 ? l[1] : '').join(''),
    ].join('\n');

/// 在所有场景（含笔记和逐字稿）里粗筛：命中的词越多、越长、越少见，分越高。取前 [top] 段，每段带命中最密处前后 [around] 字。
List<RoughHit> roughSearch(List<Scene> scenes, String query, {int top = 8, int around = 150}) {
  final terms = roughTerms(query);
  if (terms.isEmpty || scenes.isEmpty) return const [];
  final texts = [for (final s in scenes) _roughText(s)];
  final folded = [for (final t in texts) fold(t)];
  final df = {for (final t in terms) t: folded.where((f) => f.contains(t)).length};
  final n = scenes.length;
  final hits = <RoughHit>[];
  for (final (i, s) in scenes.indexed) {
    final f = folded[i];
    final got = [for (final t in terms) if (df[t]! > 0 && f.contains(t)) t];
    if (got.isEmpty) continue;
    var score = 0.0;
    for (final t in got) {
      score += t.length * (1 + (n / df[t]!)).clamp(1, 50).toDouble();
    }
    hits.add(RoughHit(s, score, _densest(texts[i], f, got, around)));
  }
  hits.sort((a, b) => a.score != b.score ? b.score.compareTo(a.score) : b.scene.start.compareTo(a.scene.start));
  return hits.length > top ? hits.sublist(0, top) : hits;
}

/// 命中最密的那一处（前后各 [around] 字内命中的不同词最多，一样多取更长的词）。
String _densest(String text, String f, List<String> got, int around) {
  final at = <(int, String)>[];
  for (final t in got) {
    for (var i = f.indexOf(t), k = 0; i >= 0 && k < 20; i = f.indexOf(t, i + t.length), k++) {
      at.add((i, t));
    }
  }
  var best = at.first.$1, bestScore = -1;
  for (final (p, _) in at) {
    final seen = {for (final (q, t) in at) if ((q - p).abs() <= around) t};
    final sc = seen.fold<int>(0, (a, t) => a + t.length * t.length);
    if (sc > bestScore) {
      bestScore = sc;
      best = p;
    }
  }
  final from = (best - around).clamp(0, text.length), to = (best + around).clamp(0, text.length);
  return '${from > 0 ? '…' : ''}${text.substring(from, to).replaceAll(RegExp(r'\s*\n\s*'), ' ')}${to < text.length ? '…' : ''}';
}

/// 给模型的「可能相关的原文片段」：每段一行头（id | 日期 钟点 | 标题）+ 片段；超过 [max] 字就少放几段。
String roughBlock(List<Scene> scenes, String query, {int top = 8, int max = 8000}) {
  final b = StringBuffer();
  for (final h in roughSearch(scenes, query, top: top)) {
    final s = h.scene;
    final item = '- ${s.id} | ${_when(s)} | ${s.title}\n  ${h.snippet}\n';
    if (b.length + item.length > max) break;
    b.write(item);
  }
  return b.toString().trimRight();
}
