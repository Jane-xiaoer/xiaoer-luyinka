// 跟 Python 版（luyinka/protocol.py，已在真卡上验证过）逐字节对答案：vectors.json 由 Python 生成。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/card/protocol.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
List<int> unhex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

void main() {
  final v = jsonDecode(File('test/vectors.json').readAsStringSync());

  test('封包和 Python 一致', () {
    final enc = Encoder()..seq = v['seq_start'];
    final cmds = {
      'sync_time': cmdSyncTime(DateTime(2026, 10, 18, 14, 54, 53)),
      'get_list': cmdGetList(),
      'request': cmdRequestFile('note20261018-000216.opus', 123456),
      'delete': cmdDelete('note20261018-000216.opus'),
      'battery': cmdSimple(typeControl, ctlGetBattery),
    };
    for (final e in cmds.entries) {
      expect(hex(enc.pack(e.value)), v['packed'][e.key], reason: e.key);
    }
  });

  test('解文件列表（大端、名字以 . 结尾）', () {
    final pkts = StreamParser().feed(unhex(v['list_packet']));
    expect(pkts.length, 1);
    expect(pkts.first.crcOk, true);
    expect(parseFileList(pkts.first).map((f) => f.toString()).toList(), List<String>.from(v['list_files']));
  });

  test('半包、粘包', () {
    final a = unhex(v['list_packet']), b = unhex(v['capacity_packet']);
    final p = StreamParser();
    expect(p.feed(a.sublist(0, 10)), isEmpty);
    final got = p.feed([...a.sublist(10), ...b]);
    expect(got.length, 2);
    final (free, total) = parseCapacity(got[1]);
    expect([free, total], v['capacity']);
  });
}
