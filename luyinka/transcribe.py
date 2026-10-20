"""转写：silero VAD 在本机切句 → 每句交给识别引擎。

引擎（config.asr.engine）：
  local  本机 SenseVoice int8（sherpa-onnx，离线、免费；模型由 `luyinka setup` 下载）
  cloud  OpenAI 兼容的 /audio/transcriptions（默认硅基流动的 SenseVoiceSmall），只上传切好的一句句音频
长录音按 30 秒一块流式读 wav，内存占用跟录音长度无关。
"""

from __future__ import annotations

import io
import json
import os
import re
import urllib.request
import uuid
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .config import C, path

ASR = C["asr"]
SENSEVOICE_DIR = Path(os.environ.get("LUYINKA_SENSEVOICE", path(ASR["model_dir"])))
VAD_MODEL = Path(os.environ.get("LUYINKA_VAD", path(ASR["vad_model"])))


def load_fixes() -> dict[str, str]:
    """同音纠错：配置里内联的 + 纠错表文件（「错写 → 正确」，每次转写现读）。"""
    fixes = dict(C.get("fixes") or {})
    for f in C.get("corrections_files") or []:
        try:
            lines = path(f).read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            line = line.strip()
            if not line or line.startswith("#") or "→" not in line:
                continue
            wrong, right = (x.strip() for x in line.split("→", 1))
            if wrong and right:
                fixes[wrong] = right
    return fixes


SR = 16000
WINDOW = 512

_TAG = re.compile(r"<\|[^|]*\|>")


@dataclass
class Segment:
    start: float
    end: float
    text: str


class Transcriber:
    def __init__(self, threads: int = 4) -> None:
        import sherpa_onnx as so

        self.so = so
        self.cloud = ASR["engine"] == "cloud"
        need = [VAD_MODEL] if self.cloud else [SENSEVOICE_DIR / "model.int8.onnx", SENSEVOICE_DIR / "tokens.txt", VAD_MODEL]
        for p in need:
            if not p.exists():
                raise FileNotFoundError(f"缺模型文件: {p}（跑一次 `luyinka setup` 会自动下载）")
        self.fixes = load_fixes()
        if not self.cloud:
            self.rec = so.OfflineRecognizer.from_sense_voice(
                model=str(SENSEVOICE_DIR / "model.int8.onnx"), tokens=str(SENSEVOICE_DIR / "tokens.txt"),
                use_itn=True, num_threads=threads, language=os.environ.get("LUYINKA_LANG", ASR.get("language") or "zh"))
        self.vad_cfg = so.VadModelConfig(
            silero_vad=so.SileroVadModelConfig(
                model=str(VAD_MODEL), threshold=0.5, min_silence_duration=0.5,
                min_speech_duration=0.25, window_size=WINDOW, max_speech_duration=20),
            sample_rate=SR)

    def _local(self, samples: np.ndarray) -> str:
        s = self.rec.create_stream()
        s.accept_waveform(SR, samples)
        self.rec.decode_stream(s)
        return s.result.text

    def _cloud(self, samples: np.ndarray) -> str:
        cfg = ASR["cloud"]
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes((np.clip(samples, -1, 1) * 32767).astype(np.int16).tobytes())
        b = uuid.uuid4().hex
        body = (f"--{b}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{cfg['model']}\r\n"
                f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n"
                f"Content-Type: audio/wav\r\n\r\n").encode() + buf.getvalue() + f"\r\n--{b}--\r\n".encode()
        req = urllib.request.Request(cfg["base_url"].rstrip("/") + "/audio/transcriptions", data=body, headers={
            "Content-Type": f"multipart/form-data; boundary={b}", "Authorization": "Bearer " + (cfg.get("api_key") or "")})
        last = None
        for _ in range(3):
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    return json.load(r).get("text") or ""
            except Exception as e:  # noqa: BLE001 — 网络抖一下再试
                last = e
        raise RuntimeError(f"云端转写失败：{last}")

    def _recognize(self, samples: np.ndarray) -> str:
        text = _TAG.sub("", self._cloud(samples) if self.cloud else self._local(samples)).strip()
        for wrong, right in self.fixes.items():
            text = text.replace(wrong, right)
        return text

    def segments(self, wav_path: Path, progress=None):
        vad = self.so.VoiceActivityDetector(self.vad_cfg, buffer_size_in_seconds=120)
        with wave.open(str(wav_path), "rb") as w:
            if w.getframerate() != SR or w.getnchannels() != 1 or w.getsampwidth() != 2:
                raise ValueError("需要 16k 单声道 16bit wav")
            total = w.getnframes()
            pending = np.zeros(0, dtype=np.float32)
            read = 0
            while True:
                raw = w.readframes(SR * 30)
                eof = not raw
                if raw:
                    read += len(raw) // 2
                    chunk = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768
                    pending = np.concatenate([pending, chunk])
                    usable = len(pending) - len(pending) % WINDOW
                    for i in range(0, usable, WINDOW):
                        vad.accept_waveform(pending[i:i + WINDOW])
                    pending = pending[usable:]
                else:
                    if len(pending):
                        vad.accept_waveform(np.pad(pending, (0, WINDOW - len(pending))))
                    vad.flush()
                while not vad.empty():
                    seg = vad.front
                    start = seg.start / SR
                    samples = np.array(seg.samples, dtype=np.float32)
                    vad.pop()
                    text = self._recognize(samples)
                    if text:
                        yield Segment(start, start + len(samples) / SR, text)
                if progress:
                    progress(read, total)
                if eof:
                    break


def fmt_ts(sec: float) -> str:
    sec = int(sec)
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def to_markdown(title: str, segs: list[Segment], meta: dict[str, str] | None = None,
                gap: float = 2.0, max_sec: float | None = None, max_chars: int | None = None) -> str:
    """相邻句子间隔 < gap 秒就并成一段，每段前标开始时间。
    max_sec / max_chars：一段最长多少秒 / 多少字，到了就另起一段（连续说话时句间很少停够 gap，
    不设上限的话几分钟并成一行，钟点只剩一个，后面按钟点切场景就切不准）。"""
    lines = [f"# {title}", ""]
    for k, v in (meta or {}).items():
        lines.append(f"- {k}：{v}")
    if meta:
        lines.append("")
    para: list[Segment] = []

    def flush():
        if para:
            lines.append(f"**[{fmt_ts(para[0].start)}]** " + "".join(s.text for s in para))
            lines.append("")
            para.clear()

    for s in segs:
        if para and (s.start - para[-1].end > gap
                     or (max_sec and s.end - para[0].start > max_sec)
                     or (max_chars and sum(len(x.text) for x in para) + len(s.text) > max_chars)):
            flush()
        para.append(s)
    flush()
    if not segs:
        lines.append("（没有识别到说话）")
    return "\n".join(lines).rstrip() + "\n"
