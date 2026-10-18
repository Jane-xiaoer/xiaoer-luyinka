"""本地转写：silero VAD 切句 + SenseVoice 识别（sherpa-onnx，离线、免费）。

模型复用 RTC 项目已装好的 SenseVoice int8（~/projects/RTC/asr_local/official_sensevoice/），
VAD 模型在本项目 models/silero_vad.onnx。
长录音按 30 秒一块流式读 wav，内存占用跟录音长度无关。
"""

from __future__ import annotations

import os
import re
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SENSEVOICE_DIR = Path(os.environ.get(
    "LUYINKA_SENSEVOICE", Path.home() / "projects/RTC/asr_local/official_sensevoice"))
# 同音纠错：自己的名字/专有词
FIXES = {"小尔": "小耳", "小二录音卡": "小耳录音卡"}
VAD_MODEL = Path(os.environ.get("LUYINKA_VAD", ROOT / "models/silero_vad.onnx"))
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

        model = SENSEVOICE_DIR / "model.int8.onnx"
        tokens = SENSEVOICE_DIR / "tokens.txt"
        for p in (model, tokens, VAD_MODEL):
            if not p.exists():
                raise FileNotFoundError(f"缺模型文件: {p}")
        self.so = so
        self.rec = so.OfflineRecognizer.from_sense_voice(
            model=str(model), tokens=str(tokens), use_itn=True, num_threads=threads,
            language=os.environ.get("LUYINKA_LANG", "zh"))
        self.vad_cfg = so.VadModelConfig(
            silero_vad=so.SileroVadModelConfig(
                model=str(VAD_MODEL), threshold=0.5, min_silence_duration=0.5,
                min_speech_duration=0.25, window_size=WINDOW, max_speech_duration=20),
            sample_rate=SR)

    def _recognize(self, samples: np.ndarray) -> str:
        s = self.rec.create_stream()
        s.accept_waveform(SR, samples)
        self.rec.decode_stream(s)
        text = _TAG.sub("", s.result.text).strip()
        for wrong, right in FIXES.items():
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
                gap: float = 2.0) -> str:
    """相邻句子间隔 < gap 秒就并成一段，每段前标开始时间。"""
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
        if para and s.start - para[-1].end > gap:
            flush()
        para.append(s)
    flush()
    if not segs:
        lines.append("（没有识别到说话）")
    return "\n".join(lines).rstrip() + "\n"
