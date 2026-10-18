// 小耳系列：暖纸底、品牌绿、深墨字；标题用宋体，正文用系统黑体（Mac 苹方 / 安卓思源黑体）。
import 'package:flutter/material.dart';

class K {
  static const paper = Color(0xFFF3F2EE);
  static const bar = Color(0xFFEBE9E2);
  static const card = Color(0xFFFBFAF7);
  static const line = Color(0xFFDCD8CC);
  static const ink = Color(0xFF2B2A26);
  static const mute = Color(0xFF5D5A52);
  static const faint = Color(0xFF7A776D);
  static const green = Color(0xFF4A7A23);
  static const greenLive = Color(0xFF7BC043);
  static const greenSoft = Color(0xFFE4EED8);
  static const greenEdge = Color(0xFFD5E6C2);
  static const todo = Color(0xFF8A4F12);
  static const todoSoft = Color(0xFFF6E6D2);
  static const sans = ['PingFang SC', 'Noto Sans CJK SC', 'Noto Sans SC', 'sans-serif'];
  static const serif = ['Songti SC', 'Noto Serif CJK SC', 'Noto Serif SC', 'serif'];

  static TextStyle title(double size) =>
      TextStyle(fontFamilyFallback: serif, fontSize: size, fontWeight: FontWeight.w700, color: ink, height: 1.3);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: K.green, surface: K.paper, primary: K.green),
    scaffoldBackgroundColor: K.paper,
    fontFamilyFallback: K.sans,
    dividerColor: K.line,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: K.ink, displayColor: K.ink, fontFamilyFallback: K.sans),
    inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none, isDense: true),
  );
}

/// 小耳：绿色毛绒猫耳小怪。stand 平常 / wave 打招呼（空的时候）/ sleep 等卡（卡不在旁边）。
class Mascot extends StatelessWidget {
  final String pose;
  final double size;
  const Mascot(this.pose, {super.key, this.size = 40});
  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/mascot/$pose.png', height: size, filterQuality: FilterQuality.medium);
}

/// 分类的颜色：同一类永远同一个色，一眼分得开。
(Color, Color) categoryColors(String c) {
  const palette = [
    (Color(0xFFE4EED8), Color(0xFF3D6A1B)), // 绿
    (Color(0xFFE3ECF4), Color(0xFF2F5878)), // 蓝
    (Color(0xFFF6E6D2), Color(0xFF8A4F12)), // 橙
    (Color(0xFFEFE4F1), Color(0xFF6B3F78)), // 紫
    (Color(0xFFF4E1E1), Color(0xFF8A3434)), // 红
    (Color(0xFFE6EEEC), Color(0xFF2F6A60)), // 青
  ];
  const fixed = {'自言自语': 0, '与人对话': 1, '打电话': 1, '商业洽谈': 2, '开会': 2, '学习听课': 3, '嘉宾分享': 4, '生活日常': 5};
  return palette[fixed[c] ?? (c.codeUnits.fold<int>(0, (a, b) => a + b) % palette.length)];
}

class Chip2 extends StatelessWidget {
  final String text;
  final bool todo;
  const Chip2(this.text, {super.key, this.todo = false});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
        decoration: BoxDecoration(
            color: todo ? K.todoSoft : categoryColors(text).$1, borderRadius: BorderRadius.circular(99)),
        child: Text(text, style: TextStyle(fontSize: 12, color: todo ? K.todo : categoryColors(text).$2)),
      );
}

String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

const _week = ['一', '二', '三', '四', '五', '六', '日'];

String dayTitle(String key, {bool short = false}) {
  final d = DateTime.parse(key);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(DateTime(d.year, d.month, d.day)).inDays;
  final md = short ? '${d.month}/${d.day}' : '${d.month} 月 ${d.day} 日';
  if (diff == 0) return short ? '今天' : '今天 · $md';
  if (diff == 1) return short ? '昨天' : '昨天 · $md';
  return '$md 周${_week[d.weekday - 1]}';
}

String duration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '$h 小时 $m 分' : (d.inMinutes > 0 ? '${d.inMinutes} 分钟' : '${d.inSeconds} 秒');
}
