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


def test_latest_for_app_update(tmp_path, monkeypatch):
    """App 的「有新版」提醒：版本号从文件名读；每个包带大小和 sha256（App 下载完核对了才装）；old/ 里的旧版不算。"""
    import hashlib
    monkeypatch.setattr(app, "DATA", tmp_path)
    d = tmp_path / "download"
    (d / "old").mkdir(parents=True)
    (d / "old" / "小耳录音卡-1.2.4.dmg").write_bytes(b"old")
    (d / "小耳录音卡-1.2.6.dmg").write_bytes(b"mac")
    (d / "小耳录音卡-1.2.6-安卓.apk").write_bytes(b"apk")
    (d / "小耳录音卡-1.2.6-安卓老手机.apk").write_bytes(b"v7")
    (d / "更新说明.txt").write_text("长会不卡了\n", encoding="utf-8")
    j = app.latest()
    assert j["version"] == "1.2.6" and j["notes"] == "长会不卡了"
    assert j["mac"]["sha256"] == hashlib.sha256(b"mac").hexdigest() and j["mac"]["size"] == 3
    assert j["android"]["url"].endswith(".apk") and "%E8%80%81" not in j["android"]["url"]
    assert "%E8%80%81" in j["android_old"]["url"]


def test_latest_empty(tmp_path, monkeypatch):
    monkeypatch.setattr(app, "DATA", tmp_path)
    assert app.latest() == {"version": "", "notes": ""}
