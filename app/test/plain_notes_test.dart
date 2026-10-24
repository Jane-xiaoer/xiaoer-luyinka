// 「顺一下」的结果不带 Markdown 符号。
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/templates.dart';

void main() {
  test('标题、加粗、列表、代码块围栏都去掉', () {
    expect(plainNotes('```markdown\n## 渠道\n\n**结论**：先做华东\n- 王总：先做华东\n* 我倾向*华南*\n- [ ] 下周给预算\n```'),
        '渠道\n\n结论：先做华东\n· 王总：先做华东\n· 我倾向华南\n· 下周给预算');
  });
  test('数字编号、正常的星号乘法不动', () {
    expect(plainNotes('待办\n1. 王总出预算\n2. 3*4 的表格'), '待办\n1. 王总出预算\n2. 3*4 的表格');
  });
}
