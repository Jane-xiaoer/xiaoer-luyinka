// 「问问小耳」的对话：把录音资料、正在看的那一段、前面几轮对话拼成发给模型的 messages。
import 'dart:convert';

import 'library.dart';
import 'search.dart';
import 'store.dart';
import 'templates.dart';

/// 一轮对话：我问的 + 小耳答的（出错的那轮不算，不进历史）。
class Turn {
  final String q, a;
  const Turn(this.q, this.a);
}

/// 正在看的这一段：完整笔记 + 完整逐字稿，不截断（上限 [focusMax] 字）。
String focusBlock(Scene s, {int focusMax = 40000}) {
  final b = StringBuffer()
    ..writeln('## 我正在看的这一段')
    ..writeln('- id：${s.id}')
    ..writeln('- 时间：${s.d['start'].toString().substring(0, 16).replaceFirst('T', ' ')}–${s.d['end'].toString().substring(11, 16)}')
    ..writeln('- 类别：${s.category}')
    ..writeln('- 标题：${s.title}');
  if (s.event.isNotEmpty) b.writeln('- 事件：${s.event}');
  if (s.place.isNotEmpty) b.writeln('- 地点：${s.place}');
  if (s.people.isNotEmpty) b.writeln('- 人物：${s.people.join('、')}');
  if (s.subject.isNotEmpty) b.writeln('- 调研对象：${s.subject}');
  final note = s.body.isNotEmpty ? s.body : legacyBody(s);
  if (note.isNotEmpty) b.writeln('\n### 整理好的笔记\n$note');
  if (s.text.isNotEmpty) {
    b.writeln('\n### 逐字稿');
    for (final l in s.text) {
      b.writeln('${l[0]} ${l[1]}');
    }
  }
  final out = b.toString().trim();
  return out.length > focusMax ? out.substring(0, focusMax) : out;
}

/// 其余场景当背景：整理好的笔记优先；放得下再带逐字稿。
String backgroundBlock(List<Scene> scenes, int max) {
  if (scenes.isEmpty || max <= 0) return '';
  final ctx = [
    for (final s in scenes)
      {
        'id': s.id,
        'time': '${s.d['start']}–${s.d['end'].toString().substring(11, 16)}',
        'category': s.category,
        'title': s.title,
        'event': s.event,
        'place': s.place,
        'people': s.people,
        if (s.subject.isNotEmpty) 'subject': s.subject,
        'note': s.body.isNotEmpty ? s.body : legacyBody(s),
        'actions': s.actions,
        'reminders': s.reminders,
      },
  ];
  var json = jsonEncode(ctx);
  if (json.length < max * 2 ~/ 3) {
    final full = jsonEncode([
      for (final (i, s) in scenes.indexed) {...ctx[i], 'text': s.text},
    ]);
    if (full.length <= max) json = full;
  }
  return json.length > max ? json.substring(0, max) : json;
}

/// 拼 messages：system（提示词 + 资料）→ 前面几轮 → 这次的问题。
/// 资料：正在看的那段放最前、不截断；其余场景按剩下的额度放；[all] 是所有日子的场景（新的在前），只给目录，用来帮我找记录。
/// 历史太长只丢最早的轮次。
List<Map<String, String>> buildAskMessages({
  required List<Scene> scenes,
  Scene? focus,
  List<Scene> all = const [],
  int catalogMax = 30000,
  List<Turn> history = const [],
  required String question,
  int materialMax = 70000,
  int focusMax = 40000,
  int backgroundMin = 10000,
  int historyMax = 24000,
}) {
  final parts = <String>[];
  if (focus != null) parts.add(focusBlock(focus, focusMax: focusMax));
  final rest = [
    for (final s in scenes)
      if (focus == null || s.id != focus.id || s.stem != focus.stem) s,
  ];
  final used = parts.fold<int>(0, (a, p) => a + p.length);
  final bg = backgroundBlock(rest, (materialMax - used).clamp(backgroundMin, materialMax));
  if (bg.isNotEmpty) parts.add('## ${focus == null ? '我的录音记录' : '其余录音记录（背景）'}（JSON）\n$bg');
  if (parts.isEmpty) parts.add('## 我的录音记录\n（这里还没有记录）');
  final cat = catalogBlock(all, max: catalogMax);
  if (cat.isNotEmpty) parts.add('## 全部记录目录（所有日子，新的在前；每行：id | 日期 钟点 | 类别 | 标题 | 事件 | 人物 | 地点）\n$cat');

  final kept = <Turn>[];
  var size = 0;
  for (final t in history.reversed) {
    size += t.q.length + t.a.length;
    if (size > historyMax) break;
    kept.insert(0, t);
  }
  return [
    {'role': 'system', 'content': '$chatPrompt\n\n${parts.join('\n\n')}'},
    for (final t in kept) ...[
      {'role': 'user', 'content': t.q},
      {'role': 'assistant', 'content': t.a},
    ],
    {'role': 'user', 'content': question},
  ];
}
