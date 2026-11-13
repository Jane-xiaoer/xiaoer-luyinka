// 「我的笔记」的底子（11-13 方案 设计/备忘录笔记-20261113/方案.md）：笔记是纯文字，另存一份和行一一对应的「身份」
//   notes_meta: [{id, at, src, ref}]  id 稳定（改字、挪行不变）· at 录到第几秒 · src 谁写的 · ref「带上没做完的」对回的旧待办
// src：me 我打的 · clip 从原话挪来 · ai「顺一下」写的 · carry 带上的旧待办
// 笔记是唯一真相：笔记里的 ☐/☑ 由代码变成待办（不靠模型），待办里打勾 / 纠正都改回笔记那一行。
import 'dart:math';

import 'note_edit.dart';

class LineMeta {
  final String id;
  double? at;
  String src;
  String? ref;
  String? who; // 待确认里亲手定的归谁（名单外的人也认，芯 +46 P2）
  String? project; // 待确认里换的项目（重新整理也不丢，芯 +46 P3）
  bool? sync; // 带上的旧待办：上次对过去的勾（两边谁变了听谁的，芯 +46 P1）
  LineMeta(this.id, {this.at, this.src = 'me', this.ref, this.who, this.project, this.sync});

  Map<String, dynamic> toJson() => {
        'id': id,
        if (at != null) 'at': at,
        'src': src,
        if (ref != null) 'ref': ref,
        if (who != null) 'who': who,
        if (project != null) 'project': project,
        if (sync != null) 'sync': sync,
      };
  static LineMeta fromJson(dynamic j) {
    final m = j is Map ? j : const {};
    return LineMeta('${m['id'] ?? newLineId()}',
        at: (m['at'] as num?)?.toDouble(), src: '${m['src'] ?? 'me'}', ref: m['ref'] as String?,
        who: m['who'] as String?, project: m['project'] as String?, sync: m['sync'] as bool?);
  }

  LineMeta copy() => LineMeta(id, at: at, src: src, ref: ref, who: who, project: project, sync: sync);
}

final _rnd = Random();
int _seq = 0;
String newLineId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++ % 1296).toRadixString(36)}${_rnd.nextInt(1296).toRadixString(36)}';

/// 读存下来的身份；行数对不上（旧数据、外面改过文件）就补齐 / 截掉，补的算「不知道」。
List<LineMeta> metaOf(String text, dynamic raw) {
  final n = '\n'.allMatches(text).length + 1;
  final l = [for (final x in (raw is List ? raw : const [])) LineMeta.fromJson(x)];
  if (l.length > n) l.removeRange(n, l.length);
  while (l.length < n) {
    l.add(LineMeta(newLineId(), src: raw is List ? 'me' : 'old'));
  }
  return l;
}

/// 文字从 [oldText] 改成 [newText]：身份跟着行走。
/// 前后相同的行直接对上；中间文字一模一样的行认回去（挪行、「顺一下」没改的行）；剩下的按顺序认（改字的那行还是它）；
/// 多出来的是新行，记 [src] / [at]。
List<LineMeta> alignMeta(String oldText, List<LineMeta> old, String newText, {String src = 'me', double? at}) {
  final a = oldText.split('\n'), b = newText.split('\n');
  final om = old.length == a.length ? old : metaOf(oldText, [for (final m in old) m.toJson()]);
  var p = 0;
  while (p < a.length && p < b.length && a[p] == b[p]) {
    p++;
  }
  var q = 0;
  while (q < a.length - p && q < b.length - p && a[a.length - 1 - q] == b[b.length - 1 - q]) {
    q++;
  }
  final midOld = [for (var i = p; i < a.length - q; i++) i];
  final used = <int>{};
  final mid = <LineMeta?>[];
  for (var j = p; j < b.length - q; j++) {
    final hit = midOld.where((i) => !used.contains(i) && a[i] == b[j] && b[j].trim().isNotEmpty).firstOrNull;
    if (hit != null) used.add(hit);
    mid.add(hit == null ? null : om[hit]);
  }
  // 「顺一下」整篇重写（src: ai）：没对上的不按顺序硬认，都算新写的
  final left = src == 'ai' ? <int>[] : [for (final i in midOld) if (!used.contains(i)) i];
  var k = 0;
  for (var j = 0; j < mid.length; j++) {
    if (mid[j] != null) continue;
    final line = b[p + j];
    if (k < left.length) {
      final m = om[left[k++]];
      // 原来是空行、现在写上字了：算这一刻写的
      if (a[left[k - 1]].trim().isEmpty && line.trim().isNotEmpty) {
        m.at ??= at;
        if (m.src == 'old') m.src = src;
      }
      mid[j] = m;
    } else {
      mid[j] = LineMeta(newLineId(), at: line.trim().isEmpty ? null : at, src: src);
    }
  }
  return [...om.take(p), ...mid.cast<LineMeta>(), ...om.skip(a.length - q)];
}

/// 笔记里的一条待办
class NoteTodo {
  final String id; // 那一行的 id
  final int line;
  final String text, who; // who：名单上的正名；我的就是「我」
  final bool done;
  final String src;
  final String? ref;
  final double? at;
  const NoteTodo(this.id, this.line, this.text, this.who, this.done, this.src, this.ref, this.at);
}

final _ownerRe = RegExp(r'^([^\s:：，,。]{1,12})[:：]\s*(.+)$');

/// 笔记里的 ☐ / ☑ 行 → 待办。「名字：…」只有名字是名单上的名字 / 叫法（[aliases]：叫法→正名，含正名自己）才算他的事。
List<NoteTodo> noteTodos(String text, List<LineMeta> meta, Map<String, String> aliases) {
  final lines = text.split('\n');
  final out = <NoteTodo>[];
  var at = 0;
  for (final (i, raw) in lines.indexed) {
    final l = lineAt(text, at);
    at += raw.length + 1;
    if (l.kind != NoteKind.todo && l.kind != NoteKind.done) continue;
    var body = text.substring(l.bodyStart, l.end).trim();
    if (body.isEmpty) continue;
    final mt = i < meta.length ? meta[i] : LineMeta('l$i', src: 'old');
    var who = '我';
    final m = _ownerRe.firstMatch(body);
    // 「名字：」认名单上的；我在待确认里亲手定过的人（名单外也算）同样认
    if (m != null && (aliases.containsKey(m[1]) || (mt.who != null && m[1] == mt.who))) {
      who = aliases[m[1]] ?? m[1]!;
      body = m[2]!.trim();
    }
    out.add(NoteTodo(mt.id, i, stripInline(body), who, l.kind == NoteKind.done, mt.src, mt.ref, mt.at));
  }
  return out;
}

/// 去掉行内的 **加粗**、==重点== 符号（给待办、复制、喂模型用）
String stripInline(String s) =>
    s.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!).replaceAllMapped(RegExp(r'==(.+?)=='), (m) => m[1]!);

/// 复制给微信 / 飞书：去掉 # ** ==，☐☑ · 1. 留着；「带上没做完的」那几行和它的小标题不带（别把自己的欠账发给对方）。
String notesForCopy(String text, List<LineMeta> meta) {
  final lines = text.split('\n');
  final out = <String>[];
  for (final (i, l) in lines.indexed) {
    final m = i < meta.length ? meta[i] : null;
    if (m?.src == 'carry' || l.trim() == '## 上次没做完') continue;
    out.add(stripInline(l.replaceFirst(RegExp(r'^#{1,2} '), '')));
  }
  return out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// 存进 资料文件夹 的 md：☐→「- [ ]」、☑→「- [x]」、·→「- 」（Obsidian 之类能看），标题、加粗、高亮本来就是 Markdown。
String notesForMd(String text) => text
    .split('\n')
    .map((l) => l
        .replaceFirstMapped(RegExp(r'^(\s*)☐ '), (m) => '${m[1]}- [ ] ')
        .replaceFirstMapped(RegExp(r'^(\s*)☑ '), (m) => '${m[1]}- [x] ')
        .replaceFirstMapped(RegExp(r'^(\s*)· '), (m) => '${m[1]}- '))
    .join('\n')
    .trim();

/// 喂给模型的笔记：去掉格式符号，「带上没做完的」不喂（不是这场会的内容）。[from]-[to] 秒给了就只要时间落在里面的行。
String notesForModel(String text, List<LineMeta> meta, {double? from, double? to}) {
  final lines = text.split('\n');
  final out = <String>[];
  for (final (i, l) in lines.indexed) {
    final m = i < meta.length ? meta[i] : null;
    if (m?.src == 'carry' || l.trim().isEmpty) continue;
    if (from != null && to != null && (m?.at == null || m!.at! < from || m.at! >= to)) continue;
    out.add(stripInline(l.replaceFirst(RegExp(r'^#{1,2} '), '')));
  }
  return out.join('\n').trim();
}

// ───────── 改笔记的某一行（待办里打勾 / 纠正都回到这里） ─────────

int _lineOf(List<LineMeta> meta, String id) => meta.indexWhere((m) => m.id == id);

String _withLine(String text, int i, String Function(String) f) {
  final l = text.split('\n');
  if (i < 0 || i >= l.length) return text;
  l[i] = f(l[i]);
  return l.join('\n');
}

/// id 那一行打勾 / 取消。找不到就原样返回。
String setLineDone(String text, List<LineMeta> meta, String id, bool done) => _withLine(text, _lineOf(meta, id),
    (l) => l.replaceFirstMapped(RegExp(r'^(\s*)[☐☑] '), (m) => '${m[1]}${done ? '☑' : '☐'} '));

/// id 那一行改归谁：我 → 去掉「名字：」；别人 → 换成「名字：」。[aliases] 用来认原来的名字前缀。
String setLineOwner(String text, List<LineMeta> meta, String id, String who, Map<String, String> aliases) =>
    _withLine(text, _lineOf(meta, id), (l) {
      final m = RegExp(r'^(\s*[☐☑] )(.*)$').firstMatch(l);
      if (m == null) return l;
      var body = m[2]!;
      final o = _ownerRe.firstMatch(body);
      final i = _lineOf(meta, id);
      final before = i >= 0 ? meta[i].who : null;
      if (o != null && (aliases.containsKey(o[1]) || o[1] == before)) body = o[2]!;
      return '${m[1]}${who == '我' || who.isEmpty ? '' : '$who：'}$body';
    });

/// id 那一行「不是任务」：☐ 换成 · 要点（字留着）。
String demoteLine(String text, List<LineMeta> meta, String id) =>
    _withLine(text, _lineOf(meta, id), (l) => l.replaceFirstMapped(RegExp(r'^(\s*)[☐☑] '), (m) => '${m[1]}· '));

// ───────── 笔记待办写进这条录音的段里 ─────────

bool _veryLike(String a, String b) {
  Set<String> g(String t) {
    final c = t.replaceAll(RegExp(r'[\s，。、,.（）()：:]'), '');
    return {for (var i = 0; i + 1 < c.length; i++) c.substring(i, i + 2)};
  }

  final x = g(a), y = g(b);
  if (x.isEmpty || y.isEmpty) return a.trim() == b.trim();
  // 比 sameTodo 严：「联系李总 / 联系李航」不算一件（踩坑）
  return x.intersection(y).length / (x.length > y.length ? x.length : y.length) >= 0.8;
}

/// 把 res 里笔记的 ☐/☑ 变成待办，放进时间落在的那一段（没时间 / 落在杂音段 → 第一段不是杂音的）。
/// 以前生成的笔记待办先拿掉重来（笔记是唯一真相）；它们身上我改过的项目按行 id 带过来。
/// 模型拆出来、跟笔记待办几乎一样、归谁也一样的：并进笔记那条（项目、确认带过来），模型那条删掉。
/// carry（带上的旧待办）不新建，返回它们，由 Store 对回旧待办去打勾。
/// 返回 (新建了几条进待办, 几条进待确认, 带上的旧待办)。
(int, int, List<NoteTodo>) applyNoteTodos(Map<String, dynamic> res, Map<String, String> aliases, {String noise = '杂音'}) {
  final text = '${res['notes'] ?? ''}';
  final meta = metaOf(text, res['notes_meta']);
  final scenes = [for (final s in (res['scenes'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
  final kept = <String, Map<String, dynamic>>{}; // 行 id → 上次那条（带我改过的项目）
  for (final s in scenes) {
    final l = [for (final a in (s['actions'] as List? ?? const [])) Map<String, dynamic>.from(a as Map)];
    for (final a in l.where((a) => a['from'] == 'note')) {
      kept['${a['note_id']}'] = a;
    }
    s['actions'] = [for (final a in l) if (a['from'] != 'note') a];
  }
  final todos = noteTodos(text, meta, aliases);
  final carry = [for (final t in todos) if (t.src == 'carry' && t.ref != null) t];
  if (scenes.isEmpty) {
    res['scenes'] = scenes;
    res['notes_meta'] = [for (final m in meta) m.toJson()];
    return (0, 0, carry);
  }
  final real = [for (final s in scenes) if (s['category'] != noise) s];
  final home = real.isNotEmpty ? real.first : scenes.first;
  Map<String, dynamic> sceneAt(double? at) {
    if (at == null) return home;
    Map<String, dynamic>? hit;
    for (final s in scenes) {
      if (((s['offset'] as num?)?.toDouble() ?? 0) <= at) hit = s;
    }
    return hit == null || hit['category'] == noise ? home : hit;
  }

  var mine = 0, ask = 0;
  for (final t in todos) {
    if (t.src == 'carry' && t.ref != null) continue;
    final sure = t.src == 'me' || t.src == 'old';
    final a = <String, dynamic>{
      'text': t.text,
      'who': t.who,
      'from': 'note',
      'note_id': t.id,
      if (sure) 'confirmed': true,
      if (t.done) 'done': true,
    };
    final before = kept[t.id];
    final mt = meta[t.line];
    if (mt.project != null) {
      a['project'] = mt.project;
    } else if (before?['project'] != null) {
      a['project'] = before!['project'];
    }
    if (before?['confirmed'] == true) a['confirmed'] = true; // 待确认里点过「是我的」：别再问
    // 模型拆的同一件：带过项目 / 确认，删掉
    for (final s in scenes) {
      final l = List<Map<String, dynamic>>.from(s['actions'] as List);
      final dup = l.where((m) => m['from'] != 'note' && _veryLike('${m['text']}', t.text) && '${m['who'] ?? '我'}' == t.who).toList();
      for (final m in dup) {
        if (m['project'] != null) a['project'] ??= m['project'];
        if (m['confirmed'] == true && m['dismissed'] != true) a['confirmed'] = true;
        if (m['t'] != null) a['t'] = m['t'];
      }
      if (dup.isNotEmpty) s['actions'] = [for (final m in l) if (!dup.contains(m)) m];
    }
    final s = sceneAt(t.at);
    s['actions'] = [...(s['actions'] as List), a];
    if (a['confirmed'] == true) {
      mine++;
    } else {
      ask++;
    }
  }
  res['scenes'] = scenes;
  res['notes_meta'] = [for (final m in meta) m.toJson()]; // 旧笔记补出来的身份写回去，id 才稳（芯 +46 P4）
  return (mine, ask, carry);
}

/// 笔记第一行有字的当标题（去掉符号，最多 30 个字）；都没字就用 [fallback]。
String firstLineTitle(String text, String fallback) {
  for (final l in text.split('\n')) {
    final t = stripInline(l.replaceFirst(RegExp(r'^\s*(#{1,2} |[☐☑·] |\d{1,3}[.、] )'), '')).trim();
    if (t.isNotEmpty) return t.length > 30 ? t.substring(0, 30) : t;
  }
  return fallback;
}
