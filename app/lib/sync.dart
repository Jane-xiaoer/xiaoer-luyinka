// 同步：卡 → 本机 → 云端 → 场景。打开 App 自动跑，之后每 30 秒看一眼（卡在旁边就拉，云端好了就收）。
import 'dart:async';

import 'card/client.dart';
import 'card/protocol.dart';
import 'cloud.dart';
import 'store.dart';

typedef LinkFactory = Future<Link?> Function(); // 扫卡并连上；扫不到返回 null

class CardState {
  bool connected = false;
  bool scanning = false;
  CardInfo? info;
  String? name;
  String? error;
  DateTime? lastSeen;
}

class Syncer {
  final Store store;
  final Cloud cloud;
  final LinkFactory connect;
  final String Function() timezone;
  final card = CardState();
  bool _busy = false;
  Timer? _timer;
  void Function()? onChange;

  Syncer(this.store, this.cloud, this.connect, this.timezone);

  void _changed() {
    store.save();
    onChange?.call();
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => run());
    run();
  }

  void stop() => _timer?.cancel();

  bool get deleteAfter => store.settings['deleteAfter'] == true;

  /// 一轮：拉卡 → 传云 → 收结果。重复调用安全（正在跑就跳过）。
  Future<void> run({bool fromCard = true}) async {
    if (_busy) return;
    _busy = true;
    try {
      cloud.token ??= store.settings['token'] as String?;
      if (cloud.token == null) {
        store.settings['token'] = await cloud.register();
      }
      if (fromCard) await _pull();
      await _upload();
      await _collect();
    } catch (e) {
      card.error = e.toString();
    } finally {
      _busy = false;
      _changed();
    }
  }

  Future<void> _pull() async {
    card.scanning = true;
    _changed();
    Link? link;
    try {
      link = await connect();
    } catch (e) {
      card.error = '连不上卡：$e';
    } finally {
      card.scanning = false;
    }
    if (link == null) {
      card.connected = false;
      return;
    }
    final c = CardClient(link);
    try {
      card
        ..connected = true
        ..error = null
        ..lastSeen = DateTime.now();
      await c.syncTime();
      card.info = await c.info();
      _changed();
      final files = await c.listFiles();
      for (final f in files) {
        final r = store.recs.putIfAbsent(f.stem, () => Rec(f.stem, f.size, 'card'));
        if (r.stage == 'card' || r.stage == 'pulling') await _download(c, f, r);
        if (r.stage == 'done' && deleteAfter && !r.deletedOnCard) {
          r.deletedOnCard = await c.delete(f.name) != false;
        }
      }
    } on CardError catch (e) {
      card.error = e.message;
    } on TimeoutException {
      card.error = '卡没回话，靠近一点再试';
    } finally {
      await c.close();
      card.connected = false;
      _changed();
    }
  }

  Future<void> _download(CardClient c, RemoteFile f, Rec r) async {
    r.stage = 'pulling';
    var last = DateTime.now();
    await c.download(f, store.raw(f.stem, part: true), progress: (got, total) {
      r.got = got;
      if (DateTime.now().difference(last).inMilliseconds > 500) {
        last = DateTime.now();
        onChange?.call();
      }
    });
    await store.raw(f.stem, part: true).rename(store.raw(f.stem).path);
    r
      ..stage = 'pulled'
      ..got = r.size;
    _changed();
  }

  Future<void> _upload() async {
    for (final r in store.recs.values.where((r) => r.stage == 'pulled' || (r.stage == 'error' && r.job == null))) {
      final f = store.raw(r.stem);
      if (!await f.exists()) continue;
      r.stage = 'uploading';
      _changed();
      try {
        r
          ..job = await cloud.upload('${r.stem}.', await f.readAsBytes(), timezone())
          ..stage = 'processing'
          ..error = null;
      } catch (e) {
        r
          ..stage = 'pulled'
          ..error = '上传没成功，稍后自动再试：$e';
      }
      _changed();
    }
  }

  Future<void> _collect() async {
    for (final r in store.recs.values.where((r) => r.stage == 'processing' && r.job != null)) {
      final j = await cloud.job(r.job!);
      r.progress = (j['progress'] as num?)?.toInt() ?? r.progress;
      if (j['status'] == 'done') {
        await store.putResult(r.stem, Map<String, dynamic>.from(j['result']));
        try {
          await store.audio(r.stem).writeAsBytes(await cloud.audio(r.job!));
        } catch (_) {}
        final raw = store.raw(r.stem);
        if (await raw.exists()) await raw.delete();
        r
          ..stage = 'done'
          ..error = null;
      } else if (j['status'] == 'error') {
        r
          ..stage = 'error'
          ..error = j['error']?.toString();
      }
      _changed();
    }
  }
}
