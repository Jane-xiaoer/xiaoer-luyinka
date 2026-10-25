// 文稿开了 iCloud「优化存储」：有的文件被挪到云上，App 读它直接报错（不干等）。
// 这时同步照样起得来，页面照样画得出，读不出的那条先跳过、不当成做完了。（用读不了的文件模拟）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

void main() {
  test('索引读不出来：peekResult 当没有；同步照样起得来；待整理的不当成做完了', () async {
    final tmp = await Directory.systemTemp.createTemp('unread');
    final lib = Library(Directory('${tmp.path}/资料'));
    await lib.ensure();
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    final store = Store(Directory('${tmp.path}/app'))..lib = lib;
    await store.putResult('r1', {'start': '2026-10-18T14:00:00', 'lines': [], 'scenes': []});
    store.recs['r1'] = Rec('r1', 0, 'done');
    store.recs['r2'] = Rec('r2', 0, 'transcribed');
    await store.putResult('r2', {'start': '2026-10-18T15:00:00', 'lines': [], 'scenes': []});
    for (final s in ['r1', 'r2']) {
      await Process.run('chmod', ['000', store.result(s).path]);
    }
    expect(() => store.readResult('r1'), throwsA(anything));
    expect(store.peekResult('r1'), isNull);

    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai');
    syncer.start(); // 以前这里抛错，定时同步就再也起不来
    await syncer.run(fromCard: false);
    expect(store.recs['r2']!.stage, 'transcribed'); // 读不出 ≠ 做完了
    syncer.stop();
    for (final s in ['r1', 'r2']) {
      await Process.run('chmod', ['644', store.result(s).path]);
    }
    await store.save(); // 后台的保存先等它落盘，再收拾
    await Future.delayed(const Duration(milliseconds: 200));
    await tmp.delete(recursive: true);
  });
}
