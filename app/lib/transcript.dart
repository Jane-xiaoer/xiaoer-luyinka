// 逐字稿拼成纯文字：一键拷贝到微信 / 飞书 / 公众号后台用。
import 'store.dart';

String _clock(String t) => t.length == 5 ? '$t:00' : t;

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 一段的逐字稿：一行一句；[times] 为 true 时每行前面带 `[HH:MM:SS] `。空行跳过。
String transcriptText(Scene s, {bool times = false}) => [
      for (final l in s.text)
        if (l.length > 1 && l[1].trim().isNotEmpty) times ? '[${_clock(l[0])}] ${l[1].trim()}' : l[1].trim(),
    ].join('\n');

/// 整条录音（同一个 stem 的所有段）的逐字稿：按开始时间排，每段前面一个小标题「## HH:MM 标题」。没字的段跳过。
String recordingTranscript(List<Scene> scenes, {bool times = false}) {
  final l = [...scenes]..sort((a, b) => a.start.compareTo(b.start));
  return [
    for (final s in l)
      if (transcriptText(s).isNotEmpty) '## ${_hm(s.start)}${s.title.isEmpty ? '' : ' ${s.title}'}\n\n${transcriptText(s, times: times)}',
  ].join('\n\n');
}

/// 字数：不算空白和换行。
int transcriptChars(String t) => t.replaceAll(RegExp(r'\s'), '').runes.length;
