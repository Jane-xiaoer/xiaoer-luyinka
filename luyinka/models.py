"""本机转写要的两个模型：SenseVoice int8（约 230MB）+ silero VAD（约 0.6MB）。`luyinka setup` 调它下载。

每个文件几个下载地址轮着试（国内连不上 huggingface 时走 hf-mirror），断了从断点续，下完核对大小。
"""

from __future__ import annotations

import logging
import time
import urllib.request
from pathlib import Path

from .config import C, path

log = logging.getLogger("luyinka")

_SV = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/"
FILES = {
    "sensevoice/model.int8.onnx": (239233841, ["https://huggingface.co/" + _SV + "model.int8.onnx",
                                               "https://hf-mirror.com/" + _SV + "model.int8.onnx"]),
    "sensevoice/tokens.txt": (315894, ["https://huggingface.co/" + _SV + "tokens.txt",
                                       "https://hf-mirror.com/" + _SV + "tokens.txt"]),
    "silero_vad.onnx": (643854, ["https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"]),
}


def targets() -> dict[str, Path]:
    """文件 → 本机路径（按配置里的 model_dir / vad_model 放）。"""
    asr = C["asr"]
    sv, vad = path(asr["model_dir"]), path(asr["vad_model"])
    return {"sensevoice/model.int8.onnx": sv / "model.int8.onnx", "sensevoice/tokens.txt": sv / "tokens.txt",
            "silero_vad.onnx": vad}


def missing(need_asr: bool = True) -> list[str]:
    return [k for k, p in targets().items()
            if (need_asr or k == "silero_vad.onnx") and not (p.exists() and p.stat().st_size == FILES[k][0])]


def _fetch(url: str, dst: Path, size: int, progress) -> None:
    part = dst.with_name(dst.name + ".part")
    have = part.stat().st_size if part.exists() else 0
    req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
    with urllib.request.urlopen(req, timeout=60) as r:
        if have and r.status != 206:  # 服务器不认断点，从头来
            have = 0
        with open(part, "ab" if have else "wb") as f:
            last = 0.0
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                have += len(chunk)
                if progress and time.time() - last > 1:
                    last = time.time()
                    progress(dst.name, have, size)
    if part.stat().st_size != size:
        raise IOError(f"{dst.name} 大小不对：{part.stat().st_size} ≠ {size}")
    part.replace(dst)


def download(need_asr: bool = True, progress=None) -> None:
    for key in missing(need_asr):
        size, urls = FILES[key]
        dst = targets()[key]
        dst.parent.mkdir(parents=True, exist_ok=True)
        errors = []
        for url in urls:
            for _ in range(3):
                try:
                    _fetch(url, dst, size, progress)
                    break
                except Exception as e:  # noqa: BLE001 — 换个地址或者续传再试
                    errors.append(f"{url}: {e}")
                    time.sleep(2)
            if dst.exists():
                break
        if not dst.exists():
            raise RuntimeError(f"{key} 下不下来：\n" + "\n".join(errors[-3:]))
        log.info("模型好了：%s", dst)
