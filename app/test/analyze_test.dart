import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/analyze.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';

final lines = [
  for (var i = 0; i < 40; i++) ['14:${(i ~/ 2).toString().padLeft(2, '0')}:${i.isEven ? '05' : '35'}', '我们看一下这个月的报价和交货时间，第$i句'],
  ['15:30:00', '这是工厂的产线，一天能出两千件，老板说下个月扩到三千'],
  for (var i = 0; i < 10; i++) ['15:3${i ~/ 2}:${i.isEven ? '10' : '40'}', '车间主任介绍了质检流程，返工率大概百分之二，第$i句'],
];

void main() {
  late Directory tmp;
  late Library lib;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lib');
    lib = Library(Directory('${tmp.path}/资料'));
    await lib.ensure();
  });
  tearDown(() => tmp.delete(recursive: true));

  /// 假模型：切场景时回两段（开会 + 现场调研），写笔记时回模板名 + 有没有给以前的调研。
  Future<String> fake(String system, String user) async {
    if (system.contains('"scenes"')) {
      return jsonEncode({
        'scenes': [
          {'start': '14:00:05', 'end': '14:19:35', 'category': '开会', 'title': '月度报价会', 'event': '对报价和交货。',
           'people': ['老王'], 'actions': [{'t': '14:10:05', 'text': '周三前发报价单', 'who': '我'}]},
          {'start': '15:30:00', 'end': '15:34:40', 'category': '现场调研', 'title': '看工厂产线', 'event': '参观产线。',
           'place': '东莞', 'subject': '东莞某工厂'},
        ]
      });
    }
    final kind = system.contains('会议纪要') ? '纪要' : (system.contains('调研笔记') ? '调研' : '其他');
    return '## 结果\n- $kind\n- ${user.contains('以前对「东莞某工厂」的调研记录') ? '有以前的' : '第一次'}';
  }

  test('切场景 → 按类别套模板 → 写进资料文件夹', () async {
    final scenes = await Analyzer(lib, fake).run('2026-10-18 14.00.00', {'start': '2026-10-18T14:00:05+08:00', 'lines': lines});
    expect(scenes.map((s) => s['category']), ['开会', '现场调研']);
    expect(scenes[0]['body'], contains('纪要'));
    expect(scenes[1]['body'], contains('调研'));
    expect(scenes[1]['subject'], '东莞某工厂');
    expect((scenes[0]['text'] as List).length, 40); // 14 点那段的逐字稿都归开会
    expect(scenes[1]['offset'], 5395.0); // 15:30:00 - 14:00:05

    final store = Store(Directory('${tmp.path}/app'))..lib = lib;
    await store.putResult('2026-10-18 14.00.00', {'start': '2026-10-18T14:00:05', 'lines': lines, 'scenes': scenes});
    expect(File('${lib.path}/会议纪要/2026-10-18 14.00 月度报价会.md').readAsStringSync(), contains('**人物**：老王'));
    expect(File('${lib.path}/现场调研/2026-10-18 15.30 看工厂产线.md').existsSync(), isTrue);
    expect(File('${lib.path}/现场调研/按对象/东莞某工厂.md').readAsStringSync(), contains('看工厂产线'));
    expect(File('${lib.path}/每日/2026-10-18.md').readAsStringSync(), contains('- [ ] 周三前发报价单'));
    expect(File('${lib.path}/模板/开会.md').existsSync(), isTrue);
    expect(store.byCategory.keys, ['开会', '现场调研']);

    // 下次再调研同一个对象：以前的记录当背景喂给模型；自己这段不算「以前」
    expect(await Analyzer(lib, fake).note(store.byCategory['现场调研']!.first), contains('第一次'));
    final again = await Analyzer(lib, fake).run('2026-10-25 15.30.00', {
      'start': '2026-10-25T15:30:00',
      'lines': [for (final l in lines.skip(40)) ['15:3${l[0].substring(4)}', l[1]]],
    });
    expect(again.firstWhere((s) => s['category'] == '现场调研')['body'], contains('有以前的'));
  });

  test('改了模板就按改过的整理', () async {
    await lib.templateFile('开会').writeAsString('只写一句话总结');
    String? seen;
    await Analyzer(lib, (s, u) async {
      if (s.contains('"scenes"')) return '{"scenes":[{"start":"14:00:05","end":"14:19:35","category":"开会","title":"会"}]}';
      seen = s;
      return '## 总结\n好';
    }).run('x', {'start': '2026-10-18T14:00:05', 'lines': lines});
    expect(seen, contains('只写一句话总结'));
  });

  test('同一件事别在行动和提醒里记两遍', () {
    final out = dedupeActions([
      {'text': '把合同模板发给王总'},
      {'text': '回去问财务账期能否缩到三十天，下周答复'},
      {'text': '先打五十台样品'},
    ], [
      {'text': '把合同模板发给王总', 'when': '下周一'},
      {'text': '答复账期能否缩到三十天', 'when': '下周'},
    ]);
    expect(out.map((a) => a['text']), ['先打五十台样品']);
  });

  test('个人感悟：单独一类，观点和演讲素材汇进观点库', () async {
    String? seen;
    final scenes = await Analyzer(lib, (s, u) async {
      if (s.contains('"scenes"')) {
        return '{"scenes":[{"start":"14:00:05","end":"14:19:35","category":"个人感悟","title":"AI 让小团队变强","place":"高铁上"}]}';
      }
      seen = s;
      return '## 触发\n看到新闻\n\n## 感悟了什么\n- **观点**：三个人能干三十个人的活\n\n## 演讲素材\n- 「工具会换，判断力不会」';
    }).run('x', {'start': '2026-10-18T14:00:05', 'lines': lines});
    expect(seen, contains('对未来的判断'));
    final store = Store(Directory('${tmp.path}/app'))..lib = lib;
    await store.putResult('x', {'start': '2026-10-18T14:00:05', 'lines': lines, 'scenes': scenes});
    expect(File('${lib.path}/个人感悟/2026-10-18 14.00 AI 让小团队变强.md').existsSync(), isTrue);
    final ideas = File('${lib.path}/个人感悟/观点库.md').readAsStringSync();
    expect(ideas, contains('2026-10-18 14:00 · 高铁上 · AI 让小团队变强'));
    expect(ideas, contains('三个人能干三十个人的活'));
    expect(ideas, contains('工具会换'));
    expect(ideas, isNot(contains('看到新闻')));
    await store.putResult('x', {'start': '2026-10-18T14:00:05', 'lines': lines, 'scenes': scenes}); // 重新整理不重复收
    expect(RegExp('三个人能干').allMatches(File('${lib.path}/个人感悟/观点库.md').readAsStringSync()).length, 1);
  });

  test('模型给了不认识的类别 / 乱写钟点也不崩', () async {
    final out = await Analyzer(lib, (s, u) async => s.contains('"scenes"')
        ? '好的：{"scenes":[{"start":"乱写","end":"99:99","category":"瞎编类","title":"x"}]}'
        : '## a\n- b').run('x', {'start': '2026-10-18T14:00:05', 'lines': lines});
    expect(out.single['category'], '多人群聊');
    expect(out.single['offset'], 0.0);
  });
}
