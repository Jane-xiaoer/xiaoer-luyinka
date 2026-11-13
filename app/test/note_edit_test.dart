// 现场会议「我的笔记」像备忘录：回车接着列表、空条结束、点框打勾、Tab 缩进、工具按钮。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/note_edit.dart';

TextEditingValue v(String t, [int? at]) => TextEditingValue(text: t, selection: TextSelection.collapsed(offset: at ?? t.length));

/// 在光标处打一个字
TextEditingValue type(TextEditingValue old, String ch) {
  final o = old.selection.baseOffset;
  return v(old.text.replaceRange(o, o, ch), o + 1);
}

void main() {
  group('回车', () {
    test('待办接着出 ☐，勾掉的那条后面也出空框', () {
      expect(afterTyping(v('☐ 发报价'), type(v('☐ 发报价'), '\n'))!.text, '☐ 发报价\n☐ ');
      expect(afterTyping(v('☑ 约时间'), type(v('☑ 约时间'), '\n'))!.text, '☑ 约时间\n☐ ');
    });
    test('要点、编号接着出，编号加一，缩进跟着', () {
      expect(afterTyping(v('· 渠道'), type(v('· 渠道'), '\n'))!.text, '· 渠道\n· ');
      final r = afterTyping(v('1. 甲\n    2. 乙'), type(v('1. 甲\n    2. 乙'), '\n'))!;
      expect(r.text, '1. 甲\n    2. 乙\n    3. ');
      expect(r.selection.baseOffset, r.text.length);
    });
    test('空的一条再回车：顶格就结束列表，缩进的先退一级', () {
      final a = afterTyping(v('☐ 甲\n☐ '), type(v('☐ 甲\n☐ '), '\n'))!;
      expect(a.text, '☐ 甲\n');
      expect(a.selection.baseOffset, 4);
      expect(afterTyping(v('· 甲\n    · '), type(v('· 甲\n    · '), '\n'))!.text, '· 甲\n· ');
    });
    test('普通行回车、粘贴、输入法组字时不动', () {
      expect(afterTyping(v('随便写'), type(v('随便写'), '\n')), isNull);
      expect(afterTyping(v('☐ 甲'), v('☐ 甲\n粘贴的\n')), isNull);
      final composing = type(v('☐ 甲'), '\n').copyWith(composing: const TextRange(start: 0, end: 1));
      expect(afterTyping(v('☐ 甲'), composing), isNull);
    });
    test('在一条中间回车：后半截成新的一条', () {
      final old = v('☐ 发报价给王总', 5);
      expect(afterTyping(old, type(old, '\n'))!.text, '☐ 发报价\n☐ 给王总');
    });
  });

  test('行首打「- 」「[] 」自动变成列表', () {
    expect(afterTyping(v('-'), type(v('-'), ' '))!.text, '· ');
    expect(afterTyping(v('甲\n  []'), type(v('甲\n  []'), ' '))!.text, '甲\n  ☐ ');
    expect(afterTyping(v('a-'), type(v('a-'), ' ')), isNull);
  });

  test('点框打勾 / 取消，点正文不勾', () {
    expect(toggleAtTap(v('甲\n☐ 发报价', 3))!.text, '甲\n☑ 发报价');
    expect(toggleAtTap(v('    ☑ 发报价', 5))!.text, '    ☐ 发报价');
    expect(toggleAtTap(v('☐ 发报价', 4)), isNull);
    expect(toggleAtTap(v('· 要点', 0)), isNull);
  });

  test('工具按钮：选中几行一起变，再按一次去掉；编号 1 2 3', () {
    final sel = TextEditingValue(text: '甲\n乙\n丙', selection: const TextSelection(baseOffset: 0, extentOffset: 5));
    expect(setKind(sel, NoteKind.number).text, '1. 甲\n2. 乙\n3. 丙');
    expect(setKind(sel, NoteKind.todo).text, '☐ 甲\n☐ 乙\n☐ 丙');
    final todos = TextEditingValue(text: '☐ 甲\n☑ 乙', selection: const TextSelection(baseOffset: 0, extentOffset: 6));
    expect(setKind(todos, NoteKind.todo).text, '甲\n乙');
    expect(setKind(v('· 甲', 1), NoteKind.todo).text, '☐ 甲');
  });

  test('Tab 缩进 / Shift+Tab 退回', () {
    expect(indent(v('☐ 甲', 2)).text, '    ☐ 甲');
    expect(indent(v('    ☐ 甲', 6), back: true).text, '☐ 甲');
    expect(indent(v('☐ 甲', 2), back: true).text, '☐ 甲');
  });

  test('标题 ⇧⌘T / 小标题 ⇧⌘H：换掉列表符号，再按一次变回正文', () {
    expect(toggleHeading(v('☐ 脚本', 2), 1).text, '# 脚本');
    expect(toggleHeading(v('# 脚本', 2), 1).text, '脚本');
    expect(toggleHeading(v('# 脚本', 2), 2).text, '## 脚本');
    final sel = TextEditingValue(text: '甲\n乙', selection: const TextSelection(baseOffset: 0, extentOffset: 3));
    expect(toggleHeading(sel, 2).text, '## 甲\n## 乙');
  });

  test('加粗 ⌘B / 重点 ⇧⌘E：包上、再按去掉；没选字放一对光标在中间', () {
    final sel = TextEditingValue(text: '先做华东', selection: const TextSelection(baseOffset: 2, extentOffset: 4));
    final b = toggleWrap(sel, '**');
    expect(b.text, '先做**华东**');
    expect(b.selection.textInside(b.text), '华东');
    expect(toggleWrap(b, '**').text, '先做华东');
    final all = TextEditingValue(text: '==重点==', selection: const TextSelection(baseOffset: 0, extentOffset: 6));
    expect(toggleWrap(all, '==').text, '重点');
    final e = toggleWrap(v('甲', 1), '==');
    expect(e.text, '甲====');
    expect(e.selection.baseOffset, 3);
  });

  test('找字：从光标往后找，到底了从头来', () {
    expect(findNext('华东 华南 华东', '华东', 1)!.baseOffset, 6);
    expect(findNext('华东 华南 华东', '华东', 7)!.baseOffset, 0);
    expect(findNext('华东', '西北', 0), isNull);
  });

  test('打 @ 选人：认出正在打的名字，换成「名字：」（一条开头）或「名字 」（句中）；按名字 / 叫法 / 公司找', () {
    expect(mentionAt(v('☐ @雨')), (2, '雨'));
    expect(mentionAt(v('邮箱 a@b.com 已发')), isNull);
    expect(insertMention(v('☐ @雨'), 2, '林夏').text, '☐ 林夏：');
    expect(insertMention(v('跟 @雨'), 2, '林夏').text, '跟 林夏 ');
    final roster = [('林夏', ['林下'], '青禾'), ('周总周宁', ['周总'], '青禾'), ('明川', <String>[], '明川生物')];
    expect(matchPeople(roster, '下'), ['林夏']);
    expect(matchPeople(roster, '青禾'), ['林夏', '周总周宁']);
    expect(matchPeople(roster, '周'), ['周总周宁']);
  });

  test('⌃⌘↑↓ 挪行：整行换位置，光标跟着', () {
    final up = moveLines(v('甲\n乙\n丙', 3), up: true);
    expect(up.text, '乙\n甲\n丙');
    expect(up.selection.baseOffset, 1);
    expect(moveLines(v('甲\n乙\n丙', 0), up: false).text, '乙\n甲\n丙');
    expect(moveLines(v('甲\n乙', 0), up: true).text, '甲\n乙');
  });

  test('输入法组字时照上样式（标题字号不跳），只在组字那截加下划线', () {
    final c = NotesController(text: '# 脚本ji');
    c.value = c.value.copyWith(composing: const TextRange(start: 4, end: 6));
    final span = c.buildTextSpan(context: _FakeContext(), style: const TextStyle(fontSize: 15), withComposing: true);
    final parts = <TextSpan>[];
    span.visitChildren((s) {
      if (s is TextSpan && s.text != null) parts.add(s);
      return true;
    });
    final ji = parts.firstWhere((p) => p.text == 'ji');
    expect(ji.style!.decoration, TextDecoration.underline);
    expect(ji.style!.fontSize, greaterThan(15)); // 还是标题的大字
    expect(parts.firstWhere((p) => p.text == '脚本').style!.decoration, isNot(TextDecoration.underline));
  });

  testWidgets('真打字：回车接着待办，点框打勾，Tab 不跳走', (tester) async {
    final c = NotesController();
    final f = FocusNode();
    final saved = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NotesEditor(controller: c, focusNode: f, hint: '', onChanged: saved.add)),
    ));
    await tester.tap(find.byTooltip('待办清单  ⇧⌘L（点框打勾）'));
    await tester.pump();
    expect(c.text, '☐ ');
    await tester.enterText(find.byType(TextField), '☐ 发报价');
    await tester.pump();
    tester.testTextInput.updateEditingValue(v('☐ 发报价\n'));
    await tester.pump();
    expect(c.text, '☐ 发报价\n☐ ');
    expect(saved.last, '☐ 发报价\n☐ ');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(c.text, '☐ 发报价\n    ☐ ');
    expect(f.hasFocus, isTrue);

    // 真点第一行的圆圈：勾上、变成 ☑；再点一下取消
    await tester.tap(find.byIcon(Icons.radio_button_unchecked_rounded).first);
    await tester.pump();
    expect(c.text, '☑ 发报价\n    ☐ ');
    expect(saved.last, '☑ 发报价\n    ☐ ');
    await tester.tap(find.byIcon(Icons.check_circle_rounded));
    await tester.pump();
    expect(c.text, '☐ 发报价\n    ☐ ');
  });
}

class _FakeContext extends Fake implements BuildContext {}
