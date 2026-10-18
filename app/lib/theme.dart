// 小耳系列：暖纸底、品牌绿、深墨字；标题用宋体，正文用系统黑体（Mac 苹方 / 安卓思源黑体）。
import 'package:flutter/material.dart';

class K {
  // 配色照小耳 IP 参考图：奶油底、象牙白卡片、嫩芽黄绿、四叶草绿、腮红桃色、暖棕墨字
  static const paper = Color(0xFFF5F0E6); // 奶油底
  static const bar = Color(0xFFEEE7D9); // 左栏 / 底栏，比底色深一点
  static const card = Color(0xFFFDFBF6); // 象牙白
  static const line = Color(0xFFE6DECD);
  static const lineStrong = Color(0xFFD9CFBA);
  static const ink = Color(0xFF34302A); // 暖棕墨
  static const mute = Color(0xFF6B6558);
  static const faint = Color(0xFF8E8778);
  static const green = Color(0xFF5E9B2E); // 四叶草绿：标题强调、时间、按钮
  static const greenLive = Color(0xFF8CC63F); // 亮一点的绿：在线小圆点、要点圆点
  static const greenSoft = Color(0xFFEDF3D3); // 嫩芽黄绿浅底：选中、标签
  static const greenEdge = Color(0xFFD5E6A0); // 嫩芽黄绿描边
  static const lime = Color(0xFFCFE38A); // 嫩芽色：装饰底
  static const todo = Color(0xFFB0603A); // 腮红桃色系：要办的事
  static const todoSoft = Color(0xFFFBE7DC);
  static const todoBg = Color(0xFFFDF4EE);
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
  final bool halo; // 身后垫一个嫩芽色圆（照参考图）
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
              decoration: BoxDecoration(color: K.lime.withValues(alpha: 0.55), shape: BoxShape.circle)),
        ),
        Positioned(left: 0, bottom: 0, child: img),
      ]),
    );
  }
}

/// 分类的颜色：同一类永远同一个色，一眼分得开。
(Color, Color) categoryColors(String c) {
  const palette = [
    (Color(0xFFEDF3D3), Color(0xFF4F8A22)), // 嫩芽绿
    (Color(0xFFE2EEF0), Color(0xFF3B6E78)), // 雾蓝
    (Color(0xFFFBE7DC), Color(0xFFA9573A)), // 腮红桃
    (Color(0xFFF0E8F3), Color(0xFF7A5487)), // 浅紫
    (Color(0xFFFAE9C8), Color(0xFF94681C)), // 奶黄
    (Color(0xFFE3F0E4), Color(0xFF3F7A4A)), // 薄荷
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
