"""整条流水线：卡上新录音 → 下载（断点续传）→ 封装 ogg → 转写 md →（可选）删卡上文件。

产出目录（配置里的 home，LUYINKA_HOME 可临时改）：
    原始/   卡上导出的裸 Opus（.opus，下载中是 .opus.part）
    音频/   能直接播放的 .ogg
    文字/   转写结果 .md
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

from . import opus_ogg
from .config import APP_DIR, C, path
from .device import Client, DeviceError, TransferStalled
from .protocol import RemoteFile

log = logging.getLogger("luyinka")

HOME = Path(os.environ.get("LUYINKA_HOME", path(C["home"])))
RAW_DIR = HOME / "原始"
AUDIO_DIR = HOME / "音频"
TEXT_DIR = HOME / "文字"
STATE = APP_DIR / "state.json"


def load_state() -> dict:
    if STATE.exists():
        return json.loads(STATE.read_text())
    return {"device": None, "files": {}}


def save_state(st: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2))
    tmp.replace(STATE)


def nice_name(stem: str) -> str:
    """note20251231121212 → 2025-12-31 12.12.12 录音；call 2026-01-21_18-30-52 → … 通话。"""
    kind = "通话" if stem.lower().startswith("call") else "录音"
    digits = re.sub(r"\D", "", stem)
    if len(digits) >= 14:
        d = digits[:14]
        return f"{d[:4]}-{d[4:6]}-{d[6:8]} {d[8:10]}.{d[10:12]}.{d[12:14]} {kind}"
    return stem.strip(". ") or "未命名"


def to_wav(src: Path, wav: Path) -> None:
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-ar", "16000", "-ac", "1",
                    "-c:a", "pcm_s16le", str(wav)], check=True)


def audio_seconds(path: Path) -> float:
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                        "-of", "default=nw=1:nk=1", str(path)], capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


_transcriber = None


def transcribe_file(src: Path, out_md: Path, title: str, extra: dict | None = None) -> Path:
    """任意音频 → md。src 是 .opus 裸帧时先封装成 ogg。"""
    global _transcriber
    from .transcribe import Transcriber, fmt_ts, to_markdown

    if _transcriber is None:
        _transcriber = Transcriber()
    with tempfile.TemporaryDirectory() as td:
        wav = Path(td) / "a.wav"
        to_wav(src, wav)
        dur = audio_seconds(wav)
        t0 = time.time()
        last = [0.0]

        def prog(done, total):
            if time.time() - last[0] > 5:
                last[0] = time.time()
                log.info("  转写 %s  %d%%", title, done * 100 // max(total, 1))

        segs = list(_transcriber.segments(wav, prog))
    meta = {"时长": fmt_ts(dur), "转写耗时": f"{time.time() - t0:.0f} 秒"}
    meta.update(extra or {})
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(to_markdown(title, segs, meta), encoding="utf-8")
    return out_md


def process_raw(stem: str, raw_path: Path) -> tuple[Path, Path]:
    title = nice_name(stem)
    raw = raw_path.read_bytes()
    ogg = AUDIO_DIR / f"{title}.ogg"
    if opus_ogg.looks_like_ogg(raw):
        ogg.write_bytes(raw)
    else:
        frames = opus_ogg.raw_to_ogg(raw, ogg)
        if not frames:
            raise ValueError(f"{raw_path.name}: 没有完整的 Opus 帧")
    md = transcribe_file(ogg, TEXT_DIR / f"{title}.md", title, {"原文件": raw_path.name})
    return ogg, md


async def sync(client: Client, delete_after: bool = False, retries: int = 3,
               reconnect=None) -> list[dict]:
    """reconnect：断线时调用的协程工厂，返回新的 Client。"""
    st = load_state()
    files: list[RemoteFile] = await client.list_files()
    log.info("卡上 %d 个录音", len(files))
    report = []
    for f in files:
        rec = st["files"].get(f.name, {})
        if rec.get("transcribed"):
            if delete_after and not rec.get("deleted"):
                rec["deleted"] = await client.delete(f.name) is not False
                save_state(st)
            continue
        part = RAW_DIR / f"{f.stem}.opus.part"
        final = RAW_DIR / f"{f.stem}.opus"
        if not final.exists():
            for attempt in range(1, retries + 1):
                try:
                    t0 = time.time()
                    await client.download(
                        f, part,
                        progress=lambda got, total, n=f.name: _progress(n, got, total))
                    part.replace(final)
                    log.info("下载完 %s（%.0f 秒）", f.name, time.time() - t0)
                    break
                except (TransferStalled, ConnectionError, asyncio.TimeoutError) as e:
                    log.warning("第 %d 次下载中断：%s", attempt, e)
                    if attempt == retries:
                        report.append({"file": f.name, "error": str(e)})
                        break
                    if reconnect:
                        client = await reconnect()
                except DeviceError as e:
                    report.append({"file": f.name, "error": str(e)})
                    break
            if not final.exists():
                continue
        ogg, md = await asyncio.to_thread(process_raw, f.stem, final)
        rec = {"size": f.size, "downloaded": True, "transcribed": True,
               "ogg": str(ogg), "md": str(md), "deleted": False}
        st["files"][f.name] = rec
        save_state(st)
        if delete_after:
            rec["deleted"] = await client.delete(f.name) is not False
            save_state(st)
        report.append({"file": f.name, "md": str(md)})
    return report


_last_print = {}


def _progress(name: str, got: int, total: int) -> None:
    now = time.time()
    if now - _last_print.get(name, 0) > 3:
        _last_print[name] = now
        pct = f"{got * 100 // total}%" if total else f"{got // 1024}KB"
        log.info("  下载 %s  %s", name, pct)
