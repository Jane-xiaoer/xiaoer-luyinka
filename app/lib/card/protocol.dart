// 录音卡协议（照 luyinka/protocol.py 移植，那边的注释写了每处为什么这样）。
// 包：0x5A 魔数 + 1B 序号 + 2B CRC16/XMODEM(长度+数据，小端) + 2B 长度(小端) + 数据（首字节类型，次字节命令）。

import 'dart:convert';
import 'dart:typed_data';

const magic = 0x5A;
const headerLen = 6;

const typeControl = 0, typeAudio = 1, typeFile = 2, typeKey = 3;

const ctlSyncTime = 0, ctlGetCapacity = 1, ctlCapacity = 2, ctlGetBattery = 3, ctlBattery = 4;
const ctlGetVersion = 10, ctlVersion = 11;

const fileGetList = 0, fileList = 1, fileRequest = 2, fileBegin = 3, fileData = 4, fileEnd = 5;
const fileStop = 7, fileDelete = 8, fileDeleteResult = 13, fileListDone = 18;

const fileEndStatus = {0: '传输完成', 1: '文件不存在', 2: 'offset 过大', 3: '其他停止'};

int crc16Xmodem(List<int> data) {
  var crc = 0;
  for (final b in data) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}

class Packet {
  final int seq;
  final Uint8List payload;
  final bool crcOk;
  Packet(this.seq, this.payload, this.crcOk);
  int get type => payload.isNotEmpty ? payload[0] : -1;
  int get cmd => payload.length > 1 ? payload[1] : -1;
  Uint8List get body => payload.length > 2 ? Uint8List.sublistView(payload, 2) : Uint8List(0);
}

class Encoder {
  int seq = 0;
  Uint8List pack(List<int> payload) {
    final len = [payload.length & 0xFF, (payload.length >> 8) & 0xFF];
    final crc = crc16Xmodem([...len, ...payload]);
    final out = Uint8List.fromList([magic, seq % 256, crc & 0xFF, (crc >> 8) & 0xFF, ...len, ...payload]);
    seq = (seq + 1) % 256;
    return out;
  }
}

/// 字节流切包：BLE 一次通知通常一整包，这里也兼容粘包 / 半包。
class StreamParser {
  final _buf = <int>[];
  List<Packet> feed(List<int> data) {
    _buf.addAll(data);
    final out = <Packet>[];
    while (true) {
      final i = _buf.indexOf(magic);
      if (i < 0) {
        _buf.clear();
        break;
      }
      if (i > 0) _buf.removeRange(0, i);
      if (_buf.length < headerLen) break;
      final length = _buf[4] | (_buf[5] << 8);
      final total = headerLen + length;
      if (_buf.length < total) break;
      final raw = _buf.sublist(0, total);
      _buf.removeRange(0, total);
      final payload = Uint8List.fromList(raw.sublist(headerLen));
      final crc = raw[2] | (raw[3] << 8);
      final ok = crc16Xmodem([raw[4], raw[5], ...payload]) == crc;
      if (!ok && length == 0) continue;
      out.add(Packet(raw[1], payload, ok));
    }
    return out;
  }
}

// ───────── App → 卡 ─────────

List<int> _u16le(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _u32le(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

List<int> cmdSyncTime(DateTime t) =>
    [typeControl, ctlSyncTime, ..._u16le(t.year), t.month, t.day, t.hour, t.minute, t.second];
List<int> cmdSimple(int type, int cmd) => [type, cmd];
List<int> cmdGetList() => cmdSimple(typeFile, fileGetList);
List<int> cmdRequestFile(String name, int offset) => [typeFile, fileRequest, ..._u32le(offset), ...utf8.encode(name)];
List<int> cmdStopFile() => [typeFile, fileStop, 0];
List<int> cmdDelete(String name) => [typeFile, fileDelete, 0, 0, 0, 0, ...utf8.encode(name)];

// ───────── 卡 → App ─────────

class RemoteFile {
  final String name; // 下载时用的名字（带 .opus）
  final int size;
  final int time;
  RemoteFile(this.name, this.size, this.time);
  String get stem => name.endsWith('.opus') ? name.substring(0, name.length - 5) : name;
  @override
  String toString() => '$name/$size/$time';
}

String _cleanName(List<int> raw) {
  final z = raw.indexOf(0);
  var name = utf8.decode(z >= 0 ? raw.sublist(0, z) : raw, allowMalformed: true).trim();
  if (!name.contains('opus')) name += name.endsWith('.') ? 'opus' : '.opus';
  return name;
}

int _u32(Uint8List b, int off, bool big) {
  final d = ByteData.sublistView(b);
  return d.getUint32(off, big ? Endian.big : Endian.little);
}

/// 文件列表：数量 / 时间 / 大小实际是大端（文档写小端），两种都试，选能把长度对上的。
List<RemoteFile> parseFileList(Packet p) {
  final body = p.body;
  if (body.length < 4) return [];
  for (final big in [true, false]) {
    final count = _u32(body, 0, big);
    if (count == 0) return [];
    final rest = body.length - 4;
    if (count > 0 && rest >= count * 28 && (rest - count * 28) % count == 0) {
      final nameLen = 20 + (rest - count * 28) ~/ count;
      final files = <RemoteFile>[];
      var off = 4;
      for (var i = 0; i < count; i++) {
        final t = _u32(body, off, big), size = _u32(body, off + 4, big);
        files.add(RemoteFile(_cleanName(body.sublist(off + 8, off + 8 + nameLen)), size, t));
        off += 8 + nameLen;
      }
      return files;
    }
  }
  throw FormatException('文件列表长度对不上: ${body.length} 字节');
}

int parseBattery(Packet p) => p.body.isNotEmpty ? p.body[0] : -1;

/// (剩余 KB, 总 KB)，小端。
(int, int) parseCapacity(Packet p) => (_u32(p.body, 0, false), _u32(p.body, 4, false));

String parseText(Packet p) {
  final z = p.body.indexOf(0);
  return utf8.decode(z >= 0 ? p.body.sublist(0, z) : p.body, allowMalformed: true).trim();
}

int parseFileEnd(Packet p) => p.body.isNotEmpty ? p.body[0] : 3;
