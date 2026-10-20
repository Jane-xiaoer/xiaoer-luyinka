// 按人看：所有场景 people 里出现过的人，跟某个人有关的段、往来小结、见面前准备的要求。
import 'search.dart';
import 'store.dart';

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

class Person {
  final String name; // 第一次见到时的写法（归一后）
  final int count; // 出现在几段里
  const Person(this.name, this.count);
}

/// 所有人，按出现的段数多 → 少；一样多的，最近见过的在前。[scenes] 新的在前。
List<Person> peopleOf(List<Scene> scenes) {
  final names = <String, String>{}, counts = <String, int>{}, order = <String, int>{};
  for (final s in scenes) {
    for (final k in {for (final p in s.people) if (personKey(p).isNotEmpty) personKey(p)}) {
      names.putIfAbsent(k, () => normPerson(s.people.firstWhere((p) => personKey(p) == k)));
      counts[k] = (counts[k] ?? 0) + 1;
      order.putIfAbsent(k, () => order.length);
    }
  }
  final keys = counts.keys.toList()
    ..sort((a, b) => counts[a] != counts[b] ? counts[b]!.compareTo(counts[a]!) : order[a]!.compareTo(order[b]!));
  return [for (final k in keys) Person(names[k]!, counts[k]!)];
}

/// 跟 [name] 有关的段（people 里有他），新的在前。
List<Scene> scenesWith(List<Scene> scenes, String name) {
  final k = personKey(name);
  final out = [for (final s in scenes) if (s.people.any((p) => personKey(p) == k)) s];
  out.sort((a, b) => b.start.compareTo(a.start));
  return out;
}

class PersonTodo {
  final Scene scene;
  final String text, who, when;
  const PersonTodo(this.scene, this.text, {this.who = '', this.when = ''});
}

/// 还没兑现的待办：这些段的 actions / reminders 里，who 或 text 提到 [name] 的。新的段在前。
List<PersonTodo> todosWith(List<Scene> scenes, String name) {
  final k = personKey(name);
  bool hit(Object? x) => k.isNotEmpty && personKey('${x ?? ''}').contains(k);
  return [
    for (final s in scenes) ...[
      for (final a in s.actions)
        if (hit(a['who']) || hit(a['text'])) PersonTodo(s, '${a['text']}', who: '${a['who'] ?? ''}'),
      for (final r in s.reminders)
        if (hit(r['text']) || hit(r['who'])) PersonTodo(s, '${r['text']}', when: '${r['when'] ?? ''}'),
    ],
  ];
}

/// 「见面前帮我准备」发给小耳的要求（资料是跟他有关的那几段的笔记，由对话那边给）。
String prepPrompt(String name) =>
    '我要和「$name」见面了。资料里是我录音卡里所有跟$name有关的记录（整理好的笔记）。帮我做一份见面前的准备，Markdown，短，'
    '用这几节：「## 上次谈到哪」（最近一次是哪天、谈了什么、停在哪一步）、「## $name在意什么」（对方的诉求、顾虑、底线）、'
    '「## 我答应过什么」（我这边说过要做、还没确认做完的，带当时的日期）、「## 这次可以聊什么」（3–5 条，从上面推出来的具体话题）。'
    '每节最多 5 条，只用记录里有的事实、数字和原话，没有的那节就写「记录里没有」，不编。';
