// 录音豆的蓝牙连接：扫广播（认硬件地址，不认 macOS 每次会变的设备编号）→ 连上 → 订阅 8888 → 往 7777 写。
// 查信息 01 01、列录音 1A 0E、换密钥 2E 01、拉文件 1A 07；删录音 1A 10 只给「已存好」的用，遥控录音 18 82。不绑定、不重置。
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import '../ble_lock.dart';
import 'protocol.dart';

/// 附近扫到的一颗豆子。
class BeanSeen {
  final BleDevice device;
  final String mac;
  BeanSeen(this.device, this.mac);
  int get rssi => device.rssi ?? -999;
}

/// 连上的一颗录音豆能做的事（同步只用这几样；测试里换成假的）。
abstract class BeanConn {
  Future<BeanInfo?> info();
  Future<List<BeanFile>> files();
  Future<int> pull(
    BeanFile f,
    File part, {
    void Function(int frames, int totalFrames)? progress,
  });

  /// 从豆子上删一条（1A 10 + id）。true = 豆子回「删了」，null = 没回话。只给「已存好」的用。
  Future<bool?> delete(int id);

  /// 开始 / 停止录音（18 82 01 / 02）。null = 没回话。
  Future<bool?> setRecording(bool on);
  Future<void> close();
}

class BeanClient implements BeanConn {
  final BleDevice device;
  final _parser = BeanParser();
  final _packets = StreamController<BeanPacket>.broadcast();
  final _subs = <StreamSubscription>[];
  late BleCharacteristic _w;
  int _chunk = 20;
  BeanCrypto? _crypto;

  BeanClient._(this.device);

  /// 扫 [timeout]，列出附近的录音豆（信号强的在前）。给了 [mac] 就扫到它为止。
  static Future<List<BeanSeen>> scan({
    Duration timeout = const Duration(seconds: 6),
    String? mac,
  }) => bleLock(() async {
    await UniversalBle.requestPermissions();
    final found = <String, BeanSeen>{};
    final sub = UniversalBle.scanStream.listen((d) {
      if (!d.services.map((s) => s.toLowerCase()).contains(beanService)) return;
      final md = d.manufacturerDataList.firstOrNull;
      final m = md == null ? null : beanMac(md.companyId, md.payload);
      if (m != null) found[m] = BeanSeen(d, m);
    });
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [beanService]),
    );
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end) &&
        !(mac != null && found.containsKey(mac))) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    await UniversalBle.stopScan();
    await sub.cancel();
    return found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
  });

  /// 只连硬件地址是 [mac] 的那颗；不在旁边返回 null。
  static Future<BeanClient?> find(String mac) async {
    // 录音豆几秒才广播一次（实测间隔能到 7 秒多），只听 6 秒会漏：多听一会儿，听到就停
    final s = (await scan(
      mac: mac,
      timeout: const Duration(seconds: 15),
    )).where((x) => x.mac == mac).firstOrNull;
    if (s == null) return null;
    final c = BeanClient._(s.device);
    await c._open();
    return c;
  }

  Future<void> _open() async {
    await device.connect();
    await device.discoverServices();
    _w = await device.getCharacteristic(beanWrite, service: beanService);
    try {
      _chunk = max(20, min(509, await device.requestMtu(512) - 3));
    } catch (_) {}
    final n = await device.getCharacteristic(beanNotify, service: beanService);
    _subs.add(
      n.onValueReceived.listen((v) {
        for (final p in _parser.feed(v)) {
          _packets.add(p);
        }
      }),
    );
    await n.notifications.subscribe();
    _subs.add(
      device.connectionStream.listen((ok) {
        if (!ok && !_packets.isClosed) _packets.close();
      }),
    );
  }

  Future<void> _write(Uint8List data) async {
    for (var i = 0; i < data.length; i += _chunk) {
      await _w.write(
        data.sublist(i, min(i + _chunk, data.length)),
        withResponse: false,
      );
    }
  }

  /// 发一条，等类型 / 编号对得上的回包。
  Future<BeanPacket?> _ask(
    Uint8List frame,
    int type,
    int id, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final got = _packets.stream
        .firstWhere((p) => p.type == type && p.id == id)
        .timeout(timeout);
    await _write(frame);
    try {
      return await got;
    } on TimeoutException {
      return null;
    } on StateError {
      return null; // 连接断了
    }
  }

  @override
  Future<BeanInfo?> info() async {
    final p = await _ask(beanFrame(0x01, 0x01), 0x01, 0x01);
    return p == null ? null : BeanInfo.parse(p.raw);
  }

  /// 全部录音：一页一页翻，直到空页或者翻回已经见过的（不知道一页多少条，按回来的算）。
  @override
  Future<List<BeanFile>> files() async {
    final out = <int, BeanFile>{};
    for (var page = 0; page < 100; page++) {
      final p = await _ask(
        beanFrame(0x1A, 0x0E, [page & 0xFF, page >> 8]),
        0x1A,
        0x0E,
      );
      if (p == null) break;
      final got = BeanFile.parseList(p.raw);
      final fresh = got.where((f) => !out.containsKey(f.id)).toList();
      if (fresh.isEmpty) break;
      for (final f in fresh) {
        out[f.id] = f;
      }
    }
    return out.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  /// 换密钥（每次连接一次）。
  Future<bool> handshake() async {
    if (_crypto?.session != null) return true;
    final c = BeanCrypto();
    final p = await _ask(c.request(), 0x2E, 0x01);
    if (p == null || !c.finish(p.raw)) return false;
    _crypto = c;
    return true;
  }

  /// 拉一条录音，解密后的裸 Opus 帧（每帧 160 字节）接着写进 [part]（断了下次从已有的帧数接着拉）。
  /// 返回这回拉下来的帧数。收到这条的「传完」（1A 0A）才算完；中间缺块就停（下一轮从缺的那块接着拉），
  /// [idle] 这么久没有新数据也停。
  @override
  Future<int> pull(
    BeanFile f,
    File part, {
    void Function(int frames, int totalFrames)? progress,
    Duration idle = const Duration(seconds: 30),
  }) async {
    if (!await handshake()) throw StateError('录音豆没换成密钥');
    final have = await part.exists() ? await part.length() ~/ frameBytes : 0;
    var total = f.frames;
    final sink = part.openWrite(mode: FileMode.append);
    BeanFileKey? key;
    var next = have; // 下一帧要的序号
    var got = 0;
    final done = Completer<void>();
    Timer? quiet;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    void bump() {
      quiet?.cancel();
      quiet = Timer(idle, finish);
    }

    final sub = _packets.stream.listen((p) {
      if (p.type != 0x1A && p.type != 0x1B || done.isCompleted) return;
      if (p.id == 0x07) {
        if (p.raw.length < 97 || u32(p.raw, 9) != f.id)
          return; // 别的文件的头（上一条的余波）
        key = _crypto!.fileKey(p.raw);
        total = u32(p.raw, 13) ~/ sliceBytes; // 头里的大小 = 块数 × 166
        bump();
      } else if (p.id == 0x08 || p.id == 0x12) {
        bump();
        if (key == null) return; // 这条的头还没到：是上一条剩下的分片，不要
        for (final (seq, data) in beanSlices(p.raw)) {
          if (seq < next) continue;
          if (seq > next) return finish(); // 缺块：停，下一轮从 next 接着拉
          sink.add(key!.decrypt(seq, data));
          next++;
          got++;
        }
        progress?.call(next, total);
      } else if (p.id == 0x0A && key != null) {
        finish();
      }
    }, onDone: finish);
    try {
      bump();
      // 从第 have 块开始：偏移按分片的 166 字节一块算（真机核对过，按 160 算会错位）
      await _write(
        beanFrame(0x1A, 0x07, [...le32(have * sliceBytes), ...le32(f.id), 0]),
      );
      await done.future;
    } finally {
      quiet?.cancel();
      await sub.cancel();
      await sink.flush();
      await sink.close();
    }
    if (key == null && got == 0) throw StateError('录音豆没开始传（没有文件头）');
    return got;
  }

  @override
  Future<bool?> delete(int id) async =>
      (await _ask(beanFrame(0x1A, 0x10, le32(id)), 0x1A, 0x10))?.ok;

  @override
  Future<bool?> setRecording(bool on) async =>
      (await _ask(beanFrame(0x18, 0x82, [on ? 1 : 2]), 0x18, 0x82))?.ok;

  @override
  Future<void> close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    try {
      await device.disconnect();
    } catch (_) {}
    if (!_packets.isClosed) await _packets.close();
  }
}
