import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/analyze.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';

final lines = [for (var i = 0; i < 20; i++) ['14:0${i ~/ 6}:${(i % 6) * 10 == 0 ? '00' : (i % 6) * 10}', '这是工厂产线，日产两千台，良品率百分之九十六，第$i句']];

void main() {
  late Directory tmp;
  late Library lib;
  late Store store;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('recat');
    lib = Library(Directory('${tmp.path}/资料'));
    await lib.ensure();
    store = Store(Directory('${tmp.path}/app'))..lib = lib;
    await store.putResult('r1', {
      'start': '2026-10-18T14:00:00',
      'lines': lines,
      'scenes': [
        {'id': 's1', 'start': '2026-10-18T14:00:00', 'end': '2026-10-18T14:03:50', 'category': '开会', 'title': '产线',
         'event': '看产线', 'people': ['厂长'], 'text': lines, 'body': '## 会议概要\n旧的'},
      ],
    });
  });
  tearDown(() => tmp.delete(recursive: true));

  final oldFile = '会议纪要/2026-10-18 14.00 产线.md';
  final newFile = '现场调研/2026-10-18 14.00 产线.md';

  test('改类别：按新类别的模板重新整理，笔记文件挪到新文件夹', () async {
    String? sys;
    final a = Analyzer(lib, (s, u) async {
      sys = s;
      return '## 关键信息\n- 新的';
    });
    expect(File('${lib.path}/$oldFile').existsSync(), isTrue);
    await store.changeCategory(store.scenes.single, '现场调研', a.note, subject: '东莞某工厂');
    expect(sys, contains('调研笔记')); // 用的是现场调研的模板
    expect(File('${lib.path}/$oldFile').existsSync(), isFalse);
    expect(File('${lib.path}/$newFile').readAsStringSync(), contains('新的'));
    expect(File('${lib.path}/现场调研/按对象/东莞某工厂.md').readAsStringSync(), contains('产线'));
    final idx = store.readResult('r1')!['scenes'][0];
    expect(idx['category'], '现场调研');
    expect(idx['subject'], '东莞某工厂');
    expect(idx['file'], '${lib.path}/$newFile');
    expect(File('${lib.path}/每日/2026-10-18.md').readAsStringSync(), contains('[现场调研]'));

    // 再改走：调研对象文件里拿掉这段
    await store.changeCategory(store.scenes.single, '多人群聊', a.note);
    expect(File('${lib.path}/现场调研/按对象/东莞某工厂.md').readAsStringSync(), isNot(contains('产线')));
    expect(File('${lib.path}/多人群聊/2026-10-18 14.00 产线.md').existsSync(), isTrue);
    expect(File('${lib.path}/$newFile').existsSync(), isFalse);
  });

  test('整理失败：类别保持原样，文件不动', () async {
    final a = Analyzer(lib, (s, u) async => throw Exception('网断了'));
    await expectLater(store.changeCategory(store.scenes.single, '打电话', a.note), throwsException);
    expect(store.scenes.single.category, '开会');
    expect(store.scenes.single.body, contains('旧的'));
    expect(File('${lib.path}/$oldFile').existsSync(), isTrue);
    expect(store.readResult('r1')!['scenes'][0]['category'], '开会');
  });

  test('改成杂音：笔记文件删掉，列表里不显示', () async {
    await store.changeCategory(store.scenes.single, '杂音', Analyzer(lib, (s, u) async => 'x').note);
    expect(File('${lib.path}/$oldFile').existsSync(), isFalse);
    expect(store.scenes, isEmpty);
    expect(store.readResult('r1')!['scenes'][0]['category'], '杂音');
  });
}
