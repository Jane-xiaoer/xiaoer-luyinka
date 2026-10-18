"""录音卡高层操作：列文件、断点续传下载、删除、电量容量。

只依赖 Transport（write + 收包队列），蓝牙 / 测试假设备都能接。
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from typing import Callable, Protocol

from . import protocol as P

log = logging.getLogger("luyinka")


class Transport(Protocol):
    packets: "asyncio.Queue[P.Packet]"

    async def write(self, data: bytes) -> None: ...
    async def close(self) -> None: ...


class DeviceError(RuntimeError):
    pass


class TransferStalled(DeviceError):
    """传输中途没数据了（断连、设备忙）。已收到的部分保留在 .part 里，下次续传。"""


class Client:
    def __init__(self, transport: Transport, ack: bool = False) -> None:
        self.t = transport
        self.enc = P.Encoder()
        # 文档说 App 收包要回 ACK；厂商 SDK 实际从不回。默认跟 SDK 走，实测不行再打开。
        self.ack = ack

    async def send(self, payload: bytes) -> None:
        await self.t.write(self.enc.pack(payload))

    async def _next(self, timeout: float) -> P.Packet:
        pkt = await asyncio.wait_for(self.t.packets.get(), timeout)
        if not pkt.crc_ok:
            log.debug("CRC 不符（照收）: type=%s cmd=%s", pkt.type, pkt.cmd)
        if self.ack:
            await self.send(P.cmd_ack(pkt.seq))
        return pkt

    async def _wait(self, type_: int, cmds: set[int], timeout: float) -> P.Packet:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            left = deadline - loop.time()
            if left <= 0:
                raise asyncio.TimeoutError
            pkt = await self._next(left)
            if pkt.type == type_ and pkt.cmd in cmds:
                return pkt
            log.debug("忽略: type=%s cmd=%s %s", pkt.type, pkt.cmd, pkt.body[:16].hex())

    def _drain(self) -> None:
        while not self.t.packets.empty():
            self.t.packets.get_nowait()

    # ---------- 基础信息 ----------

    async def sync_time(self) -> None:
        from .clock import now  # 卡上的钟按她过日子的时区，不按 Mac 系统时区

        await self.send(P.cmd_sync_time(now().replace(tzinfo=None)))

    async def battery(self, timeout: float = 5) -> int:
        await self.send(P.cmd_simple(P.TYPE_CONTROL, P.CTL_GET_BATTERY))
        return P.parse_battery(await self._wait(P.TYPE_CONTROL, {P.CTL_BATTERY}, timeout))

    async def capacity(self, timeout: float = 5) -> tuple[int, int]:
        await self.send(P.cmd_simple(P.TYPE_CONTROL, P.CTL_GET_CAPACITY))
        return P.parse_capacity(await self._wait(P.TYPE_CONTROL, {P.CTL_CAPACITY}, timeout))

    async def version(self, timeout: float = 5) -> str:
        await self.send(P.cmd_simple(P.TYPE_CONTROL, P.CTL_GET_VERSION))
        return P.parse_text(await self._wait(P.TYPE_CONTROL, {P.CTL_VERSION}, timeout))

    async def info(self) -> dict:
        out: dict = {}
        for key, fn in (("battery", self.battery), ("capacity", self.capacity), ("version", self.version)):
            try:
                out[key] = await fn()
            except asyncio.TimeoutError:
                out[key] = None
        return out

    # ---------- 文件 ----------

    async def list_files(self, timeout: float = 8, idle: float = 2.0) -> list[P.RemoteFile]:
        """列表可能分多包发；收到「列表完毕」(18) 或安静 idle 秒就结束。"""
        self._drain()
        await self.send(P.cmd_get_list())
        files: dict[str, P.RemoteFile] = {}
        got_any = False
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            wait = idle if got_any else deadline - loop.time()
            if wait <= 0:
                break
            try:
                pkt = await self._wait(P.TYPE_FILE, {P.FILE_LIST, P.FILE_LIST_DONE}, wait)
            except asyncio.TimeoutError:
                break
            got_any = True
            if pkt.cmd == P.FILE_LIST_DONE:
                break
            for f in P.parse_file_list(pkt):
                files[f.name] = f
        if not got_any:
            raise DeviceError("设备没回文件列表")
        return sorted(files.values(), key=lambda f: f.name)

    async def download(
        self,
        f: P.RemoteFile,
        part: Path,
        stall: float = 20,
        progress: Callable[[int, int], None] | None = None,
    ) -> bytes:
        """下载到 part 文件（追加写），断了从 part 现有长度续传。完成返回全部字节。"""
        part.parent.mkdir(parents=True, exist_ok=True)
        offset = part.stat().st_size if part.exists() else 0
        if f.size and offset >= f.size:
            return part.read_bytes()
        self._drain()
        await self.send(P.cmd_request_file(f.name, offset))
        got = offset
        with open(part, "ab") as fh:
            while True:
                try:
                    pkt = await self._wait(P.TYPE_FILE, {P.FILE_BEGIN, P.FILE_DATA, P.FILE_END}, stall)
                except asyncio.TimeoutError:
                    raise TransferStalled(f"{f.name}: {stall}s 没收到数据，已收 {got}/{f.size}")
                if pkt.cmd == P.FILE_BEGIN:
                    continue
                if pkt.cmd == P.FILE_DATA:
                    data = P.parse_file_data(pkt)
                    fh.write(data)
                    got += len(data)
                    if progress:
                        progress(got, f.size)
                    continue
                status = P.parse_file_end(pkt)
                if status != 0:
                    raise DeviceError(f"{f.name}: {P.FILE_END_STATUS.get(status, status)}")
                break
        if f.size and got != f.size:
            log.warning("%s: 收到 %d 字节，列表里写 %d", f.name, got, f.size)
        return part.read_bytes()

    async def stop_transfer(self) -> None:
        await self.send(P.cmd_stop_file())

    async def delete(self, name: str, timeout: float = 4) -> bool | None:
        """返回 True 成功 / False 失败 / None 老固件不回结果。"""
        await self.send(P.cmd_delete(name))
        try:
            pkt = await self._wait(P.TYPE_FILE, {P.FILE_DELETE_RESULT}, timeout)
        except asyncio.TimeoutError:
            return None
        return pkt.body[:1] == b"\0"
