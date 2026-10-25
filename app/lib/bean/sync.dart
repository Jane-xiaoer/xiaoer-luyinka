// 录音豆：把硬件上的录音管起来。连上读电量 / 存储 / 录音列表；选哪条拉哪条（或者全部同步），
// 拉下来解密包成 Ogg、标成「已拉」，后面上传转写、切场景、出纪要都走录音卡原来的流程（Syncer）；
// 拉下来转写好先停在「待你决定」：录音豆页里看文字，用户点「导入录音卡」才按类别整理，点「不要了」就从豆子上删掉、本机也不留。
// 导入了的：录音卡里原稿音频、转写稿都存好、也整理完了（「已存好」），才允许把豆子上的那条删掉（Jane 2026-10-24 定的）。
//
// 跟录音卡分开跑：蓝牙拉录音豆很慢，长录音要拉很久，不能挡着卡的同步和云端转写。
// 默认不自动拉：连上只读状态和列表，拉哪条用户自己点；设置里可以打开「自动拉新录音」。正在录的（大小 FFFFFFFF）等录完再拉。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../store.dart';
import 'client.dart';
import 'protocol.dart';

typedef BeanFinder = Future<BeanConn?> Function(String mac);
typedef BeanScanner = Future<List<BeanSeen>> Function();

class BeanSyncer extends ChangeNotifier {
  final Store store;
  final Future<void> Function() afterPull; // 拉完一条：让 Syncer 跑一轮（上传转写）
  final BeanFinder find;
  final BeanScanner scan;
  BeanSyncer(this.store, this.afterPull, {BeanFinder? find, BeanScanner? scan})
    : find = find ?? BeanClient.find,
      scan = scan ?? BeanClient.scan {
    // 上次连上时读到的电量 / 存储：没连上也能在页面上看
    final x = store.settings['beanInfo'];
    if (x is List && x.length >= 7) {
      info = BeanInfo(x[0], x[1], x[2], x[3], x[4], x[5], x[6]);
    }
  }

  static const every = Duration(minutes: 5);
  static const minMs = 2000; // 一两秒那种是开了马上关的空录音

  bool busy = false, connected = false;
  BeanInfo? info;
  String? error;
  DateTime? lastSeen;
  bool? here; // 上一回找没找到（null = 这次打开 App 还没找过）。连上读完就断开（省豆子的电），断开不等于不在旁边
  String phase = ''; // 这会儿在干嘛：找录音豆… / 连接中… / 读录音列表… / 拉录音 / 删除中…（页面上显示）
  Timer? _timer;

  // ───────── 存在 settings 里的东西（没连上也能在页面上看）─────────

  /// 豆子里有什么（上次连上时读的）：[[id, 时长毫秒], …]
  List<BeanFile> get files => [
    for (final x in (store.settings['beanFiles'] as List? ?? const []))
      BeanFile((x as List)[0] as int, x[1] as int),
  ];
  set files(List<BeanFile> v) => store.settings['beanFiles'] = [
    for (final f in v) [f.id, f.ms],
  ];

  /// 上次读到列表的时刻
  DateTime? get listedAt =>
      DateTime.tryParse(store.settings['beanListedAt'] as String? ?? '');

  /// 用户点了「拉到录音卡」、还没拉完的（录音 id）
  Set<int> get queue => {
    for (final x in (store.settings['beanQueue'] as List? ?? const []))
      x as int,
  };
  set queue(Set<int> v) => store.settings['beanQueue'] = v.toList()..sort();

  /// 连上就把新录音全拉下来（默认关：拉哪条用户自己点）
  bool get auto => store.settings['beanAuto'] == true;
  String? get mac => store.settings['beanMac'] as String?;
  bool get off => store.settings['beanOff'] == true;

  // ───────── 每条的状态 ─────────

  /// 这条在录音卡里走到哪一步了（null = 还没拉）
  Rec? recOf(BeanFile f) => store.recs[f.stem];
  bool skipped(BeanFile f) => f.ms < minMs;
  bool queued(BeanFile f) => queue.contains(f.id);

  /// 已存好：录音卡里有原稿音频、有转写稿、也整理完了。只有这样才能从豆子上删。
  bool savedSafely(BeanFile f) {
    final r = recOf(f);
    if (r == null || r.stage != 'done') return false;
    return store.audio(f.stem).existsSync() &&
        store.lib.transcript(f.stem).existsSync();
  }

  /// 待你决定：拉下来、转写好了，等用户看过文字决定导入录音卡（按类别整理）还是不要。
  bool reviewing(BeanFile f) => recOf(f)?.stage == 'review';

  /// 本机有这条的转写稿了（拉下来、转写好了）：可以点开看
  bool hasText(BeanFile f) {
    final st = recOf(f)?.stage;
    return (st == 'review' ||
            st == 'transcribed' ||
            st == 'analyzing' ||
            st == 'done') &&
        store.peekResult(f.stem) != null;
  }

  /// 转写出来的文字（点「看看」时显示）：[[钟点, 文字], …]
  List<List<String>> lines(BeanFile f) => [
    for (final x in (store.peekResult(f.stem)?['lines'] as List? ?? const []))
      List<String>.from(x),
  ];

  /// 能拉：录完了、不是空录音、还没拉过（或者拉了一半）
  bool pullable(BeanFile f) =>
      !f.recording &&
      !skipped(f) &&
      (recOf(f) == null || recOf(f)!.stage == 'pulling');

  // ───────── 用户的操作 ─────────

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => run());
    run();
  }

  void stop() => _timer?.cancel();

  void setOff(bool v) {
    store.settings['beanOff'] = v;
    store.save();
    notifyListeners();
    if (!v) run();
  }

  void setAuto(bool v) {
    store.settings['beanAuto'] = v;
    store.save();
    notifyListeners();
    if (v) run();
  }

  /// 「拉到录音卡」：排进待拉，马上去连。
  void pull(BeanFile f) {
    if (!pullable(f)) return;
    queue = {...queue, f.id};
    store.save();
    notifyListeners();
    run();
  }

  /// 「全部同步」：能拉的都排上。
  void pullAll() {
    queue = {
      ...queue,
      for (final f in files)
        if (pullable(f)) f.id,
    };
    store.save();
    notifyListeners();
    run();
  }

  /// 从豆子上删：只删已存好的（删前再核对一遍原稿和转写稿在不在）。返回删掉了几条。
  Future<int> delete(List<BeanFile> which) async {
    final ok = which.where(savedSafely).toList();
    if (ok.isEmpty) return 0;
    var n = 0;
    await _session('删除中…', (c) async {
      final gone = <int>{};
      for (final f in ok) {
        if (!savedSafely(f)) continue; // 连上的这几秒里状态变了：不删
        if (await c.delete(f.id) == true) gone.add(f.id);
      }
      n = gone.length;
      files = [
        for (final f in files)
          if (!gone.contains(f.id)) f,
      ];
      await store.save();
    });
    return n;
  }

  /// 「导入录音卡」：交给录音卡按类别整理（整理完就是「已存好」，之后可以从豆子上删）。
  Future<void> moveIn(BeanFile f) async {
    final r = recOf(f);
    if (r == null || r.stage != 'review') return;
    r
      ..stage = 'transcribed'
      ..tried = 0
      ..error = null;
    await store.save();
    notifyListeners();
    unawaited(afterPull());
  }

  /// 「不要了」：看过文字觉得没用的，从豆子上删掉，拉下来的音频和文字也丢掉（不导入录音卡）。
  /// 返回删成没有（录音豆不在旁边 / 没回话就什么都不动）。
  Future<bool> discard(BeanFile f) async {
    if (!reviewing(f)) return false;
    var ok = false;
    await _session('删除中…', (c) async {
      if (!reviewing(f)) return;
      ok = await c.delete(f.id) == true;
      if (ok) {
        files = [
          for (final x in files)
            if (x.id != f.id) x,
        ];
      }
    });
    if (!ok) return false;
    store.recs.remove(f.stem);
    for (final x in [
      store.audio(f.stem),
      store.lib.transcript(f.stem),
      store.result(f.stem),
      store.raw(f.stem),
    ]) {
      if (await x.exists()) await x.delete();
    }
    await store.save();
    notifyListeners();
    return true;
  }

  /// 遥控录音豆开始 / 停止录音。返回豆子认没认（null = 没回话）。
  Future<bool?> setRecording(bool on) async {
    bool? ok;
    await _session(on ? '开始录音…' : '停止录音…', (c) async {
      ok = await c.setRecording(on);
      info = await c.info() ?? info;
    });
    return ok;
  }

  // ───────── 连一次 ─────────

  /// 定时 / 点「现在同步」：读状态和列表，有待拉的（或者开了自动拉）就拉。
  Future<void> run() => _session('', (c) async {
    final todo = [
      for (final f in files)
        if (pullable(f) && (auto || queued(f))) f,
    ];
    if (todo.isEmpty) return;
    phase = '拉录音';
    notifyListeners();
    for (final f in todo) {
      await _pull(c, f);
    }
  });

  /// 连上（读电量、录音列表）→ 做 [body] → 断开。同一时间只连一次；暂停了不连。
  Future<void> _session(
    String what,
    Future<void> Function(BeanConn c) body,
  ) async {
    if (busy || off) return;
    busy = true;
    phase = '找录音豆…';
    notifyListeners();
    BeanConn? c;
    try {
      if (mac == null) {
        final seen = await scan();
        if (seen.isEmpty) return;
        // 认第一颗（信号最强的）：一个人一般只有一颗
        store.settings['beanMac'] = seen.first.mac;
        await store.save();
      }
      phase = '连接中…';
      notifyListeners();
      c = await find(mac!);
      if (c == null) {
        connected = false;
        here = false;
        return;
      }
      connected = true;
      here = true;
      lastSeen = DateTime.now();
      error = null;
      info = await c.info() ?? info;
      final i = info;
      if (i != null) {
        store.settings['beanInfo'] = [
          i.firmware,
          i.serial,
          i.battery,
          i.caseBattery,
          i.charging,
          i.totalKB,
          i.freeKB,
        ];
      }
      phase = '读录音列表…';
      notifyListeners();
      files = await c.files();
      store.settings['beanListedAt'] = DateTime.now().toIso8601String();
      // 豆子上已经没有的，从待拉里拿掉
      final ids = {for (final f in files) f.id};
      queue = queue.where(ids.contains).toSet();
      await store.save();
      phase = what;
      notifyListeners();
      await body(c);
    } catch (e) {
      error = '录音豆：$e';
    } finally {
      await c?.close();
      connected = false;
      busy = false;
      phase = '';
      notifyListeners();
    }
  }

  /// 这一颗豆子的录音在本机的中间文件（解密后的裸数据，断了接着往后写）。
  File _part(String stem) => File('${store.dir.path}/raw/$stem.bean');

  Future<void> _pull(BeanConn c, BeanFile f) async {
    final bytes = f.frames * frameBytes; // 解密后整条多大（进度按这个算）
    final r =
        store.recs.putIfAbsent(f.stem, () => Rec(f.stem, bytes, 'pulling'))
          ..stage = 'pulling'
          ..size = bytes
          ..noStream =
              true // Ogg 不能像卡的裸帧那样分段边拉边传，拉完整条一次传
          ..deletedOnCard = true; // 不是卡上的，卡那边的「拉完删卡」别碰它
    final part = _part(f.stem);
    final t0 = DateTime.now();
    final got0 = await part.exists() ? await part.length() : 0;
    r
      ..got = got0
      ..bps = 0;
    await store.save();
    var last = t0;
    await c.pull(
      f,
      part,
      progress: (frames, total) {
        r.got = frames * frameBytes;
        final now = DateTime.now();
        final secs = now.difference(t0).inMilliseconds / 1000;
        if (secs > 3) r.bps = (r.got - got0) / secs;
        if (now.difference(last).inMilliseconds > 1000) {
          last = now;
          notifyListeners();
        }
      },
    );
    r.bps = 0;
    final have = await part.length();
    if (have < bytes * 0.99) {
      // 没拉全（断了 / 豆子走远了）：留着，下一轮接着拉
      await store.save();
      return;
    }
    await store
        .raw(f.stem)
        .writeAsBytes(
          oggOpus(splitFrames(await part.readAsBytes())),
          flush: true,
        );
    await part.delete();
    r
      ..stage = 'pulled'
      ..got = r.size
      ..error = null;
    queue = queue..remove(f.id);
    await store.save();
    notifyListeners();
    unawaited(afterPull());
  }
}

/// 解密后的裸数据 → 一块一块（每块 160 字节；最后不满一块的丢掉，那是没传完的半块）。
List<Uint8List> splitFrames(Uint8List raw) => [
  for (var i = 0; i + frameBytes <= raw.length; i += frameBytes)
    Uint8List.sublistView(raw, i, i + frameBytes),
];
