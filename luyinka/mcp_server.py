"""MCP 服务：让任何支持 MCP 的 agent（Claude Code / Codex / Cursor / 其他）直接查录音卡的内容。

接法：claude mcp add luyinka -- luyinka mcp
（Codex：~/.codex/config.toml 里加 [mcp_servers.luyinka] command = "luyinka" args = ["mcp"]）
"""

from __future__ import annotations

import subprocess
import sys

from mcp.server.mcpserver import MCPServer

from . import api

INSTRUCTIONS = """录音卡：用户身上别着一张录音卡，一天的聊天、开会、电话都录下来了，
已经在用户电脑上转写好、按话题切成了「场景」（时间、地点、人物、标题、事件、分类、核心观点、有价值的内容、
值得记住的原话、下一步行动、提醒事项、带时间戳的全文）。
先 list_days 看哪几天有，再 get_day 拿某天的场景（不带全文），要原文再 get_scene。找某件事用 search。
把内容放进用户的工作台 / 飞书 / Notion 时，照用户自己的规则来；没有规则就问用户。"""

mcp = MCPServer("luyinka", instructions=INSTRUCTIONS)


@mcp.tool()
def list_days() -> list[dict]:
    """有整理好录音的日子（新的在前）：每天几个场景、几段录音、几件行动/提醒、简报文件路径。"""
    return api.days()


@mcp.tool()
def get_day(day: str) -> dict:
    """某一天（YYYY-MM-DD）的全部场景，不带全文。每个场景有 id，要全文用 get_scene(id)。"""
    return api.day(day)


@mcp.tool()
def get_scene(scene_id: str) -> dict:
    """一个场景的全部内容，含 text：[[钟点, 那一段原文], ...]。"""
    return api.scene(scene_id)


@mcp.tool()
def search(query: str, limit: int = 20) -> list[dict]:
    """按关键词（空格分开都要命中）搜所有场景：标题、事件、人物、观点、原文都搜。返回场景摘要 + 命中的原文句子。"""
    return api.search(query, limit)


@mcp.tool()
def pull() -> str:
    """现在就从录音卡拉新录音 → 转写 → 切场景（卡要开机、在电脑旁边）。要几分钟。"""
    r = subprocess.run([sys.executable, "-m", "luyinka.cli", "pull"], capture_output=True, text=True, timeout=7200)
    return (r.stdout + r.stderr)[-3000:]


def main() -> None:
    mcp.run("stdio")


if __name__ == "__main__":
    main()
