// 截图用：SHOT_DIR=/某目录 flutter test test/note_edit_shot_test.dart --update-goldens
// 会上笔记本（标题 / 重点 / 待办 / @ 选人 / 带上没做完的）、会后笔记卡、对着录音听、随手记、带上没做完的弹窗。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/live.dart';
import 'package:luyinka/live_view.dart';
import 'package:luyinka/note_doc.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';
import 'package:luyinka/theme.dart';

final shotDir = Platform.environment['SHOT_DIR'];

Future<void> _fonts() async {
  final home = Platform.environment['HOME'];
  final cjk = File('$home/Library/Fonts/NotoSansCJKsc-Regular.otf');
  final icons = File('/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  for (final fam in ['Roboto', 'PingFang SC', 'Songti SC', '.SF UI Text', 'sans-serif']) {
    await (FontLoader(fam)..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
  }
  await (FontLoader('MaterialIcons')..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
}

const _notes = '# 青禾防灾片 · 脚本对齐\n'
    '## 脚本\n'
    '· 开头 3 秒先给**灾害画面**，周总说客户最在意这个\n'
    '· 旁白别太硬，==像讲故事==\n'
    '    · 参考上次明川那条的语气\n'
    '## 时间\n'
    '1. 下周三前出分镜\n'
    '2. 月底交成片\n'
    '## 待办\n'
    '☑ 把上一版脚本发给周总\n'
    '☐ 周五前改完旁白\n'
    '☐ 林夏：要素材包\n'
    '\n'
    '## 上次没做完\n'
    '☐ 问周总要品牌规范\n';

void main() {
  late Directory tmp;
  late Store store;
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('noteshot');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await store.lib.ensure();
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.peopleFile.writeAsString('# 人员名单\n\n- 林夏（林下）｜同事｜青禾防灾片｜｜青禾\n- 周总周宁（周总）｜甲方｜青禾防灾片｜｜青禾\n');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('会上笔记本', (tester) async {
    if (shotDir == null) return;
    await tester.runAsync(_fonts);
    final live = LiveSession(store, Directory('${tmp.path}/app'), () async {}, shareMemory: false)
      ..stem = 'live20261113-150000'
      ..started = DateTime(2026, 11, 13, 15)
      ..title = '青禾防灾片 · 脚本对齐'
      ..state = LiveState.paused
      ..notes = _notes;
    final said = ['开头那三秒你们一定要先给灾害画面', '客户最在意的就是这个', '旁白的话别太硬', '下周三之前能不能把分镜出来', '月底交成片没问题吧'];
    for (var i = 0; i < said.length; i++) {
      live.lines.add(LiveLine(DateTime(2026, 11, 13, 15, i * 2), said[i], speaker: i.isEven ? '周总周宁' : null));
    }
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: LiveView(live: live))));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('$shotDir/1-会上笔记本.png'));

    // 打「@雨」：上面冒出名单里的人
    final field = find.byType(TextField).at(1);
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, '$_notes☐ @雨');
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('$shotDir/2-打@选人.png'));

    // 「带上没做完的事」：挑跟青禾有关的
    await tester.runAsync(() async {
      await store.putResult('live20261110-100000', {
        'start': '2026-11-10T10:00:00', 'lines': [],
        'scenes': [
          {
            'id': '20261110-100000-lyk', 'recording': 'live20261110-100000', 'offset': 0.0, 'start': '2026-11-10T10:00:00',
            'end': '2026-11-10T11:00:00', 'category': '开会', 'title': '青禾首次对接', 'event': '', 'place': '', 'people': ['周总周宁'],
            'subject': '', 'reminders': [], 'text': [], 'body': '',
            'actions': [
              {'text': '问周总要品牌规范', 'who': '我', 'confirmed': true},
              {'text': '出报价单', 'who': '我', 'confirmed': true},
              {'text': '给素材包', 'who': '林夏', 'confirmed': true},
            ],
          },
        ],
      });
    });
    await tester.tap(find.byTooltip('带上没做完的事'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '青禾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('出报价单'));
    await tester.tap(find.text('林夏：给素材包'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('$shotDir/6-带上没做完的.png'));
    await tester.pump(const Duration(seconds: 1)); // 草稿的存盘计时器走完
  });

  testWidgets('会后笔记卡 + 随手记', (tester) async {
    if (shotDir == null) return;
    await tester.runAsync(_fonts);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    tester.binding.defaultBinaryMessenger.allMessagesHandler = (channel, handler, message) async =>
        channel.startsWith('xyz.luan/audioplayers') ? const StandardMethodCodec().encodeSuccessEnvelope(null) : handler?.call(message);
    addTearDown(() => tester.binding.defaultBinaryMessenger.allMessagesHandler = null);
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const stem = 'live20261113-150000';
    final lines = _notes.split('\n');
    final meta = [for (final (i, _) in lines.indexed) LineMeta('l$i', at: i < 13 ? 60.0 * i : null, src: i >= 13 ? 'carry' : 'me')];
    await tester.runAsync(() async {
      await store.putResult(stem, {
        'start': '2026-11-13T15:00:00', 'lines': [['15:00:00', '开头那三秒你们一定要先给灾害画面']], 'title': '青禾防灾片 · 脚本对齐',
        'notes': _notes, 'notes_meta': [for (final m in meta) m.toJson()], 'source': '现场会议',
        'scenes': [
          {
            'id': '20261113-150000-lyk', 'recording': stem, 'offset': 0.0, 'start': '2026-11-13T15:00:00', 'end': '2026-11-13T15:48:00',
            'category': '开会', 'title': '青禾防灾片脚本对齐', 'event': '跟周总对脚本、旁白和交付时间。', 'place': '', 'people': ['周总周宁'],
            'subject': '', 'reminders': [], 'actions': [], 'text': [['15:00:00', '开头那三秒你们一定要先给灾害画面']], 'body': '## 纪要\n- 开头先给灾害画面',
          },
        ],
      });
      await File('${tmp.path}/资料/录音/$stem.m4a').create(recursive: true);
    });
    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai');
    await tester.pumpWidget(MaterialApp(
        theme: buildTheme(), home: Home(store: store, syncer: syncer, live: LiveSession(store, store.dir, () async {}, shareMemory: false))));
    await tester.pump();
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      await tester.pump(const Duration(seconds: 1));
    }

    await settle();
    await tester.tap(find.text('青禾防灾片脚本对齐').first);
    await settle();
    await expectLater(find.byType(Home), matchesGoldenFile('$shotDir/3-会后笔记卡.png'));
    await tester.tap(find.text('对着录音听'));
    await settle();
    await expectLater(find.byType(Home), matchesGoldenFile('$shotDir/4-对着录音听.png'));

    await tester.tap(find.byTooltip('随手记：不录音，直接打字记（☐ 待办也会进待办）'));
    await settle();
    final memoField = find.byType(TextField).last;
    await tester.enterText(memoField, '# 明川那条的想法\n· 片尾加一句品牌口号\n☐ 周一跟明川确认 logo 用新版\n☐ 周总周宁：把品牌规范发我');
    await settle();
    await expectLater(find.byType(Home), matchesGoldenFile('$shotDir/5-随手记.png'));
  });
}
