from luyinka.transcribe import Segment, to_markdown


def test_long_continuous_speech_is_split():
    segs = [Segment(i * 5.0, i * 5.0 + 4.5, "这是一句连续说的话大概二十个字左右吧") for i in range(40)]  # 句间只停 0.5 秒
    old = [l for l in to_markdown("t", segs).splitlines() if l.startswith("**[")]
    new = [l for l in to_markdown("t", segs, max_sec=30, max_chars=120).splitlines() if l.startswith("**[")]
    assert len(old) == 1
    assert len(new) >= 7
    assert all(len(l.split("** ", 1)[1]) <= 120 for l in new)
    assert new[1].startswith("**[00:00:")
