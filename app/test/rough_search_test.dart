import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/ask.dart';
import 'package:luyinka/search.dart';
import 'package:luyinka/store.dart';

String _day(int i) => '2026-10-${(i % 28 + 1).toString().padLeft(2, '0')}';

Scene sc(int i, String title, String event, List<String> text, {String body = ''}) => Scene({
      'id': 'id$i', 'start': '${_day(i)}T10:00:00', 'end': '${_day(i)}T10:30:00',
      'category': '多人群聊', 'title': title, 'event': event, 'body': body,
      'text': [for (final (j, t) in text.indexed) ['10:${j.toString().padLeft(2, '0')}:00', t]],
    }, 'stem$i');

void main() {
  final filler = [
    for (var i = 0; i < 20; i++)
      sc(i, '第$i次的会', '大家聊了聊工作安排和进度', [
        '那我们说一下这个事情，我觉得工作进度还可以', '然后那个模具的事情下周再说', '还有胶水的价格也要问一下', '好的就这样第$i次',
      ], body: '## 要点\n- 工作进度\n- 模具下周再说'),
  ];
  final target = sc(25, '考察组装线与产能', '实地看了组装线，聊了产能和报价', [
    '这里就是他们的组装线', '他们的良品率现在是百分之九十六', '主要问题是磁吸那块的胶不牢', '厂长说可以先打五十台样品',
  ], body: '## 关键信息\n- 日产两千台');
  final all = [...filler.sublist(0, 10), target, ...filler.sublist(10)];

  test('切词：去掉「帮我找 / 那次 / 我说过」这类虚词，中文取 2–4 字片段', () {
    final t = roughTerms('帮我找一下那次我说过磁吸的胶不牢');
    expect(t, containsAll(['磁吸', '胶不牢', '胶不']));
    expect(t, isNot(contains('帮我')));
    expect(t, isNot(contains('那次')));
    expect(t, isNot(contains('说过')));
    expect(roughTerms('那次跟 DeepSeek 聊的'), contains('deepseek'));
  });

  test('只在逐字稿里出现的细节（标题和事件里都没有）：粗筛能排进前 8，而且排第一', () {
    expect('${target.title}${target.event}${target.body}', isNot(contains('磁吸')));
    final hits = roughSearch(all, '我哪次说过磁吸那块胶不牢的事');
    expect(hits.length, lessThanOrEqualTo(8));
    expect(hits.map((h) => h.scene.id).take(8), contains('id25'));
    expect(hits.first.scene.id, 'id25');
    expect(hits.first.snippet, contains('磁吸那块的胶不牢'));
  });

  test('片段：命中处前后 150 字以内', () {
    final long = sc(30, '长的', '长的', ['${'无关的话' * 100}这里提到了磁吸胶条的问题${'后面的话' * 100}']);
    final h = roughSearch([long], '磁吸胶条').single;
    expect(h.snippet, contains('磁吸胶条'));
    expect(h.snippet.length, lessThanOrEqualTo(302));
  });

  test('对话里：原文片段附在目录后面，控制在 8000 字内', () {
    final sys = buildAskMessages(scenes: const [], all: all, question: '我哪次说过磁吸那块胶不牢', lookup: '我哪次说过磁吸那块胶不牢')
        .first['content']!;
    final at = sys.indexOf('## 可能相关的原文片段');
    expect(at, greaterThan(sys.indexOf('## 全部记录目录')));
    expect(sys.substring(at), contains('- id25 | 2026-10-26 10:00 | 考察组装线与产能'));
    expect(sys.substring(at), contains('磁吸那块的胶不牢'));
    final block = roughBlock(all, '模具 胶水 工作进度 磁吸', max: 8000);
    expect(block.length, lessThanOrEqualTo(8000));
    expect(roughBlock(all, '模具 胶水 工作进度', max: 500).length, lessThanOrEqualTo(500));
  });

  test('没有能用的词就不附', () {
    expect(roughBlock(all, '帮我找一下那次'), '');
    final sys = buildAskMessages(scenes: const [], all: all, question: '帮我找一下那次', lookup: '帮我找一下那次').first['content']!;
    expect(sys, isNot(contains('## 可能相关的原文片段')));
  });
}
