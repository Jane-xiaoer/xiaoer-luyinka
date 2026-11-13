// 左栏「按人」里管人（2026-11-11 Jane）：并人、写资料（公司分组）、删人，都在真 Home 上点。
// 截图：SHOT_DIR=/某目录 flutter test test/person_manage_ui_test.dart --update-goldens（会载入本机 Noto 字体）。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/cloud.dart';
import 'package:luyinka/confirm.dart';
import 'package:luyinka/home.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/live.dart';
import 'package:luyinka/llm.dart';
import 'package:luyinka/store.dart';
import 'package:luyinka/sync.dart';

final shotDir = Platform.environment['SHOT_DIR'];

Future<void> _fonts() async {
  final home = Platform.environment['HOME'];
  final cjk = File('$home/Library/Fonts/NotoSansCJKsc-Regular.otf');
  final icons = File('/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (!cjk.existsSync()) return;
  for (final fam in ['Roboto', 'PingFang SC', 'Songti SC', '.SF UI Text', 'sans-serif']) {
    await (FontLoader(fam)..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
  }
  if (icons.existsSync()) await (FontLoader('MaterialIcons')..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
}

Map<String, dynamic> sc(String id, String start, String title, List<String> people) => {
      'id': id, 'start': '$start:00', 'end': '${start.substring(0, 14)}50:00', 'category': '开会', 'title': title,
      'event': '$title。', 'people': people, 'text': [], 'body': '## 要点', 'actions': [], 'reminders': [],
    };

void main() {
  late Directory tmp;
  late Store store;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('people');
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    await store.lib.ensure();
    await store.putResult('note20261111-190000', {
      'start': '2026-11-11T19:00:00',
      'scenes': [
        sc('a', '2026-11-11T19:13', '明川生物春芽内容规划会', ['李航', '周总周宁', '董老师']),
        sc('b', '2026-11-10T14:00', '春芽报价', ['周总', '董老师']),
        sc('c', '2026-11-09T10:00', '青禾防灾片对稿', ['董老师', '欧']),
        sc('d', '2026-11-08T10:00', '随手记', ['小耳']),
      ],
    });
  });
  tearDown(() async {
    await store.save();
    await tmp.delete(recursive: true);
  });

  testWidgets('按人：并人 → 写资料按公司分组 → 删人', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    tester.binding.defaultBinaryMessenger.allMessagesHandler = (channel, handler, message) async =>
        channel.startsWith('xyz.luan/audioplayers') ? const StandardMethodCodec().encodeSuccessEnvelope(null) : handler?.call(message);
    addTearDown(() => tester.binding.defaultBinaryMessenger.allMessagesHandler = null);
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (shotDir != null) await tester.runAsync(_fonts);
    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai');
    await tester.pumpWidget(MaterialApp(
        home: Home(store: store, syncer: syncer, live: LiveSession(store, store.dir, () async {}, shareMemory: false))));
    await tester.pump();
    // 点了之后有真文件读写：真时间里等一下、再推一帧，来回几轮
    Future<void> io(Future<void> Function() f) async {
      await f();
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      }
      await tester.pumpAndSettle();
    }

    final nav = find.byType(PeopleNav);
    await tester.tap(find.text('按人'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: nav, matching: find.text('周总')), findsOneWidget);

    // 并人：点「周总」→ 中栏「并到另一个人」→ 选「周总周宁」
    await tester.tap(find.descendant(of: nav, matching: find.text('周总')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('并到另一个人'));
    await tester.pumpAndSettle();
    await io(() async => tester.tap(find.widgetWithText(ListTile, '周总周宁')));
    expect(find.descendant(of: nav, matching: find.text('周总')), findsNothing);
    expect(store.lib.peopleFile.readAsStringSync(), contains('- 周总周宁（周总周宁、周总）'));
    expect(find.text('录音里也叫：周总'), findsOneWidget);
    expect(find.text('2 段'), findsOneWidget);

    // 写资料：公司 → 左栏出现「明川生物」组
    await tester.tap(find.text('写资料'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '公司'), '明川生物');
    await tester.enterText(find.widgetWithText(TextField, '项目'), '春芽内容规划');
    await tester.enterText(find.widgetWithText(TextField, '介绍'), '明川生物品牌负责人，春芽项目拍板人；付款按阶段走。');
    await tester.tap(find.widgetWithText(ChoiceChip, '甲方'));
    await tester.pump();
    await io(() async => tester.tap(find.widgetWithText(FilledButton, '存')));
    expect(find.descendant(of: nav, matching: find.text('春芽内容规划')), findsOneWidget);
    expect(find.descendant(of: nav, matching: find.text('没分组')), findsOneWidget);
    expect(store.lib.peopleFile.readAsStringSync(), contains('｜甲方｜春芽内容规划｜明川生物品牌负责人，春芽项目拍板人；付款按阶段走。｜明川生物'));
    if (shotDir != null) await expectLater(find.byType(Home), matchesGoldenFile('$shotDir/按人-写好资料.png'));

    // 编辑框截一张
    if (shotDir != null) {
      await tester.tap(find.text('改资料'));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('$shotDir/按人-资料框.png'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    }

    // 删人：右键菜单 → 删掉，左栏不再列，底下能找回
    await tester.tap(find.descendant(of: nav, matching: find.text('小耳')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await io(() async => tester.tap(find.text('删掉').last));
    expect(find.descendant(of: nav, matching: find.text('小耳')), findsNothing);
    expect(find.text('删掉的 1 人'), findsOneWidget);
    expect(store.lib.hiddenPeopleFile.readAsStringSync().trim(), '小耳');

    // 过了撤销再找回：写过资料的周总周宁删掉 → 底下找回 → 资料和分组都在
    await tester.tap(find.descendant(of: nav, matching: find.text('周总周宁')));
    await tester.pumpAndSettle();
    await io(() async => tester.tap(find.widgetWithText(TextButton, '删掉')));
    expect(find.descendant(of: nav, matching: find.text('春芽内容规划')), findsNothing);
    expect(find.text('删掉的 2 人'), findsOneWidget);
    await tester.tap(find.text('删掉的 2 人'));
    await tester.pumpAndSettle();
    await io(() async => tester.tap(find.text('找回「周总周宁」')));
    expect(find.descendant(of: nav, matching: find.text('春芽内容规划')), findsOneWidget);
    expect(find.descendant(of: nav, matching: find.text('周总')), findsNothing);
    expect(store.lib.peopleFile.readAsStringSync(), contains('｜明川生物'));
    expect(find.text('删掉的 1 人'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('这是我 / 写资料小耳先填草稿 / 按项目看一组', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    tester.binding.defaultBinaryMessenger.allMessagesHandler = (channel, handler, message) async =>
        channel.startsWith('xyz.luan/audioplayers') ? const StandardMethodCodec().encodeSuccessEnvelope(null) : handler?.call(message);
    addTearDown(() => tester.binding.defaultBinaryMessenger.allMessagesHandler = null);
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (shotDir != null) await tester.runAsync(_fonts);
    final syncer = Syncer(store, Cloud('http://127.0.0.1:9', token: 't'), (_) async => null, () async => [], () => 'Asia/Shanghai');
    await tester.pumpWidget(MaterialApp(
        home: Home(store: store, syncer: syncer, live: LiveSession(store, store.dir, () async {}, shareMemory: false))));
    await tester.pump();
    Future<void> io(Future<void> Function() f) async {
      await f();
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      }
      await tester.pumpAndSettle();
    }

    final llm = DraftLlm(), was = Llm.instance;
    Llm.instance = llm; // App 起来时 Syncer 会设自己的，这里换成假的
    addTearDown(() => Llm.instance = was);
    final nav = find.byType(PeopleNav);
    await tester.tap(find.text('按人'));
    await tester.pumpAndSettle();

    // 这是我：右键「小耳」→ 这是我；左栏不再列，名单上记成「我」的叫法
    await tester.tap(find.descendant(of: nav, matching: find.text('小耳')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('这是我（别人这么叫我）'));
    await tester.pumpAndSettle();
    expect(find.text('「小耳」就是你？'), findsOneWidget); // 先问一句，点错了后果重
    await io(() async => tester.tap(find.widgetWithText(FilledButton, '是我')));
    expect(find.descendant(of: nav, matching: find.text('小耳')), findsNothing);
    expect(store.lib.peopleFile.readAsStringSync(), contains('- 我（我、小耳）'));

    // 写资料：小耳先从录音笔记里填草稿
    await tester.tap(find.descendant(of: nav, matching: find.text('周总周宁')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写资料'));
    await io(() async {});
    expect(find.text('小耳从录音里看出来的，先帮你填上了，看一眼对不对再存'), findsOneWidget);
    expect(llm.user, contains('明川生物春芽内容规划会'));
    if (shotDir != null) await expectLater(find.byType(MaterialApp), matchesGoldenFile('$shotDir/写资料-小耳草稿.png'));
    await io(() async => tester.tap(find.widgetWithText(FilledButton, '存')));
    expect(store.lib.peopleFile.readAsStringSync(), contains('｜甲方｜春芽内容规划｜品牌负责人，管合同｜明川生物'));

    // 按项目：左栏有「春芽内容规划」，中栏写对方公司、列出组里的人（名字 · 关系 · 公司）和段；点人跳回按人
    await tester.tap(find.text('按项目'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(GroupNav), matching: find.text('春芽内容规划')), findsOneWidget);
    expect(find.descendant(of: find.byType(GroupColumn), matching: find.text('春芽内容规划')), findsOneWidget);
    expect(find.descendant(of: find.byType(GroupColumn), matching: find.text('明川生物')), findsOneWidget);
    expect(find.byType(SceneRow), findsNWidgets(1)); // 这个测试里周总没并，组里只有周总周宁那 1 段
    if (shotDir != null) await expectLater(find.byType(Home), matchesGoldenFile('$shotDir/按项目.png'));
    await tester.tap(find.widgetWithText(ActionChip, '周总周宁 · 甲方 · 明川生物'));
    await tester.pumpAndSettle();
    expect(find.byType(PersonColumn), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('人员名单页：录音里出现过的人自动列上；不写不存，写了才存；× 跟按人删掉一样藏起来；改名旧名留作叫法', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    store.lib.peopleFile.writeAsStringSync('# 人员名单\n\n- 董老师（董老师）｜合作方｜青禾防灾片｜\n');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PeopleListView(store: store))));
    await tester.pump();
    String val(int i) => tester.widget<TextField>(find.byType(TextField).at(i)).controller!.text;
    // 每行 5 个输入框；董老师在名单上排第一，后面是录音里来的：李航、周总周宁、欧、小耳（按段数、先见先列）
    final names = [for (var i = 0; i < find.byType(TextField).evaluate().length; i += 5) val(i)];
    expect(names, ['董老师', '李航', '周总周宁', '周总', '欧', '小耳']);
    expect(find.text('录音里出现过 1 段，写点什么就存进名单'), findsWidgets);
    // 存有几步真文件读写：真时间里等一下、再推一帧，来回几轮
    Future<void> save() async {
      await tester.pump(); // 打完字先重画一帧，「存」才亮
      await tester.tap(find.text('存'));
      for (var i = 0; i < 15; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      }
      await tester.pump();
    }

    // 给「周总周宁」写公司、把董老师改名「董明」，删掉「小耳」，存
    await tester.enterText(find.byType(TextField).at(2 * 5 + 3), '明川生物');
    await tester.enterText(find.byType(TextField).at(0), '董明');
    await tester.tap(find.byTooltip('删掉这个人').last);
    await tester.pump();
    await save();
    final txt = store.lib.peopleFile.readAsStringSync();
    expect(txt, contains('- 周总周宁（周总周宁）｜｜｜｜明川生物'));
    expect(txt, contains('- 董明（董明、董老师）｜合作方｜青禾防灾片｜'));
    expect(txt, isNot(contains('李航'))); // 没写东西的不存
    expect(store.lib.hiddenPeopleFile.readAsStringSync().trim(), '小耳');

    // 把录音里的「周总」改成名单上已有的「周总周宁」：并成一行，不出两行同名
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PeopleListView(store: store))));
    await tester.pump();
    final names2 = [for (var i = 0; i < find.byType(TextField).evaluate().length; i += 5) val(i)];
    final ci = names2.indexOf('周总');
    await tester.enterText(find.byType(TextField).at(ci * 5), '周总周宁');
    await save();
    final t2 = store.lib.peopleFile.readAsStringSync();
    expect(RegExp('- 周总周宁（').allMatches(t2).length, 1);
    expect(t2, contains('- 周总周宁（周总周宁、周总）｜｜｜｜明川生物'));
    final names3 = [for (var i = 0; i < find.byType(TextField).evaluate().length; i += 5) val(i)];
    expect(names3.where((n) => n == '周总周宁').length, 1); // 存完页面重读，不再显示两行

    // 把董明改名成「周总」（周总周宁的叫法）：拦下，文件不动
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PeopleListView(store: store))));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), '周总');
    await save();
    expect(find.textContaining('没存：「周总」已经是周总周宁的名字或叫法了'), findsOneWidget);
    expect(store.lib.peopleFile.readAsStringSync(), t2);

    // 两个都写了资料的人改成同名：不悄悄并（会丢一个人的资料），拦下
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PeopleListView(store: store))));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), '周总周宁'); // 董明（合作方 / 青禾防灾片）改成周总周宁（明川生物）
    await save();
    expect(find.textContaining('没存：「周总周宁」已经是周总周宁的名字或叫法了'), findsOneWidget);
    expect(store.lib.peopleFile.readAsStringSync(), t2);
  });
}

class DraftLlm extends Llm {
  String user = '';
  DraftLlm() : super(Cloud('http://localhost'), () => {});
  @override
  Future<String> chat(String system, String user, {double temperature = 0.2}) async {
    this.user = user;
    return '{"company":"明川生物","project":"春芽内容规划","identity":"甲方","note":"品牌负责人，管合同"}';
  }
}
