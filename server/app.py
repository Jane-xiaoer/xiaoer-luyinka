"""录音卡云端：App 把卡上的录音传上来 → 转写 → 切场景 → App 拿回结果。用户电脑和手机上什么模型都不用装。

    POST /v1/register                         → {"token"}            每台装了 App 的设备领一个
    POST /v1/recordings?name=&tz=   body=卡上的原文件（裸 Opus 或 Ogg）  → {"id", "status"}
    GET  /v1/recordings/<id>                  → {"status": queued|working|done|error, "progress", "result"}
    GET  /v1/recordings/<id>/audio            → m4a（App 里播放用）
    POST /v1/recordings?…&asr=1                只转写，不切场景（新版 App 自己按类别整理）
    边拉边传（长录音别等拉完再传）：
    POST /v1/recordings?name=&tz=&asr=1&stream=1  不带 body → {"id", "status": "receiving", "stream": true}
    POST /v1/recordings/<id>/part?seq=N        body=接下来那一段原文件字节（App 按 40 字节帧边界切）→ {"parts": 云端已有几段}
                                               每段一到就排进转写；重传已有的段直接回 ok，跳了号回 409 + parts
    POST /v1/recordings/<id>/finish?parts=N    传完了：各段逐字稿按时间偏移接起来，m4a 用整条原文件出 → 之后同上面 GET
    GET  /healthz 里 "stream": 1 = 这台云端会边拉边传（老云端没有，App 就走一次性上传）
    DELETE /v1/recordings/<id>                App 取走了 → 服务器上这条全删（服务器不留内容）
    POST /v1/llm    {"messages", "temperature"} → {"content"}         不留记录的模型中转（用户没填自己的 key 时）
    POST /v1/ask    {"question", "scenes":[…]} → {"answer"}           「问问我的录音」（旧版 App）
    POST /v1/transcribe  body=16k 单声道 s16le 裸 PCM（一句话） → {"text"}   只转写不切场景（小耳经纪人🎙边说边转借用）
    GET  /healthz
    GET  /                                    下载页（Mac 安装包 + 安卓 APK，放在 <DATA>/download/）
    GET  /download/<文件>

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
from urllib.parse import parse_qs, quote, unquote, urlparse
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from luyinka import clock, opus_ogg, pipeline, scenes  # noqa: E402
from luyinka.config import C  # noqa: E402

DATA = Path(os.environ.get("LUYINKA_CLOUD_DATA", Path.home() / "luyinka-cloud"))
TOKENS = DATA / "tokens.json"
MAX_UPLOAD = 300 * 1024 * 1024          # 一条最多 300MB（裸 Opus 约 2KB/秒，够 40 小时）
DAILY_SECONDS = 24 * 3600               # 每台设备每天最多处理 24 小时录音
DAILY_LLM = 600                         # 每台设备每天最多调 600 次模型（一天录满约 100 次）
KEEP_HOURS = 24                         # App 一直没来取的，过这么久也删
SAFE = re.compile(r"^[0-9A-Za-z_.-]{1,80}$")
MAX_PART = 32 * 1024 * 1024             # 边拉边传的一段（App 默认 1.5MB ≈ 12 分钟）
JOBS: "queue.Queue[tuple]" = queue.Queue()  # (token, rid) 一次性上传；(token, rid, 段号) 转一段；(token, rid, "finish") 接起来
LOCK = threading.Lock()
STATUS_LOCK = threading.Lock()          # status.json：后台线程写进度，请求线程收段，别互相覆盖
PART_LOCK = threading.Lock()


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


def quota_left(token: str) -> float:
    rec = read_json(TOKENS, {}).get(token) or {}
    return DAILY_SECONDS - (rec.get("used") or {}).get(dt.date.today().isoformat(), 0)


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
    with STATUS_LOCK:
        if not d.exists():                                   # App 已经叫删了：别把目录又建回来
            return
        st = read_json(d / "status.json", {})
        st.update(kw)
        write_json(d / "status.json", st)


def _to_ogg(raw: bytes, ogg: Path) -> None:
    if opus_ogg.looks_like_ogg(raw):
        ogg.write_bytes(raw)
    elif not opus_ogg.raw_to_ogg(raw, ogg):
        raise ValueError("文件里没有完整的 Opus 帧")


def process(token: str, dev: str, rid: str) -> None:
    d = job_dir(dev, rid)
    meta = read_json(d / "meta.json")
    set_status(d, status="working", progress=0)
    ogg = d / "audio.ogg"
    _to_ogg((d / "upload.bin").read_bytes(), ogg)

    def segs(prog):
        return _segments(ogg, prog)
    _result(token, d, meta, ogg, segs)
    (d / "upload.bin").unlink(missing_ok=True)              # 原文件处理完就删，只留结果和播放用的 m4a


def _result(token: str, d: Path, meta: dict, ogg: Path, segs_of) -> None:
    """整条的 ogg + 逐字稿（segs_of(prog) 给出带秒数的句子）→ m4a + result.json，status=done。"""
    seconds = pipeline.audio_seconds(ogg)
    if not charge(token, seconds):
        raise ValueError("今天处理的录音超过 24 小时了，明天再传")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(ogg), "-c:a", "aac", "-b:a", "48k", str(d / "audio.m4a")],
                   check=True)
    clock.TZ = ZoneInfo(meta["tz"])                       # 这台设备的时区（单线程按顺序处理，改全局是安全的）
    title = pipeline.nice_name(meta["name"])
    from luyinka.transcribe import fmt_ts, to_markdown
    with tempfile.TemporaryDirectory() as td:
        md = Path(td) / f"{title}.md"

        def prog(done, total):
            set_status(d, progress=int(done * 80 / max(total, 1)))
        md.write_text(to_markdown(title, segs_of(prog), {"时长": fmt_ts(seconds)}, max_sec=30, max_chars=120),
                      encoding="utf-8")
        lines = [[scenes._clock(scenes.recording_start(md), sec), text] for sec, text in scenes.load_lines(md)]
        set_status(d, progress=85)
        cut = scenes.cut(md) if lines and not meta.get("asr") else []
        set_status(d, progress=92)
        scenes.add_minutes(cut)                              # 开会 / 洽谈 → 再出一份标准纪要（旧版 App）
    for s in cut:
        s.pop("audio", None)
        s.pop("card", None)
        if s.get("minutes"):
            s["minutes_md"] = scenes.minutes_md(s)
    start = scenes.recording_start(md).isoformat(timespec="seconds") if scenes._NAME.search(title) else ""
    write_json(d / "result.json", {"recording": title, "start": start, "seconds": round(seconds, 1),
                                   "lines": lines, "scenes": cut})
    ogg.unlink(missing_ok=True)
    set_status(d, status="done", progress=100)


def _segments(ogg: Path, prog=None) -> list:
    """转写成带秒数的句子（模型常驻在 pipeline._transcriber，第一条之后不再加载）。"""
    with tempfile.TemporaryDirectory() as td:
        wav = Path(td) / "a.wav"
        pipeline.to_wav(ogg, wav)
        return _locked_segments(wav, prog)


def _transcriber():
    from luyinka.transcribe import Transcriber
    if pipeline._transcriber is None:
        pipeline._transcriber = Transcriber()
    return pipeline._transcriber


def _locked_segments(wav: Path, prog=None) -> list:
    """整条录音转写：一句一句地占用模型，每转完一句就让出来、让现场会议的句子先插队。
    以前整条一直占着（长录音几分钟），这期间现场会议送来的句子只能干等，实时出字就卡住了。"""
    with ASR_LOCK:
        it = _transcriber().segments(wav, prog)
    out = []
    while True:
        while _WAITING[0]:  # 有现场会议的句子在等：先让它
            time.sleep(0.01)
        with ASR_LOCK:
            seg = next(it, None)
        if seg is None:
            return out
        out.append(seg)


# ───────── 边拉边传：一段一段收、一段一段转，传完接起来 ─────────

def part_file(d: Path, seq: int, ext: str = "bin") -> Path:
    return d / f"part{seq:04d}.{ext}"


def parts_have(d: Path) -> int:
    """云端已经收齐的段数（从 0 连续）。"""
    n = 0
    while part_file(d, n).exists() or part_file(d, n, "json").exists():
        n += 1
    return n


def raw_seconds(raw: bytes) -> float:
    """裸 Opus 的时长：按帧 TOC 加起来（跟整条 ogg 的 granule 同一算法，各段偏移接起来不漂）。"""
    return sum(opus_ogg.toc_samples_48k(f) for f in opus_ogg.split_frames(raw)) / 48000


def stitch(parts: list[dict]) -> list:
    """各段的句子（段内秒数）→ 整条录音的句子：每段加上前面各段的总时长。"""
    from luyinka.transcribe import Segment
    out, offset = [], 0.0
    for p in parts:
        out += [Segment(offset + a, offset + b, t) for a, b, t in p["segs"]]
        offset += p["seconds"]
    return out


def _stream_progress(d: Path, extra: float = 0.0) -> None:
    """转好的段占已收到的比例 → 0–84（接起来 85 → 100，跟一次性上传的进度接得上）。"""
    meta = read_json(d / "meta.json") or {}
    secs = meta.get("part_seconds") or {}
    total = sum(secs.values()) or 1
    done = sum(s for k, s in secs.items() if part_file(d, int(k), "json").exists())
    set_status(d, progress=min(84, int((done + extra) * 84 / total)))


def transcribe_part(dev: str, rid: str, seq: int) -> None:
    d = job_dir(dev, rid)
    src, out = part_file(d, seq), part_file(d, seq, "json")
    if out.exists() or not src.exists():
        return
    if (read_json(d / "status.json") or {}).get("status") in ("done", "error"):
        return
    raw = src.read_bytes()
    seconds = raw_seconds(raw)
    with tempfile.TemporaryDirectory() as td:
        ogg = Path(td) / "p.ogg"
        if not opus_ogg.raw_to_ogg(raw, ogg):
            segs = []
        else:
            segs = _segments(ogg, lambda done, total: _stream_progress(d, seconds * done / max(total, 1)))
    if not d.exists():
        return
    write_json(out, {"seconds": seconds, "segs": [[round(s.start, 3), round(s.end, 3), s.text] for s in segs]})
    _stream_progress(d)


def finish_stream(token: str, dev: str, rid: str) -> None:
    d = job_dir(dev, rid)
    meta = read_json(d / "meta.json")
    n = int(meta["finished"])
    set_status(d, status="working")
    for i in range(n):                                       # 正常早就转好了；重启丢了队列的这里补上
        transcribe_part(dev, rid, i)
    parts = [read_json(part_file(d, i, "json")) for i in range(n)]
    if any(p is None for p in parts):
        raise ValueError("有一段没收到，重新传这条")
    ogg = d / "audio.ogg"
    _to_ogg(b"".join(part_file(d, i).read_bytes() for i in range(n)), ogg)
    _result(token, d, meta, ogg, lambda prog: stitch(parts))
    for i in range(n):
        part_file(d, i).unlink(missing_ok=True)
        part_file(d, i, "json").unlink(missing_ok=True)


ASR_LOCK = threading.Lock()   # 常驻的转写模型：后台整理录音和 /v1/transcribe 共用，一次只让一个用
_WAITING = [0]                # 正在等模型的「一句话」请求数（现场会议实时出字）：后台整理录音看到它就先让
_WAIT = threading.Lock()
MAX_SNIPPET = 10 * 1024 * 1024  # 一句话最多 5 分钟多一点（16k×2 字节/秒）


def transcribe_snippet(pcm: bytes) -> str:
    """一小段裸 PCM → 文字（小耳经纪人边说边转、现场会议用云端识别时一句一句送上来）。比后台整理录音优先。"""
    import wave
    with tempfile.TemporaryDirectory() as td:
        wav = Path(td) / "s.wav"
        with wave.open(str(wav), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(pcm)
        with _WAIT:
            _WAITING[0] += 1
        with ASR_LOCK:
            with _WAIT:
                _WAITING[0] -= 1
            segs = list(_transcriber().segments(wav))
    return "".join(s.text for s in segs).strip()


def worker() -> None:
    while True:
        token, rid, *what = JOBS.get()
        dev = device_of(token)
        d = job_dir(dev, rid)
        t0 = time.time()
        try:
            if not what:
                log("开始", dev, rid)
                process(token, dev, rid)
            elif what[0] == "finish":
                log("接起来", dev, rid)
                finish_stream(token, dev, rid)
            else:
                log("转一段", dev, rid, what[0])
                transcribe_part(dev, rid, what[0])
            log("完成", dev, rid, *what, f"{time.time() - t0:.0f}s")
        except Exception as e:  # noqa: BLE001 — 一条坏了不影响下一条
            log("失败", dev, rid, traceback.format_exc()[-800:])
            set_status(d, status="error", error=str(e)[:300])


def requeue() -> None:
    """重启后把没做完的接着做。"""
    db = read_json(TOKENS, {})
    by_dev = {device_of(t): t for t in db}
    for st in sorted((DATA / "devices").glob("*/*/status.json")):
        status = (read_json(st) or {}).get("status")
        tok = by_dev.get(st.parent.parent.name)
        if not tok or status not in ("queued", "working", "receiving"):
            continue
        d, rid = st.parent, st.parent.name
        meta = read_json(d / "meta.json") or {}
        if meta.get("stream"):
            for i in range(parts_have(d)):
                if not part_file(d, i, "json").exists():
                    JOBS.put((tok, rid, i))
            if meta.get("finished") is not None:
                JOBS.put((tok, rid, "finish"))
        elif (d / "upload.bin").exists():
            JOBS.put((tok, rid))


# ───────── 不留记录的模型中转 ─────────

def llm_chat(messages: list, temperature: float = 0.2) -> str:
    """原样转给服务器配的模型（DeepSeek），只回内容。不写日志、不落盘。"""
    llm = C["llm"]
    body = {"model": llm["model"], "temperature": temperature, "messages": messages}
    req = urllib.request.Request(llm["base_url"].rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json",
                                          "Authorization": "Bearer " + (llm.get("api_key") or "x")})
    with urllib.request.urlopen(req, timeout=300) as r:
        out = json.load(r)["choices"][0]["message"]["content"]
    return re.sub(r"<think>.*?</think>", "", out, flags=re.S).strip()


def count_llm(token: str) -> bool:
    day = dt.date.today().isoformat()
    with LOCK:
        db = read_json(TOKENS, {})
        rec = db.get(token)
        if rec is None:
            return False
        n = rec.setdefault("llm", {})
        if n.get(day, 0) >= DAILY_LLM:
            return False
        rec["llm"] = {day: n.get(day, 0) + 1}
        write_json(TOKENS, db)
    return True


def sweep() -> None:
    """App 没来取（卸载了 / 一直离线）的也别一直留：做完超过 KEEP_HOURS 的整条删掉。"""
    while True:
        cutoff = time.time() - KEEP_HOURS * 3600
        for st in (DATA / "devices").glob("*/*/status.json"):
            # receiving：边拉边传传到一半，App 再也没来（卡丢了 / 卸载了）
            if (read_json(st) or {}).get("status") in ("done", "error", "receiving") and st.stat().st_mtime < cutoff:
                shutil.rmtree(st.parent, ignore_errors=True)
        time.sleep(3600)


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


# ───────── 下载页 ─────────

def download_page() -> str:
    d = DATA / "download"
    files = sorted(d.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True) if d.exists() else []
    mac = next((p.name for p in files if p.suffix == ".dmg"), None)
    apk = next((p.name for p in files if p.suffix == ".apk"), None)

    def btn(name, label, sub):
        if not name:
            return f'<div class="b off">{label}<small>还没上传</small></div>'
        return f'<a class="b" href="/download/{quote(name)}" download>{label}<small>{sub}</small></a>'
    return f"""<!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>小耳录音卡</title><link rel="icon" href="/icon.png"><link rel="apple-touch-icon" href="/icon.png"><style>
body{{margin:0;background:#c9d6c3;color:#1f4a44;font-family:-apple-system,"PingFang SC","Noto Sans SC",sans-serif}}
main{{max-width:520px;margin:48px auto;padding:40px 32px 32px;background:#f8f3e8;border-radius:24px;box-shadow:0 12px 32px rgba(31,74,68,.18)}}
h1{{font-family:"Songti SC","Noto Serif SC",serif;font-size:38px;margin:0 0 4px}}
.wave{{display:block;margin:0 0 20px}}
p{{color:#4f6a64;line-height:1.8;margin:0 0 28px}} .b{{display:flex;flex-direction:column;gap:4px;padding:18px 20px;border-radius:16px;
background:#1f4a44;color:#f8f3e8;text-decoration:none;font-size:18px;font-weight:600;margin-bottom:12px}}
.b small{{font-size:13px;font-weight:400;opacity:.75}} .b.off{{background:#e6dcc8;color:#7f928c}}
ol{{color:#4f6a64;line-height:1.9;padding-left:20px}} ol li::marker{{color:#d95e54}}
@media (max-width:560px){{main{{margin:16px;padding:28px 20px}}}}</style></head><body><main>
<img src="/icon.png" width="96" height="96" alt="" style="display:block;margin:0 0 16px -8px"><h1>小耳录音卡</h1><svg class="wave" width="132" height="12" viewBox="0 0 132 12"><path d="M1 7 Q7 1 13 7 T26 6 Q33 2 39 7 T53 6 Q59 1 66 7 T79 6 Q86 2 92 7 T106 6 Q112 1 119 7 T131 6" fill="none" stroke="#d95e54" stroke-width="2.2" stroke-linecap="round"/></svg><p>录音卡别在身上录一整天，放回手机或电脑旁边，自动拉过来、转成文字、按话题整理好。点一下就能交给你的 AI。</p>
{btn(mac, "下载 Mac 版", "macOS · 拖进「应用程序」就能用")}
{btn(apk, "下载安卓版", "安卓手机 · 下载后点开安装（要允许安装未知来源应用）")}
<ol><li>录音卡开机，放在旁边。</li><li>打开 App，第一次点「允许」使用蓝牙。</li><li>录音会自动出现，一天一页。</li></ol>
</main></body></html>"""


# ───────── HTTP ─────────

class H(BaseHTTPRequestHandler):
    timeout = 120  # 一个连接 2 分钟没收到数据就断，握手不完的不会一直占着线程
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
            return self.send(200, {"ok": True, "queue": JOBS.qsize(), "stream": 1})
        if u.path in ("/", "/download", "/download/"):
            return self.send(200, download_page().encode(), "text/html; charset=utf-8")
        if u.path in ("/icon.png", "/favicon.ico"):
            return self.send(200, (Path(__file__).resolve().parent / "icon.png").read_bytes(), "image/png")
        if u.path.startswith("/download/"):
            name = unquote(u.path[len("/download/"):])
            p = DATA / "download" / name
            if "/" in name or name.startswith(".") or not p.is_file():
                return self.send(404, {"error": "没有这个文件"})
            ctype = "application/vnd.android.package-archive" if name.endswith(".apk") else "application/octet-stream"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(p.stat().st_size))
            self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + quote(name))
            self.end_headers()
            with open(p, "rb") as f:
                shutil.copyfileobj(f, self.wfile)
            return
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
        if (read_json(d / "meta.json") or {}).get("stream") and st.get("status") == "receiving":
            st["parts"] = parts_have(d)
        if st.get("status") == "done":
            st["result"] = read_json(d / "result.json")
        return self.send(200, st)

    def do_DELETE(self):
        a = self.auth()
        if not a:
            return self.send(401, {"error": "没登记，重开一下 App"})
        m = re.match(r"^/v1/recordings/([0-9A-Za-z_-]+)$", urlparse(self.path).path)
        if not m:
            return self.send(404, {"error": "没有这个"})
        d = job_dir(a[1], m.group(1))
        if (read_json(d / "status.json", {}) or {}).get("status") in ("queued", "working"):
            return self.send(409, {"error": "还在处理"})
        shutil.rmtree(d, ignore_errors=True)
        return self.send(200, {"ok": True})

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
                if q.get("stream") == ["1"]:
                    rid = f"{time.strftime('%Y%m%d%H%M%S')}-{secrets.token_hex(3)}"
                    d = job_dir(a[1], rid)
                    d.mkdir(parents=True)
                    write_json(d / "meta.json", {"name": name, "tz": tz, "asr": q.get("asr") == ["1"], "stream": True})
                    set_status(d, status="receiving", progress=0)
                    return self.send(200, {"id": rid, "status": "receiving", "stream": True})
                raw = self.body(MAX_UPLOAD)
                rid = f"{time.strftime('%Y%m%d%H%M%S')}-{secrets.token_hex(3)}"
                d = job_dir(a[1], rid)
                d.mkdir(parents=True)
                (d / "upload.bin").write_bytes(raw)
                write_json(d / "meta.json", {"name": name, "tz": tz, "bytes": len(raw), "asr": q.get("asr") == ["1"]})
                set_status(d, status="queued", progress=0)
                JOBS.put((a[0], rid))
                return self.send(200, {"id": rid, "status": "queued", "ahead": JOBS.qsize() - 1})
            m = re.match(r"^/v1/recordings/([0-9A-Za-z_-]+)/(part|finish)$", u.path)
            if m:
                return _stream_post(self, a, m.group(1), m.group(2), parse_qs(u.query))
            if u.path == "/v1/transcribe":
                pcm = self.body(MAX_SNIPPET)
                if len(pcm) < 3200 or len(pcm) % 2:
                    return self.send(200, {"text": ""})
                if not charge(a[0], len(pcm) / 32000):
                    return self.send(429, {"error": "今天处理的录音超过 24 小时了，明天再传"})
                t0 = time.time()
                text = transcribe_snippet(pcm)
                return self.send(200, {"text": text, "ms": int((time.time() - t0) * 1000)})
            if u.path == "/v1/llm":
                b = json.loads(self.body(2 * 1024 * 1024) or b"{}")
                if not isinstance(b.get("messages"), list) or not b["messages"]:
                    return self.send(400, {"error": "没给 messages"})
                if not count_llm(a[0]):
                    return self.send(429, {"error": "今天整理的次数用完了，明天再来，或在设置里填自己的模型 key"})
                return self.send(200, {"content": llm_chat(b["messages"], float(b.get("temperature") or 0.2))})
            if u.path == "/v1/ask":
                b = json.loads(self.body(2 * 1024 * 1024) or b"{}")
                if not str(b.get("question") or "").strip():
                    return self.send(400, {"error": "没问东西"})
                return self.send(200, {"answer": ask(b["question"], b.get("scenes") or [])})
            return self.send(404, {"error": "没有这个"})
        except Exception as e:  # noqa: BLE001
            log("请求出错", self.path, traceback.format_exc()[-500:])
            return self.send(500, {"error": str(e)[:200]})


def _stream_post(h: H, a: tuple[str, str], rid: str, what: str, q: dict):
    d = job_dir(a[1], rid)
    raw = h.body(MAX_PART) if what == "part" else b""      # 先收完再上锁：别家设备网慢不挡着别人
    with PART_LOCK:
        meta = read_json(d / "meta.json")
        if not meta or not meta.get("stream"):
            return h.send(404, {"error": "没有这条"})
        status = (read_json(d / "status.json") or {}).get("status")
        have = parts_have(d)
        if what == "part":
            seq = int(q.get("seq", ["-1"])[0])
            if seq < have:                                   # App 没记下上次传成功了：已经有了，别重收
                return h.send(200, {"parts": have})
            if status != "receiving":
                return h.send(410, {"error": "这条已经传完或出错了", "status": status})
            if seq != have:
                return h.send(409, {"error": f"该传第 {have} 段", "parts": have})
            secs = raw_seconds(raw)
            got = sum((meta.get("part_seconds") or {}).values())
            if got + secs > quota_left(a[0]):
                return h.send(429, {"error": "今天处理的录音超过 24 小时了，明天再传"})
            tmp = part_file(d, seq, "tmp")
            tmp.write_bytes(raw)
            tmp.replace(part_file(d, seq))
            meta.setdefault("part_seconds", {})[str(seq)] = secs
            meta["bytes"] = meta.get("bytes", 0) + len(raw)
            write_json(d / "meta.json", meta)
            set_status(d, status="receiving")                # 碰一下 mtime：传着的别被 sweep 当成没人要的
            JOBS.put((a[0], rid, seq))
            return h.send(200, {"parts": seq + 1})
        n = int(q.get("parts", ["-1"])[0])
        if status != "receiving":
            return h.send(200, {"id": rid, "status": status})  # 已经 finish 过（App 没记下）：照常
        if n != have or n == 0:
            return h.send(409, {"error": f"云端只收到 {have} 段", "parts": have})
        meta["finished"] = n
        write_json(d / "meta.json", meta)
        set_status(d, status="queued")
        _stream_progress(d)                                  # 按全部段重算，App 看到的进度从这往上走，不往回跳
        JOBS.put((a[0], rid, "finish"))
        return h.send(200, {"id": rid, "status": "queued", "ahead": JOBS.qsize() - 1})



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
    threading.Thread(target=sweep, daemon=True).start()
    requeue()
    httpd = ThreadingHTTPServer((args.host, args.port), H)
    if args.tls_cert:
        import ssl

        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.tls_cert, args.tls_key)
        # 握手放到各自的请求线程里做（读第一个字节时），别在 accept() 里：
        # 以前有人连上 8443 不握手（扫描器），主线程卡在 accept 里的握手上，整个云端不再接新连接。
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
    log(f"录音卡云端在 {'https' if args.tls_cert else 'http'}://{args.host}:{args.port}，数据 {DATA}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
