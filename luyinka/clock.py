"""她过的是哪个时区的日子。

这台 Mac 的系统时区是洛杉矶，但 Jane 按北京时间过日子（小耳灵感的设置里写着）。
卡上的钟、录音文件名、场景时间都按这个时区，不按系统时区。
顺序：LUYINKA_TZ → 小耳灵感设置的 timezone → 系统时区。
"""

from __future__ import annotations

import datetime as _dt
import json
import os
from pathlib import Path
from zoneinfo import ZoneInfo

LINGGAN_SETTINGS = Path.home() / "projects/xiaoer-linggan/profiles/active/settings.json"


def _tz():
    name = os.environ.get("LUYINKA_TZ")
    if not name:
        try:
            name = json.loads(LINGGAN_SETTINGS.read_text(encoding="utf-8")).get("timezone")
        except (OSError, ValueError):
            name = None
    return ZoneInfo(name) if name else _dt.datetime.now().astimezone().tzinfo


TZ = _tz()


def now() -> _dt.datetime:
    return _dt.datetime.now(TZ)
