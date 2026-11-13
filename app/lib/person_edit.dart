// 左栏「按人」里点开一个人：写他是谁（公司 / 项目 / 身份 / 介绍 / 叫法），并到另一个人，删掉。
// 2026-11-11 Jane：「录制的时候写人是比较仓促的，要有个地方给我编辑」「一个公司一个项目的我还能拉到一个组里」。
import 'package:flutter/material.dart';

import 'people.dart';
import 'templates.dart';
import 'theme.dart';

/// 编辑一个人的资料。返回改好的（取消返回 null）。[taken] 是名单上别人的名字，改名撞上了要提示用「并到…」。
Future<PersonEntry?> editPerson(BuildContext context, PersonEntry p,
        {List<String> companies = const [], List<String> projects = const [], Map<String, String> taken = const {},
        Future<Map<String, String>>? draft}) =>
    showDialog<PersonEntry>(
        context: context,
        builder: (_) => _PersonDialog(p: p.copy(), companies: companies, projects: projects, taken: taken, draft: draft));

class _PersonDialog extends StatefulWidget {
  final PersonEntry p;
  final List<String> companies, projects;
  final Map<String, String> taken; // 别人占着的名字 / 叫法 → 是谁
  final Future<Map<String, String>>? draft; // 小耳从录音里看出来的草稿（公司 / 项目 / 身份 / 介绍）
  const _PersonDialog({required this.p, required this.companies, required this.projects, required this.taken, this.draft});
  @override
  State<_PersonDialog> createState() => _PersonDialogState();
}

class _PersonDialogState extends State<_PersonDialog> {
  late final name = TextEditingController(text: widget.p.name);
  late final aliases = TextEditingController(text: widget.p.aliases.where((a) => a != widget.p.name).join('、'));
  late final note = TextEditingController(text: widget.p.note);
  late final companyC = TextEditingController(text: widget.p.company), projectC = TextEditingController(text: widget.p.project);
  late String company = widget.p.company, project = widget.p.project, identity = widget.p.identity;
  String? err;
  String? draftState; // 小耳在填 / 填好了 / 没看出来

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    if (d == null) return;
    draftState = '小耳正在翻录音，帮你先填…';
    d.then((m) {
      if (!mounted) return;
      setState(() {
        // 只填还空着的：她已经动手写了的不覆盖
        if (company.isEmpty && (m['company'] ?? '').isNotEmpty) companyC.text = company = m['company']!;
        if (project.isEmpty && (m['project'] ?? '').isNotEmpty) projectC.text = project = m['project']!;
        if (identity.isEmpty && (m['identity'] ?? '').isNotEmpty) identity = m['identity']!;
        if (note.text.trim().isEmpty && (m['note'] ?? '').isNotEmpty) note.text = m['note']!;
        draftState = m.containsKey('error')
            ? '小耳这会儿没连上，自己填一下吧'
            : m.isEmpty
                ? '录音里没看出他是哪家公司，自己填一下吧'
                : '小耳从录音里看出来的，先帮你填上了，看一眼对不对再存';
      });
    });
  }

  @override
  void dispose() {
    name.dispose();
    aliases.dispose();
    note.dispose();
    companyC.dispose();
    projectC.dispose();
    _companyFocus.dispose();
    _projectFocus.dispose();
    super.dispose();
  }

  void _save() {
    final n = normPerson(name.text);
    if (n.isEmpty) return setState(() => err = '名字不能空着');
    final al = [for (final a in aliases.text.split(RegExp(r'[、,，;；\s]+'))) if (a.trim().isNotEmpty) a.trim()];
    // 撞上别人的名字或叫法：改名会把别人的段抢过来，补叫法会让两边都认不出，先拦下
    final hit = [n, ...al].where((x) => widget.taken.containsKey(personKey(x))).firstOrNull;
    if (hit != null) {
      return setState(() => err = '「$hit」是${widget.taken[personKey(hit)]}的名字或叫法。是同一个人的话，关掉这个框点「并到另一个人」；'
          '不是同一个人就换个写法（比如带上全名），不然两人的录音会混在一起');
    }
    Navigator.of(context).pop(PersonEntry(n,
        aliases: al,
        identity: identity, project: project.trim(), company: company.trim(), note: note.text.trim()));
  }

  InputDecoration _dec(String label, [String? hint]) => InputDecoration(
      labelText: label, hintText: hint, hintStyle: TextStyle(color: K.faint), isDense: true, border: const OutlineInputBorder());

  final _companyFocus = FocusNode(), _projectFocus = FocusNode();

  // 用自己的 controller（小耳的草稿回来要能填进去），下拉提示用 RawAutocomplete
  Widget _auto(String label, String hint, TextEditingController c, FocusNode f, List<String> options, void Function(String) set) =>
      RawAutocomplete<String>(
        textEditingController: c,
        focusNode: f,
        optionsBuilder: (v) => options.where((x) => x.contains(v.text.trim()) && x != v.text.trim()),
        onSelected: set,
        fieldViewBuilder: (ctx, c, focus, submit) =>
            TextField(controller: c, focusNode: focus, decoration: _dec(label, hint), onChanged: set),
        optionsViewBuilder: (ctx, onSel, opts) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 220),
              child: ListView(padding: EdgeInsets.zero, shrinkWrap: true, children: [
                for (final o in opts) ListTile(dense: true, title: Text(o), onTap: () => onSel(o)),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: K.card,
        title: Text('这个人是谁', style: K.title(20).copyWith(color: K.ink)),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(controller: name, autofocus: true, decoration: _dec('名字', '周宁'), onSubmitted: (_) => _save()),
              const SizedBox(height: 12),
              TextField(controller: aliases, decoration: _dec('录音里还怎么叫他', '周总、周总周宁（用顿号隔开）')),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _auto('公司', '明川生物', companyC, _companyFocus, widget.companies, (v) => company = v)),
                const SizedBox(width: 10),
                Expanded(child: _auto('项目', '春芽内容规划', projectC, _projectFocus, widget.projects, (v) => project = v)),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('身份', style: TextStyle(fontSize: 13, color: K.mute)),
                for (final x in personIdentities)
                  ChoiceChip(
                      label: Text(x), selected: identity == x, visualDensity: VisualDensity.compact,
                      onSelected: (on) => setState(() => identity = on ? x : '')),
              ]),
              const SizedBox(height: 12),
              TextField(controller: note, minLines: 3, maxLines: 6, decoration: _dec('介绍', '他负责什么、怎么认识的、要注意什么')),
              if (draftState != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Icon(Icons.auto_awesome, size: 14, color: K.accent),
                    const SizedBox(width: 6),
                    Expanded(child: Text(draftState!, style: TextStyle(fontSize: 12.5, color: K.accent))),
                  ]),
                ),
              const SizedBox(height: 8),
              Text('写了项目，同一个项目的人会归到「按项目」里的一组；一个人跟几个项目，用「、」隔开。这些也会给小耳整理录音时认人、判「归谁」用。',
                  style: TextStyle(fontSize: 12, height: 1.5, color: K.faint)),
              if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: TextStyle(fontSize: 13, color: K.accent))),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          FilledButton(onPressed: _save, child: const Text('存')),
        ],
      );
}

/// 选把 [from] 并到谁身上。
Future<String?> pickMergeTarget(BuildContext context, String from, List<Person> people) => showDialog<String>(
    context: context, builder: (_) => _MergeDialog(from: from, people: [for (final p in people) if (personKey(p.name) != personKey(from)) p]));

class _MergeDialog extends StatefulWidget {
  final String from;
  final List<Person> people;
  const _MergeDialog({required this.from, required this.people});
  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final l = widget.people.where((p) => q.isEmpty || personKey(p.name).contains(personKey(q))).toList();
    return AlertDialog(
      backgroundColor: K.card,
      title: Text('「${widget.from}」是谁', style: K.title(20).copyWith(color: K.ink)),
      content: SizedBox(
        width: 380,
        height: 380,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('选同一个人，两边的录音就合到一起；以后录音里的「${widget.from}」也认成他。'
              '「周总」「王总」这种好几个人都可能这么叫的，确定只指这一个人再并。',
              style: TextStyle(fontSize: 12.5, height: 1.5, color: K.mute)),
          const SizedBox(height: 10),
          TextField(
              autofocus: true,
              decoration: InputDecoration(isDense: true, prefixIcon: const Icon(Icons.search, size: 18), hintText: '找人', border: const OutlineInputBorder()),
              onChanged: (v) => setState(() => q = v)),
          const SizedBox(height: 6),
          Expanded(
            child: ListView(children: [
              for (final p in l)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.person_outline, size: 18, color: K.faint),
                  title: Text(p.name),
                  subtitle: p.group.isEmpty ? null : Text(p.group, style: TextStyle(fontSize: 12, color: K.faint)),
                  trailing: Text('${p.count} 段', style: TextStyle(fontSize: 12, color: K.faint)),
                  onTap: () => Navigator.of(context).pop(p.name),
                ),
            ]),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消'))],
    );
  }
}
