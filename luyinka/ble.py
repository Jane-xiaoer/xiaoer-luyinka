"""蓝牙传输层（bleak / macOS CoreBluetooth）。

UUID 来自厂商 SDK BluetoothConstants：服务 0xAE20，写 0xAE21，数据通知 0xAE22，按键通知 0xAE23。
macOS 上 bleak 拿到的地址是系统分配的 UUID，不是 MAC；第一次连上后记进 state 文件。
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass

from bleak import BleakClient, BleakScanner

from . import protocol as P

log = logging.getLogger("luyinka")


def _u(short: int) -> str:
    return f"0000{short:04x}-0000-1000-8000-00805f9b34fb"


SERVICE = _u(0xAE20)
WRITE = _u(0xAE21)
NOTIFY = _u(0xAE22)
NOTIFY_KEY = _u(0xAE23)

SDK_WRITE_CHUNK = 256  # SDK writeToDevice 超过 256 字节就切片


@dataclass
class Found:
    address: str
    name: str
    rssi: int
    kind: int | None   # 广播厂商数据第一字节 ^0x35；0x03 = Wi-Fi 卡片机


def _kind(adv) -> int | None:
    for data in (adv.manufacturer_data or {}).values():
        if data:
            return data[0] ^ 0x35
    return None


async def scan(timeout: float = 8.0) -> list[Found]:
    found = await BleakScanner.discover(timeout=timeout, return_adv=True, service_uuids=[SERVICE])
    out = []
    for dev, adv in found.values():
        if SERVICE in [u.lower() for u in (adv.service_uuids or [])]:
            out.append(Found(dev.address, dev.name or adv.local_name or "?", adv.rssi, _kind(adv)))
    return sorted(out, key=lambda f: -f.rssi)


class BleTransport:
    def __init__(self, address: str) -> None:
        self.address = address
        self.client = BleakClient(address, disconnected_callback=self._on_disconnect)
        self.packets: asyncio.Queue[P.Packet] = asyncio.Queue()
        self._parsers = {NOTIFY: P.StreamParser(), NOTIFY_KEY: P.StreamParser()}
        self.connected = False

    def _on_disconnect(self, _client) -> None:
        self.connected = False
        log.warning("蓝牙断开")

    def _handler(self, uuid: str):
        parser = self._parsers[uuid]

        def on_notify(_char, data: bytearray) -> None:
            try:
                for pkt in parser.feed(bytes(data)):
                    self.packets.put_nowait(pkt)
            except P.PacketError as e:
                log.debug("坏包丢弃: %s", e)
        return on_notify

    async def open(self, timeout: float = 20) -> None:
        await self.client.connect(timeout=timeout)
        self.connected = True
        await self.client.start_notify(NOTIFY, self._handler(NOTIFY))
        try:
            await self.client.start_notify(NOTIFY_KEY, self._handler(NOTIFY_KEY))
        except Exception as e:  # 按键通道不是必需的
            log.debug("按键通道订阅失败: %s", e)

    @property
    def chunk(self) -> int:
        char = self.client.services.get_characteristic(WRITE)
        mtu_max = getattr(char, "max_write_without_response_size", 20) or 20
        return max(20, min(SDK_WRITE_CHUNK, mtu_max))

    async def write(self, data: bytes) -> None:
        if not self.connected:
            raise ConnectionError("蓝牙没连上")
        n = self.chunk
        for i in range(0, len(data), n):
            await self.client.write_gatt_char(WRITE, data[i:i + n], response=False)

    async def close(self) -> None:
        if self.client.is_connected:
            await self.client.disconnect()
        self.connected = False

    async def __aenter__(self):
        await self.open()
        return self

    async def __aexit__(self, *exc):
        await self.close()
