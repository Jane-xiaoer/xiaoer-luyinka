"""一天的录音 → 场景卡 + 当天简报 → 送进小耳灵感（全程本地 35B，转写全文不出机器）。

    场景/YYYY-MM-DD/scenes.json      当天所有场景（机器用，也是经纪人面板的数据）
    场景/YYYY-MM-DD/HHMM 标题.md      一个场景一张卡：事件 / 核心观点 / 有价值的 / 值得记住的 / 下一步 / 提醒 / 内容详情
    简报/YYYY-MM-DD.md                当天简报：几点在干嘛、拆出了什么

整理完跑配置里的 after_organize：交给用户自己的 agent 按他的规则进他的工作台 / 飞书（docs/给你的agent.md）。
Jane 自己开了 linggan：「下一步行动 / 提醒事项」写进小耳灵感的本机收件口，场景由它的执行器推飞书「录音」表和日历。
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
import os
import re
import shlex
import subprocess
import urllib.request
from pathlib import Path

from . import clock
from .config import APP_DIR, C, path
from .pipeline import AUDIO_DIR, HOME, TEXT_DIR

log = logging.getLogger("luyinka")

SCENE_DIR = HOME / "场景"
BRIEF_DIR = HOME / "简报"
LINGGAN = C["linggan"]
LINGGAN_DATA = Path(os.environ.get("LUYINKA_LINGGAN_DATA", path(LINGGAN["data_dir"])))
LLM = C["llm"]
LLM_URL = os.environ.get("LUYINKA_LLM_URL", LLM["base_url"])
LLM_MODEL = os.environ.get("LUYINKA_LLM_MODEL", LLM["model"])
WINDOW_CHARS = 6000   # 一次喂给模型的转写长度（约 15 分钟连续说话）

SYSTEM = """/no_think
你在帮{owner}整理录音卡录下的一段录音转写。录音卡别在TA身上，录的是TA一天里的聊天、开会、打电话、自言自语。
转写没有区分谁在说话，会有错字（人名、品牌名尤其多），按上下文理解就行。每行开头是钟点。

按话题把它切成「场景」：同一段时间在聊同一件事算一个场景；话题换了、或者中间停了很久，就切开。
别切太碎：一两句的插话、不到 1 分钟的闲聊并进相邻场景。整段都在说一件事就只出一个场景。

每个场景给：
- start / end：从行首钟点里原样抄（HH:MM:SS）
- category：只能从这里选一个：{cats}
- title：4–16 字，说清在干嘛
- event：一句话说这段发生了什么，20–60 字，只陈述不评价，不要以「TA / 用户 / 我」开头
- place：录音里明确说到的地点；没说就留空，别猜
- people：在场或提到的人名，原样写；不是具体的人别写
- views：核心观点 0–3 条：这段里谁提出了什么看法、判断（写清是谁的观点，说不清就不写谁）
- valuable：有价值的内容 0–5 条：信息、数据、方法、资源、报价、联系方式这类以后用得上的
- memorable：值得记住的原话 0–3 句：{"t":"HH:MM:SS","text":"原话"}
- actions：达成的下一步行动：{"t":"HH:MM:SS","text":"原话（只删口水词）","who":"谁去做，说不清留空"}
- reminders：提醒事项，有具体日子或钟点的约定、截止：{"t":"HH:MM:SS","text":"原话","when":"录音里说的时间原样写"}
没有的项给空数组 / 空字符串。闲聊、情绪、重复的话不进 views / valuable / actions。

铁律：不编。转写里没有的不写，推断的不写。

只输出 JSON，不要别的字：
{"scenes":[{"start":"","end":"","category":"","title":"","event":"","place":"","people":[],"views":[],"valuable":[],"memorable":[{"t":"","text":""}],"actions":[{"t":"","text":"","who":""}],"reminders":[{"t":"","text":"","when":""}]}]}"""

CATEGORIES = list(C["categories"])
NOISE = "杂音"   # 这一类不进简报、不送出去
FALLBACK = "与人对话" if "与人对话" in CATEGORIES else next((c for c in CATEGORIES if c != NOISE), "其他")
SYSTEM = SYSTEM.replace("{owner}", C.get("owner") or "主人").replace("{cats}", " / ".join(CATEGORIES) + "（杂音 = 没有能用的内容：电视声、环境声、听不清）")

_LINE = re.compile(r"^\*\*\[(\d+):(\d\d):(\d\d)\]\*\*\s*(.*)$")
_NAME = re.compile(r"(\d{4})-(\d\d)-(\d\d) (\d\d)\.(\d\d)\.(\d\d)")
_SAFE = re.compile(r'[\\/:*?"<>|\n\r\t]')


# ───────── 读转写 ─────────

def recording_start(md: Path) -> _dt.datetime:
    """「2026-10-18 00.02.16 录音.md」→ 开录时刻（卡的钟按 clock.TZ 对过）。"""
    m = _NAME.search(md.stem)
    if not m:
        raise ValueError(f"文件名里没有时间：{md.name}")
    return _dt.datetime(*map(int, m.groups()), tzinfo=clock.TZ)


def load_lines(md: Path) -> list[tuple[float, str]]:
    """转写 md → [(录音内秒数, 这一段文字)]。"""
    out = []
    for line in md.read_text(encoding="utf-8").splitlines():
        m = _LINE.match(line.strip())
        if m and m.group(4).strip():
            h, mi, s, text = m.groups()
            out.append((int(h) * 3600 + int(mi) * 60 + int(s), text.strip()))
    return out


def recordings_of(day: str) -> list[Path]:
    return sorted(p for p in TEXT_DIR.glob(f"{day} *.md") if _NAME.search(p.stem))


def windows(lines: list[tuple[float, str]], limit: int = WINDOW_CHARS) -> list[list[tuple[float, str]]]:
    out, cur, n = [], [], 0
    for sec, text in lines:
        if cur and n + len(text) > limit:
            out.append(cur)
            cur, n = [], 0
        cur.append((sec, text))
        n += len(text)
    return out + ([cur] if cur else [])


# ───────── 模型 ─────────

def call_llm(user: str, timeout: int = 900) -> str:
    body = {"model": LLM_MODEL, "temperature": 0.2,
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]}
    req = urllib.request.Request(LLM_URL.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json",
                                          "Authorization": "Bearer " + (LLM.get("api_key") or "x")})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)["choices"][0]["message"]["content"]


def parse_scenes(raw: str) -> list[dict]:
    raw = re.sub(r"<think>.*?</think>", "", raw, flags=re.S)
    m = re.search(r"\{.*\}", raw, flags=re.S)
    if not m:
        raise ValueError("模型没给 JSON：" + raw[:200])
    scenes = json.loads(m.group(0)).get("scenes")
    if not isinstance(scenes, list):
        raise ValueError("JSON 里没有 scenes")
    return [s for s in scenes if isinstance(s, dict)]


def _clock(t0: _dt.datetime, sec: float) -> str:
    return (t0 + _dt.timedelta(seconds=sec)).strftime("%H:%M:%S")


def _sec(t0: _dt.datetime, clock: str, lo: float, hi: float) -> float:
    """模型抄回来的钟点 → 录音内秒数（抄错了就夹在这一窗里）。"""
    try:
        h, m, s = (int(x) for x in str(clock).split(":"))
    except ValueError:
        return lo
    base = t0.replace(hour=h, minute=m, second=s)
    sec = (base - t0).total_seconds()
    if sec < -43200:  # 跨了午夜
        sec += 86400
    return min(max(sec, lo), hi)


def cut(md: Path, call=call_llm) -> list[dict]:
    """一条录音 → 场景列表（带绝对时刻和这段全文）。"""
    t0 = recording_start(md)
    lines = load_lines(md)
    scenes = []
    for win in windows(lines):
        lo, hi = win[0][0], win[-1][0]
        user = "\n".join(f"[{_clock(t0, sec)}] {text}" for sec, text in win)
        for s in parse_scenes(call(user)):
            a, b = _sec(t0, s.get("start"), lo, hi), _sec(t0, s.get("end"), lo, hi)
            if b < a:
                a, b = b, a
            s["_a"], s["_b"] = a, b
            scenes.append(s)
    scenes.sort(key=lambda s: s["_a"])
    out = []
    for i, s in enumerate(scenes):
        nxt = scenes[i + 1]["_a"] if i + 1 < len(scenes) else float("inf")
        body = [(sec, text) for sec, text in lines if s["_a"] <= sec < max(nxt, s["_b"] + 1)]
        start, end = t0 + _dt.timedelta(seconds=s["_a"]), t0 + _dt.timedelta(seconds=max(s["_b"], s["_a"]))
        out.append({
            "id": f"{start:%Y%m%d-%H%M%S}-lyk",
            "recording": md.stem, "audio": str(AUDIO_DIR / f"{md.stem}.ogg"), "offset": s["_a"],
            "start": start.isoformat(timespec="seconds"), "end": end.isoformat(timespec="seconds"),
            "category": cat if (cat := str(s.get("category") or "")) in CATEGORIES else FALLBACK,
            "title": str(s.get("title") or "")[:30], "event": str(s.get("event") or ""),
            "place": str(s.get("place") or ""), "people": _strs(s.get("people")),
            "views": _strs(s.get("views")), "valuable": _strs(s.get("valuable")),
            "memorable": _pairs(s.get("memorable")), "actions": _pairs(s.get("actions"), "who"),
            "reminders": _pairs(s.get("reminders"), "when"),
            "text": [[_clock(t0, sec), text] for sec, text in body],
        })
    return out


def _strs(xs) -> list[str]:
    return [str(x).strip() for x in (xs or []) if str(x).strip()] if isinstance(xs, list) else []


def _pairs(xs, extra: str = "") -> list[dict]:
    out = []
    for x in xs if isinstance(xs, list) else []:
        if isinstance(x, dict) and str(x.get("text") or "").strip():
            d = {"t": str(x.get("t") or ""), "text": str(x["text"]).strip()}
        elif isinstance(x, str) and x.strip():
            d = {"t": "", "text": x.strip()}
        else:
            continue
        if extra:
            d[extra] = str(x.get(extra) or "").strip() if isinstance(x, dict) else ""
        out.append(d)
    return out


def todo_of(sc: dict) -> list[dict]:
    """要送进小耳灵感的：下一步行动 + 提醒事项。"""
    return sc["actions"] + sc["reminders"]


# ───────── 落地 ─────────

def _hm(iso: str) -> str:
    return iso[11:16]


def _dur(sc: dict) -> str:
    sec = (_dt.datetime.fromisoformat(sc["end"]) - _dt.datetime.fromisoformat(sc["start"])).total_seconds()
    return f"{int(sec // 60)} 分钟" if sec >= 60 else f"{int(sec)} 秒"


def scene_md(sc: dict) -> str:
    meta = [f"**时间** {sc['start'][:10]} {sc['start'][11:19]}–{sc['end'][11:19]}（{_dur(sc)}）", f"**分类** {sc['category']}"]
    if sc["place"]:
        meta.append(f"**地点** {sc['place']}")
    if sc["people"]:
        meta.append(f"**人物** {'、'.join(sc['people'])}")
    lines = [f"# {_hm(sc['start'])}–{_hm(sc['end'])} {sc['title']}", "", f"> {sc['event']}", "", "　".join(meta),
             f"**录音** `{Path(sc['audio']).name}` 从 {int(sc['offset'] // 60)}:{int(sc['offset'] % 60):02d} 起", ""]
    for head, xs in (("核心观点", sc["views"]), ("有价值的内容", sc["valuable"])):
        if xs:
            lines += [f"## {head}", ""] + [f"- {x}" for x in xs] + [""]
    if sc["memorable"]:
        lines += ["## 值得记住的", ""] + [f"> [{x['t']}] {x['text']}" for x in sc["memorable"]] + [""]
    if sc["actions"]:
        lines += ["## 下一步行动", ""] + [f"- [{x['t']}] {x['text']}" + (f"（{x['who']}）" if x.get("who") else "")
                                      for x in sc["actions"]] + [""]
    if sc["reminders"]:
        lines += ["## 提醒事项", ""] + [f"- [{x['t']}] {x['text']}" + (f"（{x['when']}）" if x.get("when") else "")
                                    for x in sc["reminders"]] + [""]
    lines += ["## 内容详情", ""] + [f"**[{t}]** {text}" for t, text in sc["text"]]
    return "\n".join(lines) + "\n"


def brief_md(day: str, scenes: list[dict]) -> str:
    real = [s for s in scenes if s["category"] != NOISE]
    todo = [(s, x) for s in real for x in todo_of(s)]
    people = sorted({p for s in real for p in s["people"]})
    lines = [f"# 录音简报 · {day}", "",
             f"录了 {len({s['recording'] for s in scenes})} 段，切出 {len(real)} 个场景"
             + (f"（另有 {len(scenes) - len(real)} 段杂音）" if len(real) < len(scenes) else "")
             + f"，{len(todo)} 件行动 / 提醒送进了小耳灵感。", ""]
    lines += ["## 一天里", "", "| 时间 | 分类 | 标题 | 事件 |", "|---|---|---|---|"]
    lines += [f"| {_hm(s['start'])}–{_hm(s['end'])} | {s['category']} | {s['title']} | {s['event']} |" for s in real]
    for head, key in (("核心观点", "views"), ("有价值的内容", "valuable")):
        xs = [(s, x) for s in real for x in s[key]]
        if xs:
            lines += ["", f"## {head}", ""] + [f"- {x}（{_hm(s['start'])} {s['title']}）" for s, x in xs]
    if todo:
        lines += ["", "## 下一步 / 提醒", ""] + [f"- {_hm(s['start'])} {s['title']}：{x['text']}" for s, x in todo]
    if people:
        lines += ["", "## 提到的人", "", "、".join(people)]
    return "\n".join(lines) + "\n"


def push_to_linggan(sc: dict) -> str | None:
    """拆出来的条目 → 小耳灵感本机收件口（不经 iCloud）。meta 最后写，分拣器只认有 meta 的。"""
    if not todo_of(sc) or sc.get("capture"):
        return sc.get("capture")
    inbox = LINGGAN_DATA / "直连" / "inbox"
    if not inbox.parent.parent.exists():
        log.warning("没找到小耳灵感的数据目录 %s，拆出来的条目先不送", LINGGAN_DATA)
        return None
    cid = sc["id"]
    d = inbox / cid
    d.mkdir(parents=True, exist_ok=True)
    text = f"【录音卡 · {_hm(sc['start'])}–{_hm(sc['end'])} {sc['title']}】\n" + "\n".join(
        f"[{x['t']}] {x['text']}" + (f"（{x['when']}）" if x.get("when") else "") for x in todo_of(sc))
    meta = {"v": 1, "id": cid, "created_at": sc["start"], "device": "录音卡", "text": text, "files": {},
            "local_only": True,   # 录音里有别人的话：分拣只用本地模型
            "recording": {"day": Path(sc["card"]).parent.name, "scene": sc["id"], "title": sc["title"], "card": sc.get("card"),
                          "scenes": str(Path(sc["card"]).parent / "scenes.json")}}
    tmp = d / "meta.json.tmp"
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(d / "meta.json")
    return cid


def enqueue_feishu(day: str) -> None:
    """排一个「录音推飞书」给小耳灵感的执行器（同一天已在排队就不重复排）。"""
    todo = LINGGAN_DATA / "动作" / "待办"
    if not todo.exists() or list(todo.glob(f"*-录音-{day}.json")):
        return
    p = todo / f"{_dt.datetime.now():%Y%m%d-%H%M%S}-录音-{day}.json"
    p.write_text(json.dumps({"kind": "录音", "day": day, "scenes": str(SCENE_DIR / day / "scenes.json"),
                             "brief": str(BRIEF_DIR / f"{day}.md"),
                             "created_at": clock.now().isoformat(timespec="seconds")},
                            ensure_ascii=False), encoding="utf-8")


def run_hook(day: str) -> None:
    """整理完一天：跑用户配的命令，交给他自己的 agent 按他的规则处理（失败只记日志，不影响整理）。"""
    cmd = (C.get("after_organize") or "").strip()
    if not cmd:
        return
    folder = SCENE_DIR / day
    env = dict(os.environ, LUYINKA_DAY=day, LUYINKA_DAY_DIR=str(folder),
               LUYINKA_SCENES_JSON=str(folder / "scenes.json"), LUYINKA_BRIEF=str(BRIEF_DIR / f"{day}.md"))
    cmd = cmd.format(day=day, day_dir=shlex.quote(str(folder)), scenes_json=shlex.quote(str(folder / "scenes.json")),
                     brief=shlex.quote(str(BRIEF_DIR / f"{day}.md")))
    log.info("交给你的 agent：%s", cmd)
    logf = APP_DIR / "logs" / "agent.log"
    logf.parent.mkdir(parents=True, exist_ok=True)
    with open(logf, "a", encoding="utf-8") as out:
        out.write(f"\n===== {clock.now():%Y-%m-%d %H:%M:%S} {day} =====\n$ {cmd}\n")
        out.flush()
        r = subprocess.run(cmd, shell=True, env=env, stdout=out, stderr=subprocess.STDOUT, cwd=str(folder), timeout=3600)
    if r.returncode:
        log.warning("agent 命令退出码 %s，详情看 %s", r.returncode, logf)


def organize(day: str, push: bool = True, call=call_llm) -> dict:
    """整理某一天：只切还没切过的录音，已有的场景和已送出的条目不动。
    push：送小耳灵感 / 推飞书（只在 linggan.enabled 时）+ 跑 after_organize 钩子。"""
    folder = SCENE_DIR / day
    index = folder / "scenes.json"
    db = json.loads(index.read_text(encoding="utf-8")) if index.exists() else {"day": day, "recordings": [], "scenes": []}
    new = 0
    for md in recordings_of(day):
        if md.stem in db["recordings"]:
            continue
        log.info("切场景 %s", md.stem)
        scenes = cut(md, call)
        for sc in scenes:
            sc["card"] = str(folder / f"{_hm(sc['start']).replace(':', '')} {_SAFE.sub('', sc['title']) or '场景'}.md")
        db["scenes"] += scenes
        db["recordings"].append(md.stem)
        new += len(scenes)
    db["scenes"].sort(key=lambda s: s["start"])
    folder.mkdir(parents=True, exist_ok=True)
    linggan = push and LINGGAN.get("enabled")
    for sc in db["scenes"]:
        Path(sc["card"]).write_text(scene_md(sc), encoding="utf-8")
        if linggan and sc["category"] != NOISE:
            sc["capture"] = push_to_linggan(sc)
    index.write_text(json.dumps(db, ensure_ascii=False, indent=1), encoding="utf-8")
    BRIEF_DIR.mkdir(parents=True, exist_ok=True)
    (BRIEF_DIR / f"{day}.md").write_text(brief_md(day, db["scenes"]), encoding="utf-8")
    if push and new:
        if linggan:
            enqueue_feishu(day)
        run_hook(day)
    return {"day": day, "new": new, "scenes": len(db["scenes"]),
            "todo": sum(len(todo_of(s)) for s in db["scenes"]), "brief": str(BRIEF_DIR / f"{day}.md")}


def days_with_recordings() -> list[str]:
    return sorted({p.stem[:10] for p in TEXT_DIR.glob("*.md") if _NAME.search(p.stem)})
