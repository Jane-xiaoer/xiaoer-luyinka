// 笔记和 Store 接上（11-13 方案）：笔记待办进待办、待办里打勾 / 纠正改回笔记、带上的旧待办对回去、会后改笔记。
import 'analyze.dart' show aliasMap;
import 'note_doc.dart';
import 'store.dart';
import 'templates.dart' show noiseCat;
import 'todos.dart';

extension NoteStore on Store {
  /// 笔记里「名字：」认人用：名单上的正名 + 叫法 → 正名（「我」不算别人）。
  Map<String, String> noteAliases() {
    final people = lib.peopleEntries();
    return {
      ...aliasMap(people),
      for (final p in people)
        if (p.name != '我') p.name: p.name,
    };
  }

  /// 笔记待办写进 res 的段里，带上的旧待办两边对勾。返回 (进待办, 进待确认)。不存盘，调用的人 putResult。
  Future<(int, int)> syncNoteTodos(Map<String, dynamic> res) async {
    await _syncCarry(res);
    final (mine, ask, _) = applyNoteTodos(res, noteAliases(), noise: noiseCat);
    return (mine, ask);
  }

  /// 带上的旧待办（ref = 段 id \t 原文）：两边谁变了听谁的（芯 +46 P1）。
  /// 笔记里这行跟上次对过去的不一样 → 是我在笔记里勾的，改旧的那条；
  /// 一样、但旧的那条变了 → 是在待办里勾的，改笔记这行。对完记下这次的状态。
  Future<void> _syncCarry(Map<String, dynamic> res) async {
    var text = '${res['notes'] ?? ''}';
    final meta = metaOf(text, res['notes_meta']);
    final todos = noteTodos(text, meta, noteAliases()).where((t) => t.src == 'carry' && t.ref != null).toList();
    if (todos.isEmpty) return;
    for (final t in todos) {
      final i = t.ref!.indexOf('\t');
      if (i < 0) continue;
      final sceneId = t.ref!.substring(0, i), want = t.ref!.substring(i + 1);
      final old = todosOf(scenes.where((s) => s.id == sceneId).toList()).where((x) => x.text == want).firstOrNull;
      if (old == null) continue;
      final m = meta[t.line];
      if (m.sync == null) {
        // 头一回对：谁打了勾听谁的（会上勾了 → 勾旧的；旧的已经在别处勾了 → 笔记这行跟上）
        if (t.done && !old.done) await setTodoDone(old, true);
        if (!t.done && old.done) text = setLineDone(text, meta, t.id, true);
        m.sync = t.done || old.done;
      } else if (m.sync != t.done) {
        if (old.done != t.done) await setTodoDone(old, t.done);
        m.sync = t.done;
      } else if (old.done != t.done) {
        text = setLineDone(text, meta, t.id, old.done);
        m.sync = old.done;
      }
    }
    res['notes'] = text;
    res['notes_meta'] = [for (final m in meta) m.toJson()];
  }

  /// 会后改了这场会 / 这条随手记的笔记：存回索引、重写 md、重算笔记待办（不重新整理）。
  Future<(int, int)> putNotes(String stem, String text, List<LineMeta> meta) async {
    final res = readResult(stem);
    if (res == null) return (0, 0);
    res['notes'] = text;
    res['notes_meta'] = [for (final m in meta) m.toJson()];
    if (stem.startsWith('memo')) {
      // 随手记：标题跟着第一行，「写到」几点
      final title = firstLineTitle(text, '');
      res['title'] = title;
      final scenes = [for (final s in (res['scenes'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
      if (scenes.isNotEmpty) {
        scenes.first['title'] = title.isEmpty ? '随手记' : title;
        final now = DateTime.now();
        String p(int n) => n.toString().padLeft(2, '0');
        final end = '${now.year}-${p(now.month)}-${p(now.day)}T${p(now.hour)}:${p(now.minute)}:${p(now.second)}';
        // 同一天里才往后挪「到几点」，隔天补记不把这条拖成跨天
        if (end.substring(0, 10) == '${scenes.first['start']}'.substring(0, 10)) scenes.first['end'] = end;
      }
      res['scenes'] = scenes;
    }
    final r = await syncNoteTodos(res);
    await putResult(stem, res);
    await writeNotesFile(stem, res);
    return r;
  }

  /// 笔记的 md：现场会议/… 或 随手记/…
  Future<void> writeNotesFile(String stem, Map<String, dynamic> res) async {
    final start = DateTime.tryParse('${res['start'] ?? ''}'.padRight(19).substring(0, 19).trim());
    if (start == null) return;
    final text = notesForMd('${res['notes'] ?? ''}');
    if (stem.startsWith('memo')) {
      await lib.writeMemo(stem, '${res['title'] ?? ''}', start, text);
    } else {
      await lib.writeLiveNotes(stem, '${res['title'] ?? ''}', start, text);
    }
  }

  /// 这条待办是笔记里来的：改笔记那一行，再重算。[edit] 拿 (笔记, 身份, 行 id) 返回改好的笔记。
  /// 不是笔记里的返回 false。
  Future<bool> editNoteTodo(Todo t, String Function(String text, List<LineMeta> meta, String id) edit,
      {void Function(LineMeta m)? meta}) async {
    final raw = rawOf(t);
    if (raw['from'] != 'note') return false;
    final res = readResult(t.scene.stem);
    if (res == null) return false;
    final text = '${res['notes'] ?? ''}';
    final ms = metaOf(text, res['notes_meta']);
    final id = '${raw['note_id']}';
    final m = ms.where((x) => x.id == id).firstOrNull;
    if (m == null) return false;
    final next = edit(text, ms, id); // 先改字（要认出改之前的「名字：」），再改身份
    meta?.call(m);
    await putNotes(t.scene.stem, next, ms);
    return true;
  }
}
