"""录音卡通讯协议（声云录音卡片 / pnote SDK）。

真相源：vendor/raw/recoder/录音笔与app端协议_WIFI&蓝牙更新.pdf
       + 厂商 Android SDK 反编译（com.wind.pnote.bluetooth.Cmd / response.*）。
两者冲突时以 SDK 代码为准（它是能跑的那份），冲突点在注释里标出。

包格式：
    0x5A | seq(1) | crc16(2, LE) | len(2, LE) | payload(len)
    payload[0] = 数据类型（0 控制 / 1 音频 / 2 文件 / 3 按键·ACK）
    payload[1] = 命令号
    crc = CRC-16/XMODEM(len_lo, len_hi, payload...)
"""

from __future__ import annotations

import datetime as _dt
import struct
from dataclasses import dataclass

MAGIC = 0x5A
HEADER_LEN = 6

TYPE_CONTROL = 0
TYPE_AUDIO = 1
TYPE_FILE = 2
TYPE_KEY = 3  # 文档里 3 既是 ACK 也是按键命令

# 控制命令（类型 0）
CTL_SYNC_TIME = 0
CTL_GET_CAPACITY = 1
CTL_CAPACITY = 2
CTL_GET_BATTERY = 3
CTL_BATTERY = 4
CTL_GET_VERSION = 10
CTL_VERSION = 11
CTL_GET_SN = 12
CTL_SN = 13
CTL_BIND = 16

# 文件命令（类型 2）
FILE_GET_LIST = 0
FILE_LIST = 1
FILE_REQUEST = 2
FILE_BEGIN = 3
FILE_DATA = 4
FILE_END = 5
FILE_STOP = 7
FILE_DELETE = 8
FILE_DELETE_ALL = 9
FILE_DELETE_ALL_RESULT = 10
FILE_REQUEST_RANGE = 12
FILE_DELETE_RESULT = 13
FILE_LIST_DONE = 18

FILE_END_STATUS = {0: "传输完成", 1: "文件不存在", 2: "offset 过大", 3: "其他停止"}


def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


class PacketError(ValueError):
    pass


@dataclass
class Packet:
    seq: int
    payload: bytes
    crc_ok: bool = True

    @property
    def type(self) -> int:
        return self.payload[0] if self.payload else -1

    @property
    def cmd(self) -> int:
        return self.payload[1] if len(self.payload) > 1 else -1

    @property
    def body(self) -> bytes:
        """命令号之后的数据。"""
        return self.payload[2:]


class Encoder:
    """给 App→设备 的包编号（SDK 里是全局自增，取模 256）。"""

    def __init__(self) -> None:
        self.seq = 0

    def pack(self, payload: bytes) -> bytes:
        length = struct.pack("<H", len(payload))
        crc = crc16_xmodem(length + payload)
        pkt = bytes([MAGIC, self.seq % 256]) + struct.pack("<H", crc) + length + payload
        self.seq = (self.seq + 1) % 256
        return pkt


def parse(buf: bytes) -> Packet:
    if len(buf) < HEADER_LEN + 1:
        raise PacketError(f"包太短: {len(buf)} 字节")
    if buf[0] != MAGIC:
        raise PacketError(f"魔数不对: 0x{buf[0]:02x}")
    seq = buf[1]
    crc, length = struct.unpack_from("<HH", buf, 2)
    payload = buf[HEADER_LEN:HEADER_LEN + length]
    if len(payload) < length:
        raise PacketError(f"包不完整: 声明 {length}，实际 {len(payload)}")
    # SDK 收包从不校验 CRC，这里只记录不丢弃，避免设备端 CRC 实现有偏差时整条链路卡死
    crc_ok = crc16_xmodem(buf[4:6] + payload) == crc
    return Packet(seq=seq, payload=bytes(payload), crc_ok=crc_ok)


class StreamParser:
    """把字节流切成包。BLE 一次通知通常就是一整包；Wi-Fi TCP 会粘包/半包，这里统一处理。"""

    def __init__(self) -> None:
        self.buf = bytearray()

    def feed(self, data: bytes) -> list[Packet]:
        self.buf += data
        out: list[Packet] = []
        while True:
            i = self.buf.find(MAGIC)
            if i < 0:
                self.buf.clear()
                break
            if i:
                del self.buf[:i]
            if len(self.buf) < HEADER_LEN:
                break
            length = struct.unpack_from("<H", self.buf, 4)[0]
            total = HEADER_LEN + length
            if len(self.buf) < total:
                break
            raw = bytes(self.buf[:total])
            del self.buf[:total]
            pkt = parse(raw)
            if not pkt.crc_ok and length == 0:
                continue
            out.append(pkt)
        return out


# ---------- App → 设备 命令 ----------

def cmd_sync_time(now: _dt.datetime | None = None) -> bytes:
    now = now or _dt.datetime.now()
    return bytes([TYPE_CONTROL, CTL_SYNC_TIME]) + struct.pack(
        "<HBBBBB", now.year, now.month, now.day, now.hour, now.minute, now.second
    )


def cmd_simple(type_: int, cmd: int) -> bytes:
    return bytes([type_, cmd])


def cmd_get_list() -> bytes:
    return cmd_simple(TYPE_FILE, FILE_GET_LIST)


def cmd_request_file(name: str, offset: int = 0) -> bytes:
    # SDK: offset 小端 4 字节 + 文件名 UTF-8（带 .opus 后缀，不补齐）
    return bytes([TYPE_FILE, FILE_REQUEST]) + struct.pack("<I", offset) + name.encode()


def cmd_request_range(name: str, start: int, end: int) -> bytes:
    return bytes([TYPE_FILE, FILE_REQUEST_RANGE]) + struct.pack("<II", start, end) + name.encode()


def cmd_stop_file() -> bytes:
    return bytes([TYPE_FILE, FILE_STOP, 0])


def cmd_delete(name: str) -> bytes:
    # SDK delFileData：命令号后留 4 个 0 字节，再接文件名
    return bytes([TYPE_FILE, FILE_DELETE]) + b"\0\0\0\0" + name.encode()


def cmd_delete_all() -> bytes:
    return cmd_simple(TYPE_FILE, FILE_DELETE_ALL)


def cmd_ack(seq: int) -> bytes:
    return bytes([TYPE_KEY, seq & 0xFF])


# ---------- 设备 → App 回复解析 ----------

@dataclass
class RemoteFile:
    name: str          # 请求下载时用的名字（带 .opus）
    size: int          # 字节
    time: int          # 秒（文档：录音时长；SDK 字段名 time）

    @property
    def stem(self) -> str:
        return self.name[:-5] if self.name.endswith(".opus") else self.name


def _clean_name(raw: bytes) -> str:
    name = raw.split(b"\0", 1)[0].decode("utf-8", "replace").strip()
    # SDK：名字里没有 "opus" 就补上；设备上报的名字通常以 "." 结尾
    if "opus" not in name:
        name = name + ("opus" if name.endswith(".") else ".opus")
    return name


def parse_file_list(pkt: Packet) -> list[RemoteFile]:
    """类型 2 / 命令 1。

    ⚠️ 文档写「4 字节小端」，SDK 代码按大端（ByteUtils.byteArrayToInt）解析数量、时间、大小。
    这里两种都试，选能把包长度对上的那种。
    """
    body = pkt.body
    if len(body) < 4:
        return []
    for endian in (">", "<"):
        count = struct.unpack_from(endian + "I", body, 0)[0]
        if count == 0:
            return []
        rest = len(body) - 4
        if count > 0 and rest >= count * 28 and (rest - count * 28) % count == 0:
            name_len = 20 + (rest - count * 28) // count
            files = []
            off = 4
            for _ in range(count):
                t, size = struct.unpack_from(endian + "II", body, off)
                name = _clean_name(body[off + 8: off + 8 + name_len])
                files.append(RemoteFile(name=name, size=size, time=t))
                off += 8 + name_len
            return files
    raise PacketError(f"文件列表长度对不上: {len(body)} 字节")


def parse_file_data(pkt: Packet) -> bytes:
    return pkt.body


def parse_file_end(pkt: Packet) -> int:
    return pkt.body[0] if pkt.body else 3


def parse_battery(pkt: Packet) -> int:
    return pkt.body[0] if pkt.body else -1


def parse_capacity(pkt: Packet) -> tuple[int, int]:
    """(剩余KB, 总KB)。SDK SizeResponseInstruct 按小端。"""
    free, total = struct.unpack_from("<II", pkt.body, 0)
    return free, total


def parse_text(pkt: Packet) -> str:
    return pkt.body.split(b"\0", 1)[0].decode("utf-8", "replace").strip()
