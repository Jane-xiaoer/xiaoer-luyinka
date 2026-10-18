"""命令行。第一次用先 `luyinka setup`。

  setup         一步步配好：找卡、下模型、填整理用的大模型、接你的 agent、开自动拉
  auto on|off   卡放电脑旁就自动拉（每 30 分钟看一眼）

  scan          找附近的录音卡
  info          电量 / 容量 / 固件版本
  list          卡上的录音列表
  pull          下载新录音 → 封装 ogg → 转写 md（加 --delete 转完删卡上文件）
  transcribe F  转写任意本地音频文件（也能吃卡上导出的裸 .opus）
  organize [日期] 切场景 + 简报 + 行动/提醒送进小耳灵感 + 推飞书「录音」表（不给日期 = 所有还没整理的）
  decode F      卡上裸 .opus → 可播放的 .ogg

给 agent 用（加 --json 出机器可读的）：
  days            哪几天有整理好的录音
  day 日期        那天的场景（--full 带全文）
  scene ID        一个场景的全部内容
  search 词…      搜所有场景
  mcp             MCP 服务（claude mcp add luyinka -- luyinka mcp）
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import subprocess
import sys
from pathlib import Path

from . import opus_ogg, pipeline

log = logging.getLogger("luyinka")


async def _connect(args):
    from .ble import BleTransport, scan
    from .device import Client

    st = pipeline.load_state()
    address = args.address or st.get("device")
    if not address:
        found = await scan()
        if not found:
            sys.exit("没扫到录音卡：确认它开着机、离 Mac 不远、没被手机 App 连着。")
        address = found[0].address
        log.info("用 %s（%s，信号 %d）", found[0].name, address, found[0].rssi)
    t = BleTransport(address)
    try:
        await t.open()
    except Exception as e:
        sys.exit(f"连不上 {address}：{e}\n可以先跑 `luyinka scan`，或者把卡关机再开机。")
    if st.get("device") != address:
        st["device"] = address
        pipeline.save_state(st)
    c = Client(t, ack=args.ack)
    await c.sync_time()
    return t, c


async def cmd_scan(args):
    from .ble import scan

    found = await scan(args.timeout)
    if not found:
        print("没扫到。")
    for f in found:
        kind = {3: "Wi-Fi 卡片机"}.get(f.kind, f"类别 {f.kind}") if f.kind is not None else ""
        print(f"{f.name:20} {f.address}  信号 {f.rssi}  {kind}")


async def cmd_info(args):
    t, c = await _connect(args)
    try:
        info = await c.info()
        b = info["battery"]
        print("电量：", "充电中" if b == 110 else (f"{b}%" if b is not None else "没回"))
        if info["capacity"]:
            free, total = info["capacity"]
            print(f"容量：剩 {free / 1024 / 1024:.1f} GB / 共 {total / 1024 / 1024:.1f} GB")
        print("固件：", info["version"] or "没回")
    finally:
        await t.close()


async def cmd_list(args):
    t, c = await _connect(args)
    try:
        files = await c.list_files()
        st = pipeline.load_state()["files"]
        for f in files:
            done = "✅" if st.get(f.name, {}).get("transcribed") else "  "
            print(f"{done} {pipeline.nice_name(f.stem):28} {f.size / 1024:9.0f} KB  {f.name}")
        print(f"共 {len(files)} 个")
    finally:
        await t.close()


async def cmd_pull(args):
    if args.auto:  # 定时任务：卡不在旁边就安静退出，别报错
        from .ble import scan

        if not await scan(6):
            log.info("卡不在旁边，下次再看")
            return
    t, c = await _connect(args)
    holder = {"t": t}

    async def reconnect():
        await holder["t"].close()
        await asyncio.sleep(2)
        nt, nc = await _connect(args)
        holder["t"] = nt
        return nc

    try:
        from .config import C

        report = await pipeline.sync(c, delete_after=args.delete or C["delete_after_pull"], reconnect=reconnect)
    finally:
        await holder["t"].close()
    ok = [r for r in report if "md" in r]
    bad = [r for r in report if "error" in r]
    print(f"新转写 {len(ok)} 个，失败 {len(bad)} 个。文字在：{pipeline.TEXT_DIR}")
    for r in bad:
        print("  ❌", r["file"], r["error"])
    if ok and not args.no_organize:
        cmd_organize(argparse.Namespace(day=None, no_push=False))


def cmd_organize(args):
    from . import scenes

    for day in [args.day] if args.day else scenes.days_with_recordings():
        r = scenes.organize(day, push=not args.no_push)
        if r["new"] or args.day:
            print(f"{day}：新切 {r['new']} 个场景，共 {r['scenes']} 个，{r['todo']} 件行动/提醒。简报 {r['brief']}")


def cmd_transcribe(args):
    src = Path(args.file).expanduser()
    stem = src.stem
    if src.suffix == ".opus" and not opus_ogg.looks_like_ogg(src.read_bytes()[:4]):
        ogg, md = pipeline.process_raw(stem, src)
    else:
        title = pipeline.nice_name(stem)
        md = pipeline.transcribe_file(src, pipeline.TEXT_DIR / f"{title}.md", title,
                                      {"原文件": src.name})
    print(md)


def cmd_decode(args):
    src = Path(args.file).expanduser()
    out = Path(args.out).expanduser() if args.out else src.with_suffix(".ogg")
    n = opus_ogg.raw_to_ogg(src.read_bytes(), out)
    print(f"{out}（{n} 帧，约 {n * 0.02:.0f} 秒）")


def _out(args, data, human):
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=1))
    else:
        human(data)


def cmd_days(args):
    from . import api

    _out(args, api.days(), lambda ds: [print(f"{d['day']}  {d['scenes']:3d} 个场景  {d['todo']:3d} 件要办  {d['brief']}")
                                       for d in ds] or print("还没有整理好的录音。"))


def cmd_day(args):
    from . import api

    def human(d):
        for s in d["scenes"]:
            print(f"{s['start'][11:16]}–{s['end'][11:16]}  [{s['category']}] {s['title']}  ({s['id']})\n    {s['event']}")
            for x in s["actions"] + s["reminders"]:
                print(f"    → {x['text']}")
    _out(args, api.day(args.day, full=args.full), human)


def cmd_scene(args):
    from . import api

    _out(args, api.scene(args.id), lambda s: print(open(s["card"], encoding="utf-8").read()))


def cmd_search(args):
    from . import api

    def human(rs):
        for s in rs:
            print(f"{s['day']} {s['start'][11:16]} [{s['category']}] {s['title']}  ({s['id']})")
            for h in s["hits"]:
                print("    " + h)
        if not rs:
            print("没搜到。")
    _out(args, api.search(" ".join(args.words), args.limit), human)


def cmd_mcp(args):
    from .mcp_server import main as run

    run()


def cmd_setup(args):
    from . import setup

    setup.run()


def cmd_auto(args):
    from . import setup

    setup.auto(args.state)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="luyinka", description="小耳录音卡：蓝牙拉录音 + 本地转写")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--address", help="设备地址（默认用上次连过的，或扫到的第一个）")
    ap.add_argument("--ack", action="store_true", help="收包回 ACK（厂商 SDK 不回；实测不通再开）")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("--timeout", type=float, default=8)
    sub.add_parser("info")
    sub.add_parser("list")
    p = sub.add_parser("pull")
    p.add_argument("--delete", action="store_true", help="转写完成后删除卡上的原文件")
    p.add_argument("--no-organize", action="store_true", help="只拉和转写，不切场景")
    p.add_argument("--auto", action="store_true", help=argparse.SUPPRESS)
    o = sub.add_parser("organize")
    o.add_argument("day", nargs="?", help="YYYY-MM-DD")
    o.add_argument("--no-push", action="store_true", help="只在本机出场景卡和简报，不送小耳灵感、不推飞书")
    sub.add_parser("setup")
    au = sub.add_parser("auto")
    au.add_argument("state", choices=["on", "off", "status"])
    for name in ("days", "day", "scene", "search"):
        q = sub.add_parser(name)
        q.add_argument("--json", action="store_true")
        if name == "day":
            q.add_argument("day")
            q.add_argument("--full", action="store_true", help="带全文")
        if name == "scene":
            q.add_argument("id")
        if name == "search":
            q.add_argument("words", nargs="+")
            q.add_argument("--limit", type=int, default=20)
    sub.add_parser("mcp")
    tr = sub.add_parser("transcribe")
    tr.add_argument("file")
    d = sub.add_parser("decode")
    d.add_argument("file")
    d.add_argument("-o", "--out")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else (logging.WARNING if args.cmd == "mcp" else logging.INFO),
                        stream=sys.stderr,
                        format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    fn = globals()[f"cmd_{args.cmd}"]
    if asyncio.iscoroutinefunction(fn):
        asyncio.run(fn(args))
    else:
        fn(args)


if __name__ == "__main__":
    main()
