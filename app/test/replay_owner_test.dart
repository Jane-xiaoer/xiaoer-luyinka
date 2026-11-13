// 回放：拿真录音走 App 真实的整理入口（Analyzer.run，按 6000 字分窗切场景、拆事），
// 用 App 设置里同一个模型（DeepSeek）重拆，看「谁说的 / 归谁」对不对。写笔记那一步用假模型跳过，省钱。
// 要真调模型、要读这台 Mac 上的真录音：REPLAY_LLM=1 才跑；key 从 App 的 state.json 读，不打印。
// 次数：REPLAY_RUNS（默认 3）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:luyinka/analyze.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/templates.dart';

final home = Platform.environment['HOME'];
final runs = int.tryParse(Platform.environment['REPLAY_RUNS'] ?? '') ?? 3;
final skip = Platform.environment['REPLAY_LLM'] == '1' ? false : '要 REPLAY_LLM=1';

Future<String> deepseek(String system, String user) async {
  if (system.startsWith(notePreamble)) return ''; // 写笔记那步不测
  final st = jsonDecode(File('$home/Library/Application Support/xyz.xiaoerai.luyinka/luyinka/state.json').readAsStringSync());
  final s = st['settings']['llm'] as Map;
  final r = await http.post(Uri.parse('${s['base']}/chat/completions'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${s['key']}'},
      body: jsonEncode({
        'model': s['model'],
        'temperature': 0.2,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
      }));
  expect(r.statusCode, 200);
  return jsonDecode(utf8.decode(r.bodyBytes))['choices'][0]['message']['content'];
}

/// 整条录音走一遍真实入口，返回所有行动（带所在场景的类别）。
Future<List<Map<String, dynamic>>> rerun(String stem) async {
  final res = jsonDecode(File('$home/Documents/小耳录音卡/.xiaoer/$stem.json').readAsStringSync()) as Map<String, dynamic>;
  final tmp = await Directory.systemTemp.createTemp('replay');
  final scenes = await Analyzer(Library(tmp), deepseek).run(stem, res);
  await tmp.delete(recursive: true);
  return [
    for (final s in scenes)
      for (final a in s['actions'] as List) {...Map<String, dynamic>.from(a), '_cat': s['category']},
  ];
}

void show(List<Map<String, dynamic>> acts) {
  for (final a in acts) {
    print('  ${a['t']} ${a['text']} | 归=${a['who']} | 说话人=${a['speaker']} | ${a['_cat']}');
  }
}

/// 重拆 [per] 次里判对的要够 [min]（默认每次都对）。
void check(String what, List<bool> per, {double min = 1}) {
  final n = per.where((x) => x).length;
  print('$what：$n/${per.length}');
  expect(n, greaterThanOrEqualTo((per.length * min).ceil()), reason: what);
}

void main() {
  test('11-04 现场会议整条重拆：#244 #243 #242 和 22:41 那句', () async {
    final p244 = <bool>[], p243 = <bool>[], p242 = <bool>[], p2241 = <bool>[], pGive = <bool>[];
    var miss242 = 0;
    for (var k = 0; k < runs; k++) {
      print('\n=== 第 ${k + 1} 次 ===');
      final acts = await rerun('live20261104-221342');
      show(acts);
      Iterable<Map<String, dynamic>> hit(bool Function(Map<String, dynamic>) f) => acts.where(f);
      // #244：没认出的人说「我我联系李航」——是他自己去，不归我
      final a244 = hit((a) => '${a['text']}'.contains('李航') && '${a['t']}'.startsWith('23:21'));
      p244.add(a244.isNotEmpty && a244.every((a) => a['who'] != '我'));
      // #243：练说「我先跟那边对接」——归练
      final a243 = hit((a) => '${a['t']}' == '22:58:49');
      p243.add(a243.isNotEmpty && a243.every((a) => a['who'] == '练' && a['speaker'] == '练'));
      // #242：练（甲方）对我们提要求「按案例做一个完整的样板」——归我，说话人练；每次都得拆出来
      final a242 = hit((a) => '${a['text']}'.contains('样板'));
      if (a242.isEmpty) miss242++;
      p242.add(a242.isNotEmpty && a242.every((a) => a['who'] == '我' && a['speaker'] == '练'));
      // 22:41:05 没认出的人说「我们就按你的来」：分不清是不是我这边，不能判成「别人」（拆不拆出来都行）
      p2241.add(hit((a) => '${a['t']}' == '22:41:05').every((a) => a['who'] != '别人'));
      // 22:39:26「素材我们到时都能提供」、22:43:22「肯定要有航拍图」：甲方给资料，不能算成我的（拆不拆出来都行）
      pGive.add(hit((a) => ['22:39:26', '22:43:22'].contains('${a['t']}')).every((a) => a['who'] != '我'));
    }
    check('#244 联系李航 不归我', p244);
    check('#243 对接看板 归练、说话人练', p243);
    // #242 模型本身有波动：2026-11-05 五批各 5 次合计 20/25（2、5、4、5、4）（第一版 358d786 是 8/8），门槛八成
    check('#242 做样板 拆出来、归我、说话人练', p242, min: 0.8);
    print('（#242 漏拆 $miss242/$runs 次）');
    check('22:41:05「我们按你的来」不判成别人', p2241);
    check('22:39:26 / 22:43:22 甲方给资料 不算成我的', pGive);
  }, timeout: const Timeout(Duration(minutes: 20)), skip: skip);

  test('11-05 iPhone 自言自语：我要做的归我，董老师在谈的不归我', () async {
    final perRun = <bool>[];
    for (var k = 0; k < runs; k++) {
      final acts = await rerun('iphone20261105-004909');
      show(acts);
      final mine = acts.where((a) => RegExp(r'脚本|要资料').hasMatch('${a['text']}'));
      final dong = acts.where((a) => '${a['text']}'.contains('下一阶段'));
      perRun.add(mine.isNotEmpty && mine.every((a) => a['who'] == '我') && dong.every((a) => a['who'] != '我'));
    }
    check('自言自语：出脚本 / 要资料归我，谈下一阶段不归我', perRun);
  }, timeout: const Timeout(Duration(minutes: 10)), skip: skip);
}
