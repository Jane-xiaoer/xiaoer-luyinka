// 把整理好的笔记（模型按模板写的 Markdown）画出来：标题、列表、待办框、表格、引用、加粗。够用就行。
import 'package:flutter/material.dart';

import 'theme.dart';

class MdView extends StatelessWidget {
  final String md;
  const MdView(this.md, {super.key});

  static final _body = TextStyle(fontSize: 14.5, height: 1.75, color: K.ink);

  @override
  Widget build(BuildContext context) {
    final out = <Widget>[];
    final lines = md.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].trimRight();
      final t = l.trimLeft();
      if (t.isEmpty) continue;
      if (t.startsWith('|')) {
        final rows = <List<String>>[];
        while (i < lines.length && lines[i].trim().startsWith('|')) {
          final cells = lines[i].trim().replaceAll(RegExp(r'^\||\|$'), '').split('|').map((c) => c.trim()).toList();
          if (!cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c))) rows.add(cells);
          i++;
        }
        i--;
        out.add(_table(rows));
      } else if (t.startsWith('### ')) {
        out.add(Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 2),
            child: _rich(t.substring(4), TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: K.ink, height: 1.6))));
      } else if (t.startsWith('## ') || t.startsWith('# ')) {
        out.add(Padding(
          padding: EdgeInsets.only(top: out.isEmpty ? 0 : 18, bottom: 6),
          child: Label(t.replaceFirst(RegExp(r'^#+ '), ''), color: K.accent),
        ));
      } else if (t.startsWith('> ')) {
        out.add(Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: K.accentEdge, width: 3))),
          child: _rich(t.substring(2), _body.copyWith(color: K.mute)),
        ));
      } else if (RegExp(r'^[-*] \[[ xX]\] ').hasMatch(t)) {
        out.add(_item(Icon(t[3] == ' ' ? Icons.check_box_outline_blank : Icons.check_box, size: 16, color: K.todo), t.substring(6),
            indent: l.length - t.length));
      } else if (RegExp(r'^[-*•] ').hasMatch(t)) {
        out.add(_item(
            Container(width: 5, height: 5, margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(color: K.accent, shape: BoxShape.circle)),
            t.substring(2),
            indent: l.length - t.length));
      } else if (RegExp(r'^\d+[.、] ').hasMatch(t)) {
        final m = RegExp(r'^(\d+)[.、] ').firstMatch(t)!;
        out.add(_item(Text('${m[1]}.', style: _body.copyWith(color: K.accent, fontWeight: FontWeight.w600)), t.substring(m[0]!.length),
            indent: l.length - t.length));
      } else {
        out.add(Padding(padding: const EdgeInsets.only(bottom: 6), child: _rich(t, _body)));
      }
    }
    return SelectionArea(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: out));
  }

  Widget _item(Widget lead, String text, {int indent = 0}) => Padding(
        padding: EdgeInsets.only(left: indent > 0 ? 18 : 0, bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 22, child: Padding(padding: const EdgeInsets.only(top: 6), child: Align(alignment: Alignment.topLeft, child: lead))),
          Expanded(child: _rich(text, _body)),
        ]),
      );

  Widget _table(List<List<String>> rows) {
    if (rows.isEmpty) return const SizedBox();
    final n = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      decoration: BoxDecoration(border: Border.all(color: K.line), borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Table(
        border: TableBorder(horizontalInside: BorderSide(color: K.line)),
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        columnWidths: {
          // 按每列最长的字数分宽度（「事项」宽、「负责人 / 截止」窄）
          for (var c = 0; c < n; c++)
            c: FlexColumnWidth(rows.map((r) => c < r.length ? r[c].length : 0).reduce((a, b) => a > b ? a : b).clamp(4, 30).toDouble()),
        },
        children: [
          for (final (i, r) in rows.indexed)
            TableRow(
              decoration: BoxDecoration(color: i == 0 ? K.cardDeep : null),
              children: [
                for (var c = 0; c < n; c++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    child: _rich(c < r.length ? r[c] : '',
                        i == 0 ? TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute) : _body.copyWith(fontSize: 14)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// **加粗**、`代码`、[链接](地址)（只显示文字）就够了。
  Widget _rich(String s, TextStyle base) {
    final spans = <TextSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`(.+?)`|\[([^\]]+)\]\((?:<[^>]*>|[^)\s]*)\)');
    var at = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > at) spans.add(TextSpan(text: s.substring(at, m.start)));
      spans.add(m[1] != null
          ? TextSpan(text: m[1], style: const TextStyle(fontWeight: FontWeight.w700))
          : m[2] != null
              ? TextSpan(text: m[2], style: TextStyle(color: K.mute))
              : TextSpan(text: m[3], style: TextStyle(color: K.accent)));
      at = m.end;
    }
    if (at < s.length) spans.add(TextSpan(text: s.substring(at)));
    return Text.rich(TextSpan(style: base, children: spans));
  }
}
