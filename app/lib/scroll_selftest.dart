// 远程测试机自检「长录音右栏拉不拉得动」（远程登录点不了鼠标，只能让 App 自己滚）：
//   LUYINKA_SCROLL_SELFTEST=<结果 json>
// 打开后切到逐字稿，把右栏从头一路滚到底（播放器一边跟着刷新），每帧耗时记下来；滚完打开设置，看设置还点不点得开。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 找最长的那个竖向滚动区（右栏逐字稿）。
ScrollableState? _longest() {
  ScrollableState? best;
  void visit(Element e) {
    if (e is StatefulElement && e.state is ScrollableState) {
      final s = e.state as ScrollableState;
      if (s.widget.axis == Axis.vertical && s.position.hasContentDimensions &&
          (best == null || s.position.maxScrollExtent > best!.position.maxScrollExtent)) {
        best = s;
      }
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return best;
}

/// 界面上现在有没有这样的组件（看设置弹没弹出来）。
bool shown(bool Function(Widget) test) {
  var hit = false;
  void visit(Element e) {
    if (hit) return;
    if (test(e.widget)) {
      hit = true;
      return;
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return hit;
}

Future<void> scrollSelfTest(String out, {required VoidCallback showTranscript, required VoidCallback tick,
    required VoidCallback openSettings, required bool Function() settingsOpen}) async {
  final frames = <double>[]; // 每帧 build + 光栅化，毫秒
  void onTimings(List<FrameTiming> t) => frames.addAll(t.map((f) => f.totalSpan.inMicroseconds / 1000));
  await Future.delayed(const Duration(seconds: 3)); // 等资料读完、右栏出来
  showTranscript();
  await Future.delayed(const Duration(seconds: 1));
  SchedulerBinding.instance.addTimingsCallback(onTimings);
  final sw = Stopwatch()..start();
  var steps = 0;
  var reached = false;
  while (sw.elapsed < const Duration(seconds: 90)) {
    final s = _longest();
    if (s == null) break;
    final p = s.position;
    if (p.pixels >= p.maxScrollExtent - 1) {
      reached = true;
      break;
    }
    p.jumpTo((p.pixels + 600).clamp(0, p.maxScrollExtent));
    tick();
    steps++;
    await SchedulerBinding.instance.endOfFrame;
  }
  final scrollMs = sw.elapsedMilliseconds;
  await Future.delayed(const Duration(milliseconds: 500));
  SchedulerBinding.instance.removeTimingsCallback(onTimings);
  final opened = Stopwatch()..start();
  openSettings();
  var settings = false;
  while (opened.elapsed < const Duration(seconds: 5) && !(settings = settingsOpen())) {
    await Future.delayed(const Duration(milliseconds: 50));
  }
  final sorted = [...frames]..sort();
  double pct(double q) => sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * q).round()];
  await File(out).writeAsString(const JsonEncoder.withIndent('  ').convert({
    'reachedEnd': reached,
    'scrollSteps': steps,
    'scrollMs': scrollMs,
    'maxExtentPx': _longest()?.position.maxScrollExtent.round(),
    'frames': frames.length,
    'frameP50ms': pct(.5),
    'frameP90ms': pct(.9),
    'frameMaxMs': pct(1),
    'framesOver100ms': frames.where((f) => f > 100).length,
    'settingsOpened': settings,
    'settingsOpenMs': opened.elapsedMilliseconds,
  }));
}
