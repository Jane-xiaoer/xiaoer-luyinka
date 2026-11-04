// 只读看一眼这台 Mac 上真的语音备忘录文件夹（REAL_VOICEMEMOS=1 才跑）：列出来的条数、几条在 _FBF、今天的有没有。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/iphone.dart';

void main() {
  test('真文件夹（只读）', () async {
    final all = await VoiceMemos(VoiceMemos.defaultDir()).list();
    final fbf = all.where((m) => m.rel.contains('_FBF')).toList();
    print('共 ${all.length} 条 · 在这台 Mac 上 ${all.where((m) => m.present).length} · 在 _FBF ${fbf.length} · ck 编号 ${all.where((m) => m.path.startsWith('ck:')).length}');
    for (final m in all.take(4)) {
      print('${m.path} | ${m.title} | ${m.at} | ${m.seconds.toStringAsFixed(1)}s | present=${m.present} | ${m.rel}');
    }
    expect(all, isNotEmpty);
  }, skip: Platform.environment['REAL_VOICEMEMOS'] == '1' ? false : '要 REAL_VOICEMEMOS=1');
}
