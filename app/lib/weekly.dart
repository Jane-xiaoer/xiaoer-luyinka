// 每周回顾：有录音的每一周（周一到周日），把这周所有段的笔记交给模型写一份回顾，
// 存成资料文件夹里的 每周/<年>-W<周数> (<周一>–<周日>).md。App 只从文件读，不另存。
import 'dart:io';

import 'analyze.dart';
import 'library.dart';
import 'store.dart';
import 'templates.dart';
import 'theme.dart' show duration, hm;
import 'todos.dart';

const weekMaterialMax = 60000; // 一周的资料最多喂这么多字

/// 一周：周一到周日，周数按 ISO（周一开头；这周的周四落在哪年就算哪年的第几周）。
class Week {
  final DateTime monday; // UTC 零点，算天数不受夏令时影响
  Week._(this.monday);

  factory Week.of(DateTime d) {
    final x = DateTime.utc(d.year, d.month, d.day);
    return Week._(x.subtract(Duration(days: x.weekday - 1)));
  }

  /// 「2026-10-18」这样的日子属于哪一周。
  factory Week.ofDay(String day) => Week.of(DateTime.parse(day.substring(0, 10)));

  DateTime get sunday => monday.add(const Duration(days: 6));
  DateTime get _thursday => monday.add(const Duration(days: 3));
  int get year => _thursday.year;
  int get number => _thursday.difference(DateTime.utc(_thursday.year, 1, 1)).inDays ~/ 7 + 1;
  String get key => '$year-W${_p2(number)}';

  /// 每周/ 里的文件名。
  String get fileName => '$key (${_ymd(monday)}–${_ymd(sunday)}).md';

  /// 10/12–10/18
  String get label => '${monday.month}/${monday.day}–${sunday.month}/${sunday.day}';

  bool contains(String day) => Week.ofDay(day).key == key;

  /// 这周已经过完了（[now] 已经是下周一或更晚）。
  bool isOver(DateTime now) => !DateTime.utc(now.year, now.month, now.day).isBefore(monday.add(const Duration(days: 7)));

  @override
  bool operator ==(Object other) => other is Week && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// 有录音的每一周，新的在前。[days] 是 yyyy-mm-dd。
List<Week> weeksOf(Iterable<String> days) {
  final out = {for (final d in days) Week.ofDay(d)}.toList();
  out.sort((a, b) => b.monday.compareTo(a.monday));
  return out;
}

/// 这周的段，按时间先后。
List<Scene> scenesIn(Week w, List<Scene> scenes) {
  final out = [for (final s in scenes) if (w.contains(s.dayKey)) s];
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// App 自己算好的数字（不让模型数）。
class WeekStats {
  final int scenes, days, meetings, deals;
  final Duration total;
  final Map<String, int> byCat; // 类别 → 段数，多的在前
  const WeekStats(this.scenes, this.days, this.meetings, this.deals, this.total, this.byCat);

  factory WeekStats.of(List<Scene> scenes) {
    final by = <String, int>{};
    for (final s in scenes) {
      by[s.category] = (by[s.category] ?? 0) + 1;
    }
    final sorted = Map.fromEntries(by.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
    return WeekStats(
      scenes.length,
      {for (final s in scenes) s.dayKey}.length,
      by['开会'] ?? 0,
      by['商务洽谈'] ?? 0,
      scenes.fold(Duration.zero, (a, s) => a + s.end.difference(s.start)),
      sorted,
    );
  }
}

const weeklyPrompt = '''你在帮我写录音卡的「每周回顾」。资料是这一周我录音卡整理出的每一段（时间、类别、标题、事件、人物、整理好的笔记），还有 App 算好的数字和还没完成的待办。
写 Markdown，只用下面五节，节标题一字不改、按这个顺序：
## 这周概览
2–4 句：开了几次会、几次洽谈、一共录了多久（这些数字只用资料里「App 算好的数字」，不要自己数、不要改），再说这周主要在忙什么。
## 推进了什么
按事情归并，每条：哪件事、推进到哪一步、关键结论或数字，末尾标日期，如「（10/17）」。
## 答应了谁什么
只列还没完成的，每条写清：谁去做、对谁、做什么、什么时候，末尾标日期。来源是「还没完成的待办」和笔记里说过要做的。
待办里标了「谁去做」的照它写：是别人去做的写成「某某去做：…」，不要写成「我答应某某」；没标谁去做的算我自己要做的；笔记里没说对谁的，就不写对谁，不要猜。
## 新冒出的观点
我这周说出来的新看法、判断、想法，尽量用原话（原话用「」括起来），末尾标日期。
## 下周要盯的
3–6 条，从上面推出来，具体到人和事。
规矩：只用资料里有的事实、人名、数字和原话，不编、不补；某一节没有内容就写「这周没有」。不要开场白和结尾客套，不要用代码块包起来。''';

/// 交给模型的资料。笔记太长时每段平均截短，总长不超过 [max]。
String weekMaterial(Week w, List<Scene> scenes, {int max = weekMaterialMax}) {
  final st = WeekStats.of(scenes);
  final head = StringBuffer()
    ..writeln('## App 算好的数字（直接用）')
    ..writeln('- 这周：${_ymd(w.monday)}（周一）到 ${_ymd(w.sunday)}（周日），${w.key}')
    ..writeln('- 有录音的天数：${st.days} 天')
    ..writeln('- 一共录了：${duration(st.total)}（各段时长加起来）')
    ..writeln('- 一共 ${st.scenes} 段：开会 ${st.meetings} 次，商务洽谈 ${st.deals} 次')
    ..writeln('- 各类段数：${st.byCat.entries.map((e) => '${e.key} ${e.value}').join('、')}')
    ..writeln();
  final open = todosOf(scenes).where((t) => !t.done).toList();
  head.writeln('## 还没完成的待办（App 汇总，打过勾的不在里面）');
  if (open.isEmpty) head.writeln('（没有）');
  for (final t in open.reversed) {
    head.writeln('- [${t.source}] ${t.text}${t.who.isNotEmpty ? '（谁去做：${t.who}）' : ''}${t.when.isNotEmpty ? '（什么时候：${t.when}）' : ''}');
  }
  head
    ..writeln()
    ..writeln('## 这周每一段（按时间先后）');
  final metas = [
    for (final s in scenes)
      [
        '### ${s.start.month}/${s.start.day} 周${'一二三四五六日'[s.start.weekday - 1]} ${hm(s.start)}–${hm(s.end)} · ${catKey(s.category)} · ${s.title}',
        if (s.event.isNotEmpty) '- 事件：${s.event}',
        if (s.people.isNotEmpty) '- 人物：${s.people.join('、')}',
        if (s.place.isNotEmpty) '- 地点：${s.place}',
        if (s.subject.isNotEmpty) '- 调研对象：${s.subject}',
      ].join('\n'),
  ];
  final bodies = [for (final s in scenes) (s.body.isNotEmpty ? s.body : legacyBody(s)).trim()];
  final fixed = head.length + metas.fold<int>(0, (a, m) => a + m.length + 4);
  final need = bodies.fold<int>(0, (a, b) => a + b.length);
  final room = max - fixed;
  final each = scenes.isEmpty ? 0 : (room / scenes.length).floor().clamp(400, max);
  final b = StringBuffer(head.toString());
  for (final (i, m) in metas.indexed) {
    var body = bodies[i];
    if (need > room && body.length > each) body = '${body.substring(0, each)}…（后面略）';
    b
      ..writeln(m)
      ..writeln(body.isEmpty ? '（这段没有整理好的笔记）' : body)
      ..writeln();
  }
  final out = b.toString().trim();
  return out.length > max ? out.substring(0, max) : out;
}

/// 每周/ 里这周的回顾文件（找不到就是 null）。文件名被改过也认：只看开头的「2026-W42」。
File? weekFile(Library lib, Week w) {
  final exact = File('${lib.weeksDir.path}/${w.fileName}');
  if (exact.existsSync()) return exact;
  if (!lib.weeksDir.existsSync()) return null;
  for (final f in lib.weeksDir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (name.endsWith('.md') && (name.startsWith('${w.key} ') || name == '${w.key}.md')) return f;
  }
  return null;
}

/// 生成这周的回顾，写进 每周/，返回文件。旧的（同一周）先删掉。
Future<File> generateWeekly(Library lib, Week w, List<Scene> scenes, Chat chat, {DateTime? now}) async {
  if (scenes.isEmpty) throw StateError('这周没有录音');
  final out = await chat(weeklyPrompt, weekMaterial(w, scenes));
  final body = out.replaceAll(RegExp(r'^```(markdown|md)?\s*|\s*```$'), '').trim();
  if (body.isEmpty) throw StateError('模型没回内容');
  final at = now ?? DateTime.now();
  final md = '# 每周回顾 · ${w.key}（${w.label}）\n\n'
      '> 生成时间：${_ymd(at)} ${hm(at)} · 资料：这周 ${scenes.length} 段录音整理好的笔记\n\n'
      '$body\n';
  await lib.weeksDir.create(recursive: true);
  final old = weekFile(lib, w);
  if (old != null && await old.exists()) await old.delete();
  final f = File('${lib.weeksDir.path}/${w.fileName}');
  await f.writeAsString(md);
  return f;
}

String _p2(int n) => n.toString().padLeft(2, '0');
String _ymd(DateTime t) => '${t.year}-${_p2(t.month)}-${_p2(t.day)}';
