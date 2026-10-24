// 跟卡说话（照 luyinka/device.py）：只依赖「能发字节 + 收到的包」，蓝牙细节在 ble.dart。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

abstract class Link {
  Stream<Packet> get packets;
  Future<void> write(Uint8List data);
  Future<void> close();
}

class CardError implements Exception {
  final String message;
  CardError(this.message);
  @override
  String toString() => message;
}

class CardInfo {
  final int? battery; // 110 = 充电中
  final int? freeKb, totalKb;
  final String? version;
  CardInfo(this.battery, this.freeKb, this.totalKb, this.version);
  bool get charging => battery == 110;
}

class CardClient {
  final Link link;
  final _enc = Encoder();
  final _q = StreamController<Packet>();
  late final StreamIterator<Packet> _it;
  late final StreamSubscription _sub;

  CardClient(this.link) {
    _sub = link.packets.listen(_q.add, onDone: _q.close); // 连接断了马上知道，不用干等 20 秒
    _it = StreamIterator(_q.stream);
  }

  Future<void> send(List<int> payload) => link.write(_enc.pack(payload));

  Future<Packet> _wait(int type, Set<int> cmds, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('卡没回话');
      final ok = await _it.moveNext().timeout(left);
      if (!ok) throw CardError('连接断了');
      final p = _it.current;
      if (p.type == type && cmds.contains(p.cmd)) return p;
    }
  }

  Future<void> syncTime([DateTime? now]) => send(cmdSyncTime(now ?? DateTime.now()));

  Future<CardInfo> info() async {
    Future<T?> get<T>(Future<T> Function() f) async {
      try {
        return await f();
      } on TimeoutException {
        return null;
      }
    }

    final b = await get(() async {
      await send(cmdSimple(typeControl, ctlGetBattery));
      return parseBattery(await _wait(typeControl, {ctlBattery}, const Duration(seconds: 5)));
    });
    final c = await get(() async {
      await send(cmdSimple(typeControl, ctlGetCapacity));
      return parseCapacity(await _wait(typeControl, {ctlCapacity}, const Duration(seconds: 5)));
    });
    final v = await get(() async {
      await send(cmdSimple(typeControl, ctlGetVersion));
      return parseText(await _wait(typeControl, {ctlVersion}, const Duration(seconds: 5)));
    });
    return CardInfo(b, c?.$1, c?.$2, v);
  }

  /// 列表可能分多包；收到「列表完毕」或安静 2 秒就结束。
  Future<List<RemoteFile>> listFiles() async {
    await send(cmdGetList());
    final files = <String, RemoteFile>{};
    var gotAny = false;
    while (true) {
      try {
        final p = await _wait(typeFile, {fileList, fileListDone},
            gotAny ? const Duration(seconds: 2) : const Duration(seconds: 8));
        gotAny = true;
        if (p.cmd == fileListDone) break;
        for (final f in parseFileList(p)) {
          files[f.name] = f;
        }
      } on TimeoutException {
        break;
      }
    }
    if (!gotAny) throw CardError('卡没回文件列表');
    return files.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// 拉到 part 文件（追加写），断了从 part 现有长度续。
  Future<void> download(RemoteFile f, File part, {void Function(int got, int total)? progress}) async {
    var got = await part.exists() ? await part.length() : 0;
    if (f.size > 0 && got >= f.size) return;
    await send(cmdRequestFile(f.name, got));
    final out = part.openWrite(mode: FileMode.append);
    try {
      while (true) {
        final Packet p;
        try {
          p = await _wait(typeFile, {fileBegin, fileData, fileEnd}, const Duration(seconds: 20));
        } on TimeoutException {
          throw CardError('${f.name}：20 秒没收到数据，已收 $got/${f.size}');
        }
        if (p.cmd == fileBegin) continue;
        if (p.cmd == fileData) {
          out.add(p.body);
          got += p.body.length;
          progress?.call(got, f.size);
          continue;
        }
        final st = parseFileEnd(p);
        if (st != 0) throw CardError('${f.name}：${fileEndStatus[st] ?? st}');
        break;
      }
    } finally {
      await out.flush();
      await out.close();
    }
  }

  /// true 成功 / false 失败 / null 老固件不回结果。
  Future<bool?> delete(String name) async {
    await send(cmdDelete(name));
    try {
      final p = await _wait(typeFile, {fileDeleteResult}, const Duration(seconds: 4));
      return p.body.isNotEmpty && p.body[0] == 0;
    } on TimeoutException {
      return null;
    }
  }

  Future<void> close() async {
    await _sub.cancel();
    await link.close();
  }
}
