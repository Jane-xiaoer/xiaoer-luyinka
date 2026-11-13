import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/analyze.dart' show aliasMap;
import 'package:luyinka/people.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/templates.dart';

Scene sc(String id, String start, List<String> people, {List<Map<String, dynamic>> actions = const []}) => Scene({
      'id': id, 'start': '$start:00', 'end': '${start.substring(0, 14)}59:00', 'category': '商务洽谈', 'title': '标题$id',
      'event': '事件$id', 'people': people, 'actions': actions, 'reminders': [], 'body': '', 'text': [['10:00:00', '原话']],
    }, 'stem');

void main() {
  final all = [
    sc('c', '2026-11-11T19:00', ['周总周宁', '董老师'], actions: [{'text': '仔细看协议', 'who': '周总'}]),
    sc('b', '2026-11-10T10:00', ['周总', '小耳']),
    sc('a', '2026-11-09T10:00', ['周总', '张总']),
  ];

  test('公司是第 5 栏：旧行照读，新行写出来再读回一样；换行和竖线不拆坏格式', () {
    final old = PersonEntry.parse('- 练（练、练总）｜甲方｜舞蹈馆与城市馆｜')!;
    expect(old.company, '');
    expect(old.line, '- 练（练、练总）｜甲方｜舞蹈馆与城市馆｜');
    final p = PersonEntry('周宁', aliases: ['周总'], company: '明川生物', project: '春芽', note: '负责品牌\n对接 | 合同');
    final back = PersonEntry.parse(p.line)!;
    expect(back.company, '明川生物');
    expect(back.note, '负责品牌；对接 / 合同');
    expect(back.group, '春芽'); // 11-13 Jane：按项目分，不按公司
    expect(PersonEntry('x', company: '明川生物').group, '明川生物'); // 没写项目才按公司
    expect(PersonEntry('x', project: '春芽、青禾防灾片').groups, ['春芽', '青禾防灾片']);
  });

  test('并人：周总并进周总周宁，左栏只剩一个、段合到一起、待办按叫法也找得到', () {
    final list = mergePerson([], '周总', '周总周宁');
    final r = Roster(list);
    final ps = peopleOf(all, r);
    expect(ps.map((p) => p.name), isNot(contains('周总')));
    expect(ps.firstWhere((p) => p.name == '周总周宁').count, 3);
    expect(scenesWith(all, '周总周宁', r).map((s) => s.id), ['c', 'b', 'a']);
    expect(scenesWith(all, '周总', r).map((s) => s.id), ['c', 'b', 'a']);
    expect(todosWith(all, '周总周宁', r).map((t) => t.text), ['仔细看协议']);
    // 没名单：照旧分开
    expect(peopleOf(all).map((p) => p.name), containsAll(['周总', '周总周宁']));
  });

  test('并人：名单上两边都有资料，空的补上、备注接起来，被并的那行拿掉', () {
    final list = mergePerson([
      PersonEntry('周总', aliases: ['周总', '周老板'], company: '明川生物', note: '爱喝茶'),
      PersonEntry('周宁', aliases: ['周宁'], project: '春芽', note: '品牌负责人'),
    ], '周总', '周宁');
    expect(list.length, 1);
    final t = list.single;
    expect(t.name, '周宁');
    expect(t.aliases, ['周宁', '周总', '周老板']);
    expect(t.company, '明川生物');
    expect(t.project, '春芽');
    expect(t.note, '品牌负责人；爱喝茶');
  });

  test('写资料改了名字：旧名字留作叫法，以前录音里的段还认得出', () {
    final list = upsertPerson([], '周总周宁', PersonEntry('周宁', company: '明川生物'));
    expect(list.single.aliases, ['周宁', '周总周宁']);
    final r = Roster(list);
    expect(scenesWith(all, '周宁', r).map((s) => s.id), ['c']);
    expect(peopleOf(all, r).firstWhere((p) => p.name == '周宁').group, '明川生物');
  });

  test('名单上还没在录音里出现的人也列上（0 段，排最后）', () {
    final ps = peopleOf(all, Roster([PersonEntry('阿星', aliases: ['阿星'])]));
    expect(ps.last.name, '阿星');
    expect(ps.last.count, 0);
  });

  test('删人：名单拿掉、名字和叫法都藏起来，左栏不列，段不动；删 1 人只算 1 人', () {
    final (list, hidden) = removePerson([PersonEntry('小耳老师', aliases: ['小耳老师', '小耳'])], [], '小耳老师');
    expect(list, isEmpty);
    expect(hidden.length, 1);
    final r = Roster(list, hiddenPeople: hidden);
    expect(peopleOf(all, r).map((p) => p.name), isNot(contains('小耳')));
    expect(scenesWith(all, '小耳', r).map((s) => s.id), ['b']);
  });

  test('过了撤销再找回：资料原样回到名单（公司、介绍、叫法都在），叫法也重新认成他', () {
    final orig = PersonEntry('周总周宁', aliases: ['周总周宁', '周总'], identity: '甲方', project: '春芽', note: '品牌负责人', company: '明川生物');
    final (l1, h1) = removePerson([orig], [], '周总周宁');
    // 存进文件再读回来（跟真 App 一样隔了一次读写）
    final h1b = [for (final h in h1) HiddenPerson.parse(h.line)!];
    final (l2, h2) = restorePerson(l1, h1b, '周总周宁');
    expect(h2, isEmpty);
    expect(l2.single.line, orig.line);
    final ps = peopleOf(all, Roster(l2, hiddenPeople: h2));
    expect(ps.map((p) => p.name), isNot(contains('周总')));
    expect(ps.firstWhere((p) => p.name == '周总周宁').group, '春芽');
  });

  test('删人不牵连别人：叫法正好是名单上别人的名字 / 叫法的，不藏', () {
    final scenes = [sc('x', '2026-11-11T10:00', ['李航']), sc('y', '2026-11-10T10:00', ['李总'])];
    final (list, hidden) = removePerson([PersonEntry('李航', aliases: ['李航', '李总']), PersonEntry('李总', aliases: ['李总'])], [], '李航');
    final ps = peopleOf(scenes, Roster(list, hiddenPeople: hidden));
    expect(ps.map((p) => p.name), ['李总']);
  });

  test('删掉的名字，名单上又加回同名的人：照样列出来', () {
    final (list, hidden) = removePerson([], [], '小耳');
    final ps = peopleOf(all, Roster([...list, PersonEntry('小耳', aliases: ['小耳'])], hiddenPeople: hidden));
    expect(ps.map((p) => p.name), contains('小耳'));
  });

  test('改名 / 补叫法撞上别人的名字或叫法：takenBy 查得出是谁，自己的不算', () {
    final r = Roster([PersonEntry('欧', aliases: ['欧', '青总']), PersonEntry('周总周宁', aliases: ['周总周宁', '周总'])]);
    final t = r.takenBy('周总周宁');
    expect(t[personKey('青总')], '欧');
    expect(t[personKey('欧')], '欧');
    expect(t.containsKey(personKey('周总')), isFalse);
  });

  test('待办按叫法找：单字叫法不用（「欧」不该找到「去欧洲」）', () {
    final r = Roster([PersonEntry('欧阳', aliases: ['欧阳', '欧'])]);
    final s = [sc('z', '2026-11-11T10:00', ['欧阳'], actions: [{'text': '订去欧洲的票', 'who': '我'}, {'text': '把稿子给欧阳', 'who': '我'}])];
    expect(todosWith(s, '欧阳', r).map((t) => t.text), ['把稿子给欧阳']);
  });

  test('单字名字（欧）：who 就是他才算，正文里的「欧洲」不算', () {
    final r = Roster([PersonEntry('欧', aliases: ['欧', '青总'])]);
    final s = [sc('z', '2026-11-11T10:00', ['欧'], actions: [{'text': '订去欧洲的票', 'who': '我'}, {'text': '改脚本', 'who': '欧'}, {'text': '催青总付款', 'who': '我'}])];
    expect(todosWith(s, '欧', r).map((t) => t.text), ['改脚本', '催青总付款']);
  });

  test('这是我：小耳、小耳老师并进「我」，按人里不列，拆事时这两个叫法认成我', () {
    var list = mergePerson([], '小耳', meName);
    list = mergePerson(list, '小耳老师', meName);
    final r = Roster(list);
    expect(peopleOf(all, r).map((p) => p.name), isNot(anyOf(contains('小耳'), contains('我'))));
    expect(aliasMap(list), {'小耳': '我', '小耳老师': '我'});
  });

  test('按项目分组（没项目按公司）：没写公司 / 项目的不进组；组里的段、待办合起来不重复', () {
    final list = [
      PersonEntry('周总周宁', aliases: ['周总周宁', '周总'], company: '明川生物'),
      PersonEntry('李航', aliases: ['李航'], company: '明川生物'),
      PersonEntry('董老师', aliases: ['董老师'], project: '青禾防灾片'),
    ];
    final r = Roster(list);
    final scenes = [...all, sc('d', '2026-11-08T10:00', ['李航'], actions: [{'text': '跟周总对报价', 'who': '李航'}])];
    final gs = groupsOf(peopleOf(scenes, r), scenes, r);
    expect(gs.map((g) => g.name), ['明川生物', '青禾防灾片']);
    expect(gs.first.names, containsAll(['周总周宁', '李航']));
    expect(scenesInGroup(scenes, gs.first.names, r).map((s) => s.id), ['c', 'b', 'a', 'd']);
    final t = todosInGroup(scenes, gs.first.names, r).map((t) => t.text).toList();
    expect(t, ['仔细看协议', '跟周总对报价']); // 「跟周总对报价」两个人都对得上，只算一次
  });

  test('写资料草稿：小耳回的 JSON 读成四栏，身份不在选项里的丢掉，读不出来就空', () {
    expect(parseDraft('好的：\n{"company":"明川生物","project":"春芽","identity":"甲方","note":"品牌负责人"}'),
        {'company': '明川生物', 'project': '春芽', 'note': '品牌负责人', 'identity': '甲方'});
    expect(parseDraft('{"company":"","identity":"老板","note":"x"}'), {'note': 'x'});
    expect(parseDraft('没看出来'), isEmpty);
    expect(draftNotes([all.first]), contains('在场：周总周宁、董老师'));
  });

  test('草稿：回复里有几段 {} 也读得出；读不出是空', () {
    expect(parseDraft('例子 {"a":1} 答案 {"company":"明川生物"}'), {'company': '明川生物'});
    expect(parseDraft('{坏的'), isEmpty);
  });

  test('身份加了乙方、分享者；提示词里说清分享者讲的不是待办、「我」那行的叫法就是我', () {
    expect(personIdentities, containsAll(['乙方', '分享者']));
    final b = peopleBlock('- 李鹏（李鹏）｜分享者｜｜');
    expect(b, contains('分享者是讲座'));
    expect(b, contains('名字是「我」的那一行'));
    final (_, extra) = parsePeople('> 身份：合作方 / 甲方 / 同事 / 朋友 / 家人 / 其他。\n');
    expect(extra.single, contains('分享者'));
  });
}
