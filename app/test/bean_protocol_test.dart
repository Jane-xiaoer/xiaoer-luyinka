// 录音豆协议：组帧 / 拆帧 / 列表 / 密钥交换和解密（和真机验证过的 Python 原型交叉对过）/ Ogg 封装。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/bean/protocol.dart';

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

/// 设备回包：09 FF 00 00 状态 类型 编号 长度 内容 校验
Uint8List rx(int type, int id, List<int> payload) {
  final n = 10 + payload.length;
  final f = Uint8List(n)
    ..setAll(0, [0x09, 0xFF, 0, 0, 1, type, id, n & 0xFF, n >> 8])
    ..setAll(9, payload);
  var s = 0;
  for (var i = 0; i < n - 1; i++) {
    s += f[i];
  }
  f[n - 1] = s & 0xFF;
  return f;
}

void main() {
  test('组帧：查设备信息、列录音第 0 页（和真机上用的一样）', () {
    expect(beanFrame(0x01, 0x01), hex('08ee00000001010a0002'));
    final list = beanFrame(0x1A, 0x0E, [0, 0]);
    expect(list.length, 12);
    expect(list.last, list.sublist(0, 11).fold<int>(0, (a, b) => a + b) & 0xFF);
  });

  test('拆帧：半帧、粘包、前面有垃圾、校验错的丢掉', () {
    final a = rx(0x01, 0x03, [7, 8]), b = rx(0x1A, 0x0E, [0, 0]);
    final bad = rx(0x01, 0x04, [1, 1])..[11] ^= 0xFF;
    final p = BeanParser();
    final got = <BeanPacket>[
      ...p.feed([0x55, 0x09]),
      ...p.feed([0xFF, ...a.sublist(2, 5)]),
      ...p.feed([...a.sublist(5), ...bad, ...b]),
    ];
    expect(got.map((x) => '${x.type}/${x.id}'), ['1/3', '26/14']);
  });

  test('录音列表：条数 + 每条 id/大小；正在录的大小是 FFFFFFFF', () {
    final f = rx(0x1A, 0x0E, [
      2,
      0,
      ...le32(1776234093),
      ...le32(5294080),
      ...le32(1792849165),
      ...le32(0xFFFFFFFF),
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
    final files = BeanFile.parseList(f);
    expect(files.map((x) => x.id), [1776234093, 1792849165]);
    expect(files.first.recording, isFalse);
    expect(files.last.recording, isTrue);
    expect(RegExp(r'^bean\d{14}$').hasMatch(files.first.stem), isTrue);
  });

  test('设备信息：固件、序列号、电量档位、存储', () {
    final p = [
      1, 9, 0, // 连接、豆子电量档位 9、没充电
      ...ascii.encode('04.82'),
      ...ascii.encode('32007ce9131d41c9'),
      ...le32(7550976), ...le32(7499674),
      0, ...ascii.encode('01.10'), 4, // 盒子：没充电、固件、档位 4
    ];
    final i = BeanInfo.parse(rx(0x01, 0x01, p))!;
    expect(i.firmware, '04.82');
    expect(i.serial, '32007ce9131d41c9');
    expect(i.battery, 100);
    expect(i.caseBattery, 50);
    expect((i.totalKB - i.freeKB) / 1024, closeTo(50.1, 0.1));
  });

  test('广播里的硬件地址：公司号 + 内容前 4 字节（和序列号对得上）', () {
    expect(
      beanMac(0xE97C, [0x13, 0x1D, 0x41, 0xC9, 0x91, 0x00]),
      '7ce9131d41c9',
    );
  });

  test('密钥交换 + 文件密钥 + 逐块解密：和 Python 原型（真机验证过）结果一样', () {
    final fx = jsonDecode(
      File('test/fixtures/bean_crypto.json').readAsStringSync(),
    );
    final c = BeanCrypto.withPrivate(
      BigInt.parse((fx['app_d'] as String).substring(2), radix: 16),
    );
    expect(c.finish(hex(fx['handshake'])), isTrue);
    final key = c.fileKey(hex(fx['head']));
    expect(key, isNotNull);
    final slices = beanSlices(hex(fx['slices']));
    expect(slices.map((s) => s.$1), [0, 1, 2]);
    for (final (seq, data) in slices) {
      expect(key!.decrypt(seq, data), hex(fx['plain'][seq]));
    }
  });

  test('密钥交换：设备算的共享密钥对不上就不认', () {
    final fx = jsonDecode(
      File('test/fixtures/bean_crypto.json').readAsStringSync(),
    );
    final c = BeanCrypto(); // 另一把私钥
    expect(c.finish(hex(fx['handshake'])), isFalse);
    expect(c.fileKey(hex(fx['head'])), isNull);
  });

  test('Ogg 封装：ffprobe 认得是 Opus、时长对', () async {
    if (!File('/opt/homebrew/bin/ffprobe').existsSync()) return;
    // 一帧静音 Opus（CELT 20ms）重复 100 帧 = 2 秒；内容不重要，看封装
    final silent = Uint8List.fromList([
      0xF8,
      0xFF,
      0xFE,
      ...List.filled(157, 0),
    ]);
    final tmp = File(
      '${Directory.systemTemp.path}/bean_test_${DateTime.now().microsecondsSinceEpoch}.ogg',
    );
    await tmp.writeAsBytes(oggOpus(List.filled(100, silent)));
    final r = await Process.run('/opt/homebrew/bin/ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration:stream=codec_name,sample_rate,channels',
      '-of',
      'json',
      tmp.path,
    ]);
    await tmp.delete();
    expect(r.exitCode, 0, reason: r.stderr);
    final j = jsonDecode(r.stdout);
    expect(j['streams'][0]['codec_name'], 'opus');
    expect(j['streams'][0]['channels'], 1);
    expect(double.parse(j['format']['duration']), closeTo(2.0, 0.05));
  });
}
