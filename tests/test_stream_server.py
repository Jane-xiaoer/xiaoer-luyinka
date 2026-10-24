"""云端边拉边传：分段收、分段转、按时间偏移接起来，结果要跟一次性上传的一样；老接口照常能用。
转写模型换成假的（每 5 秒一句），只测拼接和接口，不加载 SenseVoice。"""

import json
import subprocess
import threading
import time
import urllib.error
import urllib.request
import wave
from http.server import ThreadingHTTPServer

import pytest

from luyinka import pipeline
from luyinka.transcribe import Segment
from server import app


class FakeTranscriber:
    """每 5 秒一句、每句 2 秒（句间隔 3 秒 > 合并阈值，每句单独一行）。"""

    def segments(self, wav, progress=None):
        with wave.open(str(wav), "rb") as w:
            dur = w.getnframes() / w.getframerate()
        t = 0.0
        while t + 2 <= dur:
            yield Segment(t, t + 2, "说话")
            t += 5
        if progress:
            progress(1, 1)


def ogg_packets(data: bytes) -> list[bytes]:
    pkts, cur, i = [], b"", 0
    while i < len(data):
        nseg = data[i + 26]
        lacing = data[i + 27:i + 27 + nseg]
        pos = i + 27 + nseg
        for n in lacing:
            cur += data[pos:pos + n]
            pos += n
            if n < 255:
                pkts.append(cur)
                cur = b""
        i = pos
    return pkts


@pytest.fixture(scope="module")
def card_raw(tmp_path_factory):
    """35 秒卡格式的裸 Opus（CBR 16kbps、20ms → 每帧 40 字节）。"""
    ogg = tmp_path_factory.mktemp("enc") / "a.ogg"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=35",
                    "-ar", "16000", "-ac", "1", "-c:a", "libopus", "-b:a", "16k", "-vbr", "off",
                    "-frame_duration", "20", "-application", "voip", str(ogg)], check=True)
    pkts = ogg_packets(ogg.read_bytes())[2:]
    assert pkts and all(len(p) == 40 for p in pkts)
    return b"".join(pkts)


_worker: list = []


@pytest.fixture()
def cloud(tmp_path, monkeypatch):
    monkeypatch.setattr(app, "DATA", tmp_path)
    monkeypatch.setattr(app, "TOKENS", tmp_path / "tokens.json")
    monkeypatch.setattr(pipeline, "_transcriber", FakeTranscriber())
    while not app.JOBS.empty():
        app.JOBS.get_nowait()
    if not _worker:  # 跟线上一样只有一个后台线程
        _worker.append(threading.Thread(target=app.worker, daemon=True))
        _worker[0].start()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), app.H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{httpd.server_port}"
    token = call(base, "POST", "/v1/register")[1]["token"]
    yield base, token
    httpd.shutdown()


def call(base, method, path, body=b"", token=None):
    req = urllib.request.Request(base + path, data=body if method == "POST" else None, method=method,
                                 headers={"Authorization": f"Bearer {token or ''}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def wait_done(base, token, rid):
    for _ in range(300):
        code, st = call(base, "GET", f"/v1/recordings/{rid}", token=token)
        assert code == 200, st
        assert st["status"] != "error", st
        if st["status"] == "done":
            return st["result"]
        time.sleep(0.1)
    raise AssertionError("没做完")


Q = "name=note20261023-194438.&tz=America/Los_Angeles&asr=1"
PART = 40 * 500  # 10 秒一段（测试用；App 默认 1.5MB）


def test_stitch_offsets():
    segs = app.stitch([{"seconds": 10.0, "segs": [[0, 2, "a"], [5, 7, "b"]]},
                       {"seconds": 4.5, "segs": [[1, 2, "c"]]},
                       {"seconds": 3.0, "segs": [[0.5, 1, "d"]]}])
    assert [(s.start, s.end, s.text) for s in segs] == [(0, 2, "a"), (5, 7, "b"), (11, 12, "c"), (15, 15.5, "d")]


def test_raw_seconds_counts_frames(card_raw):
    assert app.raw_seconds(card_raw) == pytest.approx(len(card_raw) // 40 * 0.02)
    assert app.raw_seconds(card_raw + b"\x01\x02") == app.raw_seconds(card_raw)  # 残片不算


def test_stream_matches_one_shot(cloud, card_raw):
    base, tok = cloud
    assert call(base, "GET", "/healthz")[1]["stream"] == 1

    # 老接口：一次性上传（下载页上的旧版 App 还在用）
    code, d = call(base, "POST", f"/v1/recordings?{Q}", card_raw, tok)
    assert code == 200 and d["status"] == "queued"
    whole = wait_done(base, tok, d["id"])

    # 边拉边传
    code, d = call(base, "POST", f"/v1/recordings?{Q}&stream=1", b"", tok)
    assert code == 200 and d["stream"] is True and d["status"] == "receiving"
    rid = d["id"]
    chunks = [card_raw[i:i + PART] for i in range(0, len(card_raw), PART)]
    assert len(chunks) == 4
    assert call(base, "POST", f"/v1/recordings/{rid}/part?seq=0", chunks[0], tok) == (200, {"parts": 1})
    assert call(base, "POST", f"/v1/recordings/{rid}/part?seq=1", chunks[1], tok) == (200, {"parts": 2})
    # App 没记下第 1 段传成功了，又传一次：不重收
    assert call(base, "POST", f"/v1/recordings/{rid}/part?seq=1", chunks[1], tok) == (200, {"parts": 2})
    # 跳号：告诉 App 该从哪段接
    code, d = call(base, "POST", f"/v1/recordings/{rid}/part?seq=3", chunks[3], tok)
    assert code == 409 and d["parts"] == 2
    # 段还没收完就 finish：拒绝
    assert call(base, "POST", f"/v1/recordings/{rid}/finish?parts=4", b"", tok)[0] == 409
    # 第一段在传完之前就已经转好了
    for _ in range(100):
        if (app.job_dir(app.device_of(tok), rid) / "part0000.json").exists():
            break
        time.sleep(0.05)
    assert (app.job_dir(app.device_of(tok), rid) / "part0000.json").exists()
    code, st = call(base, "GET", f"/v1/recordings/{rid}", token=tok)
    assert st["status"] == "receiving" and st["parts"] == 2 and st["progress"] > 0
    for i in (2, 3):
        assert call(base, "POST", f"/v1/recordings/{rid}/part?seq={i}", chunks[i], tok)[0] == 200
    code, d = call(base, "POST", f"/v1/recordings/{rid}/finish?parts=4", b"", tok)
    assert code == 200 and d["status"] == "queued"
    res = wait_done(base, tok, rid)

    assert res["lines"] == whole["lines"]
    assert [x[0] for x in res["lines"]][:3] == ["19:44:38", "19:44:43", "19:44:48"]
    assert res["seconds"] == whole["seconds"] and res["start"] == whole["start"]
    assert res["recording"] == whole["recording"]
    d = app.job_dir(app.device_of(tok), rid)
    assert (d / "audio.m4a").stat().st_size > 1000
    assert not list(d.glob("part*")), "分段的原文件和中间结果接完就删"
    # 只按整条扣一次额度（两条录音各 35 秒）
    used = json.loads(app.TOKENS.read_text())[tok]["used"]
    assert sum(used.values()) == pytest.approx(2 * whole["seconds"], abs=0.5)
    # finish 后再传段：已经结束了
    assert call(base, "POST", f"/v1/recordings/{rid}/part?seq=4", chunks[3], tok)[0] == 410
    # 再 finish 一次（App 没记下上次成功）：照常回
    assert call(base, "POST", f"/v1/recordings/{rid}/finish?parts=4", b"", tok)[1]["status"] == "done"


def test_requeue_resumes_stream(cloud, card_raw):
    """云端重启：收到的段没转的接着转，finish 过的接着接。"""
    base, tok = cloud
    rid = call(base, "POST", f"/v1/recordings?{Q}&stream=1", b"", tok)[1]["id"]
    d = app.job_dir(app.device_of(tok), rid)
    with app.PART_LOCK:  # 模拟：段收下了，但重启丢了队列（直接写文件，不排进队列）
        meta = json.loads((d / "meta.json").read_text())
        for i in range(2):
            chunk = card_raw[i * PART:(i + 1) * PART]
            app.part_file(d, i).write_bytes(chunk)
            meta.setdefault("part_seconds", {})[str(i)] = app.raw_seconds(chunk)
        meta["finished"] = 2
        app.write_json(d / "meta.json", meta)
        app.set_status(d, status="queued")
    app.requeue()
    res = wait_done(base, tok, rid)
    assert res["seconds"] == pytest.approx(20, abs=0.1)
    assert [x[0] for x in res["lines"]] == ["19:44:38", "19:44:43", "19:44:48", "19:44:53"]
