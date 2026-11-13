// 待确认 + 人员名单：在 App 里改一件事 → 写回这一段、记进纠正记录；重新整理时记住；名单读写往返。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/analyze.dart';
import 'package:luyinka/confirm.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/templates.dart';
import 'package:luyinka/todos.dart';

void main() {
  late Directory tmp;
  late Store store;
  final now = DateTime.now();
  String iso(DateTime t) => t.toIso8601String().substring(0, 19);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('confirm');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
    final start = now.subtract(const Duration(days: 1));
    await store.putResult('rec1', {
      'start': iso(start),
      'scenes': [
        {
          'id': 's1', 'start': iso(start), 'end': iso(start.add(const Duration(hours: 1))), 'category': '开会', 'title': '展厅会',
          'event': 'x', 'people': ['练'], 'text': [], 'body': '## 要点\n- x',
          'actions': [
            {'t': '23:02:11', 'text': '做完整样板', 'who': '我', 'speaker': '练', 'said': '还是要做一个完整的样板'},
            {'t': '23:21:04', 'text': '联系李航', 'who': '别人', 'speaker': '', 'said': '我我联系李航的嗯。'},
            {'t': '23:30:00', 'text': '发报价', 'who': '我', 'speaker': '我', 'said': '我把报价发过去'},
          ],
          'reminders': [],
        },
      ],
    });
  });
  tearDown(() async {
    await store.save();
    // 界面测试里存文件是后台在跑，偶尔还没写完：临时目录删不干净不算失败
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Todo todo(String text) => todosOf(store.scenes).firstWhere((t) => t.text == text);
  List<Map<String, dynamic>> fixes() => [
        for (final l in store.lib.fixesFile.readAsLinesSync()) if (l.trim().isNotEmpty) Map<String, dynamic>.from(jsonDecode(l)),
      ];

  test('一开始三件都在待确认里', () {
    expect([for (final t in pendingTodos(store.scenes)) t.text], ['做完整样板', '联系李航', '发报价']);
  });

  test('不是任务：撇掉，待确认和总待办都不见；记进纠正记录', () async {
    final guess = await store.correctTodo(todo('做完整样板'), 'not_task');
    expect(guess, '我');
    expect(todosOf(store.scenes).map((t) => t.text), isNot(contains('做完整样板')));
    expect(pendingTodos(store.scenes).map((t) => t.text), isNot(contains('做完整样板')));
    final f = fixes().single;
    expect(f['rec'], 'rec1');
    expect(f['t'], '23:02:11');
    expect(f['said'], '还是要做一个完整的样板');
    expect(f['guess'], {'who': '我'});
    expect(f['fix'], {'kind': 'not_task'});
    // 写回了索引：重新读也是撇掉的
    final raw = (store.readResult('rec1')!['scenes'] as List).first['actions'][0];
    expect(raw['dismissed'], true);
    expect(raw['confirmed'], true);
  });

  test('是别人的：归属改了、照样在总待办里（等他）、离开待确认', () async {
    await store.correctTodo(todo('联系李航'), 'owner', who: '董老师');
    final t = todo('联系李航');
    expect(t.who, '董老师');
    expect(pendingTodos(store.scenes).map((t) => t.text), isNot(contains('联系李航')));
    expect(fixes().single['fix'], {'kind': 'owner', 'who': '董老师'});
  });

  test('是我的 → 离开待确认；换项目 → 记项目但还留在待确认', () async {
    await store.correctTodo(todo('发报价'), 'mine');
    await store.correctTodo(todo('联系李航'), 'project', project: '青禾防灾片');
    final pending = [for (final t in pendingTodos(store.scenes)) t.text];
    expect(pending, ['做完整样板', '联系李航']);
    expect(rawOf(todo('联系李航'))['project'], '青禾防灾片');
    expect([for (final f in fixes()) f['fix']['kind']], ['owner', 'project']);
  });

  test('重新整理同一条录音：App 里改过的都记住（归属、撇掉、项目）', () async {
    await store.correctTodo(todo('做完整样板'), 'not_task');
    await store.correctTodo(todo('联系李航'), 'owner', who: '董老师');
    await store.correctTodo(todo('联系李航'), 'project', project: '青禾防灾片');
    // 模型重新拆，说法变了、归属又猜回去
    final again = applyFixes([
      {'t': '23:02:11', 'text': '根据案例做完整的样板', 'who': '我'},
      {'t': '23:21:04', 'text': '联系李航', 'who': '我'},
      {'t': '23:30:00', 'text': '发报价', 'who': '我'},
    ], store.lib.fixesFor('rec1'));
    expect([for (final a in again) a['dismissed'] == true], [true, false, false]);
    expect(again[1]['who'], '董老师');
    expect(again[1]['project'], '青禾防灾片');
    expect(again[2].containsKey('fixed'), false);
  });

  test('人员名单：读、改、存，标题和说明原样留着', () async {
    store.lib.peopleFile.writeAsStringSync('# 人员名单\n\n> 说明行\n\n- 练（练、练总）｜甲方｜舞蹈馆与城市馆｜\n- 阿星（阿星）｜｜｜\n');
    final ps = store.lib.peopleEntries();
    expect([for (final p in ps) p.name], ['练', '阿星']);
    expect(ps.first.aliases, ['练', '练总']);
    expect(ps.first.identity, '甲方');
    ps[1].aliases = ['阿星', '阿西'];
    ps.add(PersonEntry('董老师', identity: '合作方', project: '青禾防灾片', note: '一起做防灾视频'));
    await store.lib.savePeople(ps);
    final txt = store.lib.peopleFile.readAsStringSync();
    expect(txt, startsWith('# 人员名单\n\n> 说明行'));
    expect(txt, contains('- 阿星（阿星、阿西）｜｜｜'));
    expect(txt, contains('- 董老师（董老师）｜合作方｜青禾防灾片｜一起做防灾视频'));
    expect(store.lib.people(), contains('阿西')); // 拆事提示词里读得到
  });

  test('人员名单：没有文件时存出来带说明', () async {
    await store.lib.savePeople([PersonEntry('练', identity: '甲方')]);
    final txt = store.lib.peopleFile.readAsStringSync();
    expect(txt, contains('> 录音里常出现的人'));
    expect(txt, contains('- 练（练）｜甲方｜｜'));
  });

  testWidgets('待确认页：看得到原话和四个按钮，点「不是任务」就从列表里消失', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConfirmView(store: store))));
    await tester.pump();
    expect(find2('还有 3 件'), findsOneWidget);
    expect(find2('“还是要做一个完整的样板”', rich: true), findsOneWidget);
    expect(find2('是我的'), findsNWidgets(3));
    expect(find2('是谁的 ▾'), findsNWidgets(3));
    expect(find2('不是任务'), findsNWidgets(3));
    expect(find2('换项目 ▾'), findsNWidgets(3));
    await tester.runAsync(() async {
      await tester.tap(find2('不是任务').first);
      for (var i = 0; i < 20 && pendingTodos(store.scenes).length == 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pump();
    expect(find2('还有 2 件'), findsOneWidget);
    expect(find2('做完整样板'), findsNothing);
  });

  testWidgets('人员名单页：加一个人、存', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    await tester.binding.setSurfaceSize(const Size(1300, 900));
    store.lib.peopleFile.writeAsStringSync('# 人员名单\n\n- 练（练、练总）｜甲方｜｜\n');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PeopleListView(store: store))));
    await tester.pump();
    expect(find2('1 人'), findsOneWidget);
    await tester.tap(find2('加一个人'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(5), '阿星'); // 第二行的「名字」（每行 5 个输入框：名字、叫法、项目、公司、介绍）
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find2('存'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(store.lib.peopleEntries().map((p) => p.name), ['练', '阿星']);
  });

  test('以前纠正过的（原型里判的）：打开待确认时套到已有录音上，不用重新整理', () async {
    await store.lib.addFix({'rec': 'rec1', 't': '23:02:11', 'text': '制作完整样板', 'fix': {'kind': 'not_mine_task'}});
    await store.lib.addFix({'rec': 'rec1', 't': '23:21:04', 'text': '联系李航', 'fix': {'kind': 'owner', 'who': '董老师'}});
    expect(await store.applyStoredFixes(), 1);
    expect([for (final t in pendingTodos(store.scenes)) t.text], ['发报价']);
    expect(todo('联系李航').who, '董老师');
    expect(todosOf(store.scenes).map((t) => t.text), isNot(contains('做完整样板')));
    expect(await store.applyStoredFixes(), 0); // 再套一次没变化
  });

  testWidgets('旧录音没存原话：从这一段的逐字稿里按钟点找出来显示', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    final start = now.subtract(const Duration(hours: 3));
    await tester.runAsync(() => store.putResult('old1', {
          'start': iso(start),
          'scenes': [
            {
              'id': 'o1', 'start': iso(start), 'end': iso(start.add(const Duration(minutes: 10))), 'category': '自言自语',
              'title': '梳理', 'event': 'x', 'people': [], 'body': '## x\n- y',
              'text': [
                ['00:49:10', '现在来录个音'],
                ['00:49:40', '跟对方要一个资料，然后这边先出一个脚本'],
              ],
              'actions': [
                {'t': '00:49:40', 'text': '先出一个脚本', 'who': ''},
              ],
              'reminders': [],
            },
          ],
        }));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConfirmView(store: store))));
    await tester.pump();
    expect(find2('“跟对方要一个资料，然后这边先出一个脚本”', rich: true), findsOneWidget);
  });

  test('不串段：同一条录音两段，只纠正第一段；提醒的纠正不套到行动上', () async {
    final start = now.subtract(const Duration(hours: 5));
    await store.putResult('two', {
      'start': iso(start),
      'scenes': [
        {
          'id': 'p1', 'start': iso(start), 'end': iso(start.add(const Duration(minutes: 30))), 'category': '开会', 'title': '一',
          'event': 'x', 'people': [], 'text': [], 'body': '## x\n- y',
          'actions': [
            {'t': '22:39:26', 'text': '提供科普文本素材', 'who': '我'},
            {'t': '22:43:22', 'text': '提供案例航拍图', 'who': '我'},
          ],
          'reminders': [
            {'t': '22:44:00', 'text': '周五前发报价', 'when': '周五前'},
          ],
        },
        {
          'id': 'p2', 'start': iso(start.add(const Duration(minutes: 40))), 'end': iso(start.add(const Duration(hours: 1))),
          'category': '开会', 'title': '二', 'event': 'x', 'people': [], 'text': [], 'body': '## x\n- y',
          'actions': [
            {'t': '22:39:50', 'text': '提供航拍图', 'who': '我'}, // 跟第一段的钟点、字面都很近
            {'t': '22:44:10', 'text': '发报价', 'who': '我'},
          ],
          'reminders': [],
        },
      ],
    });
    final p1 = store.scenes.firstWhere((s) => s.id == 'p1');
    Todo of(Scene s, String kind, int i) => todosOf([s]).firstWhere((t) => t.kind == kind && t.index == i);
    await store.correctTodo(of(p1, 'actions', 0), 'not_task');
    await store.correctTodo(of(p1, 'actions', 1), 'not_task');
    await store.correctTodo(of(p1, 'reminders', 0), 'not_task');
    expect([for (final f in store.lib.fixesFor('two')) f['list']], ['actions', 'actions', 'reminders']);
    expect(await store.applyStoredFixes(), 0); // 套一遍：第二段不动
    final p2 = (store.readResult('two')!['scenes'] as List)[1] as Map;
    expect([for (final a in p2['actions']) a['dismissed'] == true], [false, false]);
    // 重新整理（段号还在）：第二段照样不动
    final again = applyFixes([
      {'t': '22:39:50', 'text': '提供航拍图', 'who': '我'},
      {'t': '22:44:10', 'text': '发报价', 'who': '我'},
    ], store.lib.fixesFor('two'), sceneId: 'p2', sceneIds: {'p1', 'p2'});
    expect(again.any((a) => a['dismissed'] == true), false);
    // 段号变了（重新切过场景）：才在整条录音里按内容找
    final recut = applyFixes([
      {'t': '22:43:22', 'text': '提供案例航拍图', 'who': '我'},
    ], store.lib.fixesFor('two'), sceneId: 'new1', sceneIds: {'new1'});
    expect(recut.single['dismissed'], true);
  });

  test('撇掉的不进每日 md、不算件数、按人看也不出现', () async {
    await store.correctTodo(todo('联系李航'), 'not_task');
    final s = store.scenes.firstWhere((s) => s.id == 's1');
    expect(s.actions.map((a) => a['text']), isNot(contains('联系李航')));
    expect(s.todo, 2);
    final md = File('${store.lib.path}/每日/${s.dayKey}.md').readAsStringSync();
    expect(md, isNot(contains('联系李航')));
    expect(md, contains('- [ ] 发报价'));
  });
}


Finder find2(String s, {bool rich = false}) => rich ? find.textContaining(s, findRichText: true) : find.text(s);
