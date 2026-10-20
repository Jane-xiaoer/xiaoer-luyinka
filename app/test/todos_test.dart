// 总待办：汇总、打勾写回（索引 + 每日/ 的 [x]）、重新整理时带上打过的勾、「什么时候」认日期、提醒事项脚本（只拼字符串，不真跑）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/people.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';
import 'package:luyinka/todos.dart';

Map<String, dynamic> scene(String id, String start, String end, {List actions = const [], List reminders = const [], String title = '标题'}) => {
      'id': id, 'start': start, 'end': end, 'category': '开会', 'title': title, 'event': '事件', 'people': ['王总'],
      'actions': actions, 'reminders': reminders, 'text': [], 'body': '## 要点\n- 内容',
    };

void main() {
  late Directory tmp;
  late Store store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('todos');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
  });
  tearDown(() async {
    await store.save();
    await tmp.delete(recursive: true);
  });

  Future<void> seed() async {
    await store.putResult('rec1', {
      'start': '2026-10-17T09:00:00',
      'scenes': [
        scene('a', '2026-10-17T09:00:00', '2026-10-17T10:00:00', title: '周会',
            actions: [{'t': '', 'text': '把报价单发给王总', 'who': '我'}],
            reminders: [{'t': '', 'text': '跟进合同', 'when': '下周三'}]),
      ],
    });
    await store.putResult('rec2', {
      'start': '2026-10-18T14:05:00',
      'scenes': [
        scene('b', '2026-10-18T14:05:00', '2026-10-18T15:00:00', title: '洽谈',
            actions: [{'t': '', 'text': '整理样品清单', 'who': '小李'}]),
      ],
    });
  }

  group('汇总', () {
    test('所有段的待办：新的段在前，同段先提醒后行动；来源、谁、什么时候都带上', () async {
      await seed();
      final l = todosOf(store.scenes);
      expect([for (final t in l) t.text], ['整理样品清单', '跟进合同', '把报价单发给王总']);
      expect(l[0].source, '10/18 14:05 · 洽谈');
      expect(l[0].who, '小李');
      expect(l[0].timed, isFalse);
      expect(l[1].when, '下周三');
      expect(l[1].timed, isTrue);
      expect(l[1].kind, 'reminders');
      expect(l.every((t) => !t.done), isTrue);
    });
  });

  group('打勾', () {
    test('写回索引 .xiaoer/<录音>.json 和 每日/<日>.md 的 [x]；取消后回到 [ ]', () async {
      await seed();
      final t = todosOf(store.scenes).firstWhere((t) => t.text == '跟进合同');
      await store.setTodoDone(t, true);

      final j = jsonDecode(store.lib.data('rec1').readAsStringSync());
      expect(j['scenes'][0]['reminders'][0]['done'], isTrue);
      expect(j['scenes'][0]['actions'][0]['done'], isNull);
      final day = File('${store.lib.path}/每日/2026-10-17.md').readAsStringSync();
      expect(day, contains('  - [x] 跟进合同（下周三）'));
      expect(day, contains('  - [ ] 把报价单发给王总'));

      // 重新读一遍（App 重开）还在
      await store.reload();
      final again = todosOf(store.scenes);
      expect(again.firstWhere((t) => t.text == '跟进合同').done, isTrue);
      expect(store.scenes.firstWhere((s) => s.id == 'a').todo, 1, reason: '「N 件要办」只数没打勾的');

      await store.setTodoDone(again.firstWhere((t) => t.text == '跟进合同'), false);
      expect(File('${store.lib.path}/每日/2026-10-17.md').readAsStringSync(), contains('  - [ ] 跟进合同（下周三）'));
      expect(jsonDecode(store.lib.data('rec1').readAsStringSync())['scenes'][0]['reminders'][0].containsKey('done'), isFalse);
    });

    test('按人看的「还没兑现的待办」不算打过勾的', () async {
      await seed();
      await store.setTodoDone(todosOf(store.scenes).firstWhere((t) => t.text == '把报价单发给王总'), true);
      expect(todosWith(store.scenes, '王总'), isEmpty);
    });
  });

  group('重新整理带上打过的勾', () {
    test('carryDone：字面相似的新条目带上 done，不相干的不带', () {
      // 跟真数据一样走一遍 JSON（索引文件读出来的就是这样）
      final old = jsonDecode(jsonEncode([
        {'actions': [{'text': '把报价单发给王总', 'done': true}, {'text': '订机票'}], 'reminders': [{'text': '周五交周报', 'done': true}]},
      ])) as List;
      final neu = jsonDecode(jsonEncode([
        {'actions': [{'text': '报价单发给王总'}, {'text': '订机票去深圳'}], 'reminders': []},
        {'actions': [], 'reminders': [{'text': '周五前交周报', 'when': '周五'}, {'text': '约牙医'}]},
      ])) as List;
      carryDone(old, neu);
      expect(neu[0]['actions'][0]['done'], isTrue);
      expect(neu[0]['actions'][1]['done'], isNull);
      expect(neu[1]['reminders'][0]['done'], isTrue);
      expect(neu[1]['reminders'][1]['done'], isNull);
    });

    test('Syncer.reanalyze：整条录音按模板重新整理后，打过的勾还在', () async {
      final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai',
          chat: (system, user) async => system.contains('"scenes"')
              ? jsonEncode({'scenes': [
                  {'start': '09:00:00', 'end': '09:30:00', 'category': '开会', 'title': '周会（重整）', 'event': '周会',
                   'actions': [{'text': '把报价单发给王总', 'who': '我'}, {'text': '订会议室', 'who': '我'}],
                   'reminders': [{'text': '跟进合同进度', 'when': '下周三'}]},
                ]})
              : '## 要点\n- 重整');
      await store.putResult('rec1', {
        'start': '2026-10-17T09:00:00',
        'lines': [for (var i = 0; i < 30; i++) ['09:${i.toString().padLeft(2, '0')}:00', '今天周会说报价单和合同的事情，第$i句，内容要够长才会整理']],
        'scenes': [
          scene('a', '2026-10-17T09:00:00', '2026-10-17T10:00:00',
              actions: [{'t': '', 'text': '把报价单发给王总', 'who': '我', 'done': true}],
              reminders: [{'t': '', 'text': '跟进合同', 'when': '下周三', 'done': true}]),
        ],
      });
      await syncer.reanalyze('rec1');
      final l = todosOf(store.scenes);
      expect(store.scenes.single.title, '周会（重整）');
      expect({for (final t in l) t.text: t.done}, {'把报价单发给王总': true, '订会议室': false, '跟进合同进度': true});
      expect(File('${store.lib.path}/每日/2026-10-17.md').readAsStringSync(), contains('- [x] 跟进合同进度（下周三）'));
    });
  });

  group('「什么时候」认日期（按录音那天算）', () {
    final sun = DateTime(2026, 10, 18, 14, 5); // 周日
    test('相对说法', () {
      expect(parseWhen('明天下午3点', sun), DateTime(2026, 10, 19, 15));
      expect(parseWhen('后天晚上八点', sun), DateTime(2026, 10, 20, 20));
      expect(parseWhen('今晚', sun), DateTime(2026, 10, 18, 20));
      expect(parseWhen('下周三', sun), DateTime(2026, 10, 21, 9));
      expect(parseWhen('周五前', sun), DateTime(2026, 10, 23, 9), reason: '这周五已经过了，说的是下周五');
      expect(parseWhen('下下周一上午10点半', sun), DateTime(2026, 10, 26, 10, 30));
    });
    test('具体日期，跨年', () {
      expect(parseWhen('10月25日', sun), DateTime(2026, 10, 25, 9));
      expect(parseWhen('十月二十五号中午12点', sun), DateTime(2026, 10, 25, 12));
      expect(parseWhen('10/25 14:30', sun), DateTime(2026, 10, 25, 14, 30));
      expect(parseWhen('1月5号', DateTime(2026, 12, 28)), DateTime(2027, 1, 5, 9));
      expect(parseWhen('2027年3月1日', sun), DateTime(2027, 3, 1, 9));
    });
    test('说不出哪天的不设', () {
      for (final w in ['', '尽快', '月底', '下周', '有空的时候', '2月30日']) {
        expect(parseWhen(w, sun), isNull, reason: w);
      }
    });
  });

  group('放进提醒事项（只拼脚本，不真跑 osascript）', () {
    test('引号、反斜杠、换行都转义；认出日期才设提醒时间', () {
      final s = reminderScript(title: '给"王总"发 C:\\报价', note: '来源\n第二行', due: DateTime(2026, 10, 21, 15, 30));
      expect(s, contains(r'name:"给\"王总\"发 C:\\报价"'));
      expect(s, contains(r'body:"来源\n第二行"'));
      expect(s, isNot(contains('来源\n第二行')));
      expect(s, contains('set day of d to 1\nset year of d to 2026\nset month of d to 10\nset day of d to 21\nset time of d to 55800'));
      expect(s, contains('due date:d, remind me date:d'));
      expect(s, contains('tell application "Reminders"\n  tell default list\n    make new reminder with properties {'));

      final none = reminderScript(title: 'x');
      expect(none, isNot(contains('current date')));
      expect(none, isNot(contains('due date')));
      expect(none, isNot(contains('body:')));
    });

    test('一条待办 → 标题是原文，备注是来源 + 什么时候的原话', () async {
      await seed();
      final t = todosOf(store.scenes).firstWhere((t) => t.text == '跟进合同');
      final s = todoReminderScript(t);
      expect(s, contains('name:"跟进合同"'));
      expect(s, contains(r'body:"来自小耳录音卡：10/17 09:00 · 周会\n什么时候：下周三"'));
      expect(s, contains('set day of d to 21'), reason: '10/17 周六说的「下周三」= 10/21');
      final u = todosOf(store.scenes).firstWhere((t) => t.text == '整理样品清单');
      expect(todoReminderScript(u), isNot(contains('due date')));
    });

    test('失败给原因，不抛', () async {
      await seed();
      final t = todosOf(store.scenes).first;
      String? ran;
      expect(await addToReminders(t, run: (s) async {
        ran = s;
        return ProcessResult(0, 0, '', '');
      }), isNull);
      expect(ran, todoReminderScript(t));
      expect(await addToReminders(t, run: (_) async => ProcessResult(0, 1, '', 'execution error: Not authorized to send Apple events to Reminders. (-1743)')),
          contains('隐私与安全性'));
      expect(await addToReminders(t, run: (_) async => throw const OSError('没有 osascript')), contains('没建成'));
    });
  });
}
