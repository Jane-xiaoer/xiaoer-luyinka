import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/ask.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/llm.dart';
import 'package:luyinka/search.dart';
import 'package:luyinka/store.dart';
import 'dart:io';

Scene scene(String id, String start,
        {String title = '', String event = '', String body = '', String cat = '个人感悟', List<String> people = const [],
        String place = '', List<List<String>> text = const []}) =>
    Scene({
      'id': id, 'start': '$start:00', 'end': '${start.substring(0, 14)}59:00', 'category': cat, 'title': title, 'event': event,
      'body': body, 'people': people, 'place': place, 'text': text,
    }, 'stem-$id');

class FoundLlm extends Llm {
  final String reply;
  final calls = <List<Map<String, String>>>[];
  FoundLlm(this.reply) : super(Cloud('http://localhost'), () => {});
  @override
  Future<String> chatMessages(List<Map<String, String>> messages, {double temperature = 0.2}) async {
    calls.add(messages);
    return reply;
  }
}

void main() {
  final wang = scene('w', '2026-10-18T16:00',
      title: '与王总谈渠道合作条件', event: '谈扣点、账期', cat: '商务洽谈', people: ['王总'], body: '## 要点\n- **扣点**暂定百分之三十');
  final ai = scene('ai', '2026-10-20T01:03',
      title: 'AI时代的反向认知', event: 'AI让市场更卷、马太效应加剧', body: '## 感悟了什么\n- 学得更多才能不被淘汰',
      text: [['01:03:10', '我觉得Matthew效应会越来越明显，市场也会更卷']]);
  final old = scene('old', '2026-10-17T10:00', title: '早会', event: '聊排期', body: '提到马太效应这个词');
  final talk = scene('t', '2026-10-19T10:00', title: '闲聊', event: '随便聊', text: [['10:00:00', '后来说到马太效应，挺有意思']]);
  final all = [ai, talk, wang, old]; // 新的在前

  group('searchScenes 匹配', () {
    test('子串、多个词 AND、忽略大小写和全半角空格', () {
      expect(searchScenes(all, '王总').map((h) => h.scene.id), ['w']);
      expect(searchScenes(all, '扣点　王总').map((h) => h.scene.id), ['w']); // 全角空格分词
      expect(searchScenes(all, '扣点 不存在的词'), isEmpty);
      expect(searchScenes(all, 'matthew').map((h) => h.scene.id), ['ai']); // 大小写
      expect(searchScenes(all, 'ＭＡＴＴＨＥＷ').map((h) => h.scene.id), ['ai']); // 全角字母
      expect(searchScenes(all, '   '), isEmpty);
    });

    test('每个字段都能搜：地点、人物、类别、调研对象、笔记、逐字稿', () {
      final s = Scene({
        'id': 'x', 'start': '2026-10-18T17:30:00', 'end': '2026-10-18T18:00:00', 'category': '现场调研', 'title': '看工厂',
        'event': '', 'place': '东莞', 'people': ['李厂长'], 'subject': '组装线', 'body': '产能每天两千台',
        'text': [['17:31:00', '这个治具是新做的']],
      }, 'stem');
      for (final q in ['东莞', '李厂长', '现场调研', '组装线', '两千台', '治具']) {
        expect(searchScenes([s], q).length, 1, reason: q);
      }
    });
  });

  test('排序：标题 / 事件命中在前，其次笔记，最后只有逐字稿；同档新的在前', () {
    final r = searchScenes(all, '马太效应');
    expect(r.map((h) => h.scene.id), ['ai', 'old', 't']);
    expect(r.map((h) => h.tier), [0, 1, 2]);
    final a = scene('a', '2026-10-01T09:00', title: '定价');
    final b = scene('b', '2026-10-05T09:00', title: '再谈定价');
    expect(searchScenes([a, b], '定价').map((h) => h.scene.id), ['b', 'a']);
  });

  group('上下文片段', () {
    test('前后约 30 字，命中词标出来，两头加省略号', () {
      final text = '${'甲' * 50}马太效应${'乙' * 50}';
      final sn = snippetOf(text, searchTerms('马太效应'));
      expect(sn.text, '…${'甲' * 30}马太效应${'乙' * 30}…');
      expect(sn.marks, [(31, 35)]);
      expect(sn.text.substring(sn.marks.first.$1, sn.marks.first.$2), '马太效应');
    });

    test('开头命中不加前省略号；多个词都标；大小写不同也标原文', () {
      final sn = snippetOf('AI让市场更卷，ai 也让马太效应加剧', searchTerms('ai 马太'));
      expect(sn.text, 'AI让市场更卷，ai 也让马太效应加剧');
      expect([for (final (a, b) in sn.marks) sn.text.substring(a, b)], ['AI', 'ai', '马太']);
    });

    test('搜索结果的片段来自笔记 / 逐字稿，Markdown 记号去掉', () {
      final h = searchScenes([wang], '扣点').single;
      expect(h.snippet.text, contains('扣点暂定百分之三十'));
      expect(h.snippet.text, isNot(contains('**')));
      final t = searchScenes(all, '挺有意思').single;
      expect(t.snippet.text, contains('后来说到马太效应，挺有意思'));
    });
  });

  group('parseFound', () {
    test('拆出 id、去掉那一行', () {
      final (clean, ids) = parseFound('是 10/20 那段「AI时代的反向认知」。\n\n[[找到: ai, w]]');
      expect(clean, '是 10/20 那段「AI时代的反向认知」。');
      expect(ids, ['ai', 'w']);
    });

    test('全角冒号、中文逗号、反引号包着、重复、超过 5 个', () {
      final (clean, ids) = parseFound('说明\n`[[找到：a，b、a, c d e f g]]`\n');
      expect(clean, '说明');
      expect(ids, ['a', 'b', 'c', 'd', 'e']);
    });

    test('没有这一行就原样返回', () {
      final (clean, ids) = parseFound('# 文章\n\n正文');
      expect(clean, '# 文章\n\n正文');
      expect(ids, isEmpty);
    });
  });

  group('全部记录目录', () {
    test('一段一行：id | 日期 钟点 | 类别 | 标题 | 事件 | 人物 | 地点，不带笔记和逐字稿', () {
      final c = catalogBlock(all);
      expect(c.split('\n').first, 'ai | 2026-10-20 01:03 | 个人感悟 | AI时代的反向认知 | AI让市场更卷、马太效应加剧 |  | ');
      expect(c, contains('w | 2026-10-18 16:00 | 商务洽谈 | 与王总谈渠道合作条件 | 谈扣点、账期 | 王总 | '));
      expect(c, isNot(contains('学得更多')));
      expect(c, isNot(contains('Matthew')));
    });

    test('太长只留最近的', () {
      final c = catalogBlock(all, max: 120);
      expect(c, contains('ai |'));
      expect(c, isNot(contains('old |')));
      expect(c.length, lessThanOrEqualTo(120));
    });

    test('拼进 system，提示词里有找记录的规矩', () {
      final sys = buildAskMessages(scenes: [old], all: all, question: '帮我找').first['content']!;
      expect(sys, contains('## 全部记录目录'));
      expect(sys, contains('[[找到: id1, id2]]'));
      expect(sys.substring(sys.indexOf('## 全部记录目录')), contains('与王总谈渠道合作条件'));
    });
  });

  testWidgets('对话里找到的段：显示成卡片、不显示 [[找到]]、拷贝不带、点了打开', (tester) async {
    final llm = FoundLlm('应该是 10/20 凌晨那段。\n\n[[找到: ai, 不存在, w]]');
    String? copied;
    Scene? opened;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'];
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AskBox(
          store: Store(Directory.systemTemp), scenes: [old], all: all, topic: 'day:2026-10-17',
          onOpen: (s) => opened = s, child: const Text('列表'),
        ),
      ),
    ));
    await tester.enterText(find.byType(TextField), '我说过马太效应那段，帮我找出来');
    await tester.tap(find.text('问'));
    await tester.pumpAndSettle();
    expect(llm.calls.single.first['content'], contains('## 全部记录目录'));
    expect(find.textContaining('[[找到'), findsNothing);
    expect(find.byType(FoundCard), findsNWidgets(2)); // 不存在的 id 忽略
    expect(find.widgetWithText(FoundCard, 'AI时代的反向认知'), findsOneWidget);
    expect(find.widgetWithText(FoundCard, '10/20 01:03'), findsOneWidget);

    await tester.tap(find.text('拷贝'));
    await tester.pump();
    expect(copied, '应该是 10/20 凌晨那段。');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FoundCard, 'AI时代的反向认知'));
    await tester.pump();
    expect(opened?.id, 'ai');
  });

  testWidgets('点了找到的卡片跳到别的日子，对话不清空', (tester) async {
    FoundLlm('就是这段\n[[找到: ai]]');
    final key = GlobalKey();
    Widget app(String topic) => MaterialApp(
          home: Scaffold(
            body: AskBox(key: key, store: Store(Directory.systemTemp), scenes: const [], all: all, topic: topic,
                onOpen: (_) {}, child: const SizedBox()),
          ),
        );
    await tester.pumpWidget(app('day:2026-10-17'));
    await tester.enterText(find.byType(TextField), '帮我找');
    await tester.tap(find.text('问'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FoundCard));
    await tester.pumpWidget(app('day:2026-10-20'));
    await tester.pumpAndSettle();
    expect(find.text('和小耳的对话'), findsOneWidget);
    // 自己换天还是清空
    await tester.pumpWidget(app('day:2026-10-18'));
    await tester.pumpAndSettle();
    expect(find.text('和小耳的对话'), findsNothing);
  });

  testWidgets('搜索结果：片段高亮、点一条打开、搜不到提示问小耳', (tester) async {
    Scene? picked;
    final store = Store(Directory.systemTemp);
    Widget app(String q) => MaterialApp(
          home: Scaffold(
            body: SearchColumn(store: store, hits: searchScenes(all, q), scenes: const [], topic: 'day:x', selected: null,
                onPick: (s) => picked = s),
          ),
        );
    await tester.pumpWidget(app('马太效应'));
    expect(find.text('找到 3 段'), findsOneWidget);
    expect(find.byType(SnippetText), findsNWidgets(3));
    final rich = tester.widget<Text>(find.descendant(of: find.byType(SnippetText).first, matching: find.byType(Text)));
    final hl = (rich.textSpan as TextSpan).children!.cast<TextSpan>().where((s) => s.style?.color != null).map((s) => s.text);
    expect(hl, contains('马太效应'));
    await tester.tap(find.text('早会'));
    expect(picked?.id, 'old');

    await tester.pumpWidget(app('根本没有这个词'));
    expect(find.text('没找到，试试在下面问小耳'), findsOneWidget);
  });

  testWidgets('搜索框：Esc 清空', (tester) async {
    final c = TextEditingController(text: '王总');
    var cleared = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SearchField(controller: c, onChanged: (_) {}, onClear: () => cleared++)),
    ));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(cleared, 1);
    await tester.tap(find.byTooltip('清空搜索'));
    expect(cleared, 2);
  });
}
