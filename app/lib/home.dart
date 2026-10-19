// 主界面（方向 A · 今天时间线）：宽屏三栏 = 日子 / 当天时间线 + 问答 / 场景详情 + 播放条；手机 = 当天列表 → 点进详情。
import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'analyze.dart';
import 'ask.dart';
import 'cards.dart';
import 'handoff.dart';
import 'llm.dart';
import 'md_view.dart';
import 'search.dart';
import 'settings.dart';
import 'store.dart';
import 'sync.dart';
import 'templates.dart';
import 'theme.dart';

class Home extends StatefulWidget {
  final Store store;
  final Syncer syncer;
  const Home({super.key, required this.store, required this.syncer});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String? _day;
  String? _sceneId;
  bool _byCat = false; // 按天看 / 按类别看
  String? _cat;
  final player = Player();
  final _search = TextEditingController();
  final _askKey = GlobalKey(); // 搜索 / 按天 / 按类别来回切，对话不丢
  Timer? _debounce;
  String _query = '';
  List<SearchHit>? _hits;

  Store get store => widget.store;

  bool get searching => searchTerms(_query).isNotEmpty;
  List<SearchHit> get hits => _hits ??= searchScenes(store.scenes, _query);

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) {
        setState(() {
          _query = v;
          _hits = null;
        });
      }
    });
  }

  void _resetSearch() {
    _debounce?.cancel();
    _search.clear();
    _query = '';
    _hits = null;
  }

  void clearSearch() => setState(_resetSearch);

  /// 对话里小耳找到的那段：切到那天，右栏打开它。
  void openFound(Scene s) {
    setState(() {
      _resetSearch();
      _byCat = false;
      _day = s.dayKey;
      _sceneId = s.id;
    });
    if (MediaQuery.sizeOf(context).width < 900) _openNarrow(s);
  }

  @override
  void initState() {
    super.initState();
    widget.syncer.onChange = () {
      if (mounted) setState(() {});
    };
    store.addListener(_onStore);
  }

  void _onStore() {
    if (mounted) setState(() => _hits = null);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    store.removeListener(_onStore);
    player.dispose();
    super.dispose();
  }

  String? get day {
    final days = store.days;
    if (_day != null && days.containsKey(_day)) return _day;
    return days.isEmpty ? null : days.keys.first;
  }

  String? get cat {
    final c = store.byCategory;
    if (_cat != null && c.containsKey(_cat)) return _cat;
    return c.isEmpty ? null : c.keys.first;
  }

  List<Scene> get scenes => _byCat ? (cat == null ? [] : store.byCategory[cat]!) : (day == null ? [] : store.days[day]!);

  String get topic => _byCat ? 'cat:$cat' : 'day:$day';

  Scene? get scene {
    final l = searching ? [for (final h in hits) h.scene] : scenes;
    if (l.isEmpty) return null;
    return l.firstWhere((s) => s.id == _sceneId, orElse: () => l.firstWhere((s) => s.todo > 0, orElse: () => l.first));
  }

  void _handoff() => showHandoff(context, store, day, scenes);

  void pickDay(String d) => setState(() {
        _day = d;
        _sceneId = null;
      });

  void pickCat(String c) => setState(() {
        _cat = c;
        _sceneId = null;
      });

  void setMode(bool byCat) => setState(() {
        _byCat = byCat;
        _sceneId = null;
      });

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          if (!wide) TopBar(syncer: widget.syncer, store: store, onHandoff: _handoff),
          Expanded(
            // Mac 顶上 34pt 拖窗口由 MainFlutterWindow.swift 接管，那条里别放按钮
            child: wide ? _wide() : _narrow(),
          ),
          if (wide)
            ListenableBuilder(
                listenable: player, builder: (_, _) => player.stem == null ? const SizedBox() : PlayerBar(player: player)),
        ]),
      ),
    );
  }

  Widget _wide() => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
            width: 228,
            child: Sidebar(
                store: store, syncer: widget.syncer, day: day, onPick: pickDay,
                byCat: _byCat, cat: cat, onPickCat: pickCat, onMode: setMode,
                search: SearchField(controller: _search, onChanged: _onSearch, onClear: clearSearch))),
        Expanded(child: Container(
          margin: const EdgeInsets.fromLTRB(0, 12, 12, 12),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: K.card,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [BoxShadow(color: Color(0x261F4A44), blurRadius: 24, offset: Offset(0, 8))],
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: (MediaQuery.sizeOf(context).width * 0.36).clamp(360, 470).toDouble(),
          child: searching
              ? SearchColumn(
                  store: store, hits: hits, scenes: scenes, topic: topic, selected: scene?.id, top: 34,
                  askKey: _askKey, onOpen: openFound, onPick: (s) => setState(() => _sceneId = s.id))
              : _byCat
                  ? CatColumn(store: store, cat: cat, scenes: scenes, selected: scene?.id,
                      askKey: _askKey, onOpen: openFound, onPick: (s) => setState(() => _sceneId = s.id), top: 34)
                  : DayColumn(
                      store: store, day: day, scenes: scenes, selected: scene?.id, onHandoff: _handoff,
                      askKey: _askKey, onOpen: openFound, onPick: (s) => setState(() => _sceneId = s.id)),
        ),
        const VerticalDivider(width: 1, color: K.line),
        Expanded(
            child: scene == null
                ? const Hint('sleep', '还没有内容', '有录音以后，点左边任意一段，这里看要点和逐字稿。')
                : SceneDetail(scene: scene!, player: player, store: store, top: 36)),
          ]),
        )),
      ]);

  Widget _narrow() => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SearchField(controller: _search, onChanged: _onSearch, onClear: clearSearch),
        ),
        if (store.days.isNotEmpty && !searching)
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              Padding(
                padding: const EdgeInsets.only(right: 10, top: 6, bottom: 6),
                child: ModeSwitch(byCat: _byCat, onMode: setMode, compact: true),
              ),
              if (_byCat)
                for (final e in store.byCategory.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                    child: ChoiceChip(label: Text('${catFolder(e.key)} ${e.value.length}'), selected: e.key == cat, onSelected: (_) => pickCat(e.key)),
                  )
              else
                for (final d in store.days.keys)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                    child: ChoiceChip(label: Text(dayTitle(d, short: true)), selected: d == day, onSelected: (_) => pickDay(d)),
                  ),
            ]),
          ),
        Expanded(
          child: searching
              ? SearchColumn(store: store, hits: hits, scenes: scenes, topic: topic, selected: null,
                  askKey: _askKey, onOpen: openFound, onPick: _openNarrow)
              : _byCat
                  ? CatColumn(store: store, cat: cat, scenes: scenes, selected: null,
                      askKey: _askKey, onOpen: openFound, onPick: _openNarrow)
                  : DayColumn(store: store, day: day, scenes: scenes, selected: null,
                      askKey: _askKey, onOpen: openFound, onPick: _openNarrow),
        ),
      ]);

  void _openNarrow(Scene s) => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Scaffold(
                      appBar: AppBar(backgroundColor: K.paper, title: Text(s.title)),
                      body: Column(children: [
                        Expanded(child: SceneDetail(scene: s, player: player, store: store)),
                        ListenableBuilder(
                            listenable: player,
                            builder: (_, _) => player.stem == null ? const SizedBox() : PlayerBar(player: player)),
                      ]),
                    )));
}

// ───────── 卡的状态（左栏卡片 / 手机顶栏共用）─────────

/// (标题, 一行状态)
(String, String) cardStatus(Syncer syncer, Store store) {
  final c = syncer.card;
  final title = syncer.boundId == null ? '录音卡' : syncer.boundName;
  final pend = store.pending;
  final pulling = pend.where((r) => r.stage == 'pulling').toList();
  if (pulling.isNotEmpty) {
    final r = pulling.first;
    return (title, '正在拉录音 ${r.size > 0 ? (r.got * 100 ~/ r.size) : 0}%');
  }
  final working = pend.where((r) => ['pulled', 'uploading', 'processing'].contains(r.stage)).length;
  if (working > 0) return (title, '云端转写中 · $working 段');
  final analyzing = pend.where((r) => r.stage == 'analyzing').toList();
  if (analyzing.isNotEmpty) return (title, '正在按类别整理 ${analyzing.first.progress}%');
  final waiting = pend.where((r) => r.stage == 'transcribed').toList();
  if (waiting.isNotEmpty) return (title, waiting.first.error ?? '等着整理 · ${waiting.length} 段');
  if (c.connected) {
    final b = c.info?.battery;
    return (title, '已连接${b == null ? '' : ' · ${c.info!.charging ? '充电中' : '电量 $b%'}'}');
  }
  if (c.scanning) return (title, '正在找…');
  if (syncer.boundId == null) return (title, c.choices.length > 1 ? '附近有 ${c.choices.length} 张卡' : '开机后放在旁边');
  if (c.lastSeen != null) return (title, '上次同步 ${hm(c.lastSeen!)}');
  return (title, c.error ?? '不在旁边，等它靠近');
}

bool _live(Syncer syncer, Store store) => syncer.card.connected || store.pending.isNotEmpty;

// ───────── 手机顶栏：卡的状态 + 交给 Agent ─────────

class TopBar extends StatelessWidget {
  final Syncer syncer;
  final Store store;
  final VoidCallback onHandoff;
  const TopBar({super.key, required this.syncer, required this.store, required this.onHandoff});

  @override
  Widget build(BuildContext context) {
    final (title, sub) = cardStatus(syncer, store);
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(color: K.bar, border: Border(bottom: BorderSide(color: K.line))),
      child: Row(children: [
        Mascot(_live(syncer, store) ? 'stand' : 'sleep', size: 36),
        const SizedBox(width: 8),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            Text(sub, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: K.mute)),
          ]),
        ),
        if (syncer.boundId == null && syncer.card.choices.length > 1)
          TextButton(onPressed: () => showCardPicker(context, syncer), child: const Text('选卡')),
        IconButton(
          tooltip: '设置',
          icon: const Icon(Icons.tune, size: 20, color: K.mute),
          onPressed: () => showSettings(context, store, syncer),
        ),
        HandoffButton(onPressed: onHandoff, compact: true),
      ]),
    );
  }
}

class HandoffButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool compact;
  const HandoffButton({super.key, required this.onPressed, this.compact = false});
  @override
  Widget build(BuildContext context) => FilledButton.icon(
        style: FilledButton.styleFrom(
            backgroundColor: K.ink, foregroundColor: K.card, minimumSize: Size(0, compact ? 34 : 38),
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16)),
        onPressed: onPressed,
        icon: const Icon(Icons.arrow_forward, size: 16),
        label: const Text('交给 Agent'),
      );
}

// ───────── 左栏：小耳 + 日子 + 卡 ─────────

class Sidebar extends StatelessWidget {
  final Store store;
  final Syncer syncer;
  final String? day, cat;
  final bool byCat;
  final void Function(String) onPick, onPickCat;
  final void Function(bool) onMode;
  final Widget? search;
  const Sidebar(
      {super.key, required this.store, required this.syncer, required this.day, required this.onPick,
      required this.byCat, required this.cat, required this.onPickCat, required this.onMode, this.search});

  @override
  Widget build(BuildContext context) => Container(
        color: K.bar,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            // Mac 红绿灯压在左上，往下让一点
            padding: EdgeInsets.fromLTRB(16, Platform.isMacOS ? 46 : 20, 16, 18),
            child: Row(children: [
              const Mascot('stand', size: 38, halo: true),
              const SizedBox(width: 10),
              Text('小耳录音卡', style: K.title(18).copyWith(color: K.ink)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: ModeSwitch(byCat: byCat, onMode: onMode),
          ),
          if (search != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 10), child: search),
          Expanded(
              child: byCat ? CatNav(store: store, cat: cat, onPick: onPickCat) : DayNav(store: store, day: day, onPick: onPick)),
          CardPanel(syncer: syncer, store: store),
        ]),
      );
}

/// 「按天 / 按类别」切换。
class ModeSwitch extends StatelessWidget {
  final bool byCat, compact;
  final void Function(bool) onMode;
  const ModeSwitch({super.key, required this.byCat, required this.onMode, this.compact = false});

  @override
  Widget build(BuildContext context) {
    Widget seg(String t, bool v) => Expanded(
          flex: compact ? 0 : 1,
          child: GestureDetector(
            onTap: () => onMode(v),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: EdgeInsets.symmetric(vertical: 7, horizontal: compact ? 12 : 0),
              decoration: BoxDecoration(color: byCat == v ? K.card : Colors.transparent, borderRadius: BorderRadius.circular(9),
                  boxShadow: byCat == v ? const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 1))] : null),
              alignment: Alignment.center,
              child: Text(t, style: TextStyle(fontSize: 13, fontWeight: byCat == v ? FontWeight.w700 : FontWeight.w500,
                  color: byCat == v ? K.ink : K.mute)),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: K.cardDeep.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max, children: [seg('按天', false), seg('按类别', true)]),
    );
  }
}

/// 左栏搜索框：输入就搜（防抖在外面做），Esc 或 × 清空。
class SearchField extends StatelessWidget {
  final TextEditingController controller;
  final void Function(String) onChanged;
  final VoidCallback onClear;
  const SearchField({super.key, required this.controller, required this.onChanged, required this.onClear});

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClear},
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
          decoration: BoxDecoration(color: K.card.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(12),
              border: Border.all(color: K.line)),
          child: Row(children: [
            const Icon(Icons.search, size: 17, color: K.faint),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: const TextStyle(fontSize: 13.5),
                decoration: const InputDecoration(hintText: '搜标题、人、说过的话…', hintStyle: TextStyle(fontSize: 13, color: K.faint),
                    contentPadding: EdgeInsets.symmetric(vertical: 8)),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: controller,
              builder: (_, v, _) => v.text.isEmpty
                  ? const SizedBox(height: 32)
                  : IconButton(
                      tooltip: '清空搜索',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 16, color: K.mute),
                      onPressed: onClear,
                    ),
            ),
          ]),
        ),
      );
}

/// 左栏：类别 + 数量。
class CatNav extends StatelessWidget {
  final Store store;
  final String? cat;
  final void Function(String) onPick;
  const CatNav({super.key, required this.store, required this.cat, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final c = store.byCategory;
    if (c.isEmpty) return const SizedBox();
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
      for (final e in c.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Material(
            color: e.key == cat ? K.card : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onPick(e.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: categoryColors(e.key).$2, shape: BoxShape.circle)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(catFolder(e.key),
                          style: TextStyle(fontWeight: e.key == cat ? FontWeight.w600 : FontWeight.w400, color: e.key == cat ? K.ink : K.mute))),
                  Text('${e.value.length}',
                      style: TextStyle(fontSize: 12, color: e.key == cat ? K.accent : K.faint, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}

class DayNav extends StatelessWidget {
  final Store store;
  final String? day;
  final void Function(String) onPick;
  const DayNav({super.key, required this.store, required this.day, required this.onPick});

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
        for (final e in store.days.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Material(
              color: e.key == day ? K.card : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onPick(e.key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    Expanded(
                        child: Text(dayTitle(e.key, short: true),
                            style: TextStyle(
                                fontWeight: e.key == day ? FontWeight.w600 : FontWeight.w400,
                                color: e.key == day ? K.ink : K.mute))),
                    Text('${e.value.length}',
                        style: TextStyle(fontSize: 12, color: e.key == day ? K.accent : K.faint,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          ),
      ]);
}

/// 左栏底下的卡片：卡在不在、电量、选卡；设置也在这。
class CardPanel extends StatelessWidget {
  final Syncer syncer;
  final Store store;
  const CardPanel({super.key, required this.syncer, required this.store});

  @override
  Widget build(BuildContext context) {
    final (title, sub) = cardStatus(syncer, store);
    final live = _live(syncer, store);
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 12),
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 4),
      decoration: BoxDecoration(color: K.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: K.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Mascot(live ? 'stand' : 'sleep', size: 44),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 7, height: 7,
                    decoration: BoxDecoration(color: live ? K.live : K.line, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Flexible(child: Text(title, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              ]),
              const SizedBox(height: 2),
              Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: K.mute, height: 1.4)),
            ]),
          ),
        ]),
        if (syncer.boundId == null && syncer.card.choices.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 4),
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: K.accent, minimumSize: const Size(0, 34)),
              onPressed: () => showCardPicker(context, syncer),
              child: const Text('选你的卡'),
            ),
          ),
        Row(children: [
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: K.mute, padding: const EdgeInsets.symmetric(horizontal: 6)),
            onPressed: () => showSettings(context, store, syncer),
            icon: const Icon(Icons.tune, size: 16),
            label: const Text('设置', style: TextStyle(fontSize: 13)),
          ),
          const Spacer(),
          IconButton(
            tooltip: '现在同步',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, size: 18, color: K.mute),
            onPressed: () => syncer.run(),
          ),
        ]),
      ]),
    );
  }
}

// ───────── 中栏：当天时间线 + 问答 ─────────

class DayColumn extends StatelessWidget {
  final Store store;
  final String? day;
  final List<Scene> scenes;
  final String? selected;
  final void Function(Scene) onPick;
  final VoidCallback? onHandoff; // 宽屏：「交给 Agent」放在日期右边；手机在顶栏
  final Key? askKey;
  final void Function(Scene)? onOpen; // 对话里找到的那段被点了
  const DayColumn(
      {super.key, required this.store, required this.day, required this.scenes, required this.selected, required this.onPick,
      this.onHandoff, this.askKey, this.onOpen});

  @override
  Widget build(BuildContext context) {
    if (day == null) return const Hint('wave', '还没有录音', '录音卡开机、放在旁边，小耳会自动把录音拉过来、整理好。\n第一次会问你要不要用蓝牙，点允许。');
    final total = scenes.fold<Duration>(Duration.zero, (a, s) => a + s.end.difference(s.start));
    final todo = scenes.fold<int>(0, (a, s) => a + s.todo);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(24, onHandoff != null ? 34 : 20, 20, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(dayTitle(day!), style: K.title(26).copyWith(color: K.ink)),
              const SizedBox(height: 2),
              const Squiggle(width: 132),
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                _Stat(Icons.mic_none, '录了 ${duration(total)}'),
                _Stat(Icons.view_agenda_outlined, '${scenes.length} 个场景'),
                if (todo > 0) _Stat(Icons.check_circle_outline, '$todo 件要办', todo: true),
              ]),
            ]),
          ),
          if (onHandoff != null) ...[const SizedBox(width: 12), HandoffButton(onPressed: onHandoff!)],
        ]),
      ),
      Expanded(
        child: AskBox(
          key: askKey, store: store, scenes: scenes, all: store.scenes, onOpen: onOpen,
          topic: 'day:$day', focus: _focus(scenes, selected),
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), children: [
            for (final s in scenes) SceneRow(scene: s, selected: s.id == selected, onTap: () => onPick(s)),
          ]),
        ),
      ),
    ]);
  }
}

/// 中栏（按类别）：这一类所有的记录，按日子分组；现场调研按调研对象分组。
class CatColumn extends StatelessWidget {
  final Store store;
  final String? cat;
  final List<Scene> scenes;
  final String? selected;
  final void Function(Scene) onPick;
  final double top;
  final Key? askKey;
  final void Function(Scene)? onOpen;
  const CatColumn(
      {super.key, required this.store, required this.cat, required this.scenes, required this.selected, required this.onPick,
      this.top = 20, this.askKey, this.onOpen});

  @override
  Widget build(BuildContext context) {
    if (cat == null) return const Hint('wave', '还没有录音', '整理好以后，这里按类别看：会议纪要、商务洽谈、现场调研……');
    final bySubject = cat == '现场调研';
    final groups = <String, List<Scene>>{};
    for (final s in scenes) {
      groups.putIfAbsent(bySubject ? (s.subject.isEmpty ? '没写对象' : s.subject) : s.dayKey, () => []).add(s);
    }
    final total = scenes.fold<Duration>(Duration.zero, (a, s) => a + s.end.difference(s.start));
    final hint = cats.firstWhere((c) => c.key == cat, orElse: () => const Cat('', '', '')).hint;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(24, top, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(catFolder(cat!), style: K.title(26).copyWith(color: K.ink)),
          const SizedBox(height: 2),
          const Squiggle(width: 132),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _Stat(Icons.view_agenda_outlined, '${scenes.length} 段'),
            _Stat(Icons.mic_none, '共 ${duration(total)}'),
            if (bySubject) _Stat(Icons.place_outlined, '${groups.length} 个对象'),
          ]),
          if (hint.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(hint, style: const TextStyle(fontSize: 12, color: K.faint)),
          ],
        ]),
      ),
      Expanded(
        child: AskBox(
          key: askKey, store: store, scenes: scenes, all: store.scenes, onOpen: onOpen,
          topic: 'cat:$cat', focus: _focus(scenes, selected),
          hint: '问问小耳：这些${catFolder(cat!)}里…也可以让它写东西',
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), children: [
            for (final g in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
                child: Row(children: [
                  Text(bySubject ? g.key : dayTitle(g.key, short: true),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute)),
                  const SizedBox(width: 8),
                  if (bySubject) Text('${g.value.length} 次', style: const TextStyle(fontSize: 12, color: K.faint)),
                  const SizedBox(width: 8),
                  const Expanded(child: Divider(color: K.line)),
                ]),
              ),
              for (final s in g.value) SceneRow(scene: s, selected: s.id == selected, onTap: () => onPick(s), showDate: bySubject),
            ],
          ]),
        ),
      ),
    ]);
  }
}

/// 中栏（搜索时）：所有日子里搜到的段，每条带一小段命中处的上下文；底下照样能问小耳。
class SearchColumn extends StatelessWidget {
  final Store store;
  final List<SearchHit> hits;
  final List<Scene> scenes; // 搜之前那个视图的场景，问小耳时当资料
  final String topic;
  final String? selected;
  final void Function(Scene) onPick;
  final void Function(Scene)? onOpen;
  final Key? askKey;
  final double top;
  const SearchColumn(
      {super.key, required this.store, required this.hits, required this.scenes, required this.topic, required this.selected,
      required this.onPick, this.onOpen, this.askKey, this.top = 20});

  @override
  Widget build(BuildContext context) {
    final found = [for (final h in hits) h.scene];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(24, top, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('搜索结果', style: K.title(26).copyWith(color: K.ink)),
          const SizedBox(height: 2),
          const Squiggle(width: 132),
          const SizedBox(height: 10),
          _Stat(Icons.search, hits.isEmpty ? '没找到' : '找到 ${hits.length} 段'),
        ]),
      ),
      Expanded(
        child: AskBox(
          key: askKey, store: store, scenes: scenes, all: store.scenes, onOpen: onOpen,
          topic: topic, focus: _focus(found, selected),
          hint: '问问小耳：模糊说说那天大概聊了啥，让它帮你找',
          child: hits.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('没找到，试试在下面问小耳', style: TextStyle(color: K.mute, fontSize: 14)),
                  ),
                )
              : ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), children: [
                  for (final h in hits)
                    SceneRow(scene: h.scene, selected: h.scene.id == selected, onTap: () => onPick(h.scene), showDate: true,
                        extra: SnippetText(h.snippet)),
                ]),
        ),
      ),
    ]);
  }
}

/// 命中处的上下文，命中词用珊瑚粉标出来。
class SnippetText extends StatelessWidget {
  final Snippet snippet;
  const SnippetText(this.snippet, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = snippet.text;
    final spans = <TextSpan>[];
    var at = 0;
    for (final (a, b) in snippet.marks) {
      if (a > at) spans.add(TextSpan(text: t.substring(at, a)));
      spans.add(TextSpan(text: t.substring(a, b), style: const TextStyle(color: K.accent, fontWeight: FontWeight.w700)));
      at = b;
    }
    if (at < t.length) spans.add(TextSpan(text: t.substring(at)));
    return Text.rich(TextSpan(children: spans), maxLines: 3, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12.5, color: K.faint, height: 1.5));
  }
}

Scene? _focus(List<Scene> scenes, String? id) => id == null ? null : scenes.where((s) => s.id == id).firstOrNull;

class SceneRow extends StatelessWidget {
  final Scene scene;
  final bool selected, showDate;
  final VoidCallback onTap;
  final Widget? extra; // 事件下面再加一行（搜索结果的命中片段）
  const SceneRow(
      {super.key, required this.scene, required this.selected, required this.onTap, this.showDate = false, this.extra});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: selected ? K.cardDeep : Colors.transparent,
          elevation: 0,
          shadowColor: const Color(0x22000000),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14), side: BorderSide(color: selected ? K.accentEdge : Colors.transparent)),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            hoverColor: const Color(0x0A000000),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 13, 14, 13),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: 52,
                    child: Text(showDate ? '${scene.start.month}/${scene.start.day}' : hm(scene.start),
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? K.accent : K.faint,
                            fontFeatures: const [FontFeature.tabularFigures()]))),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(scene.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                      Chip2(scene.category),
                      if (scene.todo > 0) Chip2('${scene.todo} 件要办', todo: true),
                    ]),
                    const SizedBox(height: 4),
                    Text(scene.event, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: K.mute, height: 1.5)),
                    if (extra != null) ...[const SizedBox(height: 4), extra!],
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool todo;
  const _Stat(this.icon, this.text, {this.todo = false});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
        decoration: BoxDecoration(
            color: todo ? K.todoSoft : K.cardDeep, borderRadius: BorderRadius.circular(99),
            border: Border.all(color: todo ? K.todoSoft : K.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: todo ? K.todo : K.faint),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 12.5, color: todo ? K.todo : K.mute)),
        ]),
      );
}

/// 小耳 + 一句话：没录音 / 没选中 / 卡不在。
class Hint extends StatelessWidget {
  final String pose, title, body;
  const Hint(this.pose, this.title, this.body, {super.key});
  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Mascot(pose, size: 150, halo: true),
            const SizedBox(height: 18),
            Text(title, style: K.title(22)),
            const SizedBox(height: 10),
            Text(body, textAlign: TextAlign.center, style: const TextStyle(color: K.mute, height: 1.7)),
          ]),
        ),
      );
}

/// 「问问小耳」：底部输入框 + 上方展开的对话区（盖在列表上面，能收起）。
/// 能连续追问；正在看的那段（[focus]）优先交给模型；换天 / 换类别（[topic] 变了）对话清空。
/// [all] 是所有日子的场景，给模型当目录帮我找记录；它找到的段在回答下面列成卡片，点了交给 [onOpen]。
class AskBox extends StatefulWidget {
  final Store store;
  final List<Scene> scenes;
  final List<Scene> all;
  final Scene? focus;
  final String topic;
  final String hint;
  final void Function(Scene)? onOpen;
  final Widget child; // 平时显示的列表
  const AskBox(
      {super.key, required this.store, required this.scenes, required this.topic, required this.child, this.focus,
      this.all = const [], this.onOpen, this.hint = '问问小耳：这天我答应了谁什么？也可以让它帮你找哪一段'});
  @override
  State<AskBox> createState() => _AskBoxState();
}

class _Msg {
  final bool me, error;
  final String text; // 显示 / 拷贝用：去掉了 [[找到: …]]
  final String raw; // 模型原话，进历史
  final List<String> found;
  const _Msg(this.me, this.text, {this.error = false, String? raw, this.found = const []}) : raw = raw ?? text;
}

class _AskBoxState extends State<AskBox> {
  final _q = TextEditingController();
  final _scroll = ScrollController();
  final _msgs = <_Msg>[];
  bool _busy = false, _open = false;
  int _gen = 0; // 清空 / 换了资料后，路上的回答作废
  bool _keep = false; // 点了找到的卡片跳到别的日子：这次换 topic 不清空对话

  @override
  void didUpdateWidget(AskBox old) {
    super.didUpdateWidget(old);
    if (old.topic != widget.topic && !_keep) _clear();
  }

  void _openFound(Scene s) {
    _keep = true;
    widget.onOpen?.call(s);
    WidgetsBinding.instance.addPostFrameCallback((_) => _keep = false);
  }

  Scene? _byId(String id) =>
      widget.all.where((s) => s.id == id).firstOrNull ?? widget.scenes.where((s) => s.id == id).firstOrNull;

  @override
  void dispose() {
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _clear() {
    _gen++;
    _msgs.clear();
    _busy = false;
    _open = false;
  }

  List<Turn> get _history => [
        for (var i = 0; i + 1 < _msgs.length; i++)
          if (_msgs[i].me && !_msgs[i + 1].me && !_msgs[i + 1].error) Turn(_msgs[i].text, _msgs[i + 1].raw),
      ];

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
        }
      });

  Future<void> _ask() async {
    final q = _q.text.trim();
    if (q.isEmpty || _busy) return;
    final messages =
        buildAskMessages(scenes: widget.scenes, focus: widget.focus, all: widget.all, history: _history, question: q);
    final gen = _gen;
    setState(() {
      _msgs.add(_Msg(true, q));
      _busy = true;
      _open = true;
      _q.clear();
    });
    _toBottom();
    _Msg answer;
    try {
      final a = await Llm.instance!.chatMessages(messages, temperature: 0.5);
      final (clean, ids) = parseFound(a);
      answer = a.isEmpty
          ? const _Msg(false, '模型没回内容，再问一次试试。', error: true)
          : _Msg(false, clean.isEmpty && ids.isNotEmpty ? '找到这几段：' : clean, raw: a, found: ids);
    } catch (e) {
      answer = _Msg(false, '没问成：$e', error: true);
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      _msgs.add(answer);
      _busy = false;
    });
    _toBottom();
  }

  Future<void> _copy(String md) async {
    await Clipboard.setData(ClipboardData(text: md));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制'), duration: Duration(seconds: 2)));
  }

  Widget _bubble(_Msg m) {
    if (m.me) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          margin: const EdgeInsets.only(left: 48, bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(color: K.accentSoft, borderRadius: BorderRadius.circular(14)),
          child: SelectableText(m.text, style: const TextStyle(fontSize: 14.5, height: 1.6, color: K.ink)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Mascot(m.error ? 'sleep' : 'wave', size: 30),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
            decoration: BoxDecoration(
                color: m.error ? K.todoBg : K.cardDeep, borderRadius: BorderRadius.circular(14),
                border: Border.all(color: m.error ? K.todoSoft : K.line)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (m.error)
                Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 8),
                  child: SelectableText(m.text, style: const TextStyle(fontSize: 14, height: 1.6, color: K.todo)),
                )
              else
                Padding(padding: const EdgeInsets.only(right: 6), child: MdView(m.text)),
              for (final s in [for (final id in m.found) _byId(id)].nonNulls)
                Padding(padding: const EdgeInsets.only(top: 8, right: 6), child: FoundCard(scene: s, onTap: () => _openFound(s))),
              if (!m.error)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: K.mute, visualDensity: VisualDensity.compact),
                    onPressed: () => _copy(m.text),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('拷贝', style: TextStyle(fontSize: 12.5)),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _panel() => Container(
        color: K.card,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 10, 4),
            child: Row(children: [
              const Text('和小耳的对话', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute)),
              if (widget.focus != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text('正在看：${widget.focus!.title}', overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: K.faint)),
                ),
              ],
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: K.mute, visualDensity: VisualDensity.compact),
                onPressed: () => setState(_clear),
                child: const Text('清空，重新开始', style: TextStyle(fontSize: 12.5)),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: K.accent, visualDensity: VisualDensity.compact),
                onPressed: () => setState(() => _open = false),
                icon: const Icon(Icons.expand_more, size: 18),
                label: const Text('收起', style: TextStyle(fontSize: 12.5)),
              ),
            ]),
          ),
          const Divider(height: 1, color: K.line),
          Expanded(
            child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(18, 14, 18, 6), children: [
              for (final m in _msgs) _bubble(m),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 14),
                  child: Row(children: [
                    Mascot('stand', size: 30),
                    SizedBox(width: 10),
                    SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: K.accent)),
                    SizedBox(width: 8),
                    Text('小耳在写…', style: TextStyle(fontSize: 13.5, color: K.mute)),
                  ]),
                ),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: widget.child),
            if (_open && _msgs.isNotEmpty) Positioned.fill(child: _panel()),
          ]),
        ),
        if (!_open && _msgs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: K.accent, visualDensity: VisualDensity.compact),
                onPressed: () {
                  setState(() => _open = true);
                  _toBottom();
                },
                icon: const Icon(Icons.expand_less, size: 18),
                label: Text('${_busy ? '小耳在写… ' : ''}展开对话（${_history.length} 轮）', style: const TextStyle(fontSize: 12.5)),
              ),
            ),
          ),
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          padding: const EdgeInsets.fromLTRB(8, 5, 5, 5),
          decoration: BoxDecoration(
              color: K.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: K.lineStrong),
              boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 12, offset: Offset(0, 3))]),
          child: Row(children: [
            const Mascot('stand', size: 30),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _q,
                onSubmitted: (_) => _ask(),
                decoration: InputDecoration(hintText: _msgs.isEmpty ? widget.hint : '接着问，或者让小耳改一改…'),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: K.accent, minimumSize: const Size(56, 40)),
              onPressed: _busy ? null : _ask,
              child: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('问'),
            ),
          ]),
        ),
      ]);
}
/// 对话里小耳找到的一段：日期钟点 + 类别 + 标题 + 事件，点了打开。
class FoundCard extends StatelessWidget {
  final Scene scene;
  final VoidCallback onTap;
  const FoundCard({super.key, required this.scene, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final s = scene;
    return Material(
      color: K.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: K.accentEdge)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('${s.start.month}/${s.start.day} ${hm(s.start)}',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: K.accent,
                          fontFeatures: [FontFeature.tabularFigures()])),
                  Chip2(s.category),
                  Text(s.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: K.ink)),
                ]),
                if (s.event.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(s.event, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: K.mute, height: 1.5)),
                ],
              ]),
            ),
            const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.chevron_right, size: 18, color: K.accent)),
          ]),
        ),
      ),
    );
  }
}

// ───────── 右栏：场景详情 ─────────

int _secs(String clock) {
  final p = clock.split(':').map(int.parse).toList();
  return p[0] * 3600 + p[1] * 60 + (p.length > 2 ? p[2] : 0);
}

class SceneDetail extends StatelessWidget {
  final Scene scene;
  final Player player;
  final Store store;
  final double top; // 宽屏顶上留给拖动条
  const SceneDetail({super.key, required this.scene, required this.player, required this.store, this.top = 24});

  double _offsetOf(String clock) {
    final st = scene.start;
    final s0 = st.hour * 3600 + st.minute * 60 + st.second;
    return scene.offset + (_secs(clock) - s0 + 86400) % 86400;
  }

  void _play(String clock) => player.play(store, scene.stem, _offsetOf(clock), clock);

  Widget _box(String head, IconData icon, Color color, List<Widget> lines, {Color? bg}) => Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        decoration: BoxDecoration(color: bg ?? K.cardDeep, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Label(head, color: color),
          const SizedBox(height: 8),
          ...lines,
        ]),
      );

  Widget _point(String x, Color dot) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 9, right: 8),
            child: Container(width: 5, height: 5, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          ),
          Expanded(child: Text(x, style: const TextStyle(fontSize: 14, height: 1.7))),
        ]),
      );

  Widget _ts(String clock) => InkWell(
        onTap: () => _play(clock),
        child: Text(clock.substring(0, 5), style: const TextStyle(color: K.accent, fontFeatures: [FontFeature.tabularFigures()])),
      );

  @override
  Widget build(BuildContext context) {
    final s = scene;
    Widget meta(IconData i, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 14, color: K.faint),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(fontSize: 13, color: K.faint)),
        ]);
    final todo = [
      for (final a in s.actions) '${a['text']}${(a['who'] ?? '').toString().isNotEmpty ? '（${a['who']}）' : ''}',
      for (final r in s.reminders) '${r['text']}${(r['when'] ?? '').toString().isNotEmpty ? ' · ${r['when']}' : ''}',
    ];
    const body = TextStyle(fontSize: 14, height: 1.7);
    return ListView(key: PageStorageKey(s.id), padding: EdgeInsets.fromLTRB(32, top, 32, 32), children: [
      Wrap(spacing: 14, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Chip2(s.category),
        meta(Icons.schedule, '${hm(s.start)}–${hm(s.end)} · ${duration(s.end.difference(s.start))}'),
        if (s.place.isNotEmpty) meta(Icons.place_outlined, s.place),
        if (s.people.isNotEmpty) meta(Icons.people_outline, s.people.join('、')),
        if (s.subject.isNotEmpty) meta(Icons.travel_explore, '调研对象：${s.subject}'),
      ]),
      const SizedBox(height: 10),
      SelectableText(s.title, style: K.title(26).copyWith(color: K.ink)),
      const SizedBox(height: 2),
      const Squiggle(width: 96),
      const SizedBox(height: 8),
      SelectableText(s.event, style: const TextStyle(fontSize: 15, height: 1.7)),
      const SizedBox(height: 16),
      if (!s.noise) ...[NoteCard(scene: s, store: store), const SizedBox(height: 12)],
      if (s.body.isEmpty && s.minutes != null) ...[Minutes(scene: s), const SizedBox(height: 12)],
      if (s.body.isEmpty) LayoutBuilder(builder: (_, c) {
        final boxes = [
          if (s.valuable.isNotEmpty || s.views.isNotEmpty)
            _box('有价值的内容', Icons.auto_awesome_outlined, K.ink,
                [for (final x in [...s.views, ...s.valuable]) _point(x, K.accent)]),
          if (todo.isNotEmpty)
            _box('下一步 / 提醒', Icons.check_circle_outline, K.todo, [for (final x in todo) _point(x, K.todo)],
                bg: K.todoBg),
        ];
        if (boxes.length < 2 || c.maxWidth < 520) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final b in boxes) Padding(padding: const EdgeInsets.only(bottom: 12), child: b)]);
        }
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: boxes[0]),
            const SizedBox(width: 12),
            Expanded(child: boxes[1]),
          ]),
        );
      }),
      if (s.body.isEmpty && s.memorable.isNotEmpty) ...[
        const SizedBox(height: 12),
        _box('值得记住的', Icons.format_quote, K.ink, [
          for (final m in s.memorable)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if ((m['t'] ?? '').toString().length >= 5) ...[_ts(m['t']), const SizedBox(width: 8)],
                Expanded(child: Text('「${m['text']}」', style: body)),
              ]),
            ),
        ]),
      ],
      const SizedBox(height: 18),
      const Row(children: [
        Label('逐字稿'),
        SizedBox(width: 10),
        Text('点时间从那里听', style: TextStyle(fontSize: 12, color: K.faint)),
      ]),
      const SizedBox(height: 8),
      ListenableBuilder(
        listenable: player,
        builder: (_, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final line in s.text)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: player.stem == s.stem && player.label == line[0] ? K.accentSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(6)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _ts(line[0]),
                const SizedBox(width: 8),
                Expanded(child: SelectableText(line[1], style: body)),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

// ───────── 按类别整理好的笔记 ─────────

class NoteCard extends StatefulWidget {
  final Scene scene;
  final Store store;
  const NoteCard({super.key, required this.scene, required this.store});
  @override
  State<NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<NoteCard> {
  bool _busy = false;

  /// 按现在的模板（资料文件夹/模板/<类别>.md，改过就按改过的）重新整理这一段。
  Future<void> _redo() async {
    setState(() => _busy = true);
    final s = widget.scene;
    try {
      s.d['body'] = await Analyzer.of(widget.store.lib, Llm.instance!).note(s);
      await widget.store.putScene(s);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('没整理成：$e')));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scene;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 16),
      decoration: BoxDecoration(color: K.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: K.accentEdge)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Label(catFolder(s.category), color: K.accent),
          const Spacer(),
          if (s.body.isNotEmpty)
            IconButton(
              tooltip: '复制这份笔记',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy_rounded, size: 17, color: K.mute),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: '# ${s.title}\n\n${s.body}'));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('复制好了，可以直接粘到微信 / 飞书')));
                }
              },
            ),
          if (s.d['file'] != null && Platform.isMacOS)
            IconButton(
              tooltip: '在 Finder 里看这份笔记',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.folder_open_outlined, size: 17, color: K.mute),
              onPressed: () => Process.run('open', ['-R', s.d['file']]),
            ),
          TextButton(
            onPressed: _busy ? null : _redo,
            style: TextButton.styleFrom(foregroundColor: K.accent, visualDensity: VisualDensity.compact),
            child: _busy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: K.accent))
                : Text(s.body.isEmpty ? '按模板整理' : '重新整理'),
          ),
        ]),
        const SizedBox(height: 6),
        if (s.body.isNotEmpty) MdView(s.body) else const Text('这段还没按类别整理过。', style: TextStyle(color: K.faint)),
      ]),
    );
  }
}

// ───────── 会议纪要（旧版：开会 / 商业洽谈） ─────────

class Minutes extends StatelessWidget {
  final Scene scene;
  const Minutes({super.key, required this.scene});

  static const _body = TextStyle(fontSize: 14, height: 1.7);

  Widget _head(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute, letterSpacing: 1)),
      );

  Widget _li(String lead, String x, {Color color = K.ink}) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 22, child: Text(lead, style: TextStyle(fontSize: 14, height: 1.7, color: color))),
          Expanded(child: SelectableText(x, style: _body)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final m = scene.minutes!;
    List<String> strs(String k) => List<String>.from(m[k] ?? const []);
    final agenda = List<Map<String, dynamic>>.from((m['agenda'] as List? ?? const []).map((x) => Map<String, dynamic>.from(x)));
    final todos = List<Map<String, dynamic>>.from((m['todos'] as List? ?? const []).map((x) => Map<String, dynamic>.from(x)));
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: K.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: K.accentEdge),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Label('会议纪要', color: K.accent),
          const Spacer(),
          if (scene.minutesMd.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: scene.minutesMd));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('纪要已复制，可以直接粘到微信 / 飞书')));
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('复制纪要'),
              style: TextButton.styleFrom(foregroundColor: K.accent),
            ),
        ]),
        const SizedBox(height: 4),
        SelectableText((m['topic'] ?? '').toString(), style: K.title(19).copyWith(color: K.ink)),
        if (strs('attendees').isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('相关人：${strs('attendees').join('、')}', style: const TextStyle(fontSize: 13, color: K.faint)),
        ],
        if ((m['summary'] ?? '').toString().isNotEmpty) ...[_head('概要'), SelectableText(m['summary'], style: _body)],
        if (agenda.isNotEmpty) ...[
          _head('讨论内容'),
          for (final (i, a) in agenda.indexed) ...[
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8, bottom: 2),
              child: Text('${i + 1}. ${a['title']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: K.ink)),
            ),
            for (final x in List<String>.from(a['points'] ?? const [])) _li('·', x, color: K.accent),
            if ((a['conclusion'] ?? '').toString().isNotEmpty) _li('→', '结论：${a['conclusion']}', color: K.accent),
          ],
        ],
        if (strs('decisions').isNotEmpty) ...[
          _head('决议'),
          for (final (i, x) in strs('decisions').indexed) _li('${i + 1}.', x, color: K.accent),
        ],
        if (todos.isNotEmpty) ...[
          _head('待办'),
          for (final t in todos)
            _li('☐', [
              t['task'],
              if ((t['owner'] ?? '').toString().isNotEmpty) '负责：${t['owner']}',
              if ((t['due'] ?? '').toString().isNotEmpty) '截止：${t['due']}',
            ].join(' · '), color: K.todo),
        ],
        if (strs('open').isNotEmpty) ...[_head('待定问题'), for (final x in strs('open')) _li('?', x, color: K.faint)],
        if ((m['next'] ?? '').toString().isNotEmpty) ...[_head('下次会议'), SelectableText(m['next'], style: _body)],
      ]),
    );
  }
}

// ───────── 播放 ─────────

class Player extends ChangeNotifier {
  final _p = AudioPlayer();
  String? stem;
  String label = '';
  Duration pos = Duration.zero, total = Duration.zero;
  bool playing = false;

  Player() {
    _p.onPositionChanged.listen((d) {
      pos = d;
      notifyListeners();
    });
    _p.onDurationChanged.listen((d) {
      total = d;
      notifyListeners();
    });
    _p.onPlayerStateChanged.listen((s) {
      playing = s == PlayerState.playing;
      notifyListeners();
    });
  }

  Future<void> play(Store store, String stem, double offset, String label) async {
    final f = store.audio(stem);
    if (!await f.exists()) return;
    if (this.stem != stem) {
      await _p.setSourceDeviceFile(f.path);
      this.stem = stem;
    }
    this.label = label;
    await _p.seek(Duration(milliseconds: (offset * 1000).round()));
    await _p.resume();
    notifyListeners();
  }

  Future<void> toggle() => playing ? _p.pause() : _p.resume();
  Future<void> seekTo(double frac) => _p.seek(total * frac);

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }
}

class PlayerBar extends StatelessWidget {
  final Player player;
  const PlayerBar({super.key, required this.player});
  String _t(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: player,
        builder: (_, _) => Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: const BoxDecoration(color: K.bar, border: Border(top: BorderSide(color: K.line))),
          child: Row(children: [
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: K.ink),
              tooltip: player.playing ? '暂停' : '播放',
              onPressed: player.toggle,
              icon: Icon(player.playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text(_t(player.pos), style: const TextStyle(fontSize: 13, color: K.mute)),
            Expanded(
              child: Slider(
                activeColor: K.accent,
                inactiveColor: K.lineStrong,
                value: player.total.inMilliseconds == 0
                    ? 0
                    : (player.pos.inMilliseconds / player.total.inMilliseconds).clamp(0, 1).toDouble(),
                onChanged: player.seekTo,
              ),
            ),
            Text(_t(player.total), style: const TextStyle(fontSize: 13, color: K.mute)),
          ]),
        ),
      );
}
