// 录音处理到哪了：给醒目横幅和时间线占位卡用，说人话（在干嘛、多少、约剩多久、真卡住了就直说）。
import 'store.dart';

/// 一条录音在当前这一步的计时：哪一刻进的这步、上次有进度是什么时候。
class Track {
  final String stage;
  final DateTime since;
  DateTime moved;
  final int p0; // 进这一步时的进度
  int got, progress, sent;
  // 估剩多久的起点：进这一步后第一次报进度时重新定。边拉边传时云端早就转完了前几段，
  // 一进「转写」进度就从 0 跳到五六十，把这一跳算进速度会估得太快。
  DateTime rateFrom;
  int rateP0;
  Track(this.stage, this.since, this.p0, this.got, this.progress, this.sent)
      : moved = since,
        rateFrom = since,
        rateP0 = p0;
}

/// 按录音现在的状态更新计时：换了一步就重新计，有进度（拉到的字节 / 进度 / 已传段数变了）就记下时刻。做完的拿掉。
void observe(Map<String, Track> tracks, Iterable<Rec> recs, DateTime now) {
  final alive = <String>{};
  for (final r in recs) {
    if (r.stage == 'done') continue;
    alive.add(r.stem);
    final t = tracks[r.stem];
    if (t == null || t.stage != r.stage) {
      tracks[r.stem] = Track(r.stage, now, r.progress, r.got, r.progress, r.sent);
    } else if (t.got != r.got || t.progress != r.progress || t.sent != r.sent) {
      if (t.progress != r.progress && t.rateFrom == t.since && t.progress == t.p0) {
        t
          ..rateFrom = now
          ..rateP0 = r.progress;
      }
      t
        ..moved = now
        ..got = r.got
        ..progress = r.progress
        ..sent = r.sent;
    }
  }
  tracks.removeWhere((k, _) => !alive.contains(k));
}

/// 横幅上要显示的东西。step：0 从卡上拉 · 1 云端转写 · 2 整理。
class Activity {
  final int step;
  final bool alsoNext; // 边拉边传：拉着的时候云端也已经在转了
  final String headline;
  final String? detail;
  final String comfort;
  final String? stall; // 不是 null = 卡住了 / 出错了：原因 + 自动在做什么 + 你可以做什么
  final double? fraction; // 这一步的进度 0–1，不知道就是 null
  Activity(this.step, this.headline, this.comfort, {this.alsoNext = false, this.detail, this.stall, this.fraction});
}

const _order = ['pulling', 'uploading', 'pulled', 'processing', 'analyzing', 'transcribed', 'error', 'card'];

/// 横幅说哪一条：正在动的优先。
Rec? featured(Iterable<Rec> pending) {
  final l = pending.where((r) => _order.contains(r.stage)).toList()
    ..sort((a, b) => _order.indexOf(a.stage).compareTo(_order.indexOf(b.stage)));
  return l.firstOrNull;
}

/// 卡上的文件名 note20261023-194438 → 开录的墙上时间；别的名字认不出就是 null。
DateTime? recStart(String stem) {
  final m = RegExp(r'(\d{4})(\d\d)(\d\d)-?(\d\d)(\d\d)(\d\d)').firstMatch(stem);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  if (v[1] < 1 || v[1] > 12 || v[2] < 1 || v[2] > 31 || v[3] > 23 || v[4] > 59 || v[5] > 59) return null;
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}

String? recDay(String stem) {
  final t = recStart(stem);
  return t == null ? null : '${t.year}-${_p2(t.month)}-${_p2(t.day)}';
}

/// 时间线左栏的日子：有笔记的日子 + 正在处理的录音那天（第一条录音还没出结果时也有地方放占位卡），新的在前。
List<String> daysWithPending(Iterable<String> days, Iterable<Rec> pending) {
  final all = {...days, for (final r in pending) ?recDay(r.stem)}.toList()..sort((a, b) => b.compareTo(a));
  return all;
}

String _p2(int n) => n.toString().padLeft(2, '0');

/// 卡上录音 16kbps：每秒 2000 字节。不是卡上来的（size 0）就不知道多长。
double? recSeconds(Rec r) => r.size > 0 ? r.size / 2000 : null;

String spoken(double secs) {
  if (secs >= 3600) return '${(secs / 3600).toStringAsFixed(1)} 小时';
  final m = (secs / 60).round();
  return '${m < 1 ? 1 : m} 分钟';
}

String left(double secs) => secs < 60 ? '不到 1 分钟' : (secs >= 5400 ? '${(secs / 3600).toStringAsFixed(1)} 小时' : '${(secs / 60).ceil()} 分钟');

/// 安心话：按录音时长说要等多久。
String comfortLine(Rec r, {int others = 0}) {
  final secs = recSeconds(r);
  var s = secs == null
      ? 'App 开着就行，没坏，好了会自动出现在下面'
      : secs < 600
          ? '这段录音不长（约 ${spoken(secs)}），马上就好'
          : '这段录音约 ${spoken(secs)}，要等一会儿；App 开着就行，没坏，好了会自动出现在下面';
  if (others > 0) s += '（后面还有 $others 条排着）';
  return s;
}

/// 这一步正常要多久（秒），超过 2 倍算卡住。卡蓝牙约 7KB/s；云端 1 个 CPU，转写约录音时长的 0.2 倍。
double expectedSecs(Rec r) {
  final secs = recSeconds(r);
  final v = switch (r.stage) {
    'pulling' => r.size / 7000,
    'pulled' || 'uploading' => r.size / 50000,
    'processing' => (secs ?? 3600) * 0.25,
    'analyzing' || 'transcribed' => 60 + (secs ?? 1800) * 0.08,
    _ => 300.0,
  };
  return v < 150 ? 150 : v;
}

/// 按这一步里实测的进度速度估还剩几秒；还没动过就是 null。
double? _etaByRate(Rec r, Track t, DateTime now) {
  final el = now.difference(t.rateFrom).inMilliseconds / 1000;
  final done = r.progress - t.rateP0;
  // 云端进度是一档一档报的：才动了一两个点就按速度算，会一会儿 3 分钟一会儿 22 分钟地乱跳
  if (el < 20 || done < 5 || r.progress >= 100) return null;
  return (100 - r.progress) * el / done;
}

const stallIdle = Duration(minutes: 5);

/// [connected]：卡现在连着没；[cloudError]：这一轮跟云端说话出的错（没网等），没有就是 null。
Activity activity(Rec r, Track t, {required bool connected, required DateTime now, String? cloudError, int others = 0}) {
  final comfort = comfortLine(r, others: others);
  final idle = now.difference(t.moved);
  final elapsed = now.difference(t.since);
  final stuck = idle >= stallIdle; // 5 分钟没进度
  final overtime = elapsed.inSeconds > 2 * expectedSecs(r); // 超过预计时间 2 倍
  String mins(Duration d) => '${d.inMinutes} 分钟';

  switch (r.stage) {
    case 'card':
      return Activity(0, connected ? '排着队，马上从卡上拉' : '等卡靠近，靠近了自动拉', comfort,
          stall: !connected && stuck ? '卡住了：卡不在旁边 · 卡一靠近就自动拉 · 你可以把卡放到旁边、确认卡开着机' : null);
    case 'pulling':
      final f = r.size > 0 ? (r.got / r.size).clamp(0.0, 1.0) : 0.0;
      final pct = (f * 100).floor();
      final rest = r.size - r.got;
      final eta = connected && r.bps > 0 && rest > 0 ? ' · 约剩 ${left(rest / r.bps)}' : '';
      final head = connected ? '正在从卡上拉 $pct%$eta' : '等卡重新连上，接着拉（已拉 $pct%）';
      final detail = '${(r.got / 1e6).toStringAsFixed(1)} / ${(r.size / 1e6).toStringAsFixed(1)}MB'
          '${r.sent > 0 ? ' · 云端已经在边收边转（已传 ${r.sent} 段）' : ''}';
      String? stall;
      if (!connected && stuck) {
        stall = '卡住了：卡不在旁边或蓝牙断了，${mins(idle)}没拉到数据 · 每 30 秒自动重连，连上从断的地方接着拉 · 你可以把卡放到电脑旁边、确认卡有电';
      } else if (stuck) {
        stall = '卡住了：卡连着，但 ${mins(idle)}没传数据过来 · 正在自动重试 · 你可以把卡放近一点';
      } else if (overtime) {
        stall = '卡住了：拉得比平常慢很多（已经拉了 ${mins(elapsed)}） · 还在接着拉 · 你可以把卡放近一点';
      }
      return Activity(0, head, comfort, alsoNext: r.sent > 0, detail: detail, stall: stall, fraction: f);
    case 'pulled':
    case 'uploading':
      return Activity(1, '正在传到云端', comfort,
          detail: r.sent > 0 ? '大部分已经边拉边传上去了，只差最后一点' : null,
          stall: r.error != null
              ? '卡住了：传不上云端（多半是网络不通） · 每 30 秒自动重试 · 你可以看看网络'
              : overtime
                  ? '卡住了：传了 ${mins(elapsed)}还没传完，网络可能很慢 · 还在接着传 · 你可以看看网络'
                  : null);
    case 'processing':
      final eta = _etaByRate(r, t, now) ?? (recSeconds(r) == null ? null : recSeconds(r)! * 0.2 * (100 - r.progress) / 100);
      String? stall;
      if (cloudError != null && stuck) {
        stall = '卡住了：连不上云端，${mins(idle)}没有消息 · 每 30 秒自动再问 · 你可以看看网络';
      } else if (stuck) {
        stall = '卡住了：云端 ${mins(idle)}没有进度，可能在排队或服务器忙 · 每 30 秒自动再问 · 你可以先忙别的，好了会自动出来';
      } else if (overtime) {
        stall = '卡住了：云端转得比平常慢很多（已经 ${mins(elapsed)}） · 还在接着转 · 你可以先忙别的，好了会自动出来';
      }
      return Activity(1, '正在转写 ${r.progress}%${eta == null || stall != null ? '' : ' · 约剩 ${left(eta)}'}', comfort,
          detail: '云端把说的话转成文字', stall: stall, fraction: r.progress / 100);
    case 'error':
      return Activity(1, '云端没转成功', comfort,
          stall: '出错了：${r.error ?? '云端没说原因'} · 这一条不会自动重试 · 原录音还在这台电脑上，没丢');
    case 'transcribed':
      return Activity(2, '逐字稿好了，等着整理', comfort,
          stall: r.error != null ? '卡住了：${r.error} · 3 分钟后自动重试 · 你可以在「设置」里检查整理用的模型和网络' : null);
    case 'analyzing':
      final eta = _etaByRate(r, t, now);
      String? stall;
      if (stuck) {
        stall = '卡住了：整理 ${mins(idle)}没有进度，模型那边没回话 · 还在等 · 你可以检查网络，或在「设置」里换个模型';
      } else if (overtime) {
        stall = '卡住了：整理得比平常慢很多（已经 ${mins(elapsed)}），模型那边慢 · 还在接着整理 · 你可以在「设置」里换个快点的模型';
      }
      final head = r.progress == 0 ? '正在整理 · 先分场景' : '正在整理 ${r.progress}%${eta == null || stall != null ? '' : ' · 约剩 ${left(eta)}'}';
      return Activity(2, head, comfort, detail: '按类别写成笔记', stall: stall, fraction: r.progress / 100);
  }
  return Activity(0, '处理中', comfort);
}

/// 时间线占位卡上那一行：「19:44 起的录音 · 正在转写 45%」。
String placeholderLine(Rec r) {
  final t = recStart(r.stem);
  final when = t == null ? '一段录音' : '${_p2(t.hour)}:${_p2(t.minute)} 起的录音';
  final what = switch (r.stage) {
    'card' => '等着从卡上拉',
    'pulling' => '正在从卡上拉 ${r.size > 0 ? (r.got * 100 ~/ r.size).clamp(0, 100) : 0}%',
    'pulled' || 'uploading' => '正在传到云端',
    'processing' => '正在转写 ${r.progress}%',
    'error' => '云端没转成功',
    'transcribed' => '等着整理',
    'analyzing' => '正在整理 ${r.progress}%',
    _ => '处理中',
  };
  return '$when · $what';
}
