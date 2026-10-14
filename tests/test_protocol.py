import asyncio
import struct

import pytest

from luyinka import protocol as P
from luyinka.device import Client, TransferStalled

from fake_device import FakeCard


def sdk_crc(buffer: bytes) -> int:
    """逐行移植 SDK Cmd.CRC16_XMODEM，用来对拍。"""
    crc = 0
    for b in buffer:
        b = b - 256 if b > 127 else b  # Java byte 有符号
        for i in range(8):
            bit = ((b >> (7 - i)) & 1) == 1
            c15 = ((crc >> 15) & 1) == 1
            crc <<= 1
            if c15 ^ bit:
                crc ^= 4129
    return crc & 0xFFFF


def sdk_base(arr: bytes, position: int) -> bytes:
    """逐行移植 SDK Cmd.base。"""
    datas = bytearray(6 + len(arr))
    datas[0] = 90
    datas[1] = position % 256
    datas[5] = (len(arr) // 256) & 0xFF
    datas[4] = len(arr) & 255
    crc = sdk_crc(bytes([datas[4], datas[5]]) + arr)
    datas[3] = (crc // 256) & 0xFF
    datas[2] = crc & 255
    datas[6:] = arr
    return bytes(datas)


def test_crc_standard_vector():
    assert P.crc16_xmodem(b"123456789") == 0x31C3


@pytest.mark.parametrize("payload", [
    bytes([0, 3]), bytes([2, 0]), P.cmd_request_file("note20251231121212.opus", 12345),
    bytes(range(256)) * 3,
])
def test_pack_matches_sdk(payload):
    enc = P.Encoder()
    enc.seq = 7
    assert enc.pack(payload) == sdk_base(payload, 7)
    assert sdk_crc(payload) == P.crc16_xmodem(payload)


def test_request_file_layout_matches_sdk():
    # SDK getFileData: [2,2] + offset LE4 + name utf8
    b = P.cmd_request_file("note20251112-222831.opus", 274)
    assert b[:2] == bytes([2, 2])
    assert struct.unpack("<I", b[2:6])[0] == 274
    assert b[6:] == b"note20251112-222831.opus"


def test_stream_parser_handles_split_and_glued():
    enc = P.Encoder()
    a = enc.pack(bytes([2, 4]) + b"x" * 300)
    b = enc.pack(bytes([2, 5, 0]))
    sp = P.StreamParser()
    got = sp.feed(b"\x00junk" + a[:100]) + sp.feed(a[100:] + b[:3]) + sp.feed(b[3:])
    assert [p.cmd for p in got] == [4, 5]
    assert got[0].body == b"x" * 300
    assert all(p.crc_ok for p in got)


@pytest.mark.parametrize("endian", [">", "<"])
def test_file_list_both_endians(endian):
    names = ["note20251231121212.", "call20260121183052."]
    body = struct.pack(endian + "I", 2)
    for i, n in enumerate(names):
        body += struct.pack(endian + "II", 60 + i, 7200 + i) + n.encode().ljust(20, b"\0")
    pkt = P.Packet(seq=0, payload=bytes([2, 1]) + body)
    files = P.parse_file_list(pkt)
    assert [f.name for f in files] == ["note20251231121212.opus", "call20260121183052.opus"]
    assert [f.size for f in files] == [7200, 7201]


def run(coro):
    return asyncio.run(coro)


def test_client_info_list_download_delete(tmp_path):
    data = bytes(range(256)) * 40  # 10240 字节
    card = FakeCard({"note20251231121212.": data, "note20260101080000.": b"\x01" * 400})

    async def go():
        c = Client(card)
        assert await c.battery() == 87
        assert await c.capacity() == (30_000_000, 31_000_000)
        assert await c.version() == "1.2.23"
        files = await c.list_files()
        assert [f.name for f in files] == ["note20251231121212.opus", "note20260101080000.opus"]
        got = await c.download(files[0], tmp_path / "a.part")
        assert got == data
        assert card.requests[-1] == ("note20251231121212.opus", 0)
        assert await c.delete(files[0].name) is True
        assert "note20251231121212." not in card.files
    run(go())


def test_download_resumes_from_partial(tmp_path):
    data = bytes(range(200)) * 50  # 10000 字节，每块 200
    card = FakeCard({"note20251231121212.": data}, drop_after_chunks=12)

    async def go():
        c = Client(card)
        f = (await c.list_files())[0]
        part = tmp_path / "a.part"
        with pytest.raises(TransferStalled):
            await c.download(f, part, stall=0.3)
        assert part.stat().st_size == 2400
        got = await c.download(f, part, stall=0.3)
        assert got == data
        assert card.requests == [("note20251231121212.opus", 0), ("note20251231121212.opus", 2400)]
    run(go())


def test_missing_file_reports_error(tmp_path):
    card = FakeCard({})

    async def go():
        c = Client(card)
        from luyinka.device import DeviceError
        with pytest.raises(DeviceError, match="文件不存在"):
            await c.download(P.RemoteFile("nope.opus", 10, 1), tmp_path / "x.part", stall=1)
    run(go())


def test_old_firmware_delete_without_reply(tmp_path):
    card = FakeCard({"note20251231121212.": b"a" * 10}, reply_delete=False)

    async def go():
        c = Client(card)
        assert await c.delete("note20251231121212.opus", timeout=0.3) is None
    run(go())
