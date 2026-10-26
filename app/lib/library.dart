// 资料文件夹：整理好的东西都是普通文件，放在用户自己的设备上，不开 App 也能看、也能交给任何 AI / agent。
//   每日/2026-10-18.md                    这天的时间线（每段：钟点 · 类别 · 标题 · 事件）
//   会议纪要/2026-10-18 14.00 标题.md       按类别分文件夹，一段一个笔记（时间地点人物事件 + 按模板整理 + 逐字稿）
//   现场调研/按对象/某某公司.md              同一个调研对象的历次记录都追加在这（下次调研同一对象时当背景）
//   个人感悟/观点库.md                       历次感悟里的观点和演讲素材汇在一起（准备演讲时翻这一份）
//   个人感悟/观点·按主题.md                   观点库按主题归并后的版本（点「按主题整理观点库」重新生成，整份覆盖）
//   每周/2026-W42 (2026-10-12–2026-10-18).md  每周回顾（打开那一周时点按钮生成）
//   逐字稿/<录音>.md                       整条录音的全文
//   录音/<录音>.m4a                        播放用
//   模板/<类别>.md                         各类别的整理方式，可以直接改
//   模板/一键按钮.md、模板/我的写作风格.md     「拿去用」按钮的要求、让小耳写东西时照着的口吻
//   模板/常用词.md                         常提到的人名 / 品牌 / 专有名词，整理时照它纠正转写里的错字
//   成稿/2026-10-19 14.05 标题.md           对话里小耳写好、点了「存成稿」的东西
//   .xiaoer/<录音>.json                    App 用的索引（删了 App 里就看不到那条，但上面的文件还在）
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'store.dart';
import 'templates.dart';

class Library {
  Directory root;
  Library(this.root);

  static Future<Directory> defaultDir() async {
    if (Platform.isMacOS) return Directory('${Platform.environment['HOME']}/Documents/小耳录音卡');
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory(); // Android/data/<包名>/files：不用申请权限，连电脑能看到
      if (ext != null) return Directory('${ext.path}/小耳录音卡');
    }
    return Directory('${(await getApplicationDocumentsDirectory()).path}/小耳录音卡');
  }

  String get path => root.path;
  File data(String stem) => File('$path/.xiaoer/$stem.json');
  File audio(String stem) => File('$path/录音/$stem.m4a');
  File transcript(String stem) => File('$path/逐字稿/$stem.md');
  File templateFile(String cat) => File('$path/模板/$cat.md');
  Directory get subjectsDir => Directory('$path/现场调研/按对象');
  File subjectFile(String s) => File('${subjectsDir.path}/${safe(s)}.md');
  File get ideasFile => File('$path/个人感悟/观点库.md');
  File get ideasTopicFile => File('$path/个人感悟/观点·按主题.md');
  Directory get weeksDir => Directory('$path/每周');
  File get quickActionsFile => File('$path/模板/一键按钮.md');
  File get styleFile => File('$path/模板/我的写作风格.md');
  File get vocabFile => File('$path/模板/常用词.md');
  File get polishFile => File('$path/模板/会议笔记·顺一下.md');
  Directory get liveDir => Directory('$path/现场会议');

  Future<void> ensure() async {
    for (final d in ['.xiaoer', '录音', '逐字稿', '每日', '每周', '模板', '成稿']) {
      await Directory('$path/$d').create(recursive: true);
    }
    // 读不出来的（文稿开了 iCloud、被挪到云上了）先不管：读失败就当用户改过，不覆盖
    Future<String?> read(File f) async {
      try {
        return (await f.readAsString()).trim();
      } catch (_) {
        return null;
      }
    }

    for (final e in defaultTemplates.entries) {
      final f = templateFile(e.key);
      if (!await f.exists() || (legacyTemplates[e.key] ?? const []).contains(await read(f))) {
        await f.writeAsString('${e.value}\n');
      }
    }
    if (!await quickActionsFile.exists()) await quickActionsFile.writeAsString(quickActionsMd(quickActions));
    if (!await styleFile.exists()) await styleFile.writeAsString(defaultStyle);
    if (!await vocabFile.exists()) await vocabFile.writeAsString(defaultVocab);
    if (!await polishFile.exists() || legacyPolish.map((x) => x.trim()).contains(await read(polishFile))) {
      await polishFile.writeAsString(defaultPolish); // 没改过的旧默认换成新的
    }
    final readme = File('$path/说明.md');
    if (!await readme.exists()) {
      await readme.writeAsString('''# 小耳录音卡 · 资料文件夹

这里是你录音卡整理出来的全部内容，都是普通文件，只存在这台设备上（录音卡同步完可以删，云端转写完就删）。
不开 App 也能看；也可以把整个文件夹交给任何 AI / agent。

- 每日/：每天的时间线
- 会议纪要/、我的分享/、商务洽谈/、现场调研/、听课讲座/、多人群聊/ …：按类别分好的笔记
- 现场调研/按对象/：同一个调研对象的历次记录
- 个人感悟/观点库.md：平时说出来的感悟、判断、演讲素材汇在一起，准备演讲时翻这一份；观点·按主题.md 是按主题归并过的
- 每周/：每周回顾（推进了什么、答应了谁什么、下周要盯的）
- 逐字稿/、录音/：全文和原声
- 模板/：每一类怎么整理。直接改这些 .md，下次整理就按你改过的来
- 模板/一键按钮.md：每一类下面「拿去用」按钮让小耳写什么；模板/我的写作风格.md：让小耳写文章、朋友圈时照着的口吻
- 模板/常用词.md：你常提到的人名、品牌、专有名词，整理时照它把转写里听错的字改回来
- 模板/会议笔记·顺一下.md：现场会议里「顺一下」怎么帮你理笔记
- 现场会议/：现场会议里你自己记的笔记（原话全文在 逐字稿/）
- 成稿/：在对话里让小耳写好的文章、朋友圈、纪要消息，点「存成稿」存在这
- 给AI的接口.md：别的 AI / 脚本 / Obsidian 怎么读这里、怎么让小耳改记录
''');
    }
    // App 维护的说明：每次打开都按当前版本写（别手改，改了会被换回来）
    final api = File('$path/给AI的接口.md');
    try {
      if (!await api.exists() || await api.readAsString() != aiInterfaceMd) await api.writeAsString(aiInterfaceMd);
    } catch (_) {} // 被 iCloud 挪到云上了读不出：下次再说
  }

  Future<String> template(String cat) async {
    final f = templateFile(cat);
    if (await f.exists()) return (await f.readAsString()).trim();
    return defaultTemplates[cat] ?? defaultTemplates['自言自语']!;
  }

  (int, Map<String, List<(String, String)>>)? _qa;

  /// 一键按钮表：模板/一键按钮.md 认得出就用它，否则用默认表。按文件修改时间缓存，外面改了下次就生效。
  Map<String, List<(String, String)>> quickActionsTable() {
    final f = quickActionsFile;
    try {
      if (!f.existsSync()) return quickActions;
      final t = f.lastModifiedSync().millisecondsSinceEpoch;
      if (_qa?.$1 != t) _qa = (t, parseQuickActions(f.readAsStringSync()) ?? quickActions);
      return _qa!.$2;
    } catch (_) {
      return quickActions;
    }
  }

  /// 我的写作风格（去掉说明后的内容；没写就是空）。
  String writingStyle() {
    try {
      return styleFile.existsSync() ? cleanStyle(styleFile.readAsStringSync()) : '';
    } catch (_) {
      return '';
    }
  }

  /// 常用词（去掉说明后的内容；没写就是空）。
  String vocab() {
    try {
      return vocabFile.existsSync() ? cleanVocab(vocabFile.readAsStringSync()) : '';
    } catch (_) {
      return '';
    }
  }

  /// 词库（模板/常用词.md）里的词：现场会议出字时替换、「词库」窗口里编辑。
  List<VocabEntry> vocabEntries() {
    try {
      return vocabFile.existsSync() ? parseVocab(vocabFile.readAsStringSync()).$1 : [];
    } catch (_) {
      return [];
    }
  }

  /// 存词库：只换掉「- 词」那些行，文件里别的正文原样留着。
  Future<void> saveVocab(List<VocabEntry> entries) async {
    final extra = await vocabFile.exists() ? parseVocab(await vocabFile.readAsString()).$2 : <String>[];
    await vocabFile.writeAsString(vocabMd(entries, extra));
  }

  /// 「顺一下」的要求（模板文件改坏了 / 删光了就用默认的）。
  String polishPrompt() {
    try {
      final t = polishFile.existsSync() ? cleanPolish(polishFile.readAsStringSync()) : '';
      return t.isEmpty ? cleanPolish(defaultPolish) : t;
    } catch (_) {
      return cleanPolish(defaultPolish);
    }
  }

  /// 现场会议我记的笔记：现场会议/<日期 时分> <标题>.md（全文逐字稿在 逐字稿/<录音>.md）。
  Future<void> writeLiveNotes(String stem, String title, DateTime start, String notes) async {
    await liveDir.create(recursive: true);
    final f = File('${liveDir.path}/${_day(start)} ${_hm(start, '')} ${safe(title)}.md');
    await f.writeAsString([
      '# $title',
      '',
      '时间：${_day(start)} ${_hm(start)}　·　来源：现场会议　·　逐字稿：逐字稿/$stem.md',
      '',
      '## 我的笔记',
      '',
      notes.isEmpty ? '（这场会没有记笔记）' : notes,
      '',
    ].join('\n'));
  }

  Future<List<String>> subjects() async {
    if (!await subjectsDir.exists()) return [];
    return [
      for (final f in subjectsDir.listSync().whereType<File>())
        if (f.path.endsWith('.md')) f.uri.pathSegments.last.replaceAll(RegExp(r'\.md$'), ''),
    ]..sort();
  }

  /// 以前对这个对象的调研（取最近的一截，当背景喂给模型）。
  Future<String> subjectHistory(String subject, {String? except, int max = 8000}) async {
    final f = subjectFile(subject);
    if (subject.isEmpty || !await f.exists()) return '';
    var t = await f.readAsString();
    if (except != null) t = t.replaceAll(RegExp('<!-- $except -->[\\s\\S]*?<!-- /$except -->'), '');
    if (!t.contains('<!-- ')) return ''; // 只剩文件开头，没有别的调研
    return t.length > max ? t.substring(t.length - max) : t;
  }

  Future<void> writeTranscript(String stem, String start, List<List<String>> lines) async {
    await transcript(stem).writeAsString([
      '# $stem 逐字稿',
      '',
      if (start.isNotEmpty) '开录：${start.substring(0, 16).replaceAll('T', ' ')}',
      '',
      for (final l in lines) '**[${l[0]}]** ${l[1]}  ',
    ].join('\n'));
  }

  /// 一段的笔记文件（换了标题 / 类别就把旧文件删掉）。返回新文件路径。
  Future<String> writeNote(Scene s) async {
    final old = s.d['file'] as String?;
    final f = File('$path/${noteRel(s)}');
    if (old != null && old != f.path) {
      final o = File(old);
      if (await o.exists()) await o.delete();
    }
    await f.parent.create(recursive: true);
    await f.writeAsString(noteMd(s));
    s.d['file'] = f.path;
    if (catKey(s.category) == '现场调研' && s.subject.isNotEmpty) await _appendSubject(s);
    if (catKey(s.category) == '个人感悟' && s.body.isNotEmpty) await _appendIdeas(s);
    return f.path;
  }

  /// 一段的笔记在资料文件夹里的相对路径。
  static String noteRel(Scene s) => '${catFolder(s.category)}/${_day(s.start)} ${_hm(s.start, '.')} ${safe(s.title)}.md';

  /// 这一段不再算「现场调研 · [subject]」或「个人感悟」了：从调研对象文件 / 观点库里拿掉它那块。
  Future<void> forget(String id, {String subject = '', bool ideas = false}) async {
    for (final f in [if (subject.isNotEmpty) subjectFile(subject), if (ideas) ideasFile]) {
      if (!await f.exists()) continue;
      final t = await f.readAsString();
      final out = t.replaceAll(RegExp('\\n*<!-- ${RegExp.escape(id)} -->[\\s\\S]*?<!-- /${RegExp.escape(id)} -->\\n?'), '\n');
      if (out != t) await f.writeAsString('${out.trimRight()}\n');
    }
  }

  Future<void> _appendSubject(Scene s) async {
    final f = subjectFile(s.subject);
    await f.parent.create(recursive: true);
    var t = await f.exists() ? await f.readAsString() : '# 调研对象：${s.subject}\n\n同一个对象的历次调研，新的在后面。\n';
    final block = '<!-- ${s.id} -->\n## ${_day(s.start)} ${_hm(s.start)} ${s.title}\n\n${s.event}\n\n${s.body}\n<!-- /${s.id} -->';
    final re = RegExp('<!-- ${s.id} -->[\\s\\S]*?<!-- /${s.id} -->');
    t = re.hasMatch(t) ? t.replaceFirst(re, block) : '${t.trimRight()}\n\n$block\n';
    await f.writeAsString(t);
  }

  /// 观点库：每次感悟只收「感悟了什么」「对未来的判断」「演讲素材」三节（没有就收全文），按 id 覆盖。
  Future<void> _appendIdeas(Scene s) async {
    final f = ideasFile;
    await f.parent.create(recursive: true);
    var t = await f.exists() ? await f.readAsString() : '# 观点库\n\n平时说出来的感悟、对未来的判断、能拿去演讲的素材，新的在后面。\n';
    final keep = [
      for (final sec in s.body.split(RegExp(r'^## ', multiLine: true)))
        if (const ['感悟了什么', '对未来的判断', '演讲素材'].contains(sec.split('\n').first.trim())) '### ${sec.trim()}',
    ];
    final body = keep.isEmpty ? s.body.replaceAll(RegExp(r'^## ', multiLine: true), '### ') : keep.join('\n\n');
    final place = s.place.isEmpty ? '' : ' · ${s.place}';
    final block = '<!-- ${s.id} -->\n## ${_day(s.start)} ${_hm(s.start)}$place · ${s.title}\n\n$body\n<!-- /${s.id} -->';
    final re = RegExp('<!-- ${s.id} -->[\\s\\S]*?<!-- /${s.id} -->');
    t = re.hasMatch(t) ? t.replaceFirst(re, block) : '${t.trimRight()}\n\n$block\n';
    await f.writeAsString(t);
  }

  Future<void> writeDay(String day, List<Scene> scenes) async {
    final b = StringBuffer('# $day\n\n');
    for (final s in scenes) {
      // 索引里记的是绝对路径；资料文件夹换过地方（搬到别的文件夹、从电脑拷到手机）后它指着旧位置，
      // 拿来截相对路径会截错甚至越界，所以按这一段现在该在的位置算。
      final link = s.d['file'] == null ? '' : '（[笔记](<../${noteRel(s)}>)）';
      b.writeln('- **${_hm(s.start)}–${_hm(s.end)}** [${catKey(s.category)}] ${s.title}$link');
      if (s.event.isNotEmpty) b.writeln('  ${s.event}');
      for (final t in [...s.actions, ...s.reminders]) {
        b.writeln('  - [${t['done'] == true ? 'x' : ' '}] ${t['text']}${(t['when'] ?? '').toString().isNotEmpty ? '（${t['when']}）' : ''}');
      }
    }
    await File('$path/每日/$day.md').writeAsString(b.toString());
  }

  static String safe(String s) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '').trim();
    return t.isEmpty ? '未命名' : (t.length > 40 ? t.substring(0, 40) : t);
  }
}

/// 录音里的位置：秒 → 1:02:03 / 2:03。
String clockOf(double sec) {
  final s = sec.round(), h = s ~/ 3600, m = s % 3600 ~/ 60, x = s % 60;
  return h > 0 ? '$h:${_pad(m)}:${_pad(x)}' : '$m:${_pad(x)}';
}

String _day(DateTime t) => '${t.year}-${_pad(t.month)}-${_pad(t.day)}';
String _hm(DateTime t, [String sep = ':']) => '${_pad(t.hour)}$sep${_pad(t.minute)}';
String _pad(int n) => n.toString().padLeft(2, '0');

/// 一段 → 独立的 Markdown 笔记。
String noteMd(Scene s) {
  final mins = s.end.difference(s.start).inMinutes;
  // 开头的属性（YAML）：Obsidian 显示成「属性」能筛能搜；id 给别的 AI / 脚本发修改命令用（见 给AI的接口.md）
  String y(String v) => '"${v.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
  final b = StringBuffer('---\n')
    ..writeln('id: ${y(s.id)}')
    ..writeln('类别: ${y(catKey(s.category))}')
    ..writeln('来源: ${y(sourceOf(s.stem))}')
    ..writeln('日期: ${_day(s.start)}')
    ..writeln('时间: ${y('${_hm(s.start)}–${_hm(s.end)}')}');
  if (s.place.isNotEmpty) b.writeln('地点: ${y(s.place)}');
  if (s.people.isNotEmpty) b.writeln('人物: [${s.people.map(y).join(', ')}]');
  if (s.subject.isNotEmpty) b.writeln('调研对象: ${y(s.subject)}');
  b
    ..writeln('录音: ${y('录音/${s.stem}.m4a')}')
    ..writeln('tags: [小耳录音卡, ${y(catKey(s.category))}]')
    ..writeln('---\n')
    ..write('# ${s.title}\n\n');
  b.writeln('- **时间**：${_day(s.start)} ${_hm(s.start)}–${_hm(s.end)}（${mins < 1 ? '不到 1' : mins} 分钟）');
  if (s.place.isNotEmpty) b.writeln('- **地点**：${s.place}');
  if (s.people.isNotEmpty) b.writeln('- **人物**：${s.people.join('、')}');
  b.writeln('- **类别**：${catKey(s.category)}');
  b.writeln('- **来源**：${sourceOf(s.stem)}');
  if (s.subject.isNotEmpty) b.writeln('- **调研对象**：${s.subject}');
  b.writeln('- **事件**：${s.event}');
  b.writeln('- **录音**：录音/${s.stem}.m4a，从 ${clockOf(s.offset)} 开始');
  b.writeln();
  final body = s.body.isNotEmpty ? s.body : legacyBody(s);
  if (body.isNotEmpty) b.writeln('$body\n');
  if (s.text.isNotEmpty) {
    b.writeln('## 逐字稿\n');
    for (final l in s.text) {
      b.writeln('**[${l[0]}]** ${l[1]}  ');
    }
  }
  return b.toString();
}

/// 旧版本（还没按类别整理）的场景：用原来的几项拼一份。
String legacyBody(Scene s) {
  final b = StringBuffer();
  void list(String head, Iterable<String> xs) {
    if (xs.isEmpty) return;
    b.writeln('## $head\n');
    for (final x in xs) {
      b.writeln('- $x');
    }
    b.writeln();
  }

  if (s.minutesMd.isNotEmpty) b.writeln('${s.minutesMd.replaceAllMapped(RegExp(r'^(#+) ', multiLine: true), (m) => '#${m[1]} ')}\n');
  list('核心观点', s.views);
  list('有价值的内容', s.valuable);
  list('值得记住的', s.memorable.map((m) => '「${m['text']}」'));
  list('下一步行动', s.actions.map((a) => '${a['text']}${(a['who'] ?? '') != '' ? '（${a['who']}）' : ''}'));
  list('提醒事项', s.reminders.map((r) => '${r['text']}${(r['when'] ?? '') != '' ? '（${r['when']}）' : ''}'));
  return b.toString().trim();
}

/// 旧版 App 的数据（应用支持目录里的 result/、audio/）搬进资料文件夹。
Future<void> migrateOld(Directory old, Library lib) async {
  for (final (from, to) in [('result', '.xiaoer'), ('audio', '录音')]) {
    final d = Directory('${old.path}/$from');
    if (!await d.exists()) continue;
    for (final f in d.listSync().whereType<File>()) {
      final dest = File('${lib.path}/$to/${f.uri.pathSegments.last}');
      if (!await dest.exists()) await f.copy(dest.path);
      await f.delete();
    }
  }
}

String prettyJson(Object o) => const JsonEncoder.withIndent(' ').convert(o);

/// 资料文件夹里的「给AI的接口.md」：告诉别的 AI / 脚本 / Obsidian 这里怎么组织、怎么让小耳改记录。
const aiInterfaceMd = r'''# 小耳录音卡 · 给 AI 和别的程序的接口

（这份由小耳录音卡 App 维护，每次打开 App 按最新版本重写，别手改。）

这个文件夹就是小耳录音卡的全部资料，都是普通的 Markdown / JSON 文件。任何 AI（Claude Code、Codex、ChatGPT 桌面版…）、
脚本、Obsidian 都可以直接读；要**改**记录（类别、标题、人物…），按下面的「改记录」放一个命令文件，App 会照着改。

## 用 Obsidian 打开

Obsidian →「打开文件夹作为仓库」→ 选这个文件夹就行。每篇笔记开头有「属性」：
`id`（这一段的编号，改记录时用）、`类别`、`来源`（录音卡 / 录音豆 / 现场会议 / 小耳语音）、`日期`、`时间`、`地点`、`人物`、`录音`、`tags`。
可以按属性筛选、搜索、建视图。

注意：笔记是 App 按「索引」生成的。直接在 Obsidian 里改正文可以，但这一段以后被重新整理（比如改了类别）时会按索引重写，
你的手改会被覆盖。**要改类别、标题、人物这些，请用下面的命令**，App 会连索引、笔记、每日时间线一起改好。

## 文件夹里有什么

- `<类别文件夹>/<日期 钟点> <标题>.md`：每一段的笔记（会议纪要/、听课讲座/、个人感悟/、自言自语/ …）
- `每日/<日期>.md`：一天的时间线；`每周/`：每周回顾
- `逐字稿/<录音>.md`：一条录音的全文；`录音/<录音>.m4a`：原声
- `.xiaoer/<录音>.json`：索引（App 用的，里面 scenes 是这条录音切出来的各段，含 id、类别、标题、笔记、待办）。**只读，别直接改**
- `模板/`：每一类怎么整理，可以改

## 改记录：往 `.xiaoer/commands/` 放一个 .json

文件名随意（按名字顺序执行，比如 `20261025-001.json`），内容是一条操作，或者一个操作数组。App 开着的话 30 秒内照着改，
改完把原文件挪到 `.xiaoer/commands/done/`，旁边写 `<同名>.result.json`：每条 `{"ok": true/false, "message": "改了什么 / 为什么没改成"}`。

`id` 用笔记开头属性里的 `id`（或索引 scenes 里的 id）。能做的：

```json
{"op": "category", "id": "段的id", "to": "听课讲座"}
{"op": "edit", "id": "段的id", "title": "新标题", "event": "一句话事件", "place": "地点", "people": ["张三", "李四"]}
{"op": "noise", "id": "段的id"}
{"op": "merge", "id": "段的id"}
{"op": "todo", "id": "段的id", "index": 0, "done": true}
```

- `category`：改类别。类别只能是：开会、我的分享、商务洽谈、现场调研、听课讲座、多人群聊、打电话、个人感悟、自言自语、生活日常、杂音。
  改成「现场调研」可以带 `"subject": "调研对象"`。改完 App 会按新类别的模板重新整理这段笔记（要几十秒，用 App 里设好的模型）。
- `edit`：改标题 / 事件 / 地点 / 人物，只写要改的几项。
- `noise`：标成杂音，不再显示。`merge`：跟同一条录音里的上一段合成一段（重新整理）。
- `todo`：第几条待办打勾（从 0 数，`"done": false` 取消；提醒加 `"kind": "reminders"`）。

## 换大模型（整理录音、问问小耳用的）

小耳默认用的是小耳云端提供的体验额度（每天有限）。建议换成你自己的：在 App「设置 → 整理用的模型」里填，
或者让你的 AI 往 `.xiaoer/commands/` 放一个命令（OpenAI 兼容的接口都行，DeepSeek、通义千问、Kimi、智谱、OpenAI…）：

```json
{"op": "model", "provider": "DeepSeek", "base": "https://api.deepseek.com/v1", "model": "deepseek-chat", "key": "sk-…"}
```

App 收到就改用这个模型，并把命令文件里的 key 抹掉（结果里显示「已抹掉」）。key 只存在这台电脑的 App 设置里，不经过小耳的服务器。

## 放一条录音进来

往 `.xiaoer/inbox/` 放 `<名字>.json`（`{"start": "2026-10-25T14:00:00", "lines": [["14:00:05", "说的话"], …]}`，写完再改名成 .json）
和同名的 `.m4a`（原声，可以没有）。App 收进来，跟录音卡上的一样切场景、按类别整理。
''';
