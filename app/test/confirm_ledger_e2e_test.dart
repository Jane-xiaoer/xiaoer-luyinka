// 端到端：待确认按钮背后那段（applyChoice）→ 写回这一段 + 纠正记录 + 台账（副本）+ 每日 md。
// 按钮就是调 applyChoice（confirm.dart _do），这里在真异步里直接跑它（界面测试的假时间里，进程 / 文件操作会停在半路）。
// 要台账副本：LEDGER_SANDBOX=<副本目录>（里面有 settings.json、data/台账/，做法见 ledger_sandbox_test.dart）。不设就跳过，绝不碰真台账。
// 用台账里真有的三件（11-05 iPhone 那段推过去的 #247 #248，11-04 那段的 #244），把录音卡这边的场景号对上。
// ⚠️ confirm_ledger_e2e_test 和 ledger_sandbox_test 各用自己的一份副本，别同一份副本一起跑（会互相改 #247 / #248 的状态）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/confirm.dart';
import 'package:luyinka/ledger.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/todos.dart';

void main() {
  final sb = Platform.environment['LEDGER_SANDBOX'];
  final home = Platform.environment['HOME'];
  final mac = '$home/projects/xiaoer-linggan/mac';

  Map<String, dynamic> task(String id) =>
      Map<String, dynamic>.from((jsonDecode(File('$sb/data/台账/事项.json').readAsStringSync()) as Map)[id] as Map);
  Future<void> ledgerCmd(List<String> args) async {
    final r = await Process.run('/usr/bin/python3', ['$mac/ledger.py', ...args],
        workingDirectory: mac, environment: {'LINGGAN_SETTINGS': '$sb/settings.json'});
    expect(r.exitCode, 0, reason: '${r.stderr}');
  }

  test('不是任务 / 是谁的 / 换项目 / 是我的 → 副本台账「不做了 / 等某某 / 换项目 / 不动」，每日 md 不留撇掉的', () async {
    for (final id in ['244', '247', '248']) {
      await ledgerCmd(['doing', id]); // 从同一个起点开始
    }
    final tmp = await Directory.systemTemp.createTemp('e2e');
    final store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
    final now = DateTime.now();
    String iso(DateTime t) => t.toIso8601String().substring(0, 19);
    final start = now.subtract(const Duration(hours: 2));
    await store.putResult('e2e1', {
      'start': iso(start),
      'scenes': [
        {
          'id': '20261105-004910-lyk', 'start': iso(start), 'end': iso(start.add(const Duration(minutes: 1))), 'category': '自言自语',
          'title': '梳理当天推进的几件事', 'event': 'x', 'people': [], 'text': [], 'body': '## x\n- y',
          'actions': [
            {'t': '00:49:40', 'text': '向对方要资料', 'who': '我', 'said': '跟对方要一个资料'},
            {'t': '00:49:40', 'text': '先出一个脚本', 'who': '我', 'said': '这边先出一个脚本'},
          ],
          'reminders': [],
        },
        {
          'id': '20261104-230419-lyk', 'start': iso(start.add(const Duration(minutes: 10))),
          'end': iso(start.add(const Duration(minutes: 30))), 'category': '多人群聊', 'title': '聊甲方层级',
          'event': 'x', 'people': [], 'text': [], 'body': '## x\n- y',
          'actions': [
            {'t': '23:21:04', 'text': '联系李航', 'who': '别人', 'said': '我我联系李航的嗯。'},
          ],
          'reminders': [],
        },
      ],
    });
    final l = Ledger('$mac/ledger.py', '$sb/data/台账/事项.json', env: {'LINGGAN_SETTINGS': '$sb/settings.json'});
    Todo todo(String text) => todosOf(store.scenes).firstWhere((t) => t.text == text);

    // 卡片上要显示的那件：号和标题对得上
    expect((await l.find('20261105-004910-lyk', '向对方要资料', pos: 0))?.title, '向养护公司要资料');
    expect((await l.find('20261104-230419-lyk', '联系李航', pos: 0))?.id, '244');

    expect(await applyChoice(store, l, todo('联系李航'), 'not_task'), '记下了：不是任务，不进待办 · 台账 #244 改成「不做了」');
    expect(task('244')['status'], '不做了');

    expect(await applyChoice(store, l, todo('向对方要资料'), 'owner', who: '欧'), '记下了：是欧的，留着等欧 · 台账 #247 改成「等欧」');
    expect(task('247')['status'], '等别人');
    expect(task('247')['waiting_on'], '欧');

    expect(await applyChoice(store, l, todo('先出一个脚本'), 'project', project: '青禾防灾片'),
        anyOf('记下了：归「青禾防灾片」 · 台账 #248 归到「青禾防灾片」', '记下了：归「青禾防灾片」 · 台账 #248 本来就在「青禾防灾片」'));
    expect(task('248')['project'], '青禾防灾片');
    expect(pendingTodos(store.scenes).map((t) => t.text), ['先出一个脚本']); // 换项目不算确认
    // 真换一次项目（上面那次台账本来就在那个项目，走的是「不重复写」）：claim 真的执行
    expect(await applyChoice(store, l, todo('先出一个脚本'), 'project', project: '小耳录音卡'), '记下了：归「小耳录音卡」 · 台账 #248 归到「小耳录音卡」');
    expect(task('248')['project'], '小耳录音卡');

    expect(await applyChoice(store, l, todo('先出一个脚本'), 'mine'), '记下了：是你的');
    expect(task('248')['status'], '在做'); // 是我的：不动台账
    expect(pendingTodos(store.scenes), isEmpty);

    // 改主意：这件不是任务 → 台账不做了
    expect(await applyChoice(store, l, todo('先出一个脚本'), 'not_task'), contains('台账 #248 改成「不做了」'));
    // 纠正记录 6 条，带段号、列表、时区
    final fixes = [for (final l in store.lib.fixesFile.readAsLinesSync()) if (l.trim().isNotEmpty) jsonDecode(l) as Map];
    expect([for (final f in fixes) f['fix']['kind']], ['not_task', 'owner', 'project', 'project', 'owner', 'not_task']);
    expect(fixes.first['scene'], '20261104-230419-lyk');
    expect(fixes.first['list'], 'actions');
    expect('${fixes.first['at']}', matches(RegExp(r'[+-]\d\d:\d\d$')));
    // 每日 md：撇掉的不在
    final md = File('${store.lib.path}/每日/${store.scenes.first.dayKey}.md').readAsStringSync();
    expect(md, isNot(contains('联系李航')));
    expect(md, isNot(contains('先出一个脚本')));
    expect(md, contains('- 欧的：向对方要资料')); // 别人的事不给勾选框（#297）
    await store.save();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }, skip: sb == null ? '要 LEDGER_SANDBOX=<台账副本>' : false, timeout: const Timeout(Duration(minutes: 2)));
}
