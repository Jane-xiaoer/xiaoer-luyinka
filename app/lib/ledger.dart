// 小耳经纪人的台账（只有小耳自己的 Mac 上有）：待确认里改了一件事，顺手写回台账。
// 别人装的录音卡没有台账，[Ledger.detect] 返回 null，这块整个不出现。
// 读：直接读台账的 事项.json 找这件事对应的台账号（录音卡推过去时 sources 记的是「场景号#第几件」）。
// 写：一律走台账自己的命令（ledger.py），不直接改它的文件：
//   不是任务 → drop（不做了）· 是别人的 → wait --on 某某（等某某）· 换项目 → claim <号> <项目>。是我的 → 不动台账。
import 'dart:convert';
import 'dart:io';

class Ledger {
  final String script; // ledger.py
  final String tasksFile; // 事项.json
  final Map<String, String>? env; // 测试用：LINGGAN_SETTINGS 指到台账副本
  Ledger(this.script, this.tasksFile, {this.env});

  static const python = '/usr/bin/python3';

  /// 这台 Mac 上有台账就用（小耳自己的电脑），没有就是 null。
  static Ledger? detect() {
    final home = Platform.environment['HOME'];
    if (home == null || !Platform.isMacOS) return null;
    final script = '$home/projects/xiaoer-linggan/mac/ledger.py';
    final tasks = '$home/Desktop/xiaoer/小耳灵感/台账/事项.json';
    if (!File(script).existsSync() || !File(tasks).existsSync() || !File(python).existsSync()) return null;
    return Ledger(script, tasks);
  }

  /// 录音卡里一件事 → 台账里对应的那件（号、标题、状态、项目）。对不上就是 null（宁可不写台账，不写错号）。
  /// 先认字面：同一段推过去的事里，两字片段重合 ≥ 五成的最像那件；
  /// 不够五成时再看位置：录音卡推过去是「行动在前、提醒在后」按顺序列的，台账 sources 记「场景号#第几件」，
  /// 第几件正好是 [pos]、字面也沾边（≥ 两成半）的也认。
  Future<LedgerItem?> find(String sceneId, String text, {int? pos}) async {
    try {
      final all = jsonDecode(File(tasksFile).readAsStringSync()); // 文件不大；同步读，界面测试里也读得完
      final items = all is Map ? all.values : (all is List ? all : const []);
      LedgerItem? best, byPos;
      var top = 0.0;
      for (final t in items) {
        if (t is! Map) continue;
        final sources = t['sources'] is List ? (t['sources'] as List).map((x) => '$x') : const <String>[];
        if (!sources.any((s) => s.startsWith('$sceneId#'))) continue;
        final it = LedgerItem('${t['id']}', '${t['title'] ?? ''}', '${t['status'] ?? ''}', '${t['project'] ?? ''}', '${t['waiting_on'] ?? ''}');
        final s = overlap(text, it.title);
        if (s > top) (best, top) = (it, s);
        if (pos != null && sources.contains('$sceneId#$pos') && s >= 0.25) byPos = it;
      }
      // 门槛五成：同一段里「联系李总」别对上「联系李航」
      return top >= 0.5 ? best : byPos;
    } catch (_) {
      return null;
    }
  }

  Future<ProcessResult> _run(List<String> args) =>
      Process.run(python, [script, ...args],
          workingDirectory: File(script).parent.path, environment: env, stdoutEncoding: utf8, stderrEncoding: utf8);

  /// 把这次的选择写回台账；返回一句给人看的结果。出错照抛（带台账自己的报错）。
  /// 先看台账现状：已经做完 / 不做了的不再改（不把做完的改回「等别人」）；跟现在一样的不重复写。
  Future<String> apply(LedgerItem it, String kind, {String who = '', String project = ''}) async {
    final closed = it.status == '做完' || it.status == '不做了';
    if (kind == 'not_task' && closed) return '台账 #${it.id} 已经是「${it.status}」，没动';
    if (kind == 'owner' && who != '我' && who.isNotEmpty) {
      if (closed) return '台账 #${it.id} 已经是「${it.status}」，没改成等$who';
      if (it.status == '等别人' && it.waitingOn == who) return '台账 #${it.id} 本来就在等$who';
    }
    if (kind == 'project' && it.project == project) return '台账 #${it.id} 本来就在「$project」';
    final (args, done) = switch (kind) {
      'not_task' => (['drop', it.id, '--note', '录音卡待确认：不是任务', '--evidence', '录音卡待确认'], '台账 #${it.id} 改成「不做了」'),
      'owner' when who != '我' && who.isNotEmpty =>
        (['wait', it.id, '--on', who, '--note', '录音卡待确认：是$who的', '--evidence', '录音卡待确认'], '台账 #${it.id} 改成「等$who」'),
      'project' => (['claim', it.id, project, '--evidence', '录音卡待确认'], '台账 #${it.id} 归到「$project」'),
      _ => (<String>[], ''),
    };
    if (args.isEmpty) return '';
    final r = await _run(args);
    // 台账有的错（比如项目名不认识）只往 stderr 说一句、退出码还是 0：没输出结果、只有报错，也算没改成
    if (r.exitCode != 0 || ('${r.stdout}'.trim().isEmpty && '${r.stderr}'.trim().isNotEmpty)) {
      final err = '${r.stderr}'.trim();
      throw Exception(err.isEmpty ? '台账没改成（${r.exitCode}）' : err.split('\n').last);
    }
    return done;
  }

  List<String>? _projects;

  /// 台账认的项目名（换项目时的候选；claim 只认这些）。读不到就是空。
  Future<List<String>> projects() async {
    if (_projects != null) return _projects!;
    try {
      final r = await Process.run(
          python,
          ['-c', 'import json,ledger;print(json.dumps(sorted(ledger.L.project_names(ledger.L.load_projects())|set(ledger.projects())),ensure_ascii=False))'],
          workingDirectory: File(script).parent.path,
          environment: env,
          stdoutEncoding: utf8);
      if (r.exitCode == 0) return _projects = List<String>.from(jsonDecode('${r.stdout}'.trim()));
    } catch (_) {}
    return [];
  }
}

class LedgerItem {
  final String id, title, status, project, waitingOn;
  const LedgerItem(this.id, this.title, this.status, this.project, [this.waitingOn = '']);
}

/// 两句话字面有多像：[a] 的两字片段有几成在 [b] 里。
double overlap(String a, String b) {
  Set<String> g(String t) {
    final c = t.replaceAll(RegExp(r'[\s，。、,.（）()！？!?：:“”"]'), '');
    return {for (var i = 0; i + 1 < c.length; i++) c.substring(i, i + 2)};
  }

  final x = g(a), y = g(b);
  return x.isEmpty ? 0 : x.intersection(y).length / x.length;
}
