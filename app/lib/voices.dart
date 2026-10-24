// 声纹库：现场会议里标过「这句是谁说的」，就记下那句的声纹（192 维向量），以后这个人一开口就认得出来。
// 跨会议保留，只存在这台设备上：<App 目录>/voices.json
//   {"v":2, "people": {人名: {"manual": [base64 向量…], "auto": [base64 向量…]}}}（旧版是 {人名: [向量…]}，读得进来）
// manual = 亲手标的，一直留着（最多 [keep] 条）；auto = 小耳认得特别有把握时自己学的，每人只留最近 [autoKeep] 条：
// 偶尔学错一条也会被新的顶掉，不会越学越偏。
//
// 认人：和每个人记下的声纹逐条算余弦相似度，取最像的两条的平均当这个人的分数。
// 最高分够 [minScore]、又比第二像的人高出 [minMargin]；或者至少认得两个人、最高分够 [relScore] 且领先 [relMargin]，
// 才算认出来；没把握就留空，宁可空着也不乱标。
// 阈值来自 2026-10-24 实测（CAM++ 中文模型）：同一个人不同句子 0.76–0.91，不同人最高 0.72（同源合成声音除外）。
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 认人的结果：最像的是谁、多像、比第二像的高出多少、认不认（[name] 为 null = 没把握）。
class VoiceMatch {
  final String? name;
  final String best;
  final double score, gap;
  final int people;
  const VoiceMatch(this.name, this.best, this.score, this.gap, this.people);
}

class Voices {
  static const minScore = 0.6;
  static const minMargin = 0.05;
  // 对话里一两秒的短句、只标过一两句的人，分数整体偏低（2026-10-24 两人对话：对方的句子和他只有 0.37–0.47，
  // 和她只有 0.14–0.20）。至少认得两个人时，明显更像其中一个也算认出来。
  static const relScore = 0.3;
  static const relMargin = 0.15;
  // 只认得一个人时没有「更像谁」可比，只能看绝对分：同一个场地、同一套音箱里大家的分数都偏高，
  // 0.6 会把别人 40% 左右的话认成他；0.8 才压到 0.4% 以下（10-23 活动录音，只标一位嘉宾测）。
  static const soloScore = 0.8;
  // 自动学：至少认得两个人、这句够长、明显更像某一个（领先一大截）才学。只认得一个人时不学，免得把别人学成他。
  static const learnScore = 0.45;
  static const learnGap = 0.25;
  static const learnSeconds = 2.0;
  static const keep = 30; // 亲手标的每人最多留这么多条，新的顶掉旧的
  static const autoKeep = 10; // 自己学的每人最多这么多条

  final File file;
  final Map<String, List<Float32List>> _manual = {};
  final Map<String, List<Float32List>> _auto = {};
  Voices(this.file) {
    try {
      if (!file.existsSync()) return;
      final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      List<Float32List> vs(Object? l) => [for (final s in (l as List? ?? const [])) decode(s as String)];
      if (j['v'] == 2) {
        for (final e in (j['people'] as Map<String, dynamic>).entries) {
          final p = e.value as Map<String, dynamic>;
          _manual[e.key] = vs(p['manual']);
          if ((p['auto'] as List?)?.isNotEmpty == true) _auto[e.key] = vs(p['auto']);
        }
      } else {
        for (final e in j.entries) {
          _manual[e.key] = vs(e.value);
        }
      }
    } catch (_) {}
  }

  List<String> get names => {..._manual.keys, ..._auto.keys}.toList();
  int manualCount(String name) => _manual[name]?.length ?? 0;
  int autoCount(String name) => _auto[name]?.length ?? 0;

  /// 记下「这条声纹是 [name] 的」（亲手标的）。
  void add(String name, Float32List emb) {
    final list = _manual.putIfAbsent(name, () => []);
    list.add(emb);
    if (list.length > keep) list.removeRange(0, list.length - keep);
    _save();
  }

  /// 认得特别有把握的一句（[seconds] 秒长）：自己学进去。学了返回 true。
  bool learn(Float32List emb, double seconds) {
    if (seconds < learnSeconds) return false;
    final m = match(emb);
    if (m == null || m.name == null || m.people < 2 || m.score < learnScore || m.gap < learnGap) return false;
    final list = _auto.putIfAbsent(m.name!, () => []);
    list.add(emb);
    if (list.length > autoKeep) list.removeRange(0, list.length - autoKeep);
    _save();
    return true;
  }

  void forget(String name) {
    final a = _manual.remove(name) != null, b = _auto.remove(name) != null;
    if (a || b) _save();
  }

  /// 认人：认不出返回 null。
  String? identify(Float32List emb) => match(emb)?.name;

  VoiceMatch? match(Float32List emb) {
    final scores = <String, double>{};
    for (final n in names) {
      final cs = [
        for (final v in [...?_manual[n], ...?_auto[n]]) cosine(emb, v),
      ]..sort((a, b) => b.compareTo(a));
      if (cs.isEmpty) continue;
      scores[n] = cs.take(2).reduce((a, b) => a + b) / min(2, cs.length);
    }
    if (scores.isEmpty) return null;
    final ranked = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked.first;
    final second = ranked.length > 1 ? ranked[1].value : -1.0;
    final gap = best.value - second;
    String? name;
    if (ranked.length == 1) {
      name = best.value >= soloScore ? best.key : null;
    } else if ((best.value >= minScore && gap >= minMargin) || (best.value >= relScore && gap >= relMargin)) {
      name = best.key;
    }
    return VoiceMatch(name, best.key, best.value, gap, ranked.length);
  }

  void _save() {
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'v': 2,
          'people': {
            for (final n in names)
              n: {
                'manual': [for (final v in _manual[n] ?? const <Float32List>[]) encode(v)],
                'auto': [for (final v in _auto[n] ?? const <Float32List>[]) encode(v)],
              },
          },
        }),
      );
      tmp.renameSync(file.path);
    } catch (_) {}
  }

  static String encode(Float32List v) => base64Encode(v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes));
  static Float32List decode(String s) => Float32List.view(Uint8List.fromList(base64Decode(s)).buffer);

  static double cosine(Float32List a, Float32List b) {
    if (a.length != b.length || a.isEmpty) return -1;
    var d = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      d += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    return na == 0 || nb == 0 ? -1 : d / sqrt(na * nb);
  }
}

/// 一段话里找换人的位置（返回样本序号，升序）。面对面聊天接话几乎不停顿，光靠停顿切不开两个人
/// （2026-10-24 Jane 两人对话：0.3 秒停顿门槛下仍有 16 秒一段、前半她后半对方）。
///
/// 两道关（阈值来自同一天实测：她的两人对话 + 10-23 活动里嘉宾独讲）：
///   1. 每 0.5 秒一格，比较前后两个不重叠的 1.5 秒小窗：低于 [windowMax]（0.3）且是局部最低，算候选；
///      独讲时小窗也会偶尔掉到 0.3 以下（掌声、换气），所以还要第二道。
///   2. 候选点左右各取最多 4 秒整体比：低于 [sideMax]（0.6）才切。换人处 0.22–0.55，独讲误报处 0.71–0.84。
/// 切出来的每块至少 1.5 秒。[embed] 给一段样本算声纹。
List<int> speakerCuts(
  Float32List x,
  Float32List Function(Float32List) embed, {
  int rate = 16000,
  double windowMax = 0.3,
  double sideMax = 0.6,
}) {
  final win = (rate * 1.5).round(), hop = rate ~/ 2, side = rate * 4;
  if (x.length < rate * 3) return const [];
  final w = <Float32List>[for (var s = 0; s + win <= x.length; s += hop) embed(Float32List.sublistView(x, s, s + win))];
  // 分界点 b = k*hop：左窗是 [b-win, b]（第 k-3 个），右窗是 [b, b+win]（第 k 个）
  final steps = win ~/ hop; // 3
  final cand = <(int, double)>[];
  final sims = <int, double>{};
  for (var k = steps; k < w.length; k++) {
    sims[k] = Voices.cosine(w[k - steps], w[k]);
  }
  for (final e in sims.entries) {
    final k = e.key, v = e.value;
    if (v >= windowMax) continue;
    if ((sims[k - 1] ?? 2) < v || (sims[k + 1] ?? 2) < v) continue;
    cand.add((k * hop, v));
  }
  cand.sort((a, b) => a.$2.compareTo(b.$2)); // 最不像的先试
  final cuts = <int>[];
  for (final (b, _) in cand) {
    final lo = cuts.where((c) => c < b).fold(0, (m, c) => c > m ? c : m);
    final hi = cuts.where((c) => c > b).fold(x.length, (m, c) => c < m ? c : m);
    if (b - lo < win || hi - b < win) continue;
    final l = Float32List.sublistView(x, (b - side).clamp(lo, b), b);
    final r = Float32List.sublistView(x, b, (b + side).clamp(b, hi));
    if (Voices.cosine(embed(l), embed(r)) < sideMax) cuts.add(b);
  }
  return cuts..sort();
}
