"""给 agent 的查询接口：CLI 的 --json 和 MCP 都走这里，返回的都是普通 dict / list。

数据格式见 docs/给你的agent.md「数据格式」。
"""

from __future__ import annotations

import json
import re

from . import scenes as S

_DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _load(day: str) -> dict | None:
    p = S.SCENE_DIR / day / "scenes.json"
    if not _DAY.match(day or "") or not p.exists():
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def _brief(sc: dict) -> dict:
    """不带全文的场景（列表用，省 token）。"""
    return {k: v for k, v in sc.items() if k not in ("text", "_a", "_b")}


def days() -> list[dict]:
    out = []
    for d in sorted((p.name for p in S.SCENE_DIR.iterdir() if p.is_dir()) if S.SCENE_DIR.exists() else [], reverse=True):
        db = _load(d)
        if db:
            real = [s for s in db["scenes"] if s["category"] != S.NOISE]
            out.append({"day": d, "scenes": len(real), "recordings": len(db["recordings"]),
                        "todo": sum(len(S.todo_of(s)) for s in real),
                        "brief": str(S.BRIEF_DIR / f"{d}.md"), "dir": str(S.SCENE_DIR / d)})
    return out


def day(d: str, full: bool = False) -> dict:
    db = _load(d)
    if not db:
        raise KeyError(f"{d} 没有整理过的录音")
    sc = [s if full else _brief(s) for s in db["scenes"] if s["category"] != S.NOISE]
    return {"day": d, "recordings": db["recordings"], "scenes": sc, "brief": str(S.BRIEF_DIR / f"{d}.md")}


def scene(scene_id: str) -> dict:
    m = re.match(r"^(\d{4})(\d{2})(\d{2})-", scene_id or "")
    if m:
        for d in {"-".join(m.groups())} | {x["day"] for x in days()}:  # 跨午夜的录音场景可能挂在前一天
            for s in (_load(d) or {}).get("scenes", []):
                if s["id"] == scene_id:
                    return s
    raise KeyError(f"没有这个场景：{scene_id}")


def search(q: str, limit: int = 20) -> list[dict]:
    """按关键词搜所有场景（标题 / 事件 / 人物 / 观点 / 原文），新的在前；命中原文的带上那一句。"""
    words = [w for w in re.split(r"\s+", q.strip()) if w]
    out = []
    for d in days():
        for s in (_load(d["day"]) or {}).get("scenes", []):
            if s["category"] == S.NOISE:
                continue
            meta = json.dumps(_brief(s), ensure_ascii=False)
            lines = [f"[{t}] {x}" for t, x in s.get("text", [])]
            if all(w in meta or any(w in ln for ln in lines) for w in words):
                hits = [ln for ln in lines if any(w in ln for w in words)][:3]
                out.append(dict(_brief(s), day=d["day"], hits=hits))
                if len(out) >= limit:
                    return out
    return out
