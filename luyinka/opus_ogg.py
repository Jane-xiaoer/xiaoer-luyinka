"""把录音卡导出的裸 Opus 帧封装成标准 Ogg Opus 文件。

SDK 文档：「opus 格式，16k，单声道，40 字节一帧」——没有容器、没有长度前缀，
所以按固定 40 字节切帧。每帧时长从 Opus TOC 字节读出，不写死 20ms。
封装成 .ogg 之后，QuickTime / ffmpeg / 任何播放器都能直接打开。
"""

from __future__ import annotations

import struct
import subprocess
import zlib
from pathlib import Path

FRAME_BYTES = 40
SAMPLE_RATE = 16000

# Ogg 用的 CRC32：多项式 0x04C11DB7，不反射，初值 0
_CRC_TABLE = []
for _i in range(256):
    _r = _i << 24
    for _ in range(8):
        _r = ((_r << 1) ^ 0x04C11DB7) if _r & 0x80000000 else (_r << 1)
    _CRC_TABLE.append(_r & 0xFFFFFFFF)


def _ogg_crc(data: bytes) -> int:
    crc = 0
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) ^ b) & 0xFF]
    return crc


def toc_samples_48k(packet: bytes) -> int:
    """按 RFC 6716 §3.1 从 TOC 字节算出这一包解码后的 48kHz 采样数。"""
    if not packet:
        return 0
    toc = packet[0]
    config = toc >> 3
    if config < 12:          # SILK：10/20/40/60 ms
        frame = (480, 960, 1920, 2880)[config & 3]
    elif config < 16:        # Hybrid：10/20 ms
        frame = (480, 960)[config & 1]
    else:                    # CELT：2.5/5/10/20 ms
        frame = (120, 240, 480, 960)[config & 3]
    code = toc & 3
    if code == 0:
        n = 1
    elif code in (1, 2):
        n = 2
    else:
        n = (packet[1] & 0x3F) if len(packet) > 1 else 1
    return frame * n


class _OggWriter:
    def __init__(self, fh, serial: int = 0x4C59_4B41) -> None:
        self.fh = fh
        self.serial = serial
        self.page_no = 0

    def page(self, packets: list[bytes], granule: int, bos=False, eos=False) -> None:
        lacing = bytearray()
        for p in packets:
            n = len(p)
            lacing += b"\xff" * (n // 255) + bytes([n % 255])
        flags = (0x02 if bos else 0) | (0x04 if eos else 0)
        header = struct.pack(
            "<4sBBqIIIB", b"OggS", 0, flags, granule, self.serial, self.page_no, 0, len(lacing)
        ) + bytes(lacing)
        body = b"".join(packets)
        crc = _ogg_crc(header + body)
        header = header[:22] + struct.pack("<I", crc) + header[26:]
        self.fh.write(header + body)
        self.page_no += 1


def split_frames(raw: bytes, frame_bytes: int = FRAME_BYTES) -> list[bytes]:
    usable = len(raw) - len(raw) % frame_bytes
    return [raw[i:i + frame_bytes] for i in range(0, usable, frame_bytes)]


def raw_to_ogg(raw: bytes, out: Path, frame_bytes: int = FRAME_BYTES,
               input_rate: int = SAMPLE_RATE) -> int:
    """返回写入的帧数。末尾不足一帧的残片丢弃（断点续传时会补回来）。"""
    frames = split_frames(raw, frame_bytes)
    pre_skip = 312
    head = b"OpusHead" + struct.pack("<BBHIhB", 1, 1, pre_skip, input_rate, 0, 0)
    tags = b"OpusTags" + struct.pack("<I", 7) + b"luyinka" + struct.pack("<I", 0)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as fh:
        w = _OggWriter(fh)
        w.page([head], 0, bos=True)
        w.page([tags], 0)
        granule = 0
        batch: list[bytes] = []
        for i, f in enumerate(frames):
            granule += toc_samples_48k(f)
            batch.append(f)
            if len(batch) == 50 or i == len(frames) - 1:
                # RFC 7845：granule = 到本页为止解码出的 48k 采样总数（含 pre-skip）
                w.page(batch, granule, eos=(i == len(frames) - 1))
                batch = []
        if not frames:
            w.page([], 0, eos=True)
    return len(frames)


def ogg_to_wav(ogg: Path, wav: Path) -> None:
    wav.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(ogg), "-ar", "16000", "-ac", "1", str(wav)],
        check=True,
    )


def looks_like_ogg(raw: bytes) -> bool:
    return raw[:4] == b"OggS"


def checksum(raw: bytes) -> str:
    return f"{zlib.crc32(raw):08x}"
