"""按厂商 SDK 的解析方式回包的假录音卡，用来在没有真机时测 device.Client。"""

from __future__ import annotations

import asyncio
import struct

from luyinka import protocol as P


class FakeCard:
    def __init__(self, files: dict[str, bytes], chunk: int = 200, endian: str = ">",
                 drop_after_chunks: int | None = None, reply_delete: bool = True) -> None:
        # files 的 key 是设备上报的名字（不带 opus，以 . 结尾），和真机一样
        self.files = dict(files)
        self.chunk = chunk
        self.endian = endian            # SDK 按大端解析列表
        self.drop_after_chunks = drop_after_chunks
        self.reply_delete = reply_delete
        self.enc = P.Encoder()
        self.parser = P.StreamParser()
        self.packets: asyncio.Queue[P.Packet] = asyncio.Queue()
        self.requests: list[tuple[str, int]] = []
        self.received: list[P.Packet] = []

    # Transport 接口
    async def write(self, data: bytes) -> None:
        for pkt in self.parser.feed(data):
            assert pkt.crc_ok, "App 发来的包 CRC 不对"
            self.received.append(pkt)
            await self._handle(pkt)

    async def close(self) -> None:
        pass

    def _emit(self, payload: bytes) -> None:
        raw = self.enc.pack(payload)
        # 模拟 BLE 每次通知一整包
        for pkt in P.StreamParser().feed(raw):
            self.packets.put_nowait(pkt)

    async def _handle(self, pkt: P.Packet) -> None:
        t, c, body = pkt.type, pkt.cmd, pkt.body
        if t == P.TYPE_CONTROL and c == P.CTL_GET_BATTERY:
            self._emit(bytes([0, P.CTL_BATTERY, 87]))
        elif t == P.TYPE_CONTROL and c == P.CTL_GET_CAPACITY:
            self._emit(bytes([0, P.CTL_CAPACITY]) + struct.pack("<II", 30_000_000, 31_000_000))
        elif t == P.TYPE_CONTROL and c == P.CTL_GET_VERSION:
            self._emit(bytes([0, P.CTL_VERSION]) + b"1.2.23")
        elif t == P.TYPE_FILE and c == P.FILE_GET_LIST:
            e = self.endian
            body = struct.pack(e + "I", len(self.files))
            for name, data in self.files.items():
                body += struct.pack(e + "II", len(data) // 2000, len(data))
                body += name.encode().ljust(20, b"\0")
            self._emit(bytes([2, P.FILE_LIST]) + body)
            self._emit(bytes([2, P.FILE_LIST_DONE, 0]))
        elif t == P.TYPE_FILE and c == P.FILE_REQUEST:
            offset = struct.unpack_from("<I", body, 0)[0]
            name = body[4:].decode()
            self.requests.append((name, offset))
            key = name[:-4] if name.endswith("opus") else name
            if key not in self.files:
                self._emit(bytes([2, P.FILE_END, 1]))
                return
            data = self.files[key]
            self._emit(bytes([2, P.FILE_BEGIN]) + name.encode())
            sent = 0
            for i in range(offset, len(data), self.chunk):
                if self.drop_after_chunks is not None and sent >= self.drop_after_chunks:
                    self.drop_after_chunks = None  # 只断一次
                    return
                self._emit(bytes([2, P.FILE_DATA]) + data[i:i + self.chunk])
                sent += 1
            self._emit(bytes([2, P.FILE_END, 0]))
        elif t == P.TYPE_FILE and c == P.FILE_DELETE:
            name = body[4:].decode()
            key = name[:-4] if name.endswith("opus") else name
            ok = self.files.pop(key, None) is not None
            if self.reply_delete:
                self._emit(bytes([2, P.FILE_DELETE_RESULT, 0 if ok else 1]))
