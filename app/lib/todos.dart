// 总待办：所有场景的 actions（要做的事）+ reminders（到点提醒），能打勾、能放进 Mac 的「提醒事项」。
// 打勾存在那一条里（done: true），写回 .xiaoer/<录音>.json，每日/<日>.md 里跟着变成 - [x]。
import 'dart:io';

import 'analyze.dart';
import 'store.dart';

class Todo {
  final Scene scene;
  final String kind; // actions / reminders
  final int index; // 在那一段 [kind] 列表里的位置
  final String text, who, when;
  final bool done;
  const Todo(this.scene, this.kind, this.index, {required this.text, this.who = '', this.when = '', this.done = false});

  /// 有说什么时候的（提醒，按原话显示）；其余算「没时间的」。
  bool get timed => when.isNotEmpty;

  /// 来源：10/18 14:00 · 段标题
  String get source => '${scene.start.month}/${scene.start.day} ${_p2(scene.start.hour)}:${_p2(scene.start.minute)} · ${scene.title}';
}

/// 所有段的待办，新的段在前；同一段里先提醒、后行动。
List<Todo> todosOf(List<Scene> scenes) {
  final sorted = [...scenes]..sort((a, b) => b.start.compareTo(a.start));
  return [
    for (final s in sorted)
      for (final kind in const ['reminders', 'actions'])
        for (final (i, m) in s.pairs(kind).indexed)
          if ('${m['text'] ?? ''}'.trim().isNotEmpty)
            Todo(s, kind, i,
                text: '${m['text']}'.trim(),
                who: '${m['who'] ?? ''}'.trim(),
                when: '${m['when'] ?? ''}'.trim(),
                done: m['done'] == true),
  ];
}

/// 重新整理一条录音后：旧条目里打过勾的，按字面相似（跟 dedupeActions 同一个判断）把勾带到新条目上。
void carryDone(List oldScenes, List newScenes) {
  final doneTexts = [
    for (final s in oldScenes)
      if (s is Map)
        for (final kind in const ['actions', 'reminders'])
          for (final m in (s[kind] as List? ?? const []))
            if (m is Map && m['done'] == true) '${m['text'] ?? ''}',
  ];
  if (doneTexts.isEmpty) return;
  for (final s in newScenes) {
    if (s is! Map<String, dynamic>) continue;
    for (final kind in const ['actions', 'reminders']) {
      final l = s[kind];
      if (l is! List) continue;
      s[kind] = [
        for (final m in l)
          if (m is Map && doneTexts.any((t) => sameTodo(t, '${m['text'] ?? ''}')))
            Map<String, dynamic>.from(m)..['done'] = true
          else
            m,
      ];
    }
  }
}

// ───────── 「什么时候」的原话 → 具体日期 ─────────

const _cnDigits = {'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};

/// 阿拉伯数字或「三」「十二」「二十五」这样的中文数字。
int? _num(String s) {
  final d = int.tryParse(s);
  if (d != null) return d;
  if (s.isEmpty) return null;
  if (!s.contains('十')) return s.length == 1 ? _cnDigits[s] : null;
  final p = s.split('十');
  if (p.length != 2) return null;
  final tens = p[0].isEmpty ? 1 : _cnDigits[p[0]];
  final ones = p[1].isEmpty ? 0 : _cnDigits[p[1]];
  return tens == null || ones == null ? null : tens * 10 + ones;
}

const _n = r'(\d{1,2}|[一二两三四五六七八九十]{1,3})';
const _weekdays = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7, '末': 6};

/// 待办里「什么时候」的原话 → 具体时刻；说不出哪一天的（「尽快」「月底」「下周」）返回 null。
/// 相对的说法（明天、下周三）按这段录音那天 [base] 算。说了日子没说钟点的，算早上 9 点。
DateTime? parseWhen(String when, DateTime base) {
  final w = when.trim();
  if (w.isEmpty) return null;
  final b = DateTime(base.year, base.month, base.day);
  DateTime? day;
  final md = RegExp('(?:(\\d{4})年)?$_n月$_n[日号]').firstMatch(w) ??
      RegExp(r'(?:(\d{4})[-/.])?(\d{1,2})[-/.](\d{1,2})(?![\d.:：])').firstMatch(w);
  if (md != null) {
    final mo = _num(md[2]!), d = _num(md[3]!);
    if (mo != null && d != null && mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
      var y = md[1] != null ? int.parse(md[1]!) : b.year;
      var x = DateTime(y, mo, d);
      if (x.month != mo) return null; // 2 月 30 日之类
      // 没写年份、算出来比录音那天早半年以上：说的是明年（12 月底说「1 月 5 号」）
      if (md[1] == null && b.difference(x).inDays > 180) x = DateTime(++y, mo, d);
      day = x;
    }
  } else if (w.contains('大后天')) {
    day = b.add(const Duration(days: 3));
  } else if (w.contains('后天')) {
    day = b.add(const Duration(days: 2));
  } else if (RegExp(r'明[天日早晚儿]').hasMatch(w)) {
    day = b.add(const Duration(days: 1));
  } else if (RegExp(r'今[天日早晚儿]').hasMatch(w)) {
    day = b;
  } else {
    final wk = RegExp(r'(下下|下个?|这个?|本)?(?:周|星期|礼拜)([一二三四五六日天末])').firstMatch(w);
    if (wk != null) {
      final monday = b.subtract(Duration(days: b.weekday - 1));
      final pre = wk[1] ?? '';
      final shift = pre.startsWith('下下') ? 14 : (pre.startsWith('下') ? 7 : 0);
      var x = monday.add(Duration(days: shift + _weekdays[wk[2]]! - 1));
      // 只说「周五」、这周的周五已经过了：说的是下周五
      if (pre.isEmpty && x.isBefore(b)) x = x.add(const Duration(days: 7));
      day = DateTime(x.year, x.month, x.day);
    }
  }
  if (day == null) return null;
  var hour = 9, minute = 0;
  final t = RegExp('(凌晨|上午|早上|早晨|早|中午|下午|傍晚|晚上|夜里|晚)?$_n[点:：时](半|\\d{1,2})?').firstMatch(w);
  if (t != null) {
    final h = _num(t[2]!);
    if (h != null && h <= 24) {
      hour = h % 24;
      minute = t[3] == '半' ? 30 : (int.tryParse(t[3] ?? '') ?? 0).clamp(0, 59);
      final p = t[1] ?? '';
      if (['下午', '傍晚', '晚上', '夜里', '晚'].contains(p) && hour < 12) hour += 12;
      if (p == '中午' && hour < 6) hour += 12;
    }
  } else if (RegExp(r'下午').hasMatch(w)) {
    hour = 14;
  } else if (RegExp(r'晚').hasMatch(w)) {
    hour = 20;
  }
  return DateTime(day.year, day.month, day.day, hour, minute);
}

// ───────── 放进 Mac 的「提醒事项」 ─────────

/// AppleScript 字符串字面量（带两头的引号）：反斜杠、引号、换行都转义。
String appleString(String s) =>
    '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('\n', '\\n').replaceAll('\t', '\\t')}"';

/// 在「提醒事项」默认列表里建一条的 AppleScript。[due] 有才设提醒日期。
String reminderScript({required String title, String note = '', DateTime? due}) {
  final b = StringBuffer();
  if (due != null) {
    // 先把日设成 1 再改年月日：不然今天是 31 号时改成 2 月会溢出到 3 月
    b
      ..writeln('set d to current date')
      ..writeln('set day of d to 1')
      ..writeln('set year of d to ${due.year}')
      ..writeln('set month of d to ${due.month}')
      ..writeln('set day of d to ${due.day}')
      ..writeln('set time of d to ${due.hour * 3600 + due.minute * 60}');
  }
  final props = [
    'name:${appleString(title)}',
    if (note.isNotEmpty) 'body:${appleString(note)}',
    if (due != null) ...['due date:d', 'remind me date:d'],
  ].join(', ');
  b
    ..writeln('tell application "Reminders"')
    ..writeln('  tell default list')
    ..writeln('    make new reminder with properties {$props}')
    ..writeln('  end tell')
    ..writeln('end tell');
  return b.toString();
}

/// 一条待办 → 提醒事项的脚本（标题 = 待办原文；备注 = 来源 + 什么时候的原话）。
String todoReminderScript(Todo t) => reminderScript(
      title: t.text,
      note: ['来自小耳录音卡：${t.source}', if (t.who.isNotEmpty) '谁去做：${t.who}', if (t.when.isNotEmpty) '什么时候：${t.when}'].join('\n'),
      due: parseWhen(t.when, t.scene.start),
    );

/// 真的建一条（只在 Mac 上）。成功返回 null，失败返回给人看的原因。
Future<String?> addToReminders(Todo t, {Future<ProcessResult> Function(String script)? run}) async {
  try {
    final r = await (run ?? (s) => Process.run('osascript', ['-e', s]))(todoReminderScript(t));
    if (r.exitCode == 0) return null;
    final err = '${r.stderr}'.trim();
    if (err.contains('-1743') || err.contains('Not authorized') || err.contains('不允许')) {
      return '没权限：到「系统设置 → 隐私与安全性 → 自动化」里，允许小耳录音卡控制「提醒事项」';
    }
    return err.isEmpty ? '提醒事项没建成（退出码 ${r.exitCode}）' : '提醒事项没建成：$err';
  } catch (e) {
    return '提醒事项没建成：$e';
  }
}

String _p2(int n) => n.toString().padLeft(2, '0');
