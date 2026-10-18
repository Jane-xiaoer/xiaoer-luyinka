"""录音卡云端：App 把卡上的录音传上来 → 转写 → 切场景 → App 拿回结果。用户电脑和手机上什么模型都不用装。

    POST /v1/register                         → {"token"}            每台装了 App 的设备领一个
    POST /v1/recordings?name=&tz=   body=卡上的原文件（裸 Opus 或 Ogg）  → {"id", "status"}
    GET  /v1/recordings/<id>                  → {"status": queued|working|done|error, "progress", "result"}
    GET  /v1/recordings/<id>/audio            → m4a（App 里播放用）
    POST /v1/ask    {"question", "scenes":[…]} → {"answer"}           「问问我的录音」
    GET  /healthz

result = {"recording", "start", "seconds", "lines": [[钟点, 文字]…], "scenes": [场景…]}（场景格式同 docs/给你的agent.md）

跑：LUYINKA_CONFIG=server.json python3 -m server.app --port 8790
server.json 里的 asr / llm 就是服务器用的转写和大模型（同 ~/.luyinka/config.json 的格式）。
一个后台线程按顺序处理，所以每条录音之间不会抢内存。
"""

from __future__ import annotations

import argparse
import datetime as dt
import hmac
import json
import os
import queue
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from luyinka import clock, opus_ogg, pipeline, scenes  # noqa: E402
from luyinka.config import C  # noqa: E402

DATA = Path(os.environ.get("LUYINKA_CLOUD_DATA", Path.home() / "luyinka-cloud"))
TOKENS = DATA / "tokens.json"
MAX_UPLOAD = 300 * 1024 * 1024          # 一条最多 300MB（裸 Opus 约 2KB/秒，够 40 小时）
DAILY_SECONDS = 24 * 3600               # 每台设备每天最多处理 24 小时录音
SAFE = re.compile(r"^[0-9A-Za-z_.-]{1,80}$")
JOBS: "queue.Queue[tuple[str, str]]" = queue.Queue()
LOCK = threading.Lock()


def log(*a):
    print(time.strftime("%m-%d %H:%M:%S"), *a, flush=True)


def read_json(p: Path, default=None):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def write_json(p: Path, obj) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")
    tmp.replace(p)


# ───────── 设备 ─────────

def register() -> str:
    tok = secrets.token_urlsafe(24)
    with LOCK:
        db = read_json(TOKENS, {})
        db[tok] = {"created": dt.datetime.now().isoformat(timespec="seconds"), "used": {}}
        write_json(TOKENS, db)
    return tok


def device_of(token: str) -> str | None:
    db = read_json(TOKENS, {})
    for tok in db:
        if hmac.compare_digest(tok, token or ""):
            return tok[:12].replace("-", "x").replace("_", "y")
    return None


def charge(token: str, seconds: float) -> bool:
    """记今天用了多少秒，超额就拒。"""
    day = dt.date.today().isoformat()
    with LOCK:
        db = read_json(TOKENS, {})
        rec = db.get(token)
        if rec is None:
            return False
        used = rec.setdefault("used", {})
        if used.get(day, 0) + seconds > DAILY_SECONDS:
            return False
        used[day] = used.get(day, 0) + seconds
        rec["used"] = {k: v for k, v in used.items() if k >= (dt.date.today() - dt.timedelta(days=7)).isoformat()}
        write_json(TOKENS, db)
    return True


# ───────── 处理一条录音 ─────────

def job_dir(dev: str, rid: str) -> Path:
    return DATA / "devices" / dev / rid


def set_status(d: Path, **kw) -> None:
    st = read_json(d / "status.json", {})
    st.update(kw)
    write_json(d / "status.json", st)


def process(token: str, dev: str, rid: str) -> None:
    d = job_dir(dev, rid)
    meta = read_json(d / "meta.json")
    raw = (d / "upload.bin").read_bytes()
    set_status(d, status="working", progress=0)
    ogg = d / "audio.ogg"
    if opus_ogg.looks_like_ogg(raw):
        ogg.write_bytes(raw)
    elif not opus_ogg.raw_to_ogg(raw, ogg):
        raise ValueError("文件里没有完整的 Opus 帧")
    seconds = pipeline.audio_seconds(ogg)
    if not charge(token, seconds):
        raise ValueError("今天处理的录音超过 24 小时了，明天再传")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(ogg), "-c:a", "aac", "-b:a", "48k", str(d / "audio.m4a")],
                   check=True)
    clock.TZ = ZoneInfo(meta["tz"])                       # 这台设备的时区（单线程按顺序处理，改全局是安全的）
    title = pipeline.nice_name(meta["name"])
    with tempfile.TemporaryDirectory() as td:
        md = Path(td) / f"{title}.md"

        def prog(done, total):
            set_status(d, progress=int(done * 80 / max(total, 1)))
        _transcribe(ogg, md, title, prog)
        lines = [[scenes._clock(scenes.recording_start(md), sec), text] for sec, text in scenes.load_lines(md)]
        set_status(d, progress=85)
        cut = scenes.cut(md) if lines else []
    for s in cut:
        s.pop("audio", None)
        s.pop("card", None)
    start = scenes.recording_start(md).isoformat(timespec="seconds") if scenes._NAME.search(title) else ""
    write_json(d / "result.json", {"recording": title, "start": start, "seconds": round(seconds, 1),
                                   "lines": lines, "scenes": cut})
    (d / "upload.bin").unlink(missing_ok=True)              # 原文件处理完就删，只留结果和播放用的 m4a
    ogg.unlink(missing_ok=True)
    set_status(d, status="done", progress=100)


def _transcribe(ogg: Path, md: Path, title: str, prog) -> None:
    """转写成 md（模型常驻在 pipeline._transcriber，第一条之后不再加载）。"""
    from luyinka.transcribe import Transcriber, fmt_ts, to_markdown

    if pipeline._transcriber is None:
        pipeline._transcriber = Transcriber()
    with tempfile.TemporaryDirectory() as td:
        wav = Path(td) / "a.wav"
        pipeline.to_wav(ogg, wav)
        segs = list(pipeline._transcriber.segments(wav, prog))
    md.write_text(to_markdown(title, segs, {"时长": fmt_ts(pipeline.audio_seconds(ogg))}), encoding="utf-8")


def worker() -> None:
    while True:
        token, rid = JOBS.get()
        dev = device_of(token)
        d = job_dir(dev, rid)
        t0 = time.time()
        try:
            log("开始", dev, rid)
            process(token, dev, rid)
            log("完成", dev, rid, f"{time.time() - t0:.0f}s")
        except Exception as e:  # noqa: BLE001 — 一条坏了不影响下一条
            log("失败", dev, rid, traceback.format_exc()[-800:])
            set_status(d, status="error", error=str(e)[:300])


def requeue() -> None:
    """重启后把没做完的接着做。"""
    db = read_json(TOKENS, {})
    by_dev = {device_of(t): t for t in db}
    for st in sorted((DATA / "devices").glob("*/*/status.json")):
        if (read_json(st) or {}).get("status") in ("queued", "working") and (st.parent / "upload.bin").exists():
            tok = by_dev.get(st.parent.parent.name)
            if tok:
                JOBS.put((tok, st.parent.name))


# ───────── 问问我的录音 ─────────

ASK_SYSTEM = """你是用户的录音助手。下面是用户录音卡整理出的场景（JSON），只根据这些回答用户的问题。
回答要短、直接，用中文；提到具体内容时带上日期和钟点（如「10/18 14:05 跟老王谈报价」）。录音里没有的就说没找到，别编。"""


def ask(question: str, scenes_ctx: list) -> str:
    llm = C["llm"]
    ctx = json.dumps(scenes_ctx, ensure_ascii=False)[:60000]
    body = {"model": llm["model"], "temperature": 0.3,
            "messages": [{"role": "system", "content": ASK_SYSTEM},
                         {"role": "user", "content": f"## 我的录音场景\n{ctx}\n\n## 我的问题\n{question}"}]}
    req = urllib.request.Request(llm["base_url"].rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json",
                                          "Authorization": "Bearer " + (llm.get("api_key") or "x")})
    with urllib.request.urlopen(req, timeout=180) as r:
        out = json.load(r)["choices"][0]["message"]["content"]
    return re.sub(r"<think>.*?</think>", "", out, flags=re.S).strip()


# ───────── HTTP ─────────

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def auth(self) -> tuple[str, str] | None:
        tok = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
        dev = device_of(tok)
        return (tok, dev) if dev else None

    def body(self, limit: int) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise ValueError("太大了")
        return self.rfile.read(n)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/healthz":
            return self.send(200, {"ok": True, "queue": JOBS.qsize()})
        a = self.auth()
        if not a:
            return self.send(401, {"error": "没登记，重开一下 App"})
        m = re.match(r"^/v1/recordings/([0-9A-Za-z_-]+)(/audio)?$", u.path)
        if not m:
            return self.send(404, {"error": "没有这个"})
        d = job_dir(a[1], m.group(1))
        if not d.exists():
            return self.send(404, {"error": "没有这条"})
        if m.group(2):
            p = d / "audio.m4a"
            return self.send(200, p.read_bytes(), "audio/mp4") if p.exists() else self.send(404, {"error": "还没好"})
        st = read_json(d / "status.json", {})
        if st.get("status") == "done":
            st["result"] = read_json(d / "result.json")
        return self.send(200, st)

    def do_POST(self):
        u = urlparse(self.path)
        try:
            if u.path == "/v1/register":
                return self.send(200, {"token": register()})
            a = self.auth()
            if not a:
                return self.send(401, {"error": "没登记，重开一下 App"})
            if u.path == "/v1/recordings":
                q = parse_qs(u.query)
                name, tz = q.get("name", [""])[0], q.get("tz", ["Asia/Shanghai"])[0]
                if not SAFE.match(name):
                    return self.send(400, {"error": "文件名不对"})
                ZoneInfo(tz)
                raw = self.body(MAX_UPLOAD)
                rid = f"{time.strftime('%Y%m%d%H%M%S')}-{secrets.token_hex(3)}"
                d = job_dir(a[1], rid)
                d.mkdir(parents=True)
                (d / "upload.bin").write_bytes(raw)
                write_json(d / "meta.json", {"name": name, "tz": tz, "bytes": len(raw)})
                set_status(d, status="queued", progress=0)
                JOBS.put((a[0], rid))
                return self.send(200, {"id": rid, "status": "queued", "ahead": JOBS.qsize() - 1})
            if u.path == "/v1/ask":
                b = json.loads(self.body(2 * 1024 * 1024) or b"{}")
                if not str(b.get("question") or "").strip():
                    return self.send(400, {"error": "没问东西"})
                return self.send(200, {"answer": ask(b["question"], b.get("scenes") or [])})
            return self.send(404, {"error": "没有这个"})
        except Exception as e:  # noqa: BLE001
            log("请求出错", self.path, traceback.format_exc()[-500:])
            return self.send(500, {"error": str(e)[:200]})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("PORT", 8790)))
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--tls-cert", help="https 证书（fullchain）；不给就是 http")
    ap.add_argument("--tls-key")
    args = ap.parse_args()
    DATA.mkdir(parents=True, exist_ok=True)
    if not shutil.which("ffmpeg"):
        sys.exit("服务器上要装 ffmpeg")
    threading.Thread(target=worker, daemon=True).start()
    requeue()
    httpd = ThreadingHTTPServer((args.host, args.port), H)
    if args.tls_cert:
        import ssl

        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.tls_cert, args.tls_key)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    log(f"录音卡云端在 {'https' if args.tls_cert else 'http'}://{args.host}:{args.port}，数据 {DATA}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
