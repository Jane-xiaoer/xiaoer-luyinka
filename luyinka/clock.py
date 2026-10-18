"""用户过的是哪个时区的日子。

卡上的钟、录音文件名、场景时间都按这个时区，不按系统时区
（Jane 的 Mac 系统时区是洛杉矶，但她按北京时间过日子）。
顺序：LUYINKA_TZ → 配置的 timezone → 系统时区。
"""

from __future__ import annotations

import datetime as _dt
import os
from zoneinfo import ZoneInfo

from .config import C


def _tz():
    name = os.environ.get("LUYINKA_TZ") or C.get("timezone")
    return ZoneInfo(name) if name else _dt.datetime.now().astimezone().tzinfo


TZ = _tz()


def now() -> _dt.datetime:
    return _dt.datetime.now(TZ)
