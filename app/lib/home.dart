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
          TopBar(syncer: widget.syncer, store: store, onHandoff: () => showHandoff(context, store, day, scenes)),
          Expanded(child: wide ? _wide() : _narrow()),
          if (wide)
            ListenableBuilder(
                listenable: player, builder: (_, _) => player.stem == null ? const SizedBox() : PlayerBar(player: player)),
        ]),
      ),
    );
  }

  Widget _wide() => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: 200, child: DayNav(store: store, day: day, onPick: pickDay)),
        const VerticalDivider(width: 1),
        SizedBox(
          width: (MediaQuery.sizeOf(context).width * 0.36).clamp(360, 470).toDouble(),
          child: DayColumn(
              store: store, day: day, scenes: scenes, selected: scene?.id,
              onPick: (s) => setState(() => _sceneId = s.id)),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: scene == null ? const SizedBox() : SceneDetail(scene: scene!, player: player, store: store)),
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

// ───────── 顶栏：卡的状态 + 交给 Agent ─────────

class TopBar extends StatelessWidget {
  final Syncer syncer;
  final Store store;
  final VoidCallback onHandoff;
  const TopBar({super.key, required this.syncer, required this.store, required this.onHandoff});

  String _status() {
    final c = syncer.card;
    final pend = store.pending;
    final pulling = pend.where((r) => r.stage == 'pulling').toList();
    if (pulling.isNotEmpty) {
      final r = pulling.first;
      return '正在从卡上拉录音 ${r.size > 0 ? (r.got * 100 ~/ r.size) : 0}%';
    }
    final working = pend.where((r) => ['pulled', 'uploading', 'processing'].contains(r.stage)).length;
    if (working > 0) return '云端整理中 · $working 段';
    final name = syncer.boundName;
    if (c.connected) {
      final b = c.info?.battery;
      return '$name 已连接${b == null ? '' : ' · ${c.info!.charging ? '充电中' : '电量 $b%'}'}';
    }
    if (syncer.boundId == null) return c.scanning ? '正在找录音卡…' : '把录音卡开机，放在旁边';
    if (c.scanning) return '正在找 $name…';
    if (c.lastSeen != null) return '$name · 上次同步 ${hm(c.lastSeen!)}';
    return c.error ?? '等 $name 靠近';
  }

  @override
  Widget build(BuildContext context) {
    final live = syncer.card.connected || store.pending.isNotEmpty;
    return Container(
      height: 52,
      // Mac：标题栏透明，左边让出红绿灯的位置
      padding: EdgeInsets.only(left: Platform.isMacOS ? 78 : 16, right: 16),
      decoration: const BoxDecoration(color: K.bar, border: Border(bottom: BorderSide(color: K.line))),
      child: Row(children: [
        IconButton(
          tooltip: '设置',
          icon: const Icon(Icons.tune, size: 20, color: K.mute),
          onPressed: () => showSettings(context, store, syncer),
        ),
        const Spacer(),
        Container(width: 8, height: 8, decoration: BoxDecoration(color: live ? K.greenLive : K.line, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Flexible(child: Text(_status(), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: K.mute))),
        if (syncer.boundId == null && syncer.card.choices.length > 1)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: K.green, minimumSize: const Size(0, 32)),
              onPressed: () => showCardPicker(context, syncer),
              child: Text('附近有 ${syncer.card.choices.length} 张卡，选你的'),
            ),
          ),
        IconButton(
          tooltip: '现在同步',
          icon: const Icon(Icons.refresh, size: 18, color: K.mute),
          onPressed: () => syncer.run(),
        ),
        const Spacer(),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: K.ink, foregroundColor: K.paper, minimumSize: const Size(0, 36)),
          onPressed: onHandoff,
          icon: const Icon(Icons.arrow_forward, size: 16),
          label: const Text('交给 Agent'),
        ),
      ]),
    );
  }
}

// ───────── 左栏：日子 ─────────

class DayNav extends StatelessWidget {
  final Store store;
  final String? day;
  final void Function(String) onPick;
  const DayNav({super.key, required this.store, required this.day, required this.onPick});

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.fromLTRB(12, 18, 12, 12), children: [
        Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 14), child: Text('小耳录音卡', style: K.title(20))),
        for (final e in store.days.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Material(
              color: e.key == day ? K.greenSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () => onPick(e.key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Row(children: [
                    Expanded(
                        child: Text(dayTitle(e.key, short: true),
                            style: TextStyle(
                                fontWeight: e.key == day ? FontWeight.w600 : FontWeight.w400,
                                color: e.key == day ? const Color(0xFF3D6A1B) : K.ink))),
                    Text('${e.value.length} 段', style: TextStyle(color: e.key == day ? const Color(0xFF3D6A1B) : K.faint)),
                  ]),
                ),
              ),
            ),
          ),
      ]);
}

// ───────── 中栏：当天时间线 + 问答 ─────────

class DayColumn extends StatelessWidget {
  final Store store;
  final String? day;
  final List<Scene> scenes;
  final String? selected;
  final void Function(Scene) onPick;
  const DayColumn(
      {super.key, required this.store, required this.day, required this.scenes, required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    if (day == null) return const EmptyState();
    final total = scenes.fold<Duration>(Duration.zero, (a, s) => a + s.end.difference(s.start));
    final todo = scenes.fold<int>(0, (a, s) => a + s.todo);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(dayTitle(day!), style: K.title(26)),
          const SizedBox(height: 4),
          Text('录了 ${duration(total)} · ${scenes.length} 个场景${todo > 0 ? ' · $todo 件要办' : ''}',
              style: const TextStyle(fontSize: 14, color: K.mute)),
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
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12), side: BorderSide(color: selected ? K.greenEdge : Colors.transparent)),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: 52,
                    child: Text(hm(scene.start),
                        style: TextStyle(fontSize: 13, color: selected ? K.green : K.faint,
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

class EmptyState extends StatelessWidget {
  const EmptyState({super.key});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('还没有录音', style: K.title(22)),
            const SizedBox(height: 10),
            const Text('录音卡开机、放在旁边，App 会自动把录音拉过来、整理好。\n第一次会问你要不要用蓝牙，点允许。',
                textAlign: TextAlign.center, style: TextStyle(color: K.mute, height: 1.7)),
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
      // 先问当天；当天找不到的，模型会说没找到
      final ctx = [for (final s in widget.scenes) Map<String, dynamic>.from(s.d)..remove('text')];
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
        title: Text(q, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: SelectableText(answer, style: const TextStyle(fontSize: 15, height: 1.7)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        decoration: BoxDecoration(
            color: K.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFD6D2C6))),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _q,
              onSubmitted: (_) => _ask(),
              decoration: const InputDecoration(hintText: '问问这天的录音…'),
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
  const SceneDetail({super.key, required this.scene, required this.player, required this.store});

  double _offsetOf(String clock) {
    final st = scene.start;
    final s0 = st.hour * 3600 + st.minute * 60 + st.second;
    return scene.offset + (_secs(clock) - s0 + 86400) % 86400;
  }

  void _play(String clock) => player.play(store, scene.stem, _offsetOf(clock), clock);

  Widget _box(String head, Color color, List<Widget> lines) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(color: K.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2DFD6))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(head, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 6),
          ...lines,
        ]),
      );

  Widget _ts(String clock) => InkWell(
        onTap: () => _play(clock),
        child: Text(clock.substring(0, 5), style: const TextStyle(color: K.green, fontFeatures: [FontFeature.tabularFigures()])),
      );

  @override
  Widget build(BuildContext context) {
    final s = scene;
    final meta = [
      '${hm(s.start)}–${hm(s.end)}', duration(s.end.difference(s.start)), s.category,
      if (s.place.isNotEmpty) s.place, if (s.people.isNotEmpty) s.people.join('、'),
    ].join(' · ');
    final todo = [
      for (final a in s.actions) '${a['text']}${(a['who'] ?? '').toString().isNotEmpty ? '（${a['who']}）' : ''}',
      for (final r in s.reminders) '${r['text']}${(r['when'] ?? '').toString().isNotEmpty ? ' · ${r['when']}' : ''}',
    ];
    const body = TextStyle(fontSize: 14, height: 1.7);
    return ListView(padding: const EdgeInsets.fromLTRB(28, 24, 28, 24), children: [
      Text(meta, style: const TextStyle(fontSize: 13, color: K.faint)),
      const SizedBox(height: 4),
      SelectableText(s.title, style: K.title(24)),
      const SizedBox(height: 8),
      SelectableText(s.event, style: const TextStyle(fontSize: 15, height: 1.7)),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (_, c) {
        final boxes = [
          if (s.valuable.isNotEmpty || s.views.isNotEmpty)
            _box('有价值的内容', K.green, [for (final x in [...s.views, ...s.valuable]) Text(x, style: body)]),
          if (todo.isNotEmpty) _box('下一步 / 提醒', K.todo, [for (final x in todo) Text(x, style: body)]),
        ];
        if (boxes.length < 2 || c.maxWidth < 520) {
          return Column(children: [for (final b in boxes) Padding(padding: const EdgeInsets.only(bottom: 12), child: b)]);
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
        _box('值得记住的', K.green, [
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
      const Text('逐字稿 · 点时间从那里听', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.green)),
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
              style: IconButton.styleFrom(backgroundColor: K.ink),
              tooltip: player.playing ? '暂停' : '播放',
              onPressed: player.toggle,
              icon: Icon(player.playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text(_t(player.pos), style: const TextStyle(fontSize: 13, color: K.mute)),
            Expanded(
              child: Slider(
                activeColor: K.green,
                inactiveColor: const Color(0xFFD6D2C6),
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
