// 「交给 Agent」：把这一天的录音整理交出去。
//   复制给任意 AI（豆包 / Kimi / ChatGPT / Claude 网页版…）· 交给本机的 Claude Code / Codex（按设置里的整理规则）
//   分享到别的 App（安卓：飞书、微信、豆包…）· 存成 Markdown 文件
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'store.dart';
import 'theme.dart';

const defaultRules = '''按下面的规则处理我录音卡这一天的整理结果：
1. 每个场景在我的工作台里记一条：时间、标题、分类、人物、事件、核心观点、下一步行动、提醒事项。
   我的工作台是：（写上：飞书多维表格链接 / Notion 数据库 / 某个文件夹）
2. 「下一步行动」进我的待办，有具体时间的「提醒事项」进我的日历。
3. 最后用 5 行以内告诉我：这天聊了什么、要我马上看的。
不对外发任何东西；原文里没有的不写。''';

/// 一天 → Markdown（给 AI 看，也给人看）。
String dayMarkdown(String day, List<Scene> scenes, {bool fullText = true}) {
  final b = StringBuffer('# ${dayTitle(day)} 录音整理\n\n');
  for (final s in scenes) {
    b.writeln('## ${hm(s.start)}–${hm(s.end)} ${s.title}');
    b.writeln();
    b.writeln('- 分类：${s.category}');
    if (s.place.isNotEmpty) b.writeln('- 地点：${s.place}');
    if (s.people.isNotEmpty) b.writeln('- 人物：${s.people.join('、')}');
    b.writeln('- 事件：${s.event}');
    void list(String head, Iterable<String> xs) {
      if (xs.isEmpty) return;
      b.writeln('- $head：');
      for (final x in xs) {
        b.writeln('  - $x');
      }
    }

    list('核心观点', s.views);
    list('有价值的内容', s.valuable);
    list('值得记住的', s.memorable.map((m) => '[${m['t']}] ${m['text']}'));
    list('下一步行动', s.actions.map((a) => '${a['text']}${(a['who'] ?? '') != '' ? '（${a['who']}）' : ''}'));
    list('提醒事项', s.reminders.map((r) => '${r['text']}${(r['when'] ?? '') != '' ? '（${r['when']}）' : ''}'));
    if (s.body.isNotEmpty) {
      b.writeln('\n${s.body.replaceAllMapped(RegExp(r'^(#+) ', multiLine: true), (m) => '##${m[1]} ')}');
    } else if (s.minutesMd.isNotEmpty) {
      b.writeln('\n${s.minutesMd.replaceAllMapped(RegExp(r'^(#+) ', multiLine: true), (m) => '##${m[1]} ')}');
    }
    if (fullText && s.text.isNotEmpty) {
      b.writeln('\n<details><summary>逐字稿</summary>\n');
      for (final l in s.text) {
        b.writeln('[${l[0]}] ${l[1]}  ');
      }
      b.writeln('\n</details>');
    }
    b.writeln();
  }
  return b.toString();
}

/// 本机装了的 agent 命令行（App 从 Finder 打开时 PATH 里没有 ~/.local/bin，自己找）。
String? findAgent(String name) {
  if (!Platform.isMacOS) return null;
  final home = Platform.environment['HOME'] ?? '';
  for (final d in ['$home/.local/bin', '/opt/homebrew/bin', '/usr/local/bin', '$home/.claude/local', '$home/.npm-global/bin']) {
    final f = File('$d/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

Future<File> exportDay(Store store, String day, List<Scene> scenes) async {
  final dir = Directory('${store.dir.path}/export/$day');
  await dir.create(recursive: true);
  await File('${dir.path}/scenes.json').writeAsString(
      const JsonEncoder.withIndent(' ').convert({'day': day, 'scenes': [for (final s in scenes) s.d]}));
  final md = File('${dir.path}/$day 录音整理.md');
  await md.writeAsString(dayMarkdown(day, scenes));
  return md;
}

void showHandoff(BuildContext context, Store store, String? day, List<Scene> scenes) {
  if (day == null || scenes.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('这天还没有整理好的录音')));
    return;
  }
  final claude = findAgent('claude'), codex = findAgent('codex');
  showModalBottomSheet(
    context: context,
    backgroundColor: K.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('把 ${dayTitle(day)} 交给…', style: K.title(20)),
          const SizedBox(height: 4),
          Text('${scenes.length} 个场景，带要点、要办的和逐字稿', style: const TextStyle(color: K.mute)),
          const SizedBox(height: 16),
          if (claude != null) _Dest(Icons.terminal, 'Claude Code', '按你的整理规则，放进你的工作台 / 飞书',
              () => _runAgent(ctx, store, day, scenes, claude, 'Claude Code')),
          if (codex != null) _Dest(Icons.terminal, 'Codex', '按你的整理规则处理',
              () => _runAgent(ctx, store, day, scenes, codex, 'Codex')),
          _Dest(Icons.copy_all, '复制给任意 AI', '粘到豆包 / Kimi / ChatGPT / Claude 里就能用', () async {
            final rules = (store.settings['rules'] as String?) ?? defaultRules;
            await Clipboard.setData(ClipboardData(text: '$rules\n\n---\n\n${dayMarkdown(day, scenes)}'));
            if (ctx.mounted) {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('复制好了，去 AI 那里粘贴')));
            }
          }),
          _Dest(Icons.ios_share, '分享到其他 App', Platform.isAndroid ? '飞书、微信、豆包、Notion…' : '邮件、备忘录、飞书…', () async {
            final f = await exportDay(store, day, scenes);
            if (ctx.mounted) Navigator.pop(ctx);
            await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: '${dayTitle(day)} 录音整理'));
          }),
          _Dest(Icons.description_outlined, '存成 Markdown 文件', '存到「下载」文件夹', () async {
            final f = await exportDay(store, day, scenes);
            final dl = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
            final out = await f.copy('${dl.path}/${f.uri.pathSegments.last}');
            if (ctx.mounted) {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('存好了：${out.path}')));
            }
          }),
        ]),
      ),
    ),
  );
}

class _Dest extends StatelessWidget {
  final IconData icon;
  final String title, sub;
  final VoidCallback onTap;
  const _Dest(this.icon, this.title, this.sub, this.onTap);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: K.paper,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: K.line)),
          child: ListTile(
            minTileHeight: 60,
            leading: Icon(icon, color: K.accent),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(sub, style: const TextStyle(color: K.mute, fontSize: 13)),
            onTap: onTap,
          ),
        ),
      );
}

Future<void> _runAgent(BuildContext ctx, Store store, String day, List<Scene> scenes, String exe, String name) async {
  Navigator.pop(ctx);
  final f = await exportDay(store, day, scenes);
  final rules = (store.settings['rules'] as String?) ?? defaultRules;
  final prompt = '$rules\n\n这一天的数据：${f.parent.path}/scenes.json（同目录有 Markdown 版）。日期：$day。';
  final args = name == 'Claude Code'
      ? ['-p', prompt, '--allowedTools', 'Read,Write,Edit,Bash,mcp__*']
      : ['exec', '--full-auto', prompt];
  final out = ValueNotifier<String>('$name 正在处理 $day 的录音…\n');
  if (!ctx.mounted) return;
  showDialog(
    context: ctx,
    builder: (_) => AlertDialog(
      backgroundColor: K.card,
      title: Text('交给 $name'),
      content: SizedBox(
        width: 560,
        child: ValueListenableBuilder(
          valueListenable: out,
          builder: (_, v, _) => SingleChildScrollView(child: SelectableText(v, style: const TextStyle(height: 1.6))),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('关掉'))],
    ),
  );
  final home = Platform.environment['HOME'] ?? '';
  final env = {
    'PATH': '$home/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${Platform.environment['PATH'] ?? ''}',
  };
  try {
    final r = await Process.run(exe, args, workingDirectory: f.parent.path, environment: env);
    out.value = '${(r.stdout as String).trim()}\n${(r.stderr as String).trim()}'.trim();
    if (out.value.isEmpty) out.value = '做完了（退出码 ${r.exitCode}）';
  } catch (e) {
    out.value = '没跑起来：$e';
  }
}
