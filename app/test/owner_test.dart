// 拆出来的事：说话人 / 原话从逐字稿行首标注取（不信模型），喂给模型时没认出的人补「？：」。不调模型。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/analyze.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/todos.dart';
import 'package:luyinka/templates.dart';

void main() {
  final lines = [
    ['22:58:49', '练：我我先跟那边对接一下'],
    ['23:02:11', '练：还是要根据案例做一个完整一点的样板'],
    ['23:20:25', '我：我不想当小白鼠'],
    ['23:21:04', '我我联系李航的嗯。'],
  ];

  test('说话人、原话按行首标注填；没标的说话人留空', () {
    final out = tidyActions([
      {'t': '22:58:49', 'text': '对接看板系统', 'who': '练', 'speaker': '模型乱填的'},
      {'t': '23:02:11', 'text': '做完整样板', 'who': '我'},
      {'t': '23:21:04', 'text': '联系李航', 'who': '别人'},
    ], lines);
    expect([for (final a in out) a['speaker']], ['练', '练', '']);
    expect([for (final a in out) a['who']], ['练', '我', '别人']);
    expect(out[0]['said'], '我我先跟那边对接一下');
    expect(out[2]['said'], '我我联系李航的嗯。');
  });

  test('钟点对不上取之前最近的一行；没钟点 / 在第一行之前就空着', () {
    final out = tidyActions([
      {'t': '23:02:30', 'text': 'a'},
      {'t': '', 'text': 'b'},
      {'t': '22:00:00', 'text': 'c'},
      {'t': '23:20', 'text': 'd'},
    ], lines);
    expect(out[0]['speaker'], '练');
    expect(out[1]['said'], '');
    expect(out[2]['said'], '');
    expect(out[3]['said'], '还是要根据案例做一个完整一点的样板');
  });

  test('模型把钟点抄成旁边一行：按内容找回真正说这件事的那句', () {
    final scene = [
      ['23:01:26', '嗯嗯，那差不多我们也了解了啊，我觉得做我们基本没有太大问题啊，包括就是说这个案例'],
      ['23:02:11', '练：还是要根据现在这个提供的案例做一个就是比较完整一点的样板'],
    ];
    final out = tidyActions([
      {'t': '23:01:26', 'text': '根据提供的案例做一个比较完整的样板', 'who': '我'},
    ], scene);
    expect(out[0]['t'], '23:02:11');
    expect(out[0]['speaker'], '练');
    // 钟点抄对了、内容也沾边：不动
    final kept = tidyActions([
      {'t': '23:01:26', 'text': '了解这个案例没有问题', 'who': '我'},
    ], scene);
    expect(kept[0]['t'], '23:01:26');
  });

  test('自言自语 / 个人感悟里没写归谁的 → 我；别的类别不替模型做主', () {
    final xs = [
      {'t': '', 'text': '先出一个脚本', 'who': ''},
      {'t': '', 'text': '跟董老师确认', 'who': '董老师'},
    ];
    expect([for (final a in tidyActions(xs, const [], solo: true)) a['who']], ['我', '董老师']);
    expect([for (final a in tidyActions(xs, const [])) a['who']], ['', '董老师']);
    expect(soloCats, containsAll(['自言自语', '个人感悟']));
  });

  test('没认出的人只说「我们」：不信「别人」，留空；说了单数「我」才信', () {
    final scene = [
      ['22:41:05', '对，就是如果你们有这个文案，我们就按你的回量来就行了啊'],
      ['23:21:04', '我我联系李航的嗯。'],
      ['22:58:49', '练：我们先跟技术支持单位对接'],
      ['22:47:01', '嗯嗯它里面有就这个文字说明，这个就是跟刚刚那个图片那个配套的'],
    ];
    final out = tidyActions([
      {'t': '22:41:05', 'text': '按提供的文案制作视频', 'who': '别人'},
      {'t': '23:21:04', 'text': '联系李航', 'who': '别人'},
      {'t': '22:58:49', 'text': '跟技术支持单位对接', 'who': '练'},
      {'t': '22:47:01', 'text': '提供案例配套文字说明', 'who': '别人'},
      {'t': '', 'text': '没出处的事', 'who': '别人'},
    ], scene);
    // 只有明说「我们」又没单数「我」的才清空；甲方要交资料（原话没「我们」）、没出处的，照模型的「别人」
    expect([for (final a in out) a['who']], ['', '别人', '练', '别人', '别人']);
  });

  test('没认出的人说「我们提供 / 发给你」：是给东西的一方，兜底不清他的「别人」', () {
    final scene = [
      ['10:00:00', '这个素材我们到时都能提供啊'],
      ['10:01:00', '照片我们这边有，回头发给你们'],
      ['10:02:00', '对，我们就按你们的来做就行'],
    ];
    final out = tidyActions([
      {'t': '10:00:00', 'text': '提供素材', 'who': '别人'},
      {'t': '10:01:00', 'text': '发照片', 'who': '别人'},
      {'t': '10:02:00', 'text': '按对方的来做', 'who': '别人'},
    ], scene);
    expect([for (final a in out) a['who']], ['别人', '别人', '']);
  });

  test('「我」不显示（跟以前空着一样），别人 / 人名照写', () {
    expect(shownWho('我'), '');
    expect(shownWho(' 我 '), '');
    expect(shownWho(null), '');
    expect(shownWho('别人'), '别人');
    expect(shownWho('练'), '练');
  });

  test('原话太长截到 80 字', () {
    final out = tidyActions([
      {'t': '10:00:00', 'text': 'x'},
    ], [
      ['10:00:00', '我：${'啊' * 100}'],
    ]);
    expect((out[0]['said'] as String).length, 81);
  });

  test('认过人的录音：没标的行补「？：」；没认过人的录音一行不动', () {
    expect(hasSpeakerMarks(lines), true);
    expect([for (final l in lines) feedLine(l, true)], [
      '[22:58:49] 练：我我先跟那边对接一下',
      '[23:02:11] 练：还是要根据案例做一个完整一点的样板',
      '[23:20:25] 我：我不想当小白鼠',
      '[23:21:04] ？：我我联系李航的嗯。',
    ]);
    final solo = [
      ['00:49:40', '跟对方要一个资料，然后这边先出一个脚本'],
    ];
    expect(hasSpeakerMarks(solo), false);
    expect(feedLine(solo[0], false), '[00:49:40] 跟对方要一个资料，然后这边先出一个脚本');
  });

  test('提示词讲清「归谁」≠「谁说的」', () {
    final p = cutPrompt(const []);
    expect(p, contains('「？：」的是没认出来的人'));
    expect(p, contains('不是「谁说的」'));
  });

  test('纠正记录 → 提示词一行；认不出的跳过', () {
    expect(fixLine({'text': '联系李航', 'said': '我我联系李航的嗯。', 'guess': {'who': '别人'}, 'fix': {'kind': 'not_mine_task'}}),
        '- 原话「我我联系李航的嗯。」拆成「联系李航」，当时猜归「别人」→ 不进我的待办（不是我要做的事）');
    expect(fixLine({'text': '要资料', 'said': '跟对方要一个资料', 'fix': {'kind': 'owner', 'who': '欧'}}), contains('是欧的，不是我的'));
    expect(fixLine({'text': '出脚本', 'said': '', 'fix': {'kind': 'owner', 'who': '我'}}), endsWith('→ 是我的'));
    expect(fixLine({'text': 'x', 'fix': {'kind': '乱写'}}), '');
    expect(fixLine({'fix': {'kind': 'not_task'}}), '');
  });

  test('人员名单、纠正记录进拆事提示词；没有就不出现这两节', () {
    final p = cutPrompt(const [], people: '- 练（练、练总）｜甲方｜舞蹈馆与城市馆｜', fixes: '- 原话「a」拆成「b」→ 是我的');
    expect(p, contains('我录音里常出现的人'));
    expect(p, contains('练（练、练总）｜甲方'));
    expect(p, contains('我以前亲手纠正过的拆事'));
    final bare = cutPrompt(const []);
    expect(bare, isNot(contains('我录音里常出现的人')));
    expect(bare, isNot(contains('我以前亲手纠正过的拆事')));
  });

  test('Library 读人员名单（去掉说明行）和纠正记录（最近 N 条，坏行跳过）', () async {
    final d = await Directory.systemTemp.createTemp('lib');
    await Directory('${d.path}/.xiaoer').create();
    File('${d.path}/人员名单.md').writeAsStringSync('# 人员名单\n\n> 说明\n\n- 练（练总）｜甲方｜｜\n');
    File('${d.path}/.xiaoer/纠正.jsonl').writeAsStringSync([
      for (var i = 0; i < 3; i++) jsonEncode({'text': '事$i', 'said': '话$i', 'fix': {'kind': 'owner', 'who': '我'}}),
      '不是 json',
    ].join('\n'));
    final lib = Library(d);
    expect(lib.people(), '- 练（练总）｜甲方｜｜');
    expect(lib.fixes(max: 2).split('\n'), [contains('事1'), contains('事2')]);
    expect(Library(await Directory.systemTemp.createTemp('empty')).fixes(), '');
  });

  group('我的纠正「记住」：重新整理同一条录音时改回我选的', () {
    Map<String, dynamic> fix(String t, String text, Map<String, dynamic> f) => {'rec': 'r', 't': t, 'text': text, 'fix': f};

    test('同一钟点两件事按内容分开；模型换了说法也认得', () {
      final out = applyFixes([
        {'t': '00:49:40', 'text': '向对方要资料', 'who': '我'},
        {'t': '00:49:40', 'text': '先出一个视频脚本', 'who': '我'},
      ], [
        fix('00:49:40', '向养护公司要资料', {'kind': 'owner', 'who': '欧'}),
        fix('00:49:40', '先出一个脚本', {'kind': 'owner', 'who': '我'}),
      ]);
      expect([for (final a in out) a['who']], ['欧', '我']);
      expect([for (final a in out) a['fixed']], ['owner', 'owner']);
      expect(out.any((a) => a['dismissed'] == true), false);
    });

    test('不是我的事 → 撇掉、归属改别人；不是任务 → 撇掉；钟点差一点也认得', () {
      final out = applyFixes([
        {'t': '23:02:11', 'text': '根据提供的案例制作完整样板', 'who': '我'},
        {'t': '23:21:04', 'text': '联系李航', 'who': '别人'},
        {'t': '22:58:49', 'text': '跟技术支持单位对接看板', 'who': '练'},
        {'t': '22:00:00', 'text': '不相干的事', 'who': '我'},
      ], [
        fix('23:02:11', '制作展馆交互完整样板', {'kind': 'not_mine_task'}),
        fix('23:21:30', '联系李航', {'kind': 'not_mine_task'}),
        fix('22:58:49', '对接展馆看板系统', {'kind': 'not_task'}),
      ]);
      expect([for (final a in out) a['who']], ['别人', '别人', '练', '我']);
      expect([for (final a in out) a['dismissed'] == true], [true, true, true, false]);
      expect(out[3].containsKey('fixed'), false);
    });

    test('找不到对应的不动；后写的纠正覆盖先写的；不改传进来的', () {
      final src = [
        {'t': '10:00:00', 'text': '发报价', 'who': '我'},
      ];
      final out = applyFixes(src, [
        fix('11:00:00', '发报价', {'kind': 'not_task'}), // 差一小时，不算
        fix('10:00:00', '发报价', {'kind': 'owner', 'who': '练'}),
        fix('10:00:05', '发报价单', {'kind': 'owner', 'who': '我'}),
      ]);
      expect(out.single['who'], '我');
      expect(out.single['fixed'], 'owner');
      expect(src.single.containsKey('fixed'), false);
    });

    test('Library 只取这条录音的纠正', () async {
      final d = await Directory.systemTemp.createTemp('fx');
      await Directory('${d.path}/.xiaoer').create();
      File('${d.path}/.xiaoer/纠正.jsonl').writeAsStringSync([
        jsonEncode(fix('1:00', 'a', {'kind': 'not_task'})),
        jsonEncode({...fix('1:00', 'b', {'kind': 'not_task'}), 'rec': 'other'}),
        '坏行',
      ].join('\n'));
      expect([for (final f in Library(d).fixesFor('r')) f['text']], ['a']);
    });
  });

  test('总待办不列撇掉的事（不是我的 / 不是任务）', () {
    final s = Scene({
      'id': 'x', 'start': '2026-11-04T23:00:00', 'end': '2026-11-04T23:30:00', 'category': '开会', 'title': 't',
      'actions': [
        {'t': '23:02:11', 'text': '做样板', 'who': '别人', 'dismissed': true, 'fixed': 'not_mine_task'},
        {'t': '23:10:00', 'text': '发报价', 'who': '我'},
        {'t': '00:49:40', 'text': '要资料', 'who': '欧', 'fixed': 'owner'},
      ],
    }, 'r');
    expect([for (final t in todosOf([s])) t.text], ['发报价', '要资料']);
  });

  test('没钟点的纠正：整条录音里按内容找，字面很像才认', () {
    final out = applyFixes([
      {'t': '', 'text': '提供科普类文本素材', 'who': ''},
      {'t': '22:43:22', 'text': '提供案例航拍图', 'who': '我'},
      {'t': '', 'text': '提供一些别的东西', 'who': '我'},
    ], [
      {'rec': 'r', 't': '', 'text': '提供科普类文本素材', 'fix': {'kind': 'not_task'}},
      {'rec': 'r', 't': '', 'text': '提供航拍图', 'fix': {'kind': 'not_task'}},
      {'rec': 'r', 't': '', 'text': '完全对不上的事', 'fix': {'kind': 'not_task'}},
    ]);
    expect([for (final a in out) a['dismissed'] == true], [true, true, false]);
  });

  test('人员名单的叫法 → 名字：阿西→阿星、练总→练；两个人共用的叫法谁都不换', () {
    final m = aliasMap([
      PersonEntry('阿星', aliases: ['阿星', '阿西']),
      PersonEntry('练', aliases: ['练', '练总']),
      PersonEntry('李航', aliases: ['李总']),
      PersonEntry('刘大', aliases: ['李总']),
    ]);
    expect(m, {'阿西': '阿星', '练总': '练'});
  });

  test('叫法等于别人的名字、或者是「我 / 别人」：不进对照表（不串人）', () {
    expect(aliasMap([PersonEntry('李航', aliases: ['李航', '李总']), PersonEntry('李总', aliases: ['李总'])]), isEmpty);
    expect(aliasMap([PersonEntry('练', aliases: ['我', '练总']), PersonEntry('阿星', aliases: ['别人', '阿西'])]), {'练总': '练', '阿西': '阿星'});
  });
}
