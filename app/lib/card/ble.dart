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

  /// 扫 [timeout]，列出附近所有的卡（信号强的在前）。给了 [until] 就扫到那张为止。
  static Future<List<BleDevice>> scan({Duration timeout = const Duration(seconds: 6), String? until}) async {
    await UniversalBle.requestPermissions();
    final found = <String, BleDevice>{};
    final sub = UniversalBle.scanStream.listen((d) {
      if (d.services.contains(service) || d.deviceId == until) found[d.deviceId] = d;
    });
    await UniversalBle.startScan(scanFilter: ScanFilter(withServices: [service]));
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end) && !(until != null && found.containsKey(until))) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    await UniversalBle.stopScan();
    await sub.cancel();
    return found.values.toList()..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
  }

  /// 只连 [id] 这一张；它不在旁边就返回 null，别人的卡一律不碰。
  static Future<BleLink?> find(String id) async {
    final d = (await scan(until: id)).where((d) => d.deviceId == id).firstOrNull;
    if (d == null) return null;
    final link = BleLink._(d);
    await link._open();
    return link;
  }

  /// 卡名 + 编号尾号，好认是哪张。
  static String label(BleDevice d) {
    final hex = d.deviceId.replaceAll(RegExp('[^0-9A-Fa-f]'), '').toUpperCase();
    final name = (d.name ?? '').trim().isEmpty ? '录音卡' : d.name!.trim();
    return hex.length < 4 ? name : '$name · ${hex.substring(hex.length - 4)}';
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
