import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/ask.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/drafts.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/llm.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/templates.dart';

class FakeLlm extends Llm {
  final calls = <List<Map<String, String>>>[];
  final String reply;
  FakeLlm(this.reply) : super(Cloud('http://localhost'), () => {});
  @override
  Future<String> chatMessages(List<Map<String, String>> messages, {double temperature = 0.2}) async {
    calls.add(messages);
    return reply;
  }
}

void main() {
  late Directory tmp;
  late Library lib;
  late Scene ai;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('drafts');
    lib = Library(Directory('${tmp.path}/资料'));
    await lib.ensure();
    ai = Scene({
      'id': 'ai', 'start': '2026-10-20T01:03:10', 'end': '2026-10-20T01:20:00', 'category': '个人感悟',
      'title': 'AI时代的反向认知', 'event': '凌晨一个人说对 AI 的看法', 'body': '## 感悟了什么\n- **观点**：反向认知',
      'file': '${lib.path}/个人感悟/2026-10-20 01.03 AI时代的反向认知.md',
    }, 'voice20261020-010310');
  });
  tearDown(() => tmp.delete(recursive: true));

  group('存成稿', () {
    test('标题：取第一个「# 」标题；没有就取要求的前 16 字', () {
      expect(draftTitle('前言\n\n# **反向认知**：AI 时代\n\n## 一\n正文', '写成公众号文章'), '反向认知：AI 时代');
      expect(draftTitle('## 小标题\n正文', '把这段写成一条朋友圈，200 字以内，口语一点'), '把这段写成一条朋友圈，200 字');
      expect(draftTitle('正文', '  标题换三个\n备选 '), '标题换三个 备选');
    });

    test('文件名、元信息、来源链接；重名加 (2)', () {
      final at = DateTime(2026, 10, 19, 14, 5);
      const answer = '# AI 时代，反着想\n\n## 一\n正文';
      final f = saveDraft(lib, answer: answer, request: '写成公众号文章', source: ai, at: at);
      expect(f.path, '${lib.path}/成稿/2026-10-19 14.05 AI 时代，反着想.md');
      final md = f.readAsStringSync();
      expect(md, startsWith('> 生成时间：2026-10-19 14:05\n> 我的要求：写成公众号文章\n'));
      expect(md, contains('> 来源：2026-10-20 01:03 · 个人感悟 · AI时代的反向认知 · [来源](<../个人感悟/2026-10-20 01.03 AI时代的反向认知.md>)'));
      expect(md, endsWith('\n\n$answer\n'));

      final f2 = saveDraft(lib, answer: answer, request: '写成公众号文章', source: ai, at: at);
      final f3 = saveDraft(lib, answer: answer, request: '写成公众号文章', source: ai, at: at);
      expect(f2.path, endsWith('/成稿/2026-10-19 14.05 AI 时代，反着想 (2).md'));
      expect(f3.path, endsWith('/成稿/2026-10-19 14.05 AI 时代，反着想 (3).md'));
      expect(f.readAsStringSync(), md); // 原来那份没被覆盖
    });

    test('文件名里的非法字符去掉；没选中段也能存；多行要求压成一行', () {
      final f = saveDraft(lib, answer: '没有标题的正文', request: '整理一下：A/B 方案?\n给我看', at: DateTime(2026, 10, 19, 9, 0));
      expect(f.uri.pathSegments.last, '2026-10-19 09.00 整理一下：AB 方案 给我看.md');
      final md = f.readAsStringSync();
      expect(md, contains('> 我的要求：整理一下：A/B 方案? 给我看\n'));
      expect(md, contains('> 来源：（当时没选中具体哪一段）'));
    });

    test('列出成稿新的在前，能按标题和正文搜', () {
      saveDraft(lib, answer: '# 旧的一篇\n讲马太效应', request: 'q', at: DateTime(2026, 10, 18, 8, 0));
      saveDraft(lib, answer: '# 反向认知\n正文里有清迈', request: 'q', at: DateTime(2026, 10, 19, 8, 0));
      File('${lib.path}/成稿/.DS_Store').writeAsStringSync('x');
      final l = listDrafts(lib);
      expect([for (final d in l) d.title], ['反向认知', '旧的一篇']);
      expect(l.first.when, '2026-10-19 08:00');
      expect(l.first.body, startsWith('# 反向认知'));
      expect([for (final h in searchDrafts(l, '马太')) h.draft.title], ['旧的一篇']);
      expect([for (final h in searchDrafts(l, '清迈')) h.draft.title], ['反向认知']);
      expect(searchDrafts(l, '清迈').single.snippet.marks, isNotEmpty);
      expect(searchDrafts(l, '没有这个词'), isEmpty);
    });

    test('ensure 建好 成稿/、一键按钮.md、我的写作风格.md；说明.md 写上成稿', () {
      expect(Directory('${lib.path}/成稿').existsSync(), isTrue);
      expect(lib.quickActionsFile.readAsStringSync(), quickActionsMd(quickActions));
      expect(lib.styleFile.readAsStringSync(), defaultStyle);
      expect(File('${lib.path}/说明.md').readAsStringSync(), contains('成稿/'));
    });

    test('已有的 说明.md / 一键按钮.md / 写作风格不覆盖', () async {
      File('${lib.path}/说明.md').writeAsStringSync('我自己的说明');
      lib.styleFile.writeAsStringSync('我自己的风格');
      lib.quickActionsFile.writeAsStringSync('## 开会\n- 只要结论：一句话说结论');
      await lib.ensure();
      expect(File('${lib.path}/说明.md').readAsStringSync(), '我自己的说明');
      expect(lib.styleFile.readAsStringSync(), '我自己的风格');
      expect(lib.quickActionsFile.readAsStringSync(), contains('只要结论'));
    });
  });

  group('一键按钮表', () {
    test('默认表：每个要求的类别都有按钮，要求写清体裁和长度', () {
      for (final c in ['个人感悟', '我的分享', '开会', '商务洽谈', '现场调研', '听课讲座', '多人群聊', '打电话', '自言自语']) {
        expect(quickActions[c], isNotEmpty, reason: c);
      }
      expect([for (final a in quickActions['个人感悟']!) a.$1], ['写成公众号文章', '写成朋友圈', '写成 3 分钟演讲稿']);
      expect(quickActions['个人感悟']![0].$2, allOf(contains('1500–2500 字'), contains('标题'), contains('小标题')));
      expect(quickActions['个人感悟']![1].$2, allOf(contains('200 字以内'), contains('不用 Markdown 标题')));
      for (final l in quickActions.values) {
        for (final (_, ask) in l) {
          expect(ask, isNot(contains('\n'))); // 文件里一行一个
        }
      }
    });

    test('写成文件再读回来一模一样', () {
      expect(parseQuickActions(quickActionsMd(quickActions)), quickActions);
    });

    test('用户改过就按改过的来：增删改、类别写文件夹名也认、英文冒号也认', () {
      lib.quickActionsFile.writeAsStringSync('''# 一键按钮
> 说明

## 会议纪要
- 只要结论：一句话说结论
- 发老板: 写给老板看的三行汇报

## 个人感悟
- 写成小红书：写成小红书笔记，500 字
这行不是按钮，忽略
''');
      final t = lib.quickActionsTable();
      expect(t.keys, ['开会', '个人感悟']);
      expect(t['开会'], [('只要结论', '一句话说结论'), ('发老板', '写给老板看的三行汇报')]);
      expect(t['个人感悟'], [('写成小红书', '写成小红书笔记，500 字')]);
      expect(t['商务洽谈'], isNull); // 删掉的类别就没有按钮
    });

    test('写坏了（一个按钮都认不出来）、空文件、文件没了：用默认表', () {
      expect(parseQuickActions('随便写的一段话\n- 没有类别的按钮：要求'), isNull);
      expect(parseQuickActions('## 开会\n没有按钮'), isNull);
      expect(parseQuickActions(''), isNull);
      lib.quickActionsFile.writeAsStringSync('乱七八糟 ### --- ：：');
      expect(lib.quickActionsTable(), quickActions);
      lib.quickActionsFile.deleteSync();
      expect(lib.quickActionsTable(), quickActions);
    });
  });

  group('我的写作风格', () {
    test('默认文件只有说明 = 没内容，不进提示词', () {
      expect(cleanStyle(defaultStyle), '');
      expect(lib.writingStyle(), '');
      final sys = buildAskMessages(scenes: [ai], focus: ai, question: 'q', style: lib.writingStyle()).first['content']!;
      expect(sys, isNot(contains('## 我的写作风格')));
      expect(sys, startsWith('$chatPrompt\n\n## 我正在看的这一段'));
    });

    test('写了内容就放进系统提示词（在资料前面），最多 6000 字', () {
      lib.styleFile.writeAsStringSync('$defaultStyle\n句子短。一两句一段。\n不说「说实话」。');
      expect(lib.writingStyle(), '句子短。一两句一段。\n不说「说实话」。');
      final sys = buildAskMessages(scenes: [ai], focus: ai, question: 'q', style: lib.writingStyle()).first['content']!;
      final at = sys.indexOf('## 我的写作风格（写文章 / 朋友圈 / 演讲稿等创作时照这个写；回答事实问题时不用管）\n句子短。');
      expect(at, greaterThan(0));
      expect(sys.indexOf('## 我正在看的这一段'), greaterThan(at));
      expect(sys, isNot(contains('以「>」开头的说明行')));

      lib.styleFile.writeAsStringSync('风' * 9000);
      expect(lib.writingStyle().length, 6000);
      expect(styleBlock('格' * 9000), contains('格' * 6000));
      expect(styleBlock('格' * 9000), isNot(contains('格' * 6001)));
      expect(styleBlock('  \n '), '');
    });
  });

  testWidgets('一键按钮发出要求；存成稿 → 已存 ✓；带上写作风格', (tester) async {
    final llm = FakeLlm('# 反着想\n\n## 一\n正文');
    final store = Store(Directory('${tmp.path}/app'))..lib = lib;
    lib.styleFile.writeAsStringSync('$defaultStyle\n句子短。');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    final key = GlobalKey<AskBoxState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          Expanded(child: AskBox(key: key, store: store, scenes: [ai], topic: 'day:2026-10-20', child: const Text('列表'))),
          Expanded(child: QuickBar(scene: ai, store: store, onQuick: (s, l, p) => key.currentState!.quick(s, l, p))),
        ]),
      ),
    ));
    expect(find.text('写成公众号文章'), findsOneWidget);
    expect(find.text('写成朋友圈'), findsOneWidget);
    await tester.tap(find.text('写成公众号文章'));
    await tester.pumpAndSettle();

    final sent = llm.calls.single;
    expect(sent.last['content'], quickActions['个人感悟']![0].$2); // 发给模型的是完整要求
    expect(sent.first['content'], contains('## 我的写作风格'));
    expect(sent.first['content'], contains('句子短。'));
    expect(sent.first['content'], contains('- 标题：AI时代的反向认知')); // 这段当正在看的
    expect(find.text('和小耳的对话'), findsOneWidget);
    expect(find.widgetWithText(Container, '写成公众号文章'), findsWidgets); // 对话里显示按钮名

    await tester.tap(find.text('存成稿'));
    await tester.pump();
    expect(find.text('已存 ✓'), findsOneWidget);
    final l = store.drafts;
    expect(l.single.title, '反着想');
    expect(l.single.md, contains('> 我的要求：写成公众号文章'));
    expect(l.single.md, contains('[来源](<../个人感悟/2026-10-20 01.03 AI时代的反向认知.md>)'));

    // 追问：历史里放的是完整要求
    await tester.enterText(find.byType(TextField), '标题换三个');
    await tester.tap(find.text('问'));
    await tester.pumpAndSettle();
    expect(llm.calls[1][1]['content'], quickActions['个人感悟']![0].$2);
    expect(find.text('存成稿'), findsOneWidget); // 新回答还没存
  });
  testWidgets('右栏：拿去用按钮在标题和事件下面、笔记卡片上面；窄屏换行', (tester) async {
    final store = Store(Directory('${tmp.path}/app'))..lib = lib;
    final player = Player();
    addTearDown(player.dispose);
    final body = '## 感悟了什么\n${List.generate(80, (i) => '- 第$i条很长的笔记').join('\n')}';
    final s = Scene({...ai.d, 'body': body}, ai.stem);
    String? got;
    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SceneDetail(scene: s, player: player, store: store, onQuick: (_, l, _) => got = l)),
    ));
    final bar = find.byType(QuickBar);
    expect(bar, findsOneWidget); // 第一屏就有，不用滚
    final barTop = tester.getTopLeft(bar).dy;
    expect(barTop, greaterThan(tester.getBottomLeft(find.text(s.event)).dy - 1));
    expect(barTop, lessThan(tester.getTopLeft(find.byType(NoteCard)).dy));
    expect(tester.getBottomLeft(bar).dy, lessThan(700));
    final b1 = tester.getTopLeft(find.text('写成公众号文章')).dy, b3 = tester.getTopLeft(find.text('写成 3 分钟演讲稿')).dy;
    expect(b3, greaterThan(b1)); // 360 宽放不下一排，换行了
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('写成朋友圈'));
    expect(got, '写成朋友圈');
  });
}
