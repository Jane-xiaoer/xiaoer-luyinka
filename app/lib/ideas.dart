// 观点按主题归类：个人感悟/观点库.md 是按时间追加的；这里让模型按主题归并一份，
// 存成 个人感悟/观点·按主题.md（整份覆盖，开头写生成时间）。
import 'dart:io';

import 'analyze.dart';
import 'library.dart';
import 'theme.dart' show hm;

const ideasMax = 60000; // 观点库太长只给最近这么多字

const ideasTopicPrompt = '''你在帮我把「观点库」按主题整理。资料是我观点库的原文：每块以「## 日期 钟点 · 标题」开头，下面是那次说出来的感悟、对未来的判断、演讲素材。
输出 Markdown：
- 按主题分组，一共 3–10 个主题，主题名你来定（短，一看就知道讲什么）。每个主题用「## 主题名」开头，下面固定三节：
  - 「### 核心观点」：把不同日期里说的同一个观点合并成一条，每条末尾用括号标出处日期，格式如「（10/18、10/20）」，日期取那块标题里的日期，写成 月/日、不补 0。
  - 「### 例子和金句」：我用过的例子、故事、数字，和原话金句（金句用「」括起来，照原话一字不改），每条末尾也标日期。
  - 「### 可以讲成演讲的提纲」：3–5 点，按讲的顺序，每点一句话。
- 放不进任何主题的零散观点，归到最后一个「## 其他」（没有就不写这一节）。
规矩：只用观点库里有的内容，不编观点、例子、数字和原话；某一节没有内容就写「（没有）」。不要开场白和结尾，不要用代码块包起来。''';

/// 交给模型的资料：观点库全文，太长就取最后 [max] 字（从一块的开头切）。
String ideasMaterial(String raw, {int max = ideasMax}) {
  if (raw.length <= max) return raw;
  var cut = raw.substring(raw.length - max);
  final i = cut.indexOf(RegExp(r'^## |^<!-- ', multiLine: true));
  if (i > 0) cut = cut.substring(i);
  return cut;
}

String _p2(int n) => n.toString().padLeft(2, '0');

/// 按主题整理观点库，写进 个人感悟/观点·按主题.md，返回文件。观点库没内容就抛错。
Future<File> generateIdeasTopics(Library lib, Chat chat, {DateTime? now}) async {
  final src = lib.ideasFile;
  final raw = await src.exists() ? (await src.readAsString()).trim() : '';
  if (!raw.contains('<!-- ')) throw StateError('观点库还是空的：先有「个人感悟」类的录音，整理后会自动收进去');
  final material = ideasMaterial(raw);
  final out = await chat(ideasTopicPrompt, material);
  final body = out.replaceAll(RegExp(r'^```(markdown|md)?\s*|\s*```$'), '').trim();
  if (body.isEmpty) throw StateError('模型没回内容');
  final at = now ?? DateTime.now();
  final md = '# 观点 · 按主题\n\n'
      '> 生成时间：${at.year}-${_p2(at.month)}-${_p2(at.day)} ${hm(at)} · 资料：个人感悟/观点库.md'
      '${material.length < raw.length ? '（太长，只用了最近 ${material.length} 字）' : '（全文 ${raw.length} 字）'}\n\n'
      '$body\n';
  final f = lib.ideasTopicFile;
  await f.parent.create(recursive: true);
  await f.writeAsString(md);
  return f;
}
