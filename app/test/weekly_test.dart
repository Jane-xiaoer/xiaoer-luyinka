// 每周回顾（周的划分、数字、资料、写文件）+ 观点按主题（写文件）。模型用假的。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/ideas.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/weekly.dart';

Scene sc(String id, String start, String end, String cat, {String body = '', List actions = const []}) => Scene({
      'id': id, 'start': start, 'end': end, 'category': cat, 'title': '标题$id', 'event': '事件$id', 'people': ['王总'],
      'actions': actions, 'reminders': [], 'body': body,
      'text': [['10:00:00', '逐字稿原文不该给模型$id']],
    }, 'rec');

void main() {
  group('周的划分', () {
    test('周一到周日，ISO 周数', () {
      final w = Week.ofDay('2026-10-18'); // 周日
      expect(w.monday, DateTime.utc(2026, 10, 12));
      expect(w.sunday, DateTime.utc(2026, 10, 18));
      expect(w.key, '2026-W42');
      expect(w.fileName, '2026-W42 (2026-10-12–2026-10-18).md');
      expect(w.label, '10/12–10/18');
      expect(Week.ofDay('2026-10-12').key, '2026-W42');
      expect(Week.ofDay('2026-10-19').key, '2026-W43');
    });

    test('跨月、跨年', () {
      final m = Week.ofDay('2026-11-01');
      expect(m.label, '10/26–11/1');
      expect(m.contains('2026-10-26'), isTrue);
      expect(m.contains('2026-11-02'), isFalse);
      // 2025-12-31 是周三：这周的周四是 2026-01-01，算 2026 年第 1 周
      final a = Week.ofDay('2025-12-31');
      expect(a.key, '2026-W01');
      expect(a.fileName, '2026-W01 (2025-12-29–2026-01-04).md');
      // 2027-01-01 是周五：这周的周四是 2026-12-31，算 2026 年第 53 周
      final b = Week.ofDay('2027-01-01');
      expect(b.key, '2026-W53');
      expect(b.label, '12/28–1/3');
      expect(Week.ofDay('2027-01-04').key, '2027-W01');
    });

    test('有录音的周，新的在前；过完没过完', () {
      final l = weeksOf(['2026-10-20', '2026-10-18', '2026-10-17', '2025-12-31']);
      expect([for (final w in l) w.key], ['2026-W43', '2026-W42', '2026-W01']);
      final w = Week.ofDay('2026-10-18');
      expect(w.isOver(DateTime(2026, 10, 18, 23, 59)), isFalse);
      expect(w.isOver(DateTime(2026, 10, 19, 0, 1)), isTrue);
    });
  });

  group('数字和资料', () {
    final scenes = [
      sc('a', '2026-10-17T09:00:00', '2026-10-17T10:30:00', '开会', body: '## 要点\n- 定了价格', actions: [{'text': '发报价', 'who': '我'}, {'text': '已办的', 'done': true}]),
      sc('b', '2026-10-17T14:00:00', '2026-10-17T14:45:00', '商务洽谈', body: '## 要点\n- 对方要样品'),
      sc('c', '2026-10-18T07:40:00', '2026-10-18T08:00:00', '开会'),
      sc('x', '2026-10-20T07:40:00', '2026-10-20T08:00:00', '开会'), // 下一周的
    ];

    test('这周的段、统计（App 算，不让模型数）', () {
      final w = Week.ofDay('2026-10-18');
      final l = scenesIn(w, scenes);
      expect([for (final s in l) s.id], ['a', 'b', 'c']);
      final st = WeekStats.of(l);
      expect(st.scenes, 3);
      expect(st.days, 2);
      expect(st.meetings, 2);
      expect(st.deals, 1);
      expect(st.total, const Duration(hours: 2, minutes: 35));
      expect(st.byCat, {'开会': 2, '商务洽谈': 1});
    });

    test('资料：带数字、笔记、没完成的待办；不带逐字稿、不带打过勾的', () {
      final w = Week.ofDay('2026-10-18');
      final m = weekMaterial(w, scenesIn(w, scenes));
      expect(m, contains('一共录了：2 小时 35 分'));
      expect(m, contains('一共 3 段：开会 2 次，商务洽谈 1 次'));
      expect(m, contains('有录音的天数：2 天'));
      expect(m, contains('### 10/17 周六 09:00–10:30 · 开会 · 标题a'));
      expect(m, contains('- 定了价格'));
      expect(m, contains('[10/17 09:00 · 标题a] 发报价（谁去做：我）'));
      expect(m, isNot(contains('已办的')));
      expect(m, isNot(contains('逐字稿原文')));
      expect(m, isNot(contains('标题x')));
    });

    test('笔记太长时每段截短，总长不超过上限', () {
      final long = [for (var i = 0; i < 10; i++) sc('$i', '2026-10-1${i % 7 + 2}T09:00:00', '2026-10-1${i % 7 + 2}T10:00:00', '开会', body: '长' * 20000)];
      final w = Week.ofDay('2026-10-14');
      final m = weekMaterial(w, scenesIn(w, long));
      expect(m.length, lessThanOrEqualTo(weekMaterialMax));
      expect(m, contains('…（后面略）'));
      expect('### '.allMatches(m).length, 10, reason: '每段都还在');
    });
  });

  group('写文件', () {
    late Directory tmp;
    late Library lib;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('weekly');
      lib = Library(Directory('${tmp.path}/资料'));
      await lib.ensure();
    });
    tearDown(() => tmp.delete(recursive: true));

    test('ensure 建 每周/；生成回顾存成 每周/<年>-W<周> (<周一>–<周日>).md，重新生成覆盖', () async {
      expect(Directory('${lib.path}/每周').existsSync(), isTrue);
      final w = Week.ofDay('2026-10-18');
      final scenes = [sc('a', '2026-10-17T09:00:00', '2026-10-17T10:30:00', '开会', body: '## 要点\n- 定了价格')];
      expect(weekFile(lib, w), isNull);
      String? sys, user;
      final f = await generateWeekly(lib, w, scenes, (s, u) async {
        sys = s;
        user = u;
        return '```markdown\n## 这周概览\n开了 1 次会。\n```';
      }, now: DateTime(2026, 10, 19, 8, 30));
      expect(f.path, '${lib.path}/每周/2026-W42 (2026-10-12–2026-10-18).md');
      expect(sys, contains('## 下周要盯的'));
      expect(user, contains('一共 1 段：开会 1 次'));
      expect(f.readAsStringSync(),
          '# 每周回顾 · 2026-W42（10/12–10/18）\n\n> 生成时间：2026-10-19 08:30 · 资料：这周 1 段录音整理好的笔记\n\n## 这周概览\n开了 1 次会。\n');
      expect(weekFile(lib, w)!.path, f.path);

      await generateWeekly(lib, w, scenes, (s, u) async => '## 这周概览\n第二版', now: DateTime(2026, 10, 20));
      expect(lib.weeksDir.listSync().length, 1);
      expect(f.readAsStringSync(), contains('第二版'));
    });

    test('文件名被改过也认（只看开头的周号）', () {
      File('${lib.weeksDir.path}/2026-W42 我改过的名字.md').writeAsStringSync('x');
      expect(weekFile(lib, Week.ofDay('2026-10-18'))!.path, endsWith('2026-W42 我改过的名字.md'));
      expect(weekFile(lib, Week.ofDay('2026-10-20')), isNull);
    });

    test('这周没有录音 / 模型空回：不写文件，抛错', () async {
      final w = Week.ofDay('2026-10-18');
      await expectLater(generateWeekly(lib, w, [], (s, u) async => 'x'), throwsStateError);
      await expectLater(generateWeekly(lib, w, [sc('a', '2026-10-17T09:00:00', '2026-10-17T10:00:00', '开会')], (s, u) async => '  '),
          throwsStateError);
      expect(weekFile(lib, w), isNull);
    });

    test('观点按主题：写进 个人感悟/观点·按主题.md，开头写生成时间，覆盖旧的', () async {
      await expectLater(generateIdeasTopics(lib, (s, u) async => 'x'), throwsStateError, reason: '观点库还没有');
      lib.ideasFile
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('# 观点库\n\n<!-- a -->\n## 2026-10-18 07:40 · 硬件\n\n### 感悟了什么\n- 一个人加 AI 能做硬件\n<!-- /a -->\n');
      String? user;
      final f = await generateIdeasTopics(lib, (s, u) async {
        user = u;
        return '## AI 与个人\n### 核心观点\n- 一个人加 AI 能做硬件（10/18）';
      }, now: DateTime(2026, 10, 19, 9, 5));
      expect(f.path, '${lib.path}/个人感悟/观点·按主题.md');
      expect(user, contains('一个人加 AI 能做硬件'));
      final md = f.readAsStringSync();
      expect(md, startsWith('# 观点 · 按主题\n\n> 生成时间：2026-10-19 09:05 · 资料：个人感悟/观点库.md（全文 '));
      expect(md, endsWith('- 一个人加 AI 能做硬件（10/18）\n'));
      await generateIdeasTopics(lib, (s, u) async => '## 新主题', now: DateTime(2026, 10, 20));
      expect(f.readAsStringSync(), contains('## 新主题'));
      expect(f.readAsStringSync(), isNot(contains('AI 与个人')));
    });

    test('观点库太长只给最近 6 万字，从一块的开头切', () {
      final raw = '# 观点库\n${[for (var i = 0; i < 100; i++) '<!-- $i -->\n## 2026-10-18 · 第$i块\n${'字' * 1000}\n<!-- /$i -->'].join('\n')}';
      final m = ideasMaterial(raw);
      expect(m.length, lessThanOrEqualTo(ideasMax));
      expect(m, startsWith('<!-- '));
      expect(m, endsWith('<!-- /99 -->'));
      expect(ideasMaterial('短的'), '短的');
    });
  });
}
