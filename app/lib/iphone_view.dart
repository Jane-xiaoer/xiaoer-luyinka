// 设置 →「设备与云端」里的「iPhone 语音备忘录」：开关、收到哪了、文件夹读不了时怎么开，
// 还有「挑以前的录音导入」（起点之前的不自动收，用户自己勾）。只有 Mac 有。
import 'dart:io';

import 'package:flutter/material.dart';

import 'iphone.dart';
import 'theme.dart';

const memoHowTo = '打开同步：iPhone「设置 → 你的名字 → iCloud → 语音备忘录」打开；'
    'Mac「系统设置 → Apple 账户 → iCloud → 语音备忘录」打开。同步过来后这里会自动收。';
// 2026-11-04 实测（macOS 26）：读别的 App 的数据，系统不弹框，直接不让读，只能在「完全磁盘访问权限」里手动打开。
const memoDeniedHowTo = 'macOS 默认不让别的 App 读语音备忘录，要给录音卡开一次「完全磁盘访问权限」：'
    '点「去打开」，在列表里打开「小耳录音卡」（列表里没有就点左下「+」，在「应用程序」里选它），然后退出录音卡再打开一次。';

/// 打开「系统设置 → 隐私与安全性 → 完全磁盘访问权限」那一页
Future<void> openFullDiskAccess() =>
    Process.run('/usr/bin/open', ['x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles']);

/// 第一次发现读不了语音备忘录：主动问一次（只问一次，以后在设置里看得到、点得到）。
Future<void> askMemoAccess(BuildContext context, VoiceMemoSyncer memos) async {
  if (memos.off || memos.problem?.denied != true || memos.store.settings['iphoneAsked'] == true) return;
  memos.store.settings['iphoneAsked'] = true;
  await memos.store.save();
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('接上 iPhone 语音备忘录'),
      content: const Text(memoDeniedHowTo, style: TextStyle(height: 1.6)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('以后再说')),
        FilledButton(
          onPressed: () {
            Navigator.pop(c);
            openFullDiskAccess();
          },
          child: const Text('去打开'),
        ),
      ],
    ),
  );
}

/// 状态一行：最近收到哪条、几条，或者为什么还没有。
String memoStatus(VoiceMemoSyncer s) {
  final p = s.problem;
  if (p != null) return p.denied ? memoDeniedHowTo : '这台 Mac 上还没有语音备忘录。$memoHowTo';
  if (s.off) return '已关闭：iPhone 上新录的不会收进来';
  final n = s.taken.length, last = s.last;
  final wait = s.waiting > 0 ? '；有 ${s.waiting} 条正在从 iCloud 下载，下完了再收' : '';
  if (n == 0) {
    final since = s.since;
    return '还没同步过来。iPhone 上${since == null ? '' : ' ${_md(since)} 之后'}新录的，iCloud 同步到这台 Mac 就自动收进来$wait';
  }
  final at = DateTime.tryParse('${last['at'] ?? ''}');
  return '最近收到：「${last['title'] ?? ''}」${at == null ? '' : '（${_md(at)}）'} · 一共收了 $n 条$wait';
}

class MemoSettings extends StatelessWidget {
  final VoiceMemoSyncer memos;
  const MemoSettings(this.memos, {super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: memos,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: !memos.off,
            activeThumbColor: K.accent,
            onChanged: (v) => memos.setOff(!v),
            secondary: Icon(Icons.phone_iphone_rounded, color: K.mute),
            title: const Text('iPhone 语音备忘录'),
            subtitle: Text('iPhone「语音备忘录」新录的，自动收进来转写、整理（只读，不会改动 iPhone 上的录音）',
                style: TextStyle(fontSize: 12.5, color: K.faint)),
          ),
          Text(memoStatus(memos),
              style: TextStyle(fontSize: 13, height: 1.5, color: memos.problem != null ? K.accent : K.mute)),
          if (memos.problem?.denied == true)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: openFullDiskAccess,
                icon: const Icon(Icons.lock_open_rounded, size: 18),
                label: const Text('去打开'),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => showMemoPicker(context, memos),
              icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
              label: const Text('挑以前的录音导入'),
            ),
          ),
        ]),
      );
}

Future<void> showMemoPicker(BuildContext context, VoiceMemoSyncer memos) =>
    showDialog(context: context, builder: (_) => MemoPicker(memos));

/// 起点之前的语音备忘录：勾上的导入（转写、整理）。
class MemoPicker extends StatefulWidget {
  final VoiceMemoSyncer memos;
  final Future<List<Memo>>? list; // 已经读好的（测试用）；没给就打开时读
  const MemoPicker(this.memos, {super.key, this.list});
  @override
  State<MemoPicker> createState() => _MemoPickerState();
}

class _MemoPickerState extends State<MemoPicker> {
  VoiceMemoSyncer get memos => widget.memos;
  late final Future<List<Memo>> _list = widget.list ?? memos.before();
  final _on = <String>{};
  List<Memo>? _loaded;

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: K.card,
        title: const Text('挑以前的录音导入'),
        content: SizedBox(
          width: 560,
          height: 440,
          child: FutureBuilder<List<Memo>>(
            future: _list,
            builder: (context, snap) {
              if (snap.hasError) {
                final e = snap.error;
                return Text(e is MemoError && e.denied ? memoDeniedHowTo : '这台 Mac 上还没有语音备忘录。$memoHowTo',
                    style: TextStyle(height: 1.6, color: K.mute));
              }
              final l = _loaded = snap.data;
              if (l == null) return const Center(child: CircularProgressIndicator());
              if (l.isEmpty) return Text('没有以前的录音', style: TextStyle(color: K.mute));
              final taken = memos.taken, queued = memos.queue;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('共 ${l.length} 条（打开这功能之前录的）。勾上的会转写、按类别整理，长的一条要几分钟。',
                    style: TextStyle(fontSize: 13, color: K.faint)),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: l.length,
                    itemBuilder: (_, i) {
                      final m = l[i];
                      final done = taken.contains(m.path), wait = queued.contains(m.path);
                      final note = done
                          ? ' · 已导入'
                          : wait
                              ? ' · 排着，下完了就导入'
                              : m.present
                                  ? ''
                                  : ' · 还在 iCloud 上';
                      return CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: K.accent,
                        value: done || wait || _on.contains(m.path),
                        onChanged: done || wait ? null : (v) => setState(() => v == true ? _on.add(m.path) : _on.remove(m.path)),
                        title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${_ymd(m.wall)} · ${memoDuration(m.seconds)}$note',
                            style: TextStyle(fontSize: 12, color: K.faint)),
                      );
                    },
                  ),
                ),
              ]);
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: K.cta),
            onPressed: _on.isEmpty
                ? null
                : () {
                    final pick = [for (final m in _loaded ?? const <Memo>[]) if (_on.contains(m.path)) m];
                    Navigator.pop(context);
                    memos.pick(pick);
                  },
            child: Text(_on.isEmpty ? '导入' : '导入 ${_on.length} 条'),
          ),
        ],
      );
}

/// 62 秒 → 1 分 2 秒；1 小时以上 → 1 小时 14 分
String memoDuration(double secs) {
  if (secs <= 0) return '时长不知道';
  final s = secs.round();
  if (s < 60) return '$s 秒';
  if (s < 3600) return '${s ~/ 60} 分${s % 60 == 0 ? '' : ' ${s % 60} 秒'}';
  return '${s ~/ 3600} 小时${s % 3600 ~/ 60 == 0 ? '' : ' ${s % 3600 ~/ 60} 分'}';
}

String _p2(int n) => n.toString().padLeft(2, '0');
String _md(DateTime t) => '${_p2(t.month)}-${_p2(t.day)} ${_p2(t.hour)}:${_p2(t.minute)}';
String _ymd(DateTime t) => '${t.year}-${_p2(t.month)}-${_p2(t.day)} ${_p2(t.hour)}:${_p2(t.minute)}';
