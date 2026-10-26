import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/analyze.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/templates.dart';

final lines = [for (var i = 0; i < 20; i++) ['14:00:${(i * 2).toString().padLeft(2, '0')}', '我们用奥米亚做海报，小二帮我记一下，第$i句']];

void main() {
  late Directory tmp;
  late Library lib;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vocab');
    lib = Library(Directory('${tmp.path}/资料'));
    await lib.ensure();
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<List<String>> run() async {
    final seen = <String>[];
    await Analyzer(lib, (s, u) async {
      seen.add(s);
      if (s.contains('"scenes"')) return '{"scenes":[{"start":"14:00:00","end":"14:00:38","category":"自言自语","title":"做海报"}]}';
      return '## 想法\n- 好';
    }).run('x', {'start': '2026-10-18T14:00:00', 'lines': lines});
    return seen;
  }

  test('默认的常用词文件：写进去了，但只有说明和示例，不进提示词', () async {
    expect(lib.vocabFile.readAsStringSync(), defaultVocab);
    expect(lib.vocab(), '');
    final seen = await run();
    expect(seen.length, 2);
    for (final s in seen) {
      expect(s, isNot(contains('常提到的人名')));
      expect(s, isNot(contains('王宗')));
    }
  });

  test('写了常用词：切场景和写笔记的提示词里都有', () async {
    await lib.vocabFile.writeAsString('$defaultVocab\n- 小耳（不是 小二）\n- Omia（不是 奥米亚）\n');
    expect(lib.vocab(), '- 小耳（不是 小二）\n- Omia（不是 奥米亚）');
    final seen = await run();
    final cut = seen.firstWhere((s) => s.contains('"scenes"'));
    final note = seen.firstWhere((s) => !s.contains('"scenes"'));
    for (final s in [cut, note]) {
      expect(s, contains('常提到的人名 / 品牌 / 专有名词'));
      expect(s, contains('- Omia（不是 奥米亚）'));
      expect(s, isNot(contains('王宗'))); // 说明里的示例不算
    }
    expect(note.indexOf('常提到的人名'), lessThan(note.indexOf('这一类的整理方式')));
  });

  test('常用词最多 3000 字', () {
    expect(cleanVocab('# 常用词\n> 说明\n${'- 很长的词\n' * 1000}').length, 3000);
  });

  test('外面删了常用词文件：下次打开写回默认', () async {
    await lib.vocabFile.delete();
    await lib.ensure();
    expect(lib.vocabFile.readAsStringSync(), defaultVocab);
  });

  test('以前的 模板/常用词.md 搬成资料文件夹最外层的 词汇表.md，词一个不少', () async {
    final tmp = await Directory.systemTemp.createTemp('vocabmove');
    final lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${lib.path}/模板').create(recursive: true);
    await File('${lib.path}/模板/常用词.md').writeAsString('# 常用词\n> 说明\n- 小耳老师（常被听成 小冉老师）\n- Omia\n');
    await lib.ensure();
    expect(File('${lib.path}/模板/常用词.md').existsSync(), isFalse);
    expect(lib.vocabFile.path, endsWith('/资料/词汇表.md'));
    expect(lib.vocabFile.readAsStringSync(), startsWith('# 词汇表'));
    expect(lib.vocabEntries().map((e) => e.word), ['小耳老师', 'Omia']);
    expect(lib.vocabEntries().first.wrong, ['小冉老师']);
    await tmp.delete(recursive: true);
  });
}
