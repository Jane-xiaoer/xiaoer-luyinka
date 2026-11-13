// 按人看：所有场景 people 里出现过的人，跟某个人有关的段、往来小结、见面前准备的要求。
import 'dart:convert';

import 'analyze.dart' show aliasMap;
import 'search.dart';
import 'store.dart';
import 'templates.dart' show HiddenPerson, PersonEntry, personIdentities;

/// 人名轻度归一：全角转半角、去掉所有空白。「王总」「王总监」不合并。
String normPerson(String name) {
  final out = StringBuffer();
  for (final c in name.runes) {
    var x = c;
    if (x == 0x3000) continue;
    if (x >= 0xFF01 && x <= 0xFF5E) x -= 0xFEE0;
    out.writeCharCode(x);
  }
  return out.toString().replaceAll(RegExp(r'\s+'), '');
}

/// 比较用的键：归一后再统一英文大小写。
String personKey(String name) => fold(normPerson(name));

/// 人员名单 + 藏起来的人：把录音里的各种叫法认成名单上的同一个人（「周总」并进「周总周宁」后，两边的段都算他的）。
class Roster {
  final List<PersonEntry> entries;
  final List<HiddenPerson> hiddenPeople;
  final Set<String> hidden = {}; // 藏起来的 personKey
  final Map<String, String> _canon = {}; // personKey(名字 / 叫法) → 名单上的名字
  Roster(this.entries, {this.hiddenPeople = const []}) {
    for (final e in entries) {
      if (personKey(e.name).isNotEmpty) _canon.putIfAbsent(personKey(e.name), () => e.name);
    }
    // 叫法跟拆事用同一套规则：叫法等于别人名字、两个人共用的，都不换
    aliasMap(entries).forEach((a, n) => _canon.putIfAbsent(personKey(a), () => n));
    // 藏：删掉的人的名字和叫法；但名单上现在有人用着的（别人的名字 / 叫法，或者又加回来的同名人）不藏，免得牵连别人
    final used = {for (final e in entries) ...[personKey(e.name), for (final a in e.aliases) personKey(a)]};
    for (final h in hiddenPeople) {
      for (final k in {personKey(h.e.name), for (final a in h.e.aliases) personKey(a)}) {
        if (k.isNotEmpty && !used.contains(k)) hidden.add(k);
      }
    }
  }
  static final empty = Roster(const []);

  /// 录音里的写法 → 认成谁（名单上没有就是它自己，轻度归一）。
  String canon(String raw) => _canon[personKey(raw)] ?? normPerson(raw);
  PersonEntry? entry(String name) => entries.where((e) => personKey(e.name) == personKey(name)).firstOrNull;
  bool isHidden(String name) => hidden.contains(personKey(canon(name)));

  /// 名单上别人占着的名字和叫法 → 是谁（[except] 自己的不算）。改名、补叫法时查撞没撞。
  Map<String, String> takenBy(String except) => {
        for (final e in entries)
          if (personKey(e.name) != personKey(except)) ...{
            personKey(e.name): e.name,
            for (final a in e.aliases) if (personKey(a).isNotEmpty) personKey(a): e.name,
          }
      };

  /// 这个人的所有叫法（含名字），找待办时用。
  Set<String> keysOf(String name) {
    final c = canon(name), e = entry(c);
    // 叫法按「包含」找待办，单字叫法（欧、练）会误中「去欧洲」，只用两个字以上的
    return {personKey(c), personKey(name),
      if (e != null) for (final a in e.aliases) if (_canon[personKey(a)] == e.name && personKey(a).runes.length >= 2) personKey(a)}
      ..removeWhere((k) => k.isEmpty);
  }
}

class Person {
  final String name; // 名单上的名字；名单上没有的，是第一次见到时的写法（归一后）
  final int count; // 出现在几段里
  final PersonEntry? entry; // 名单上的资料（没写过就是 null）
  const Person(this.name, this.count, [this.entry]);
  String get group => entry?.group ?? '';
  List<String> get groups => entry?.groups ?? const [];
}

/// 所有人，按出现的段数多 → 少；一样多的，最近见过的在前。[scenes] 新的在前。
/// 有 [roster]：叫法并到名单上的名字、藏起来的人不列；名单上还没在录音里出现过的人也列上（0 段，排最后）。
List<Person> peopleOf(List<Scene> scenes, [Roster? roster]) {
  final r = roster ?? Roster.empty;
  final names = <String, String>{}, counts = <String, int>{}, order = <String, int>{};
  for (final s in scenes) {
    final seen = <String, String>{};
    for (final p in s.people) {
      final c = r.canon(p), k = personKey(c);
      if (k.isNotEmpty) seen.putIfAbsent(k, () => c);
    }
    seen.forEach((k, c) {
      names.putIfAbsent(k, () => c);
      counts[k] = (counts[k] ?? 0) + 1;
      order.putIfAbsent(k, () => order.length);
    });
  }
  for (final e in r.entries) {
    final k = personKey(e.name);
    if (k.isEmpty || counts.containsKey(k)) continue;
    names[k] = e.name;
    counts[k] = 0;
    order[k] = order.length;
  }
  final keys = counts.keys.where((k) => !r.hidden.contains(k) && k != personKey(meName)).toList() // 「我」不列
    ..sort((a, b) => counts[a] != counts[b] ? counts[b]!.compareTo(counts[a]!) : order[a]!.compareTo(order[b]!));
  return [for (final k in keys) Person(names[k]!, counts[k]!, r.entry(names[k]!))];
}

/// 跟 [name] 有关的段（people 里有他，叫法也算），新的在前。
List<Scene> scenesWith(List<Scene> scenes, String name, [Roster? roster]) {
  final r = roster ?? Roster.empty;
  final k = personKey(r.canon(name));
  final out = [for (final s in scenes) if (s.people.any((p) => personKey(r.canon(p)) == k)) s];
  out.sort((a, b) => b.start.compareTo(a.start));
  return out;
}

class PersonTodo {
  final Scene scene;
  final String text, who, when;
  const PersonTodo(this.scene, this.text, {this.who = '', this.when = ''});
}

/// 还没兑现的待办：这些段的 actions / reminders 里，没打勾、who 或 text 提到 [name] 的。新的段在前。
List<PersonTodo> todosWith(List<Scene> scenes, String name, [Roster? roster]) {
  final ks = (roster ?? Roster.empty).keysOf(name);
  // 单字的名字（欧、练）按「包含」会误中「去欧洲」：单字的只认 who 整个就是他
  bool hit(Object? x, {bool who = false}) {
    final t = personKey('${x ?? ''}');
    return ks.any((k) => k.runes.length >= 2 ? t.contains(k) : (who && t == k));
  }
  return [
    for (final s in scenes) ...[
      for (final a in s.actions)
        if (a['done'] != true && (hit(a['who'], who: true) || hit(a['text']))) PersonTodo(s, '${a['text']}', who: '${a['who'] ?? ''}'),
      for (final r in s.reminders)
        if (r['done'] != true && (hit(r['text']) || hit(r['who'], who: true))) PersonTodo(s, '${r['text']}', when: '${r['when'] ?? ''}'),
    ],
  ];
}

/// 「见面前帮我准备」发给小耳的要求（资料是跟他有关的那几段的笔记，由对话那边给）。
String prepPrompt(String name) =>
    '我要和「$name」见面了。资料里是我录音卡里所有跟$name有关的记录（整理好的笔记）。帮我做一份见面前的准备，Markdown，短，'
    '用这几节：「## 上次谈到哪」（最近一次是哪天、谈了什么、停在哪一步）、「## $name在意什么」（对方的诉求、顾虑、底线）、'
    '「## 我答应过什么」（我这边说过要做、还没确认做完的，带当时的日期）、「## 这次可以聊什么」（3–5 条，从上面推出来的具体话题）。'
    '每节最多 5 条，只用记录里有的事实、数字和原话，没有的那节就写「记录里没有」，不编。';

// ───────── 在「按人」里管人：改资料 / 并人 / 删人（都落到 人员名单.md）─────────

List<String> _uniq(Iterable<String> xs) {
  final seen = <String>{}, out = <String>[];
  for (final x in xs) {
    final t = x.trim();
    if (t.isNotEmpty && seen.add(personKey(t))) out.add(t);
  }
  return out;
}

/// 存一个人的资料：名单上有 [oldName] 就换掉，没有就加上。改了名字的，旧名字留作叫法（以前录音里的段还认得出是他）。
List<PersonEntry> upsertPerson(List<PersonEntry> list, String oldName, PersonEntry p) {
  final out = [for (final e in list) e.copy()];
  final q = p.copy()..name = normPerson(p.name);
  q.aliases = _uniq([q.name, ...q.aliases, if (oldName.trim().isNotEmpty) normPerson(oldName)]);
  final i = out.indexWhere((e) => personKey(e.name) == personKey(oldName));
  if (i >= 0) {
    out[i] = q;
  } else {
    out.add(q);
  }
  return out;
}

/// 把 [from] 并进 [into]（同一个人录音里叫法不一样，比如「周总」和「周总周宁」）：
/// [from] 和它的叫法都变成 [into] 的叫法；[into] 没填的资料用 [from] 的补上，两边都有的备注接在一起。
List<PersonEntry> mergePerson(List<PersonEntry> list, String from, String into) {
  final out = [for (final e in list) e.copy()];
  final fi = out.indexWhere((e) => personKey(e.name) == personKey(from));
  final f = fi >= 0 ? out.removeAt(fi) : null;
  var t = out.where((e) => personKey(e.name) == personKey(into)).firstOrNull;
  if (t == null) out.add(t = PersonEntry(normPerson(into), aliases: [normPerson(into)]));
  t.aliases = _uniq([t.name, ...t.aliases, normPerson(from), ...?f?.aliases]);
  if (f != null) {
    if (t.identity.isEmpty) t.identity = f.identity;
    if (t.project.isEmpty) t.project = f.project;
    if (t.company.isEmpty) t.company = f.company;
    if (f.note.isNotEmpty && !t.note.contains(f.note)) t.note = t.note.isEmpty ? f.note : '${t.note}；${f.note}';
  }
  return out;
}

/// 删掉一个人：从名单上拿掉，整行资料存进「删掉的人」，左栏「按人」不再列（录音和段都不动）。返回（新名单，新的删掉的人）。
(List<PersonEntry>, List<HiddenPerson>) removePerson(List<PersonEntry> list, List<HiddenPerson> hidden, String name) {
  final out = [for (final e in list) e.copy()];
  final i = out.indexWhere((e) => personKey(e.name) == personKey(name));
  final h = i >= 0 ? HiddenPerson(out.removeAt(i), listed: true) : HiddenPerson(PersonEntry(normPerson(name), aliases: [normPerson(name)]));
  return (out, [for (final x in hidden) if (personKey(x.e.name) != personKey(name)) x, h]);
}

/// 找回删掉的人：资料原样放回名单（名单上已经又有同名的就不重复加），从「删掉的人」里拿掉。
(List<PersonEntry>, List<HiddenPerson>) restorePerson(List<PersonEntry> list, List<HiddenPerson> hidden, String name) {
  final out = [for (final e in list) e.copy()];
  final h = hidden.where((x) => personKey(x.e.name) == personKey(name)).firstOrNull;
  if (h != null && h.listed && !out.any((e) => personKey(e.name) == personKey(name))) out.add(h.e.copy());
  return (out, [for (final x in hidden) if (personKey(x.e.name) != personKey(name)) x]);
}

// ───────── 「我」：别人在录音里怎么叫我（小耳、小耳老师）─────────

/// 名单上代表录音卡主人的那一行叫「我」，叫法写别人怎么称呼我。拆事时这些叫法统一成「我」（这件事归我），按人里不列。
const meName = '我';
bool isMe(String name) => personKey(name) == personKey(meName);

// ───────── 一组人（同一家公司 / 同一个项目）─────────

/// 这一组的人（[group] 是 Person.group）。
List<Person> membersOf(List<Person> people, String group) => [for (final p in people) if (p.groups.contains(group)) p];

/// 跟这组里任何一个人有关的段，新的在前，不重复。
List<Scene> scenesInGroup(List<Scene> scenes, List<String> names, [Roster? roster]) {
  final r = roster ?? Roster.empty;
  final ks = {for (final n in names) personKey(r.canon(n))};
  final out = [for (final s in scenes) if (s.people.any((p) => ks.contains(personKey(r.canon(p))))) s];
  out.sort((a, b) => b.start.compareTo(a.start));
  return out;
}

/// 这组人的还没兑现的待办（同一条只算一次）。
List<PersonTodo> todosInGroup(List<Scene> scenes, List<String> names, [Roster? roster]) {
  final seen = <String>{}, out = <PersonTodo>[];
  for (final n in names) {
    for (final t in todosWith(scenes, n, roster)) {
      if (seen.add('${t.scene.id}|${t.text}')) out.add(t);
    }
  }
  return out;
}

/// 「见面前帮我准备」：对一整家公司 / 一个项目。
String groupPrepPrompt(String group, List<String> names) =>
    '我要跟「$group」（${names.join('、')}）见面了。资料里是我录音卡里所有跟他们有关的记录（整理好的笔记）。帮我做一份见面前的准备，Markdown，短，'
    '用这几节：「## 上次谈到哪」（最近一次是哪天、谈了什么、停在哪一步）、「## 他们各自在意什么」（按人写诉求、顾虑、底线）、'
    '「## 我答应过什么」（我这边说过要做、还没确认做完的，带当时的日期）、「## 这次可以聊什么」（3–5 条，从上面推出来的具体话题）。'
    '每节最多 5 条，只用记录里有的事实、数字和原话，没有的那节就写「记录里没有」，不编。';

// ───────── 写资料的草稿：小耳从录音笔记里先填 ─────────

/// 给小耳的要求：从跟 [name] 有关的笔记里看出他是哪个公司、哪个项目、什么身份、一句介绍。资料由调用方拼进 user。
String draftSystem(String name) =>
    '下面是我录音卡里跟「$name」有关的几段会议笔记。只根据这些笔记，帮我填$name的资料，回一个 JSON，不要别的字：'
    '{"company":"他所在的公司或机构，看不出来就空","project":"他跟我主要在合作的项目，看不出来就空",'
    '"identity":"他相对我是 合作方 / 甲方 / 同事 / 朋友 / 家人 / 其他 之一，看不出来就空",'
    '"note":"一两句介绍：他负责什么、在这些会上说过的关键立场或要求，40 字以内，不编"}';

/// 跟 [name] 有关的段的笔记（新的在前，最多 [max] 段，每段截短），给草稿用。
String draftNotes(List<Scene> scenes, {int max = 6}) => [
      for (final s in scenes.take(max))
        '### ${s.start.month}/${s.start.day} ${s.title}（在场：${s.people.join('、')}）\n'
            '${(s.body.isNotEmpty ? s.body : s.event).length > 1500 ? '${(s.body.isNotEmpty ? s.body : s.event).substring(0, 1500)}…' : (s.body.isNotEmpty ? s.body : s.event)}',
    ].join('\n\n');

/// 小耳回的 JSON → 草稿（只留认得的四栏，身份不在选项里的丢掉）。读不出来就是空的。
Map<String, String> parseDraft(String reply) {
  // 回复里可能有几段 {}：从最长的试起，哪段读得出来用哪段
  final cands = [for (final m in RegExp(r'\{[^{}]*\}').allMatches(reply)) m.group(0)!];
  final whole = RegExp(r'\{[\s\S]*\}').firstMatch(reply)?.group(0);
  for (final c in [?whole, ...cands]) {
    final r = _draftOf(c);
    if (r != null && r.isNotEmpty) return r; // 读得出、又有内容的那段
  }
  return {};
}

Map<String, String>? _draftOf(String json) {
  try {
    final j = jsonDecode(json) as Map;
    String v(String k) => '${j[k] ?? ''}'.trim();
    return {
      for (final k in ['company', 'project', 'note']) if (v(k).isNotEmpty) k: v(k),
      if (personIdentities.contains(v('identity'))) 'identity': v('identity'),
    };
  } catch (_) {
    return null;
  }
}

/// 一家公司 / 一个项目里的人。
class PersonGroup {
  final String name;
  final List<Person> members;
  const PersonGroup(this.name, this.members);
  List<String> get names => [for (final p in members) p.name];
}

/// 按项目分组（一个人跟几个项目就进几组；没写项目按公司）；没写的人不进任何组。跟组里人有关的段多的组在前。
List<PersonGroup> groupsOf(List<Person> people, List<Scene> scenes, [Roster? roster]) {
  final by = <String, List<Person>>{};
  for (final p in people) {
    for (final g in p.groups) {
      (by[g] ??= []).add(p);
    }
  }
  final n = {for (final e in by.entries) e.key: scenesInGroup(scenes, [for (final p in e.value) p.name], roster).length};
  final keys = by.keys.toList()..sort((a, b) => n[b]!.compareTo(n[a]!));
  return [for (final k in keys) PersonGroup(k, by[k]!)];
}

// ───────── 人员名单页存之前：同名并一行、撞名拦下 ─────────

/// 一行的名字 + 叫法（比较用的键）。
Set<String> keysOfEntry(PersonEntry e) => {personKey(e.name), for (final a in e.aliases) personKey(a)}..remove('');

/// 名字一样的几行并成一行（叫法合起来，空的栏补上）。只并「至少一边还没写资料」的（录音里来的「周总」改成「周总周宁」）；
/// 两边都写了资料的不并，留给 nameClash 拦下，免得悄悄丢掉一个人的资料。并进去的那行算改过。
List<PersonEntry> collapseSameName(List<PersonEntry> list, Set<PersonEntry> changed) {
  bool blank(PersonEntry x) => [x.identity, x.project, x.company, x.note].every((v) => v.trim().isEmpty);
  final out = <PersonEntry>[];
  for (final e in list) {
    final t = out.where((x) => personKey(x.name) == personKey(e.name) && (blank(x) || blank(e))).firstOrNull;
    if (t == null) {
      out.add(e);
      continue;
    }
    t.aliases = _uniq([...t.aliases, ...e.aliases]);
    if (t.identity.isEmpty) t.identity = e.identity;
    if (t.project.isEmpty) t.project = e.project;
    if (t.company.isEmpty) t.company = e.company;
    if (e.note.isNotEmpty && !t.note.contains(e.note)) t.note = t.note.isEmpty ? e.note : '${t.note}；${e.note}';
    changed.add(t);
  }
  return out;
}

/// 两个人用了同一个名字 / 叫法，而且至少一边是这次改的：返回（撞的那个写法，另一个人的名字）；没撞返回 null。
/// 原来就撞着的（两边都没改）不拦，拆事那边本来就两个都不换。
(String, String)? nameClash(List<PersonEntry> list, Set<PersonEntry> changed) {
  final owner = <String, PersonEntry>{};
  for (final e in list) {
    for (final k in keysOfEntry(e)) {
      final o = owner[k];
      if (o == null) {
        owner[k] = e;
      } else if (!identical(o, e) && (changed.contains(e) || changed.contains(o))) {
        final mine = changed.contains(e) ? e : o, other = identical(mine, e) ? o : e;
        final shown = [mine.name, ...mine.aliases].firstWhere((x) => personKey(x) == k, orElse: () => k);
        return (shown, other.name);
      }
    }
  }
  return null;
}
