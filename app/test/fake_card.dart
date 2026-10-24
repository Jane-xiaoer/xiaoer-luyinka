// 假录音卡：照真卡的协议应答（字节怎么排以 protocol.dart / vectors.json / tests/fake_device.py 为准），
// 没有真卡、没有蓝牙时用它测整条同步链路。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:luyinka/card/client.dart';
import 'package:luyinka/card/protocol.dart';
import 'package:luyinka/sync.dart';

/// 一张卡（文件、电量这些状态在这）；每连一次给一条新的 [FakeLink]，跟蓝牙每次重连一样。
class FakeCard {
  final String id, label;
  /// 卡上报的名字（真卡是 `note20261018-000216.`，以点结尾，不带 opus）→ 裸 Opus 字节。
  final Map<String, Uint8List> files;
  int battery; // 110 = 充电中
  int freeKb, totalKb;
  String version;
  int chunk; // 每个数据包带多少字节
  int listPerPacket; // 文件列表每包几条（真卡文件多时分多包）
  bool replyDelete; // 老固件删了不回结果
  final bool bigEndian; // 真卡列表是大端
  final List<String> deleted = [];
  final List<(String, int)> requests = []; // (文件名, offset)
  final List<Packet> received = [];
  DateTime? clock; // 收到的对时
  int connects = 0;
  int? bytesPerSec; // 限速：像真卡蓝牙那样慢慢回数据（null = 立刻全回）
  int? dropAt; // 拉到这个字节数就断开蓝牙（只断一次），测断点续传
  bool _hangUp = false;

  FakeCard(Map<String, List<int>> files,
      {this.id = 'FA:KE:CA:RD:00:01',
      this.label = '录音卡 · 0001',
      this.battery = 87,
      this.freeKb = 30000000,
      this.totalKb = 31000000,
      this.version = '1.2.23',
      this.chunk = 200,
      this.listPerPacket = 10,
      this.replyDelete = true,
      this.bigEndian = true})
      : files = {for (final e in files.entries) e.key: Uint8List.fromList(e.value)};

  /// 卡上报的名字：`note…-…` → `note…-….`
  static String deviceName(String stem) => stem.endsWith('.') ? stem : '$stem.';

  LinkFactory get connect => (id) async => id == this.id ? open() : null;
  CardScanner get scan => () async => [CardChoice(id, label, -50)];

  FakeLink open() {
    connects++;
    return FakeLink(this);
  }

  String _key(String name) => name.endsWith('opus') ? name.substring(0, name.length - 4) : name;

  List<List<int>> handle(Packet p) {
    received.add(p);
    final t = p.type, c = p.cmd, body = p.body;
    if (t == typeControl && c == ctlSyncTime && body.length >= 7) {
      clock = DateTime(body[0] | (body[1] << 8), body[2], body[3], body[4], body[5], body[6]);
      return [];
    }
    if (t == typeControl && c == ctlGetBattery) return [[typeControl, ctlBattery, battery]];
    if (t == typeControl && c == ctlGetCapacity) return [[typeControl, ctlCapacity, ..._u32(freeKb, false), ..._u32(totalKb, false)]];
    if (t == typeControl && c == ctlGetVersion) return [[typeControl, ctlVersion, ...utf8.encode(version), 0]];
    if (t == typeFile && c == fileGetList) {
      final names = files.keys.toList();
      final out = <List<int>>[];
      for (var i = 0; i < names.length; i += listPerPacket) {
        final part = names.sublist(i, i + listPerPacket > names.length ? names.length : i + listPerPacket);
        final b = <int>[typeFile, fileList, ..._u32(part.length, bigEndian)];
        for (final n in part) {
          final data = files[n]!;
          final name = utf8.encode(n);
          b
            ..addAll(_u32(data.length ~/ 2000, bigEndian)) // 时长（秒）：16kbps → 每秒 2000 字节
            ..addAll(_u32(data.length, bigEndian))
            ..addAll([...name, ...List.filled(20 - name.length, 0)]);
        }
        out.add(b);
      }
      if (names.isEmpty) out.add([typeFile, fileList, 0, 0, 0, 0]);
      out.add([typeFile, fileListDone, 0]);
      return out;
    }
    if (t == typeFile && c == fileRequest) {
      final offset = ByteData.sublistView(body).getUint32(0, Endian.little);
      final name = utf8.decode(body.sublist(4));
      requests.add((name, offset));
      final data = files[_key(name)];
      if (data == null) return [[typeFile, fileEnd, 1]];
      if (offset > data.length) return [[typeFile, fileEnd, 2]];
      final cut = dropAt;
      if (cut != null && cut > offset && cut < data.length) {
        dropAt = null;
        _hangUp = true;
        return [
          [typeFile, fileBegin, ...utf8.encode(name)],
          for (var i = offset; i < cut; i += chunk) [typeFile, fileData, ...data.sublist(i, i + chunk > cut ? cut : i + chunk)],
        ];
      }
      return [
        [typeFile, fileBegin, ...utf8.encode(name)],
        for (var i = offset; i < data.length; i += chunk)
          [typeFile, fileData, ...data.sublist(i, i + chunk > data.length ? data.length : i + chunk)],
        [typeFile, fileEnd, 0],
      ];
    }
    if (t == typeFile && c == fileDelete) {
      final name = utf8.decode(body.sublist(4));
      final ok = files.remove(_key(name)) != null;
      if (ok) deleted.add(name);
      return replyDelete ? [[typeFile, fileDeleteResult, ok ? 0 : 1]] : [];
    }
    return [];
  }

  static List<int> _u32(int v, bool big) {
    final d = ByteData(4)..setUint32(0, v, big ? Endian.big : Endian.little);
    return d.buffer.asUint8List();
  }
}

/// 一次连接：App 写进来的字节按真卡的切包方式解，回的包也真的封成字节再切回来（CRC、序号都走一遍）。
class FakeLink implements Link {
  final FakeCard card;
  final _out = StreamController<Packet>.broadcast();
  final _in = StreamParser();
  final _enc = Encoder();
  final _back = StreamParser();
  FakeLink(this.card);

  @override
  Stream<Packet> get packets => _out.stream;

  @override
  Future<void> write(Uint8List data) async {
    for (final p in _in.feed(data)) {
      if (!p.crcOk) throw StateError('App 发来的包 CRC 不对');
      final replies = card.handle(p);
      final hangUp = card._hangUp;
      card._hangUp = false;
      // 卡是异步回的：放到下一轮事件里，别在 write 里同步回
      if (card.bytesPerSec == null && !hangUp) {
        scheduleMicrotask(() => replies.forEach(_emit));
      } else {
        unawaited(_slow(replies, hangUp));
      }
    }
  }

  void _emit(List<int> r) {
    if (_out.isClosed) return;
    for (final q in _back.feed(_enc.pack(r))) {
      _out.add(q);
    }
  }

  Future<void> _slow(List<List<int>> replies, bool hangUp) async {
    await Future.delayed(Duration.zero);
    for (final r in replies) {
      final bps = card.bytesPerSec;
      if (bps != null && r.length > 2 && r[0] == typeFile && r[1] == fileData) {
        await Future.delayed(Duration(microseconds: (r.length - 2) * 1000000 ~/ bps));
      }
      _emit(r);
    }
    if (hangUp) await close(); // 蓝牙断了：App 那边等包等到流结束
  }

  @override
  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }
}
