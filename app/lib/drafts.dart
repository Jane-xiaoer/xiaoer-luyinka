// 成稿：对话里小耳写好的东西（公众号文章、朋友圈、纪要消息…）存成资料文件夹里的 成稿/<日期 钟点> <标题>.md。
import 'dart:io';

import 'library.dart';
import 'search.dart';
import 'store.dart';

const draftsKey = '成稿';

/// 成稿的标题：回答里第一个「# 」标题；没有就取我那句要求的前 16 字。
String draftTitle(String answer, String request) {
  final m = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(answer);
  final t = (m?[1] ?? '').replaceAll(RegExp(r'\*\*|__|`'), '').trim();
  if (t.isNotEmpty) return t;
  final q = request.replaceAll(RegExp(r'\s+'), ' ').trim();
  return q.length > 16 ? q.substring(0, 16) : q;
}

String _p2(int n) => n.toString().padLeft(2, '0');
String _stamp(DateTime t, String sep) => '${t.year}-${_p2(t.month)}-${_p2(t.day)} ${_p2(t.hour)}$sep${_p2(t.minute)}';

/// 成稿文件的内容：开头一段引用块（生成时间、我的要求、来源），然后正文。
/// [libPath] 用来把来源笔记的绝对路径换成相对 成稿/ 的链接。
String draftMd({required DateTime at, required String request, required String body, Scene? source, String libPath = ''}) {
  final b = StringBuffer()
    ..writeln('> 生成时间：${_stamp(at, ':')}')
    ..writeln('> 我的要求：${request.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim()}');
  if (source == null) {
    b.writeln('> 来源：（当时没选中具体哪一段）');
  } else {
    final s = source;
    final file = s.d['file'] as String?;
    final rel = file != null && libPath.isNotEmpty && file.startsWith('$libPath/') ? file.substring(libPath.length + 1) : null;
    b.writeln('> 来源：${_stamp(s.start, ':')} · ${s.category} · ${s.title}${rel == null ? '' : ' · [来源](<../$rel>)'}');
  }
  b
    ..writeln()
    ..writeln(body.trim());
  return b.toString();
}

/// 存一份成稿，返回文件。重名加 (2)、(3)…
File saveDraft(Library lib, {required String answer, required String request, Scene? source, DateTime? at}) {
  final now = at ?? DateTime.now();
  final dir = Directory('${lib.path}/$draftsKey')..createSync(recursive: true);
  final base = '${_stamp(now, '.')} ${Library.safe(draftTitle(answer, request))}';
  var f = File('${dir.path}/$base.md');
  for (var i = 2; f.existsSync(); i++) {
    f = File('${dir.path}/$base ($i).md');
  }
  f.writeAsStringSync(draftMd(at: now, request: request, body: answer, source: source, libPath: lib.path));
  return f;
}

class Draft {
  final File file;
  final String when; // 2026-10-19 14:05（文件名里没有就用修改时间）
  final String title;
  final String md;
  const Draft(this.file, this.when, this.title, this.md);
  String get path => file.path;

  /// 正文（去掉开头的元信息引用块）。
  String get body => md.replaceFirst(RegExp(r'^(>.*\n)+\s*'), '');
}

final _name = RegExp(r'^(\d{4}-\d{2}-\d{2}) (\d{2})\.(\d{2}) (.+)$');

/// 成稿/ 里的文件，新的在前。
List<Draft> listDrafts(Library lib) {
  final dir = Directory('${lib.path}/$draftsKey');
  if (!dir.existsSync()) return [];
  final out = <Draft>[];
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.md') || name.startsWith('.')) continue;
    final stem = name.substring(0, name.length - 3);
    final m = _name.firstMatch(stem);
    String md;
    try {
      md = f.readAsStringSync();
    } catch (_) {
      continue;
    }
    out.add(m != null
        ? Draft(f, '${m[1]} ${m[2]}:${m[3]}', m[4]!, md)
        : Draft(f, _stamp(f.lastModifiedSync(), ':'), stem, md));
  }
  out.sort((a, b) => b.when != a.when ? b.when.compareTo(a.when) : b.path.compareTo(a.path));
  return out;
}

class DraftHit {
  final Draft draft;
  final Snippet snippet;
  const DraftHit(this.draft, this.snippet);
}

/// 左栏搜索也搜成稿：标题 + 正文，每个词都要出现。标题命中的在前，同档新的在前（[drafts] 已经是新的在前）。
List<DraftHit> searchDrafts(List<Draft> drafts, String query) {
  final terms = searchTerms(query);
  if (terms.isEmpty) return const [];
  final top = <DraftHit>[], rest = <DraftHit>[];
  for (final d in drafts) {
    final t = fold(d.title), b = fold(d.md);
    if (!terms.every((x) => t.contains(x) || b.contains(x))) continue;
    final inTitle = terms.any(t.contains);
    final plain = d.body.replaceAll(RegExp(r'^\s*#+\s*', multiLine: true), '').replaceAll(RegExp(r'\s*\n\s*'), ' ');
    final show = terms.any(fold(plain).contains) ? plain : d.title;
    (inTitle ? top : rest).add(DraftHit(d, snippetOf(show, terms)));
  }
  return [...top, ...rest];
}
