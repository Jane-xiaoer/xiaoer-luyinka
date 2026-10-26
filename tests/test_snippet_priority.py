"""现场会议用云端识别时，一句一句送上来；后台正在转一条长录音也不能让它干等（长录音每转完一句就让出模型）。"""
import threading
import time
from pathlib import Path

from luyinka import pipeline
from luyinka.transcribe import Segment
from server import app


class SlowModel:
    """假模型：长录音 40 句、每句 50ms；一句话 1 句。"""

    def segments(self, wav, prog=None):
        n = 1 if "s.wav" in str(wav) else 40
        for i in range(n):
            time.sleep(0.05)
            yield Segment(i, i + 1, f"第{i}句")


def test_live_sentence_cuts_in_line(tmp_path, monkeypatch):
    monkeypatch.setattr(pipeline, "_transcriber", SlowModel())
    long_done = []
    t = threading.Thread(target=lambda: long_done.append(app._locked_segments(Path(tmp_path / "a.wav"))))
    t.start()
    time.sleep(0.2)  # 长录音已经在转了
    t0 = time.time()
    text = app.transcribe_snippet(b"\0" * 32000)
    waited = time.time() - t0
    assert text == "第0句"
    assert waited < 0.5, f"一句话等了 {waited:.2f} 秒（长录音要 2 秒），没插上队"
    assert not long_done  # 长录音还没转完，句子已经回去了
    t.join()
    assert len(long_done[0]) == 40  # 长录音一句没少
