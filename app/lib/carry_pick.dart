// 会上「带上没做完的事」（11-13 方案 A）：挑以前没打勾的待办，插进这场的笔记。
// 插进去的行带着它原来是哪一条（ref = 段 id \t 原文），收会时不新建，会上打勾就勾原来那条（note_store.dart）。
import 'package:flutter/material.dart';

import 'store.dart';
import 'theme.dart';
import 'todos.dart';

/// 可以带上的：近 [days] 天、没打勾、不是笔记里「带上」来的（它自己就是原件）
List<Todo> carryable(Store store, {int days = 60, DateTime? now}) {
  final since = (now ?? DateTime.now()).subtract(Duration(days: days));
  return [
    for (final t in todosOf(store.scenes))
      if (!t.done && t.kind == 'actions' && t.scene.start.isAfter(since)) t,
  ];
}

/// 一条待办跟这几个人有关吗：归他、那一段有他、或者字里提到他
bool aboutPeople(Todo t, Set<String> names) =>
    names.isEmpty || names.contains(t.who) || t.scene.people.any(names.contains) || names.any((n) => n.length >= 2 && t.text.contains(n));

/// 插进笔记的那一行
String carryLine(Todo t) => '☐ ${t.who.isEmpty || t.who == '我' ? '' : '${t.who}：'}${t.text}';

/// 挑：返回挑中的待办（取消返回 null）
Future<List<Todo>?> pickCarry(BuildContext context, Store store) {
  final all = carryable(store);
  final entries = store.lib.peopleEntries().where((p) => p.name != '我').toList();
  final groups = <String, Set<String>>{};
  for (final p in entries) {
    for (final g in [...p.groups, if (p.company.trim().isNotEmpty) p.company.trim()]) {
      (groups[g] ??= {}).add(p.name);
    }
  }
  // 人：待办里出现得多的在前
  final count = <String, int>{};
  for (final p in entries) {
    final n = all.where((t) => aboutPeople(t, {p.name})).length;
    if (n > 0) count[p.name] = n;
  }
  final people = count.keys.toList()..sort((a, b) => count[b]!.compareTo(count[a]!));
  final gkeys = groups.keys.where((g) => all.any((t) => aboutPeople(t, groups[g]!))).toList();
  return showDialog<List<Todo>>(
    context: context,
    builder: (ctx) {
      String? filter; // 公司 / 项目 或 人名
      final picked = <Todo>{};
      return StatefulBuilder(builder: (ctx, set) {
        final names = filter == null ? <String>{} : (groups[filter] ?? {filter!});
        final list = [for (final t in all) if (aboutPeople(t, names)) t];
        Widget chip(String label, String? value) => Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 6),
          child: ChoiceChip(
            label: Text(label, style: const TextStyle(fontSize: 13)),
            selected: filter == value,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => set(() => filter = value),
          ),
        );
        return AlertDialog(
          title: const Text('带上没做完的事'),
          content: SizedBox(
            width: 520,
            height: 460,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('这次跟谁开？挑一下，只看跟他有关的。勾上的插进笔记，会上打勾，原来那条也跟着勾。',
                  style: TextStyle(fontSize: 13, color: K.mute, height: 1.5)),
              const SizedBox(height: 10),
              Wrap(children: [
                chip('全部', null),
                for (final g in gkeys) chip(g, g),
                for (final p in people.take(12)) chip(p, p),
              ]),
              const Divider(),
              Expanded(
                child: list.isEmpty
                    ? Center(child: Text('没有没做完的事', style: TextStyle(color: K.faint)))
                    : ListView(children: [
                        for (final t in list)
                          CheckboxListTile(
                            dense: true,
                            value: picked.contains(t),
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(carryLine(t).substring(2), style: const TextStyle(fontSize: 14)),
                            subtitle: Text(t.source, style: TextStyle(fontSize: 12, color: K.faint)),
                            onChanged: (v) => set(() => v == true ? picked.add(t) : picked.remove(t)),
                          ),
                      ]),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, [for (final t in list) if (picked.contains(t)) t]),
              child: Text(picked.isEmpty ? '带上' : '带上 ${picked.length} 条'),
            ),
          ],
        );
      });
    },
  );
}

/// 插进笔记：末尾加「## 上次没做完」（已经有了就接在后面），返回 (新笔记, 行文字 → ref)
(String, Map<String, String>) insertCarry(String notes, List<Todo> todos) {
  final lines = [for (final t in todos) carryLine(t)];
  final refs = {for (final t in todos) carryLine(t): '${t.scene.id}\t${t.text}'};
  final has = notes.split('\n').contains('## 上次没做完');
  final base = notes.trimRight();
  final next = [
    if (base.isNotEmpty) base,
    if (base.isNotEmpty && !has) '',
    if (!has) '## 上次没做完',
    ...lines,
  ].join('\n');
  return ('$next\n', refs);
}
