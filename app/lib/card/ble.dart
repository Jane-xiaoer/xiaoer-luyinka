// 蓝牙：扫带 0xAE20 服务的卡 → 连上 → 订阅 0xAE22（数据）/ 0xAE23（按键）→ 往 0xAE21 写。
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'client.dart';
import 'protocol.dart';

const service = '0000ae20-0000-1000-8000-00805f9b34fb';
const chWrite = '0000ae21-0000-1000-8000-00805f9b34fb';
const chNotify = '0000ae22-0000-1000-8000-00805f9b34fb';
const chKey = '0000ae23-0000-1000-8000-00805f9b34fb';

class BleLink implements Link {
  final BleDevice device;
  final _out = StreamController<Packet>.broadcast();
  final _parsers = {chNotify: StreamParser(), chKey: StreamParser()};
  final _subs = <StreamSubscription>[];
  late BleCharacteristic _w;
  int _chunk = 20;

  BleLink._(this.device);

  /// 扫 [timeout]，找到信号最强的卡就连上；没有返回 null。[preferId] 是上次连过的那张。
  static Future<BleLink?> find({Duration timeout = const Duration(seconds: 6), String? preferId}) async {
    await UniversalBle.requestPermissions();
    final found = <String, BleDevice>{};
    final sub = UniversalBle.scanStream.listen((d) {
      if (d.services.contains(service) || d.deviceId == preferId) found[d.deviceId] = d;
    });
    await UniversalBle.startScan(scanFilter: ScanFilter(withServices: [service]));
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end) && !(preferId != null && found.containsKey(preferId))) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    await UniversalBle.stopScan();
    await sub.cancel();
    if (found.isEmpty) return null;
    final best = found[preferId] ??
        (found.values.toList()..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999))).first;
    final link = BleLink._(best);
    await link._open();
    return link;
  }

  String get id => device.deviceId;
  String get name => device.name ?? '录音卡';

  Future<void> _open() async {
    await device.connect();
    await device.discoverServices();
    _w = await device.getCharacteristic(chWrite, service: service);
    try {
      _chunk = max(20, min(256, await device.requestMtu(256) - 3)); // SDK 超过 256 字节就切片
    } catch (_) {}
    for (final uuid in [chNotify, chKey]) {
      try {
        final c = await device.getCharacteristic(uuid, service: service);
        _subs.add(c.onValueReceived.listen((v) {
          for (final p in _parsers[uuid]!.feed(v)) {
            _out.add(p);
          }
        }));
        await c.notifications.subscribe();
      } catch (_) {
        if (uuid == chNotify) rethrow; // 按键通道不是必需的
      }
    }
    _subs.add(device.connectionStream.listen((ok) {
      if (!ok && !_out.isClosed) _out.close();
    }));
  }

  @override
  Stream<Packet> get packets => _out.stream;

  @override
  Future<void> write(Uint8List data) async {
    for (var i = 0; i < data.length; i += _chunk) {
      await _w.write(data.sublist(i, min(i + _chunk, data.length)), withResponse: false);
    }
  }

  @override
  Future<void> close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    try {
      await device.disconnect();
    } catch (_) {}
    if (!_out.isClosed) await _out.close();
  }
}
