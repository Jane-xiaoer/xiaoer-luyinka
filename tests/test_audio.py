"""音频链路：模拟录音卡的裸 Opus（16k 单声道 40 字节/帧）→ ogg → wav → SenseVoice。"""

import struct
import subprocess
from pathlib import Path

import pytest

from luyinka import opus_ogg, pipeline

ZH = Path.home() / "projects/RTC/asr_local/official_sensevoice/test_wavs/zh.wav"


def ogg_packets(data: bytes) -> list[bytes]:
    """最小 Ogg 解复用（测试用）：取出所有包。"""
    pkts, cur, i = [], b"", 0
    while i < len(data):
        assert data[i:i + 4] == b"OggS"
        nseg = data[i + 26]
        lacing = data[i + 27:i + 27 + nseg]
        pos = i + 27 + nseg
        for l in lacing:
            cur += data[pos:pos + l]
            pos += l
            if l < 255:
                pkts.append(cur)
                cur = b""
        i = pos
    return pkts


def make_card_raw(src: Path, tmp: Path) -> bytes:
    """用 libopus 按卡的参数编码（CBR 16kbps、20ms → 每帧正好 40 字节），去掉容器只留裸帧。"""
    ogg = tmp / "enc.ogg"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-ar", "16000", "-ac", "1",
                    "-c:a", "libopus", "-b:a", "16k", "-vbr", "off", "-frame_duration", "20",
                    "-application", "voip", str(ogg)], check=True)
    pkts = ogg_packets(ogg.read_bytes())[2:]  # 去掉 OpusHead / OpusTags
    assert pkts and all(len(p) == 40 for p in pkts), {len(p) for p in pkts}
    return b"".join(pkts)


@pytest.fixture(scope="module")
def card_raw(tmp_path_factory):
    if not ZH.exists():
        pytest.skip("缺 RTC 测试音频")
    return make_card_raw(ZH, tmp_path_factory.mktemp("enc"))


def test_toc_20ms():
    # SILK WB 20ms code0
    assert opus_ogg.toc_samples_48k(bytes([(9 << 3) | 0])) == 960


def test_raw_to_ogg_plays_with_right_length(card_raw, tmp_path):
    ogg = tmp_path / "x.ogg"
    n = opus_ogg.raw_to_ogg(card_raw + b"\x01\x02\x03", ogg)  # 末尾残片应被丢弃
    assert n == len(card_raw) // 40
    want = pipeline.audio_seconds(ZH)
    got = pipeline.audio_seconds(ogg)
    assert abs(got - want) < 0.1, (got, want)
    # ffmpeg 完整解码不报错
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", str(ogg), "-f", "null", "-"],
                       capture_output=True, text=True)
    assert r.returncode == 0 and not r.stderr.strip(), r.stderr


def test_full_pipeline_transcribes(card_raw, tmp_path, monkeypatch):
    monkeypatch.setattr(pipeline, "AUDIO_DIR", tmp_path / "音频")
    monkeypatch.setattr(pipeline, "TEXT_DIR", tmp_path / "文字")
    raw = tmp_path / "note20251231121212.opus"
    raw.write_bytes(card_raw)
    ogg, md = pipeline.process_raw("note20251231121212.", raw)
    assert ogg.name == "2025-12-31 12.12.12 录音.ogg"
    text = md.read_text()
    print(text)
    assert "# 2025-12-31 12.12.12 录音" in text
    assert "**[00:00:" in text
    body = text.split("**", 2)[-1]
    assert len(body.strip()) > 5
