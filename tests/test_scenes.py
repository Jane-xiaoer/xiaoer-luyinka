import json

import pytest

from luyinka import scenes as S

MD = """# 2026-10-18 14.00.00 录音

- 时长：00:30:00

**[00:00:05]** 我们先说报价的事，你那边一个月多少钱。

**[00:10:00]** 好，那就定了，下周三之前我把合同发给你。

**[00:20:00]** 电视的声音。
"""


def fake_llm(user: str) -> str:
    assert "[14:00:05]" in user and "[14:10:00]" in user  # 行首是绝对钟点
    return json.dumps({"scenes": [
        {"start": "14:00:05", "end": "14:10:00", "category": "商业洽谈", "title": "跟老王谈报价",
         "event": "谈月费和合同。", "place": "", "people": ["老王"], "views": [], "valuable": ["月费待定"],
         "memorable": [{"t": "14:00:05", "text": "你那边一个月多少钱"}],
         "actions": [{"t": "14:10:00", "text": "把合同发给你", "who": "我"}],
         "reminders": [{"t": "14:10:00", "text": "下周三之前发合同", "when": "下周三之前"}]},
        {"start": "14:20:00", "end": "14:20:00", "category": "杂音", "title": "电视", "event": "",
         "actions": [{"t": "", "text": "不该被送出去"}]},
    ]}, ensure_ascii=False)


@pytest.fixture
def home(tmp_path, monkeypatch):
    text = tmp_path / "文字"
    text.mkdir()
    (text / "2026-10-18 14.00.00 录音.md").write_text(MD, encoding="utf-8")
    linggan = tmp_path / "灵感"
    (linggan / "直连" / "inbox").mkdir(parents=True)
    (linggan / "动作" / "待办").mkdir(parents=True)
    for k, v in {"TEXT_DIR": text, "AUDIO_DIR": tmp_path / "音频", "SCENE_DIR": tmp_path / "场景",
                 "BRIEF_DIR": tmp_path / "简报", "LINGGAN_DATA": linggan,
                 "LINGGAN": {"enabled": True}}.items():
        monkeypatch.setattr(S, k, v)
    return tmp_path


def test_cut_maps_clock_to_offsets(home):
    sc = S.cut(home / "文字" / "2026-10-18 14.00.00 录音.md", fake_llm)
    assert [s["category"] for s in sc] == ["商业洽谈", "杂音"]
    assert sc[0]["offset"] == 5 and sc[0]["start"].endswith("14:00:05" + sc[0]["start"][19:])
    assert [t for t, _ in sc[0]["text"]] == ["14:00:05", "14:10:00"]   # 场景全文到下一个场景为止
    assert sc[0]["reminders"][0]["when"] == "下周三之前"


def test_organize_pushes_once_and_skips_noise(home):
    r = S.organize("2026-10-18", call=fake_llm)
    assert r["new"] == 2 and r["todo"] == 3
    inbox = list((home / "灵感" / "直连" / "inbox").iterdir())
    assert len(inbox) == 1                                             # 杂音场景不送
    meta = json.loads((inbox[0] / "meta.json").read_text(encoding="utf-8"))
    assert meta["device"] == "录音卡" and meta["local_only"] is True
    assert "下周三之前发合同（下周三之前）" in meta["text"]
    assert meta["recording"]["scenes"].endswith("2026-10-18/scenes.json")
    assert len(list((home / "灵感" / "动作" / "待办").glob("*-录音-2026-10-18.json"))) == 1
    brief = (home / "简报" / "2026-10-18.md").read_text(encoding="utf-8")
    assert "跟老王谈报价" in brief and "电视" not in brief

    # 再跑一遍：录音已切过，不再调模型、不重复送
    r2 = S.organize("2026-10-18", call=lambda u: pytest.fail("不该再调模型"))
    assert r2["new"] == 0
    assert len(list((home / "灵感" / "直连" / "inbox").iterdir())) == 1


def test_hook_runs_with_day_vars(home, monkeypatch):
    monkeypatch.setattr(S, "APP_DIR", home / "app")
    monkeypatch.setitem(S.C, "after_organize", "echo $LUYINKA_DAY {day} > " + str(home / "hook.txt"))
    S.organize("2026-10-18", call=fake_llm)
    assert (home / "hook.txt").read_text().split() == ["2026-10-18", "2026-10-18"]


def test_no_linggan_no_push(home, monkeypatch):
    monkeypatch.setattr(S, "LINGGAN", {"enabled": False})
    S.organize("2026-10-18", call=fake_llm)
    assert not list((home / "灵感" / "直连" / "inbox").iterdir())
    assert not list((home / "灵感" / "动作" / "待办").iterdir())


MINUTES = {"topic": "老王合作报价", "attendees": ["老王"], "summary": "月费待定，下周三前发合同。",
           "agenda": [{"title": "报价", "points": ["询问月费"], "conclusion": "未定"}],
           "decisions": ["下周三前发合同"], "todos": [{"task": "发合同", "owner": "我", "due": "下周三之前"}],
           "open": ["月费多少"], "next": ""}


def test_meeting_scene_gets_minutes(home):
    sc = S.cut(home / "文字" / "2026-10-18 14.00.00 录音.md", fake_llm)
    sc[0]["text"] = sc[0]["text"] * 20                  # 够长才出纪要
    seen = []
    S.add_minutes(sc, lambda u: seen.append(u) or json.dumps(MINUTES, ensure_ascii=False))
    assert len(seen) == 1 and "[14:00:05]" in seen[0]    # 只有洽谈那段过了一遍，杂音没有
    m = sc[0]["minutes"]
    assert m["todos"][0]["owner"] == "我" and m["agenda"][0]["conclusion"] == "未定"
    md = S.minutes_md(sc[0])
    assert md.startswith("# 会议纪要：老王合作报价") and "| 发合同 | 我 | 下周三之前 |" in md
    assert "## 会议纪要：" in S.scene_md(sc[0]) and "### 讨论内容" in S.scene_md(sc[0])


def test_minutes_bad_json_is_skipped(home):
    sc = S.cut(home / "文字" / "2026-10-18 14.00.00 录音.md", fake_llm)
    sc[0]["text"] = sc[0]["text"] * 20
    S.add_minutes(sc, lambda u: "不是 JSON")
    assert "minutes" not in sc[0]
