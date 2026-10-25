// 安克 AI 录音豆（飞书版，型号 D3200）的蓝牙协议：让它脱离飞书、直接把录音拉进录音卡。
//
// 协议参考社区逆向整理的 PROTOCOL.md（github.com/tacshi/Soundcore，该项目没有许可证，只参考协议、不抄代码），
// 2026-10-24 用 Jane 自己的录音豆逐条实测过：不用绑定、不用登录就能查信息、列录音、拉录音；
// 拉下来的转成文字是正常的中文。只发查询和拉取命令：绑定 / 解绑（0B 87）、恢复出厂（01 B8）、删文件（1A 10）一律不发，
// 豆子还绑在飞书上，飞书那边照常能用。
//
//   发：08 EE 00 00 00 | 类型 | 编号 | 总长 u16 LE | 内容 | 校验（前面所有字节之和的低 8 位）
//   收：09 FF 00 00 | 状态 | 类型 | 编号 | 总长 u16 LE | 内容 | 校验
//
// 录音是加密的：先交换密钥（P-256 ECDH → HKDF-SHA256 得会话密钥），每个文件的文件头里带着用会话密钥加密的文件密钥，
// 数据每 160 字节一块、AES-CTR 解密，解出来每块就是一帧 Opus（48kHz 单声道 20ms），设备不加封装，自己包成 Ogg。
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 录音豆广播的服务号（D3200）。
const beanService = '020cf5da-0000-1000-8000-00805f9b34fb';
const beanWrite = '00007777-0000-1000-8000-00805f9b34fb';
const beanNotify = '00008888-0000-1000-8000-00805f9b34fb';

/// 正在录的那条：列表里的大小是 FFFFFFFF（还在变长），等录完再拉。
const recordingSize = 0xFFFFFFFF;

const frameBytes = 160; // 解密后一帧 Opus
const sliceBytes = 166; // 分片里一块：序号 u32 + 标志 + 160 数据 + 1

Uint8List beanFrame(int type, int id, [List<int> payload = const []]) {
  final n = 7 + 2 + payload.length + 1;
  final out = Uint8List(n)
    ..setAll(0, [0x08, 0xEE, 0, 0, 0, type, id])
    ..[7] = n & 0xFF
    ..[8] = n >> 8
    ..setAll(9, payload);
  out[n - 1] = _sum(out, n - 1);
  return out;
}

int _sum(List<int> b, int end) {
  var s = 0;
  for (var i = 0; i < end; i++) {
    s += b[i];
  }
  return s & 0xFF;
}

int u16(List<int> b, int o) => b[o] | b[o + 1] << 8;
int u32(List<int> b, int o) =>
    b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;
List<int> le32(int v) => [
  v & 0xFF,
  v >> 8 & 0xFF,
  v >> 16 & 0xFF,
  v >> 24 & 0xFF,
];

/// 设备回来的一帧。
class BeanPacket {
  final Uint8List raw;
  BeanPacket(this.raw);
  int get status => raw[4];
  int get type => raw[5];
  int get id => raw[6];
  bool get ok => status & 0x0F == 1;
}

/// 通知里收到的字节可能半帧、可能几帧粘在一起：按 09 FF 头和长度切，校验不对的丢掉。
class BeanParser {
  final _buf = <int>[];

  List<BeanPacket> feed(List<int> data) {
    _buf.addAll(data);
    final out = <BeanPacket>[];
    while (true) {
      var k = -1;
      for (var i = 0; i + 1 < _buf.length; i++) {
        if (_buf[i] == 0x09 && _buf[i + 1] == 0xFF) {
          k = i;
          break;
        }
      }
      if (k < 0) {
        // 留最后一个字节：可能是下一帧头的前半
        if (_buf.length > 1) _buf.removeRange(0, _buf.length - 1);
        return out;
      }
      if (k > 0) _buf.removeRange(0, k);
      if (_buf.length < 10) return out;
      final n = u16(_buf, 7);
      if (n < 10) {
        _buf.removeRange(0, 2);
        continue;
      }
      if (_buf.length < n) return out;
      final f = Uint8List.fromList(_buf.sublist(0, n));
      _buf.removeRange(0, n);
      if (_sum(f, n - 1) == f[n - 1]) out.add(BeanPacket(f));
    }
  }
}

/// 设备信息（01 01 的回包）。
class BeanInfo {
  final String firmware, serial;
  final int battery, caseBattery; // 百分比
  final bool charging;
  final int totalKB, freeKB;
  final bool caseCharging, recording;
  BeanInfo(
    this.firmware,
    this.serial,
    this.battery,
    this.caseBattery,
    this.charging,
    this.totalKB,
    this.freeKB, {
    this.caseCharging = false,
    this.recording = false,
  });

  /// 电量档位 0–9 → (档位 + 1) × 10%；大于 9 的按百分比原样用。
  static int pct(int b) => b <= 9 ? (b + 1) * 10 : min(b, 100);

  static BeanInfo? parse(Uint8List f) {
    if (f.length < 9 + 3 + 5 + 16 + 8 + 1 + 5 + 1) return null;
    String asc(int o, int n) => ascii
        .decode(
          f.sublist(o, o + n).takeWhile((c) => c != 0).toList(),
          allowInvalid: true,
        )
        .trim();
    var p = 9;
    final bat = f[p + 1], chg = f[p + 2];
    p += 3;
    final fw = asc(p, 5);
    p += 5;
    final sn = asc(p, 16).toLowerCase();
    p += 16;
    final total = u32(f, p), free = u32(f, p + 4);
    p += 8;
    final boxChg = f[p];
    p += 1 + 5;
    final boxBat = f[p];
    // 盒子电量后面：盒子 MAC 6、颜色、自动关机开关、自动关机档、拾音灯、盒子灯，然后才是「正在录」
    final rec = p + 1 + 6 + 5;
    return BeanInfo(
      fw,
      sn,
      pct(bat),
      pct(boxBat),
      chg == 1,
      total,
      free,
      caseCharging: boxChg == 1,
      recording: rec < f.length - 1 && f[rec] == 1,
    );
  }
}

/// 豆子里的一条录音。[id] 就是开始录的时刻（Unix 秒）。
class BeanFile {
  /// [ms]：列表里那个数是录音时长（毫秒），不是字节数（2026-10-24 真机核对：列表 136080 ↔ 6804 块 × 20ms）
  final int id, ms;
  BeanFile(this.id, this.ms);
  bool get recording => ms == recordingSize;
  DateTime get start => DateTime.fromMillisecondsSinceEpoch(id * 1000);

  int get seconds => ms ~/ 1000;

  /// 一共多少块（每块 160 字节、20ms 一个 Opus 包）
  int get frames => ms ~/ 20;

  /// 录音卡里的名字：bean + 本地年月日时分秒。云端取名字里前 14 位数字当开始时刻。
  String get stem {
    final t = start;
    String p(int n) => n.toString().padLeft(2, '0');
    return 'bean${t.year}${p(t.month)}${p(t.day)}${p(t.hour)}${p(t.minute)}${p(t.second)}';
  }

  @override
  String toString() => '$id/${ms}ms';

  /// 录音列表（1A 0E）的一页：条数 u16 + 每条（id u32 + 时长毫秒 u32）。
  static List<BeanFile> parseList(Uint8List f) {
    if (f.length < 12) return [];
    final n = u16(f, 9);
    return [
      for (var k = 0; k < n && 11 + 8 * k + 8 <= f.length - 1; k++)
        BeanFile(u32(f, 11 + 8 * k), u32(f, 15 + 8 * k)),
    ];
  }
}

/// 广播里的厂商数据（公司号 2 字节 + 内容）：前 6 字节是这颗豆子的硬件地址。
/// macOS 每次扫到的设备编号会变，认豆子靠它，不靠编号。
String? beanMac(int companyId, List<int> payload) {
  final b = [companyId & 0xFF, companyId >> 8 & 0xFF, ...payload];
  if (b.length < 6) return null;
  return b.take(6).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

// ───────── 加密 ─────────

/// 一次连接里的密钥：先 [request] 发公钥，收到设备回包 [finish] 出会话密钥。
class BeanCrypto {
  final _domain = ECDomainParameters('secp256r1');
  late final AsymmetricKeyPair<ECPublicKey, ECPrivateKey> _pair;
  Uint8List? session;

  /// 测试用：指定私钥（和 Python 原型生成的测试数据对得上）。
  BeanCrypto.withPrivate(BigInt d) {
    final q = _domain.G * d;
    _pair = AsymmetricKeyPair(
      ECPublicKey(q, _domain),
      ECPrivateKey(d, _domain),
    );
  }

  BeanCrypto([SecureRandom? random]) {
    final r = random ?? _random();
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_domain), r));
    final p = gen.generateKeyPair();
    _pair = AsymmetricKeyPair(p.publicKey, p.privateKey);
  }

  /// 发给设备的密钥交换帧（2E 01 + 65 字节未压缩公钥）。
  Uint8List request() =>
      beanFrame(0x2E, 0x01, _pair.publicKey.Q!.getEncoded(false));

  /// 设备回包：@9 设备公钥 65 字节，@74 设备算的共享密钥 32 字节。两边一致才算成。
  bool finish(Uint8List f) {
    if (f.length < 106) return false;
    final q = _domain.curve.decodePoint(f.sublist(9, 74));
    if (q == null) return false;
    final shared = _fixed(
      (ECDHBasicAgreement()..init(_pair.privateKey)).calculateAgreement(
        ECPublicKey(q, _domain),
      ),
      32,
    );
    if (!_eq(shared, f.sublist(74, 106))) return false;
    session = hkdf(
      shared,
      Uint8List.fromList([1, 2, 3]),
      Uint8List.fromList([1, 2, 3]),
      32,
    );
    return true;
  }

  /// 文件头（1A 07，≥97 字节）→ 这个文件的解密器；会话没建好或文件密钥不对返回 null。
  BeanFileKey? fileKey(Uint8List head) {
    if (session == null || head.length < 97) return null;
    final plain = aesCtr(session!, head.sublist(79, 95), head.sublist(33, 79));
    if (ascii.decode(plain.sublist(0, 14), allowInvalid: true) !=
        'soundcored3200')
      return null;
    return BeanFileKey(plain.sublist(14, 46), head.sublist(17, 29));
  }

  static SecureRandom _random() {
    final r = Random.secure();
    return FortunaRandom()..seed(
      KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => r.nextInt(256))),
      ),
    );
  }
}

/// 一个文件的密钥：第 seq 块的计数器 = nonce 前 12 字节 + 大端 u32(seq × 10)。
class BeanFileKey {
  final Uint8List key, nonce12;
  BeanFileKey(this.key, this.nonce12);

  Uint8List decrypt(int seq, Uint8List data) {
    final iv = Uint8List(16)..setAll(0, nonce12);
    final c = (seq * 10) & 0xFFFFFFFF;
    iv
      ..[12] = c >> 24 & 0xFF
      ..[13] = c >> 16 & 0xFF
      ..[14] = c >> 8 & 0xFF
      ..[15] = c & 0xFF;
    return aesCtr(key, iv, data);
  }
}

/// 文件分片（1A 08 / 1A 12）：从 @9 起每 166 字节一块。返回 [(序号, 160 字节数据)]。
List<(int, Uint8List)> beanSlices(Uint8List f) {
  final out = <(int, Uint8List)>[];
  for (var i = 9; f.length - i >= 165; i += sliceBytes) {
    out.add((u32(f, i), Uint8List.sublistView(f, i + 5, i + 5 + frameBytes)));
  }
  return out;
}

Uint8List aesCtr(List<int> key, List<int> iv, List<int> data) {
  final c = CTRStreamCipher(AESEngine())
    ..init(
      false,
      ParametersWithIV(
        KeyParameter(Uint8List.fromList(key)),
        Uint8List.fromList(iv),
      ),
    );
  final out = Uint8List(data.length);
  c.processBytes(Uint8List.fromList(data), 0, data.length, out, 0);
  return out;
}

Uint8List hkdf(Uint8List ikm, Uint8List salt, Uint8List info, int length) {
  final prk = (HMac(SHA256Digest(), 64)..init(KeyParameter(salt))).process(ikm);
  final out = BytesBuilder();
  var t = Uint8List(0);
  for (var n = 1; out.length < length; n++) {
    t = (HMac(
      SHA256Digest(),
      64,
    )..init(KeyParameter(prk))).process(Uint8List.fromList([...t, ...info, n]));
    out.add(t);
  }
  return Uint8List.sublistView(out.toBytes(), 0, length);
}

Uint8List _fixed(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x >>= 8;
  }
  return out;
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ───────── Ogg Opus ─────────

/// 一帧一帧的裸 Opus（每帧 160 字节、20ms、48kHz 单声道）→ Ogg Opus 文件（云端、播放器都认）。
Uint8List oggOpus(List<Uint8List> frames, {int serial = 0x58454552}) {
  final out = BytesBuilder(copy: false);
  final head = BytesBuilder()
    ..add(ascii.encode('OpusHead'))
    ..add([1, 1, 0x38, 0x01]) // 版本 1、单声道、预跳 312
    ..add(le32(48000))
    ..add([0, 0, 0]); // 增益 0、声道映射 0
  final tags = BytesBuilder()
    ..add(ascii.encode('OpusTags'))
    ..add(le32(6))
    ..add(ascii.encode('xiaoer'))
    ..add(le32(0));
  out.add(_page(serial, 0, 0, [head.toBytes()], 2));
  out.add(_page(serial, 1, 0, [tags.toBytes()], 0));
  var seq = 2, granule = 0;
  const perPage = 50; // 一页 1 秒
  for (var k = 0; k < frames.length; k += perPage) {
    final chunk = frames.sublist(k, min(k + perPage, frames.length));
    granule += 960 * chunk.length;
    out.add(
      _page(
        serial,
        seq++,
        granule,
        chunk,
        k + perPage >= frames.length ? 4 : 0,
      ),
    );
  }
  if (frames.isEmpty) out.add(_page(serial, seq, 0, [], 4));
  return out.toBytes();
}

Uint8List _page(
  int serial,
  int seq,
  int granule,
  List<Uint8List> packets,
  int flag,
) {
  final segs = <int>[];
  for (final p in packets) {
    var n = p.length;
    while (n >= 255) {
      segs.add(255);
      n -= 255;
    }
    segs.add(n);
  }
  final b = BytesBuilder()
    ..add(ascii.encode('OggS'))
    ..add([0, flag]);
  final g = ByteData(8)..setInt64(0, granule, Endian.little);
  b
    ..add(g.buffer.asUint8List())
    ..add(le32(serial))
    ..add(le32(seq))
    ..add([0, 0, 0, 0])
    ..add([segs.length, ...segs]);
  for (final p in packets) {
    b.add(p);
  }
  final page = b.toBytes();
  final crc = _oggCrc(page);
  page.setAll(22, le32(crc));
  return page;
}

final _crcTable = List<int>.generate(256, (i) {
  var r = i << 24;
  for (var k = 0; k < 8; k++) {
    r = (r & 0x80000000) != 0
        ? ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
        : (r << 1) & 0xFFFFFFFF;
  }
  return r;
});

int _oggCrc(List<int> data) {
  var crc = 0;
  for (final b in data) {
    crc = ((crc << 8) & 0xFFFFFFFF) ^ _crcTable[((crc >> 24) & 0xFF) ^ b];
  }
  return crc;
}
