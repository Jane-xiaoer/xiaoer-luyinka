import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/analyze.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/templates.dart';

Map<String, dynamic> raw(int w, double a, double b, String cat, {List<String> people = const [], String title = ''}) => {
      '_w': w, '_a': a, '_b': b, 'category': cat, 'title': title.isEmpty ? cat : title, 'event': '$cat 的事',
      'people': people, 'actions': [{'text': '发方案给董老师'}], 'reminders': [],
    };

List<String> line(String t, String s) => [t, s];

void main() {
  group('切场景规则', () {
    test('cutPrompt 按场合切，不按话题切；会上讲方案不算我的分享', () {
      final p = cutPrompt(const []);
      expect(p, contains('按「场合」'));
      expect(p, contains('不按话题切'));
      expect(p, contains('话题变了不是切开的理由'));
      expect(p, contains('不要单独切成「我的分享」'));
      expect(p, contains('停顿 10 分钟以上'));
      expect(p, contains('1–3 个场景'));
      expect(p, isNot(contains('按话题把它切成')));
      expect(cats.firstWhere((c) => c.key == '我的分享').hint, contains('开会时我讲方案'));
    });

    test('开会模板有「主讲与汇报」小节（没有就省）', () {
      expect(defaultTemplates['开会'], contains('## 主讲与汇报'));
      expect(defaultTemplates['开会'], contains('没人主讲就整节省掉'));
    });

    test('用户没改过的旧版开会模板会换成新的，改过的不动', () async {
      final tmp = await Directory.systemTemp.createTemp('tpl');
      final lib = Library(Directory('${tmp.path}/资料'));
      await lib.templateFile('开会').parent.create(recursive: true);
      await lib.templateFile('开会').writeAsString('${legacyTemplates['开会']!.first}\n');
      await lib.templateFile('打电话').writeAsString('我自己改的');
      await lib.ensure();
      expect(await lib.template('开会'), contains('## 主讲与汇报'));
      expect(await lib.template('打电话'), '我自己改的');
      await lib.templateFile('开会').writeAsString('只写一句话');
      await lib.ensure();
      expect(await lib.template('开会'), '只写一句话');
      await tmp.delete(recursive: true);
    });
  });

  group('窗口边界合并', () {
    test('边界两边是同一场合（开会 / 我的分享、人物有交集、时间接得上）就合成一段', () {
      final out = joinWindows([
        raw(0, 0, 900, '我的分享', people: ['董老师'], title: '讲 VI 方案'),
        raw(1, 905, 1500, '开会', people: ['董老师', '刘康'], title: '方案反馈'),
      ]);
      expect(out, hasLength(1));
      expect(out.single['category'], '开会');
      expect(out.single['title'], '方案反馈');
      expect(out.single['_a'], 0);
      expect(out.single['_b'], 1500);
      expect(out.single['people'], ['董老师', '刘康']);
      expect(out.single['actions'], hasLength(2)); // 去重在 run 里做
    });

    test('一场会跨了三窗也连成一段', () {
      final out = joinWindows([
        raw(0, 0, 900, '开会', people: ['董老师']),
        raw(1, 905, 1800, '开会'),
        raw(2, 1810, 2400, '开会', people: ['董老师']),
      ]);
      expect(out.single['_b'], 2400);
    });

    test('场合不同 / 隔太久 / 人对不上 / 同一窗里的 / 杂音：不合', () {
      expect(joinWindows([raw(0, 0, 900, '开会'), raw(1, 905, 1500, '商务洽谈')]), hasLength(2));
      expect(joinWindows([raw(0, 0, 900, '开会'), raw(1, 1300, 1500, '开会')]), hasLength(2));
      expect(joinWindows([raw(0, 0, 900, '开会', people: ['王总']), raw(1, 905, 1500, '开会', people: ['李总'])]), hasLength(2));
      expect(joinWindows([raw(0, 0, 400, '开会'), raw(0, 405, 900, '开会')]), hasLength(2));
      expect(joinWindows([raw(0, 0, 900, '杂音'), raw(1, 905, 1500, '杂音')]), hasLength(2));
    });

    test('Analyzer.run：两窗切出来的同一场会合成一段，待办去重', () async {
      final tmp = await Directory.systemTemp.createTemp('join');
      final lib = Library(Directory('${tmp.path}/资料'));
      await lib.ensure();
      final lines = [
        for (var i = 0; i < 60; i++)
          line('19:${(1 + i ~/ 4).toString().padLeft(2, '0')}:${((i % 4) * 15).toString().padLeft(2, '0')}', '品牌 VI 和展厅方案，第$i句。' * 8),
      ];
      expect(windows(lines).length, greaterThan(1));
      var calls = 0;
      final scenes = await Analyzer(lib, (s, u) async {
        if (!s.contains('"scenes"')) return '## 会议概要\n好';
        final first = u.split('\n').first.substring(1, 9), last = u.split('\n').last.substring(1, 9);
        calls++;
        return jsonEncode({
          'scenes': [
            {'start': first, 'end': last, 'category': calls == 1 ? '我的分享' : '开会', 'title': calls == 1 ? '讲方案' : '方案讨论',
             'people': ['董老师'], 'actions': [{'text': '把 VI 方案发给董老师', 'who': '我'}]},
          ]
        });
      }).run('note20261020-190156', {'start': '2026-10-20T19:01:00', 'lines': lines});
      expect(calls, windows(lines).length);
      expect(scenes, hasLength(1));
      expect(scenes.single['category'], '开会');
      expect(scenes.single['start'], '2026-10-20T19:01:00');
      expect((scenes.single['text'] as List).length, 60);
      expect(scenes.single['actions'], hasLength(1));
      await tmp.delete(recursive: true);
    });
  });

  test('模型没提录音后面那一大截杂音：单独成杂音段，开会不会一直算到录音结束', () async {
    final tmp = await Directory.systemTemp.createTemp('tail');
    final lib = Library(Directory('${tmp.path}/资料'));
    await lib.ensure();
    final lines = [
      for (var i = 0; i < 10; i++) line('19:0${i ~/ 2}:${i.isEven ? '00' : '30'}', '方案和分工，第$i句。' * 5),
      line('19:36:16', '嗯是。'),
      line('20:04:09', '。'),
    ];
    final scenes = await Analyzer(lib, (s, u) async => s.contains('"scenes"')
        ? '{"scenes":[{"start":"19:00:00","end":"19:04:30","category":"开会","title":"方案会","event":"讲方案。"}]}'
        : '## 会议概要\n好').run('x', {'start': '2026-10-20T19:00:00', 'seconds': 4883.8, 'lines': lines});
    expect(scenes.map((s) => s['category']), ['开会', '杂音']);
    expect(scenes[0]['end'], '2026-10-20T19:04:30');
    expect((scenes[0]['text'] as List).length, 10);
    expect(scenes[1]['start'], '2026-10-20T19:36:16');
    expect(scenes[1]['end'], '2026-10-20T20:21:24');
    expect(scenes[1]['body'], '');

    // 隔得不久（最后一句的话尾）：照旧算进最后一段、算到录音结束
    final near = await Analyzer(lib, (s, u) async => s.contains('"scenes"')
        ? '{"scenes":[{"start":"19:00:00","end":"19:04:00","category":"开会","title":"方案会"}]}'
        : '## 会议概要\n好').run('y', {'start': '2026-10-20T19:00:00', 'seconds': 300.0, 'lines': lines.take(10).toList()});
    expect(near.single['end'], '2026-10-20T19:05:00');
    await tmp.delete(recursive: true);
  });

  test('合并后的事件：去掉重复的句号再接', () {
    final m = mergeScenes([
      {'id': 'a', 'start': '2026-10-20T19:00:00', 'end': '2026-10-20T19:10:00', 'category': '开会', 'event': '讲方案。'},
      {'id': 'b', 'start': '2026-10-20T19:10:00', 'end': '2026-10-20T19:20:00', 'category': '开会', 'event': '定分工。'},
    ]);
    expect(m['event'], '讲方案；定分工。');
  });

  group('手动合并', () {
    late Directory tmp;
    late Library lib;
    late Store store;
    const stem = 'note20261020-190156';
    final t1 = [line('19:01:57', '我先讲一下品牌 VI 的方案'), line('19:10:00', '展厅这边分三个区')];
    final t2 = [line('19:17:16', '董老师觉得配色要再亮一点'), line('19:20:00', '刘康负责展厅施工图')];
    final t3 = [line('19:23:21', '那就按这个定稿')];
    final t4 = [line('19:36:16', '（电视声）')];

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('merge');
      lib = Library(Directory('${tmp.path}/资料'));
      await lib.ensure();
      store = Store(Directory('${tmp.path}/app'))..lib = lib;
      await store.putResult(stem, {
        'start': '2026-10-20T19:01:56',
        'lines': [...t1, ...t2, ...t3, ...t4],
        'scenes': [
          {'id': 'a', 'start': '2026-10-20T19:01:57', 'end': '2026-10-20T19:17:06', 'offset': 1.0, 'category': '我的分享',
           'title': '品牌VI提案讲解', 'event': '讲 VI 和展厅方案。', 'people': ['小冉老师', '董老师'], 'text': t1, 'body': '## 我讲了什么\n旧',
           'actions': [{'text': '把 VI 方案发给董老师', 'who': '我', 'done': true}], 'reminders': []},
          {'id': 'b', 'start': '2026-10-20T19:17:16', 'end': '2026-10-20T19:23:02', 'offset': 920.0, 'category': '开会',
           'title': 'VI方案反馈与分工', 'event': '反馈并分工。', 'people': ['董老师', '刘康'], 'text': t2, 'body': '## 会议概要\n旧',
           'actions': [{'text': '把VI方案发给董老师', 'who': ''}, {'text': '出展厅施工图', 'who': '刘康'}],
           'reminders': [{'text': '周五前交施工图', 'when': '周五'}]},
          {'id': 'c', 'start': '2026-10-20T19:23:21', 'end': '2026-10-20T19:26:04', 'offset': 1285.0, 'category': '开会',
           'title': '定稿讨论', 'event': '定稿。', 'people': ['陈总'], 'text': t3, 'body': '## 会议概要\n旧'},
          {'id': 'd', 'start': '2026-10-20T19:36:16', 'end': '2026-10-20T20:23:20', 'offset': 2060.0, 'category': '杂音',
           'title': '无有效内容', 'text': t4},
        ],
      });
    });
    tearDown(() => tmp.delete(recursive: true));

    Future<String> note(Scene s) async => '## 会议概要\n合并后（${s.category}）\n\n## 主讲与汇报\n### 我：VI 方案';

    test('跟上一段合并：时间 / 人物 / 待办 / 逐字稿合起来，旧文件换成新文件', () async {
      final b = store.scenes.firstWhere((s) => s.id == 'b');
      expect(store.previousOf(b)!.id, 'a');
      final m = await store.mergeWithPrevious(b, note);
      expect(m.id, 'a');
      expect(m.category, '开会'); // 我的分享 + 开会 → 开会
      expect(m.title, 'VI方案反馈与分工');
      expect(m.d['start'], '2026-10-20T19:01:57');
      expect(m.d['end'], '2026-10-20T19:23:02');
      expect(m.offset, 1.0);
      expect(m.people, ['小冉老师', '董老师', '刘康']);
      expect(m.actions.map((a) => a['text']), ['把 VI 方案发给董老师', '出展厅施工图']);
      expect(m.actions.first['done'], true); // 打过的勾带着
      expect(m.reminders.single['text'], '周五前交施工图');
      expect(m.text, [...t1, ...t2]);
      expect(m.body, contains('合并后（开会）'));

      expect(File('${lib.path}/我的分享/2026-10-20 19.01 品牌VI提案讲解.md').existsSync(), isFalse);
      expect(File('${lib.path}/会议纪要/2026-10-20 19.17 VI方案反馈与分工.md').existsSync(), isFalse);
      final f = File('${lib.path}/会议纪要/2026-10-20 19.01 VI方案反馈与分工.md');
      expect(f.readAsStringSync(), contains('19:01–19:23'));
      expect(f.readAsStringSync(), contains('展厅这边分三个区'));
      expect(File('${lib.path}/会议纪要/2026-10-20 19.23 定稿讨论.md').existsSync(), isTrue);

      final idx = store.readResult(stem)!['scenes'] as List;
      expect([for (final s in idx) s['id']], ['a', 'c', 'd']);
      final day = File('${lib.path}/每日/2026-10-20.md').readAsStringSync();
      expect(day, contains('19:01–19:23** [开会] VI方案反馈与分工'));
      expect(day, isNot(contains('品牌VI提案讲解')));
      expect(store.scenes.map((s) => s.id), ['c', 'a']);
    });

    test('整条录音当一段：所有非杂音段合一，后面的杂音留着', () async {
      final m = await store.mergeRecording(stem, note);
      expect(m.d['end'], '2026-10-20T19:26:04');
      expect(m.people, ['小冉老师', '董老师', '刘康', '陈总']);
      expect(m.text, [...t1, ...t2, ...t3]);
      expect(store.scenes.single.id, 'a');
      expect(store.scenesOf(stem).map((s) => s.id), ['a', 'd']);
      final files = Directory('${lib.path}/会议纪要').listSync().map((f) => f.uri.pathSegments.last).toList();
      expect(files, ['2026-10-20 19.01 VI方案反馈与分工.md']);
      expect(Directory('${lib.path}/我的分享').listSync(), isEmpty);
    });

    test('整理失败：几段原样不动，文件不动', () async {
      final b = store.scenes.firstWhere((s) => s.id == 'b');
      await expectLater(store.mergeWithPrevious(b, (_) async => throw Exception('网断了')), throwsException);
      expect(store.scenesOf(stem).map((s) => s.id), ['a', 'b', 'c', 'd']);
      expect(store.scenesOf(stem).first.category, '我的分享');
      expect(store.scenesOf(stem).first.text, t1);
      expect(File('${lib.path}/我的分享/2026-10-20 19.01 品牌VI提案讲解.md').existsSync(), isTrue);
      expect((store.readResult(stem)!['scenes'] as List).length, 4);
    });

    test('第一段没有上一段；感悟并进会里，观点库里拿掉', () async {
      expect(store.previousOf(store.scenes.firstWhere((s) => s.id == 'a')), isNull);
      final c = store.scenes.firstWhere((s) => s.id == 'c');
      await store.changeCategory(c, '个人感悟', (_) async => '## 感悟了什么\n- **观点**：定稿要快');
      expect(lib.ideasFile.readAsStringSync(), contains('定稿要快'));
      await store.mergeWithPrevious(store.scenes.firstWhere((s) => s.id == 'c'), note);
      expect(lib.ideasFile.readAsStringSync(), isNot(contains('定稿要快')));
    });

    test('重新切分换了一批段：旧的笔记文件删掉', () async {
      final res = store.readResult(stem)!;
      res['scenes'] = [
        {'id': 'n', 'start': '2026-10-20T19:01:57', 'end': '2026-10-20T19:26:04', 'category': '开会', 'title': '品牌VI方案会',
         'text': [...t1, ...t2, ...t3], 'body': '## 会议概要\n新'},
      ];
      await store.putResult(stem, res);
      expect(Directory('${lib.path}/会议纪要').listSync().map((f) => f.uri.pathSegments.last), ['2026-10-20 19.01 品牌VI方案会.md']);
      expect(Directory('${lib.path}/我的分享').listSync(), isEmpty);
    });
  });
}
