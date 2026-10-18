// 主界面（方向 A · 今天时间线）：宽屏三栏 = 日子 / 当天时间线 + 问答 / 场景详情 + 播放条；手机 = 当天列表 → 点进详情。
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'cards.dart';
import 'cloud.dart';
import 'handoff.dart';
import 'settings.dart';
import 'store.dart';
import 'sync.dart';
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
  final player = Player();

  Store get store => widget.store;

  @override
  void initState() {
    super.initState();
    widget.syncer.onChange = () {
      if (mounted) setState(() {});
    };
    store.addListener(_onStore);
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    player.dispose();
    super.dispose();
  }

  String? get day {
    final days = store.days;
    if (_day != null && days.containsKey(_day)) return _day;
    return days.isEmpty ? null : days.keys.first;
  }

  List<Scene> get scenes => day == null ? [] : store.days[day]!;

  Scene? get scene {
    final l = scenes;
    if (l.isEmpty) return null;
    return l.firstWhere((s) => s.id == _sceneId, orElse: () => l.firstWhere((s) => s.todo > 0, orElse: () => l.first));
  }

  void _handoff() => showHandoff(context, store, day, scenes);

  void pickDay(String d) => setState(() {
        _day = d;
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
        SizedBox(width: 228, child: Sidebar(store: store, syncer: widget.syncer, day: day, onPick: pickDay)),
        const VerticalDivider(width: 1),
        SizedBox(
          width: (MediaQuery.sizeOf(context).width * 0.36).clamp(360, 470).toDouble(),
          child: DayColumn(
              store: store, day: day, scenes: scenes, selected: scene?.id, onHandoff: _handoff,
              onPick: (s) => setState(() => _sceneId = s.id)),
        ),
        const VerticalDivider(width: 1),
        Expanded(
            child: scene == null
                ? const Hint('sleep', '还没有内容', '有录音以后，点左边任意一段，这里看要点和逐字稿。')
                : SceneDetail(scene: scene!, player: player, store: store, top: 44)),
      ]);

  Widget _narrow() => Column(children: [
        if (store.days.length > 1)
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (final d in store.days.keys)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                  child: ChoiceChip(label: Text(dayTitle(d, short: true)), selected: d == day, onSelected: (_) => pickDay(d)),
                ),
            ]),
          ),
        Expanded(
          child: DayColumn(
            store: store, day: day, scenes: scenes, selected: null,
            onPick: (s) => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Scaffold(
                      appBar: AppBar(backgroundColor: K.paper, title: Text(s.title)),
                      body: Column(children: [
                        Expanded(child: SceneDetail(scene: s, player: player, store: store)),
                        ListenableBuilder(
                            listenable: player,
                            builder: (_, _) => player.stem == null ? const SizedBox() : PlayerBar(player: player)),
                      ]),
                    ))),
          ),
        ),
      ]);
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
  if (working > 0) return (title, '云端整理中 · $working 段');
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
            backgroundColor: K.green, foregroundColor: Colors.white, minimumSize: Size(0, compact ? 34 : 38),
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
  final String? day;
  final void Function(String) onPick;
  const Sidebar({super.key, required this.store, required this.syncer, required this.day, required this.onPick});

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
              Text('小耳录音卡', style: K.title(18)),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(22, 0, 16, 6),
            child: Text('每天', style: TextStyle(fontSize: 12, color: K.faint, fontWeight: FontWeight.w600, letterSpacing: 1)),
          ),
          Expanded(child: DayNav(store: store, day: day, onPick: onPick)),
          CardPanel(syncer: syncer, store: store),
        ]),
      );
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
              color: e.key == day ? K.greenSoft : Colors.transparent,
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
                                color: e.key == day ? K.green : K.mute))),
                    Text('${e.value.length}',
                        style: TextStyle(fontSize: 12, color: e.key == day ? K.green : K.faint,
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
                    decoration: BoxDecoration(color: live ? K.greenLive : K.line, shape: BoxShape.circle)),
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
              style: FilledButton.styleFrom(backgroundColor: K.green, minimumSize: const Size(0, 34)),
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
  const DayColumn(
      {super.key, required this.store, required this.day, required this.scenes, required this.selected, required this.onPick,
      this.onHandoff});

  @override
  Widget build(BuildContext context) {
    if (day == null) return const Hint('wave', '还没有录音', '录音卡开机、放在旁边，小耳会自动把录音拉过来、整理好。\n第一次会问你要不要用蓝牙，点允许。');
    final total = scenes.fold<Duration>(Duration.zero, (a, s) => a + s.end.difference(s.start));
    final todo = scenes.fold<int>(0, (a, s) => a + s.todo);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(24, onHandoff != null ? 44 : 20, 20, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(dayTitle(day!), style: K.title(26)),
              const SizedBox(height: 6),
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
        child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), children: [
          for (final s in scenes) SceneRow(scene: s, selected: s.id == selected, onTap: () => onPick(s)),
        ]),
      ),
      AskBox(store: store, scenes: scenes),
    ]);
  }
}

class SceneRow extends StatelessWidget {
  final Scene scene;
  final bool selected;
  final VoidCallback onTap;
  const SceneRow({super.key, required this.scene, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: selected ? K.card : Colors.transparent,
          elevation: selected ? 0.6 : 0,
          shadowColor: const Color(0x22000000),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14), side: BorderSide(color: selected ? K.greenEdge : Colors.transparent)),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            hoverColor: const Color(0x0A000000),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 13, 14, 13),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: 52,
                    child: Text(hm(scene.start),
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? K.green : K.faint,
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
            color: todo ? K.todoSoft : K.card, borderRadius: BorderRadius.circular(99),
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

class AskBox extends StatefulWidget {
  final Store store;
  final List<Scene> scenes;
  const AskBox({super.key, required this.store, required this.scenes});
  @override
  State<AskBox> createState() => _AskBoxState();
}

class _AskBoxState extends State<AskBox> {
  final _q = TextEditingController();
  bool _busy = false;

  Future<void> _ask() async {
    final q = _q.text.trim();
    if (q.isEmpty || _busy) return;
    setState(() => _busy = true);
    String answer;
    try {
      // 问当天：要点 + 逐字稿都给它（云端截到 6 万字）；当天找不到的，模型会说没找到
      final ctx = [for (final s in widget.scenes) Map<String, dynamic>.from(s.d)];
      answer = await Cloud.instance!.ask(q, ctx);
    } catch (e) {
      answer = '没问成：$e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: K.card,
        title: Row(children: [
          const Mascot('wave', size: 52),
          const SizedBox(width: 12),
          Expanded(child: Text(q, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
        ]),
        content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SelectableText(answer, style: const TextStyle(fontSize: 15, height: 1.7))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Container(
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
              decoration: const InputDecoration(hintText: '问问小耳：这天我答应了谁什么？'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: K.green, minimumSize: const Size(56, 40)),
            onPressed: _busy ? null : _ask,
            child: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('问'),
          ),
        ]),
      );
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
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        decoration: BoxDecoration(
            color: bg ?? K.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: K.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(head, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
          ]),
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
        child: Text(clock.substring(0, 5), style: const TextStyle(color: K.green, fontFeatures: [FontFeature.tabularFigures()])),
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
    return ListView(padding: EdgeInsets.fromLTRB(32, top, 32, 32), children: [
      Wrap(spacing: 14, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Chip2(s.category),
        meta(Icons.schedule, '${hm(s.start)}–${hm(s.end)} · ${duration(s.end.difference(s.start))}'),
        if (s.place.isNotEmpty) meta(Icons.place_outlined, s.place),
        if (s.people.isNotEmpty) meta(Icons.people_outline, s.people.join('、')),
      ]),
      const SizedBox(height: 10),
      SelectableText(s.title, style: K.title(26)),
      const SizedBox(height: 8),
      SelectableText(s.event, style: const TextStyle(fontSize: 15, height: 1.7)),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (_, c) {
        final boxes = [
          if (s.valuable.isNotEmpty || s.views.isNotEmpty)
            _box('有价值的内容', Icons.auto_awesome_outlined, K.green,
                [for (final x in [...s.views, ...s.valuable]) _point(x, K.greenLive)]),
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
      if (s.memorable.isNotEmpty) ...[
        const SizedBox(height: 12),
        _box('值得记住的', Icons.format_quote, K.green, [
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
        Icon(Icons.notes, size: 16, color: K.green),
        SizedBox(width: 6),
        Text('逐字稿', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.green)),
        SizedBox(width: 8),
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
                  color: player.stem == s.stem && player.label == line[0] ? K.greenSoft : Colors.transparent,
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
              style: IconButton.styleFrom(backgroundColor: K.green),
              tooltip: player.playing ? '暂停' : '播放',
              onPressed: player.toggle,
              icon: Icon(player.playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text(_t(player.pos), style: const TextStyle(fontSize: 13, color: K.mute)),
            Expanded(
              child: Slider(
                activeColor: K.green,
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
