import 'dart:async';
// iPhone 语音备忘录：读 db（复制出来读，不碰原文件夹）、起点之后的才自动收、起点之前的勾了才收、
// 没下完的（空的 / 还在变 / 时长对不上）下轮再看、收过的不再收（重启、iCloud 重新下载都一样）、文件夹没有 / 不让读时说人话。
// 全用临时的假文件夹，不碰真的语音备忘录。
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luyinka/iphone.dart';
import 'package:luyinka/iphone_view.dart';
import 'package:luyinka/library.dart';
import 'package:luyinka/local_asr.dart' show startOf;
import 'package:luyinka/store.dart';

/// 2025-01-22 17:55:33 上海 = 09:55:33 UTC
final t1 = DateTime.utc(2025, 1, 22, 9, 55, 33);
double coreData(DateTime t) => t.millisecondsSinceEpoch / 1000 - coreDataEpoch;

Future<void> makeDb(Directory d, List<(String path, String title, DateTime at, double secs)> rows) async {
  final sql = StringBuffer(
      'create table ZCLOUDRECORDING (Z_PK integer primary key, ZDATE timestamp, ZDURATION float, ZEVICTIONDATE timestamp, '
      'ZCUSTOMLABEL varchar, ZENCRYPTEDTITLE varchar, ZPATH varchar);');
  for (final (p, t, at, s) in rows) {
    sql.write("insert into ZCLOUDRECORDING (ZDATE, ZDURATION, ZENCRYPTEDTITLE, ZPATH) values (${coreData(at)}, $s, '$t', '$p');");
  }
  sql.write("insert into ZCLOUDRECORDING (ZDATE, ZDURATION, ZENCRYPTEDTITLE, ZPATH) values (0, 0, '新录音 2', null);");
  final r = await Process.run('/usr/bin/sqlite3', ['${d.path}/CloudRecordings.db', sql.toString()]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
}

/// 测试里的「现在」（假钟）。放文件的默认修改时间也按它算，别用真钟——不然换一天跑，文件就成了「未来写的」、永远判成没下完。
late DateTime clock;

/// 放一个「录音」文件；默认（假钟的）1 小时前写好的（早就下完了）
File put(Directory d, String name, {int bytes = 1000, DateTime? modified}) {
  final f = File('${d.path}/$name')..writeAsBytesSync(Uint8List(bytes));
  f.setLastModifiedSync(modified ?? clock.subtract(const Duration(hours: 1)));
  return f;
}

Map<String, String> snapshot(Directory d) => {
      for (final f in d.listSync().whereType<File>()) f.path: '${f.lengthSync()}:${f.lastModifiedSync().millisecondsSinceEpoch}',
    };

void main() {
  late Directory tmp, vm;
  late Store store;
  var converted = <String>[];
  var secs = <String, double?>{}; // 文件名 → 假的实际时长（没写 = 跟 db 一样长）
  var woke = 0;

  VoiceMemoSyncer syncer({Map<String, double>? dbSecs}) => VoiceMemoSyncer(
        store,
        VoiceMemos(vm),
        () async {},
        convert: (src, dst) async {
          converted.add(src.uri.pathSegments.last);
          await dst.writeAsBytes(await src.readAsBytes());
        },
        probe: (f) async {
          final n = f.uri.pathSegments.last;
          return secs.containsKey(n) ? secs[n] : 62.0;
        },
        now: () => clock,
        wake: () async => woke++,
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('iphone');
    vm = await Directory('${tmp.path}/Recordings').create();
    await Directory('${tmp.path}/app/raw').create(recursive: true);
    store = Store(Directory('${tmp.path}/app'))..lib = Library(Directory('${tmp.path}/资料'));
    await store.lib.ensure();
    converted = [];
    secs = {};
    clock = DateTime.now();
  });
  tearDown(() async {
    await store.save();
    if (vm.existsSync()) await Process.run('chmod', ['-R', 'u+rwx', vm.path]);
    await tmp.delete(recursive: true);
  });

  test('读 db：标题、开录时刻、时长；文件名里的墙上时间做录音名；文件夹里什么都没动', () async {
    await makeDb(vm, [
      ('20250122 175533.m4a', '同济大学四平路校区 5', t1, 62.35),
      ('20250122 180256.m4a', '新录音 137', t1.add(const Duration(minutes: 7, seconds: 23)), 296.8),
    ]);
    put(vm, '20250122 175533.m4a');
    final before = snapshot(vm);
    final l = await VoiceMemos(vm).list();
    expect(l.map((m) => m.path), ['20250122 180256.m4a', '20250122 175533.m4a']); // 新的在前；没文件名的那行不算
    final m = l.last;
    expect(m.title, '同济大学四平路校区 5');
    expect(m.at.difference(t1).inMilliseconds.abs(), lessThan(2));
    expect(m.seconds, closeTo(62.35, 0.001));
    expect(m.wall, DateTime(2025, 1, 22, 17, 55, 33));
    expect(m.stem, 'iphone20250122-175533');
    expect(m.present, isTrue);
    expect(l.first.present, isFalse); // db 里有、文件还在 iCloud 上
    expect(snapshot(vm), before);
    expect(vm.listSync().length, 2); // 没多出 -journal / -shm 之类
    expect(startOf(m.stem), DateTime(2025, 1, 22, 17, 55, 33));
    expect(sourceOf(m.stem), 'iPhone');
    expect(memoTitle(store..settings['iphoneTitles'] = {'a': '新录音 137', 'b': '同济'}, 'a'), isNull);
    expect(memoTitle(store, 'b'), '同济');
  }, skip: !Platform.isMacOS);

  test('没有 db：标题、时间看文件名', () async {
    put(vm, '20250122 175533.m4a');
    final m = (await VoiceMemos(vm).list()).single;
    expect(m.title, '录音 2025-01-22 17:55');
    expect(m.wall, DateTime(2025, 1, 22, 17, 55, 33));
    expect(m.seconds, 0);
  });

  test('起点：第一次打开时记下，之后新录的自动收，之前的不收；勾了的旧录音才收', () async {
    clock = DateTime(2026, 11, 4, 10);
    put(vm, '20261103 090000.m4a');
    final s = syncer();
    await s.run();
    expect(s.since, clock);
    expect(converted, isEmpty);
    put(vm, '20261104 110000.m4a');
    clock = DateTime(2026, 11, 4, 12);
    await s.run();
    expect(converted, ['20261104 110000.m4a']);
    final r = store.recs['iphone20261104-110000']!;
    expect(r.stage, 'pulled');
    expect(store.raw(r.stem).existsSync(), isTrue);
    expect(s.last['title'], '录音 2026-11-04 11:00');
    expect(memoStatus(s), contains('最近收到'));

    final old = await s.before();
    expect(old.map((m) => m.path), ['20261103 090000.m4a']);
    await s.pick(old);
    expect(converted, ['20261104 110000.m4a', '20261103 090000.m4a']);
    expect(s.queue, isEmpty);
    expect(store.recs.containsKey('iphone20261103-090000'), isTrue);
  });

  test('没下完的不收：空文件、还在变、时长比 db 短、文件还没下来；下完了再收', () async {
    clock = DateTime(2026, 11, 4, 10);
    final s = syncer();
    await s.run(); // 记下起点
    final at = DateTime(2026, 11, 4, 11);
    await makeDb(vm, [
      ('20261104 110000.m4a', '会议', at, 62),
      ('20261104 110500.m4a', '空的', at.add(const Duration(minutes: 5)), 30),
      ('20261104 111000.m4a', '还在下', at.add(const Duration(minutes: 10)), 30),
      ('20261104 111500.m4a', '在云上', at.add(const Duration(minutes: 15)), 30),
    ]);
    clock = DateTime(2026, 11, 4, 12);
    put(vm, '20261104 110000.m4a'); // 文件在，可实际只有 20 秒
    secs['20261104 110000.m4a'] = 20;
    put(vm, '20261104 110500.m4a', bytes: 0);
    put(vm, '20261104 111000.m4a', bytes: 100, modified: clock.subtract(const Duration(seconds: 5)));
    await s.run();
    expect(converted, isEmpty);
    expect(s.waiting, 4);
    expect(memoStatus(s), contains('正在从 iCloud 下载'));

    // 时长对上了；还在下的那条大小变了（还没完）
    secs['20261104 110000.m4a'] = 61.5;
    put(vm, '20261104 111000.m4a', bytes: 200, modified: clock);
    clock = clock.add(const Duration(seconds: 30));
    await s.run();
    expect(converted, ['20261104 110000.m4a']);

    // 又过 30 秒，大小没再变：收
    clock = clock.add(const Duration(seconds: 30));
    await s.run();
    expect(converted, ['20261104 110000.m4a', '20261104 111000.m4a']);
    expect(s.waiting, 2); // 空的、在云上的还等着
  }, skip: !Platform.isMacOS);

  test('收过的不再收：再跑、重启 App、iCloud 重新下载一遍都一样', () async {
    clock = DateTime(2026, 11, 4, 10);
    final s = syncer();
    await s.run();
    put(vm, '20261104 110000.m4a');
    clock = DateTime(2026, 11, 4, 12);
    await s.run();
    await s.run();
    expect(converted.length, 1);

    // 重启：从 state.json 读回来
    await store.save();
    store = Store(store.dir)..lib = store.lib;
    final st = await File('${store.dir.path}/state.json').readAsString();
    expect(st, contains('20261104 110000.m4a'));
    await store.load();
    // iCloud 重新下载：文件换了一份（修改时间变了）
    put(vm, '20261104 110000.m4a', bytes: 1200);
    await syncer().run();
    expect(converted.length, 1);
    // App 里删了这条（录音没了），也不会再从 iPhone 收回来
    store.recs.clear();
    await syncer().run();
    expect(converted.length, 1);
  });

  test('关了就不收；文件夹没有 / 不让读：说清楚怎么打开', () async {
    clock = DateTime(2026, 11, 4, 10);
    store.settings['iphoneOff'] = true;
    final s = syncer();
    await s.run();
    expect(s.since, isNull);
    expect(memoStatus(s), contains('已关闭'));
    s.setOff(false);
    await Future.delayed(Duration.zero);
    while (s.busy) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    await vm.delete(recursive: true);
    await s.run();
    expect(s.problem?.denied, isFalse);
    expect(memoStatus(s), allOf(contains('iCloud → 语音备忘录'), contains('系统设置 → Apple 账户')));
    await expectLater(s.before(), throwsA(isA<MemoError>()));

    await vm.create();
    await Process.run('chmod', ['000', vm.path]);
    await s.run();
    expect(s.problem?.denied, isTrue);
    expect(memoStatus(s), contains('完全磁盘访问权限'));
  });

  testWidgets('挑以前的录音：列出起点之前的（标题、日期、时长），勾了导入', (tester) async {
    store.settings['iphoneSince'] = clock.toIso8601String();
    await tester.runAsync(() async {
      await makeDb(vm, [
        ('20250122 175533.m4a', '同济大学四平路校区 5', t1, 62.35),
        ('20250112 090816.m4a', '中山北二路 2', DateTime.utc(2025, 1, 12, 1, 8, 16), 8490.9),
      ]);
      put(vm, '20250122 175533.m4a');
    });
    final s = syncer();
    final l = (await tester.runAsync(s.before))!; // 读 db 是真的子进程，在假时钟外面读
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MemoPicker(s, list: Future.value(l)))));
    await tester.pump();
    expect(find.textContaining('共 2 条'), findsOneWidget);
    expect(find.text('同济大学四平路校区 5'), findsOneWidget);
    expect(find.textContaining('2025-01-22 17:55 · 1 分 2 秒'), findsOneWidget);
    expect(find.textContaining('2 小时 21 分 · 还在 iCloud 上'), findsOneWidget);
    await tester.tap(find.text('同济大学四平路校区 5'));
    await tester.pump();
    expect(find.text('导入 1 条'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('导入 1 条'));
      for (var i = 0; i < 50 && converted.isEmpty; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pump();
    expect(converted, ['20250122 175533.m4a']);
    expect(store.recs.containsKey('iphone20250122-175533'), isTrue);
  }, skip: !Platform.isMacOS);

  test('CAF 里的 Opus 包进 Ogg：系统解得出、时长对（真的 m4a → Ogg）', () async {
    final d = await Directory.systemTemp.createTemp('m4aogg');
    try {
      // 3 秒 440Hz 的 wav → m4a（跟语音备忘录一样是 AAC）
      const rate = 16000, n = rate * 3;
      final pcm = ByteData(n * 2);
      for (var i = 0; i < n; i++) {
        pcm.setInt16(i * 2, (sin(2 * pi * 440 * i / rate) * 8000).round(), Endian.little);
      }
      final h = ByteData(44);
      void tag(int o, String s) {
        for (final (i, c) in s.codeUnits.indexed) {
          h.setUint8(o + i, c);
        }
      }
      tag(0, 'RIFF');
      h.setUint32(4, 36 + n * 2, Endian.little);
      tag(8, 'WAVEfmt ');
      h
        ..setUint32(16, 16, Endian.little)
        ..setUint16(20, 1, Endian.little)
        ..setUint16(22, 1, Endian.little)
        ..setUint32(24, rate, Endian.little)
        ..setUint32(28, rate * 2, Endian.little)
        ..setUint16(32, 2, Endian.little)
        ..setUint16(34, 16, Endian.little);
      tag(36, 'data');
      h.setUint32(40, n * 2, Endian.little);
      final wav = File('${d.path}/a.wav')..writeAsBytesSync([...h.buffer.asUint8List(), ...pcm.buffer.asUint8List()]);
      final m4a = File('${d.path}/a.m4a');
      final r = await Process.run('/usr/bin/afconvert', ['-f', 'm4af', '-d', 'aac', wav.path, m4a.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(await afinfoSeconds(m4a), closeTo(3, 0.1));
      expect(await afinfoSeconds(File('${d.path}/a.wav.half')), isNull);

      final ogg = File('${d.path}/a.opus');
      await m4aToOgg(m4a, ogg);
      final head = ogg.readAsBytesSync();
      expect(String.fromCharCodes(head.sublist(0, 4)), 'OggS');
      expect(await afinfoSeconds(ogg), closeTo(3, 0.1));
      // 本机转写那一步：Ogg → 16k wav
      final back = File('${d.path}/b.wav');
      final r2 = await Process.run('/usr/bin/afconvert', ['-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', ogg.path, back.path]);
      expect(r2.exitCode, 0, reason: '${r2.stderr}');
      expect(back.lengthSync(), closeTo(n * 2, rate * 2 * 0.25)); // AAC 编码头尾会多出一点
      // 老的语音备忘录是 44.1k 立体声
      final st = File('${d.path}/st.m4a');
      final r3 = await Process.run('/usr/bin/afconvert', ['-f', 'm4af', '-d', 'aac@44100', '-c', '2', wav.path, st.path]);
      expect(r3.exitCode, 0, reason: '${r3.stderr}');
      await m4aToOgg(st, File('${d.path}/st.opus'));
      expect(await afinfoSeconds(File('${d.path}/st.opus')), closeTo(3, 0.15));
      // 半截的 m4a（尾巴没下来）：afinfo 读不出
      final half = File('${d.path}/half.m4a')..writeAsBytesSync(m4a.readAsBytesSync().sublist(0, m4a.lengthSync() ~/ 2));
      final hs = await afinfoSeconds(half);
      expect(hs == null || hs < 2.9, isTrue);
    } finally {
      await d.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);

  test('App 没开、只有后台同步时：声音在 _FBF 外部文件里也收；之后整理成 .m4a 也不重复收（认 ZUNIQUEID）', () async {
    final s = syncer();
    await s.run(); // 记起点
    const u = '8264BF79-8F56-402C-89A0-483367F042C4';
    final hex = '03232323' 'EC31020000000000' '${u.replaceAll('-', '')}'
        '${u.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join()}';
    expect(externalRef(hex), '.CloudRecordings_SUPPORT/_FBF/$u');
    expect(externalRef(''), '');
    final at = clock.add(const Duration(minutes: 1)).toUtc();
    Future<void> sql(String q) async {
      final r = await Process.run('/usr/bin/sqlite3', ['${vm.path}/CloudRecordings.db', q]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }
    await sql('create table ZCLOUDRECORDING (Z_PK integer primary key, ZDATE timestamp, ZDURATION float, ZEVICTIONDATE timestamp, '
        'ZCUSTOMLABEL varchar, ZENCRYPTEDTITLE varchar, ZPATH varchar, ZUNIQUEID varchar, ZAUDIOFUTURE blob);'
        "insert into ZCLOUDRECORDING (ZDATE, ZDURATION, ZENCRYPTEDTITLE, ZPATH, ZUNIQUEID, ZAUDIOFUTURE) "
        "values (${coreData(at)}, 62, '金隅凤栖家园 3', null, '0D56F59C-CE3F', X'$hex');"
        "insert into ZCLOUDRECORDING (ZDATE, ZDURATION, ZENCRYPTEDTITLE, ZPATH, ZUNIQUEID, ZAUDIOFUTURE) "
        "values (${coreData(at)}, 0, '还在录', null, 'AAAA', null);");
    clock = clock.add(const Duration(minutes: 5));
    await s.run();
    expect(converted, isEmpty); // 声音还没从 iCloud 拉下来
    final memo = (await VoiceMemos(vm).list()).single; // 没有声音引用的那条不列
    expect((memo.path, memo.title, memo.present), ('ck:0D56F59C-CE3F', '金隅凤栖家园 3', false));
    final fbf = await Directory('${vm.path}/.CloudRecordings_SUPPORT/_FBF').create(recursive: true);
    put(fbf, u);
    await s.run();
    expect(converted, [u]);
    expect(store.recs.keys.where((k) => k.startsWith('iphone')), hasLength(1));
    expect(store.settings['iphoneTaken'], contains('ck:0D56F59C-CE3F'));
    // 后来语音备忘录 App 开了：整理成 .m4a、ZPATH 填上、_FBF 那份没了
    File('${fbf.path}/$u').deleteSync();
    put(vm, '20261104 040700-0D56F59C.m4a');
    await sql("update ZCLOUDRECORDING set ZPATH = '20261104 040700-0D56F59C.m4a' where ZUNIQUEID = '0D56F59C-CE3F';");
    await s.run();
    expect(converted, [u]); // 不重复收
    expect((await VoiceMemos(vm).list()).single.rel, '20261104 040700-0D56F59C.m4a');
  });

  test('隔 10 分钟叫醒一次语音备忘录的后台同步', () async {
    final s = syncer();
    woke = 0;
    await s.run();
    await s.run();
    expect(woke, 1);
    clock = clock.add(const Duration(minutes: 11));
    await s.run();
    expect(woke, 2);
  });

  testWidgets('读不了语音备忘录：第一次主动问一次（去打开 / 以后再说），之后不再问', (t) async {
    final s = syncer();
    s.problem = MemoError(true, 'denied');
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    await t.runAsync(() async {
      unawaited(askMemoAccess(ctx, s)); // 先存 settings（真读写）再弹框
      await Future.delayed(const Duration(milliseconds: 300));
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('去打开'), findsOneWidget);
    expect(find.textContaining('完全磁盘访问权限'), findsOneWidget);
    expect(store.settings['iphoneAsked'], true);
    await t.tap(find.text('以后再说'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.pump();
    expect(find.text('去打开'), findsNothing);
    await t.runAsync(() => askMemoAccess(ctx, s)); // 问过了：直接返回
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('去打开'), findsNothing);
  });
}
