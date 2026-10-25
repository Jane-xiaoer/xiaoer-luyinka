// 也录电脑声音：两路节奏不一样（电脑声音一小块一小块、时早时晚），混出来要连续、一个采样不丢不重。
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/live.dart';

void main() {
  test('电脑声音时早时晚：混出来的就是两路逐个相加，连续不断', () {
    final rnd = Random(1);
    const total = 16000 * 5;
    final mic = Int16List.fromList([for (var i = 0; i < total; i++) (i % 97) - 48]);
    final sys = Int16List.fromList([for (var i = 0; i < total; i++) (i % 31) * 10]);
    final m = AudioMixer(4800);
    final out = <int>[];
    // 按 10ms 一拍走：电脑声音每拍产出一块，但晚 0–200ms 才送到（成串地到，顺序不乱）；麦克风每 100ms 一块
    final arrive = <int>[]; // 第 k 块电脑声音哪一拍送到
    var last = 0;
    for (var k = 0; k < total ~/ 160; k++) {
      last = max(last, k + rnd.nextInt(21));
      arrive.add(last);
    }
    var mi = 0, si = 0;
    for (var t = 0; mi < total || si < total ~/ 160; t++) {
      while (si < arrive.length && arrive[si] <= t) {
        m.addSys(Int16List.sublistView(sys, si * 160, si * 160 + 160));
        si++;
      }
      if (t % 10 == 9 && mi < total) {
        out.addAll(m.addMic(Int16List.sublistView(mic, mi, mi + 1600)));
        mi += 1600;
      }
    }
    out.addAll(m.addMic(Int16List(0)));
    expect(out.length, total);
    for (var i = 0; i < total; i++) {
      expect(out[i], mic[i] + sys[i], reason: '第 $i 个采样');
    }
  });

  test('电脑声音停了：不等它，麦克风照常出', () {
    final m = AudioMixer(4800);
    final got = m.addMic(Int16List.fromList(List.filled(8000, 100)));
    expect(got.length, 8000);
    expect(got.every((v) => v == 100), isTrue);
  });

  test('不戴耳机：电脑在出声时麦克风里的回声压低；电脑安静时麦克风原样', () {
    final m = AudioMixer(4800);
    // 电脑在出声（响）+ 麦克风里是小一点的回声
    m.addSys(Int16List.fromList(List.filled(1600, 8000)));
    final echo = m.addMic(Int16List.fromList(List.filled(1600, 3000)));
    expect(echo.every((v) => v < 8000 + 3000 * 0.2), isTrue);
    // 电脑安静了 1 秒：麦克风（你说话）原样
    for (var k = 0; k < 10; k++) {
      m.addSys(Int16List(1600));
      m.addMic(Int16List.fromList(List.filled(1600, 0)));
    }
    m.addSys(Int16List(1600));
    final me = m.addMic(Int16List.fromList(List.filled(1600, 3000)));
    expect(me.every((v) => v == 3000), isTrue);
  });
}
