// 主界面（方向 A · 今天时间线）：宽屏三栏 = 日子 / 当天时间线 + 问答 / 场景详情 + 播放条；手机 = 当天列表 → 点进详情。
import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'analyze.dart';
import 'bean/sync.dart';
import 'bean/view.dart';
import 'card/view.dart';
import 'actions.dart';
import 'ask.dart';
import 'cards.dart';
import 'drafts.dart';
import 'handoff.dart';
import 'ideas.dart';
import 'live.dart';
import 'live_view.dart';
import 'llm.dart';
import 'md_view.dart';
import 'people.dart';
import 'progress.dart';
import 'search.dart';
import 'settings.dart';
import 'store.dart';
import 'sync.dart';
import 'templates.dart';
import 'theme.dart';
import 'todos.dart';
import 'transcript.dart';
import 'weekly.dart';

class Home extends StatefulWidget {
  final Store store;
  final Syncer syncer;
  final LiveSession live;
  final BeanSyncer? bean;
  final bool askOwnKey; // 第一次打开问一句「填你自己的模型 key」（App 里开，测试里不弹）
  const Home({super.key, required this.store, required this.syncer, required this.live, this.bean, this.askOwnKey = false});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String? _day;
  String? _sceneId;
  int _mode = 0; // 0 按天看 · 1 按类别看 · 2 按人看 · 3 待办 · 4 每周回顾 · 5 现场会议 · 6 录音豆 · 7 录音卡
  bool get _byCat => _mode == 1;
  bool get _byPerson => _mode == 2;
  bool get _todos => _mode == 3;
  bool get _weeks => _mode == 4;
  bool get _live => _mode == 5;
  bool get _beanMode => _mode == 6 && widget.bean != null;
  bool get _cardMode => _mode == 7;
  String? _cat;
  String? _person;
  String? _week; // 每周回顾：选中的那周（2026-W42）
  bool _ideas = false; // 按类别 → 个人感悟：右栏在看「观点 · 按主题」
  final player = Player();
  final _search = TextEditingController();
  final _askKey = GlobalKey<AskBoxState>(); // 搜索 / 按天 / 按类别来回切，对话不丢
  Timer? _debounce;
  String _query = '';
  List<SearchHit>? _hits;
  List<DraftHit>? _dhits;
  String? _draft; // 右栏正在看的成稿（文件路径）

  Store get store => widget.store;

  bool get searching => searchTerms(_query).isNotEmpty;
  List<SearchHit> get hits => _hits ??= searchScenes(store.scenes, _query);
  List<DraftHit> get draftHits => _dhits ??= searchDrafts(store.drafts, _query);

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) {
        setState(() {
          _query = v;
          _hits = null;
          _dhits = null;
        });
      }
    });
  }

  void _resetSearch() {
    _debounce?.cancel();
    _search.clear();
    _query = '';
    _hits = null;
    _dhits = null;
  }

  void clearSearch() => setState(_resetSearch);

  /// 对话里小耳找到的那段：切到那天，右栏打开它。
  void openFound(Scene s) {
    setState(() {
      _resetSearch();
      _mode = 0;
      _day = s.dayKey;
      _sceneId = s.id;
      _draft = null;
    });
    if (MediaQuery.sizeOf(context).width < 900) _openNarrow(s);
  }

  @override
  void initState() {
    super.initState();
    widget.syncer.onChange = () {
      if (mounted) setState(() {});
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _askOwnKey());
    // 截图 / 自检用：LUYINKA_START_MODE=7 打开就进录音卡页（6 录音豆、5 现场会议、3 待办…）；SETTINGS=1 打开设置
    final m = int.tryParse(Platform.environment['LUYINKA_START_MODE'] ?? '');
    if (m != null) _mode = m;
    final sec = Platform.environment['LUYINKA_START_SETTINGS'];
    if (sec != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => showSettings(context, store, widget.syncer, section: sec));
    }
    store.addListener(_onStore);
  }

  /// 第一次打开：还没填自己的模型 key，说一声（只问一次；之后问答框上面一直有一行小字提醒）
  Future<void> _askOwnKey() async {
    if (!mounted || !widget.askOwnKey || widget.syncer.llm.own || store.settings['ownKeyTold'] == true) return;
    store.settings['ownKeyTold'] = true;
    await store.save();
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: K.card,
        title: const Text('填上你自己的大模型 key'),
        content: const Text(
          '录音转成文字在你的电脑上做，不花钱；按类别整理、写纪要、问问小耳要用大模型。\n\n'
          '现在先用小耳的体验额度（每天有限）。建议填你自己的 key：DeepSeek、通义千问、Kimi、智谱、OpenAI 都行，'
          'key 只存在这台电脑上，不经过小耳的服务器。\n\n'
          '也可以让你的 AI（Claude Code、Codex…）照资料文件夹里的「给AI的接口.md」帮你接上它想用的模型。',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('先用体验额度')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: K.cta),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('现在去填'),
          ),
        ],
      ),
    );
    if (go == true && mounted) showSettings(context, store, widget.syncer);
  }

  void _onStore() {
    if (mounted) {
      setState(() {
        _hits = null;
        _dhits = null;
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    store.removeListener(_onStore);
    player.dispose();
    super.dispose();
  }

  /// 左栏 / 手机日子条：有笔记的日子 + 正在处理的录音那天。
  List<String> get dayKeys => daysWithPending(store.days.keys, store.pending);

  String? get day {
    final days = dayKeys;
    if (_day != null && days.contains(_day)) return _day;
    return days.firstOrNull;
  }

  /// 这一天里还在处理、还没出笔记的录音：时间线里先放占位卡。
  List<Rec> get pendingToday => [
        for (final r in store.pending)
          if (day != null && recDay(r.stem) == day && store.scenesOf(r.stem).isEmpty) r,
      ];

  /// 有录音在路上：列表顶上挂横幅。
  Widget _withBanner(Widget child, {bool compact = false}) {
    if (store.pending.isEmpty) return child;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: compact ? const EdgeInsets.fromLTRB(12, 8, 12, 2) : const EdgeInsets.fromLTRB(16, 34, 16, 0),
        child: ProgressBanner(syncer: widget.syncer, store: store, compact: compact),
      ),
      Expanded(child: child),
    ]);
  }

  String? get cat {
    if (_cat == draftsKey) return draftsKey;
    final c = store.byCategory;
    if (_cat != null && c.containsKey(_cat)) return _cat;
    return c.isEmpty ? null : c.keys.first;
  }

  List<Person> get people => peopleOf(store.scenes);

  String? get person {
    final l = people;
    if (_person != null && l.any((p) => personKey(p.name) == personKey(_person!))) return _person;
    return l.isEmpty ? null : l.first.name;
  }

  List<Week> get weeks => weeksOf(store.days.keys);

  Week? get week {
    final l = weeks;
    return l.where((w) => w.key == _week).firstOrNull ?? l.firstOrNull;
  }

  int get openTodos => todosOf(store.scenes).where((t) => !t.done).length;

  List<Scene> get scenes => _todos
      ? store.scenes.where((s) => s.todo > 0).toList()
      : _weeks
      ? (week == null ? [] : scenesIn(week!, store.scenes))
      : _byPerson
      ? (person == null ? [] : scenesWith(store.scenes, person!))
      : _byCat
          ? (cat == null || cat == draftsKey ? [] : store.byCategory[cat]!)
          : (day == null ? [] : store.days[day] ?? []);

  bool get inDrafts => _byCat && cat == draftsKey && !searching;

  /// 右栏要显示的成稿：成稿列表里选中的（没选就第一篇），或者搜索结果里点了的那篇。
  Draft? get draft {
    if (searching) return draftHits.map((h) => h.draft).where((d) => d.path == _draft).firstOrNull;
    if (!inDrafts) return null;
    final l = store.drafts;
    return l.where((d) => d.path == _draft).firstOrNull ?? l.firstOrNull;
  }

  String get topic => _todos
      ? 'todo'
      : _weeks
          ? 'week:${week?.key}'
          : _byPerson
              ? 'person:$person'
              : (_byCat ? 'cat:$cat' : 'day:$day');

  /// 按类别 → 个人感悟时，右栏在看「观点 · 按主题」。
  bool get showIdeas => _ideas && _byCat && cat == '个人感悟' && !searching;

  Scene? get scene {
    // 待办 / 每周回顾：没点哪段时右栏不默认打开第一段（待办给提示，每周回顾给这周的回顾）
    if (!searching && (_todos || _weeks)) {
      return _sceneId == null ? null : (_todos ? store.scenes : scenes).where((s) => s.id == _sceneId).firstOrNull;
    }
    final l = searching ? [for (final h in hits) h.scene] : scenes;
    if (l.isEmpty) return null;
    return l.firstWhere((s) => s.id == _sceneId, orElse: () => l.firstWhere((s) => s.todo > 0, orElse: () => l.first));
  }

  void _handoff() => showHandoff(context, store, day, scenes);

  void pickDay(String d) => setState(() {
        _mode = 0; // 待办那一屏左栏还是日子，点了回到按天看
        _day = d;
        _sceneId = null;
        _draft = null;
      });

  void pickCat(String c) {
    if (c == draftsKey) store.refreshDrafts(); // 外面（Finder 里）改过、删过的也看得到
    setState(() {
      _cat = c;
      _sceneId = null;
      _draft = null;
      _ideas = false;
    });
  }

  void pickWeek(String key) => setState(() {
        _week = key;
        _sceneId = null;
        _draft = null;
      });

  /// 每周回顾：右栏回到这周的回顾。
  void _pickReview() => setState(() => _sceneId = null);

  Future<String> _chat(String system, String user) => Llm.instance!.chat(system, user, temperature: 0.3);

  void _genWeek(Week w) {
    if (!store.hasLib || Llm.instance == null) return;
    setState(() => _sceneId = null);
    Jobs.instance.run('week:${w.key}', () => generateWeekly(store.lib, w, scenesIn(w, store.scenes), _chat));
  }

  void _genIdeas() {
    if (!store.hasLib || Llm.instance == null) return;
    Jobs.instance.run('ideas', () => generateIdeasTopics(store.lib, _chat));
  }

  /// 「按主题整理观点库」：还没整理过就开始整理；右栏（手机上新开一页）看结果。
  void _openIdeas() {
    if (!store.hasLib) return;
    if (!store.lib.ideasTopicFile.existsSync()) _genIdeas();
    if (MediaQuery.sizeOf(context).width < 900) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => Scaffold(
                appBar: AppBar(backgroundColor: K.paper, title: const Text('观点 · 按主题')),
                body: IdeasView(store: store, onGenerate: _genIdeas),
              )));
      return;
    }
    setState(() {
      _ideas = true;
      _sceneId = null;
      _draft = null;
    });
  }

  void _openNarrowReview(Week w) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
            appBar: AppBar(backgroundColor: K.paper, title: Text('第 ${w.number} 周回顾')),
            body: WeekReview(store: store, week: w, onGenerate: _genWeek),
          )));

  void pickPerson(String p) => setState(() {
        _person = p;
        _sceneId = null;
        _draft = null;
      });

  void setMode(int mode) => setState(() {
        _mode = mode;
        _sceneId = null;
        _draft = null;
        _ideas = false;
      });

  void _pickScene(Scene s) => setState(() {
        _sceneId = s.id;
        _draft = null;
        _ideas = false;
      });

  void _pickDraft(Draft d) => setState(() => _draft = d.path);

  /// 右栏「拿去用」按钮：在对话里以这段为正在看的那段，发出对应的要求。手机上先退回列表，好看到对话。
  void _quick(Scene s, String label, String prompt) {
    final box = _askKey.currentState;
    if (box == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('先回到按天或按类别的列表，再点一次')));
      return;
    }
    if (MediaQuery.sizeOf(context).width < 900) Navigator.of(context).maybePop();
    box.quick(s, label, prompt);
  }

  /// 往来小结上的「见面前帮我准备」：资料只给跟这个人有关的那几段的笔记（不给逐字稿）。
  void _prep(String name) {
    final box = _askKey.currentState;
    if (box == null) return;
    box.quick(null, '见面前帮我准备：$name', prepPrompt(name), notesOnly: true);
  }

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
                store: store, syncer: widget.syncer, day: _todos ? null : day, onPick: pickDay,
                mode: _mode, cat: cat, onPickCat: pickCat, onMode: setMode,
                people: people, person: person, onPickPerson: pickPerson,
                todoCount: openTodos, weeks: weeks, week: week?.key, onPickWeek: pickWeek, live: widget.live, bean: widget.bean,
                search: SearchField(controller: _search, onChanged: _onSearch, onClear: clearSearch))),
        Expanded(child: _frosted(Container(
          margin: const EdgeInsets.fromLTRB(0, 12, 12, 12),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: K.card,
            borderRadius: BorderRadius.circular(22),
            // 深色玻璃：一圈很细的亮边（玻璃的边），影子更深
            border: K.dark ? Border.all(color: const Color(0x1FFFFFFF)) : null,
            boxShadow: [
              BoxShadow(color: K.dark ? const Color(0x66000000) : const Color(0x261F4A44), blurRadius: 24, offset: const Offset(0, 8)),
            ],
          ),
          child: _live && !searching
              ? LiveView(live: widget.live, top: 24)
              : _beanMode && !searching
              ? BeanView(bean: widget.bean!, store: store, onOpen: openFound, top: 24)
              : _cardMode && !searching
              ? CardView(syncer: widget.syncer, store: store, onOpen: openFound, top: 24)
              : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: (MediaQuery.sizeOf(context).width * 0.36).clamp(360, 470).toDouble(),
          child: _withBanner(searching
              ? SearchColumn(
                  store: store, hits: hits, scenes: scenes, topic: topic, selected: draft == null ? scene?.id : null, top: 34,
                  draftHits: draftHits, selectedDraft: draft?.path, onPickDraft: _pickDraft,
                  askKey: _askKey, onOpen: openFound, onPick: _pickScene)
              : inDrafts
                  ? DraftColumn(drafts: store.drafts, selected: draft?.path, onPick: _pickDraft, top: 34)
                  : _todos
                  ? TodoColumn(store: store, scenes: scenes, selected: scene?.id,
                      askKey: _askKey, onOpen: openFound, onPick: _pickScene, top: 34)
                  : _weeks
                  ? WeekColumn(store: store, week: week, scenes: scenes, selected: scene?.id,
                      askKey: _askKey, onOpen: openFound, onPick: _pickScene, onReview: _pickReview,
                      onGenerate: _genWeek, top: 34)
                  : _byPerson
                  ? PersonColumn(store: store, person: person, scenes: scenes, selected: scene?.id,
                      askKey: _askKey, onOpen: openFound, onPick: _pickScene, onPrep: _prep, top: 34)
                  : _byCat
                      ? CatColumn(store: store, cat: cat, scenes: scenes, selected: showIdeas ? null : scene?.id,
                          askKey: _askKey, onOpen: openFound, onPick: _pickScene, top: 34,
                          onIdeas: cat == '个人感悟' ? _openIdeas : null)
                      : DayColumn(
                          store: store, day: day, scenes: scenes, pending: pendingToday, selected: scene?.id,
                          onHandoff: _handoff, askKey: _askKey, onOpen: openFound, onPick: _pickScene)),
        ),
        VerticalDivider(width: 1, color: K.line),
        Expanded(
            child: draft != null
                ? DraftDetail(draft: draft!, top: 36)
                : inDrafts
                    ? const Hint('wave', '还没有成稿', '在对话里让小耳写好东西，点回答下面的「存成稿」，就存到这里。')
                    : showIdeas
                    ? IdeasView(store: store, onGenerate: _genIdeas, top: 36)
                    : _weeks && !searching && scene == null && week != null
                    ? WeekReview(store: store, week: week!, onGenerate: _genWeek, top: 36)
                    : scene == null
                        ? (_todos && !searching
                            ? const Hint('wave', '点一条待办', '点待办下面的来源，这里打开它来自的那一段。')
                            : const Hint('sleep', '还没有内容', '有录音以后，点左边任意一段，这里看要点和逐字稿。'))
                        : SceneDetail(scene: scene!, player: player, store: store, top: 36, onQuick: _quick,
                            onMerged: _pickScene, onRecut: widget.syncer.reanalyze)),
          ]),
        ))),
      ]);

  /// 深色玻璃：内容面板背后模糊一下（磨砂玻璃）；少女风原样
  Widget _frosted(Widget panel) => K.dark
      ? Padding(
          padding: EdgeInsets.zero,
          child: Stack(fit: StackFit.passthrough, children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30), child: const SizedBox.expand()),
                ),
              ),
            ),
            panel,
          ]),
        )
      : panel;

  Widget _narrow() => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SearchField(controller: _search, onChanged: _onSearch, onClear: clearSearch),
        ),
        if (!searching)
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              Padding(
                padding: const EdgeInsets.only(right: 10, top: 6, bottom: 6),
                child: ChoiceChip(
                    avatar: const Icon(Icons.sd_card_outlined, size: 16), label: const Text('录音卡'),
                    selected: _cardMode, onSelected: (_) => setMode(7)),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10, top: 6, bottom: 6),
                child: ChoiceChip(
                    avatar: const Icon(Icons.mic_none_rounded, size: 16), label: const Text('现场会议'),
                    selected: _live, onSelected: (_) => setMode(5)),
              ),
              if (widget.bean != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10, top: 6, bottom: 6),
                  child: ChoiceChip(
                      avatar: const Icon(Icons.graphic_eq_rounded, size: 16), label: const Text('录音豆'),
                      selected: _beanMode, onSelected: (_) => setMode(6)),
                ),
              if (store.days.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(right: 10, top: 6, bottom: 6),
                child: ModeSwitch(mode: _mode, onMode: setMode, compact: true),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                child: ChoiceChip(label: Text('待办 $openTodos'), selected: _todos, onSelected: (_) => setMode(3)),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10, top: 6, bottom: 6),
                child: ChoiceChip(label: const Text('每周回顾'), selected: _weeks, onSelected: (_) => setMode(4)),
              ),
              if (_weeks)
                for (final w in weeks)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                    child: ChoiceChip(label: Text(w.label), selected: w.key == week?.key, onSelected: (_) => pickWeek(w.key)),
                  )
              else if (_byPerson)
                for (final p in people)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                    child: ChoiceChip(label: Text('${p.name} ${p.count}'), selected: p.name == person, onSelected: (_) => pickPerson(p.name)),
                  )
              else if (_byCat)
                for (final e in store.byCategory.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                    child: ChoiceChip(label: Text('${catFolder(e.key)} ${e.value.length}'), selected: e.key == cat, onSelected: (_) => pickCat(e.key)),
                  ),
              if (_byPerson || _todos || _weeks)
                const SizedBox()
              else if (_byCat)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                  child: ChoiceChip(label: Text('$draftsKey ${store.drafts.length}'), selected: cat == draftsKey,
                      onSelected: (_) => pickCat(draftsKey)),
                )
              else
                for (final d in dayKeys)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                    child: ChoiceChip(label: Text(dayTitle(d, short: true)), selected: d == day, onSelected: (_) => pickDay(d)),
                  ),
              ],
            ]),
          ),
        Expanded(
          child: _live && !searching
              ? LiveView(live: widget.live)
              : _beanMode && !searching
              ? BeanView(bean: widget.bean!, store: store, onOpen: openFound)
              : _cardMode && !searching
              ? CardView(syncer: widget.syncer, store: store, onOpen: openFound)
              : _withBanner(compact: true, searching
              ? SearchColumn(store: store, hits: hits, scenes: scenes, topic: topic, selected: null,
                  draftHits: draftHits, onPickDraft: _openNarrowDraft,
                  askKey: _askKey, onOpen: openFound, onPick: _openNarrow)
              : inDrafts
                  ? DraftColumn(drafts: store.drafts, selected: null, onPick: _openNarrowDraft)
                  : _todos
                  ? TodoColumn(store: store, scenes: scenes, selected: null,
                      askKey: _askKey, onOpen: openFound, onPick: _openNarrow)
                  : _weeks
                  ? WeekColumn(store: store, week: week, scenes: scenes, selected: null,
                      askKey: _askKey, onOpen: openFound, onPick: _openNarrow, onReview: () => _openNarrowReview(week!),
                      onGenerate: (w) {
                        _genWeek(w);
                        _openNarrowReview(w);
                      })
                  : _byPerson
                  ? PersonColumn(store: store, person: person, scenes: scenes, selected: null,
                      askKey: _askKey, onOpen: openFound, onPick: _openNarrow, onPrep: _prep)
                  : _byCat
                  ? CatColumn(store: store, cat: cat, scenes: scenes, selected: null,
                      askKey: _askKey, onOpen: openFound, onPick: _openNarrow, onIdeas: cat == '个人感悟' ? _openIdeas : null)
                  : DayColumn(store: store, day: day, scenes: scenes, pending: pendingToday, selected: null,
                      askKey: _askKey, onOpen: openFound, onPick: _openNarrow)),
        ),
      ]);

  void _openNarrow(Scene s) => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Scaffold(
                      appBar: AppBar(backgroundColor: K.paper, title: Text(s.title)),
                      body: Column(children: [
                        Expanded(
                            child: SceneDetail(
                                scene: s, player: player, store: store, onQuick: _quick, onRecut: widget.syncer.reanalyze)),
                        ListenableBuilder(
                            listenable: player,
                            builder: (_, _) => player.stem == null ? const SizedBox() : PlayerBar(player: player)),
                      ]),
                    )));

  void _openNarrowDraft(Draft d) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
            appBar: AppBar(backgroundColor: K.paper, title: Text(d.title)),
            body: DraftDetail(draft: d),
          )));
}

/// 这条从哪来的：录音卡 / 录音豆 / 现场会议 / 小耳语音（小图标 + 字，不抢类别的颜色）。
class SourceTag extends StatelessWidget {
  final String stem;
  const SourceTag(this.stem, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = sourceOf(stem);
    final icon = switch (s) {
      '录音豆' => Icons.graphic_eq_rounded,
      '现场会议' => Icons.mic_none_rounded,
      '小耳语音' => Icons.record_voice_over_outlined,
      _ => Icons.sd_card_outlined,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: K.line), borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: K.faint),
        const SizedBox(width: 3),
        Text(s, style: TextStyle(fontSize: 11.5, color: K.faint)),
      ]),
    );
  }
}

// ───────── 卡的状态（左栏卡片 / 手机顶栏共用）─────────

/// (标题, 一行状态)
(String, String) cardStatus(Syncer syncer, Store store) {
  final c = syncer.card;
  final title = syncer.boundId == null ? '录音卡' : syncer.boundName;
  final pend = store.pending;
  final pulling = pend.where((r) => r.stage == 'pulling' && !r.stem.startsWith('bean')).toList(); // 录音豆的进度在它自己的面板
  if (pulling.isNotEmpty) return (title, pullLine(pulling.first));
  final processing = pend.where((r) => r.stage == 'processing').toList();
  if (processing.isNotEmpty) {
    return (title, '云端转写 ${processing.first.progress}%${processing.length > 1 ? ' · 共 ${processing.length} 条' : ''}');
  }
  if (pend.any((r) => r.stage == 'pulled' || r.stage == 'uploading')) return (title, '正在传到云端');
  final analyzing = pend.where((r) => r.stage == 'analyzing').toList();
  if (analyzing.isNotEmpty) return (title, '整理中 ${analyzing.first.progress}%');
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

/// 「从卡上拉 3.2 / 13.6MB · 约剩 25 分钟 · 已传云端 2 段」：剩多久按这一轮实测的速度估。
String pullLine(Rec r) {
  String mb(int b) => (b / 1e6).toStringAsFixed(1);
  final left = r.size - r.got;
  final eta = r.bps > 0 && left > 0 ? ' · 约剩 ${(left / r.bps / 60).ceil()} 分钟' : '';
  return '从卡上拉 ${mb(r.got)} / ${mb(r.size)}MB$eta${r.sent > 0 ? ' · 已传云端 ${r.sent} 段' : ''}';
}

bool _live(Syncer syncer, Store store) => syncer.card.connected || store.pending.isNotEmpty;

// ───────── 处理中横幅：有录音在路上就一直挂在列表顶上，说清在干嘛、等多久、卡没卡住 ─────────

class ProgressBanner extends StatefulWidget {
  final Syncer syncer;
  final Store store;
  final bool compact; // 手机窄屏
  const ProgressBanner({super.key, required this.syncer, required this.store, this.compact = false});
  @override
  State<ProgressBanner> createState() => _ProgressBannerState();
}

class _ProgressBannerState extends State<ProgressBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // 没有新进度时界面不会重画：隔一会儿自己重算一次「约剩多久」「卡没卡住」
    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pend = widget.store.pending;
    final r = featured(pend);
    if (r == null) return const SizedBox.shrink();
    final s = widget.syncer;
    final a = activity(r, s.track(r),
        connected: s.card.connected, now: DateTime.now(), cloudError: s.card.error, others: pend.length - 1);
    final c = widget.compact;
    final stalled = a.stall != null;
    final parts = a.stall?.split(' · ') ?? const <String>[];
    final fg = stalled ? K.accent : K.ink;
    return Container(
      padding: EdgeInsets.fromLTRB(c ? 14 : 18, c ? 12 : 14, c ? 14 : 18, c ? 12 : 14),
      decoration: BoxDecoration(
        color: stalled ? const Color(0xFFFBE8E3) : const Color(0xFFE8F0E3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: stalled ? K.accentEdge : const Color(0xFFBFD2B6), width: 1.2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        StepBar(step: a.step, alsoNext: a.alsoNext, stalled: stalled, compact: c),
        SizedBox(height: c ? 10 : 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: EdgeInsets.only(top: c ? 3 : 4, right: 10),
            child: stalled
                ? Icon(Icons.error_outline_rounded, size: c ? 20 : 22, color: K.accent)
                : SizedBox(
                    width: c ? 16 : 18, height: c ? 16 : 18,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: K.live)),
          ),
          Expanded(
            child: Text(stalled ? parts.first : a.headline,
                style: TextStyle(fontSize: c ? 17 : 19, fontWeight: FontWeight.w700, color: fg, height: 1.35)),
          ),
        ]),
        if (!stalled && a.fraction != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
                value: a.fraction, minHeight: 6, color: K.live, backgroundColor: const Color(0xFFCFDDC8)),
          ),
        ],
        if (stalled)
          for (final p in parts.skip(1))
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 32),
              child: Text(p, style: TextStyle(fontSize: 13.5, color: K.ink, height: 1.45)),
            ),
        Padding(
          padding: EdgeInsets.only(top: 6, left: stalled ? 32 : 0),
          child: Text(
            stalled ? '眼下：${a.headline}' : (a.detail ?? ''),
            style: TextStyle(fontSize: 12.5, color: K.mute, height: 1.45),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(top: 4, left: stalled ? 32 : 0),
          child: Text(a.comfort, style: TextStyle(fontSize: c ? 13 : 13.5, color: K.mute, height: 1.5)),
        ),
      ]),
    );
  }
}

/// ① 从卡上拉 → ② 云端转写 → ③ 整理：做完的打勾，当前这步高亮。
class StepBar extends StatelessWidget {
  final int step;
  final bool alsoNext, stalled, compact;
  const StepBar({super.key, required this.step, this.alsoNext = false, this.stalled = false, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final names = compact ? const ['从卡上拉', '云端转写', '整理'] : const ['从卡上拉', '云端转写', '整理成笔记'];
    Widget dot(int i) {
      final done = i < step;
      final now = i == step || (alsoNext && i == step + 1);
      final color = done ? K.live : (now ? (stalled && i == step ? K.accent : K.ink) : K.faint);
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 22, height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? K.live : (now ? color : Colors.transparent),
            border: Border.all(color: color, width: 1.5),
          ),
          child: done
              ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
              : Text('${i + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: now ? Colors.white : K.faint)),
        ),
        const SizedBox(width: 6),
        Text(names[i],
            style: TextStyle(
                fontSize: compact ? 13 : 13.5, color: color, fontWeight: now ? FontWeight.w700 : FontWeight.w500)),
      ]);
    }

    Widget line(int i) => Expanded(
          child: Container(
            height: 2,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: i < step ? K.live : const Color(0xFFCFDDC8),
          ),
        );
    return Row(children: [dot(0), line(0), dot(1), line(1), dot(2)]);
  }
}

/// 时间线里的灰色占位卡：正在处理的录音先在它的时间位置占个座，出结果后换成真笔记。
class PendingRow extends StatelessWidget {
  final Rec rec;
  const PendingRow({super.key, required this.rec});

  @override
  Widget build(BuildContext context) {
    final t = recStart(rec.stem);
    final f = switch (rec.stage) {
      'pulling' => rec.size > 0 ? rec.got / rec.size : null,
      'processing' || 'analyzing' => rec.progress / 100,
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 13, 14, 13),
        decoration: BoxDecoration(
          color: const Color(0xFFEDEAE3),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: K.lineStrong),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 52,
              child: Text(t == null ? '' : hm(t),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: K.faint,
                      fontFeatures: [FontFeature.tabularFigures()]))),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(placeholderLine(rec), style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: K.mute)),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                    value: f?.clamp(0.0, 1.0), minHeight: 4, color: K.faint, backgroundColor: K.line),
              ),
              const SizedBox(height: 6),
              Text('还在处理，好了这里自动换成笔记', style: TextStyle(fontSize: 12.5, color: K.faint)),
            ]),
          ),
        ]),
      ),
    );
  }
}
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
      decoration: BoxDecoration(color: K.bar, border: Border(bottom: BorderSide(color: K.line))),
      child: Row(children: [
        Mascot(_live(syncer, store) ? 'stand' : 'sleep', size: 36),
        const SizedBox(width: 8),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            Text(sub, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: K.mute)),
          ]),
        ),
        if (syncer.boundId == null && syncer.card.choices.length > 1)
          TextButton(onPressed: () => showCardPicker(context, syncer), child: const Text('选卡')),
        IconButton(
          tooltip: '设置',
          icon: Icon(Icons.tune, size: 20, color: K.mute),
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
            backgroundColor: K.strong, foregroundColor: K.onStrong, minimumSize: Size(0, compact ? 34 : 38),
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
  final String? day, cat, person;
  final int mode;
  final void Function(String) onPick, onPickCat, onPickPerson;
  final void Function(int) onMode;
  final List<Person> people;
  final Widget? search;
  final int todoCount; // 还没打勾的待办
  final List<Week> weeks;
  final String? week;
  final void Function(String)? onPickWeek;
  final LiveSession? live;
  final BeanSyncer? bean;
  const Sidebar(
      {super.key, required this.store, required this.syncer, required this.day, required this.onPick,
      required this.mode, required this.cat, required this.onPickCat, required this.onMode,
      required this.people, required this.person, required this.onPickPerson, this.search,
      this.todoCount = 0, this.weeks = const [], this.week, this.onPickWeek, this.live, this.bean});

  @override
  Widget build(BuildContext context) => Container(
        color: K.bar,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // 顶上：名字 + 「开会」（现场会议是一个动作，不跟内容、设备混在一列）
          Padding(
            // Mac 红绿灯压在左上，往下让一点
            padding: EdgeInsets.fromLTRB(16, Platform.isMacOS ? 46 : 20, 12, 16),
            child: Row(children: [
              const Mascot('stand', size: 30),
              const SizedBox(width: 8),
              Expanded(child: Text('小耳录音卡', overflow: TextOverflow.ellipsis, style: K.title(17).copyWith(color: K.ink))),
              MeetButton(live: live, selected: mode == 5, onTap: () => onMode(5)),
            ]),
          ),
          if (search != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 10), child: search),
          // 看内容：按天 / 按类别 / 按人，左栏主体
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: ModeSwitch(mode: mode, onMode: onMode),
          ),
          Expanded(
              child: switch (mode) {
            1 => CatNav(store: store, cat: cat, onPick: onPickCat),
            2 => PeopleNav(people: people, person: person, onPick: onPickPerson),
            4 => WeekNav(store: store, weeks: weeks, week: week, onPick: (k) => onPickWeek?.call(k)),
            _ => DayNav(store: store, days: daysWithPending(store.days.keys, store.pending), day: day, onPick: onPick),
          }),
          _rule(),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
            child: Column(children: [
              NavRow(icon: Icons.checklist_rounded, text: '待办', count: todoCount, selected: mode == 3, onTap: () => onMode(3)),
              NavRow(icon: Icons.event_note_outlined, text: '每周回顾', selected: mode == 4, onTap: () => onMode(4)),
            ]),
          ),
          _rule(),
          // 设备：一台一行，点进去是设备页
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
            child: Column(children: [
              DeviceRow(
                icon: Icons.sd_card_outlined,
                name: '录音卡',
                listen: store,
                status: () => _cardLine(),
                on: () => syncer.card.connected || store.pending.any((r) => sourceOf(r.stem) == '录音卡'),
                selected: mode == 7,
                onTap: syncer.boundId == null && syncer.card.choices.length > 1
                    ? () => showCardPicker(context, syncer)
                    : () => onMode(7),
              ),
              if (bean != null)
                DeviceRow(
                  icon: Icons.graphic_eq_rounded,
                  name: '录音豆',
                  listen: bean!,
                  status: () => bean!.connected || bean!.here == true
                      ? '${bean!.info?.battery ?? '—'}%'
                      : (bean!.mac == null ? '没连过' : '不在旁边'),
                  on: () => bean!.connected || bean!.here == true,
                  selected: mode == 6,
                  onTap: () => onMode(6),
                ),
              NavRow(icon: Icons.tune, text: '设置', selected: false, onTap: () => showSettings(context, store, syncer)),
            ]),
          ),
          const SizedBox(height: 8),
        ]),
      );

  Widget _rule() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
        child: Divider(height: 1, color: K.dark ? K.line : K.lineStrong.withValues(alpha: 0.6)),
      );

  /// 录音卡那一行右边的短状态：选卡 / 电量 / 不在旁边
  String _cardLine() {
    if (syncer.boundId == null) return syncer.card.choices.length > 1 ? '选卡' : '没连过';
    if (store.pending.any((r) => r.stage == 'pulling' && sourceOf(r.stem) == '录音卡')) return '拉取中';
    final b = syncer.card.info?.battery ?? (store.settings['cardInfo'] is List ? (store.settings['cardInfo'] as List)[0] as int? : null);
    if (syncer.card.connected) return b == null ? '已连接' : (b >= 110 ? '充电中' : '$b%');
    return '不在旁边';
  }
}

/// 设备一行：图标 + 名字 + 在不在的小点 + 右边一个短状态（电量 / 不在旁边）。
class DeviceRow extends StatelessWidget {
  final IconData icon;
  final String name;
  final Listenable listen;
  final String Function() status;
  final bool Function() on;
  final bool selected;
  final VoidCallback onTap;
  const DeviceRow({super.key, required this.icon, required this.name, required this.listen, required this.status,
      required this.on, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: listen,
        builder: (_, _) => NavRow(
          icon: icon,
          text: name,
          selected: selected,
          onTap: onTap,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(status(), style: TextStyle(fontSize: 12, color: K.faint)),
            const SizedBox(width: 6),
            Container(width: 7, height: 7, decoration: BoxDecoration(color: on() ? K.live : K.lineStrong, shape: BoxShape.circle)),
          ]),
        ),
      );
}

/// 左栏顶上的「开会」：点了进现场会议；正在录时变成「会议中」。
class MeetButton extends StatelessWidget {
  final LiveSession? live;
  final bool selected;
  final VoidCallback onTap;
  const MeetButton({super.key, required this.live, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: live ?? ValueNotifier(0),
        builder: (_, _) {
          final rec = live?.state == LiveState.recording;
          final active = live?.active == true; // 有一场没结束（暂停着）
          return FilledButton.icon(
            onPressed: onTap,
            icon: Icon(rec || active ? Icons.fiber_manual_record : Icons.mic_none_rounded, size: rec || active ? 10 : 15),
            label: const Text('开会'),
            style: FilledButton.styleFrom(
              backgroundColor: rec || selected ? K.accent : K.card,
              foregroundColor: rec || selected ? Colors.white : K.ink,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          );
        },
      );
}

/// 「按天 / 按类别 / 按人」切换。
class ModeSwitch extends StatelessWidget {
  final int mode;
  final bool compact;
  final void Function(int) onMode;
  const ModeSwitch({super.key, required this.mode, required this.onMode, this.compact = false});

  @override
  Widget build(BuildContext context) {
    Widget seg(String t, int v) => Expanded(
          flex: compact ? 0 : 1,
          child: GestureDetector(
            onTap: () => onMode(v),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: EdgeInsets.symmetric(vertical: 7, horizontal: compact ? 12 : 0),
              decoration: BoxDecoration(color: mode == v ? K.card : Colors.transparent, borderRadius: BorderRadius.circular(9),
                  boxShadow: mode == v ? const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 1))] : null),
              alignment: Alignment.center,
              child: Text(t, style: TextStyle(fontSize: 13, fontWeight: mode == v ? FontWeight.w700 : FontWeight.w500,
                  color: mode == v ? K.ink : K.mute)),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: K.dark ? K.cardDeep : K.cardDeep.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max, children: [seg('按天', 0), seg('按类别', 1), seg('按人', 2)]),
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
            Icon(Icons.search, size: 17, color: K.faint),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: const TextStyle(fontSize: 13.5),
                decoration: InputDecoration(hintText: '搜标题、人、说过的话…', hintStyle: TextStyle(fontSize: 13, color: K.faint),
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
                      icon: Icon(Icons.close, size: 16, color: K.mute),
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
    final drafts = store.drafts.length;
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
      if (c.isNotEmpty) Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Divider(height: 1, color: K.line)),
      Material(
        color: cat == draftsKey ? K.card : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onPick(draftsKey),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(Icons.edit_note, size: 16, color: cat == draftsKey ? K.accent : K.faint),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(draftsKey,
                      style: TextStyle(fontWeight: cat == draftsKey ? FontWeight.w600 : FontWeight.w400,
                          color: cat == draftsKey ? K.ink : K.mute))),
              Text('$drafts',
                  style: TextStyle(fontSize: 12, color: cat == draftsKey ? K.accent : K.faint, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// 左栏（按人）：所有出现过的人 + 出现在几段里，多的在前。
class PeopleNav extends StatelessWidget {
  final List<Person> people;
  final String? person;
  final void Function(String) onPick;
  const PeopleNav({super.key, required this.people, required this.person, required this.onPick});

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(16),
        child: Text('整理好的记录里还没认出人名。', style: TextStyle(fontSize: 13, color: K.faint)),
      );
    }
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
      for (final p in people)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Material(
            color: p.name == person ? K.card : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onPick(p.name),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Icon(Icons.person_outline, size: 16, color: p.name == person ? K.accent : K.faint),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(p.name, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: p.name == person ? FontWeight.w600 : FontWeight.w400,
                              color: p.name == person ? K.ink : K.mute))),
                  Text('${p.count}',
                      style: TextStyle(fontSize: 12, color: p.name == person ? K.accent : K.faint, fontWeight: FontWeight.w600)),
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
  final List<String> days;
  final String? day;
  final void Function(String) onPick;
  const DayNav({super.key, required this.store, required this.days, required this.day, required this.onPick});

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
        for (final e in [for (final k in days) MapEntry(k, store.days[k] ?? const <Scene>[])])
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
                    Text(e.value.isEmpty ? '处理中' : '${e.value.length}',
                        style: TextStyle(fontSize: 12, color: e.key == day ? K.accent : K.faint,
                            fontWeight: FontWeight.w600)),
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
  final List<Rec> pending; // 这天还在处理的录音：按开录时间插一张占位卡
  final String? selected;
  final void Function(Scene) onPick;
  final VoidCallback? onHandoff; // 宽屏：「交给 Agent」放在日期右边；手机在顶栏
  final Key? askKey;
  final void Function(Scene)? onOpen; // 对话里找到的那段被点了
  const DayColumn(
      {super.key, required this.store, required this.day, required this.scenes, required this.selected, required this.onPick,
      this.pending = const [], this.onHandoff, this.askKey, this.onOpen});

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
            for (final (t, x) in [
              for (final s in scenes) (s.start, s),
              for (final r in pending) (recStart(r.stem)!, r),
            ]..sort((a, b) => a.$1.compareTo(b.$1)))
              if (x is Scene)
                SceneRow(scene: x, selected: x.id == selected, onTap: () => onPick(x))
              else
                PendingRow(key: ValueKey('pending:${(x as Rec).stem}:$t'), rec: x),
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
  final VoidCallback? onIdeas; // 个人感悟：「按主题整理观点库」
  const CatColumn(
      {super.key, required this.store, required this.cat, required this.scenes, required this.selected, required this.onPick,
      this.top = 20, this.askKey, this.onOpen, this.onIdeas});

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
            Text(hint, style: TextStyle(fontSize: 12, color: K.faint)),
          ],
          if (onIdeas != null) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: K.accent, side: BorderSide(color: K.accentEdge), visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99))),
              onPressed: onIdeas,
              icon: const Icon(Icons.auto_awesome_outlined, size: 16),
              label: const Text('按主题整理观点库'),
            ),
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
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute)),
                  const SizedBox(width: 8),
                  if (bySubject) Text('${g.value.length} 次', style: TextStyle(fontSize: 12, color: K.faint)),
                  const SizedBox(width: 8),
                  Expanded(child: Divider(color: K.line)),
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

/// 中栏（按人）：顶上一张「跟 X 的往来」小结卡，下面是跟他有关的所有段（新的在前）。
class PersonColumn extends StatelessWidget {
  final Store store;
  final String? person;
  final List<Scene> scenes;
  final String? selected;
  final void Function(Scene) onPick;
  final void Function(String) onPrep;
  final double top;
  final Key? askKey;
  final void Function(Scene)? onOpen;
  const PersonColumn(
      {super.key, required this.store, required this.person, required this.scenes, required this.selected, required this.onPick,
      required this.onPrep, this.top = 20, this.askKey, this.onOpen});

  @override
  Widget build(BuildContext context) {
    if (person == null) return const Hint('wave', '还没认出人', '整理好的记录里出现过的人会列在左边，点一个看跟他的所有往来。');
    final name = person!;
    final total = scenes.fold<Duration>(Duration.zero, (a, s) => a + s.end.difference(s.start));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(24, top, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: K.title(26).copyWith(color: K.ink)),
          const SizedBox(height: 2),
          const Squiggle(width: 132),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _Stat(Icons.view_agenda_outlined, '${scenes.length} 段'),
            _Stat(Icons.mic_none, '共 ${duration(total)}'),
          ]),
        ]),
      ),
      Expanded(
        child: AskBox(
          key: askKey, store: store, scenes: scenes, all: store.scenes, onOpen: onOpen,
          topic: 'person:$name', focus: _focus(scenes, selected),
          hint: '问问小耳：跟$name之间…也可以让它帮你准备见面',
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), children: [
            PersonSummary(name: name, scenes: scenes, onPrep: () => onPrep(name), onOpen: onPick),
            const SizedBox(height: 10),
            for (final s in scenes) SceneRow(scene: s, selected: s.id == selected, onTap: () => onPick(s), showDate: true),
          ]),
        ),
      ),
    ]);
  }
}

/// 「跟 X 的往来」：最近一次是哪天什么事、还没兑现的待办，和「见面前帮我准备」。
class PersonSummary extends StatelessWidget {
  final String name;
  final List<Scene> scenes; // 新的在前
  final VoidCallback onPrep;
  final void Function(Scene) onOpen;
  const PersonSummary({super.key, required this.name, required this.scenes, required this.onPrep, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final last = scenes.firstOrNull;
    final todos = todosWith(scenes, name);
    final body = TextStyle(fontSize: 13.5, height: 1.6, color: K.ink);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      decoration: BoxDecoration(color: K.cardDeep, borderRadius: BorderRadius.circular(16), border: Border.all(color: K.accentEdge)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Label('跟$name的往来', color: K.accent),
        const SizedBox(height: 8),
        if (last != null)
          InkWell(
            onTap: () => onOpen(last),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '最近一次：', style: TextStyle(color: K.mute)),
              TextSpan(text: '${last.start.month}/${last.start.day} ${hm(last.start)} ${last.title}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              if (last.event.isNotEmpty) TextSpan(text: '。${last.event}', style: TextStyle(color: K.mute)),
            ]), style: body),
          ),
        const SizedBox(height: 8),
        Text(todos.isEmpty ? '还没兑现的待办：没有' : '还没兑现的待办（${todos.length}）',
            style: TextStyle(fontSize: 13, color: K.mute, fontWeight: FontWeight.w600)),
        for (final t in todos.take(8))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: EdgeInsets.only(top: 3, right: 6), child: Icon(Icons.check_box_outline_blank, size: 14, color: K.todo)),
              Expanded(
                child: Text(
                    '${t.text}${t.who.isNotEmpty ? '（${t.who}）' : ''}${t.when.isNotEmpty ? ' · ${t.when}' : ''}'
                    ' — ${t.scene.start.month}/${t.scene.start.day}',
                    style: body),
              ),
            ]),
          ),
        if (todos.length > 8) Text('还有 ${todos.length - 8} 条，在各段里看', style: TextStyle(fontSize: 12, color: K.faint)),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: K.accent, visualDensity: VisualDensity.compact),
            onPressed: onPrep,
            icon: const Icon(Icons.event_note_outlined, size: 16),
            label: const Text('见面前帮我准备'),
          ),
        ),
      ]),
    );
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
  final List<DraftHit> draftHits;
  final String? selectedDraft;
  final void Function(Draft)? onPickDraft;
  const SearchColumn(
      {super.key, required this.store, required this.hits, required this.scenes, required this.topic, required this.selected,
      required this.onPick, this.onOpen, this.askKey, this.top = 20, this.draftHits = const [], this.selectedDraft,
      this.onPickDraft});

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
          Wrap(spacing: 6, runSpacing: 6, children: [
            _Stat(Icons.search, hits.isEmpty ? (draftHits.isEmpty ? '没找到' : '录音里没找到') : '找到 ${hits.length} 段'),
            if (draftHits.isNotEmpty) _Stat(Icons.edit_note, '${draftHits.length} 篇成稿'),
          ]),
        ]),
      ),
      Expanded(
        child: AskBox(
          key: askKey, store: store, scenes: scenes, all: store.scenes, onOpen: onOpen,
          topic: topic, focus: _focus(found, selected),
          hint: '问问小耳：模糊说说那天大概聊了啥，让它帮你找',
          child: hits.isEmpty && draftHits.isEmpty
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('没找到，试试在下面问小耳', style: TextStyle(color: K.mute, fontSize: 14)),
                  ),
                )
              : ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), children: [
                  for (final h in draftHits)
                    DraftRow(draft: h.draft, selected: h.draft.path == selectedDraft, onTap: () => onPickDraft?.call(h.draft),
                        extra: SnippetText(h.snippet)),
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
      spans.add(TextSpan(text: t.substring(a, b), style: TextStyle(color: K.accent, fontWeight: FontWeight.w700)));
      at = b;
    }
    if (at < t.length) spans.add(TextSpan(text: t.substring(at)));
    return Text.rich(TextSpan(children: spans), maxLines: 3, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, color: K.faint, height: 1.5));
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
                      SourceTag(scene.stem),
                      if (scene.todo > 0) Chip2('${scene.todo} 件要办', todo: true),
                    ]),
                    const SizedBox(height: 4),
                    Text(scene.event, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: K.mute, height: 1.5)),
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
            Text(body, textAlign: TextAlign.center, style: TextStyle(color: K.mute, height: 1.7)),
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
  State<AskBox> createState() => AskBoxState();
}

class _Msg {
  final bool me, error;
  final String text; // 显示 / 拷贝用：去掉了 [[找到: …]]；一键按钮发的只显示按钮名
  final String raw; // 进历史的原话：模型的原回答 / 一键按钮背后的完整要求
  final List<String> found;
  final String ask; // 小耳的回答：对应我那句要求（存成稿时记下来）
  final Scene? focus; // 小耳的回答：当时正在看的那段
  const _Msg(this.me, this.text, {this.error = false, String? raw, this.found = const [], this.ask = '', this.focus})
      : raw = raw ?? text;
}

class AskBoxState extends State<AskBox> {
  final _q = TextEditingController();
  final _scroll = ScrollController();
  final _msgs = <_Msg>[];
  bool _busy = false, _open = false;
  int _gen = 0; // 清空 / 换了资料后，路上的回答作废
  bool _keep = false; // 点了找到的卡片跳到别的日子：这次换 topic 不清空对话
  final _saved = Map<_Msg, String>.identity(); // 存成稿了的回答 → 文件路径

  @override
  void didUpdateWidget(AskBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topic != widget.topic && !_keep) _clear();
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
    _saved.clear();
    _busy = false;
    _open = false;
  }

  List<Turn> get _history => [
        for (var i = 0; i + 1 < _msgs.length; i++)
          if (_msgs[i].me && !_msgs[i + 1].me && !_msgs[i + 1].error) Turn(_msgs[i].raw, _msgs[i + 1].raw),
      ];

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
        }
      });

  /// 一键按钮：以 [s] 为正在看的这一段（null = 不指定，用这一栏的资料），发出 [prompt]（对话里显示成 [label]）。
  /// [notesOnly]：资料只给笔记，不给逐字稿。
  void quick(Scene? s, String label, String prompt, {bool notesOnly = false}) {
    if (_busy) {
      _snack('小耳还在写上一条，写完再点');
      return;
    }
    _ask(show: label, prompt: prompt, focus: s, button: true, notesOnly: notesOnly);
  }

  /// 发一句：默认是输入框里打的；一键按钮给 [show]（显示的）+ [prompt]（发给模型的）+ [focus]。
  Future<void> _ask({String? show, String? prompt, Scene? focus, bool button = false, bool notesOnly = false}) async {
    final typed = show == null;
    final q = typed ? _q.text.trim() : show;
    if (q.isEmpty || _busy) return;
    final send = prompt ?? q;
    final at = button ? focus : (focus ?? widget.focus);
    final store = widget.store;
    final messages = buildAskMessages(scenes: widget.scenes, focus: at, all: widget.all, history: _history, question: send,
        style: store.hasLib ? store.lib.writingStyle() : '', lookup: typed ? send : '', withText: !notesOnly);
    final gen = _gen;
    setState(() {
      _msgs.add(_Msg(true, q, raw: send));
      _busy = true;
      _open = true;
      if (typed) _q.clear();
    });
    _toBottom();
    _Msg answer;
    var edits = <EditOp>[];
    try {
      final a = await Llm.instance!.chatMessages(messages, temperature: 0.5);
      final (found, ids) = parseFound(a);
      final (clean, ops) = parseEdits(found);
      edits = ops;
      answer = a.isEmpty
          ? const _Msg(false, '模型没回内容，再问一次试试。', error: true)
          : _Msg(false, clean.isEmpty && ids.isNotEmpty ? '找到这几段：' : clean, raw: a, found: ids, ask: q, focus: at);
    } catch (e) {
      answer = _Msg(false, '没问成：$e', error: true);
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      _msgs.add(answer);
      if (edits.isEmpty) _busy = false;
    });
    _toBottom();
    if (edits.isEmpty) return;
    // 小耳要动手改：照着改（改类别要按新模板重新整理，慢一点），改完把结果接在回答下面
    final i = _msgs.length - 1;
    setState(() => _msgs[i] = _Msg(false, '${answer.text}\n\n_正在改…_', raw: answer.raw, found: answer.found, ask: q, focus: at));
    final results = await applyEdits(store, edits, Analyzer.of(store.lib, Llm.instance!).note);
    if (!mounted || gen != _gen) return;
    setState(() {
      _msgs[i] = _Msg(false, '${answer.text}\n\n${results.map((r) => '- $r').join('\n')}',
          raw: '${answer.raw}\n\n（App 的执行结果：${results.join('；')}）', found: answer.found, ask: q, focus: at);
      _busy = false;
    });
    _toBottom();
  }

  Future<void> _copy(String md) async {
    await Clipboard.setData(ClipboardData(text: md));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制'), duration: Duration(seconds: 2)));
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 3)));
  }

  /// 存成稿；已经存了就在 Finder 里显示（手机上提示存在哪）。
  void _saveDraft(_Msg m) {
    final saved = _saved[m];
    if (saved != null) return revealDraft(context, saved);
    final store = widget.store;
    if (!store.hasLib) return _snack('资料文件夹还没准备好，没存成');
    try {
      final f = saveDraft(store.lib, answer: m.text, request: m.ask, source: m.focus);
      setState(() => _saved[m] = f.path);
      store.refreshDrafts();
      if (!Platform.isMacOS) _snack('存好了：资料文件夹/$draftsKey/${f.uri.pathSegments.last}');
    } catch (e) {
      _snack('没存成：$e');
    }
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
          child: SelectableText(m.text, style: TextStyle(fontSize: 14.5, height: 1.6, color: K.ink)),
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
                  child: SelectableText(m.text, style: TextStyle(fontSize: 14, height: 1.6, color: K.todo)),
                )
              else
                Padding(padding: const EdgeInsets.only(right: 6), child: MdView(m.text)),
              for (final s in [for (final id in m.found) _byId(id)].nonNulls)
                Padding(padding: const EdgeInsets.only(top: 8, right: 6), child: FoundCard(scene: s, onTap: () => _openFound(s))),
              if (!m.error)
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Tooltip(
                    message: _saved[m] == null ? '存进资料文件夹的「$draftsKey」' : (Platform.isMacOS ? '在 Finder 里显示' : '看存在哪'),
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                          foregroundColor: _saved[m] == null ? K.mute : K.accent, visualDensity: VisualDensity.compact),
                      onPressed: () => _saveDraft(m),
                      icon: Icon(_saved[m] == null ? Icons.save_alt_rounded : Icons.check_rounded, size: 15),
                      label: Text(_saved[m] == null ? '存成稿' : '已存 ✓', style: const TextStyle(fontSize: 12.5)),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: K.mute, visualDensity: VisualDensity.compact),
                    onPressed: () => _copy(m.text),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('拷贝', style: TextStyle(fontSize: 12.5)),
                  ),
                ]),
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
              Text('和小耳的对话', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute)),
              if (widget.focus != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text('正在看：${widget.focus!.title}', overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: K.faint)),
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
          Divider(height: 1, color: K.line),
          Expanded(
            child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(18, 14, 18, 6), children: [
              for (final m in _msgs) _bubble(m),
              if (_busy)
                Padding(
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
        // 还在用小耳的体验额度：提醒填自己的模型 key（对外发的版本，每个人用自己的）
        if (Llm.instance != null && !Llm.instance!.own)
          Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              '在用小耳的体验额度（每天有限）· 设置 → 大模型 里填你自己的 key',
              style: TextStyle(fontSize: 12, color: K.faint, height: 1.5),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: K.accentEdge)),
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
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: K.accent,
                          fontFeatures: [FontFeature.tabularFigures()])),
                  Chip2(s.category),
                  SourceTag(s.stem),
                  Text(s.title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: K.ink)),
                ]),
                if (s.event.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(s.event, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: K.mute, height: 1.5)),
                ],
              ]),
            ),
            Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.chevron_right, size: 18, color: K.accent)),
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

class SceneDetail extends StatefulWidget {
  final Scene scene;
  final Player player;
  final Store store;
  final double top; // 宽屏顶上留给拖动条
  final void Function(Scene, String, String)? onQuick; // 「拿去用」按钮：(这段, 按钮名, 要求)
  final void Function(Scene)? onMerged; // 合并好以后打开合好的那段；不给就退回上一页（手机上）
  final Future<void> Function(String stem)? onRecut; // 整条录音重新切场景、重新整理
  const SceneDetail(
      {super.key, required this.scene, required this.player, required this.store, this.top = 24, this.onQuick,
      this.onMerged, this.onRecut});

  /// 「笔记 | 逐字稿」切换。放在类上而不是 State 里：点别的段时保持上次选的。
  static final transcriptTab = ValueNotifier<bool>(false);
  @override
  State<SceneDetail> createState() => _SceneDetailState();
}

class _SceneDetailState extends State<SceneDetail> {
  Scene get scene => widget.scene;
  Player get player => widget.player;
  Store get store => widget.store;

  Future<void> _copy(String t) async {
    await Clipboard.setData(ClipboardData(text: t));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('逐字稿复制好了（${transcriptChars(t)} 字）'), duration: const Duration(seconds: 2)));
    }
  }

  Widget _btn(String label, IconData icon, VoidCallback? onPressed, {String? tip}) {
    final b = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
          foregroundColor: K.accent, side: BorderSide(color: K.accentEdge), visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap, minimumSize: const Size(0, 28),
          padding: const EdgeInsets.symmetric(horizontal: 10), textStyle: const TextStyle(fontSize: 12.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99))),
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      label: Text(label),
    );
    return tip == null ? b : Tooltip(message: tip, child: b);
  }

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
        child: Text(clock.substring(0, 5), style: TextStyle(color: K.accent, fontFeatures: [FontFeature.tabularFigures()])),
      );

  /// 逐字稿每一行：点时间从那里听，正在播的那行高亮。
  /// 一行一个 ListView 子项（长录音几百行，只画看得见的）；播放器走一下只重画这一行的底色，字不重排。
  List<Widget> _lines(Scene s, TextStyle body) => [
        for (final line in s.text)
          ListenableBuilder(
            listenable: player,
            builder: (_, child) => Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: player.stem == s.stem && player.label == line[0] ? K.accentSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(6)),
              child: child,
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _ts(line[0]),
              const SizedBox(width: 8),
              Expanded(child: SelectableText(line[1], style: body)),
            ]),
          ),
      ];

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: SceneDetail.transcriptTab,
        builder: (context, tx, _) => _build(context, tx),
      );

  /// 这一段的逐字稿拷贝按钮：纯文字 / 带时间 / 整条录音；Mac 上还有「在 Finder 显示」。
  Widget _tools(Scene s) {
    // 长录音全文几万字：点了再拼，别每次重画都拼一遍
    final empty = transcriptText(s).isEmpty;
    final same = store.scenesOf(s.stem);
    final whole = same.isEmpty ? [s] : same;
    final file = store.hasLib ? store.lib.transcript(s.stem) : null;
    return Wrap(spacing: 6, runSpacing: 6, children: [
      _btn('拷贝', Icons.copy_rounded, empty ? null : () => _copy(transcriptText(s)), tip: '这一段，纯文字，一行一句'),
      _btn('带时间拷贝', Icons.schedule, empty ? null : () => _copy(transcriptText(s, times: true)),
          tip: '每行前面带 [时:分:秒]'),
      _btn('整条录音', Icons.library_books_outlined,
          whole.every((x) => transcriptText(x).isEmpty) ? null : () => _copy(recordingTranscript(whole)),
          tip: '这一段所在整条录音的全部逐字稿，按段分开'),
      if (Platform.isMacOS && file != null)
        _btn('在 Finder 显示', Icons.folder_open_outlined,
            () => file.existsSync() ? Process.run('open', ['-R', file.path]) : Process.run('open', [file.parent.path]),
            tip: '逐字稿/${s.stem}.md'),
    ]);
  }

  Widget _build(BuildContext context, bool tx) {
    final s = scene;
    Widget meta(IconData i, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 14, color: K.faint),
          const SizedBox(width: 4),
          Text(t, style: TextStyle(fontSize: 13, color: K.faint)),
        ]);
    final todo = [
      for (final a in s.actions) '${a['text']}${(a['who'] ?? '').toString().isNotEmpty ? '（${a['who']}）' : ''}',
      for (final r in s.reminders) '${r['text']}${(r['when'] ?? '').toString().isNotEmpty ? ' · ${r['when']}' : ''}',
    ];
    const body = TextStyle(fontSize: 14, height: 1.7);
    final header = <Widget>[
      Wrap(spacing: 14, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        CategoryChip(scene: s, store: store),
        SourceTag(s.stem),
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
      if (!s.noise) ...[
        const SizedBox(height: 8),
        MergeBar(scene: s, store: store, onMerged: widget.onMerged, onRecut: widget.onRecut),
      ],
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('笔记'), icon: Icon(Icons.notes, size: 16)),
            ButtonSegment(value: true, label: Text('逐字稿'), icon: Icon(Icons.subject, size: 16)),
          ],
          selected: {tx},
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact, selectedForegroundColor: K.accent,
              selectedBackgroundColor: K.accentSoft, side: BorderSide(color: K.accentEdge)),
          onSelectionChanged: (v) => SceneDetail.transcriptTab.value = v.first,
        ),
      ),
    ];
    if (tx) {
      return ListView(key: PageStorageKey('${s.id}/逐字稿'), padding: EdgeInsets.fromLTRB(32, widget.top, 32, 32), children: [
        ...header,
        const SizedBox(height: 14),
        _tools(s),
        const SizedBox(height: 8),
        Text('点时间从那里听', style: TextStyle(fontSize: 12, color: K.faint)),
        const SizedBox(height: 8),
        if (s.text.isEmpty) Text('这段没有逐字稿。', style: TextStyle(color: K.faint)) else ..._lines(s, body),
      ]);
    }
    return ListView(key: PageStorageKey(s.id), padding: EdgeInsets.fromLTRB(32, widget.top, 32, 32), children: [
      ...header,
      if (!s.noise && widget.onQuick != null) ...[
        const SizedBox(height: 10),
        QuickBar(scene: s, store: store, onQuick: widget.onQuick!),
      ],
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
      Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Label('逐字稿'),
        Text('点时间从那里听', style: TextStyle(fontSize: 12, color: K.faint)),
        _tools(s),
      ]),
      const SizedBox(height: 8),
      ..._lines(s, body),
    ]);
  }
}

// ───────── 手动改类别 ─────────

/// 右栏标题上方的类别：点了选别的类别，按新类别的模板重新整理这一段。
class CategoryChip extends StatefulWidget {
  final Scene scene;
  final Store store;
  const CategoryChip({super.key, required this.scene, required this.store});
  @override
  State<CategoryChip> createState() => _CategoryChipState();
}

class _CategoryChipState extends State<CategoryChip> {
  String? _to; // 正在改成哪一类

  Future<String?> _askSubject(String now) async {
    final c = TextEditingController(text: now);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: K.card,
        title: const Text('调研的是谁？'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: '哪家公司 / 哪个门店 / 哪个项目（可以留空）'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: K.cta), onPressed: () => Navigator.pop(ctx, true), child: const Text('好')),
        ],
      ),
    );
    return ok == true ? c.text.trim() : null;
  }

  Future<void> _change(String cat) async {
    final s = widget.scene, store = widget.store;
    if (cat == s.category || _to != null) return;
    var subject = '';
    if (cat == '现场调研') {
      final x = await _askSubject(s.subject);
      if (x == null) return;
      subject = x;
    }
    if (!mounted || !store.hasLib || Llm.instance == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _to = cat);
    try {
      await store.changeCategory(s, cat, Analyzer.of(store.lib, Llm.instance!).note, subject: subject);
      messenger.showSnackBar(SnackBar(
          content: Text(cat == noiseCat ? '改成「$noiseCat」了，列表里不再显示这段' : '改成「${catFolder(cat)}」了，已按新模板重新整理')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('没改成，类别还是「${catFolder(s.category)}」：$e')));
    }
    if (mounted) setState(() => _to = null);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scene;
    if (_to != null) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: K.accent)),
        const SizedBox(width: 6),
        Text('正在改成「${_to == noiseCat ? noiseCat : catFolder(_to!)}」，按新模板重新整理…',
            style: TextStyle(fontSize: 12.5, color: K.accent)),
      ]);
    }
    return PopupMenuButton<String>(
      tooltip: '改类别',
      onSelected: _change,
      color: K.card,
      itemBuilder: (_) => [
        for (final c in [...cats.map((c) => c.key), noiseCat])
          PopupMenuItem(
            value: c,
            child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: categoryColors(c).$2, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Text(c == noiseCat ? '$noiseCat（不要这段）' : catFolder(c),
                  style: TextStyle(fontWeight: c == s.category ? FontWeight.w700 : FontWeight.w400)),
              if (c == s.category) ...[const SizedBox(width: 6), Icon(Icons.check, size: 15, color: K.accent)],
            ]),
          ),
      ],
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Chip2(s.category),
        Icon(Icons.arrow_drop_down, size: 18, color: K.faint),
      ]),
    );
  }
}

// ───────── 一场会别拆成几段：手动合并 / 重新切分 ─────────

/// 右栏标题下面：跟上一段合并、整条录音当一段、重新切分这条录音。
class MergeBar extends StatefulWidget {
  final Scene scene;
  final Store store;
  final void Function(Scene)? onMerged;
  final Future<void> Function(String stem)? onRecut;
  const MergeBar({super.key, required this.scene, required this.store, this.onMerged, this.onRecut});
  @override
  State<MergeBar> createState() => _MergeBarState();
}

class _MergeBarState extends State<MergeBar> {
  String? _doing; // 正在干什么（显示在按钮那一行）

  Future<bool> _confirm(String title, String body, String ok) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: K.card,
          title: Text(title),
          content: Text(body, style: const TextStyle(height: 1.6)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: K.cta), onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
          ],
        ),
      ) ==
      true;

  Future<void> _merge(bool whole) async {
    final s = widget.scene, store = widget.store;
    if (_doing != null || !store.hasLib || Llm.instance == null) return;
    final prev = store.previousOf(s);
    final parts = whole ? store.scenesOf(s.stem).where((x) => !x.noise).toList() : [?prev, s];
    if (parts.length < 2) return;
    parts.sort((a, b) => a.start.compareTo(b.start));
    final cat = mergedCategory(parts.map((x) => x.category));
    final list = [for (final x in parts) '· ${hm(x.start)}–${hm(x.end)} [${catFolder(x.category)}] ${x.title}'].join('\n');
    if (!await _confirm(whole ? '整条录音当一段？' : '跟上一段合并？',
        '$list\n\n合成一段「${catFolder(cat)}」，按这一类的模板重新整理（一般半分钟）。原来这几段的笔记文件会换成合好的这一份。', '合并')) {
      return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context), nav = Navigator.of(context);
    setState(() => _doing = '正在合并，按「${catFolder(cat)}」模板重新整理…');
    try {
      final note = Analyzer.of(store.lib, Llm.instance!).note;
      final m = whole ? await store.mergeRecording(s.stem, note) : await store.mergeWithPrevious(s, note);
      messenger.showSnackBar(SnackBar(content: Text('合成一段了：${hm(m.start)}–${hm(m.end)} ${m.title}')));
      if (widget.onMerged != null) {
        widget.onMerged!(m);
      } else {
        nav.maybePop();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('没合并成，原来的几段都没动：$e')));
    }
    if (mounted) setState(() => _doing = null);
  }

  Future<void> _recut() async {
    final s = widget.scene;
    if (_doing != null || widget.onRecut == null) return;
    if (!await _confirm('重新切分这条录音？',
        '整条录音按「一个场合一段」重新切场景、重新整理（一般一两分钟，进度看左下角录音卡那栏）。\n'
            '这条录音里手动改过的类别、合并过的段会被新的结果替换；打过勾的待办会带过去。',
        '重新切分')) {
      return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('开始重新切分这条录音，整理好会自动换上')));
    if (widget.onMerged == null) Navigator.of(context).maybePop();
    widget.onRecut!(s.stem).catchError((Object e) {
      messenger.showSnackBar(SnackBar(content: Text('重新切分没成功：$e')));
    });
  }

  Widget _btn(String label, IconData icon, VoidCallback? onPressed, String tip) => Tooltip(
        message: tip,
        child: TextButton.icon(
          style: TextButton.styleFrom(
              foregroundColor: K.mute, visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 8), textStyle: const TextStyle(fontSize: 12.5)),
          onPressed: onPressed,
          icon: Icon(icon, size: 15),
          label: Text(label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = widget.scene, store = widget.store;
    if (_doing != null) {
      return Row(children: [
        SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: K.accent)),
        const SizedBox(width: 6),
        Text(_doing!, style: TextStyle(fontSize: 12.5, color: K.accent)),
      ]);
    }
    final prev = store.previousOf(s);
    final many = store.scenesOf(s.stem).where((x) => !x.noise).length > 1;
    return Wrap(spacing: 2, runSpacing: 2, children: [
      if (prev != null)
        _btn('跟上一段合并', Icons.merge_type, () => _merge(false),
            '跟「${hm(prev.start)} ${prev.title}」合成一段（同一场会被拆开了时用）'),
      if (many) _btn('整条录音当一段', Icons.unfold_less, () => _merge(true), '这条录音里所有段合成一段'),
      if (widget.onRecut != null)
        _btn('重新切分这条录音', Icons.content_cut, _recut, '整条录音按「一个场合一段」重新切场景、重新整理'),
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
              icon: Icon(Icons.copy_rounded, size: 17, color: K.mute),
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
              icon: Icon(Icons.folder_open_outlined, size: 17, color: K.mute),
              onPressed: () => Process.run('open', ['-R', s.d['file']]),
            ),
          TextButton(
            onPressed: _busy ? null : _redo,
            style: TextButton.styleFrom(foregroundColor: K.accent, visualDensity: VisualDensity.compact),
            child: _busy
                ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: K.accent))
                : Text(s.body.isEmpty ? '按模板整理' : '重新整理'),
          ),
        ]),
        const SizedBox(height: 6),
        if (s.body.isNotEmpty) MdView(s.body) else Text('这段还没按类别整理过。', style: TextStyle(color: K.faint)),
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
        child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute, letterSpacing: 1)),
      );

  Widget _li(String lead, String x, {Color? color}) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 22, child: Text(lead, style: TextStyle(fontSize: 14, height: 1.7, color: color ?? K.ink))),
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
          Label('会议纪要', color: K.accent),
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
          Text('相关人：${strs('attendees').join('、')}', style: TextStyle(fontSize: 13, color: K.faint)),
        ],
        if ((m['summary'] ?? '').toString().isNotEmpty) ...[_head('概要'), SelectableText(m['summary'], style: _body)],
        if (agenda.isNotEmpty) ...[
          _head('讨论内容'),
          for (final (i, a) in agenda.indexed) ...[
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8, bottom: 2),
              child: Text('${i + 1}. ${a['title']}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: K.ink)),
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

  final _subs = <StreamSubscription>[];

  Player() {
    _subs.addAll([
      _p.onPositionChanged.listen((d) {
        pos = d;
        notifyListeners();
      }),
      _p.onDurationChanged.listen((d) {
        total = d;
        notifyListeners();
      }),
      _p.onPlayerStateChanged.listen((s) {
        playing = s == PlayerState.playing;
        notifyListeners();
      }),
    ]);
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
    // 先断开：播放器关掉时还会再发一两个事件，到这里已经没人听了
    for (final s in _subs) {
      s.cancel();
    }
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
          decoration: BoxDecoration(color: K.bar, border: Border(top: BorderSide(color: K.line))),
          child: Row(children: [
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: K.dark ? K.accent : K.ink),
              tooltip: player.playing ? '暂停' : '播放',
              onPressed: player.toggle,
              icon: Icon(player.playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text(_t(player.pos), style: TextStyle(fontSize: 13, color: K.mute)),
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
            Text(_t(player.total), style: TextStyle(fontSize: 13, color: K.mute)),
          ]),
        ),
      );
}

// ───────── 拿去用：每类的一键按钮 ─────────

/// 笔记卡片下面一排按钮：按这段的类别列出（模板/一键按钮.md 改过就按改过的）。点了交给 [onQuick]。
class QuickBar extends StatelessWidget {
  final Scene scene;
  final Store store;
  final void Function(Scene, String, String) onQuick;
  const QuickBar({super.key, required this.scene, required this.store, required this.onQuick});

  @override
  Widget build(BuildContext context) {
    final table = store.hasLib ? store.lib.quickActionsTable() : quickActions;
    final acts = table[scene.category] ?? const [];
    if (acts.isEmpty) return const SizedBox();
    return Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text('拿去用', style: TextStyle(fontSize: 12, color: K.faint, fontWeight: FontWeight.w600)),
      for (final (name, ask) in acts)
        OutlinedButton(
          style: OutlinedButton.styleFrom(
              foregroundColor: K.accent, side: BorderSide(color: K.accentEdge), visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap, minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 10), textStyle: const TextStyle(fontSize: 12.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99))),
          onPressed: () => onQuick(scene, name, ask),
          child: Text(name),
        ),
    ]);
  }
}

// ───────── 成稿 ─────────

/// 在 Finder 里显示这份成稿；手机上提示它存在哪。
void revealDraft(BuildContext context, String path) {
  if (Platform.isMacOS) {
    Process.run('open', ['-R', path]);
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('存在：资料文件夹/$draftsKey/${File(path).uri.pathSegments.last}'), duration: const Duration(seconds: 4)));
}

class DraftRow extends StatelessWidget {
  final Draft draft;
  final bool selected;
  final VoidCallback onTap;
  final Widget? extra;
  const DraftRow({super.key, required this.draft, required this.selected, required this.onTap, this.extra});

  @override
  Widget build(BuildContext context) {
    final first = draft.body
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'^\s*#+\s*'), '').trim())
        .firstWhere((l) => l.isNotEmpty && l != draft.title, orElse: () => '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? K.cardDeep : Colors.transparent,
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
                  child: Text('${int.parse(draft.when.substring(5, 7))}/${int.parse(draft.when.substring(8, 10))}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? K.accent : K.faint,
                          fontFeatures: const [FontFeature.tabularFigures()]))),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(draft.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    const Chip2(draftsKey),
                  ]),
                  if (extra == null && first.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(first, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: K.mute, height: 1.5)),
                  ],
                  if (extra != null) ...[const SizedBox(height: 4), extra!],
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 中栏（按类别 → 成稿）：成稿/ 里的文件，新的在前。
class DraftColumn extends StatelessWidget {
  final List<Draft> drafts;
  final String? selected;
  final void Function(Draft) onPick;
  final double top;
  const DraftColumn({super.key, required this.drafts, required this.selected, required this.onPick, this.top = 20});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(24, top, 20, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(draftsKey, style: K.title(26).copyWith(color: K.ink)),
            const SizedBox(height: 2),
            const Squiggle(width: 132),
            const SizedBox(height: 10),
            _Stat(Icons.edit_note, '${drafts.length} 篇'),
            const SizedBox(height: 8),
            Text('在对话里让小耳写好的东西，点「存成稿」存在资料文件夹的「成稿」里', style: TextStyle(fontSize: 12, color: K.faint)),
          ]),
        ),
        Expanded(
          child: drafts.isEmpty
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有成稿', style: TextStyle(color: K.mute, fontSize: 14)),
                  ),
                )
              : ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), children: [
                  for (final d in drafts) DraftRow(draft: d, selected: d.path == selected, onTap: () => onPick(d)),
                ]),
        ),
      ]);
}

/// 右栏：一篇成稿（开头的元信息 + 正文），能拷贝正文、在 Finder 里显示。
class DraftDetail extends StatelessWidget {
  final Draft draft;
  final double top;
  const DraftDetail({super.key, required this.draft, this.top = 24});

  @override
  Widget build(BuildContext context) => ListView(key: PageStorageKey(draft.path), padding: EdgeInsets.fromLTRB(32, top, 32, 32), children: [
        Wrap(spacing: 14, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Chip2(draftsKey),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.schedule, size: 14, color: K.faint),
            const SizedBox(width: 4),
            Text(draft.when, style: TextStyle(fontSize: 13, color: K.faint)),
          ]),
        ]),
        const SizedBox(height: 10),
        SelectableText(draft.title, style: K.title(26).copyWith(color: K.ink)),
        const SizedBox(height: 2),
        const Squiggle(width: 96),
        const SizedBox(height: 8),
        Row(children: [
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: K.accent, visualDensity: VisualDensity.compact),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: draft.body.trim()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('正文复制好了'), duration: Duration(seconds: 2)));
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('拷贝正文'),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: K.mute, visualDensity: VisualDensity.compact),
            onPressed: () => revealDraft(context, draft.path),
            icon: const Icon(Icons.folder_open_outlined, size: 16),
            label: Text(Platform.isMacOS ? '在 Finder 里显示' : '存在哪'),
          ),
        ]),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
          decoration: BoxDecoration(color: K.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: K.accentEdge)),
          child: MdView(draft.md),
        ),
      ]);
}

// ───────── 后台活：每周回顾 / 观点按主题（换了栏也不中断，两边的按钮都看得到进度）─────────

class Jobs extends ChangeNotifier {
  static final instance = Jobs();
  final busy = <String>{};
  final errors = <String, String>{};

  Future<void> run(String key, Future<void> Function() f) async {
    if (busy.contains(key)) return;
    busy.add(key);
    errors.remove(key);
    notifyListeners();
    try {
      await f();
    } catch (e) {
      errors[key] = e is StateError ? e.message : '$e';
    }
    busy.remove(key);
    notifyListeners();
  }
}

/// 左栏的一行：图标 + 名字 + 数字（待办、每周回顾）。
class NavRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;
  const NavRow({super.key, required this.icon, required this.text, this.count, required this.selected, required this.onTap,
      this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: selected ? K.card : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(children: [
                Icon(icon, size: 16, color: selected ? K.accent : K.mute),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(text,
                        style: TextStyle(fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: selected ? K.ink : K.mute))),
                if (count != null && count! > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(color: K.todoSoft, borderRadius: BorderRadius.circular(99)),
                    child: Text('$count', style: TextStyle(fontSize: 12, color: K.todo, fontWeight: FontWeight.w700)),
                  ),
                ?trailing,
              ]),
            ),
          ),
        ),
      );
}

/// 左栏（每周回顾）：有录音的每一周，新的在前；生成过回顾的打个勾。
class WeekNav extends StatelessWidget {
  final Store store;
  final List<Week> weeks;
  final String? week;
  final void Function(String) onPick;
  const WeekNav({super.key, required this.store, required this.weeks, required this.week, required this.onPick});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Jobs.instance,
        builder: (_, _) => ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
          for (final w in weeks)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: w.key == week ? K.card : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onPick(w.key),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(children: [
                      Expanded(
                          child: Text(w.label,
                              style: TextStyle(fontWeight: w.key == week ? FontWeight.w600 : FontWeight.w400,
                                  color: w.key == week ? K.ink : K.mute))),
                      if (store.hasLib && weekFile(store.lib, w) != null)
                        Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.check, size: 14, color: K.accent)),
                      Text('W${w.number}', style: TextStyle(fontSize: 12, color: w.key == week ? K.accent : K.faint, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );
}

// ───────── 待办 ─────────

/// 中栏（待办）：所有段的待办，分「有时间的」「没时间的」，打了勾的收进底下的「已完成」。
class TodoColumn extends StatefulWidget {
  final Store store;
  final List<Scene> scenes; // 还有没办完待办的段，问小耳时当资料
  final String? selected;
  final void Function(Scene) onPick;
  final double top;
  final Key? askKey;
  final void Function(Scene)? onOpen;
  const TodoColumn(
      {super.key, required this.store, required this.scenes, required this.selected, required this.onPick, this.top = 20,
      this.askKey, this.onOpen});
  @override
  State<TodoColumn> createState() => _TodoColumnState();
}

class _TodoColumnState extends State<TodoColumn> {
  bool _showDone = false;

  Widget _head(String t, int n) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
        child: Row(children: [
          Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute)),
          const SizedBox(width: 8),
          Text('$n', style: TextStyle(fontSize: 12, color: K.faint)),
          const SizedBox(width: 8),
          Expanded(child: Divider(color: K.line)),
        ]),
      );

  Widget _tile(Todo t) => TodoTile(
      key: ValueKey('${t.scene.stem}/${t.scene.id}/${t.kind}/${t.index}'),
      todo: t, store: widget.store, selected: t.scene.id == widget.selected, onOpen: () => widget.onPick(t.scene));

  @override
  Widget build(BuildContext context) {
    final all = todosOf(widget.store.scenes);
    final open = all.where((t) => !t.done).toList();
    final timed = open.where((t) => t.timed).toList(), untimed = open.where((t) => !t.timed).toList();
    final done = all.where((t) => t.done).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(24, widget.top, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('待办', style: K.title(26).copyWith(color: K.ink)),
          const SizedBox(height: 2),
          const Squiggle(width: 132),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _Stat(Icons.check_circle_outline, '${open.length} 件没办完', todo: open.isNotEmpty),
            if (timed.isNotEmpty) _Stat(Icons.alarm, '${timed.length} 件有时间'),
            if (done.isNotEmpty) _Stat(Icons.done_all, '已完成 ${done.length}'),
          ]),
          const SizedBox(height: 8),
          Text('所有录音里整理出的要办的事。打的勾记在那一段里，每日时间线里也跟着打勾。', style: TextStyle(fontSize: 12, color: K.faint)),
        ]),
      ),
      Expanded(
        child: AskBox(
          key: widget.askKey, store: widget.store, scenes: widget.scenes, all: widget.store.scenes, onOpen: widget.onOpen,
          topic: 'todo', focus: _focus(widget.scenes, widget.selected),
          hint: '问问小耳：这些待办里先做哪件？',
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), children: [
            if (all.isEmpty)
              Padding(
                padding: EdgeInsets.all(24),
                child: Text('整理出来的待办都会汇到这。现在还没有。', style: TextStyle(color: K.mute, fontSize: 14)),
              ),
            if (timed.isNotEmpty) ...[_head('有时间的', timed.length), for (final t in timed) _tile(t)],
            if (untimed.isNotEmpty) ...[_head('没时间的', untimed.length), for (final t in untimed) _tile(t)],
            if (done.isNotEmpty) ...[
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showDone = !_showDone),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
                  child: Row(children: [
                    Icon(_showDone ? Icons.expand_less : Icons.expand_more, size: 18, color: K.mute),
                    const SizedBox(width: 4),
                    Text('已完成（${done.length}）', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute)),
                    const SizedBox(width: 8),
                    Expanded(child: Divider(color: K.line)),
                  ]),
                ),
              ),
              if (_showDone) for (final t in done) _tile(t),
            ],
          ]),
        ),
      ),
    ]);
  }
}

/// 一条待办：勾 + 原文 + 什么时候 / 谁去做 + 来源（点了打开那段）；Mac 上能放进「提醒事项」。
class TodoTile extends StatefulWidget {
  final Todo todo;
  final Store store;
  final bool selected;
  final VoidCallback onOpen;
  const TodoTile({super.key, required this.todo, required this.store, required this.selected, required this.onOpen});
  @override
  State<TodoTile> createState() => _TodoTileState();
}

class _TodoTileState extends State<TodoTile> {
  bool _saving = false, _adding = false;

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 4)));
  }

  Future<void> _toggle(bool v) async {
    setState(() => _saving = true);
    try {
      await widget.store.setTodoDone(widget.todo, v);
    } catch (e) {
      _snack('没记上：$e');
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _remind() async {
    final t = widget.todo;
    setState(() => _adding = true);
    final err = await addToReminders(t);
    if (!mounted) return;
    setState(() => _adding = false);
    final due = parseWhen(t.when, t.scene.start);
    _snack(err ??
        (due == null
            ? '放进「提醒事项」了${t.when.isEmpty ? '' : '（「${t.when}」认不出具体哪天，没设提醒时间）'}'
            : '放进「提醒事项」了，${due.month}/${due.day} ${hm(due)} 提醒'));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.todo;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 6, 6, 8),
        decoration: BoxDecoration(
            color: widget.selected ? K.cardDeep : Colors.transparent, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.selected ? K.accentEdge : Colors.transparent)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 36,
            child: _saving
                ? const Padding(
                    padding: EdgeInsets.all(11), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)))
                : Checkbox(
                    value: t.done, activeColor: K.todo, side: BorderSide(color: K.todo, width: 1.5),
                    onChanged: (v) => _toggle(v == true)),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.text,
                    style: TextStyle(fontSize: 14.5, height: 1.5, color: t.done ? K.faint : K.ink,
                        decoration: t.done ? TextDecoration.lineThrough : null)),
                if (t.when.isNotEmpty || t.who.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (t.when.isNotEmpty)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.alarm, size: 13, color: K.todo),
                        const SizedBox(width: 3),
                        Text(t.when, style: TextStyle(fontSize: 12.5, color: K.todo)),
                      ]),
                    if (t.who.isNotEmpty) Text('谁去做：${t.who}', style: TextStyle(fontSize: 12.5, color: K.mute)),
                  ]),
                ],
                const SizedBox(height: 2),
                InkWell(
                  onTap: widget.onOpen,
                  child: Text('${t.source} ›', style: TextStyle(fontSize: 12.5, color: K.accent)),
                ),
              ]),
            ),
          ),
          if (Platform.isMacOS && !t.done)
            IconButton(
              tooltip: '放进「提醒事项」',
              visualDensity: VisualDensity.compact,
              onPressed: _adding ? null : _remind,
              icon: _adding
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.add_alert_outlined, size: 18, color: K.mute),
            ),
        ]),
      ),
    );
  }
}

// ───────── 每周回顾 ─────────

/// 中栏（每周回顾）：这周的数字、「这周回顾」一行（这周过完还没生成就是一条提示），下面是这周每天的段。
class WeekColumn extends StatelessWidget {
  final Store store;
  final Week? week;
  final List<Scene> scenes; // 按时间先后
  final String? selected;
  final void Function(Scene) onPick;
  final VoidCallback onReview;
  final void Function(Week) onGenerate;
  final double top;
  final Key? askKey;
  final void Function(Scene)? onOpen;
  const WeekColumn(
      {super.key, required this.store, required this.week, required this.scenes, required this.selected, required this.onPick,
      required this.onReview, required this.onGenerate, this.top = 20, this.askKey, this.onOpen});

  @override
  Widget build(BuildContext context) {
    if (week == null) return const Hint('wave', '还没有录音', '有录音以后，这里按周回顾：推进了什么、答应了谁什么、下周要盯的。');
    final w = week!;
    final st = WeekStats.of(scenes);
    final days = <String, List<Scene>>{};
    for (final s in scenes) {
      days.putIfAbsent(s.dayKey, () => []).add(s);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(24, top, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${w.label} 这一周', style: K.title(26).copyWith(color: K.ink)),
          const SizedBox(height: 2),
          const Squiggle(width: 132),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _Stat(Icons.mic_none, '录了 ${duration(st.total)}'),
            _Stat(Icons.view_agenda_outlined, '${st.scenes} 段'),
            if (st.meetings > 0) _Stat(Icons.groups_outlined, '开会 ${st.meetings} 次'),
            if (st.deals > 0) _Stat(Icons.handshake_outlined, '洽谈 ${st.deals} 次'),
          ]),
        ]),
      ),
      Expanded(
        child: AskBox(
          key: askKey, store: store, scenes: scenes, all: store.scenes, onOpen: onOpen,
          topic: 'week:${w.key}', focus: _focus(scenes, selected),
          hint: '问问小耳：这周我答应了谁什么？',
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), children: [
            ListenableBuilder(
              listenable: Jobs.instance,
              builder: (_, _) {
                final busy = Jobs.instance.busy.contains('week:${w.key}');
                final has = store.hasLib && weekFile(store.lib, w) != null;
                final nudge = !busy && !has && w.isOver(DateTime.now());
                return Material(
                  color: nudge ? K.todoBg : (selected == null ? K.cardDeep : Colors.transparent),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: nudge ? K.todoSoft : (selected == null ? K.accentEdge : K.line))),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: nudge ? () => onGenerate(w) : onReview,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                      child: Row(children: [
                        Icon(nudge ? Icons.auto_awesome_outlined : Icons.event_note_outlined, size: 18, color: nudge ? K.todo : K.accent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            busy
                                ? '小耳正在写这周回顾…'
                                : nudge
                                    ? '这周还没回顾，点这里生成'
                                    : has
                                        ? '这周回顾'
                                        : '这周回顾（这周还没过完，也可以先生成）',
                            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: nudge ? K.todo : K.ink),
                          ),
                        ),
                        if (busy)
                          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: K.accent))
                        else
                          Icon(Icons.chevron_right, size: 18, color: nudge ? K.todo : K.accent),
                      ]),
                    ),
                  ),
                );
              },
            ),
            for (final g in days.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                child: Row(children: [
                  Text(dayTitle(g.key, short: true), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute)),
                  const SizedBox(width: 8),
                  Expanded(child: Divider(color: K.line)),
                ]),
              ),
              for (final s in g.value) SceneRow(scene: s, selected: s.id == selected, onTap: () => onPick(s)),
            ],
          ]),
        ),
      ),
    ]);
  }
}

/// 拷贝 / 在 Finder 里显示 / 存成稿 这一排（每周回顾、观点按主题共用）。
Widget _fileActions(BuildContext context, File f, String md, {VoidCallback? onRedo, String redo = '重新生成', VoidCallback? onDraft}) =>
    Wrap(spacing: 2, children: [
      if (onRedo != null)
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: K.accent, visualDensity: VisualDensity.compact),
          onPressed: onRedo,
          icon: const Icon(Icons.refresh, size: 16),
          label: Text(redo),
        ),
      TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: K.mute, visualDensity: VisualDensity.compact),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: md.trim()));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('复制好了'), duration: Duration(seconds: 2)));
          }
        },
        icon: const Icon(Icons.copy_rounded, size: 16),
        label: const Text('拷贝'),
      ),
      TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: K.mute, visualDensity: VisualDensity.compact),
        onPressed: () => Platform.isMacOS
            ? Process.run('open', ['-R', f.path])
            : ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('存在：${f.path}'))),
        icon: const Icon(Icons.folder_open_outlined, size: 16),
        label: Text(Platform.isMacOS ? '在 Finder 里显示' : '存在哪'),
      ),
      if (onDraft != null)
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: K.mute, visualDensity: VisualDensity.compact),
          onPressed: onDraft,
          icon: const Icon(Icons.save_alt_rounded, size: 16),
          label: const Text('存成稿'),
        ),
    ]);

Widget _mdCard(String md) => Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      decoration: BoxDecoration(color: K.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: K.accentEdge)),
      child: MdView(md),
    );

Widget _busyRow(String t) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: K.accent)),
        const SizedBox(width: 8),
        Flexible(child: Text(t, style: TextStyle(fontSize: 13.5, color: K.mute))),
      ]),
    );

Widget _errorText(String e) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SelectableText('没生成成：$e', style: TextStyle(fontSize: 13.5, height: 1.6, color: K.todo)),
    );

String _readOr(File? f) {
  try {
    return f == null ? '' : f.readAsStringSync();
  } catch (_) {
    return '';
  }
}

/// 右栏：这一周的回顾（每周/ 里的文件）。没生成过给「生成这周回顾」，生成过给「重新生成」。
class WeekReview extends StatelessWidget {
  final Store store;
  final Week week;
  final void Function(Week) onGenerate;
  final double top;
  const WeekReview({super.key, required this.store, required this.week, required this.onGenerate, this.top = 24});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Jobs.instance,
        builder: (context, _) {
          final job = 'week:${week.key}';
          final busy = Jobs.instance.busy.contains(job);
          final err = Jobs.instance.errors[job];
          final f = store.hasLib ? weekFile(store.lib, week) : null;
          final md = _readOr(f);
          return ListView(key: PageStorageKey(job), padding: EdgeInsets.fromLTRB(32, top, 32, 32), children: [
            Wrap(spacing: 14, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Chip2('每周回顾'),
              Text('${week.key} · ${week.label}', style: TextStyle(fontSize: 13, color: K.faint)),
            ]),
            const SizedBox(height: 10),
            Text('${week.label} 回顾', style: K.title(26).copyWith(color: K.ink)),
            const SizedBox(height: 2),
            const Squiggle(width: 96),
            const SizedBox(height: 8),
            if (err != null) _errorText(err),
            if (busy) _busyRow('小耳正在看这周的录音、写回顾…（一般半分钟到一分钟）'),
            if (f != null && md.isNotEmpty) ...[
              _fileActions(context, f, md, onRedo: busy ? null : () => onGenerate(week)),
              const SizedBox(height: 8),
              _mdCard(md),
            ] else if (!busy) ...[
              Text(week.isOver(DateTime.now()) ? '这周还没回顾。' : '这周还没过完，现在生成只包括到目前为止的录音。',
                  style: TextStyle(fontSize: 14, color: K.mute, height: 1.7)),
              const SizedBox(height: 4),
              Text('回顾会写：这周概览、推进了什么、答应了谁什么、新冒出的观点、下周要盯的。存在资料文件夹的「每周」里。',
                  style: TextStyle(fontSize: 12.5, color: K.faint, height: 1.6)),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: K.cta),
                  onPressed: () => onGenerate(week),
                  icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                  label: const Text('生成这周回顾'),
                ),
              ),
            ],
          ]);
        },
      );
}

// ───────── 观点按主题 ─────────

/// 右栏：个人感悟/观点·按主题.md。能重新整理、拷贝、在 Finder 里显示、存成稿。
class IdeasView extends StatelessWidget {
  final Store store;
  final VoidCallback onGenerate;
  final double top;
  const IdeasView({super.key, required this.store, required this.onGenerate, this.top = 24});

  void _draft(BuildContext context, String md) {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final body = md.replaceFirst(RegExp(r'^> .*\n+', multiLine: true), ''); // 生成时间那行不进成稿正文
      final f = saveDraft(store.lib, answer: body, request: '按主题整理观点库');
      store.refreshDrafts();
      messenger.showSnackBar(SnackBar(content: Text('存成稿了：$draftsKey/${f.uri.pathSegments.last}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('没存成：$e')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Jobs.instance,
        builder: (context, _) {
          final busy = Jobs.instance.busy.contains('ideas');
          final err = Jobs.instance.errors['ideas'];
          final f = store.hasLib ? store.lib.ideasTopicFile : null;
          final md = f != null && f.existsSync() ? _readOr(f) : '';
          return ListView(padding: EdgeInsets.fromLTRB(32, top, 32, 32), children: [
            const Wrap(children: [Chip2('个人感悟')]),
            const SizedBox(height: 10),
            Text('观点 · 按主题', style: K.title(26).copyWith(color: K.ink)),
            const SizedBox(height: 2),
            const Squiggle(width: 96),
            const SizedBox(height: 8),
            Text('把「观点库」里按时间记下的观点，按主题归并：核心观点（标出处日期）、例子和金句、可以讲成演讲的提纲。',
                style: TextStyle(fontSize: 12.5, color: K.faint, height: 1.6)),
            const SizedBox(height: 8),
            if (err != null) _errorText(err),
            if (busy) _busyRow('小耳正在按主题整理观点库…（一般一两分钟）'),
            if (f != null && md.isNotEmpty) ...[
              _fileActions(context, f, md, onRedo: busy ? null : onGenerate, redo: '重新整理', onDraft: () => _draft(context, md)),
              const SizedBox(height: 8),
              _mdCard(md),
            ] else if (!busy)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: K.cta),
                  onPressed: onGenerate,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                  label: const Text('开始整理'),
                ),
              ),
          ]);
        },
      );
}
