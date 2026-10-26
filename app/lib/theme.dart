// 小耳系列：暖纸底、品牌绿、深墨字；标题用宋体，正文用系统黑体（Mac 苹方 / 安卓思源黑体）。
import 'dart:math';

import 'package:flutter/material.dart';

/// 一套皮肤：配色 + 标题字体 + 要不要吉祥物和手绘点缀。设置 → 外观里换，马上生效。
class Skin {
  final String key, name;
  final Color sage, card, cardDeep, line, lineStrong, ink, mute, faint, accent, accentSoft, accentEdge, blush;
  final Color live, todo, todoSoft, todoBg;
  final bool serifTitle; // 标题用宋体（少女风）还是黑体（简约风）
  final bool cute; // 吉祥物、手绘波浪线、小星星
  final bool dark; // 深色：系统控件（输入框、菜单、对话框）也按深色画
  final List<(Color, Color)> cats; // 类别标签的（底色, 字色）
  const Skin({
    required this.key,
    required this.name,
    required this.sage,
    required this.card,
    required this.cardDeep,
    required this.line,
    required this.lineStrong,
    required this.ink,
    required this.mute,
    required this.faint,
    required this.accent,
    required this.accentSoft,
    required this.accentEdge,
    required this.blush,
    required this.live,
    required this.todo,
    required this.todoSoft,
    required this.todoBg,
    required this.serifTitle,
    required this.cute,
    this.dark = false,
    required this.cats,
  });
}

/// 少女风：照 Paperless Post 请柬——鼠尾草绿底、米白纸卡片、深青墨字、珊瑚粉手绘点缀，有小耳。
const girlSkin = Skin(
  key: 'girl',
  name: '少女风',
  sage: Color(0xFFC9D6C3),
  card: Color(0xFFF8F3E8),
  cardDeep: Color(0xFFF1EADB),
  line: Color(0xFFE6DCC8),
  lineStrong: Color(0xFFD5C9B1),
  ink: Color(0xFF1F4A44),
  mute: Color(0xFF4F6A64),
  faint: Color(0xFF7F928C),
  accent: Color(0xFFD95E54),
  accentSoft: Color(0xFFF9E1DC),
  accentEdge: Color(0xFFEFB8AF),
  blush: Color(0xFFF3D2CE),
  live: Color(0xFF4F9A68),
  todo: Color(0xFF8F6514),
  todoSoft: Color(0xFFF5E6C2),
  todoBg: Color(0xFFFBF4E2),
  serifTitle: true,
  cute: true,
  cats: [
    (Color(0xFFDDE7D8), Color(0xFF2F5E50)), // 鼠尾草
    (Color(0xFFF9E1DC), Color(0xFFB4483F)), // 信封粉
    (Color(0xFFF5E6C2), Color(0xFF8F6514)), // 奶黄
    (Color(0xFFDCE6EA), Color(0xFF2F5A6A)), // 雾蓝
    (Color(0xFFEBE2EE), Color(0xFF6A4C78)), // 浅紫
    (Color(0xFFE2EBE0), Color(0xFF3F6B4A)), // 薄荷
  ],
);

/// 深色玻璃：照苹果深色模式——左栏和窗口底透明、露出系统的毛玻璃（看得到桌面），内容卡片是深灰半透明，
/// 白字、苹果蓝强调，没有吉祥物和手绘点缀，标题用黑体。
const glassSkin = Skin(
  key: 'glass',
  name: '深色玻璃',
  dark: true,
  sage: Color(0x1A000000), // 左栏、窗口底：几乎透明，底下的蓝光透上来
  card: Color(0xB30B0E15), // 内容面板：半透明近黑（带一点蓝）+ 背后模糊 = 磨砂玻璃
  cardDeep: Color(0x12FFFFFF),
  line: Color(0x1FFFFFFF),
  lineStrong: Color(0x33FFFFFF),
  ink: Color(0xFFF5F5F7),
  mute: Color(0xFFC7C7CC),
  faint: Color(0xFF8E8E93),
  accent: Color(0xFF0A84FF),
  accentSoft: Color(0x330A84FF),
  accentEdge: Color(0x660A84FF),
  blush: Color(0x260A84FF),
  live: Color(0xFF30D158),
  todo: Color(0xFFFF9F0A),
  todoSoft: Color(0x33FF9F0A),
  todoBg: Color(0x1AFF9F0A),
  serifTitle: false,
  cute: false,
  cats: [
    (Color(0x2EFFFFFF), Color(0xFFE5E5EA)),
    (Color(0x330A84FF), Color(0xFF64D2FF)),
    (Color(0x33FF9F0A), Color(0xFFFFD60A)),
    (Color(0x3330D158), Color(0xFF30D158)),
    (Color(0x33BF5AF2), Color(0xFFDA8FFF)),
    (Color(0x33FF375F), Color(0xFFFF6482)),
  ],
);

const skins = [girlSkin, glassSkin];

/// 现在用的皮肤（App 根上听它，一换整个界面重画）。
final skin = ValueNotifier<Skin>(girlSkin);

class K {
  static Skin get _s => skin.value;
  static Color get sage => _s.sage; // 窗口底
  static Color get paper => _s.sage;
  static Color get bar => _s.sage; // 左栏、播放条直接落在底色上
  static Color get card => _s.card;
  static Color get cardDeep => _s.cardDeep;
  static Color get line => _s.line;
  static Color get lineStrong => _s.lineStrong;
  static Color get ink => _s.ink; // 正文、标题
  static Color get mute => _s.mute;
  static Color get faint => _s.faint;
  static Color get accent => _s.accent; // 时间、强调、按钮
  static Color get accentSoft => _s.accentSoft; // 选中、标签底
  static Color get accentEdge => _s.accentEdge;
  static Color get blush => _s.blush;
  static Color get live => _s.live; // 在线小圆点
  static Color get todo => _s.todo; // 要办的事
  static Color get todoSoft => _s.todoSoft;
  static Color get todoBg => _s.todoBg;
  static bool get cute => _s.cute;
  static bool get dark => _s.dark;
  /// 主按钮的底：少女风珊瑚粉，深色玻璃是半透明苹果蓝
  static Color get cta => _s.dark ? const Color(0xD90A84FF) : _s.accent;
  /// 深色实心按钮（交给 Agent、导入录音卡、播放）：少女风墨色底 + 米白字；深色玻璃是磨砂白玻璃 + 白字
  static Color get strong => _s.dark ? const Color(0x2EFFFFFF) : _s.ink;
  static Color get onStrong => _s.dark ? _s.ink : _s.card;
  /// 选中的筛选标签
  static Color get picked => _s.dark ? const Color(0x400A84FF) : _s.cardDeep;

  /// 设备页那几块：少女风是半透明白，深色玻璃是一层很淡的亮
  static Color get tile => _s.dark ? _s.cardDeep : Colors.white.withValues(alpha: 0.6);

  /// 浮在上面的整块面板（右边滑出的详情、交给 Agent）：少女风用底色，深色玻璃用不透明深灰（透明的话后面会透出来）
  static Color get panel => _s.dark ? const Color(0xF52A2A2D) : _s.sage;
  static const sans = ['PingFang SC', 'Noto Sans CJK SC', 'Noto Sans SC', 'sans-serif'];
  static const serif = ['Songti SC', 'Noto Serif CJK SC', 'Noto Serif SC', 'serif'];

  static TextStyle title(double size) => TextStyle(
    fontFamilyFallback: _s.serifTitle ? serif : sans,
    fontSize: size,
    fontWeight: FontWeight.w700,
    color: ink,
    height: 1.3,
  );
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: K.accent,
      brightness: K.dark ? Brightness.dark : Brightness.light,
      surface: K.dark ? K.card : K.paper,
      primary: K.accent,
      onPrimary: Colors.white,
    ),
    scaffoldBackgroundColor: K.paper,
    fontFamilyFallback: K.sans,
    dividerColor: K.line,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: K.ink, displayColor: K.ink, fontFamilyFallback: K.sans),
    inputDecorationTheme: InputDecorationTheme(
      border: InputBorder.none,
      isDense: true,
      hintStyle: TextStyle(color: K.faint),
      labelStyle: TextStyle(color: K.mute),
    ),
    textSelectionTheme: TextSelectionThemeData(cursorColor: K.accent, selectionColor: K.accent.withValues(alpha: 0.3)),
    popupMenuTheme: PopupMenuThemeData(color: K.dark ? const Color(0xFF2C2C2E) : K.card),
    dialogTheme: DialogThemeData(backgroundColor: K.dark ? const Color(0xF22C2C2E) : K.card),
    // 深色玻璃：按钮、标签都是磨砂玻璃——半透明白 + 一圈细亮边；主按钮是半透明的苹果蓝
    outlinedButtonTheme: K.dark
        ? OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              backgroundColor: const Color(0x1AFFFFFF),
              foregroundColor: K.ink,
              side: const BorderSide(color: Color(0x33FFFFFF)),
            ),
          )
        : null,
    filledButtonTheme: K.dark
        ? FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xD90A84FF),
              foregroundColor: Colors.white,
              side: const BorderSide(color: Color(0x40FFFFFF)),
            ),
          )
        : null,
    chipTheme: K.dark
        ? ChipThemeData(
            backgroundColor: const Color(0x14FFFFFF),
            selectedColor: const Color(0x400A84FF),
            side: const BorderSide(color: Color(0x26FFFFFF)),
            labelStyle: TextStyle(color: K.ink),
          )
        : null,
    iconButtonTheme: K.dark ? IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: K.mute)) : null,
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
    if (!K.cute) return const SizedBox.shrink(); // 简约风不放吉祥物
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
              decoration: BoxDecoration(color: K.blush, shape: BoxShape.circle)),
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
  Widget build(BuildContext context) => K.cute
      ? Align(alignment: Alignment.centerLeft, child: CustomPaint(size: Size(width, 12), painter: _SquigglePainter()))
      : const SizedBox(height: 4); // 简约风不画手绘线
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
  Widget build(BuildContext context) =>
      K.cute ? CustomPaint(size: Size.square(size), painter: _SparklePainter()) : SizedBox(width: size * 0.3);
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
  final Color? color;
  const Label(this.text, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        const Sparkle(),
        const SizedBox(width: 7),
        Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 2, color: color ?? K.ink)),
      ]);
}

/// 分类的颜色：同一类永远同一个色，一眼分得开。
(Color, Color) categoryColors(String c) {
  final palette = skin.value.cats;
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

/// 深色玻璃的壁纸：几乎全黑，左栏那一溜透出科技蓝的光（像屏幕边上打了一道蓝光），右下角再淡淡一点蓝，别的地方都是黑。
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xFF04060B)),
        child: Stack(fit: StackFit.expand, children: [
          // 左栏一溜蓝：从最左边往右慢慢淡掉，到左栏边上就没了
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment(-0.45, 0),
                colors: [Color(0x591E6BFF), Color(0x1F0A84FF), Color(0x0004060B)],
                stops: [0, 0.55, 1],
              ),
            ),
          ),
          const _Glow(Alignment(-1.0, -0.35), Color(0xFF1E6BFF), 0.75), // 左栏中上：一团亮一点的蓝
          const _Glow(Alignment(1.15, 1.2), Color(0xFF0A84FF), 0.7), // 右下：很淡的蓝
        ]),
      );
}

class _Glow extends StatelessWidget {
  final Alignment at;
  final Color color;
  final double radius;
  const _Glow(this.at, this.color, this.radius);
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: at,
            radius: radius,
            colors: [color.withValues(alpha: 0.45), color.withValues(alpha: 0.0)],
          ),
        ),
      );
}
