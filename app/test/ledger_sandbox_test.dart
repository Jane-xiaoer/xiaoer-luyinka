// 待确认写回经纪人台账：在台账的「副本」上真跑一遍（LEDGER_SANDBOX=<副本目录>，里面有 settings.json 和 data/台账/）。
// 副本怎么做：把 ~/Desktop/xiaoer/小耳灵感/台账 整个拷进 <副本>/data/台账，settings.json 拷一份、data_dir 指到 <副本>/data。
// 不设 LEDGER_SANDBOX 就跳过——绝不碰真台账。
// ⚠️ confirm_ledger_e2e_test 和 ledger_sandbox_test 各用自己的一份副本，别同一份副本一起跑（会互相改 #247 / #248 的状态）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/ledger.dart';

void main() {
  final sb = Platform.environment['LEDGER_SANDBOX'];
  final home = Platform.environment['HOME'];

  Map<String, dynamic> task(String id) =>
      Map<String, dynamic>.from((jsonDecode(File('$sb/data/台账/事项.json').readAsStringSync()) as Map)[id] as Map);

  test('副本台账：找对应的号，不是任务→不做了，是别人的→等某某，换项目→claim', () async {
    final l = Ledger('$home/projects/xiaoer-linggan/mac/ledger.py', '$sb/data/台账/事项.json', env: {'LINGGAN_SETTINGS': '$sb/settings.json'});
    // 先把副本里要测的两件设成「在做」：不依赖副本拷过来时的状态（芯 11-05 提醒）
    for (final id in ['247', '248']) {
      final r = await Process.run('/usr/bin/python3', ['$home/projects/xiaoer-linggan/mac/ledger.py', 'doing', id],
          workingDirectory: '$home/projects/xiaoer-linggan/mac', environment: {'LINGGAN_SETTINGS': '$sb/settings.json'});
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(task(id)['status'], '在做');
    }
    // 找号：录音卡推过去时 sources 是「场景号#第几件」
    final a = await l.find('20261105-004910-lyk', '先出一个视频脚本');
    final b = await l.find('20261105-004910-lyk', '向对方要资料', pos: 0); // 字面只四成，靠位置认
    expect(a?.id, '248');
    expect(b?.id, '247');
    expect(await l.find('20261105-004910-lyk', '完全不相干的一件事'), isNull);
    expect(await l.find('没有这个场景', '先出一个脚本'), isNull);

    expect(await l.apply(a!, 'not_task'), '台账 #248 改成「不做了」');
    expect(task('248')['status'], '不做了');

    expect(await l.apply(b!, 'owner', who: '欧'), '台账 #247 改成「等欧」');
    expect(task('247')['status'], '等别人');
    expect(task('247')['waiting_on'], '欧');

    // 247 本来就在青禾防灾片：不重复写
    final b2 = (await l.find('20261105-004910-lyk', '向对方要资料', pos: 0))!;
    expect(await l.find('20261105-004910-lyk', '向对方要资料'), isNull); // 不给位置：字面不够，不认
    expect(await l.apply(b2, 'project', project: '青禾防灾片'), '台账 #247 本来就在「青禾防灾片」');
    expect(await l.apply(b2, 'owner', who: '欧'), '台账 #247 本来就在等欧');
    // 已经「不做了」的：再点不是任务不动；已经做完的不改回「等别人」
    final a2 = (await l.find('20261105-004910-lyk', '先出一个视频脚本'))!;
    expect(await l.apply(a2, 'not_task'), '台账 #248 已经是「不做了」，没动');
    expect(await l.apply(a2, 'owner', who: '欧'), '台账 #248 已经是「不做了」，没改成等欧');
    // 字面不够像：不认（注意：只差一个字的，比如「联系李总」对「联系李航」重合约七成，门槛挡不住，
    // 靠的是只在同一段的几件里找 + 卡片上显示台账标题让我点之前看得到）
    expect(await l.find('20261105-004910-lyk', '跟供应商确认交期'), isNull);

    // 项目名台账不认：照抛台账自己的话
    await expectLater(l.apply(b2, 'project', project: '没有这个项目'), throwsA(predicate((e) => '$e'.contains('没有叫「没有这个项目」的项目'))));
    // 是我的 / 是「我」的：不动台账
    expect(await l.apply(b, 'mine'), '');
    expect(await l.apply(b, 'owner', who: '我'), '');

    expect(await l.projects(), contains('青禾防灾片'));
  }, skip: sb == null ? '要 LEDGER_SANDBOX=<台账副本>' : false);
}
