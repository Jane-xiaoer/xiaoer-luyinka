"""下载页：Mac 一个包；安卓主流手机一个大按钮，老手机（文件名带「老手机」）一行小字链接。"""
from server import app


def test_two_android_packages(tmp_path, monkeypatch):
    monkeypatch.setattr(app, "DATA", tmp_path)
    d = tmp_path / "download"
    d.mkdir()
    (d / "小耳录音卡-1.2.3.dmg").write_bytes(b"x" * 1000)
    (d / "小耳录音卡-1.2.3-安卓老手机.apk").write_bytes(b"x" * 2_000_000)
    (d / "小耳录音卡-1.2.3-安卓.apk").write_bytes(b"x" * 3_000_000)
    html = app.download_page()
    assert "下载安卓版" in html and "3MB" in html
    assert "%E8%80%81%E6%89%8B%E6%9C%BA" in html and "下载老手机版（2MB）" in html  # 老手机版的链接
    assert html.index("下载安卓版") < html.index("下载老手机版")


def test_no_old_phone_package(tmp_path, monkeypatch):
    monkeypatch.setattr(app, "DATA", tmp_path)
    (tmp_path / "download").mkdir()
    (tmp_path / "download" / "小耳录音卡-1.2.3-安卓.apk").write_bytes(b"x")
    assert "老手机版" not in app.download_page()
