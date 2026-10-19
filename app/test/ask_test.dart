import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/ask.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/llm.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/templates.dart';

Scene scene(String id, String start, String title, {String body = '', List<List<String>> text = const []}) => Scene({
      'id': id, 'start': '$start:00', 'end': '${start.substring(0, 14)}59:00', 'category': '个人感悟', 'title': title,
      'event': '$title 的事件', 'body': body, 'text': text,
    }, 'stem-$id');

/// 假模型：记下收到的 messages，回一段 Markdown。
class FakeLlm extends Llm {
  final calls = <List<Map<String, String>>>[];
  FakeLlm() : super(Cloud('http://localhost'), () => {});
  @override
  Future<String> chatMessages(List<Map<String, String>> messages, {double temperature = 0.2}) async {
    calls.add(messages);
    return '# 第${calls.length}篇\n\n正文第${calls.length}段';
  }
}

void main() {
  final a = scene('a', '2026-10-20T09:00', '早上的会', body: '## 要点\n- 早会内容');
  final b = scene('b', '2026-10-20T13:00', 'AI时代的反向认知',
      body: '## 感悟了什么\n- **观点**：反向认知', text: [for (var i = 0; i < 300; i++) ['13:${(i % 60).toString().padLeft(2, '0')}:00', '逐字稿第$i句，反向认知的展开']]);
  final c = scene('c', '2026-10-20T18:00', '晚上的饭局', body: '## 话题\n- 吃饭');

  group('buildAskMessages', () {
    test('正在看的那段放最前、给完整笔记和逐字稿，其余当背景', () {
      final m = buildAskMessages(scenes: [a, b, c], focus: b, question: '把这个写成公众号文章');
      expect(m.first['role'], 'system');
      final sys = m.first['content']!;
      expect(sys, startsWith(chatPrompt));
      final at = sys.indexOf('## 我正在看的这一段');
      final bg = sys.indexOf('## 其余录音记录（背景）');
      expect(at, greaterThan(0));
      expect(bg, greaterThan(at));
      expect(sys.substring(at, bg), contains('AI时代的反向认知'));
      expect(sys.substring(at, bg), contains('逐字稿第299句')); // 逐字稿不截断
      expect(sys.substring(bg), contains('早上的会'));
      expect(sys.substring(bg), contains('晚上的饭局'));
      expect(sys.substring(bg), isNot(contains('AI时代的反向认知'))); // 不重复放
      expect(m.last, {'role': 'user', 'content': '把这个写成公众号文章'});
      expect(m.length, 2);
    });

    test('没选中时照旧放全部记录', () {
      final sys = buildAskMessages(scenes: [a, c], question: '今天干了啥').first['content']!;
      expect(sys, isNot(contains('## 我正在看的这一段')));
      expect(sys, contains('## 我的录音记录'));
      expect(sys, contains('晚上的饭局'));
    });

    test('正在看的那段超过上限才截', () {
      final sys = buildAskMessages(scenes: [b], focus: b, question: 'q', focusMax: 500).first['content']!;
      expect(sys.length, lessThan(chatPrompt.length + 600));
    });

    test('多轮：历史按顺序放在 system 后面、问题前面；太长只丢最早的轮次', () {
      final history = [for (var i = 0; i < 5; i++) Turn('问$i', '答$i ${'字' * 100}')];
      final full = buildAskMessages(scenes: [a], focus: a, history: history, question: '新问题');
      expect([for (final x in full) x['role']], ['system', for (var i = 0; i < 5; i++) ...['user', 'assistant'], 'user']);
      expect(full[1]['content'], '问0');
      expect(full[2]['content'], startsWith('答0'));

      final cut = buildAskMessages(scenes: [a], focus: a, history: history, question: '新问题', historyMax: 330);
      expect(cut.first['content'], contains('早上的会')); // system 和资料保留
      expect([for (final x in cut.skip(1)) x['content']!.split(' ').first], ['问2', '答2', '问3', '答3', '问4', '答4', '新问题']);
      expect(cut.last['content'], '新问题');
    });
  });

  testWidgets('对话区：连续追问带上下文、能拷贝、换天清空', (tester) async {
    final llm = FakeLlm();
    final store = Store(Directory.systemTemp);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'];
      return null;
    });
    Widget app(String topic, Scene? focus) => MaterialApp(
          home: Scaffold(
            body: AskBox(store: store, scenes: [a, b, c], topic: topic, focus: focus, child: const Text('时间线列表')),
          ),
        );

    await tester.pumpWidget(app('day:2026-10-20', b));
    await tester.enterText(find.byType(TextField), '把这个写成公众号文章');
    await tester.tap(find.text('问'));
    await tester.pumpAndSettle();
    expect(find.text('和小耳的对话'), findsOneWidget);
    expect(find.textContaining('第1篇'), findsOneWidget);
    expect(llm.calls.single.first['content'], contains('## 我正在看的这一段'));

    await tester.enterText(find.byType(TextField), '标题换三个备选');
    await tester.tap(find.text('问'));
    await tester.pumpAndSettle();
    final second = llm.calls[1];
    expect([for (final x in second) x['role']], ['system', 'user', 'assistant', 'user']);
    expect(second[2]['content'], contains('第1篇'));
    expect(second.last['content'], '标题换三个备选');

    await tester.tap(find.text('拷贝').last);
    await tester.pump();
    expect(copied, '# 第2篇\n\n正文第2段');
    expect(find.text('已复制'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('已复制'), findsNothing);

    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.text('和小耳的对话'), findsNothing);
    expect(find.textContaining('展开对话（2 轮）'), findsOneWidget);

    // 同一天换选中段：对话还在，下一问用新的那段
    await tester.pumpWidget(app('day:2026-10-20', c));
    await tester.enterText(find.byType(TextField), '那这段呢');
    await tester.tap(find.text('问'));
    await tester.pumpAndSettle();
    final third = llm.calls[2].first['content']!;
    expect(third.substring(third.indexOf('## 我正在看的这一段'), third.indexOf('## 其余录音记录')), contains('晚上的饭局'));
    expect(llm.calls[2].length, 6);

    // 换天：对话清空
    await tester.pumpWidget(app('day:2026-10-21', c));
    await tester.pumpAndSettle();
    expect(find.text('和小耳的对话'), findsNothing);
    expect(find.textContaining('展开对话'), findsNothing);

    // 出错写在对话里，不弹窗
    Llm.instance = _BrokenLlm();
    await tester.enterText(find.byType(TextField), '再问');
    await tester.tap(find.text('问'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没问成：网络断了'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });
}

class _BrokenLlm extends Llm {
  _BrokenLlm() : super(Cloud('http://localhost'), () => {});
  @override
  Future<String> chatMessages(List<Map<String, String>> messages, {double temperature = 0.2}) async => throw CloudError('网络断了');
}
