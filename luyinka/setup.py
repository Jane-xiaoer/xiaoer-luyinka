"""`luyinka setup`：一步步配好，回车 = 用括号里的默认值。重跑会带上次填的，随时可以改。

  1 产出放哪   2 时区   3 转写（本机 / 云端）  4 整理用的大模型   5 接你的 agent   6 找卡   7 自动拉
"""

from __future__ import annotations

import asyncio
import json
import os
import plistlib
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

from . import config as CF

PKG_ROOT = Path(__file__).resolve().parent.parent
RULES = CF.APP_DIR / "整理规则.md"
LABEL = "com.luyinka.pull"
PLIST = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"

RULES_TEMPLATE = """# 录音卡整理规则（给我的 agent 看的）

> 每天录音整理完，录音卡会叫你的 agent 读这份规则，按它处理当天的场景。随便改，改完下次生效。
> 数据：当天的 scenes.json（路径在命令里给），格式见 luyinka 的 docs/给你的agent.md。

## 我是谁
（写几句：你做什么工作、在乎什么，agent 判断「什么值得记」靠这个）

## 每天要做的
1. 读当天的 scenes.json，跳过「杂音」。
2. 每个场景在我的工作台里记一条：时间、标题、分类、人物、事件、核心观点、下一步行动、提醒事项。
   - 我的工作台是：（例：飞书多维表格 https://xxx.feishu.cn/base/xxx，用 lark-cli 写；或 Notion 数据库；或 ~/Notes/录音/ 文件夹）
3. 「下一步行动」进我的待办，「提醒事项」进我的日历（有具体时间的）。
4. 最后给我一段 5 行以内的总结：今天聊了什么、要我马上看的。

## 别做的
- 不对外发任何东西（不发消息、不发邮件、不发帖）。
- 原文里没有的不写。
"""

AGENTS = {
    "1": ("Claude Code", "claude",
          'claude -p "按 {rules} 里的规则处理 {{day}} 的录音。数据：{{scenes_json}}" '
          '--allowedTools "Read,Write,Edit,Bash,mcp__luyinka__*"'),
    "2": ("Codex", "codex",
          'codex exec --full-auto "按 {rules} 里的规则处理 {{day}} 的录音。数据：{{scenes_json}}"'),
}


def ask(q: str, default: str = "") -> str:
    a = input(f"{q}" + (f" [{default}]" if default else "") + "：").strip()
    return a or default


def yes(q: str, default: bool = True) -> bool:
    a = input(f"{q} [{'Y/n' if default else 'y/N'}]：").strip().lower()
    return default if not a else a.startswith("y")


def _bar(name, have, total):
    n = int(30 * have / max(total, 1))
    print(f"\r  {name} [{'#' * n}{'.' * (30 - n)}] {have / 1e6:.0f}/{total / 1e6:.0f} MB", end="", flush=True)


def _test_llm(llm: dict) -> str:
    body = json.dumps({"model": llm["model"], "messages": [{"role": "user", "content": "回一个字：好"}],
                       "max_tokens": 10}).encode()
    req = urllib.request.Request(llm["base_url"].rstrip("/") + "/chat/completions", data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + (llm.get("api_key") or "x")})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["choices"][0]["message"]["content"].strip()


def run() -> None:
    cfg = CF.load()
    print("\n🎙 录音卡设置（回车 = 用括号里的）\n")

    print("1/7 录音、文字、场景放哪个文件夹")
    cfg["home"] = ask("  文件夹", cfg["home"])
    CF.path(cfg["home"]).mkdir(parents=True, exist_ok=True)

    print("\n2/7 你按哪个时区过日子（卡上的钟按它对）")
    cfg["timezone"] = ask("  时区", cfg["timezone"] or "Asia/Shanghai")

    print("\n3/7 转写：1 = 本机（免费、不联网，要下载约 230MB 模型）  2 = 云端（快、要 API key，默认硅基流动）")
    if ask("  选", "2" if cfg["asr"]["engine"] == "cloud" else "1") == "2":
        cfg["asr"]["engine"] = "cloud"
        c = cfg["asr"]["cloud"]
        c["base_url"] = ask("  接口地址", c["base_url"])
        c["api_key"] = ask("  API key", c["api_key"])
        c["model"] = ask("  模型", c["model"])
    else:
        cfg["asr"]["engine"] = "local"

    print("\n4/7 把一天的录音切成场景、提炼要点，用哪个大模型（任何 OpenAI 兼容接口）")
    llm = cfg["llm"]
    llm["base_url"] = ask("  接口地址（DeepSeek / 通义 / Kimi / 本地 ollama 都行）", llm["base_url"])
    llm["api_key"] = ask("  API key", llm["api_key"])
    llm["model"] = ask("  模型", llm["model"])
    try:
        print("  试一下：", _test_llm(llm))
    except Exception as e:  # noqa: BLE001
        print(f"  ⚠️  没通：{e}\n  先存下，回头 `luyinka setup` 再改。")
    cfg["owner"] = ask("  它该怎么称呼你", cfg.get("owner") or "我")

    CF.save(cfg)
    CF.C.clear()
    CF.C.update(CF.load())
    from . import models

    need = models.missing(cfg["asr"]["engine"] == "local")
    if need:
        print("\n  下载模型：", "、".join(need))
        models.download(cfg["asr"]["engine"] == "local", _bar)
        print()

    print("\n5/7 每天整理完，交给你自己的 agent 按你的规则处理（进你的工作台 / 飞书 / Notion）")
    if not RULES.exists():
        RULES.write_text(RULES_TEMPLATE, encoding="utf-8")
    found = {k: v for k, v in AGENTS.items() if shutil.which(v[1])}
    opts = "  ".join(f"{k} = {v[0]}" for k, v in found.items())
    pick = ask(f"  {opts + '  ' if opts else ''}3 = 自己写命令  0 = 先不接", "1" if "1" in found else "0")
    if pick in found:
        cfg["after_organize"] = found[pick][2].format(rules=RULES)
    elif pick == "3":
        cfg["after_organize"] = ask("  命令（可用 {day} {day_dir} {scenes_json} {brief}）", cfg["after_organize"])
    elif pick == "0":
        cfg["after_organize"] = ""
    if cfg["after_organize"]:
        print(f"  规则在 {RULES}，打开改成你的。")
        subprocess.run(["open", str(RULES)])
    if shutil.which("claude") and yes("  把录音卡接进 Claude Code（MCP，以后直接问它「上周跟谁聊过 XX」）"):
        subprocess.run(["claude", "mcp", "remove", "-s", "user", "luyinka"], capture_output=True)
        subprocess.run(["claude", "mcp", "add", "-s", "user", "luyinka", "--", *launcher(), "mcp"])
    CF.save(cfg)

    print("\n6/7 找卡：卡开机，放在电脑旁边，别让手机 App 连着它")
    from .ble import scan

    found_cards = asyncio.run(scan(10))
    if found_cards:
        from . import pipeline

        st = pipeline.load_state()
        st["device"] = found_cards[0].address
        pipeline.save_state(st)
        print(f"  找到了：{found_cards[0].name}（信号 {found_cards[0].rssi}）")
    else:
        print("  没扫到。没关系，卡开机后 `luyinka scan` 再试；第一次会弹「允许使用蓝牙」，点允许。")

    print("\n7/7 卡放回电脑旁边就自动拉（每 30 分钟看一眼，拉完自动转写、整理、交给你的 agent）")
    if yes("  开自动"):
        auto("on")
    print(f"\n✅ 好了。配置在 {CF.CONFIG}，随时 `luyinka setup` 重来。\n   现在可以：luyinka pull（马上拉）· luyinka days（看整理好的）\n")


def launcher() -> list[str]:
    exe = shutil.which("luyinka")
    return [exe] if exe else [sys.executable, "-m", "luyinka.cli"]


def auto(state: str) -> None:
    uid = os.getuid()
    if state == "status":
        r = subprocess.run(["launchctl", "print", f"gui/{uid}/{LABEL}"], capture_output=True, text=True)
        print("自动拉：开着（每 30 分钟）" if r.returncode == 0 else "自动拉：关着")
        print(f"日志：{CF.APP_DIR / 'logs' / 'pull.log'}")
        return
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"], capture_output=True)
    if state == "off":
        PLIST.unlink(missing_ok=True)
        print("自动拉：关了")
        return
    logs = CF.APP_DIR / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    plist = {"Label": LABEL, "ProgramArguments": [*launcher(), "pull", "--auto"],
             "StartInterval": 1800, "RunAtLoad": True,
             "EnvironmentVariables": {"PYTHONPATH": str(PKG_ROOT),
                                      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + str(Path.home() / ".local/bin")},
             "StandardOutPath": str(logs / "pull.log"), "StandardErrorPath": str(logs / "pull.log")}
    PLIST.write_bytes(plistlib.dumps(plist))
    subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", str(PLIST)], check=False)
    print(f"自动拉：开了（每 30 分钟；日志 {logs / 'pull.log'}）")
