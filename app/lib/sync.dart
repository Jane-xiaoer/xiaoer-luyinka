// 同步：卡 → 本机 → 云端转写 → 本机按类别整理 → 资料文件夹。打开 App 自动跑，之后每 30 秒看一眼。
// 长录音边拉边传：从卡上每拉够一段（1.5MB ≈ 12 分钟）就传上云端先转着，拉完再传最后一段、叫云端接起来。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'analyze.dart';
import 'card/client.dart';
import 'card/protocol.dart';
import 'cloud.dart';
import 'llm.dart';
import 'store.dart';
import 'todos.dart';

typedef LinkFactory = Future<Link?> Function(String id); // 只连这一张；不在旁边返回 null
typedef CardScanner = Future<List<CardChoice>> Function(); // 附近所有的卡，信号强的在前

/// 附近扫到的一张卡。
/// 卡上一帧 40 字节（16k 单声道 Opus，20ms）。
const frameBytes = 40;

/// 边拉边传一段多大：1.5MB ≈ 12.5 分钟。是 [frameBytes] 的整数倍，段边界正好落在帧边界上。
const defaultPartBytes = frameBytes * 37500;

/// 已经拉到 [have] 字节、传了 [sent] 段时，接下来要传的段 [(开始, 结束)]（每段 [partBytes]）。
/// 没拉完只传满的段；[last]（拉完了）连最后不满一段的也传。
List<(int, int)> partsToSend(int have, int sent, int partBytes, {bool last = false}) => [
      for (var start = sent * partBytes; start < have; start += partBytes)
        if (start + partBytes <= have) (start, start + partBytes) else if (last) (start, have),
    ];

class CardChoice {
  final String id, label;
  final int? rssi;
  CardChoice(this.id, this.label, this.rssi);
}

class CardState {
  bool connected = false;
  bool scanning = false;
  CardInfo? info;
  String? error;
  DateTime? lastSeen;
  List<CardChoice> choices = []; // 第一次就扫到好几张：等用户自己点
}

class Syncer {
  final Store store;
  final Cloud cloud;
  final LinkFactory connect;
  final CardScanner scan;
  final String Function() timezone;
  final int partBytes;
  final card = CardState();
  bool _busy = false;
  Timer? _timer;
  void Function()? onChange;

  late final Llm llm;
  Chat? chat; // 测试时换成假的

  Syncer(this.store, this.cloud, this.connect, this.scan, this.timezone, {this.chat, this.partBytes = defaultPartBytes})
      : assert(partBytes % frameBytes == 0) {
    llm = Llm(cloud, () => Map<String, dynamic>.from(store.settings['llm'] ?? {}));
    cloud.onToken = (t) {
      store.settings['token'] = t;
      store.save();
    };
  }

  /// 认准的那张卡（第一次连上就锁定，只在「换一张卡」时改）。
  String? get boundId => store.settings['device'] as String?;
  String get boundName => (store.settings['deviceName'] as String?) ?? '录音卡';

  void bind(CardChoice c) {
    store.settings['device'] = c.id;
    store.settings['deviceName'] = c.label;
    card
      ..choices = []
      ..info = null
      ..lastSeen = null
      ..error = null;
    _changed();
    run();
  }

  /// 给「选卡」列表用：等手上这一轮跑完再扫，免得跟同步抢蓝牙。
  Future<List<CardChoice>> scanNearby() async {
    while (_busy) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    _busy = true;
    try {
      return await scan();
    } finally {
      _busy = false;
    }
  }

  void _changed() {
    store.save();
    onChange?.call();
  }

  void start() {
    // 旧版整理的（还没按类别模板写笔记）：排进「待整理」，升级后自动按新模板重整一遍
    for (final r in store.recs.values.where((r) => r.stage == 'done')) {
      r.progress = 0; // 旧版做完了进度还停在半截
      final res = store.readResult(r.stem);
      final sc = res?['scenes'] as List?;
      if (sc != null && sc.isNotEmpty && sc.every((x) => x is Map && !x.containsKey('body')) && (res?['lines'] as List?)?.isNotEmpty == true) {
        r.stage = 'transcribed';
      }
    }
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
      // 不用云端，先收：云端登记不上也不耽误外面放进来的。它出错不能拖垮拉卡（每条的错它自己报）
      await importInbox().catchError((_) {});
      cloud.token ??= store.settings['token'] as String?;
      if (cloud.token == null) {
        store.settings['token'] = await cloud.register();
      }
      if (fromCard) await _pull();
      await _upload();
      await _collect();
      await _analyze();
    } on CloudError catch (e) {
      if (e.status == 401) {
        // 云端不认这个登记（换了服务器 / 数据重置）：重新登记，没出结果的从头传
        store.settings['token'] = await cloud.register();
        for (final r in store.recs.values.where((r) => r.stage == 'processing').toList()) {
          r
            ..stage = 'pulled'
            ..job = null;
        }
        for (final r in store.recs.values) {
          r
            ..stream = null
            ..sent = 0;
        }
      } else {
        card.error = e.message;
      }
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
      if (boundId == null) {
        final seen = await scan();
        if (seen.length == 1) {
          store.settings['device'] = seen.first.id;
          store.settings['deviceName'] = seen.first.label;
          card.choices = [];
        } else {
          card.choices = seen; // 0 张：接着等；好几张：让用户点
        }
      }
      if (boundId != null) link = await connect(boundId!);
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
      // 记下来：没连上也能在「录音卡」页看到上次的电量 / 存储
      store.settings['cardInfo'] = [card.info!.battery, card.info!.freeKb, card.info!.totalKb, card.info!.version, DateTime.now().toIso8601String()];
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
    final part = store.raw(f.stem, part: true);
    final t0 = DateTime.now();
    final got0 = await part.exists() ? await part.length() : 0;
    r
      ..got = got0
      ..bps = 0;
    var last = t0;
    _kick(r, part); // 上一轮（或 App 重启前）已经拉下来的，先把满的段传了
    try {
      await c.download(f, part, progress: (got, total) {
        r.got = got;
        final now = DateTime.now();
        final secs = now.difference(t0).inMilliseconds / 1000;
        if (secs > 3) r.bps = (got - got0) / secs;
        if (now.difference(last).inMilliseconds > 500) {
          last = now;
          onChange?.call();
          _kick(r, part);
        }
      });
    } finally {
      await _pumping; // 正在传的那段等它传完，别跟下一轮抢
      r.bps = 0;
    }
    await part.rename(store.raw(f.stem).path);
    r
      ..stage = 'pulled'
      ..got = r.size;
    _changed();
  }

  Future<void> _pumping = Future.value();
  bool _pumpBusy = false;
  DateTime? _pumpFailed;

  /// 拉卡的同时：攒够一段就在后台传上去（不挡着拉卡）。传失败了 30 秒内不再试，拉完那一下会补传。
  void _kick(Rec r, File src) {
    if (_pumpBusy || r.got < (r.sent + 1) * partBytes) return;
    if (_pumpFailed != null && DateTime.now().difference(_pumpFailed!).inSeconds < 30) return;
    _pumpBusy = true;
    _pumping = _stream(r, src).catchError((_) => _pumpFailed = DateTime.now()).whenComplete(() => _pumpBusy = false);
  }

  /// 边拉边传：把 [src] 里还没传的满段传上去；[last]（拉完了）连最后一段也传，再叫云端接起来。
  /// 不满一段的短录音、云端不支持的、云端那条坏了的：什么都不做，拉完走一次性上传。
  Future<void> _stream(Rec r, File src, {bool last = false}) async {
    if (r.job != null || r.noStream) return;
    if (r.stream == null) {
      if (await src.length() < partBytes || !await cloud.canStream()) return;
      r
        ..stream = await cloud.openStream('${r.stem}.', timezone())
        ..sent = 0;
      _changed();
    }
    final id = r.stream!;
    try {
      final have = await src.length();
      final raf = await src.open();
      try {
        while (true) {
          final next = partsToSend(have, r.sent, partBytes, last: last).firstOrNull;
          if (next == null) break;
          await raf.setPosition(next.$1);
          final bytes = await raf.read(next.$2 - next.$1);
          // 云端回它实际有几段：重传了已有的、或跳了号，都按它说的接着来
          r.sent = await cloud.putPart(id, r.sent, bytes);
          _changed();
        }
      } finally {
        await raf.close();
      }
      if (!last) return;
      try {
        await cloud.finish(id, r.sent);
      } on CloudError catch (e) {
        if (e.status == 409) r.sent = 0; // 云端段数跟这边对不上：下回从头对一遍（已有的段云端直接认，不重收）
        rethrow;
      }
      r
        ..job = id
        ..stream = null;
    } on CloudError catch (e) {
      if (e.status == 404 || e.status == 410) {
        // 云端那条没了（太久没传被清掉）→ 重开一条；坏了 / 已经结束 → 这条改回一次性上传
        r
          ..stream = null
          ..sent = 0
          ..noStream = e.status == 410;
        _changed();
      }
      rethrow;
    }
  }

  Future<void> _upload() async {
    for (final r in store.recs.values.where((r) => r.stage == 'pulled' || (r.stage == 'error' && r.job == null)).toList()) {
      final f = store.raw(r.stem);
      if (!await f.exists()) continue;
      r.stage = 'uploading';
      _changed();
      try {
        await _stream(r, f, last: true);
        r.job ??= await cloud.upload('${r.stem}.', await f.readAsBytes(), timezone());
        r
          ..stage = 'processing'
          ..progress = 0
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
    for (final r in store.recs.values.where((r) => r.stage == 'processing' && r.job != null).toList()) {
      final j = await cloud.job(r.job!);
      r.progress = (j['progress'] as num?)?.toInt() ?? r.progress;
      if (j['status'] == 'done') {
        final res = Map<String, dynamic>.from(j['result']);
        final lines = [for (final x in (res['lines'] as List? ?? const [])) List<String>.from(x)];
        await store.lib.writeTranscript(r.stem, (res['start'] ?? '').toString(), lines);
        try {
          await store.audio(r.stem).writeAsBytes(await cloud.audio(r.job!));
        } catch (_) {}
        final old = (res['scenes'] as List?)?.isNotEmpty == true; // 旧版云端已经切好了
        await store.putResult(r.stem, {...res, 'scenes': res['scenes'] ?? []});
        await cloud.delete(r.job!).catchError((_) {}); // 取走了，云端删掉
        final raw = store.raw(r.stem);
        if (await raw.exists()) await raw.delete();
        r
          ..stage = r.stem.startsWith('bean') && !old
              ? 'review' // 录音豆的：先在录音豆页给用户看内容（没转出字也一样），导不导入由用户定
              : old || lines.isEmpty
                  ? 'done'
                  : 'transcribed'
          ..job = null
          ..progress = 0
          ..error = null;
      } else if (j['status'] == 'error') {
        r
          ..stage = 'error'
          ..error = j['error']?.toString();
      }
      _changed();
    }
  }

  /// 不是卡上来的录音（小耳语音按三道杠说的长口述等）：别的程序在本机转写好，放进
  /// <资料>/.xiaoer/inbox/<录音>.json（{start, lines:[[钟点, 文字]]}，最后写、写完再改名成 .json）
  /// 和同名 .m4a（原声，可没有），这里收进来，跟卡上的一样排进「待整理」。收完把收件里的删掉。
  Future<void> importInbox() async {
    final inbox = Directory('${store.lib.path}/.xiaoer/inbox');
    if (!await inbox.exists()) return;
    for (final f in inbox.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      final stem = f.path.split('/').last.replaceAll(RegExp(r'\.json$'), '');
      final audio = File('${inbox.path}/$stem.m4a');
      try {
        if (!store.recs.containsKey(stem) && !await store.result(stem).exists()) {
          final res = Map<String, dynamic>.from(jsonDecode(await f.readAsString()));
          final lines = [for (final x in (res['lines'] as List? ?? const [])) List<String>.from(x)];
          if (lines.isNotEmpty) {
            if (await audio.exists()) await audio.copy(store.audio(stem).path);
            await store.lib.writeTranscript(stem, (res['start'] ?? '').toString(), lines);
            await store.putResult(stem, {...res, 'scenes': []});
            store.recs[stem] = Rec(stem, 0, 'transcribed')..deletedOnCard = true;
          }
        }
        await f.delete();
        if (await audio.exists()) await audio.delete();
      } catch (e) {
        card.error = '收外面放进来的录音没成功（$stem）：$e';
      }
      _changed();
    }
  }

  /// 转写好的：在这台设备上按类别整理。失败了（没网 / key 不对）过 3 分钟再试，逐字稿已经存好了不会丢。
  Future<void> _analyze() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final r in store.recs.values.where((r) => r.stage == 'transcribed' && now - r.tried > 180000).toList()) {
      final res = store.readResult(r.stem);
      if (res == null) {
        r.stage = 'done';
        continue;
      }
      r
        ..stage = 'analyzing'
        ..progress = 0;
      _changed();
      try {
        final a = chat != null ? Analyzer(store.lib, chat!) : Analyzer.of(store.lib, llm);
        final before = res['scenes'] as List? ?? const [];
        res['scenes'] = await a.run(r.stem, res, progress: (d, t) {
          r.progress = t == 0 ? 0 : d * 100 ~/ t;
          onChange?.call();
        });
        carryDone(before, res['scenes']);
        await store.putResult(r.stem, res);
        r
          ..stage = 'done'
          ..progress = 0
          ..error = null;
      } catch (e) {
        r
          ..stage = 'transcribed'
          ..tried = now
          ..error = '整理没成功，稍后自动再试：$e';
      }
      _changed();
    }
  }

  /// 按（改过的）模板重新整理一条录音。
  Future<void> reanalyze(String stem) async {
    final r = store.recs.putIfAbsent(stem, () => Rec(stem, 0, 'transcribed')..deletedOnCard = true);
    r
      ..stage = 'transcribed'
      ..tried = 0;
    _changed();
    await run(fromCard: false);
  }
}
