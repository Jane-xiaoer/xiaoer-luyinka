// 待确认 + 人员名单（2026-11-05 Jane：「在小耳录音卡里给我一个权限，让我可以去纠正」）。
// 待确认：录音里拆出来的每件事，一键改「是我的 / 是谁的 / 不是任务 / 换项目」。改了马上写回这一段、记进纠正记录
//（下次重新整理同一条录音时记住），小耳自己的 Mac 上顺手写回经纪人台账（不是任务→不做了、别人的→等某某、换项目→claim）。
// 人员名单：编辑 资料文件夹/人员名单.md（只存这一份，拆事认人、判归谁用；经纪人也读它）。
import 'package:flutter/material.dart';

import 'analyze.dart' show sourceLine;
import 'ledger.dart';
import 'people.dart';
import 'store.dart';
import 'templates.dart';
import 'theme.dart';
import 'todos.dart';

// ───────── 待确认 ─────────

/// 待确认里点了一个按钮：改这一段、记纠正（Store.correctTodo），有台账就写回台账；返回给人看的一句话。
/// 按钮就调它（界面只管显示忙和提示条），测试也直接测它。[item] 是事先找好的台账那件（没给就现找）。
Future<String> applyChoice(Store store, Ledger? ledger, Todo t, String kind,
    {String who = '', String project = '', LedgerItem? item}) async {
  item ??= await ledger?.find(t.scene.id, t.text, pos: t.kind == 'actions' ? t.index : t.scene.pairs('actions').length + t.index);
  try {
    await store.correctTodo(t, kind, who: who, project: project);
  } catch (e) {
    return '没记上：$e';
  }
  var msg = switch (kind) {
    'mine' => '记下了：是你的',
    'owner' => '记下了：是$who的，留着等$who',
    'not_task' => '记下了：不是任务，不进待办',
    _ => '记下了：归「$project」',
  };
  if (ledger != null && kind != 'mine') {
    if (item == null) {
      msg += ' · 台账里没找到这件';
    } else {
      try {
        final r = await ledger.apply(item, kind, who: who, project: project);
        if (r.isNotEmpty) msg += ' · $r';
      } catch (e) {
        msg += ' · 台账没改成：${'$e'.replaceFirst('Exception: ', '')}';
      }
    }
  }
  return msg;
}

class ConfirmView extends StatefulWidget {
  final Store store;
  final Ledger? ledger;
  final double top;
  final void Function(Scene)? onOpen;
  const ConfirmView({super.key, required this.store, this.ledger, this.top = 24, this.onOpen});
  @override
  State<ConfirmView> createState() => _ConfirmViewState();
}

class _ConfirmViewState extends State<ConfirmView> {
  final _busy = <String>{};
  final _ledgerItems = <String, Future<LedgerItem?>>{};
  List<String> _projects = [];

  @override
  void initState() {
    super.initState();
    widget.ledger?.projects().then((p) {
      if (mounted) setState(() => _projects = p);
    });
    // 以前纠正过的（原型里、别的地方）套到已有录音上：判过的不再出现
    widget.store.applyStoredFixes().catchError((_) => 0);
  }

  String _key(Todo t) => '${t.scene.stem}/${t.scene.id}/${t.kind}/${t.index}';

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 4)));
  }

  Future<LedgerItem?> _ledgerOf(Todo t) =>
      _ledgerItems[_key(t)] ??= widget.ledger?.find(t.scene.id, t.text, pos: _pos(t)) ?? Future.value(null);

  /// 这件事在这一段推给经纪人时排第几（行动在前、提醒在后，跟 luyinka_app.py _todo 一样）。
  int _pos(Todo t) => t.kind == 'actions' ? t.index : t.scene.pairs('actions').length + t.index;

  List<String> get _projectChoices {
    final fromPeople = [for (final p in widget.store.lib.peopleEntries()) if (p.project.isNotEmpty) p.project];
    return {..._projects, ...fromPeople}.toList();
  }

  Future<void> _do(Todo t, String kind, {String who = '', String project = ''}) async {
    final k = _key(t);
    setState(() => _busy.add(k));
    final item = await _ledgerOf(t); // 先找台账号：改完这一段后 index 可能变
    final msg = await applyChoice(widget.store, widget.ledger, t, kind, who: who, project: project, item: item);
    _ledgerItems.remove(k);
    _snack(msg);
    if (mounted) setState(() => _busy.remove(k));
  }

  Future<String?> _ask(String title, String hint) async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: hint),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('算了')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('好')),
        ],
      ),
    );
  }

  Future<void> _pickOwner(Todo t) async {
    final names = [for (final p in widget.store.lib.peopleEntries()) p.name];
    final speaker = '${rawOf(t)['speaker'] ?? ''}';
    if (speaker.isNotEmpty && speaker != '我' && !names.contains(speaker)) names.insert(0, speaker);
    final v = await _menu<String>(t, '是谁的？', [for (final n in names) (n, n), ('…', '名单里没有，手写')]);
    if (v == null) return;
    final who = v == '…' ? await _ask('是谁的？', '名字，比如：董老师') : v;
    if (who != null && who.isNotEmpty) await _do(t, 'owner', who: who);
  }

  Future<void> _pickProject(Todo t) async {
    final v = await _menu<String>(t, '归到哪个项目？', [for (final p in _projectChoices) (p, p), ('…', '手写项目名')]);
    if (v == null) return;
    final p = v == '…' ? await _ask('归到哪个项目？', widget.ledger == null ? '项目名' : '要跟台账里的项目名一字不差') : v;
    if (p != null && p.isNotEmpty) await _do(t, 'project', project: p);
  }

  Future<T?> _menu<T>(Todo t, String title, List<(T, String)> items) => showDialog<T>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(title, style: const TextStyle(fontSize: 16)),
          children: [
            SizedBox(
              width: 320,
              height: (items.length * 44.0).clamp(44, 420),
              child: ListView(children: [
                for (final (v, label) in items)
                  SimpleDialogOption(onPressed: () => Navigator.pop(ctx, v), child: Text(label, style: const TextStyle(fontSize: 14.5))),
              ]),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (_, _) {
        final todos = pendingTodos(widget.store.scenes);
        final groups = <Scene, List<Todo>>{};
        for (final t in todos) {
          (groups[t.scene] ??= []).add(t);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(28, widget.top, 28, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text('待确认', style: K.title(26).copyWith(color: K.ink)),
                const SizedBox(width: 10),
                Text(todos.isEmpty ? '都过完了' : '还有 ${todos.length} 件', style: TextStyle(fontSize: 13, color: K.mute)),
              ]),
              const SizedBox(height: 2),
              const Squiggle(width: 110),
              const SizedBox(height: 10),
              Text(
                  '最近两周录音里拆出来的事，过一眼：是你的、是谁的、不是任务、换项目。改了马上生效，'
                  '下次重新整理同一条录音也记得${widget.ledger == null ? '' : '，经纪人台账跟着改'}。不点也照常进待办。',
                  style: TextStyle(fontSize: 12.5, height: 1.5, color: K.faint)),
            ]),
          ),
          Expanded(
            child: todos.isEmpty
                ? Center(child: Text('没有要确认的。新录音整理完，拆出来的事会先到这里。', style: TextStyle(color: K.mute, fontSize: 14)))
                : ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
                    for (final MapEntry(key: s, value: ts) in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                        child: Row(children: [
                          Flexible(
                            child: InkWell(
                              onTap: widget.onOpen == null ? null : () => widget.onOpen!(s),
                              child: Text('${ts.first.source} ›',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: K.mute)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Divider(color: K.line)),
                          TextButton(
                              onPressed: ts.any((t) => _busy.contains(_key(t)))
                                  ? null
                                  : () async {
                                      setState(() => _busy.addAll(ts.map(_key)));
                                      var n = 0;
                                      try {
                                        for (final t in ts) {
                                          await widget.store.correctTodo(t, 'mine');
                                          n++;
                                        }
                                        _snack('这段 $n 件都记成你的了');
                                      } catch (e) {
                                        _snack('记了 $n 件，后面的没记上：$e');
                                      }
                                      if (mounted) setState(() => _busy.removeAll(ts.map(_key)));
                                    },
                              child: const Text('这段都是我的')),
                        ]),
                      ),
                      for (final t in ts) _card(t),
                    ],
                  ]),
          ),
        ]);
      },
    );
  }

  Widget _card(Todo t) {
    final raw = rawOf(t);
    var said = '${raw['said'] ?? ''}', speaker = '${raw['speaker'] ?? ''}';
    final who = '${raw['who'] ?? ''}';
    if (said.isEmpty) {
      // 旧录音拆事时还没存原话：按钟点 + 内容从这一段的逐字稿里找出来
      final lines = [for (final l in (t.scene.d['text'] as List? ?? const [])) if (l is List && l.length >= 2) ['${l[0]}', '${l[1]}']];
      final src = sourceLine('${raw['t'] ?? ''}', lines, what: t.text);
      if (src != null) {
        final m = RegExp(r'^([^\s：:，。,、]{1,8})：').firstMatch(src[1]);
        speaker = m?.group(1) ?? '';
        said = (m == null ? src[1] : src[1].substring(m.end)).trim();
        if (said.length > 120) said = '${said.substring(0, 120)}…';
      }
    }
    final project = '${raw['project'] ?? ''}';
    final busy = _busy.contains(_key(t));
    final notMe = who.isNotEmpty && who != '我';
    return Container(
      key: ValueKey(_key(t)),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(color: K.tile, borderRadius: BorderRadius.circular(14), border: Border.all(color: K.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (notMe) _tag('像是$who的', K.todo),
          if (who.isEmpty) _tag('拿不准是谁的', K.mute),
          Expanded(child: Text(t.text, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.4, color: K.ink))),
        ]),
        if (said.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
            decoration: BoxDecoration(color: K.cardDeep, borderRadius: BorderRadius.circular(8), border: Border(left: BorderSide(color: K.lineStrong, width: 3))),
            child: Text.rich(TextSpan(children: [
              if (speaker.isNotEmpty) TextSpan(text: '$speaker：', style: TextStyle(color: K.mute)),
              TextSpan(text: '“$said”'),
            ]), style: TextStyle(fontSize: 13.5, height: 1.5, color: K.ink)),
          ),
        ],
        const SizedBox(height: 6),
        Wrap(spacing: 14, runSpacing: 2, children: [
          if ('${raw['t'] ?? ''}'.isNotEmpty) Text('${raw['t']}', style: TextStyle(fontSize: 12.5, color: K.accent)),
          Text('谁说的：${speaker.isEmpty ? '没认出' : speaker}', style: TextStyle(fontSize: 12.5, color: K.mute)),
          Text('猜归：${who.isEmpty ? '—' : who}', style: TextStyle(fontSize: 12.5, color: K.mute)),
          if (project.isNotEmpty) Text('项目：$project', style: TextStyle(fontSize: 12.5, color: K.mute)),
          if (widget.ledger != null)
            FutureBuilder<LedgerItem?>(
              future: _ledgerOf(t),
              builder: (_, s) => s.data == null
                  ? const SizedBox()
                  : Text('台账 #${s.data!.id}「${s.data!.title}」· ${s.data!.status}${s.data!.project.isEmpty ? '' : ' · ${s.data!.project}'}',
                      style: TextStyle(fontSize: 12.5, color: K.faint)),
            ),
        ]),
        const SizedBox(height: 10),
        busy
            ? const SizedBox(height: 32, child: Align(alignment: Alignment.centerLeft, child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))))
            : Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton(onPressed: () => _do(t, 'mine'), child: const Text('是我的')),
                OutlinedButton(onPressed: () => _pickOwner(t), child: const Text('是谁的 ▾')),
                OutlinedButton(onPressed: () => _do(t, 'not_task'), child: const Text('不是任务')),
                OutlinedButton(onPressed: () => _pickProject(t), child: const Text('换项目 ▾')),
              ]),
      ]),
    );
  }

  Widget _tag(String s, Color c) => Container(
        margin: const EdgeInsets.only(right: 8, top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
        child: Text(s, style: TextStyle(fontSize: 12, color: c)),
      );
}

// ───────── 人员名单 ─────────

class PeopleListView extends StatefulWidget {
  final Store store;
  final Ledger? ledger;
  final double top;
  const PeopleListView({super.key, required this.store, this.ledger, this.top = 24});
  @override
  State<PeopleListView> createState() => _PeopleListViewState();
}

class _PeopleListViewState extends State<PeopleListView> {
  late List<PersonEntry> _people;
  final _ctl = <String, TextEditingController>{};
  bool _dirty = false, _saving = false;
  final _auto = <PersonEntry, int>{}; // 从录音里自动列进来的人 → 出现在几段里
  final _orig = <PersonEntry, String>{}; // 打开时的名字（改了名，旧名字留作叫法）
  final _origKeys = <PersonEntry, Set<String>>{}; // 打开时的名字 + 叫法（看这一行改没改）
  static bool _sameKeys(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);
  final _removed = <PersonEntry>[]; // 点了 × 的人：存的时候跟「按人」里删掉一样藏起来（能在按人左栏底下找回）

  /// 自动列进来的人，写了点什么（改名、身份、项目、公司、介绍、别的叫法）才算要存。
  bool _keep(PersonEntry p) =>
      !_auto.containsKey(p) ||
      p.name.trim() != (_orig[p] ?? p.name).trim() || // 改了名（比如把「周总」改成名单上的「周总周宁」）
      [p.identity, p.project, p.company, p.note].any((x) => x.trim().isNotEmpty) ||
      p.aliases.any((a) => a.trim().isNotEmpty && a.trim() != p.name.trim());
  List<String> _projects = [];

  @override
  void initState() {
    super.initState();
    _load();
    widget.ledger?.projects().then((p) {
      if (mounted) setState(() => _projects = p);
    });
  }

  /// 读名单 + 录音里出现过、名单上还没有的人（存完也重读一遍，页面跟文件对上）。
  void _load() {
    _auto.clear();
    _orig.clear();
    _origKeys.clear();
    _people = widget.store.lib.peopleEntries();
    // 录音里出现过、名单上还没有的人自动列在后面（Jane 11-12：「上面的人员要自动出现在下面」）。
    // 不写资料就不存进名单，免得名单被随口一提的名字塞满；写了任何一栏才存
    final lib = widget.store.lib;
    for (final p in peopleOf(widget.store.scenes, Roster(_people, hiddenPeople: lib.hiddenPeople()))) {
      if (p.entry != null) continue;
      final e = PersonEntry(p.name, aliases: [p.name]);
      _auto[e] = p.count;
      _people.add(e);
    }
    for (final e in _people) {
      _orig[e] = e.name;
      _origKeys[e] = keysOfEntry(e);
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _c(PersonEntry p, String field, String value) =>
      _ctl['${identityHashCode(p)}/$field'] ??= TextEditingController(text: value);

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final lib = widget.store.lib;
      // 改了名：旧名字留作叫法，以前录音里的段还认得出是他（在副本上改，拦下来时页面上的不动）
      final changed = <PersonEntry>{};
      final copies = <PersonEntry>[];
      for (final p in _people) {
        if (!_keep(p)) continue;
        final q = p.copy();
        final old = (_orig[p] ?? '').trim();
        if (old.isNotEmpty && old != q.name.trim() && !q.aliases.contains(old)) q.aliases = [...q.aliases, old];
        if (_origKeys[p] == null || !_sameKeys(_origKeys[p]!, keysOfEntry(q))) changed.add(q);
        copies.add(q);
      }
      // 同名的两行（把录音里的「周总」改成名单上已有的「周总周宁」）并成一行
      var list = collapseSameName(copies, changed);
      // 改名 / 补叫法撞上别人的名字或叫法：会串人，拦下
      final clash = nameClash(list, changed);
      if (clash != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              duration: const Duration(seconds: 6),
              content: Text('没存：「${clash.$1}」已经是${clash.$2}的名字或叫法了。是同一个人就到「按人」里用「并到另一个人」；'
                  '不是同一个人就换个写法（比如带上全名），不然两人的录音会混在一起')));
          setState(() => _saving = false);
        }
        return;
      }
      if (_removed.isNotEmpty) {
        var hidden = lib.hiddenPeople();
        for (final p in _removed) {
          final name = (_orig[p] ?? p.name).trim();
          final listed = !_auto.containsKey(p);
          // 名单上的人按存档里那一行藏（资料原样留着，找回能回来）；录音里来的只藏名字
          final (l, h) = removePerson(listed ? [...list, p.copy()..name = name] : list, hidden, name);
          list = l;
          hidden = h;
        }
        await lib.saveHiddenPeople(hidden);
        _removed.clear();
      }
      await lib.savePeople(list);
      _dirty = false;
      if (mounted) {
        // 旧输入框这一帧还挂着，下一帧再释放
        final old = _ctl.values.toList();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final c in old) {
            c.dispose();
          }
        });
        setState(() {
          _ctl.clear();
          _load();
        });
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('人员名单存好了，下次整理录音就用上')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('没存上：$e')));
    }
    if (mounted) setState(() => _saving = false);
  }

  void _changed() => setState(() => _dirty = true);

  Widget _field(PersonEntry p, String field, String value, String hint, void Function(String) set, {double? width}) {
    final f = TextField(
      controller: _c(p, field, value),
      style: TextStyle(fontSize: 14, color: K.ink),
      decoration: InputDecoration(isDense: true, hintText: hint, hintStyle: TextStyle(color: K.faint), border: const OutlineInputBorder()),
      onChanged: (v) {
        set(v.trim());
        _changed();
      },
    );
    return width == null ? Expanded(child: f) : SizedBox(width: width, child: f);
  }

  Widget _row(PersonEntry p) => Padding(
        key: ObjectKey(p),
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // 「我」那一行：名字不能改、不能删（改了 / 删了，「小耳」「小耳老师」就不再认成我），只改叫法
          if (isMe(_orig[p] ?? p.name))
            SizedBox(
                width: 110,
                child: Tooltip(
                    message: '这一行是你自己：叫法里写别人怎么喊你（小耳、小耳老师），这么叫你的事都算你的',
                    child: Text('我', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: K.accent))))
          else
            _field(p, 'name', p.name, '名字', (v) => p.name = v, width: 110),
          const SizedBox(width: 8),
          _field(p, 'aliases', p.aliases.join('、'), '叫法：董哥、董老师', (v) => p.aliases = [for (final a in v.split(RegExp(r'[、,，]'))) if (a.trim().isNotEmpty) a.trim()]),
          const SizedBox(width: 8),
          SizedBox(
            width: 104,
            child: DropdownButtonFormField<String>(
              initialValue: personIdentities.contains(p.identity) ? p.identity : null,
              isDense: true,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: '身份'),
              items: [for (final x in personIdentities) DropdownMenuItem(value: x, child: Text(x, style: const TextStyle(fontSize: 14)))],
              onChanged: (v) {
                p.identity = v ?? '';
                _changed();
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 170,
            child: Autocomplete<String>(
              initialValue: TextEditingValue(text: p.project),
              optionsBuilder: (v) => _projects.where((x) => x.contains(v.text.trim())),
              onSelected: (v) {
                p.project = v;
                _changed();
              },
              fieldViewBuilder: (ctx, c, focus, submit) => TextField(
                controller: c,
                focusNode: focus,
                style: TextStyle(fontSize: 14, color: K.ink),
                decoration: InputDecoration(isDense: true, hintText: '常跟哪个项目', hintStyle: TextStyle(color: K.faint), border: const OutlineInputBorder()),
                onChanged: (v) {
                  p.project = v.trim();
                  _changed();
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          _field(p, 'company', p.company, '公司', (v) => p.company = v, width: 130),
          const SizedBox(width: 8),
          _field(p, 'note', p.note, _auto.containsKey(p) ? '录音里出现过 ${_auto[p]} 段，写点什么就存进名单' : '介绍（可不填）', (v) => p.note = v),
          if (isMe(_orig[p] ?? p.name))
            const SizedBox(width: 40)
          else
            IconButton(
              tooltip: '删掉这个人',
              icon: Icon(Icons.close, size: 18, color: K.mute),
              onPressed: () => setState(() {
                _people.remove(p);
                if ((_orig[p] ?? p.name).trim().isNotEmpty) _removed.add(p);
                _dirty = true;
              }),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(28, widget.top, 28, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('人员名单', style: K.title(26).copyWith(color: K.ink)),
            const SizedBox(width: 10),
            Text('${_people.where((p) => p.name.isNotEmpty).length} 人', style: TextStyle(fontSize: 13, color: K.mute)),
            const Spacer(),
            if (_dirty) Text('有改动没存', style: TextStyle(fontSize: 12.5, color: K.todo)),
            const SizedBox(width: 10),
            FilledButton(onPressed: _saving || !_dirty ? null : _save, child: Text(_saving ? '存着…' : '存')),
          ]),
          const SizedBox(height: 2),
          const Squiggle(width: 120),
          const SizedBox(height: 10),
          Text(
              '录音里常出现的人。拆事时用它认说话人、判断「这件事归谁」。叫法写全一点，录音里怎么喊的就怎么写，转写常听错的也写上（比如「阿星、阿西」）。'
              '甲方提的要求一般归你；合作方说「我去…」一般归他。存在资料文件夹的「人员名单.md」，只存这一份。',
              style: TextStyle(fontSize: 12.5, height: 1.5, color: K.faint)),
        ]),
      ),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(28, 4, 20, 24), children: [
          for (final p in _people) _row(p),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('加一个人'),
              onPressed: () => setState(() {
                _people.add(PersonEntry(''));
                _dirty = true;
              }),
            ),
          ),
        ]),
      ),
    ]);
  }
}
