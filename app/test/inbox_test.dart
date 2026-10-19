// 外面放进来的录音（小耳语音的长口述）：收进来 → 跟卡上的一样整理 → 收件里删掉。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

void main() {
  late Directory tmp;
  late Store store;
  late Syncer syncer;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('inbox');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
    syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai',
        chat: (system, user) async => system.contains('"scenes"')
            ? jsonEncode({'scenes': [{'start': '14:30:00', 'end': '14:31:00', 'category': '个人感悟', 'title': '清迈过冬', 'event': '想去清迈。'}]})
            : '## 笔记\n- 清迈');
  });
  tearDown(() async {
    await store.save(); // 等排队的存档写完再删临时目录
    await tmp.delete(recursive: true);
  });

  test('收进来、整理好、收件清空', () async {
    final inbox = Directory('${store.lib.path}/.xiaoer/inbox')..createSync();
    File('${inbox.path}/voice20261019-143000.m4a').writeAsBytesSync([1, 2, 3]);
    File('${inbox.path}/voice20261019-143000.json').writeAsStringSync(jsonEncode({
      'start': '2026-10-19T14:30:00',
      'lines': [for (var i = 0; i < 20; i++) ['14:30:${i.toString().padLeft(2, '0')}', '我想十一月去清迈待一阵子，十二月底回来，第$i句']],
    }));
    await syncer.run(fromCard: false);
    expect(inbox.listSync(), isEmpty);
    expect(store.recs['voice20261019-143000']!.stage, 'done');
    expect(store.audio('voice20261019-143000').readAsBytesSync(), [1, 2, 3]);
    expect(store.lib.transcript('voice20261019-143000').readAsStringSync(), contains('清迈'));
    expect(store.scenes.single.title, '清迈过冬');
    expect(File('${store.lib.path}/个人感悟/2026-10-19 14.30 清迈过冬.md').existsSync(), isTrue);
  });

  test('已经有的不重收，空的不收', () async {
    final inbox = Directory('${store.lib.path}/.xiaoer/inbox')..createSync();
    File('${inbox.path}/a.json').writeAsStringSync(jsonEncode({'start': '', 'lines': []}));
    await syncer.importInbox();
    expect(store.recs, isEmpty);
    expect(inbox.listSync(), isEmpty);
  });
}
