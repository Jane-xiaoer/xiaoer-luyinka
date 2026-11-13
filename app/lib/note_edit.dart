// 现场会议右边「我的笔记」：像备忘录那样记（Jane 11-13 要）。
// 笔记仍是纯文字（复制能直接粘微信 / 飞书，「顺一下」也照旧），列表靠行首的符号：
//   ☐ 待办（点一下勾上 → ☑，变灰划掉）　· 要点　1. 编号
// 回车自动接着下一条，空的一条再回车就结束列表；Tab / Shift+Tab 缩进；「- 」「[] 」打出来自动变成列表。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

enum NoteKind { plain, todo, done, bullet, number }

const _indentUnit = '    ';
final _lineRe = RegExp(r'^([ \t]*)(☐ |☑ |· |(\d{1,3})[.、] )?');

class NoteLine {
  final int start, end; // 这一行在全文里的范围（不含换行）
  final String indent;
  final NoteKind kind;
  final int markLen; // 行首符号（含后面的空格）的长度
  final int? n; // 编号
  const NoteLine(this.start, this.end, this.indent, this.kind, this.markLen, this.n);
  int get bodyStart => start + indent.length + markLen;
  bool get isList => kind != NoteKind.plain;
}

NoteLine lineAt(String text, int offset) {
  final o = offset.clamp(0, text.length);
  final start = o == 0 ? 0 : text.lastIndexOf('\n', o - 1) + 1;
  var end = text.indexOf('\n', o);
  if (end < 0) end = text.length;
  final m = _lineRe.firstMatch(text.substring(start, end))!;
  final mark = m[2];
  final kind = switch (mark) {
    null => NoteKind.plain,
    '☐ ' => NoteKind.todo,
    '☑ ' => NoteKind.done,
    '· ' => NoteKind.bullet,
    _ => NoteKind.number,
  };
  return NoteLine(start, end, m[1]!, kind, mark?.length ?? 0, m[3] == null ? null : int.parse(m[3]!));
}

String markOf(NoteKind k, [int n = 1]) => switch (k) {
  NoteKind.plain => '',
  NoteKind.todo => '☐ ',
  NoteKind.done => '☑ ',
  NoteKind.bullet => '· ',
  NoteKind.number => '$n. ',
};

TextEditingValue _replace(TextEditingValue v, int from, int to, String with_, {int? caret}) {
  final t = v.text.replaceRange(from, to, with_);
  int shift(int o) => o <= from ? o : (o >= to ? o + with_.length - (to - from) : from + with_.length);
  return TextEditingValue(
    text: t,
    selection: caret != null
        ? TextSelection.collapsed(offset: caret)
        : TextSelection(baseOffset: shift(v.selection.baseOffset), extentOffset: shift(v.selection.extentOffset)),
  );
}

/// 打字以后要不要顺手改一下：回车接着列表、空条回车结束列表、「- 」「[] 」变成列表符号。
/// 只管「在光标处打进一个字」这种改动（粘贴、输入法组字时不动）；不用改就返回 null。
TextEditingValue? afterTyping(TextEditingValue old, TextEditingValue now) {
  if (now.composing.isValid || !now.selection.isCollapsed) return null;
  if (now.text.length != old.text.length + 1) return null;
  final at = now.selection.baseOffset - 1; // 刚打进来的那个字
  if (at < 0 || now.text.replaceRange(at, at + 1, '') != old.text) return null;
  final ch = now.text[at];

  if (ch == '\n') {
    final prev = lineAt(now.text, at);
    if (!prev.isList) return null;
    if (now.text.substring(prev.bodyStart, prev.end).trim().isEmpty && prev.end == at) {
      // 空的一条再回车：缩进的先退一级，顶格的就结束列表（去掉符号和这个回车）
      if (prev.indent.isNotEmpty) {
        final less = prev.indent.length >= _indentUnit.length ? prev.indent.substring(_indentUnit.length) : '';
        return _replace(now, prev.start, at + 1, less + now.text.substring(prev.start + prev.indent.length, prev.end),
            caret: prev.start + less.length + prev.markLen);
      }
      return _replace(now, prev.start, at + 1, '', caret: prev.start);
    }
    final next = prev.kind == NoteKind.done ? NoteKind.todo : prev.kind;
    final ins = prev.indent + markOf(next, (prev.n ?? 0) + 1);
    return _replace(now, at + 1, at + 1, ins, caret: at + 1 + ins.length);
  }

  if (ch == ' ') {
    final l = lineAt(now.text, at);
    if (l.isList) return null;
    final head = now.text.substring(l.start + l.indent.length, at + 1);
    final to = switch (head) { '- ' || '* ' || '• ' => NoteKind.bullet, '[] ' || '[ ] ' => NoteKind.todo, _ => null };
    if (to == null) return null;
    final from = l.start + l.indent.length;
    return _replace(now, from, at + 1, markOf(to), caret: from + markOf(to).length);
  }
  return null;
}

/// 点在 ☐ / ☑ 上（光标落在符号前后）就勾上 / 取消，返回改好的；没点在框上返回 null。
TextEditingValue? toggleAtTap(TextEditingValue v) {
  if (!v.selection.isCollapsed) return null;
  final o = v.selection.baseOffset;
  final l = lineAt(v.text, o);
  if (l.kind != NoteKind.todo && l.kind != NoteKind.done) return null;
  final box = l.start + l.indent.length;
  if (o != box && o != box + 1) return null;
  final to = l.kind == NoteKind.todo ? '☑' : '☐';
  return _replace(v, box, box + 1, to, caret: l.end);
}

/// 选中的几行（没选就是光标那一行）都改成 [k]；已经全是 [k] 再按一次就去掉符号。
/// 勾选框：☐ 和 ☑ 都算「待办」。
TextEditingValue setKind(TextEditingValue v, NoteKind k) {
  final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
  final lines = _linesIn(v.text, sel);
  bool same(NoteLine l) => k == NoteKind.todo ? (l.kind == NoteKind.todo || l.kind == NoteKind.done) : l.kind == k;
  final off = lines.every(same);
  var out = v;
  for (var i = lines.length - 1; i >= 0; i--) {
    // 倒着改，前面的位置不变；编号按正序 1、2、3
    final l = lines[i];
    final from = l.start + l.indent.length;
    final keepDone = k == NoteKind.todo && l.kind == NoteKind.done;
    final mark = off ? '' : (keepDone ? '☑ ' : markOf(k, i + 1));
    out = _replace(out, from, from + l.markLen, mark);
  }
  if (v.selection.isCollapsed) {
    // 光标放到这一行正文后面（空行就在符号后面），接着打字
    final l = lineAt(out.text, lines.first.start);
    return out.copyWith(selection: TextSelection.collapsed(offset: l.end));
  }
  return out;
}

/// Tab / Shift+Tab：选中的几行整体缩进 / 退回一级。
TextEditingValue indent(TextEditingValue v, {bool back = false}) {
  final lines = _linesIn(v.text, v.selection);
  var out = v;
  for (final l in lines.reversed) {
    if (!back) {
      out = _replace(out, l.start, l.start, _indentUnit);
    } else if (l.indent.isNotEmpty) {
      final cut = l.indent.startsWith(_indentUnit) ? _indentUnit.length : (l.indent.startsWith('\t') ? 1 : l.indent.length);
      out = _replace(out, l.start, l.start + cut, '');
    }
  }
  return out;
}

/// ⇧⌘T 标题 / ⇧⌘H 小标题：选中的几行变成「# 」/「## 」（去掉列表符号）；已经是这一级再按就变回正文。
TextEditingValue toggleHeading(TextEditingValue v, int level) {
  final lines = _linesIn(v.text, v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length));
  final mark = '${'#' * level} ';
  bool isIt(NoteLine l) => v.text.substring(l.start, l.end).startsWith(mark) && !v.text.substring(l.start, l.end).startsWith('$mark#');
  final off = lines.every(isIt);
  var out = v;
  for (final l in lines.reversed) {
    final line = out.text.substring(l.start, l.end);
    final h = RegExp(r'^#{1,2} ').firstMatch(line);
    final cut = h != null ? h.end : l.indent.length + l.markLen;
    out = _replace(out, l.start, l.start + cut, off ? '' : mark);
  }
  if (v.selection.isCollapsed) {
    return out.copyWith(selection: TextSelection.collapsed(offset: lineAt(out.text, lines.first.start).end));
  }
  return out;
}

/// ⌘B 加粗「**」/ ⇧⌘E 重点「==」：选中的字两边加上；已经包着就去掉；没选字就放一对、光标在中间。
TextEditingValue toggleWrap(TextEditingValue v, String mark) {
  final sel = v.selection;
  if (!sel.isValid) return v;
  final a = sel.start, b = sel.end, t = v.text, n = mark.length;
  if (a >= n && b + n <= t.length && t.substring(a - n, a) == mark && t.substring(b, b + n) == mark) {
    final out = t.replaceRange(b, b + n, '').replaceRange(a - n, a, '');
    return TextEditingValue(text: out, selection: TextSelection(baseOffset: a - n, extentOffset: b - n));
  }
  final inner = t.substring(a, b);
  if (inner.length >= 2 * n && inner.startsWith(mark) && inner.endsWith(mark)) {
    final x = inner.substring(n, inner.length - n);
    return TextEditingValue(text: t.replaceRange(a, b, x), selection: TextSelection(baseOffset: a, extentOffset: a + x.length));
  }
  final out = t.replaceRange(a, b, '$mark$inner$mark');
  return TextEditingValue(
    text: out,
    selection: sel.isCollapsed ? TextSelection.collapsed(offset: a + n) : TextSelection(baseOffset: a + n, extentOffset: b + n),
  );
}

/// 找字：[from] 之后下一个（到底了从头来）；没有返回 null。
TextSelection? findNext(String text, String q, int from) {
  if (q.isEmpty) return null;
  var i = text.indexOf(q, from.clamp(0, text.length));
  if (i < 0) i = text.indexOf(q);
  return i < 0 ? null : TextSelection(baseOffset: i, extentOffset: i + q.length);
}

/// 光标前面正在打「@名字」：返回 (@ 的位置, 打了的字)；不是就 null。
(int, String)? mentionAt(TextEditingValue v) {
  if (!v.selection.isCollapsed || v.composing.isValid && v.composing.start < v.selection.baseOffset - 12) return null;
  final o = v.selection.baseOffset;
  final l = lineAt(v.text, o);
  final m = RegExp(r'[@＠]([^\s@＠:：，,]{0,12})$').firstMatch(v.text.substring(l.start, o));
  if (m == null) return null;
  return (l.start + m.start, m[1]!);
}

/// 选了人：把「@打的字」换成「名字：」（在一条的开头，表示这条是他的事）或「名字 」（句子中间）。
TextEditingValue insertMention(TextEditingValue v, int at, String name) {
  final l = lineAt(v.text, at);
  final head = at == l.bodyStart;
  final ins = head ? '$name：' : '$name ';
  return _replace(v, at, v.selection.baseOffset, ins, caret: at + ins.length);
}

/// 人名筛选：名字、叫法、公司、项目里含打的字（不分大小写），名字开头对上的排前面；最多 [max] 个。
List<String> matchPeople(List<(String, List<String>, String)> roster, String q, {int max = 8}) {
  final k = q.toLowerCase();
  final hits = [
    for (final (name, aliases, group) in roster)
      if (k.isEmpty || [name, ...aliases, group].any((x) => x.toLowerCase().contains(k))) name,
  ];
  hits.sort((a, b) => (a.toLowerCase().startsWith(k) ? 0 : 1).compareTo(b.toLowerCase().startsWith(k) ? 0 : 1));
  return hits.take(max).toList();
}

/// ⌃⌘↑ / ⌃⌘↓：选中的几行（没选就是光标那行）整体跟上 / 下一行换位置，光标跟着走。
TextEditingValue moveLines(TextEditingValue v, {required bool up}) {
  final lines = _linesIn(v.text, v.selection);
  final a = lines.first.start, b = lines.last.end;
  if (up && a == 0) return v;
  if (!up && b >= v.text.length) return v;
  final block = v.text.substring(a, b);
  if (up) {
    final p = lineAt(v.text, a - 1);
    final other = v.text.substring(p.start, p.end);
    final t = v.text.replaceRange(p.start, b, '$block\n$other');
    final d = p.start - a;
    return TextEditingValue(text: t, selection: TextSelection(baseOffset: v.selection.baseOffset + d, extentOffset: v.selection.extentOffset + d));
  }
  final n = lineAt(v.text, b + 1);
  final other = v.text.substring(n.start, n.end);
  final t = v.text.replaceRange(a, n.end, '$other\n$block');
  final d = other.length + 1;
  return TextEditingValue(text: t, selection: TextSelection(baseOffset: v.selection.baseOffset + d, extentOffset: v.selection.extentOffset + d));
}

List<NoteLine> _linesIn(String text, TextSelection sel) {
  final a = sel.start.clamp(0, text.length), b = sel.end.clamp(0, text.length);
  final out = <NoteLine>[];
  var l = lineAt(text, a);
  while (true) {
    out.add(l);
    if (l.end >= b || l.end >= text.length) break;
    l = lineAt(text, l.end + 1);
  }
  return out;
}

/// 显示：勾掉的待办变灰划掉，☐ / · / 编号用主题色，正文照常。存下来的还是纯文字。
class NotesController extends TextEditingController {
  NotesController({super.text});

  /// 点了第 offset 个字上的框（编辑器接上，打勾 / 取消）
  void Function(int offset)? onBox;

  /// ⌘F 在找的字：找到的地方淡淡标一下
  String _find = '';
  String get find => _find;
  set find(String v) {
    if (v == _find) return;
    _find = v;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final size = style?.fontSize ?? 15;
    final comp = withComposing && value.composing.isValid ? value.composing : TextRange.empty;
    final kids = <InlineSpan>[];
    // 一段文字带一个样式；输入法组字的那一截切出来加下划线（组字时样式照上，字号不跳）
    void put0(int from, int to, [TextStyle? st]) {
      if (to <= from) return;
      if (!comp.isValid || comp.end <= from || comp.start >= to) {
        kids.add(TextSpan(text: text.substring(from, to), style: st));
        return;
      }
      final cs = comp.start.clamp(from, to), ce = comp.end.clamp(from, to);
      if (cs > from) kids.add(TextSpan(text: text.substring(from, cs), style: st));
      kids.add(TextSpan(text: text.substring(cs, ce), style: (st ?? const TextStyle()).copyWith(decoration: TextDecoration.underline)));
      if (to > ce) kids.add(TextSpan(text: text.substring(ce, to), style: st));
    }

    // 找字的命中：切开加底色
    final hits = <(int, int)>[];
    if (find.isNotEmpty) {
      for (var i = text.indexOf(find); i >= 0; i = text.indexOf(find, i + find.length)) {
        hits.add((i, i + find.length));
      }
    }
    void put(int from, int to, [TextStyle? st]) {
      var at = from;
      for (final (hs, he) in hits) {
        if (he <= at || hs >= to) continue;
        final s0 = hs < at ? at : hs, e0 = he > to ? to : he;
        put0(at, s0, st);
        put0(s0, e0, (st ?? const TextStyle()).copyWith(backgroundColor: const Color(0x5542A5F5)));
        at = e0;
      }
      put0(at, to, st);
    }

    final faintMark = TextStyle(color: K.faint.withValues(alpha: 0.6), fontSize: size * 0.7, fontWeight: FontWeight.w400);
    var at = 0;
    while (at <= text.length) {
      final l = lineAt(text, at);
      final done = l.kind == NoteKind.done;
      final h = RegExp(r'^(#{1,2}) ').firstMatch(text.substring(l.start, l.end));
      var bodyStyle = done ? TextStyle(color: K.faint, decoration: TextDecoration.lineThrough, decorationColor: K.faint) : null;
      var from = l.start;
      if (h != null) {
        // 标题「# 」/ 小标题「## 」：符号淡小，字变大加粗
        put(from, from + h.end, faintMark);
        from += h.end;
        bodyStyle = TextStyle(fontSize: size * (h[1]!.length == 1 ? 1.45 : 1.18), fontWeight: FontWeight.w700, height: 1.5);
      } else if (l.isList) {
        final markStart = l.start + l.indent.length;
        put(l.start, markStart);
        if (l.kind == NoteKind.todo || done) {
          // ☐ / ☑ 是一个字，画成一个勾选框（占位也正好一个字，光标位置对得上）；后面的空格照常
          kids.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onBox?.call(markStart),
                child: Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      size: size * 1.25, color: done ? K.accent : K.mute),
                ),
              ),
            ),
          ));
          put(markStart + 1, l.bodyStart);
        } else {
          put(markStart, l.bodyStart, TextStyle(color: K.accent, fontWeight: FontWeight.w700));
        }
        from = l.bodyStart;
      }
      // 正文里的 **加粗**、==重点==：符号淡小，中间加粗 / 黄底
      final body = text.substring(from, l.end);
      var i = 0;
      for (final m in RegExp(r'\*\*(.+?)\*\*|==(.+?)==').allMatches(body)) {
        put(from + i, from + m.start, bodyStyle);
        final inner = m[1] != null
            ? (bodyStyle ?? const TextStyle()).copyWith(fontWeight: FontWeight.w700)
            : (bodyStyle ?? const TextStyle()).copyWith(backgroundColor: const Color(0x66FFD54F));
        put(from + m.start, from + m.start + 2, faintMark);
        put(from + m.start + 2, from + m.end - 2, inner);
        put(from + m.end - 2, from + m.end, faintMark);
        i = m.end;
      }
      put(from + i, l.end, bodyStyle);
      if (l.end >= text.length) break;
      put(l.end, l.end + 1);
      at = l.end + 1;
    }
    return TextSpan(style: style, children: kids);
  }
}

/// 右边的笔记本：上面一条小工具（待办 / 要点 / 编号），下面直接打字。
class NotesEditor extends StatefulWidget {
  final NotesController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final String hint;
  final double fontSize; // ⌘= / ⌘- 调，外面记住
  final ValueChanged<double>? onFontSize;
  /// 打「@」时挑人：(名字, 叫法, 公司或项目)
  final List<(String, List<String>, String)> people;
  /// 「带上没做完的事」按钮（会上才有）
  final VoidCallback? onCarry;
  /// true：撑满给的高度（会上右边）；false：跟着字长高（会后嵌在页面里）
  final bool expand;
  const NotesEditor(
      {super.key, required this.controller, required this.focusNode, required this.onChanged, required this.hint,
      this.fontSize = 15, this.onFontSize, this.people = const [], this.onCarry, this.expand = true});
  @override
  State<NotesEditor> createState() => _NotesEditorState();
}

class _NotesEditorState extends State<NotesEditor> {
  // 每次改动前后的样子：onChanged 里拿「改之前」对比，才知道刚打进来的是哪个字
  late TextEditingValue _prev = widget.controller.value, _cur = widget.controller.value;
  NotesController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_track);
    c.onBox = _box;
  }

  @override
  void dispose() {
    _findText.dispose();
    _findFocus.dispose();
    c.removeListener(_track);
    c.onBox = null;
    super.dispose();
  }

  void _box(int at) {
    final t = toggleAtTap(c.value.copyWith(selection: TextSelection.collapsed(offset: at), composing: TextRange.empty));
    if (t != null) _set(t);
  }

  (int, String)? _mention;

  void _track() {
    if (c.value == _cur) return;
    _prev = _cur;
    _cur = c.value;
    final m = widget.people.isEmpty ? null : mentionAt(c.value);
    if (m != _mention && mounted) setState(() => _mention = m);
  }

  void _pick(String name) {
    final m = _mention;
    if (m == null) return;
    _set(insertMention(c.value, m.$1, name));
    widget.focusNode.requestFocus();
  }

  void _set(TextEditingValue v) {
    c.value = v;
    widget.onChanged(v.text);
  }

  void _changed(String t) {
    final fixed = afterTyping(_prev, c.value);
    if (fixed != null) {
      _set(fixed);
    } else {
      widget.onChanged(t);
    }
  }

  void _apply(TextEditingValue Function(TextEditingValue) f) {
    if (c.value.composing.isValid) return;
    _set(f(c.value.selection.isValid ? c.value : c.value.copyWith(selection: TextSelection.collapsed(offset: c.text.length))));
    widget.focusNode.requestFocus();
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (c.value.composing.isValid) return KeyEventResult.ignored; // 输入法在组字，键给输入法
    final k = HardwareKeyboard.instance;
    final cmd = k.isMetaPressed || k.isControlPressed;
    if (e.logicalKey == LogicalKeyboardKey.tab && !cmd && !k.isAltPressed) {
      _apply((v) => indent(v, back: k.isShiftPressed));
      return KeyEventResult.handled;
    }
    if (k.isMetaPressed && k.isControlPressed &&
        (e.logicalKey == LogicalKeyboardKey.arrowUp || e.logicalKey == LogicalKeyboardKey.arrowDown)) {
      _apply((v) => moveLines(v, up: e.logicalKey == LogicalKeyboardKey.arrowUp));
      return KeyEventResult.handled;
    }
    if (cmd && !k.isShiftPressed && widget.onFontSize != null &&
        (e.logicalKey == LogicalKeyboardKey.equal || e.logicalKey == LogicalKeyboardKey.minus)) {
      final f = (widget.fontSize + (e.logicalKey == LogicalKeyboardKey.equal ? 1 : -1)).clamp(12.0, 26.0);
      widget.onFontSize!(f);
      return KeyEventResult.handled;
    }
    if (cmd && !k.isShiftPressed && e.logicalKey == LogicalKeyboardKey.keyB) {
      _apply((v) => toggleWrap(v, '**'));
      return KeyEventResult.handled;
    }
    if (cmd && !k.isShiftPressed && e.logicalKey == LogicalKeyboardKey.keyF) {
      _openFind();
      return KeyEventResult.handled;
    }
    if (cmd && k.isShiftPressed) {
      final kind = switch (e.logicalKey) {
        LogicalKeyboardKey.keyL => NoteKind.todo,
        LogicalKeyboardKey.digit7 => NoteKind.bullet,
        LogicalKeyboardKey.digit9 => NoteKind.number,
        _ => null,
      };
      if (kind != null) {
        _apply((v) => setKind(v, kind));
        return KeyEventResult.handled;
      }
      final head = switch (e.logicalKey) { LogicalKeyboardKey.keyT => 1, LogicalKeyboardKey.keyH => 2, _ => 0 };
      if (head > 0) {
        _apply((v) => toggleHeading(v, head));
        return KeyEventResult.handled;
      }
      if (e.logicalKey == LogicalKeyboardKey.keyE) {
        _apply((v) => toggleWrap(v, '=='));
        return KeyEventResult.handled;
      }
      if (e.logicalKey == LogicalKeyboardKey.keyU) {
        // 勾上 / 取消光标这一行的待办（备忘录也是 ⇧⌘U）
        final l = lineAt(c.text, c.selection.baseOffset);
        if (l.kind == NoteKind.todo || l.kind == NoteKind.done) {
          final box = l.start + l.indent.length;
          _set(toggleAtTap(c.value.copyWith(selection: TextSelection.collapsed(offset: box)))!
              .copyWith(selection: c.selection));
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, String tip, VoidCallback on) => IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 18, color: K.mute),
      onPressed: on,
    );
    Widget tool(IconData icon, String tip, NoteKind k) => btn(icon, tip, () => _apply((v) => setKind(v, k)));
    final field = Padding(
      padding: widget.expand ? const EdgeInsets.fromLTRB(20, 0, 18, 8) : const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _key,
        child: TextField(
          controller: c,
          focusNode: widget.focusNode,
          maxLines: null,
          minLines: widget.expand ? null : 3,
          expands: widget.expand,
          keyboardType: TextInputType.multiline,
          textAlignVertical: TextAlignVertical.top,
          style: TextStyle(fontSize: widget.fontSize, height: 1.7, color: K.ink),
          decoration: InputDecoration(hintText: widget.hint, hintStyle: TextStyle(color: K.faint, height: 1.7)),
          onTap: () {
            final t = toggleAtTap(c.value);
            if (t != null) _set(t);
          },
          onChanged: _changed,
        ),
      ),
    );
    return Column(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: widget.expand ? const EdgeInsets.fromLTRB(12, 0, 12, 2) : EdgeInsets.zero,
          child: Row(
            children: [
              tool(Icons.check_circle_outline_rounded, '待办清单  ⇧⌘L（点框打勾）', NoteKind.todo),
              tool(Icons.format_list_bulleted_rounded, '要点  ⇧⌘7', NoteKind.bullet),
              tool(Icons.format_list_numbered_rounded, '编号  ⇧⌘9', NoteKind.number),
              Container(width: 1, height: 16, margin: const EdgeInsets.symmetric(horizontal: 4), color: K.line),
              btn(Icons.title_rounded, '标题  ⇧⌘T（小标题 ⇧⌘H）', () => _apply((v) => toggleHeading(v, 1))),
              btn(Icons.format_bold_rounded, '加粗  ⌘B', () => _apply((v) => toggleWrap(v, '**'))),
              btn(Icons.border_color_outlined, '标重点（黄底）  ⇧⌘E', () => _apply((v) => toggleWrap(v, '=='))),
              btn(Icons.search_rounded, '在笔记里找  ⌘F', _openFind),
              if (widget.onCarry != null) btn(Icons.playlist_add_check_rounded, '带上没做完的事', widget.onCarry!),
              const SizedBox(width: 6),
              Flexible(
                child: Text('Tab 缩进 · 回车接着下一条 · 打 @ 选人', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: K.faint)),
              ),
            ],
          ),
        ),
        if (_finding) _findBar(),
        if (_mention != null) _peopleStrip(),
        if (widget.expand) Expanded(child: field) else field,
      ],
    );
  }

  bool _finding = false;
  final _findText = TextEditingController();
  final _findFocus = FocusNode();

  void _openFind() {
    final sel = c.selection;
    if (sel.isValid && !sel.isCollapsed) _findText.text = sel.textInside(c.text);
    setState(() => _finding = true);
    c.find = _findText.text;
    _findFocus.requestFocus();
    _findText.selection = TextSelection(baseOffset: 0, extentOffset: _findText.text.length);
  }

  void _closeFind() {
    setState(() => _finding = false);
    c.find = '';
    widget.focusNode.requestFocus();
  }

  void _findGo() {
    final at = c.selection.isValid ? c.selection.end : 0;
    final hit = findNext(c.text, _findText.text, at);
    if (hit == null) return;
    c.selection = hit;
    widget.focusNode.requestFocus(); // 跳过去（输入框把选中的滚出来）；再按 ⌘F 接着找
  }

  Widget _findBar() => Padding(
    padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
    child: Row(children: [
      Icon(Icons.search_rounded, size: 16, color: K.faint),
      const SizedBox(width: 6),
      Expanded(
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeFind},
          child: TextField(
            controller: _findText,
            focusNode: _findFocus,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              isDense: true,
              hintText: '在笔记里找，回车跳过去',
              hintStyle: TextStyle(fontSize: 13, color: K.faint),
            ),
            onChanged: (q) {
              c.find = q;
              setState(() {});
            },
            onSubmitted: (_) => _findGo(),
          ),
        ),
      ),
      if (_findText.text.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text('${_findText.text.allMatchesIn(c.text)} 处', style: TextStyle(fontSize: 12, color: K.faint)),
        ),
      IconButton(tooltip: '关掉（Esc）', visualDensity: VisualDensity.compact, icon: Icon(Icons.close_rounded, size: 16, color: K.faint), onPressed: _closeFind),
    ]),
  );

  Widget _peopleStrip() {
    final hits = matchPeople(widget.people, _mention!.$2);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          Text(hits.isEmpty ? '名单里没有「${_mention!.$2}」，接着打就是新名字' : '这条是谁的？', style: TextStyle(fontSize: 12, color: K.faint)),
          for (final n in hits)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: ActionChip(
                label: Text(n, style: const TextStyle(fontSize: 13)),
                visualDensity: VisualDensity.compact,
                onPressed: () => _pick(n),
              ),
            ),
        ]),
      ),
    );
  }
}

extension on String {
  int allMatchesIn(String text) => isEmpty ? 0 : RegExp(RegExp.escape(this)).allMatches(text).length;
}
