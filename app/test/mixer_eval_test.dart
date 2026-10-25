// 手动评估用（平时跳过）：MIXER_EVAL="<电脑声音wav>|<麦克风wav>|<输出wav>" 把两路按 100ms / 10ms 一块喂进 AudioMixer，混好存下来。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/live.dart';

Int16List wav(String p) {
  final b = File(p).readAsBytesSync();
  return Int16List.fromList(Int16List.view(b.buffer, 44, (b.length - 44) ~/ 2));
}

void main() {
  final env = Platform.environment['MIXER_EVAL'];
  test('评估混音', () {
    final [sysP, micP, outP] = env!.split('|');
    final sys = wav(sysP), mic = wav(micP);
    final m = AudioMixer(4800);
    final out = BytesBuilder();
    final n = sys.length < mic.length ? sys.length : mic.length;
    for (var i = 0; i < n; i += 1600) {
      for (var j = i; j < i + 1600 && j < n; j += 160) {
        m.addSys(Int16List.sublistView(sys, j, j + 160 < n ? j + 160 : n));
      }
      out.add(m.addMic(Int16List.sublistView(mic, i, i + 1600 < n ? i + 1600 : n)).buffer.asUint8List());
    }
    final pcm = out.takeBytes();
    final h = File(sysP).readAsBytesSync().sublist(0, 44);
    ByteData.sublistView(h).setUint32(40, pcm.length, Endian.little);
    ByteData.sublistView(h).setUint32(4, 36 + pcm.length, Endian.little);
    File(outP).writeAsBytesSync([...h, ...pcm]);
  }, skip: env == null);
}
