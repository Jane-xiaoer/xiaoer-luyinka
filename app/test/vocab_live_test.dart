// 词库：读写、出字替换、保存时把这场已经出来的原话改对。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/live.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/templates.dart';

void main() {
  test('读：新写法、旧写法（不是）、只有词；说明行和标题不算', () {
    final (es, extra) = parseVocab('# 常用词\n> 说明\n- 品牌机（常被听成 品牌纪、品牌期）\n- 王总（不是 王宗）\n- Omia\n随手记的一行\n');
    expect([for (final e in es) '${e.word}:${e.wrong.join('|')}'], ['品牌机:品牌纪|品牌期', '王总:王宗', 'Omia:']);
    expect(extra, ['随手记的一行']);
  });

  test('写回再读：一样；别的正文原样留着', () {
    final md = vocabMd([const VocabEntry('品牌机', ['品牌纪', '品牌期']), const VocabEntry('Omia')], ['随手记的一行']);
    final (es, extra) = parseVocab(md);
    expect(es.map((e) => '${e.word}:${e.wrong.join('|')}'), ['品牌机:品牌纪|品牌期', 'Omia:']);
    expect(extra, ['随手记的一行']);
  });

  test('替换：长的错词先换', () {
    final es = [const VocabEntry('会议机', ['会议纪', '会议期']), const VocabEntry('品牌机要', ['品牌纪要'])];
    expect(fixWords('做好品牌纪要，然后做会议纪。', es), '做好品牌机要，然后做会议机。');
  });

  test('现场会议：存词库时这场已经出来的原话也改对，存进 模板/常用词.md', () async {
    final tmp = await Directory.systemTemp.createTemp('vocab');
    addTearDown(() => tmp.delete(recursive: true));
    final store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await store.lib.ensure();
    final live = LiveSession(store, Directory('${tmp.path}/app'), () async {}, shareMemory: false);
    live.lines.addAll([LiveLine(DateTime(2026, 10, 24, 15), '先把品牌期做完'), LiveLine(DateTime(2026, 10, 24, 15, 1), '再看课程')]);
    final n = await live.saveVocab([const VocabEntry('品牌机', ['品牌期'])]);
    expect(n, 1);
    expect(live.lines.first.text, '先把品牌机做完');
    expect(store.lib.vocabFile.readAsStringSync(), contains('- 品牌机（常被听成 品牌期）'));
    expect(store.lib.vocab(), contains('品牌机')); // 整理、顺一下也能读到
    live.dispose();
  });
}
