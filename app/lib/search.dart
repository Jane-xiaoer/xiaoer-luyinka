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
