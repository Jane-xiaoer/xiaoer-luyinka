// 假卡（fake_card.dart）本身对不对：回的包按 vectors.json（真卡抓的）对答案；再用它把 CardClient 和 Syncer 拉卡这一段走一遍（不连云端）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/card/client.dart';
import 'package:luyinka/card/protocol.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

import 'fake_card.dart';

List<int> unhex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

void main() {
  final v = jsonDecode(File('test/vectors.json').readAsStringSync());

  test('文件列表的字节和真卡一模一样', () {
    final card = FakeCard({
      'note20261017-235453.': List.filled(164040, 0),
      'note20261018-000216.': List.filled(164041, 0),
    });
    final reply = card.handle(StreamParser().feed(Encoder().pack(cmdGetList())).single);
    final real = StreamParser().feed(unhex(v['list_packet'])).single;
    expect(reply.first, real.payload);
    expect(reply.last, [typeFile, fileListDone, 0]);
  });

  test('CardClient：电量容量版本、分包列表、断点续传、删除', () async {
    final data = List.generate(5000, (i) => i % 251);
    final card = FakeCard({'note20261019-093000.': data, 'note20261019-093500.': [1, 2, 3]}, listPerPacket: 1, chunk: 333);
    final c = CardClient(card.open());
    await c.syncTime(DateTime(2026, 10, 19, 9, 0, 1));
    expect(card.clock, DateTime(2026, 10, 19, 9, 0, 1));
    final info = await c.info();
    expect([info.battery, info.freeKb, info.totalKb, info.version], [87, 30000000, 31000000, '1.2.23']);
    final files = await c.listFiles();
    expect(files.map((f) => f.toString()), ['note20261019-093000.opus/5000/2', 'note20261019-093500.opus/3/0']);

    final tmp = await Directory.systemTemp.createTemp('fakecard');
    final part = File('${tmp.path}/a.part')..writeAsBytesSync(data.sublist(0, 1234));
    await c.download(files.first, part);
    expect(part.readAsBytesSync(), data);
    expect(card.requests.single, ('note20261019-093000.opus', 1234));

    expect(await c.delete('note20261019-093000.opus'), true);
    expect(await c.delete('note20261019-093000.opus'), false);
    expect(card.files.keys, ['note20261019-093500.']);
    await c.close();
    await tmp.delete(recursive: true);
  });

  test('Syncer 拉卡：认卡、拉到本机、卡上文件不动（云端连不上也不丢）', () async {
    final tmp = await Directory.systemTemp.createTemp('fakesync');
    final store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
    final card = FakeCard({'note20261019-093000.': List.generate(4000, (i) => i % 7)});
    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), card.connect, card.scan, () => 'Asia/Shanghai');
    await syncer.run();
    expect(store.settings['device'], card.id);
    expect(store.recs['note20261019-093000']!.stage, 'pulled');
    expect(store.raw('note20261019-093000').readAsBytesSync(), List.generate(4000, (i) => i % 7));
    expect(card.files, hasLength(1));
    expect(syncer.card.info?.version, '1.2.23');
    await store.save();
    await tmp.delete(recursive: true);
  });
}
