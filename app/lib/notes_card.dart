// 会后「我的笔记」卡（11-13 方案 D）：这场会 / 这条随手记的笔记，在这场的第一段顶上。
// 跟会上同一个编辑器，直接改，停手一会儿自动存（重算笔记待办、重写 md，不重新整理）。
// 「对着录音听」：每行有时间的显示钟点，点了从那儿听（手机上没有悬停，所以常显）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'note_doc.dart';
import 'note_edit.dart';
import 'note_store.dart';
import 'store.dart';
import 'theme.dart';

/// 这一段要不要放笔记卡：现场会议 / 随手记，有笔记（随手记总是放），而且是这条录音第一段不是杂音的。
bool showsNotes(Store store, Scene s) {
  if (!s.stem.startsWith('live') && !s.stem.startsWith('memo')) return false;
  final first = store.scenes.where((x) => x.stem == s.stem && !x.noise).toList()..sort((a, b) => a.offset.compareTo(b.offset));
  if (first.isEmpty || first.first.id != s.id) return false;
  if (s.stem.startsWith('memo')) return true;
  return '${store.peekResult(s.stem)?['notes'] ?? ''}'.trim().isNotEmpty;
}

class MyNotesCard extends StatefulWidget {
  final Scene scene;
  final Store store;
  final void Function(double offset, String label)? onPlay; // 没有录音（随手记、只有笔记的会）就不给
  final VoidCallback? onRecut; // 照笔记重新整理（有逐字稿才给）
  final bool autofocus;
  const MyNotesCard({super.key, required this.scene, required this.store, this.onPlay, this.onRecut, this.autofocus = false});
  @override
  State<MyNotesCard> createState() => _MyNotesCardState();
}

class _MyNotesCardState extends State<MyNotesCard> {
  final _c = NotesController();
  final _focus = FocusNode();
  List<LineMeta> _meta = [];
  Timer? _save;
  bool _listen = false;
  String _saved = '';
  String? _said; // 存完的一句提示

  String get stem => widget.scene.stem;

  @override
  void initState() {
    super.initState();
    _load();
    widget.store.addListener(_external);
    if (widget.autofocus && _c.text.trim().isEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void didUpdateWidget(MyNotesCard old) {
    super.didUpdateWidget(old);
    if (old.scene.stem != stem) {
      _flush(old.scene.stem);
      _load();
    }
  }

  @override
  void dispose() {
    // 点了随手记又什么都没写就走了：这条不留（先停掉存盘，别跟删除抢，芯 +46）；不然把没存的存了
    if (stem.startsWith('memo') && _c.text.trim().isEmpty) {
      _save?.cancel();
      _save = null;
      widget.store.dropRecording(stem);
    } else {
      _flush(stem);
    }
    widget.store.removeListener(_external);
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _load() {
    final res = widget.store.peekResult(stem) ?? const {};
    final t = '${res['notes'] ?? ''}';
    _meta = metaOf(t, res['notes_meta']);
    _saved = t;
    _lastText = t;
    _c.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  // 别处改了笔记（待办里打勾、待确认里改归谁）：我没在改的时候跟上
  void _external() {
    if (!mounted || _save != null || _focus.hasFocus) return;
    final res = widget.store.peekResult(stem);
    final t = '${res?['notes'] ?? ''}';
    if (res != null && t != _c.text) setState(_load);
  }

  void _changed(String v) {
    _meta = alignMeta(_lastText, _meta, v, src: 'me', at: null);
    _lastText = v;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 900), () => _flush(stem));
  }

  String _lastText = '';

  Future<void> _flush(String which) async {
    final pending = _save != null;
    _save?.cancel();
    _save = null;
    if (!pending || _c.text == _saved) return;
    // 输入法还在组字（拼音没选完）：等打完再存，别把拼音存进笔记和待办（芯 +46）
    if (mounted && _c.value.composing.isValid) {
      _save = Timer(const Duration(milliseconds: 600), () => _flush(which));
      return;
    }
    final text = _c.text;
    final (mine, ask) = await widget.store.putNotes(which, text, _meta);
    _saved = text;
    if (mounted) setState(() => _said = mine + ask == 0 ? '存好了' : '存好了 · 笔记里的待办 $mine 条在「待办」${ask > 0 ? '、$ask 条在「待确认」' : ''}');
  }

  @override
  Widget build(BuildContext context) {
    final memo = stem.startsWith('memo');
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: K.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: K.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(Icons.edit_note_rounded, size: 18, color: K.accent),
          const SizedBox(width: 6),
          Text(memo ? '随手记' : '我开会时记的笔记', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          if (_said != null) Flexible(child: Text(_said!, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: K.faint))),
          const Spacer(),
          if (widget.onPlay != null && _meta.any((m) => m.at != null))
            TextButton.icon(
              onPressed: () async {
                await _flush(stem);
                setState(() => _listen = !_listen);
              },
              icon: Icon(_listen ? Icons.edit_rounded : Icons.headphones_rounded, size: 16),
              label: Text(_listen ? '接着改' : '对着录音听', style: const TextStyle(fontSize: 12.5)),
            ),
          IconButton(
            tooltip: '复制（不带「上次没做完」那一节，可以直接发）',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.copy_rounded, size: 16, color: K.mute),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: notesForCopy(_c.text, _meta)));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('笔记复制好了'), duration: Duration(seconds: 2)));
              }
            },
          ),
          if (memo)
            IconButton(
              tooltip: '删掉这条随手记',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.delete_outline_rounded, size: 16, color: K.mute),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('删掉这条随手记？'),
                    content: const Text('笔记和里面的待办都会一起删掉，找不回来。'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('不删')),
                      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('删掉')),
                    ],
                  ),
                );
                if (ok != true) return;
                _save?.cancel();
                _save = null;
                await widget.store.dropRecording(stem);
              },
            ),
          if (widget.onRecut != null)
            IconButton(
              tooltip: '照笔记重新整理这场会（纪要会以你的笔记为主线重写）',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.auto_fix_high_rounded, size: 16, color: K.mute),
              onPressed: () async {
                await _flush(stem);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('照笔记重新整理？'),
                    content: const Text('这场会的分段和纪要会重新写，以你的笔记为主线。你的笔记、笔记里的待办和勾都不动。'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('先不')),
                      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('重新整理')),
                    ],
                  ),
                );
                if (ok == true) widget.onRecut!();
              },
            ),
        ]),
        const SizedBox(height: 4),
        if (_listen) _listenView() else NotesEditor(
          controller: _c,
          focusNode: _focus,
          expand: false,
          hint: memo ? '想到什么就记。☐ 记待办，打 @ 选人。' : '补记点什么都行，☐ 记待办。',
          people: [
            for (final p in widget.store.lib.peopleEntries())
              if (p.name != '我') (p.name, p.aliases, '${p.project} ${p.company}'),
          ],
          onChanged: _changed,
        ),
      ]),
    );
  }

  /// 对着录音听：一行一行，有时间的前面常显钟点，点了从那儿听
  Widget _listenView() {
    final lines = _c.text.split('\n');
    final start = widget.scene.start.subtract(Duration(milliseconds: (widget.scene.offset * 1000).round()));
    String clock(double at) {
      final t = start.add(Duration(milliseconds: (at * 1000).round()));
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, l) in lines.indexed)
        if (l.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 64,
                child: i < _meta.length && _meta[i].at != null
                    ? InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => widget.onPlay!(_meta[i].at!, clock(_meta[i].at!)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.play_arrow_rounded, size: 14, color: K.accent),
                            Text(clock(_meta[i].at!), style: TextStyle(fontSize: 12, color: K.accent)),
                          ]),
                        ),
                      )
                    : null,
              ),
              Expanded(
                // 跟编辑时一样的样子（标题、勾、重点），只看
                child: Text.rich(NotesController(text: l)
                    .buildTextSpan(context: context, style: TextStyle(fontSize: 15, height: 1.6, color: K.ink), withComposing: false)),
              ),
            ]),
          ),
    ]);
  }
}
