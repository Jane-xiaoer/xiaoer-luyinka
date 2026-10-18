"""用户配置：~/.luyinka/config.json（LUYINKA_CONFIG 可改）。`luyinka setup` 生成，手改也行。

别人装好开箱即用靠它：所有路径、模型、整理用的大模型、整理完叫谁的 agent，都在这一份里。
没写的项用 DEFAULTS。
"""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path

APP_DIR = Path(os.environ.get("LUYINKA_APP_DIR", Path.home() / ".luyinka"))
CONFIG = Path(os.environ.get("LUYINKA_CONFIG", APP_DIR / "config.json"))

DEFAULTS: dict = {
    # 产出目录：原始/ 音频/ 文字/ 场景/ 简报/
    "home": "~/Documents/录音卡",
    # 时区：卡上的钟、文件名、场景时间都按它；空 = 系统时区
    "timezone": "",
    # 转写：local = 本机 SenseVoice（免费、离线）；cloud = OpenAI 兼容的语音接口（/audio/transcriptions）
    "asr": {
        "engine": "local",
        "model_dir": "~/.luyinka/models/sensevoice",
        "vad_model": "~/.luyinka/models/silero_vad.onnx",
        "language": "zh",
        "cloud": {"base_url": "https://api.siliconflow.cn/v1", "api_key": "", "model": "FunAudioLLM/SenseVoiceSmall"},
    },
    # 切场景用的大模型：任何 OpenAI 兼容接口（DeepSeek / 通义 / Kimi / 本地 ollama 都行）
    "llm": {"base_url": "https://api.deepseek.com/v1", "api_key": "", "model": "deepseek-chat"},
    # 同音纠错：内联的「错写: 正确」+ 额外的纠错表文件（每行「错写 → 正确」）
    "fixes": {},
    "corrections_files": [],
    # 场景分类（固定词表，模型只能从这里选）
    "categories": ["嘉宾分享", "商业洽谈", "与人对话", "开会", "学习听课", "打电话", "自言自语", "生活日常", "杂音"],
    # 整理完一天后跑的命令：交给用户自己的 agent 按他的规则处理（见 docs/给你的agent.md）
    # 可用变量：{day} {day_dir} {scenes_json} {brief}
    "after_organize": "",
    # 小耳灵感（Jane 自己的系统）：行动/提醒送进它的收件口，场景推飞书。别人不用开
    "linggan": {"enabled": False, "data_dir": "~/Desktop/xiaoer/小耳灵感"},
    # 拉完录音后删卡上的原文件
    "delete_after_pull": False,
}


def _merge(base: dict, over: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in (over or {}).items():
        out[k] = _merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def load() -> dict:
    try:
        user = json.loads(CONFIG.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        user = {}
    return _merge(DEFAULTS, user)


def save(cfg: dict) -> None:
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(CONFIG)


def path(p: str) -> Path:
    return Path(os.path.expanduser(p))


C = load()
