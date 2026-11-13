// 笔记的底子：每行身份跟着行走、笔记待办、复制 / md / 喂模型、待办里打勾 / 纠正改回笔记、带上的旧待办。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/live.dart';
import 'package:luyinka/sync.dart';
import 'package:luyinka/note_doc.dart';
import 'package:luyinka/note_store.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/todos.dart';

void main() {
  group('身份跟着行走', () {
    test('改字不换 id、不改时间；新行记现在', () {
      var m = alignMeta('', [LineMeta('a')], '☐ 发报价', at: 10);
      final id = m[0].id;
      m = alignMeta('☐ 发报价', m, '☐ 发报价给王总', at: 50);
      expect(m.single.id, id);
      m = alignMeta('☐ 发报价给王总', m, '☐ 发报价给王总\n☐ 约时间', at: 60);
      expect(m[0].id, id);
      expect(m[1].at, 60);
    });
    test('中间回车断成两行：前半截还是原来那行', () {
      final m0 = [LineMeta('x', at: 5)];
      final m = alignMeta('☐ 发报价给王总', m0, '☐ 发报价\n☐ 给王总', at: 9);
      expect(m[0].id, 'x');
      expect(m[1].at, 9);
    });
    test('挪行：身份跟着文字走', () {
      final m0 = [LineMeta('a'), LineMeta('b'), LineMeta('c')];
      final m = alignMeta('甲\n乙\n丙', m0, '甲\n丙\n乙');
      expect([for (final x in m) x.id], ['a', 'c', 'b']);
    });
    test('顺一下：没改的行留身份，改写的算 ai、没时间', () {
      final m0 = [LineMeta('a', at: 3), LineMeta('b', at: 4, src: 'carry', ref: 'r')];
      final m = alignMeta('王总说华东\n☐ 旧事', m0, '渠道\n1. 先做华东\n\n☐ 旧事', src: 'ai', at: null);
      expect(m.last.id, 'b');
      expect(m.last.ref, 'r');
      expect(m.first.src, 'ai');
      expect(m.first.at, isNull);
    });
    test('旧数据没有身份：补齐算 old', () {
      expect(metaOf('a\nb', null).map((m) => m.src), ['old', 'old']);
    });
  });

  test('复制：「上次没做完」小标题就算身份对不上也不带（芯 +46）', () {
    final m = [LineMeta('1'), LineMeta('2'), LineMeta('3'), LineMeta('4'), LineMeta('5', src: 'carry')];
    expect(notesForCopy('甲\n\n\n## 上次没做完\n☐ 旧事', m), '甲');
  });

  test('复制给微信：去掉 # ** ==，不带「带上没做完的」', () {
    final m = [LineMeta('1'), LineMeta('2'), LineMeta('3', src: 'carry'), LineMeta('4', src: 'carry')];
    expect(notesForCopy('# 脚本\n**旁白**别太==硬==\n## 上次没做完\n☐ 旧事', m), '脚本\n旁白别太硬');
  });

  test('md：☐ ☑ · 变成 Markdown 列表', () {
    expect(notesForMd('☐ 甲\n    ☑ 乙\n· 丙'), '- [ ] 甲\n    - [x] 乙\n- 丙');
  });

  test('喂模型：只要时间落在这段里的行', () {
    final m = [LineMeta('1', at: 10), LineMeta('2', at: 100), LineMeta('3')];
    expect(notesForModel('甲\n乙\n丙', m, from: 0, to: 60), '甲');
    expect(notesForModel('甲\n乙\n丙', m), '甲\n乙\n丙');
  });

  test('标题：第一行有字的', () {
    expect(firstLineTitle('\n# **青禾**脚本\n☐ 甲', 'x'), '青禾脚本');
    expect(firstLineTitle('  ', '现场会议笔记'), '现场会议笔记');
  });

  group('和 Store 接上', () {
    late Directory tmp;
    late Store store;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('notedoc');
      store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
      await store.lib.ensure();
      await store.lib.peopleFile.writeAsString('# 人员名单\n\n- 林夏（林下）｜同事｜||\n');
    });
    tearDown(() async => tmp.delete(recursive: true));

    Map<String, dynamic> scene(String id, double offset, {List actions = const [], String cat = '开会'}) => {
          'id': id, 'recording': 'live20261113-150000', 'offset': offset,
          'start': '2026-11-13T15:${(offset ~/ 60).toString().padLeft(2, '0')}:00', 'end': '2026-11-13T15:59:00',
          'category': cat, 'title': '段$id', 'event': '', 'place': '', 'people': [], 'subject': '',
          'reminders': [], 'actions': actions, 'text': [], 'body': '',
        };

    Future<void> put(String notes, List<LineMeta> meta, List scenes) async {
      final res = {'start': '2026-11-13T15:00:00', 'lines': [], 'title': '青禾', 'notes': notes,
        'notes_meta': [for (final m in meta) m.toJson()], 'scenes': scenes};
      await store.syncNoteTodos(res);
      await store.putResult('live20261113-150000', res);
    }

    test('按时间进段；模型拆的同一件并掉（项目带过来）、像但不是同一件的不并', () async {
      await put('☐ 联系李总\n☐ 周五前改完旁白', [LineMeta('a', at: 700), LineMeta('b', at: 10)], [
        scene('s1', 0, actions: [
          {'text': '周五前改完旁白', 'who': '我', 'project': '青禾', 't': '15:01'},
        ]),
        scene('s2', 600, actions: [
          {'text': '联系李航', 'who': '我'},
        ]),
      ]);
      final s1 = store.scenes.firstWhere((s) => s.id == 's1'), s2 = store.scenes.firstWhere((s) => s.id == 's2');
      expect([for (final a in s1.actions) '${a['text']}|${a['from']}|${a['project']}'], ['周五前改完旁白|note|青禾']);
      expect([for (final a in s2.actions) a['text']], ['联系李航', '联系李总']);
    });

    test('待办里打勾 → 笔记那行变 ☑；纠正「是林夏的」→ 笔记写成「林夏：」；「不是任务」→ 变成要点', () async {
      await put('☐ 发报价\n☐ 要素材包\n☐ 订会议室', [LineMeta('a'), LineMeta('b', src: 'clip'), LineMeta('c')], [scene('s1', 0)]);
      Todo todo(String text) => todosOf(store.scenes).firstWhere((t) => t.text == text);
      await store.setTodoDone(todo('发报价'), true);
      expect(store.readResult('live20261113-150000')!['notes'], startsWith('☑ 发报价'));
      expect(todo('发报价').done, isTrue);

      expect(rawOf(todo('要素材包'))['confirmed'], isNull); // 挪来的：待确认
      await store.correctTodo(todo('要素材包'), 'owner', who: '林夏');
      final res = store.readResult('live20261113-150000')!;
      expect(res['notes'], contains('☐ 林夏：要素材包'));
      expect(rawOf(todo('要素材包'))['who'], '林夏');
      expect(rawOf(todo('要素材包'))['confirmed'], isTrue);

      await store.correctTodo(todo('订会议室'), 'not_task');
      expect(store.readResult('live20261113-150000')!['notes'], endsWith('· 订会议室'));
      expect(todosOf(store.scenes).map((t) => t.text), isNot(contains('订会议室')));
      expect(File('${store.lib.liveDir.path}/2026-11-13 1500 青禾.md').readAsStringSync(), contains('- [x] 发报价'));
    });

    test('带上的旧待办：不新建，会上勾了旧的跟着勾', () async {
      // 上次那场
      await store.putResult('live20261110-100000', {
        'start': '2026-11-10T10:00:00', 'lines': [],
        'scenes': [
          {...scene('old1', 0, actions: [{'text': '问林夏要素材包', 'who': '我', 'confirmed': true}]), 'recording': 'live20261110-100000'},
        ],
      });
      await put('## 上次没做完\n☑ 问林夏要素材包', [LineMeta('h', src: 'carry'), LineMeta('c', src: 'carry', ref: 'old1\t问林夏要素材包')],
          [scene('s1', 0)]);
      expect(store.scenes.firstWhere((s) => s.id == 's1').actions, isEmpty);
      expect(todosOf(store.scenes).firstWhere((t) => t.text == '问林夏要素材包').done, isTrue);
    });

    test('重新整理两次：条数不变、勾还在', () async {
      await put('☑ 发报价\n☐ 约时间', [LineMeta('a'), LineMeta('b')], [scene('s1', 0)]);
      for (var i = 0; i < 2; i++) {
        final res = jsonDecode(jsonEncode(store.readResult('live20261113-150000')!)) as Map<String, dynamic>;
        res['scenes'] = [scene('s1', 0)]; // 模型重切出来的新段（没有笔记待办）
        await store.syncNoteTodos(res);
        await store.putResult('live20261113-150000', res);
      }
      expect([for (final t in todosOf(store.scenes)) '${t.text}|${t.done}'], ['发报价|true', '约时间|false']);
    });

    test('待确认改成名单外的人：笔记写「董老师：」，重算后还是董老师的（芯 +46 P2）', () async {
      await put('☐ 要素材包', [LineMeta('a', src: 'clip')], [scene('s1', 0)]);
      await store.correctTodo(todosOf(store.scenes).single, 'owner', who: '董老师');
      final t = todosOf(store.scenes).single;
      expect('${t.text}|${t.who}', '要素材包|董老师');
      expect(store.readResult('live20261113-150000')!['notes'], '☐ 董老师：要素材包');
      // 再改回是我的
      await store.correctTodo(t, 'mine');
      expect('${todosOf(store.scenes).single.who}|${store.readResult('live20261113-150000')!['notes']}', '我|☐ 要素材包');
    });

    test('带上的旧待办在待办里勾了，再改这场笔记也不会被取消（芯 +46 P1）', () async {
      await store.putResult('live20261110-100000', {
        'start': '2026-11-10T10:00:00', 'lines': [],
        'scenes': [
          {...scene('old1', 0, actions: [{'text': '问林夏要素材包', 'who': '我', 'confirmed': true}]), 'recording': 'live20261110-100000'},
        ],
      });
      final meta = [LineMeta('h', src: 'carry'), LineMeta('c', src: 'carry', ref: 'old1\t问林夏要素材包')];
      await put('## 上次没做完\n☐ 问林夏要素材包', meta, [scene('s1', 0)]);
      Todo old() => todosOf(store.scenes).firstWhere((t) => t.scene.id == 'old1');
      expect(old().done, isFalse);
      await store.setTodoDone(old(), true); // 在待办里勾旧的
      final res = store.readResult('live20261113-150000')!;
      final text = '${res['notes']}\n· 补一句';
      await store.putNotes('live20261113-150000', text, alignMeta('${res['notes']}', metaOf('${res['notes']}', res['notes_meta']), text));
      expect(old().done, isTrue);
      expect(store.readResult('live20261113-150000')!['notes'], contains('☑ 问林夏要素材包')); // 笔记这行跟上
      // 反过来：笔记里取消 → 旧的跟着取消
      final r2 = store.readResult('live20261113-150000')!;
      final t2 = '${r2['notes']}'.replaceFirst('☑ 问林夏', '☐ 问林夏');
      await store.putNotes('live20261113-150000', t2, metaOf('${r2['notes']}', r2['notes_meta']));
      expect(old().done, isFalse);
    });

    test('真重新整理（Syncer）：笔记待办的项目、勾、条数都不变；旧笔记补的身份写回、id 稳（芯 +46 P3/P4）', () async {
      await Directory('${tmp.path}/app/raw').create(recursive: true);
      const stem = 'live20261113-150000';
      await store.putResult(stem, {
        'start': '2026-11-13T15:00:00', 'lines': [for (var i = 0; i < 5; i++) ['15:0$i:00', '我们说第$i句']],
        'notes': '☐ 发报价\n☐ 约时间', // 旧数据：没有 notes_meta
        'scenes': [scene('s1', 0)],
      });
      final res0 = store.readResult(stem)!;
      await store.syncNoteTodos(res0);
      await store.putResult(stem, res0);
      final ids = [for (final m in store.readResult(stem)!['notes_meta'] as List) m['id']];
      Todo t(String x) => todosOf(store.scenes).firstWhere((y) => y.text == x);
      await store.correctTodo(t('发报价'), 'project', project: '青禾');
      await store.setTodoDone(t('约时间'), true);
      final sy = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai',
          chat: (system, user) async => system.contains('"scenes"')
              ? '{"scenes":[{"start":"15:00:00","end":"15:04:00","category":"开会","title":"新切的","event":""}]}'
              : '## 纪要');
      for (var i = 0; i < 2; i++) {
        await sy.reanalyze(stem);
      }
      expect(store.scenes.single.title, '新切的');
      expect([for (final x in todosOf(store.scenes)) '${x.text}|${x.done}|${rawOf(x)['project']}'], ['发报价|false|青禾', '约时间|true|null']);
      expect([for (final m in store.readResult(stem)!['notes_meta'] as List) m['id']], ids);
      await store.save();
    });
  });

  test('开会中途关掉 App 再打开：笔记和每行身份都在', () async {
    final tmp = await Directory.systemTemp.createTemp('notedraft');
    addTearDown(() => tmp.delete(recursive: true));
    final store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await store.lib.ensure();
    final dir = Directory('${tmp.path}/app');
    final a = LiveSession(store, dir, () async {}, shareMemory: false)
      ..stem = 'live20261113-150000'
      ..started = DateTime(2026, 11, 13, 15)
      ..state = LiveState.paused;
    a.setNotes('☐ 发报价', at: 30);
    a.setNotes('☐ 发报价\n## 上次没做完\n☐ 旧事', src: 'carry', refs: {'☐ 旧事': 'x\t旧事'});
    await Future<void>.delayed(const Duration(milliseconds: 800)); // 草稿 600ms 后落盘
    final b = LiveSession(store, dir, () async {}, shareMemory: false);
    expect(b.notes, a.notes);
    expect([for (final m in b.notesMeta) '${m.src}|${m.at}|${m.ref}'], ['me|30.0|null', 'carry|${b.notesMeta[1].at}|null', 'carry|${b.notesMeta[2].at}|x\t旧事']);
  });
}
