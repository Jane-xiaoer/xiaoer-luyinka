// 点开一条录音看内容（录音卡 / 录音豆两页共用）：右边滑出来，上面是这条的情况和能做的事，
// 中间播放原声，下面全文；点哪句从哪句开始播，正在播的那句高亮。
import 'package:flutter/material.dart';

import 'home.dart' show Player;
import 'store.dart';
import 'theme.dart';

/// 滑出一条录音的详情。[listen] 变了就重画（状态、按钮跟着变）；[actions] / [hint] 按当时的状态给。
Future<void> openRecSheet(
  BuildContext context, {
  required Store store,
  required String stem,
  required Listenable listen,
  required DateTime start,
  required int seconds,
  required String Function() status,
  required List<Widget> Function(BuildContext sheet) actions,
  String? Function()? hint,
}) => showGeneralDialog(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭',
  barrierColor: Colors.black26,
  transitionDuration: const Duration(milliseconds: 220),
  pageBuilder: (c, _, _) => Align(
    alignment: Alignment.centerRight,
    child: SizedBox(
      width: MediaQuery.sizeOf(c).width.clamp(0, 600).toDouble(),
      height: double.infinity,
      child: RecSheet(
        store: store,
        stem: stem,
        listen: listen,
        start: start,
        seconds: seconds,
        status: status,
        actions: actions,
        hint: hint,
      ),
    ),
  ),
  transitionBuilder: (_, a, _, child) => SlideTransition(
    position: Tween(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
    child: child,
  ),
);

String recDuration(int s) {
  String p(int n) => n.toString().padLeft(2, '0');
  return s >= 3600
      ? '${s ~/ 3600}:${p(s % 3600 ~/ 60)}:${p(s % 60)}'
      : '${p(s ~/ 60)}:${p(s % 60)}';
}

/// 这条转写出来的文字：[[钟点, 文字], …]（还没转写就是空的）
List<List<String>> recLines(Store store, String stem) => [
  for (final x in (store.peekResult(stem)?['lines'] as List? ?? const []))
    List<String>.from(x),
];

class RecSheet extends StatefulWidget {
  final Store store;
  final String stem;
  final Listenable listen;
  final DateTime start;
  final int seconds;
  final String Function() status;
  final List<Widget> Function(BuildContext sheet) actions;
  final String? Function()? hint;
  const RecSheet({
    super.key,
    required this.store,
    required this.stem,
    required this.listen,
    required this.start,
    required this.seconds,
    required this.status,
    required this.actions,
    this.hint,
  });

  @override
  State<RecSheet> createState() => _RecSheetState();
}

class _RecSheetState extends State<RecSheet> {
  final _player = Player();

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  /// 这句离开录多少秒：钟点减开录的钟点（跨零点也对）
  double _offset(String clock) {
    int secs(String c) {
      final p = c.split(':').map(int.parse).toList();
      return p[0] * 3600 + p[1] * 60 + (p.length > 2 ? p[2] : 0);
    }

    final start = (widget.store.peekResult(widget.stem)?['start'] ?? '')
        .toString();
    if (start.length < 19) return 0;
    try {
      return ((secs(clock) - secs(start.substring(11, 19)) + 86400) % 86400)
          .toDouble();
    } catch (_) {
      return 0;
    }
  }

  void _play(double at) => _player.play(widget.store, widget.stem, at, '');

  String _t(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Material(
    color: K.panel,
    elevation: 8,
    child: SafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.listen, widget.store, _player]),
        builder: (context, _) {
          final t = widget.start;
          String p2(int n) => n.toString().padLeft(2, '0');
          final lines = recLines(widget.store, widget.stem);
          final hasAudio = widget.store.audio(widget.stem).existsSync();
          final mine = _player.stem == widget.stem;
          final at = mine ? _player.pos.inMilliseconds / 1000 : -1.0;
          var cur = -1; // 正在播的那句
          for (var i = 0; i < lines.length; i++) {
            if (at >= _offset(lines[i][0])) cur = i;
          }
          final status = widget.status();
          final actions = widget.actions(context);
          final hint = widget.hint?.call();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${t.month} 月 ${t.day} 日 ${p2(t.hour)}:${p2(t.minute)}',
                            style: K.title(24).copyWith(color: K.ink),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${sourceOf(widget.stem)} · ${recDuration(widget.seconds)}${status.isEmpty ? '' : ' · $status'}',
                            style: TextStyle(color: K.mute, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close_rounded, color: K.mute),
                    ),
                  ],
                ),
              ),
              if (actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 4),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: actions,
                  ),
                ),
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
                  child: Text(
                    hint,
                    style: TextStyle(color: K.faint, fontSize: 12),
                  ),
                ),
              if (hasAudio)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: K.card,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      IconButton.filled(
                        style: IconButton.styleFrom(backgroundColor: K.strong),
                        tooltip: mine && _player.playing ? '暂停' : '播放原声',
                        onPressed: () => mine ? _player.toggle() : _play(0),
                        icon: Icon(
                          mine && _player.playing
                              ? Icons.pause
                              : Icons.play_arrow,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _t(mine ? _player.pos : Duration.zero),
                        style: TextStyle(fontSize: 12.5, color: K.mute),
                      ),
                      Expanded(
                        child: Slider(
                          activeColor: K.accent,
                          inactiveColor: K.lineStrong,
                          value: !mine || _player.total.inMilliseconds == 0
                              ? 0
                              : (_player.pos.inMilliseconds /
                                        _player.total.inMilliseconds)
                                    .clamp(0, 1)
                                    .toDouble(),
                          onChanged: mine ? _player.seekTo : null,
                        ),
                      ),
                      Text(
                        recDuration(widget.seconds),
                        style: TextStyle(fontSize: 12.5, color: K.mute),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              if (lines.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(24, 8, 24, 4),
                  child: Text(
                    '点哪句，就从哪句开始播',
                    style: TextStyle(color: K.faint, fontSize: 12),
                  ),
                ),
              Expanded(
                child: lines.isEmpty
                    ? Center(
                        child: Text(
                          hasAudio
                              ? '没转出文字（可能没人说话），可以听一下原声'
                              : '还没转成文字：拉下来、转写好了这里就能看',
                          style: TextStyle(color: K.mute),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: lines.length,
                        itemBuilder: (_, i) => InkWell(
                          onTap: hasAudio
                              ? () => _play(_offset(lines[i][0]))
                              : null,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: i == cur ? K.cardDeep : null,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 66,
                                  child: Text(
                                    lines[i][0],
                                    style: TextStyle(
                                      color: K.faint,
                                      fontSize: 12.5,
                                      height: 1.75,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    lines[i][1],
                                    style: TextStyle(
                                      color: K.ink,
                                      fontSize: 14.5,
                                      height: 1.65,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
