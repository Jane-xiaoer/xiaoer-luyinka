// 一段话里换人的地方切开；一个人讲到底不切。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/voices.dart';

/// 假声纹：数正负样本（正 = 甲，负 = 乙），像不像就看比例
Float32List fake(Float32List x) {
  var a = 0, b = 0;
  for (final v in x) {
    v > 0 ? a++ : b++;
  }
  return Float32List.fromList([a.toDouble(), b.toDouble()]);
}

Float32List talk(List<(int, double)> parts) =>
    Float32List.fromList([for (final (sec, v) in parts) ...List.filled(sec * 16000, v)]);

void main() {
  test('甲讲 5 秒、乙接着讲 6 秒：在 5 秒处切开', () {
    final cuts = speakerCuts(talk([(5, 1), (6, -1)]), fake);
    expect(cuts, [5 * 16000]);
  });

  test('甲—乙—甲：切两刀', () {
    expect(speakerCuts(talk([(4, 1), (4, -1), (4, 1)]), fake), [4 * 16000, 8 * 16000]);
  });

  test('一个人讲 20 秒：不切', () {
    expect(speakerCuts(talk([(20, 1)]), fake), isEmpty);
  });

  test('不到 3 秒：不找', () {
    expect(speakerCuts(talk([(1, 1), (1, -1)]), fake), isEmpty);
  });

  test('插话不到 1.5 秒：不单独切出来', () {
    expect(speakerCuts(talk([(5, 1), (1, -1), (5, 1)]), fake), isEmpty);
  });
}
