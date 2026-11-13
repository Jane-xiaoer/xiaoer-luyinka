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


def test_page_shows_version_and_notes(tmp_path, monkeypatch):
    """下载页写版本号、哪天更新的、这次更新了什么（点开看全文）；说明里的尖括号不当网页标签。"""
    monkeypatch.setattr(app, "DATA", tmp_path)
    d = tmp_path / "download"
    d.mkdir()
    (d / "小耳录音卡-1.3.1.dmg").write_bytes(b"mac")
    (d / "更新说明.txt").write_text("能暂停了\n· 拉了一半的留着 <b>\n· 卡上的不删\n", encoding="utf-8")
    page = app.download_page()
    assert "最新版 1.3.1" in page and "日更新" in page
    assert "这次更新了什么：能暂停了" in page and "· 卡上的不删" in page
    assert "&lt;b&gt;" in page


def test_page_without_packages_has_no_version(tmp_path, monkeypatch):
    monkeypatch.setattr(app, "DATA", tmp_path)
    (tmp_path / "download").mkdir()
    assert "最新版" not in app.download_page()


def test_standard_names_and_checksums(tmp_path, monkeypatch):
    """按版本号的英文名：XiaoerLuyinka-<版本>-macos-universal.dmg / -android-arm64.apk / -android-armv7.apk；
    页上有安全校验（签名、证书指纹、每个包的 SHA-256、SHA256SUMS.txt）。"""
    import hashlib
    monkeypatch.setattr(app, "DATA", tmp_path)
    d = tmp_path / "download"
    d.mkdir()
    (d / "XiaoerLuyinka-1.3.2-macos-universal.dmg").write_bytes(b"mac")
    (d / "XiaoerLuyinka-1.3.2-android-arm64.apk").write_bytes(b"a64")
    (d / "XiaoerLuyinka-1.3.2-android-armv7.apk").write_bytes(b"v7")
    (d / "SHA256SUMS.txt").write_text("x", encoding="utf-8")
    j = app.latest()
    assert j["version"] == "1.3.2"
    assert j["android"]["url"].endswith("android-arm64.apk") and j["android_old"]["url"].endswith("android-armv7.apk")
    page = app.download_page()
    assert "下载老手机版" in page and "android-armv7.apk" in page
    assert "安全校验" in page and app.ANDROID_CERT_SHA256 in page and app.MAC_TEAM in page
    assert hashlib.sha256(b"a64").hexdigest() in page and "SHA256SUMS.txt" in page
