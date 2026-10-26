// 现场会议的界面：左边实时原话，右边我的笔记，底下「顺一下」。
// 宽屏左右两栏；手机上下两块（原话在上、笔记在下）。
// 原话进笔记：点一句 = 整句进去；选中一段 →「记到笔记」。进去的只有文字，不带时间（Jane 定的）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'live.dart';
import 'templates.dart' show VocabEntry;
import 'theme.dart';

class LiveView extends StatefulWidget {
  final LiveSession live;
  final double top; // Mac 顶上拖窗口那条让出来
  const LiveView({super.key, required this.live, this.top = 0});
  @override
  State<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<LiveView> {
  late final _notes = TextEditingController(text: widget.live.notes);
  late final _title = TextEditingController(text: widget.live.title);
  final _ask = TextEditingController();
  final _scroll = ScrollController();
  final _notesFocus = FocusNode();
  String _selected = ''; // 拖动选中的一段文字
  final Set<int> _picked = {}; // 点选的几句（行号），可以不挨着
  Offset? _anchor; // 最后一次松手的位置：浮动「添加笔记」放这儿
  int _selRound = 0; // 加完笔记后换个 key，把拖选的高亮清掉
  bool _polishing = false;
  String? _undo; // 顺之前的笔记：撤回用
  int _seen = 0;

  LiveSession get live => widget.live;

  @override
  void initState() {
    super.initState();
    live.addListener(_onLive);
    _seen = live.lines.length;
  }

  @override
  void dispose() {
    live.removeListener(_onLive);
    _notes.dispose();
    _title.dispose();
    _ask.dispose();
    _scroll.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  void _onLive() {
    if (!mounted) return;
    // 一场收完 / 放弃后重新开：输入框跟着清空
    if (live.stem == null && (_notes.text.isNotEmpty || _title.text.isNotEmpty) && live.state == LiveState.idle) {
      _notes.clear();
      _title.clear();
      _undo = null;
      _picked.clear();
    }
    if (_title.text.isEmpty && live.title.isNotEmpty) _title.text = live.title;
    if (live.lines.length != _seen) {
      // 新出了一句：本来就在底部才跟着滚，翻上去看的时候不打扰
      final atBottom = !_scroll.hasClients || _scroll.position.maxScrollExtent - _scroll.offset < 80;
      _seen = live.lines.length;
      if (atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    }
    setState(() {});
  }

  /// 原话进笔记：接在笔记末尾，自成一段，光标停在后面接着写。
  void _clip(String text) {
    final t = text.trim().replaceAll(RegExp(r'\s*\n\s*'), '\n');
    if (t.isEmpty) return;
    final cur = _notes.text.trimRight();
    final next = cur.isEmpty ? '$t\n' : '$cur\n\n$t\n';
    _notes.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    live.setNotes(next);
    _undo = null;
    // 拖选（含双击选中的词）的高亮只能换 key 重建来清；重建会丢滚动位置（Jane：加完就跳回最前面了），
    // 所以先记下、重建完放回去。只是点选 / 双击整句时不重建。
    final hadDrag = _selected.trim().isNotEmpty;
    final keep = _scroll.hasClients ? _scroll.offset : null;
    setState(() {
      _selected = '';
      _anchor = null;
      if (hadDrag) _selRound++;
    });
    if (hadDrag && keep != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(keep.clamp(0.0, _scroll.position.maxScrollExtent));
      });
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('记到笔记了'), duration: Duration(milliseconds: 900), behavior: SnackBarBehavior.floating),
    );
  }

  void _toggle(int i) => setState(() => _picked.contains(i) ? _picked.remove(i) : _picked.add(i));

  /// 点选的几句按说话顺序拼成一段进笔记（被切碎的半句话本来就是一个意思）。
  void _clipPicked() {
    final idx = _picked.where((i) => i < live.lines.length).toList()..sort();
    _picked.clear();
    _clip(idx.map((i) => live.lines[i].text.trim()).join());
  }

  // ───────── 谁说的 ─────────

  static const _palette = [
    Color(0xFFD95E54),
    Color(0xFF4F7FA8),
    Color(0xFF4F9A68),
    Color(0xFF8F6514),
    Color(0xFF7A5BA6),
    Color(0xFF2E8C8C),
    Color(0xFFB0577E),
    Color(0xFF5E6B2F),
  ];
  static Color _colorOf(String name) => _palette[name.codeUnits.fold(0, (a, c) => (a * 31 + c) & 0x7fffffff) % _palette.length];

  /// 每句前面的小标签：亲手标的实心，小耳按声纹猜的描边，不知道的是「？」。点它选人。
  Widget _speakerChip(int i, LiveLine l) {
    final who = l.speaker;
    final c = who == null ? K.faint : _colorOf(who);
    final guessed = who != null && l.auto;
    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 6),
      child: Tooltip(
        message: who == null ? '点一下：标这句是谁说的' : (guessed ? '小耳按声音猜的是「$who」，不对就点一下改' : '你标的：$who'),
        waitDuration: const Duration(milliseconds: 700),
        child: GestureDetector(
          onTapDown: (d) => _pickWho([i], d.globalPosition),
          child: Container(
            constraints: const BoxConstraints(minWidth: 26, maxWidth: 72),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: who == null || guessed ? Colors.transparent : c.withValues(alpha: 0.14),
              border: Border.all(color: who == null ? K.line : c.withValues(alpha: guessed ? 0.6 : 0.0)),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              who ?? '？',
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c, fontWeight: who == null ? FontWeight.w400 : FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }

  /// 选「这几句是谁说的」：认识的人、新的人、清掉。
  Future<void> _pickWho(List<int> idx, Offset at) async {
    if (idx.isEmpty) return;
    final current = idx.length == 1 ? live.lines[idx.first].speaker : null;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final pick = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      color: K.card,
      items: [
        for (final p in live.people)
          PopupMenuItem(
            value: 'p:$p',
            height: 38,
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: _colorOf(p), shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(p)),
                if (p == current) const Icon(Icons.check_rounded, size: 16, color: K.accent),
              ],
            ),
          ),
        if (live.people.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(value: 'new', height: 38, child: Text('新的人…')),
        if (live.voices.names.isNotEmpty)
          const PopupMenuItem(
            value: 'manage',
            height: 38,
            child: Text('认得的人…', style: TextStyle(color: K.mute)),
          ),
        if (idx.any((i) => live.lines[i].speaker != null))
          const PopupMenuItem(
            value: 'clear',
            height: 38,
            child: Text('不知道是谁', style: TextStyle(color: K.mute)),
          ),
      ],
    );
    if (!mounted || pick == null) return;
    if (pick == 'manage') {
      await _manageVoices();
      return;
    }
    if (pick == 'clear') {
      live.label(idx, null);
    } else if (pick == 'new') {
      final name = await _askName();
      if (name != null && name.trim().isNotEmpty) live.label(idx, name);
    } else {
      live.label(idx, pick.substring(2));
    }
    if (idx.length > 1) setState(_picked.clear);
    if (live.voices.names.length == 1 && mounted) {
      _toast('再标一句别人说的话，小耳才能分清两个人；之后你们的话会自动标上');
    }
    if (live.speakerOff && mounted) _toast('认人用的声纹模型没下载下来：这次只记名字，下次联网开会时会补上自动认人');
  }

  /// 认得的人：标错过（比如把两个人混在一起的一句标给了某人）就忘掉重标。
  Future<void> _manageVoices() => showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        backgroundColor: K.card,
        title: Text('认得的人', style: K.title(20)),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '标错了（比如一句话里混着两个人，却标给了一个人），就把这个人忘掉，再挑他自己说的清楚的长句重新标。',
                style: TextStyle(color: K.mute, fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 10),
              for (final n in live.voices.names)
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(color: _colorOf(n), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(n)),
                    Text(
                      '亲标 ${live.voices.manualCount(n)} 句${live.voices.autoCount(n) > 0 ? ' · 自己学了 ${live.voices.autoCount(n)} 句' : ''}',
                      style: const TextStyle(color: K.faint, fontSize: 12),
                    ),
                    TextButton(
                      onPressed: () {
                        live.forgetVoice(n);
                        set(() {});
                      },
                      child: const Text('忘掉', style: TextStyle(color: K.accent)),
                    ),
                  ],
                ),
              if (live.voices.names.isEmpty) const Text('现在一个都不认得。', style: TextStyle(color: K.faint)),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好'))],
      ),
    ),
  );

  Future<String?> _askName() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这是谁？'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: '名字或称呼，比如：王总、我、小李'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('好', style: TextStyle(color: K.accent)),
          ),
        ],
      ),
    );
  }

  Future<void> _openVocab() async {
    final entries = await showDialog<List<VocabEntry>>(
      context: context,
      builder: (_) => VocabDialog(initial: live.vocab),
    );
    if (entries == null || !mounted) return;
    final n = await live.saveVocab(entries);
    if (mounted) _toast(n > 0 ? '词汇表存好了，这场里改对了 $n 句' : '词汇表存好了，之后出的字按它改');
  }

  Future<void> _copyNotes() async {
    final t = _notes.text.trim();
    if (t.isEmpty) {
      _toast('笔记还是空的');
      return;
    }
    await Clipboard.setData(ClipboardData(text: t));
    if (mounted) _toast('笔记已复制，可以直接粘到微信 / 飞书');
  }

  Future<void> _polish() async {
    if (_polishing) return;
    if (_notes.text.trim().isEmpty && live.lines.isEmpty) {
      _toast('还没有笔记也没有原话，先记一点再顺');
      return;
    }
    setState(() => _polishing = true);
    final before = _notes.text;
    try {
      live.setNotes(before);
      final out = await live.polish(ask: _ask.text);
      if (!mounted) return;
      if (out.isEmpty) throw Exception('小耳没回内容');
      _undo = before;
      _notes.text = out;
      live.setNotes(out);
      _ask.clear();
    } catch (e) {
      _toast('没顺成：${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _polishing = false);
    }
  }

  void _revert() {
    if (_undo == null) return;
    _notes.text = _undo!;
    live.setNotes(_undo!);
    setState(() => _undo = null);
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _finish() async {
    live.setNotes(_notes.text);
    live.setTitle(_title.text.trim().isEmpty ? live.title : _title.text.trim());
    final s = await live.finish();
    if (!mounted) return;
    if (s != null) _toast('收进录音卡了，正在整理；整理好在「按天」里能看到，也会进飞书');
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('放弃这场会？'),
        content: const Text('原话、笔记、录音都不留，也不会收进录音卡。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('不放弃')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('放弃', style: TextStyle(color: K.accent)),
          ),
        ],
      ),
    );
    if (ok == true) await live.discard();
  }

  @override
  Widget build(BuildContext context) {
    if (live.state == LiveState.idle) return _idle();
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: widget.top),
        _header(wide),
        if (live.status != null) _statusLine(),
        const Divider(height: 1, color: K.line),
        Expanded(
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: (MediaQuery.sizeOf(context).width * 0.34).clamp(320, 460).toDouble(), child: _transcript()),
                    const VerticalDivider(width: 1, color: K.line),
                    Expanded(child: _notesPane()),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 2, child: _transcript()),
                    const Divider(height: 1, color: K.line),
                    Expanded(flex: 3, child: _notesPane()),
                  ],
                ),
        ),
      ],
    );
  }

  // ───────── 还没开始 ─────────

  Widget _idle() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Mascot('wave', size: 140, halo: true),
            const SizedBox(height: 18),
            Text('现场会议', style: K.title(24)),
            const SizedBox(height: 10),
            const Text(
              '用这台设备的麦克风边听边出原话。左边是原话，右边记你自己的笔记：'
              '点一句原话、或者选中一段，就能挪进笔记，不用打字。\n记完点「顺一下」，小耳对照原话帮你把笔记理顺。'
              '\n结束后整场收进录音卡，跟卡上的录音一样切场景、出纪要。',
              textAlign: TextAlign.center,
              style: TextStyle(color: K.mute, height: 1.7),
            ),
            const SizedBox(height: 22),
            if (live.lastSaved != null)
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text(
                  '上一场已经收进录音卡，正在整理。',
                  style: TextStyle(color: K.live, fontWeight: FontWeight.w600),
                ),
              ),
            FilledButton.icon(
              onPressed: live.start,
              icon: const Icon(Icons.mic_rounded),
              label: const Text('开始现场会议'),
              style: FilledButton.styleFrom(
                backgroundColor: K.accent,
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 12),
            _systemChip(),
            if (live.status != null) ...[const SizedBox(height: 14), _statusText()],
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _openVocab,
              icon: const Icon(Icons.menu_book_outlined, size: 17, color: K.mute),
              label: const Text('词汇表：开会前先把常被听错的词填好', style: TextStyle(color: K.mute)),
            ),
          ],
        ),
      ),
    ),
  );

  /// 「也录电脑声音」：开线上会议（腾讯会议 / 飞书 / Zoom…）时把对方的声音也录进来
  Widget _systemChip() {
    if (!Platform.isMacOS) return const SizedBox();
    final on = live.withSystem;
    final busy = live.state == LiveState.preparing || live.state == LiveState.saving;
    return Tooltip(
      message: '开线上会议时打开：把电脑里放出来的声音（腾讯会议、飞书、Zoom 里对方说的话）也录进来。\n'
          '外放的话对方的声音会被麦克风再录一遍，戴耳机效果最好。',
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: busy ? null : () => live.setWithSystem(!on),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 2, 14, 2),
          decoration: BoxDecoration(
            color: on ? K.live.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: on ? K.live : K.lineStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.scale(
                scale: 0.75,
                child: Switch(
                  value: on,
                  activeTrackColor: K.live,
                  onChanged: busy ? null : live.setWithSystem,
                ),
              ),
              Icon(Icons.laptop_mac_rounded, size: 16, color: on ? K.live : K.mute),
              const SizedBox(width: 6),
              Text(
                on ? '电脑声音：开着（对方说话也会出字）' : '电脑声音：关着（开线上会议时打开）',
                style: TextStyle(
                  fontSize: 13,
                  color: on ? K.live : K.mute,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusText() => Text(
    live.status!,
    textAlign: TextAlign.center,
    style: const TextStyle(color: K.accent, height: 1.6),
  );

  Widget _statusLine() => Container(
    color: K.accentSoft,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
    child: Row(
      children: [
        if (live.state == LiveState.preparing || live.state == LiveState.saving) ...[
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, value: live.progress, color: K.accent),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(
            live.progress == null ? live.status! : '${live.status!}  ${(live.progress! * 100).round()}%',
            style: const TextStyle(color: K.ink, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  // ───────── 顶栏：标题 · 状态 · 按钮 ─────────

  Widget _header(bool wide) {
    final rec = live.state == LiveState.recording;
    final busy = live.state == LiveState.preparing || live.state == LiveState.saving;
    final e = live.elapsed;
    final clock =
        '${e.inHours > 0 ? '${e.inHours}:' : ''}${(e.inMinutes % 60).toString().padLeft(2, '0')}:${(e.inSeconds % 60).toString().padLeft(2, '0')}';
    final buttons = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _pill(rec ? '录音中 $clock' : (live.state == LiveState.paused ? '已暂停 $clock' : clock), rec),
        if (live.cloudAsr)
          Tooltip(
            message: '本机识别模型还在后台下载，这场先用云端识别（每句晚几秒出字）。下好以后下一场自动改回本机。',
            child: _pill('云端识别 · 本机模型下载中', false),
          ),
        OutlinedButton.icon(
          onPressed: busy ? null : (rec ? live.pause : live.start),
          icon: Icon(rec ? Icons.pause_rounded : Icons.mic_rounded, size: 18),
          label: Text(rec ? '暂停' : '接着录'),
          style: OutlinedButton.styleFrom(
            foregroundColor: K.ink,
            side: const BorderSide(color: K.lineStrong),
          ),
        ),
        FilledButton(
          onPressed: busy ? null : _finish,
          style: FilledButton.styleFrom(backgroundColor: K.accent),
          child: const Text('结束，收进录音卡'),
        ),
        _systemChip(),
        if (live.state == LiveState.paused)
          TextButton(
            onPressed: _discard,
            child: const Text('放弃', style: TextStyle(color: K.faint)),
          ),
        IconButton(
          tooltip: '词汇表：常被听错的词',
          onPressed: _openVocab,
          icon: const Icon(Icons.menu_book_outlined, size: 20, color: K.mute),
        ),
      ],
    );
    final title = TextField(
      controller: _title,
      style: K.title(wide ? 20 : 18),
      decoration: const InputDecoration(
        hintText: '会议标题',
        hintStyle: TextStyle(color: K.faint),
      ),
      onChanged: live.setTitle,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 22 : 14, 10, wide ? 18 : 14, 12),
      child: wide
          ? Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 12),
                buttons,
              ],
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: 8), buttons]),
    );
  }

  Widget _pill(String text, bool on) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: on ? K.accentSoft : K.cardDeep, borderRadius: BorderRadius.circular(99)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: on ? K.accent : K.faint,
            shape: BoxShape.circle,
            boxShadow: on
                ? [
                    BoxShadow(
                      color: K.accent.withValues(alpha: 0.25 + 0.5 * live.level),
                      blurRadius: 2 + 8 * live.level,
                      spreadRadius: 1 + 3 * live.level,
                    ),
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 7),
        Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: on ? K.accent : K.mute,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  // ───────── 左：原话 ─────────

  Widget _transcript() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _paneTitle('原话', live.lines.isEmpty ? null : '双击一句进笔记；拖选一段或单击多选，点旁边的「添加笔记」；点「？」标是谁说的'),
      Expanded(
        child: live.lines.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    live.state == LiveState.recording ? '在听…说完一句，这里就出字' : '还没有原话',
                    style: const TextStyle(color: K.faint),
                  ),
                ),
              )
            : LayoutBuilder(
                builder: (_, box) => Listener(
                  // 松开鼠标 / 手指的地方：「添加笔记」小标签就冒在这儿，不用去底下找按钮
                  onPointerUp: (e) => WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _anchor = e.localPosition);
                  }),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: SelectionArea(
                          key: ValueKey(_selRound),
                          onSelectionChanged: (c) {
                            final t = c?.plainText ?? '';
                            if (t != _selected) setState(() => _selected = t);
                          },
                          child: ListView.builder(
                            key: const PageStorageKey('live-lines'),
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(18, 4, 14, 24),
                            itemCount: live.lines.length,
                            itemBuilder: (_, i) => _line(i, live.lines[i]),
                          ),
                        ),
                      ),
                      if (_anchor != null && (_selected.trim().isNotEmpty || _picked.isNotEmpty)) _floatingChip(box.biggest),
                    ],
                  ),
                ),
              ),
      ),
    ],
  );

  /// 选中以后浮在手边的小标签：添加笔记（多选时还能「标为…」）。
  Widget _floatingChip(Size area) {
    final dragged = _selected.trim().isNotEmpty;
    final a = _anchor!;
    const w = 300.0, h = 40.0;
    final left = (a.dx - 24).clamp(8.0, (area.width - (dragged ? 120 : w)).clamp(8.0, double.infinity));
    final top = a.dy - h - 10 >= 0 ? a.dy - h - 10 : a.dy + 18;
    Widget pill(String text, VoidCallback onTap, {bool strong = false, IconData? icon}) => Material(
      color: strong ? K.ink : K.card,
      borderRadius: BorderRadius.circular(99),
      elevation: strong ? 3 : 0,
      shadowColor: const Color(0x401F4A44),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 15, color: strong ? K.card : K.ink), const SizedBox(width: 5)],
              Text(
                text,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: strong ? K.card : K.ink),
              ),
            ],
          ),
        ),
      ),
    );
    return Positioned(
      left: left,
      top: top,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: K.card,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: K.line),
          boxShadow: const [BoxShadow(color: Color(0x261F4A44), blurRadius: 12, offset: Offset(0, 4))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: dragged
              ? [pill('添加笔记', () => _clip(_selected), strong: true, icon: Icons.add_rounded)]
              : [
                  pill('添加笔记 · ${_picked.length} 句', _clipPicked, strong: true, icon: Icons.add_rounded),
                  const SizedBox(width: 3),
                  Builder(
                    builder: (bc) => pill('标为…', () {
                      final b = bc.findRenderObject() as RenderBox;
                      _pickWho(_picked.toList()..sort(), b.localToGlobal(Offset(0, b.size.height)));
                    }, icon: Icons.person_outline_rounded),
                  ),
                  const SizedBox(width: 3),
                  pill('取消', () => setState(_picked.clear)),
                ],
        ),
      ),
    );
  }

  Widget _line(int i, LiveLine l) {
    final on = _picked.contains(i);
    final t = l.at;
    final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 时间不进选区：选中拷出去的只有原话
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.only(top: 9, right: 10),
              child: Text(
                hm,
                style: const TextStyle(fontSize: 11.5, color: K.faint, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ),
          SelectionContainer.disabled(child: _speakerChip(i, l)),
          Expanded(
            child: Tooltip(
              message: on ? '再点一下：不选这句' : '双击：直接进笔记；单击：选中，可以多选',
              waitDuration: const Duration(milliseconds: 900),
              child: Material(
                color: on ? K.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _selected.trim().isEmpty ? () => _toggle(i) : null,
                  onDoubleTap: () {
                    _picked.remove(i);
                    _clip(l.text);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    // 标了谁，字就是谁的颜色（压暗一点好读），一眼分得清谁在说
                    child: Text(
                      l.text,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.65,
                        color: l.speaker == null ? K.ink : Color.lerp(_colorOf(l.speaker!), Colors.black, 0.2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _paneTitle(String t, String? hint, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 16, 6),
    child: Row(
      children: [
        Text(
          t,
          style: const TextStyle(fontWeight: FontWeight.w700, color: K.mute, fontSize: 13, letterSpacing: 1),
        ),
        if (hint != null) ...[
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hint,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: K.faint, fontSize: 12),
            ),
          ),
        ],
        if (hint == null) const Spacer(),
        ?trailing,
      ],
    ),
  );

  // ───────── 右：我的笔记 + 顺一下 ─────────

  Widget _notesPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _paneTitle(
        '我的笔记',
        null,
        trailing: IconButton(
          tooltip: '复制笔记',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.copy_rounded, size: 17, color: K.mute),
          onPressed: _copyNotes,
        ),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 18, 8),
          child: TextField(
            controller: _notes,
            focusNode: _notesFocus,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontSize: 15, height: 1.7, color: K.ink),
            decoration: const InputDecoration(
              hintText: '边听边记。双击左边一句原话、或者选中一段，就挪到这里。',
              hintStyle: TextStyle(color: K.faint, height: 1.7),
            ),
            onChanged: (v) {
              live.setNotes(v);
              if (_undo != null) setState(() => _undo = null);
            },
          ),
        ),
      ),
      _aiBar(),
    ],
  );

  Widget _aiBar() => Container(
    margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
    padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
    decoration: BoxDecoration(
      color: K.cardDeep,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: K.line),
    ),
    child: Row(
      children: [
        const Mascot('stand', size: 26),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _ask,
            enabled: !_polishing,
            style: const TextStyle(fontSize: 14, color: K.ink),
            decoration: InputDecoration(
              hintText: _polishing ? '小耳在对照原话理你的笔记…' : '跟小耳说怎么改，不说就按模板顺一下（比如：按议题分，最后列待办）',
              hintStyle: const TextStyle(color: K.faint, fontSize: 13),
            ),
            onSubmitted: (_) => _polish(),
          ),
        ),
        if (_undo != null && !_polishing)
          TextButton(
            onPressed: _revert,
            child: const Text('撤回', style: TextStyle(color: K.mute)),
          ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _polishing ? null : _polish,
          style: FilledButton.styleFrom(backgroundColor: K.accent, padding: const EdgeInsets.symmetric(horizontal: 16)),
          child: _polishing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('顺一下'),
        ),
      ],
    ),
  );
}

/// 侧栏上「现场会议」那一行右边的小红点：正在录 / 有没收的会。
class LiveDot extends StatelessWidget {
  final LiveSession live;
  const LiveDot({super.key, required this.live});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: live,
    builder: (_, _) => !live.active
        ? const SizedBox()
        : Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: live.state == LiveState.recording ? K.accent : K.faint, shape: BoxShape.circle),
          ),
  );
}

/// 词汇表窗口：每行一个词，「常被听成」可以写几个（顿号分开）。存进 资料文件夹的 词汇表.md。
class VocabDialog extends StatefulWidget {
  final List<VocabEntry> initial;
  const VocabDialog({super.key, required this.initial});
  @override
  State<VocabDialog> createState() => _VocabDialogState();
}

class _VocabDialogState extends State<VocabDialog> {
  late final rows = [
    for (final e in widget.initial) (TextEditingController(text: e.word), TextEditingController(text: e.wrong.join('、'))),
  ];

  @override
  void initState() {
    super.initState();
    if (rows.isEmpty) _add();
  }

  @override
  void dispose() {
    for (final (a, b) in rows) {
      a.dispose();
      b.dispose();
    }
    super.dispose();
  }

  void _add() => setState(() => rows.add((TextEditingController(), TextEditingController())));

  List<VocabEntry> _collect() => [
    for (final (a, b) in rows)
      if (a.text.trim().isNotEmpty)
        VocabEntry(a.text.trim(), b.text.split(RegExp(r'[、,，/／;；\s]+')).map((x) => x.trim()).where((x) => x.isNotEmpty).toList()),
  ];

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: K.card,
    title: Text('词汇表', style: K.title(20)),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '常被听错的人名、品牌、产品名。填了「常被听成」的，出字时自动换成对的；整理纪要、「顺一下」也会照这里改错字。',
            style: TextStyle(color: K.mute, fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 12),
          const Row(
            children: [
              Expanded(
                flex: 2,
                child: Text('正确的词', style: TextStyle(color: K.faint, fontSize: 12)),
              ),
              SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: Text('常被听成（多个用顿号分开，可不填）', style: TextStyle(color: K.faint, fontSize: 12)),
              ),
              SizedBox(width: 36),
            ],
          ),
          const SizedBox(height: 4),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (i, (a, b)) in rows.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(flex: 2, child: _box(a, '品牌机')),
                        const SizedBox(width: 10),
                        Expanded(flex: 3, child: _box(b, '品牌纪、品牌期')),
                        IconButton(
                          tooltip: '删掉这个词',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(() => rows.removeAt(i)),
                          icon: const Icon(Icons.close_rounded, size: 18, color: K.faint),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: _add, icon: const Icon(Icons.add_rounded, size: 18), label: const Text('加一个词')),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(
        onPressed: () => Navigator.pop(context, _collect()),
        style: FilledButton.styleFrom(backgroundColor: K.accent),
        child: const Text('保存'),
      ),
    ],
  );

  Widget _box(TextEditingController c, String hint) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(color: K.paper.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(8)),
    child: TextField(
      controller: c,
      style: const TextStyle(fontSize: 14, color: K.ink),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: K.faint),
      ),
    ),
  );
}
