// 小耳系列：暖纸底、品牌绿、深墨字；标题用宋体，正文用系统黑体（Mac 苹方 / 安卓思源黑体）。
import 'dart:math';

import 'package:flutter/material.dart';

class K {
  // 配色照 Paperless Post 请柬：鼠尾草绿底、米白纸卡片、深青墨字、珊瑚粉手绘点缀
  static const sage = Color(0xFFC9D6C3); // 窗口底：鼠尾草绿
  static const paper = sage;
  static const bar = sage; // 左栏、播放条直接落在绿底上
  static const card = Color(0xFFF8F3E8); // 米白纸
  static const cardDeep = Color(0xFFF1EADB); // 纸上的小格子
  static const line = Color(0xFFE6DCC8);
  static const lineStrong = Color(0xFFD5C9B1);
  static const ink = Color(0xFF1F4A44); // 深青墨：正文、标题
  static const mute = Color(0xFF4F6A64);
  static const faint = Color(0xFF7F928C);
  static const accent = Color(0xFFD95E54); // 珊瑚粉：时间、强调、按钮
  static const accentSoft = Color(0xFFF9E1DC); // 信封粉：选中、标签底
  static const accentEdge = Color(0xFFEFB8AF);
  static const blush = Color(0xFFF3D2CE);
  static const live = Color(0xFF4F9A68); // 在线小圆点
  static const todo = Color(0xFF8F6514); // 要办的事：奶黄
  static const todoSoft = Color(0xFFF5E6C2);
  static const todoBg = Color(0xFFFBF4E2);
  static const sans = ['PingFang SC', 'Noto Sans CJK SC', 'Noto Sans SC', 'sans-serif'];
  static const serif = ['Songti SC', 'Noto Serif CJK SC', 'Noto Serif SC', 'serif'];

  static TextStyle title(double size) =>
      TextStyle(fontFamilyFallback: serif, fontSize: size, fontWeight: FontWeight.w700, color: ink, height: 1.3);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: K.accent, surface: K.paper, primary: K.accent),
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
  final bool halo; // 身后垫一个信封粉的圆
  const Mascot(this.pose, {super.key, this.size = 40, this.halo = false});
  @override
  Widget build(BuildContext context) {
    final img = Image.asset('assets/mascot/$pose.png', height: size, filterQuality: FilterQuality.medium);
    if (!halo) return img;
    return SizedBox(
      width: size * 1.3,
      height: size,
      child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
        Positioned(
          right: 0,
          top: size * 0.02,
          child: Container(
              width: size * 0.78, height: size * 0.78,
              decoration: const BoxDecoration(color: K.blush, shape: BoxShape.circle)),
        ),
        Positioned(left: 0, bottom: 0, child: img),
      ]),
    );
  }
}

/// 珊瑚粉手绘波浪线（请柬边上那种丝带），放在标题下面。
class Squiggle extends StatelessWidget {
  final double width;
  const Squiggle({super.key, this.width = 120});
  @override
  Widget build(BuildContext context) =>
      Align(alignment: Alignment.centerLeft, child: CustomPaint(size: Size(width, 12), painter: _SquigglePainter()));
}

class _SquigglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = K.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(0, size.height * 0.6);
    const waves = 5;
    final w = size.width / waves;
    for (var i = 0; i < waves; i++) {
      // 波峰高低略有不同，看着像手画的
      final up = i.isEven ? 0.05 : 0.2;
      path.quadraticBezierTo(w * i + w * 0.25, size.height * up, w * i + w * 0.5, size.height * 0.55);
      path.quadraticBezierTo(w * i + w * 0.75, size.height * (1.05 - up), w * (i + 1), size.height * 0.5);
    }
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// 珊瑚粉小星星 ✳（请柬上撒的那种），给小标题打头。
class Sparkle extends StatelessWidget {
  final double size;
  const Sparkle({super.key, this.size = 13});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _SparklePainter());
}

// 自己画：系统会把 ✳ 换成绿色 emoji
class _SparklePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = K.accent
      ..strokeWidth = size.width * 0.16
      ..strokeCap = StrokeCap.round;
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    for (var i = 0; i < 4; i++) {
      final a = i * 3.14159 / 4;
      final d = Offset(r * 0.9 * cos(a), r * 0.9 * sin(a));
      canvas.drawLine(c - d, c + d, p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// 小标题：✳ + 字距拉开的深青墨字。
class Label extends StatelessWidget {
  final String text;
  final Color color;
  const Label(this.text, {super.key, this.color = K.ink});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        const Sparkle(),
        const SizedBox(width: 7),
        Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 2, color: color)),
      ]);
}

/// 分类的颜色：同一类永远同一个色，一眼分得开。
(Color, Color) categoryColors(String c) {
  const palette = [
    (Color(0xFFDDE7D8), Color(0xFF2F5E50)), // 鼠尾草
    (Color(0xFFF9E1DC), Color(0xFFB4483F)), // 信封粉
    (Color(0xFFF5E6C2), Color(0xFF8F6514)), // 奶黄
    (Color(0xFFDCE6EA), Color(0xFF2F5A6A)), // 雾蓝
    (Color(0xFFEBE2EE), Color(0xFF6A4C78)), // 浅紫
    (Color(0xFFE2EBE0), Color(0xFF3F6B4A)), // 薄荷
  ];
  const fixed = {'开会': 2, '我的分享': 1, '商务洽谈': 4, '现场调研': 3, '听课讲座': 5, '多人群聊': 1, '打电话': 3, '自言自语': 0, '个人感悟': 4,
      '生活日常': 5, '商业洽谈': 4, '学习听课': 5, '嘉宾分享': 5, '与人对话': 1};
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
