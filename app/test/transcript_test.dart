// 逐字稿拼成纯文字（拷贝用）：一段纯文字 / 带时间 / 整条录音按段排序 / 空逐字稿。
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/transcript.dart';

Scene sc(String id, String start, String title, List<List<String>> text, {String stem = 'rec1'}) =>
    Scene({'id': id, 'start': start, 'end': start, 'category': '开会', 'title': title, 'text': text}, stem);

void main() {
  final a = sc('a', '2026-10-17T09:00:00', '周会', [
    ['09:00:05', '大家好 '],
    ['09:00:12', ''],
    ['09:01', '开始吧'],
  ]);
  final b = sc('b', '2026-10-17T09:30:00', '复盘', [
    ['09:30:01', '说说上周'],
  ]);
  final empty = sc('c', '2026-10-17T09:20:00', '杂音', []);

  test('纯文字：一行一句，不带时间，空行跳过', () {
    expect(transcriptText(a), '大家好\n开始吧');
  });

  test('带时间：每行前面 [HH:MM:SS]，只有时分的补 :00', () {
    expect(transcriptText(a, times: true), '[09:00:05] 大家好\n[09:01:00] 开始吧');
  });

  test('整条录音：按开始时间排，每段「## HH:MM 标题」，没字的段跳过', () {
    expect(recordingTranscript([b, empty, a]), '## 09:00 周会\n\n大家好\n开始吧\n\n## 09:30 复盘\n\n说说上周');
    expect(recordingTranscript([b, a], times: true), contains('## 09:30 复盘\n\n[09:30:01] 说说上周'));
  });

  test('空逐字稿：都是空串，字数 0', () {
    expect(transcriptText(empty), '');
    expect(transcriptText(empty, times: true), '');
    expect(recordingTranscript([empty]), '');
    expect(recordingTranscript([]), '');
    expect(transcriptChars(''), 0);
    expect(transcriptChars('大家好\n开始 吧'), 6);
  });
}
