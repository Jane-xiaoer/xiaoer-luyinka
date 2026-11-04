// iPhone「语音备忘录」：iPhone 打开 iCloud 同步语音备忘录后，Mac 上会有一份（[VoiceMemos.defaultDir]）：
//   <文件夹>/20250122 180256.m4a …      录音
//   <文件夹>/CloudRecordings.db           SQLite，表 ZCLOUDRECORDING：ZPATH 文件名 · ZENCRYPTEDTITLE 标题 · ZDATE 开录（Core Data 秒）· ZDURATION 秒
// 后台每 30 秒看一眼：打开这功能之后新录的，下完了就收进来（转成 Ogg Opus 放进 raw/，转写、按类别整理都走 Syncer）。
// 以前录的（起点之前）不自动收，设置里「挑以前的录音导入」自己勾。
// 那个文件夹只读：只列目录、读文件；db 先复制到临时文件夹再读。绝不往里写、改、删任何东西。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'local_asr.dart' show cafOpus, packetsOgg;
import 'store.dart';

/// Core Data 的时间从 2001-01-01 UTC 算起
const coreDataEpoch = 978307200;

/// 语音备忘录里的一条。
class Memo {
  final String path; // 文件夹里的文件名（db 的 ZPATH），认「收没收过」用它
  final String title;
  final DateTime at; // 开录的那一刻（比起点早晚用）
  final DateTime wall; // 开录时 iPhone 上的墙上时间（文件名里的；没有就按这台电脑的时区算）
  final double seconds; // db 里记的时长（0 = 不知道）
  final bool present; // 文件在这台 Mac 上了（false = 还在 iCloud 上没下来）
  Memo(this.path, this.title, this.at, this.wall, this.seconds, {this.present = true});

  /// 录音名：iphone20250122-175533（时间是 iPhone 上的墙上时间）
  String get stem =>
      'iphone${wall.year}${_p2(wall.month)}${_p2(wall.day)}-${_p2(wall.hour)}${_p2(wall.minute)}${_p2(wall.second)}';
}

/// 文件夹没有 / 读不了。[denied] = 有但不让读（macOS 问「访问其他 App 的数据」时点了不允许）。
class MemoError implements Exception {
  final bool denied;
  final String detail;
  MemoError(this.denied, this.detail);
  @override
  String toString() => detail;
}

/// 文件名开头的「20250122 175533」→ 墙上时间
DateTime? wallOf(String name) {
  final m = RegExp(r'^(\d{4})(\d\d)(\d\d) (\d\d)(\d\d)(\d\d)').firstMatch(name);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}

/// 读语音备忘录文件夹（只读）。
class VoiceMemos {
  final Directory dir;
  final String sqlite;
  VoiceMemos(this.dir, {this.sqlite = '/usr/bin/sqlite3'});

  /// 测试 / 自检可以用 LUYINKA_VOICEMEMOS_DIR 指到别的文件夹
  static Directory defaultDir() => Directory(
        Platform.environment['LUYINKA_VOICEMEMOS_DIR'] ??
            '${Platform.environment['HOME']}/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings',
      );

  /// 所有录音（db 里有的 + 文件夹里有的），新的在前。文件夹没有 / 读不了抛 [MemoError]。
  Future<List<Memo>> list() async {
    final List<FileSystemEntity> items;
    try {
      items = await dir.list().toList();
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      if (code == 2) throw MemoError(false, '这台 Mac 上没有语音备忘录文件夹');
      throw MemoError(true, '没有权限读语音备忘录文件夹（${e.osError?.message ?? e.message}）');
    }
    final files = <String, File>{
      for (final f in items.whereType<File>())
        if (f.path.endsWith('.m4a') && !f.uri.pathSegments.last.startsWith('.')) f.uri.pathSegments.last: f,
    };
    final meta = await readDb();
    final out = <Memo>[];
    for (final MapEntry(key: name, value: m) in meta.entries) {
      final at = m.$2;
      out.add(Memo(name, m.$1.isEmpty ? _plainTitle(name) : m.$1, at, wallOf(name) ?? at, m.$3,
          present: files.containsKey(name)));
    }
    for (final MapEntry(key: name, value: f) in files.entries) {
      if (meta.containsKey(name)) continue;
      // db 读不了 / 还没记上这条：时间看文件名，认不出就看文件时间
      final wall = wallOf(name);
      final at = wall ?? (await f.stat()).modified;
      out.add(Memo(name, _plainTitle(name), at, wall ?? at, 0));
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  /// 在这台 Mac 上的这条录音（只拿来读）
  File file(Memo m) => File('${dir.path}/${m.path}');

  /// db 里的：文件名 → (标题, 开录时刻, 时长秒)。没有 db / 读不了就是空的（退回看文件名）。
  /// 先把 db 连同 -wal / -shm 复制到临时文件夹再读：直接打开原文件，sqlite 也可能往旁边写东西。
  Future<Map<String, (String, DateTime, double)>> readDb() async {
    final db = File('${dir.path}/CloudRecordings.db');
    final out = <String, (String, DateTime, double)>{};
    Directory? tmp;
    try {
      if (!await db.exists()) return out;
      tmp = await Directory.systemTemp.createTemp('luyinka-memos');
      for (final s in ['', '-wal', '-shm']) {
        final f = File('${db.path}$s');
        if (await f.exists()) await f.copy('${tmp.path}/v.db$s');
      }
      final r = await Process.run(sqlite, [
        '-json',
        '${tmp.path}/v.db',
        'select ZPATH p, coalesce(nullif(ZENCRYPTEDTITLE, \'\'), ZCUSTOMLABEL, \'\') t, ZDATE d, ZDURATION s '
            'from ZCLOUDRECORDING where ZPATH is not null and ZPATH != \'\' and ZEVICTIONDATE is null',
      ]);
      if (r.exitCode != 0) return out;
      final text = (r.stdout as String).trim();
      if (text.isEmpty) return out;
      for (final x in (jsonDecode(text) as List).whereType<Map>()) {
        final d = (x['d'] as num?)?.toDouble();
        if (d == null) continue;
        final at = DateTime.fromMillisecondsSinceEpoch(((d + coreDataEpoch) * 1000).round());
        out['${x['p']}'] = ('${x['t'] ?? ''}'.trim(), at, (x['s'] as num?)?.toDouble() ?? 0);
      }
    } catch (_) {
      // db 坏了 / 被锁 / 没有 sqlite3：退回看文件名
    } finally {
      await tmp?.delete(recursive: true).catchError((_) => tmp!);
    }
    return out;
  }

  static String _plainTitle(String name) {
    final w = wallOf(name);
    return w == null
        ? name.replaceAll(RegExp(r'\.m4a$'), '')
        : '录音 ${w.year}-${_p2(w.month)}-${_p2(w.day)} ${_p2(w.hour)}:${_p2(w.minute)}';
  }
}

/// 文件里实际有多少秒（系统自带的 afinfo）。读不出（多半是还没下完、文件尾巴没到）= null。
Future<double?> afinfoSeconds(File f) async {
  try {
    final r = await Process.run('/usr/bin/afinfo', [f.path]);
    if (r.exitCode != 0) return null;
    final m = RegExp(r'estimated duration: ([\d.]+) sec').firstMatch('${r.stdout}');
    return m == null ? null : double.tryParse(m[1]!);
  } catch (_) {
    return null;
  }
}

/// m4a → Ogg Opus（16k 单声道）：afconvert 先解成 16k 单声道 wav，再编成 CAF 里的 Opus，最后把包装进 Ogg
/// （afconvert 写不了 Ogg Opus；老的立体声录音直接转单声道 Opus 会报 'cclo'，所以先过一道 wav）。
/// 这样跟录音卡 / 录音豆一样，本机转写、云端转写都认。
Future<void> m4aToOgg(File src, File dst) async {
  final tmp = await Directory.systemTemp.createTemp('luyinka-m4a');
  try {
    final wav = File('${tmp.path}/a.wav'), caf = File('${tmp.path}/a.caf');
    for (final args in [
      ['-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', src.path, wav.path],
      ['-f', 'caff', '-d', 'opus@16000', '-b', '32000', wav.path, caf.path],
    ]) {
      final r = await Process.run('/usr/bin/afconvert', args);
      if (r.exitCode != 0) throw Exception('音频转换没成功：${r.stderr}');
    }
    final c = cafOpus(await caf.readAsBytes());
    if (c.packets.isEmpty) throw Exception('这条录音里没有声音数据');
    final part = File('${dst.path}.tmp');
    await part.parent.create(recursive: true);
    await part.writeAsBytes(packetsOgg(c.packets, preSkip: c.preSkip), flush: true);
    await part.rename(dst.path);
  } finally {
    await tmp.delete(recursive: true);
  }
}

typedef MemoConvert = Future<void> Function(File src, File dst);
typedef MemoProbe = Future<double?> Function(File f);

/// 把语音备忘录收进录音卡。存在 settings 里的：
///   iphoneOff 关了 · iphoneSince 起点（第一次打开时记，之前录的不自动收）· iphoneTaken 收过的文件名
///   iphoneQueue 用户勾了、还没收的旧录音 · iphoneTitles 录音名 → iPhone 上的标题 · iphoneLast 最近收的那条
class VoiceMemoSyncer extends ChangeNotifier {
  static VoiceMemoSyncer? instance; // 设置页用（只有 Mac 有）

  final Store store;
  final VoiceMemos memos;
  final Future<void> Function() afterImport; // 收进来一条：让 Syncer 跑一轮（转写、整理）
  final MemoConvert convert;
  final MemoProbe probe;
  final DateTime Function() now;
  VoiceMemoSyncer(this.store, this.memos, this.afterImport,
      {MemoConvert? convert, MemoProbe? probe, DateTime Function()? now})
      : convert = convert ?? m4aToOgg,
        probe = probe ?? afinfoSeconds,
        now = now ?? DateTime.now;

  static const every = Duration(seconds: 30);

  /// 刚下来的文件：两次看到大小、修改时间都一样，而且这么久没动过，才算下完
  static const settle = Duration(seconds: 10);

  /// 这么久没动过的文件：不用等第二次看（挑旧录音导入时不用干等一轮）
  static const old = Duration(minutes: 2);

  bool busy = false;
  MemoError? problem; // 上次看文件夹时的问题（没有 / 不让读）
  int waiting = 0; // 上次看到的：该收、但还没下完的条数
  DateTime? checkedAt;
  final _sizes = <String, String>{}; // 文件名 → 上次看到的「大小:修改时间」
  Timer? _timer;

  bool get off => store.settings['iphoneOff'] == true;
  DateTime? get since => DateTime.tryParse(store.settings['iphoneSince'] as String? ?? '');
  Set<String> get taken => {for (final x in (store.settings['iphoneTaken'] as List? ?? const [])) '$x'};
  Set<String> get queue => {for (final x in (store.settings['iphoneQueue'] as List? ?? const [])) '$x'};
  Map<String, dynamic> get last => Map<String, dynamic>.from(store.settings['iphoneLast'] as Map? ?? const {});

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => run());
    run();
  }

  void stop() => _timer?.cancel();

  void setOff(bool v) {
    store.settings['iphoneOff'] = v;
    store.save();
    notifyListeners();
    if (!v) run();
  }

  /// 起点之前的（「挑以前的录音导入」列这些），新的在前
  Future<List<Memo>> before() async {
    final s = since ?? now();
    return [for (final m in await memos.list()) if (m.at.isBefore(s)) m];
  }

  /// 用户勾了的旧录音：排上，下完了就收
  Future<void> pick(Iterable<Memo> which) async {
    store.settings['iphoneQueue'] = {...queue, for (final m in which) if (!taken.contains(m.path)) m.path}.toList()..sort();
    await store.save();
    notifyListeners();
    await run();
  }

  /// 一轮：看文件夹，起点之后新录的 + 用户勾了的，下完了就收进来。重复调用安全（正在跑就跳过）。
  Future<void> run() async {
    if (busy || off) return;
    busy = true;
    try {
      if (since == null) {
        // 第一次打开：从现在算起，以前录的不自动收（几百条要转好几天、会刷满时间线）
        store.settings['iphoneSince'] = now().toIso8601String();
        await store.save();
      }
      final List<Memo> all;
      try {
        all = await memos.list();
        problem = null;
      } on MemoError catch (e) {
        problem = e;
        return;
      } finally {
        checkedAt = now();
      }
      final got = taken, q = queue;
      final todo = [
        for (final m in all.reversed) // 旧的先收
          if (!got.contains(m.path) && (!m.at.isBefore(since!) || q.contains(m.path))) m,
      ];
      var wait = 0;
      for (final m in todo) {
        if (!await ready(m)) {
          wait++;
          continue;
        }
        try {
          await _take(m);
        } catch (_) {
          wait++; // 这一轮没收成（转换失败 / 读到一半被 iCloud 挪走）：下轮再试
        }
      }
      waiting = wait;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 下完了没有：文件在、不是空的、大小不再变、实际时长跟 db 里记的对得上。没下完的下轮再看，别收半截。
  Future<bool> ready(Memo m) async {
    final f = memos.file(m);
    final FileStat st;
    try {
      st = await f.stat();
    } catch (_) {
      return false;
    }
    if (st.type != FileSystemEntityType.file || st.size == 0) return false;
    final key = '${st.size}:${st.modified.millisecondsSinceEpoch}';
    final age = now().difference(st.modified);
    final same = _sizes[m.path] == key;
    _sizes[m.path] = key;
    if (age < old && (!same || age < settle)) return false;
    final secs = await probe(f);
    if (secs == null || secs <= 0) return false;
    if (m.seconds > 0 && secs < m.seconds - (m.seconds * 0.03 > 2 ? m.seconds * 0.03 : 2)) return false;
    return true;
  }

  Future<void> _take(Memo m) async {
    var stem = m.stem;
    for (var k = 2; store.recs.containsKey(stem) || (store.hasLib && store.result(stem).existsSync()); k++) {
      stem = '${m.stem}-$k'; // 同一秒开录的两条（几乎不会有）
    }
    final src = memos.file(m);
    await convert(src, store.raw(stem));
    store.recs[stem] = Rec(stem, await src.length(), 'pulled')
      ..noStream = true // 一整条，不用边拉边传
      ..deletedOnCard = true; // 不是卡上的，卡那边的「拉完删卡」别碰它
    store.settings['iphoneTaken'] = [...taken, m.path];
    store.settings['iphoneQueue'] = [...queue.where((p) => p != m.path)];
    store.settings['iphoneTitles'] = {...Map<String, dynamic>.from(store.settings['iphoneTitles'] as Map? ?? const {}), stem: m.title};
    store.settings['iphoneLast'] = {'title': m.title, 'stem': stem, 'at': now().toIso8601String()};
    await store.save();
    notifyListeners();
    unawaited(afterImport());
  }
}

/// 这条在 iPhone 上起的标题（整理时当线索）。「新录音 12」这种系统默认的不算。
String? memoTitle(Store store, String stem) {
  final t = (store.settings['iphoneTitles'] as Map?)?[stem];
  if (t is! String || t.trim().isEmpty || RegExp(r'^(新录音|New Recording)\s*\d*$').hasMatch(t.trim())) return null;
  return t.trim();
}

String _p2(int n) => n.toString().padLeft(2, '0');
