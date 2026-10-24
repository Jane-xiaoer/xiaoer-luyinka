// 声纹库：够像又拉得开才认，没把握留空；跨会议存盘。
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/voices.dart';

/// 以 [base] 为中心、加一点噪声的「同一个人的另一句」
Float32List near(Float32List base, int seed, [double noise = 0.35]) {
  final r = Random(seed);
  return Float32List.fromList([for (final x in base) x + noise * (r.nextDouble() * 2 - 1)]);
}

Float32List person(int seed) {
  final r = Random(seed * 7919);
  return Float32List.fromList([for (var i = 0; i < 192; i++) r.nextDouble() * 2 - 1]);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('voices'));
  tearDown(() async => tmp.delete(recursive: true));

  test('标过的人认得出来，没标过的人不乱认', () {
    final v = Voices(File('${tmp.path}/voices.json'));
    final wang = person(1), li = person(2), stranger = person(3);
    v.add('王总', near(wang, 10));
    v.add('王总', near(wang, 11));
    v.add('小李', near(li, 20));
    expect(v.identify(near(wang, 12)), '王总');
    expect(v.identify(near(li, 21)), '小李');
    expect(v.identify(near(stranger, 30)), isNull);
  });

  test('两个人都差不多像：拉不开就不认', () {
    final v = Voices(File('${tmp.path}/voices.json'));
    final a = person(1);
    v.add('甲', near(a, 1, 0.05));
    v.add('乙', near(a, 2, 0.05));
    expect(v.identify(near(a, 3, 0.05)), isNull);
  });

  test('存盘：下次打开还认得；忘掉以后不再认', () {
    final f = File('${tmp.path}/voices.json');
    final wang = person(1);
    Voices(f).add('王总', near(wang, 10));
    final again = Voices(f);
    expect(again.names, ['王总']);
    expect(again.identify(near(wang, 11)), '王总');
    again.forget('王总');
    expect(Voices(f).identify(near(wang, 12)), isNull);
  });

  test('每个人只留最近 30 条', () {
    final v = Voices(File('${tmp.path}/voices.json'));
    for (var i = 0; i < 40; i++) {
      v.add('王总', near(person(1), i));
    }
    expect(v.manualCount('王总'), Voices.keep);
    expect(Voices(File('${tmp.path}/voices.json')).manualCount('王总'), Voices.keep);
  });

  test('只认得一个人：要非常像（≥0.8）才认；认得两个人：明显更像谁就是谁', () {
    final v = Voices(File('${tmp.path}/voices.json'));
    final me = person(1), other = person(2);
    v.add('我', near(me, 1, 0.1));
    // 和「我」有点像但不够 0.8：只认得一个人时不认
    final half = Float32List.fromList([for (var i = 0; i < 192; i++) me[i] * 0.55 + other[i] * 0.45]);
    expect(Voices.cosine(half, me), lessThan(0.8));
    expect(v.identify(half), isNull);
    expect(v.identify(near(me, 2, 0.1)), '我');
    v.add('对方', near(other, 3, 0.1));
    // 一两秒的短句：分数低，但明显更像「我」
    final short = Float32List.fromList([for (var i = 0; i < 192; i++) me[i] * 0.8 + (i.isEven ? 0.9 : -0.9)]);
    expect(Voices.cosine(short, me), lessThan(0.6));
    expect(v.identify(short), '我');
  });

  test('自动学：至少认得两个人、够长、明显更像才学；只留最近 10 条；旧格式读得进来', () {
    final f = File('${tmp.path}/voices.json');
    final me = person(1), other = person(2);
    // 旧格式（只有人名 → 向量）
    f.writeAsStringSync('{"我": ["${Voices.encode(near(me, 1, 0.1))}"]}');
    final v = Voices(f);
    expect(v.manualCount('我'), 1);
    expect(v.learn(near(me, 2, 0.1), 5), isFalse); // 只认得一个人：不学
    v.add('对方', near(other, 3, 0.1));
    expect(v.learn(near(me, 4, 0.1), 1.0), isFalse); // 太短
    expect(v.learn(near(me, 5, 0.1), 5), isTrue);
    for (var i = 0; i < 15; i++) {
      v.learn(near(me, 10 + i, 0.1), 5);
    }
    expect(v.autoCount('我'), Voices.autoKeep);
    expect(v.manualCount('我'), 1);
    // 存成新格式，再读回来一样
    final again = Voices(f);
    expect(again.manualCount('我'), 1);
    expect(again.autoCount('我'), Voices.autoKeep);
    again.forget('我');
    expect(Voices(f).names, ['对方']);
  });
}
