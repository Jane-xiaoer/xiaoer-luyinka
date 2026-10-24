// 被停顿切碎的半句话接成一整句；离得远、换了人、太长就不接。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/live.dart';

DateTime t(double s) => DateTime(2026, 10, 24, 15).add(Duration(milliseconds: (s * 1000).round()));
final me = Float32List.fromList([1, 0.1]), other = Float32List.fromList([0.1, 1]);
LiveLine seg(double a, double b, String text, {String? who, bool auto = true, Float32List? emb}) =>
    LiveLine(t(a), text, end: t(b), speaker: who, auto: auto, emb: emb ?? me);
String? nobody(Float32List _) => null;

void main() {
  test('隔得近：接成一句，前一段的句号换逗号', () {
    final j = joinLines(seg(0, 1.2, '可以继续。'), seg(2.0, 2.8, '去编辑。'), nobody)!;
    expect(j.text, '可以继续，去编辑。');
    expect(j.at, t(0));
    expect(j.end, t(2.8));
  });

  test('问号、感叹号结尾的不改', () {
    expect(joinLines(seg(0, 1, '是吗？'), seg(1.5, 2, '对。'), nobody)!.text, '是吗？对。');
  });

  test('停得久、换了人、太长、旧草稿没有结束时间：不接', () {
    expect(joinLines(seg(0, 1, '第一件事。'), seg(3, 4, '第二件事。'), nobody), isNull);
    expect(joinLines(seg(0, 1, '先做华东。', who: '王总'), seg(1.5, 2, '我觉得华南好。', who: '我'), nobody), isNull);
    expect(joinLines(seg(0, 10, '长' * 120), seg(10.5, 12, '短' * 40), nobody), isNull);
    expect(joinLines(LiveLine(t(0), '旧的。'), seg(0.5, 1, '新的。'), nobody), isNull);
  });

  test('隔得近但声音不像（两个人接话）：不接', () {
    expect(joinLines(seg(0, 1, '你看他识别不出来。'), seg(1.2, 2, '不是我说的。', emb: other), nobody), isNull);
  });

  test('太短没声纹的小碎片：紧跟着就接上；隔了 1 秒以上不接', () {
    expect(joinLines(seg(0, 1, '我觉得。'), LiveLine(t(1.5), '可以。', end: t(1.8)), nobody)!.text, '我觉得，可以。');
    expect(joinLines(seg(0, 1, '我觉得。'), LiveLine(t(2.2), '可以。', end: t(2.5)), nobody), isNull);
    expect(joinLines(seg(0, 1, '我觉得。'), LiveLine(t(1.2), '那还是挺有用的一个功能。', end: t(1.9)), nobody), isNull);
  });

  test('只有语气词：不显示', () {
    expect(isFiller('嗯。'), isTrue);
    expect(isFiller('呃，啊。'), isTrue);
    expect(isFiller('对。'), isFalse);
    expect(isFiller('可。'), isFalse);
  });

  test('一边认得出、一边认不出：接上，按合起来的声纹重新认', () {
    final e = Float32List.fromList([1, 0]);
    final j = joinLines(seg(0, 1, '我觉得。', who: '我', emb: e), seg(1.4, 3, '还不错。', emb: e), (_) => '我')!;
    expect(j.speaker, '我');
    expect(j.auto, isTrue);
  });

  test('你亲手标的人：接上以后还是你标的，不被重认改掉', () {
    final j = joinLines(seg(0, 1, '先做。', who: '王总', auto: false, emb: Float32List.fromList([1, 0])),
        seg(1.2, 2, '华东。', emb: Float32List.fromList([0.95, 0.2])), (_) => '别人')!;
    expect(j.speaker, '王总');
    expect(j.auto, isFalse);
  });
}
