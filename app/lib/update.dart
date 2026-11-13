// 自动更新：打开时问一次云端 /v1/latest，之后每 6 小时再问；比自己新就挂一条提醒，点「现在更新」：
//   Mac：下载 DMG → 核对 sha256 → 挂上 → 核对签名是小耳的（团队 3DP32PZ62M）、苹果公证过 → 换掉现在这个 App → 重新打开
//        （装在别处没写权限 / 从 DMG 里直接开的：打开 DMG，让用户自己拖进「应用程序」）
//   安卓：下载 APK → 核对 sha256 → 叫出系统的安装界面（安卓规定这一下得用户自己点「安装」）
// 正在开现场会议的时候不换（换了会断录音），开完再更新。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'cloud.dart';

/// 每一版更新了什么（App 里带着）：更新完第一次打开，挂一条「已经更新到 x 了」，点开看这里。
/// 第一行是一句话总结。服务器上的 更新说明.txt 用同一段（还没更新的人在「有新版」那条里看到）。
const whatsNew = {
  '1.3.1': '''收录音时能「暂停」和「这条先不收」了，卡上的录音不会删。
· 正在从卡上拉、上传、转写时，处理条下面有「暂停」：停下所有收录，拉了一半的留着，点「接着收」从断的地方继续
· 「这条先不收」：这条不收了，电脑上拉下来的清掉，卡上的录音原样留着；以后在「录音卡」页点「重新收」就能再收''',
  '1.3.0': '''开会记笔记像备忘录一样好用了，笔记里的待办开完会自动进「待办」。
· 现场会议右边直接打字记：待办（点圆圈打勾）、要点、编号、标题、加粗、黄底重点、找字；回车自动接下一条，Tab 缩进，打 @ 从人员名单挑人
· 开会时点「带上没做完的事」，把以前没做完的插进来；会上打勾，原来那条也跟着勾
· 开完会：你打的待办直接进「待办」；小耳整理会议时以你的笔记为主线；点开这场会，最上面就是你的笔记，能接着改，还能「对着录音听」
· 新增「随手记」（左栏搜索框旁的小图标）：不录音，直接打字记，待办一样进待办
· 人员管理：按人里能写资料（公司、项目、介绍）、删人、并人、标「这是我」；顶上新增「按项目」，一个项目一组
· 开会时「这是谁？」可以直接从人员名单里选
· 从卡上拉录音时界面不再卡；另外修了一些问题''',
};

const teamId = '3DP32PZ62M'; // Developer ID Application: Juan Li —— 不是这个签名的包一律不装

/// [a] 比 [b] 新（按点分开的数字比：1.2.10 > 1.2.9）。
bool newer(String a, String b) {
  List<int> p(String v) => [for (final x in v.split(RegExp(r'[.+]'))) int.tryParse(x) ?? 0];
  final x = p(a), y = p(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final m = i < x.length ? x[i] : 0, n = i < y.length ? y[i] : 0;
    if (m != n) return m > n;
  }
  return false;
}

/// 下载地址里的文件名（中文名在地址里是 %E5… 编码的；pathSegments 已经解码过，别再解一次，再解会抛错）。
String fileNameOf(Uri url) => url.pathSegments.last;

/// 这台设备该下哪个包：Mac 的 DMG；安卓 64 位芯片用主流包，老手机用老手机包。
Map<String, dynamic>? packageFor(Map<String, dynamic> latest, {required bool mac, bool arm64 = true}) {
  final k = mac ? 'mac' : (arm64 ? 'android' : 'android_old');
  final p = latest[k] ?? (mac ? null : latest['android']);
  return p == null ? null : Map<String, dynamic>.from(p);
}

class Updater extends ChangeNotifier {
  static final instance = Updater();
  static const _ch = MethodChannel('xiaoer/update');

  String current = '';
  Map<String, dynamic>? latest; // 有比自己新的才有
  bool later = false; // 点了「以后再说」：这次打开不再提醒
  bool busy = false;
  double? progress; // 下载进度 0~1
  String? status; // 正在干嘛 / 出了什么错
  bool failed = false;

  /// 现在能不能换（比如正在开会就不行）：返回不能的原因。
  String? Function()? blocker;
  Timer? _timer;

  /// 刚更新完（这台设备上次用的是旧版）：挂一条「已经更新到 x 了」，点「知道了」收起
  String? justUpdated;

  String get version => latest?['version'] ?? '';
  String get notes => latest?['notes'] ?? '';
  bool get show => latest != null && !later;

  Future<void> start() async {
    if (!(Platform.isMacOS || Platform.isAndroid)) return;
    try {
      current = (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return;
    }
    await _checkJustUpdated();
    await check();
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) => check());
  }

  Future<void> check() async {
    final base = Cloud.instance?.base;
    if (base == null || busy) return;
    try {
      final r = await http.get(Uri.parse('$base/v1/latest')).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return;
      final j = Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes)));
      final v = (j['version'] ?? '').toString();
      if (v.isEmpty || !newer(v, current) || await _pkg(j) == null) return;
      if (latest?['version'] != v) later = false; // 又出了更新的一版：再提醒
      latest = j;
      notifyListeners();
    } catch (_) {
      // 没网 / 云端是旧版没有这个接口：不提醒就是了
    }
  }

  Future<Map<String, dynamic>?> _pkg(Map<String, dynamic> j) async {
    var arm64 = true;
    if (Platform.isAndroid) {
      try {
        arm64 = (await _ch.invokeListMethod<String>('abis') ?? const []).contains('arm64-v8a');
      } catch (_) {}
    }
    return packageFor(j, mac: Platform.isMacOS, arm64: arm64);
  }

  /// 记下这台设备用过的版本：跟上次不一样（或者是老用户第一次有这个记录）就算刚更新完。
  Future<void> _checkJustUpdated() async {
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/luyinka');
      final f = File('${dir.path}/用过的版本.txt');
      final before = f.existsSync() ? f.readAsStringSync().trim() : null;
      final oldUser = File('${dir.path}/state.json').existsSync(); // 1.2.x 的老用户：以前没记，但用过
      if (before != current && (before != null || oldUser) && whatsNew.containsKey(current)) justUpdated = current;
      dir.createSync(recursive: true);
      f.writeAsStringSync(current);
      if (justUpdated != null) notifyListeners();
    } catch (_) {}
  }

  void seen() {
    justUpdated = null;
    notifyListeners();
  }

  void dismiss() {
    later = true;
    notifyListeners();
  }

  void _say(String s, {bool error = false}) {
    status = s;
    failed = error;
    notifyListeners();
  }

  Future<void> install() async {
    if (busy || latest == null) return;
    final no = blocker?.call();
    if (no != null) return _say(no, error: true);
    busy = true;
    progress = 0;
    _say('下载新版…');
    try {
      final p = (await _pkg(latest!))!;
      final url = Uri.parse(Cloud.instance!.base).resolve(p['url']);
      final dir = Directory('${(await getTemporaryDirectory()).path}/luyinka-update')..createSync(recursive: true);
      final f = File('${dir.path}/${fileNameOf(url)}');
      await _download(url, f, (p['size'] as num?)?.toInt() ?? 0, p['sha256']?.toString() ?? '');
      progress = null;
      if (Platform.isMacOS) {
        await _installMac(f);
      } else {
        await _installAndroid(f);
      }
    } catch (e) {
      progress = null;
      busy = false;
      _say('没更新成：$e', error: true);
    }
  }

  /// 边下边算 sha256，对不上就不要。
  Future<void> _download(Uri url, File f, int size, String sha) async {
    final c = http.Client();
    try {
      final r = await c.send(http.Request('GET', url)).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) throw '下载失败（${r.statusCode}）';
      final total = r.contentLength ?? size;
      final d = SHA256Digest();
      final out = f.openWrite();
      var got = 0;
      await for (final b in r.stream) {
        final u = b is Uint8List ? b : Uint8List.fromList(b);
        d.update(u, 0, u.length);
        out.add(u);
        got += u.length;
        if (total > 0) {
          progress = got / total;
          notifyListeners();
        }
      }
      await out.close();
      final h = Uint8List(32);
      d.doFinal(h, 0);
      final hex = [for (final x in h) x.toRadixString(16).padLeft(2, '0')].join();
      if (sha.isNotEmpty && hex != sha) {
        await f.delete();
        throw '下载的文件不完整，再点一次试试';
      }
    } finally {
      c.close();
    }
  }

  Future<ProcessResult> _run(String exe, List<String> args) async {
    final r = await Process.run(exe, args);
    if (r.exitCode != 0) throw '${args.first} 没通过：${(r.stderr as String).trim()}';
    return r;
  }

  /// 现在这个 App 的 .app 文件夹（…/小耳录音卡.app/Contents/MacOS/XiaoerLuyinka 往上三层）。
  static Directory get bundle => File(Platform.resolvedExecutable).parent.parent.parent;

  Future<void> _installMac(File dmg) async {
    _say('核对新版的签名…');
    final work = dmg.parent;
    final mnt = Directory('${work.path}/mnt');
    if (mnt.existsSync()) await Process.run('hdiutil', ['detach', '-force', mnt.path]);
    mnt.createSync(recursive: true);
    await _run('hdiutil', ['attach', '-nobrowse', '-readonly', '-noautoopen', '-mountpoint', mnt.path, dmg.path]);
    final fresh = Directory('${work.path}/新版.app');
    try {
      final app = mnt.listSync().whereType<Directory>().firstWhere((d) => d.path.endsWith('.app'),
          orElse: () => throw '安装包里没找到 App');
      if (fresh.existsSync()) fresh.deleteSync(recursive: true);
      await _run('ditto', [app.path, fresh.path]);
    } finally {
      await Process.run('hdiutil', ['detach', '-force', mnt.path]);
    }
    await _run('codesign', ['--verify', '--deep', '--strict', fresh.path]);
    final who = await Process.run('codesign', ['-dv', '--verbose=2', fresh.path]);
    if (!'${who.stderr}'.contains('TeamIdentifier=$teamId')) throw '签名不是小耳的，不装';
    final gk = await Process.run('spctl', ['-a', '-t', 'exec', '-vv', fresh.path]);
    if (gk.exitCode != 0) throw '没过苹果的公证检查：${'${gk.stderr}'.trim()}';

    final cur = bundle;
    if (!_writable(cur.parent)) {
      // 没权限换（装在别人的「应用程序」里 / 直接从 DMG 开的）：打开安装包，让用户自己拖
      await Process.run('open', [dmg.path]);
      busy = false;
      return _say('新版安装包打开了：把「小耳录音卡」拖进「应用程序」，替换旧的就好');
    }
    _say('装好了，马上重新打开…');
    // App 退出以后再换（开着的时候换会坏）：旧的挪进临时文件夹，新的放进去，再打开；换失败就把旧的放回去
    const script = r'''
while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
OLD="$4/旧版-$(date +%s).app"
if mv "$2" "$OLD"; then
  ditto "$3" "$2" || { rm -rf "$2"; mv "$OLD" "$2"; }
fi
open "$2"
''';
    await Process.start('/bin/bash', ['-c', script, 'update', '$pid', cur.path, fresh.path, work.path],
        mode: ProcessStartMode.detached);
    await Future.delayed(const Duration(milliseconds: 600));
    exit(0);
  }

  bool _writable(Directory d) {
    try {
      final t = File('${d.path}/.luyinka-update-test-$pid')..writeAsStringSync('');
      t.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _installAndroid(File apk) async {
    final ok = await _ch.invokeMethod<bool>('canInstall') ?? true;
    if (!ok) {
      busy = false;
      await _ch.invokeMethod('allowInstall');
      return _say('先在弹出来的设置里打开「允许安装应用」，回来再点一次「现在更新」', error: true);
    }
    await _ch.invokeMethod('install', {'path': apk.path});
    busy = false;
    _say('在系统弹出来的界面里点「安装」就好');
  }
}
