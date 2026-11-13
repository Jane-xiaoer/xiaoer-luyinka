// 现场会议：开到一半的会 → 结束收进录音卡（逐字稿、我的笔记、待整理）→ 跟卡上的一样整理；「顺一下」带上原话和笔记。
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/analyze.dart' show Chat;
import 'package:luyinka/cloud.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/live.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

void main() {
  late Directory tmp;
  late Store store;
  late Syncer syncer;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('live');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
    syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai',
        chat: (system, user) async => system.contains('"scenes"')
            ? jsonEncode({'scenes': [{'start': '15:00:00', 'end': '15:01:00', 'category': '开会', 'title': '渠道方案', 'event': '讨论渠道。'}]})
            : '## 纪要\n- 渠道');
  });
  tearDown(() async {
    await store.save();
    await tmp.delete(recursive: true);
  });

  LiveSession meeting({Chat? chat}) {
    final live = LiveSession(store, Directory('${tmp.path}/app'), () async {}, shareMemory: false, chat: chat);
    final t0 = DateTime(2026, 10, 24, 15, 0, 0);
    live
      ..stem = 'live20261024-150000'
      ..started = t0
      ..title = '渠道会'
      ..notes = '王总说先做华东\n我觉得华南更好'
      ..state = LiveState.paused;
    for (var i = 0; i < 20; i++) {
      live.lines.add(LiveLine(t0.add(Duration(seconds: 3 * i)), '我们这个渠道先从华东开始铺，第$i句'));
    }
    return live;
  }

  test('结束：收进录音卡，跟卡上的一样整理', () async {
    final live = meeting();
    final stem = await live.finish();
    expect(stem, 'live20261024-150000');
    expect(live.state, LiveState.idle);
    expect(live.lines, isEmpty);

    final t = await store.lib.transcript(stem!).readAsString();
    expect(t, contains('**[15:00:03]** 我们这个渠道先从华东开始铺，第1句'));
    final notes = File('${store.lib.liveDir.path}/2026-10-24 1500 渠道会.md').readAsStringSync();
    expect(notes, contains('王总说先做华东\n我觉得华南更好'));
    expect(notes, contains('逐字稿/live20261024-150000.md'));

    await syncer.run(fromCard: false);
    expect(store.recs[stem]!.stage, 'done');
    final res = store.readResult(stem)!;
    expect(res['notes'], '王总说先做华东\n我觉得华南更好');
    expect(res['source'], '现场会议');
    expect(res['start'], startsWith('2026-10-24T15:00:00'));
    expect((res['scenes'] as List).single['title'], '渠道方案');
  });

  test('没识别出字也没记笔记：不收，停在暂停', () async {
    final live = meeting()
      ..lines.clear()
      ..notes = '  ';
    expect(await live.finish(), isNull);
    expect(live.state, LiveState.paused);
    expect(store.recs, isEmpty);
  });

  test('没识别出字、只有笔记：收成一段开会，笔记待办马上进（11-13 芯：别逼她点放弃丢笔记）', () async {
    final live = meeting()..lines.clear();
    live.notes = '';
    live.setNotes('青禾脚本会\n☐ 周五前改完旁白\n☑ 发上一版');
    final stem = await live.finish();
    expect(stem, 'live20261024-150000');
    expect(live.lastNotesOnly, isTrue);
    expect(live.noteSummary, contains('2 条已进「待办」'));
    expect(store.recs[stem], isNull); // 不排进整理
    final s = store.scenes.single;
    expect(s.category, '开会');
    expect(s.title, '渠道会');
    expect([for (final a in s.actions) '${a['text']}|${a['done'] == true}|${a['confirmed'] == true}'],
        ['周五前改完旁白|false|true', '发上一版|true|true']);
    expect(File('${store.lib.liveDir.path}/2026-10-24 1500 渠道会.md').readAsStringSync(), contains('- [ ] 周五前改完旁白'));
  });

  test('笔记待办：我打的进待办、挪来的进待确认、名单上的「名字：」归他、整理后还在、模型拆的重复并掉', () async {
    await store.lib.peopleFile.writeAsString('# 人员名单\n\n- 林夏（林下）｜同事｜||\n');
    final live = meeting(chat: null);
    live.notes = '';
    live.setNotes('☐ 周五前改完旁白\n☐ 林下：要素材包\n☐ 预算：50万');
    live.setNotes('${live.notes}\n\n☐ 先从华东开始铺', src: 'clip', at: 3);
    final stem = await live.finish();
    expect(live.noteSummary, contains('3 条整理完进「待办」'));
    expect(live.noteSummary, contains('1 条'));
    await syncer.run(fromCard: false);
    expect(store.recs[stem]!.stage, 'done');
    final acts = store.scenes.single.pairs('actions').where((a) => a['from'] == 'note').toList();
    expect([for (final a in acts) '${a['text']}|${a['who']}|${a['confirmed'] == true}'], [
      '周五前改完旁白|我|true',
      '要素材包|林夏|true',
      '预算：50万|我|true',
      '先从华东开始铺|我|false',
    ]);
  });

  test('顺一下：要求来自模板，原话当背景，笔记是主体', () async {
    String? sys, usr;
    final live = meeting(chat: (s, u) async {
      sys = s;
      usr = u;
      return '```markdown\n## 渠道\n- 王总：先做华东\n- 我倾向华南\n```';
    });
    final out = await live.polish(ask: '最后列待办');
    expect(out, '渠道\n· 王总：先做华东\n· 我倾向华南'); // 默认不要 # - 这些符号
    expect(sys, contains('保留我的倾向'));
    expect(sys, contains('不要用 Markdown'));
    expect(sys, isNot(contains('以「>」开头的说明行'))); // 说明行不发给模型
    expect(usr, contains('## 我的笔记\n王总说先做华东'));
    expect(usr, contains('## 会议原话（背景）\n我们这个渠道先从华东开始铺，第0句'));
    expect(usr, contains('最后列待办'));
    expect(usr, isNot(contains('15:00'))); // 原话不带时间
  });

  test('草稿：App 关了再开，没收的会还在（停在暂停）', () async {
    final appDir = Directory('${tmp.path}/app');
    final a = LiveSession(store, appDir, () async {}, shareMemory: false);
    a
      ..stem = 'live20261024-150000'
      ..started = DateTime(2026, 10, 24, 15)
      ..state = LiveState.paused
      ..lines.add(LiveLine(DateTime(2026, 10, 24, 15, 0, 5), '第一句'));
    a.setNotes('记了一句');
    a.dispose(); // 关 App 时存草稿
    final b = LiveSession(store, appDir, () async {}, shareMemory: false);
    expect(b.state, LiveState.paused);
    expect(b.notes, '记了一句');
    expect(b.lines.single.text, '第一句');
  });

  test('标是谁说的：记下声纹，同一个人别的句子自动认出来；收进录音卡带上名字', () async {
    Float32List voice(double x) => Float32List.fromList(List.generate(192, (i) => i.isEven ? x : 1 - x));
    final live = meeting();
    live.lines
      ..clear()
      ..add(LiveLine(DateTime(2026, 10, 24, 15), '先做华东', emb: voice(0.9)))
      ..add(LiveLine(DateTime(2026, 10, 24, 15, 0, 5), '我觉得华南更好', emb: voice(0.1)))
      ..add(LiveLine(DateTime(2026, 10, 24, 15, 0, 9), '华东的渠道已经铺了一半', emb: voice(0.88)))
      ..add(LiveLine(DateTime(2026, 10, 24, 15, 0, 12), '嗯'));
    live.label([0], '王总');
    expect(live.lines[0].speaker, '王总');
    expect(live.lines[0].auto, isFalse);
    expect(live.lines[2].speaker, '王总'); // 声音像，自动认出
    expect(live.lines[2].auto, isTrue);
    expect(live.lines[1].speaker, isNull); // 不像，不乱标
    expect(live.lines[3].speaker, isNull); // 太短没有声纹
    expect(live.people, ['王总']);

    live.label([1], '我');
    expect(live.lines[2].speaker, '王总');
    // 跨会议：新开一个 session 也认得
    final next = LiveSession(store, Directory('${tmp.path}/app'), () async {}, shareMemory: false);
    expect(next.voices.identify(voice(0.92)), '王总');
    expect(next.voices.identify(voice(0.12)), '我');

    final stem = await live.finish();
    final t = await store.lib.transcript(stem!).readAsString();
    expect(t, contains('**[15:00:00]** 王总：先做华东'));
    expect(t, contains('**[15:00:05]** 我：我觉得华南更好'));
    expect(t, contains('**[15:00:12]** 嗯'));
  });

  test('有原声：转成 录音/<录音>.m4a（经纪人工作台要靠它认真录音）', () async {
    if (!Platform.isMacOS) return;
    final live = meeting();
    final pcm = File('${tmp.path}/app/live/live20261024-150000.pcm');
    await pcm.parent.create(recursive: true);
    // 1 秒 440Hz，16k 单声道 16 位
    final b = ByteData(32000);
    for (var i = 0; i < 16000; i++) {
      b.setInt16(i * 2, (8000 * sin(2 * pi * 440 * i / 16000)).round(), Endian.little);
    }
    await pcm.writeAsBytes(b.buffer.asUint8List());
    final stem = await live.finish();
    expect(stem, isNotNull, reason: live.status);
    expect(store.audio(stem!).existsSync(), isTrue);
    expect(store.audio(stem).lengthSync(), greaterThan(1000));
    expect(pcm.existsSync(), isFalse); // 收完清掉
  });

  test('重开没收完的会：没学过的有把握的句子补学进声纹库，每句只学一次', () async {
    Float32List voice(double x) => Float32List.fromList(List.generate(192, (i) => i.isEven ? x : 1 - x));
    final appDir = Directory('${tmp.path}/app');
    final a = LiveSession(store, appDir, () async {}, shareMemory: false);
    a.voices
      ..add('我', voice(0.9))
      ..add('练', voice(0.1));
    final t = DateTime(2026, 10, 24, 15);
    a
      ..stem = 'live20261024-150000'
      ..started = t
      ..state = LiveState.paused
      ..lines.addAll([
        LiveLine(t, '我说一句长的', end: t.add(const Duration(seconds: 5)), emb: voice(0.88)),
        LiveLine(t.add(const Duration(seconds: 6)), '练说一句长的', end: t.add(const Duration(seconds: 10)), emb: voice(0.12)),
        LiveLine(t.add(const Duration(seconds: 11)), '短', end: t.add(const Duration(seconds: 12)), emb: voice(0.85)),
      ]);
    a.setNotes('x');
    a.dispose();
    final b = LiveSession(store, appDir, () async {}, shareMemory: false);
    expect(b.voices.autoCount('我'), 1); // 短的那句不学
    expect(b.voices.autoCount('练'), 1);
    expect(b.lines.every((l) => l.learned), isTrue);
    b.dispose();
    final c = LiveSession(store, appDir, () async {}, shareMemory: false);
    expect(c.voices.autoCount('我'), 1); // 再开一次不重复学
    expect(c.voices.autoCount('练'), 1);
    c.dispose();
  });

  test('整理看我的笔记：切段那步当参考（按时间给），写纪要那步当主线；带上的旧待办不喂', () async {
    final users = <String>[];
    final sy = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai',
        chat: (system, user) async {
          users.add(user);
          return system.contains('"scenes"')
              ? jsonEncode({'scenes': [{'start': '15:00:00', 'end': '15:01:00', 'category': '开会', 'title': '渠道方案', 'event': '讨论渠道。'}]})
              : '## 纪要\n- 渠道';
        });
    final live = meeting();
    live.notes = '';
    live.setNotes('我倾向==华南==', at: 5);
    live.setNotes('${live.notes}\n## 上次没做完\n☐ 旧事', src: 'carry');
    final stem = await live.finish();
    await sy.run(fromCard: false);
    expect(store.recs[stem]!.stage, 'done');
    final cut = users.firstWhere((u) => u.contains('第0句'));
    expect(cut, contains('我开会时在这一截记的笔记，只当参考'));
    expect(cut, contains('我倾向华南'));
    expect(cut, isNot(contains('旧事')));
    final note = users.firstWhere((u) => u.contains('## 这一段'));
    expect(note, contains('## 我当时记的笔记（这一段的）\n我倾向华南'));
    expect(note, isNot(contains('旧事')));
  });
}
