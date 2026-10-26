// 左栏「录音豆」：把硬件上的录音管起来（布局参考 Soundcore Manager 的设备页）。
//   设备卡片：在不在 / 正在录音、序列号固件、开始停止录音、全部拉下来、清理已存好的
//   电量（豆子、充电盒两个圆环）+ 存储
//   设备上的录音：每条时长和走到哪一步；选哪条拉哪条；拉下来转写好先在这里看文字（「待你决定」），
//   用户定导入录音卡还是不要；导入了、原稿和转写都存好了（「已存好」）才能从豆子上删
import 'package:flutter/material.dart';

import '../rec_sheet.dart';

import '../store.dart';
import '../theme.dart';
import 'protocol.dart';
import 'sync.dart';

/// 一条录音走到第几步：0 还在豆子里 · 1 拉到本机 · 2 传到云端 · 3 转写 · 4 整理 · 5 都好了
int beanStep(Rec? r) => switch (r?.stage) {
  null => 0,
  'pulling' => 1,
  'pulled' || 'uploading' => 2,
  'processing' => 3,
  'review' || 'transcribed' || 'analyzing' => 4,
  'done' => 5,
  _ => 2, // error：多半卡在上传 / 转写
};

String beanDuration(int s) => recDuration(s);

class BeanView extends StatefulWidget {
  final BeanSyncer bean;
  final Store store;
  final void Function(Scene) onOpen;
  final double top;
  const BeanView({
    super.key,
    required this.bean,
    required this.store,
    required this.onOpen,
    this.top = 0,
  });

  @override
  State<BeanView> createState() => _BeanViewState();
}

class _BeanViewState extends State<BeanView> {
  BeanSyncer get bean => widget.bean;
  Store get store => widget.store;
  void Function(Scene) get onOpen => widget.onOpen;
  double get top => widget.top;

  /// 列表筛选：全部 / 待你决定 / 已导入 / 还没拉
  String _filter = '全部';
  String _kind(BeanFile f) => bean.reviewing(f)
      ? '待你决定'
      : bean.hasText(f)
      ? '已导入'
      : '还没拉';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([bean, store]),
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 1100;
      final pad = MediaQuery.sizeOf(context).width >= 900 ? 26.0 : 14.0;
      final files = bean.files.reversed
          .where((f) => !bean.skipped(f))
          .toList(); // 新的在上；空录音不显示（Jane：空的不要）
      return ListView(
        padding: EdgeInsets.fromLTRB(pad, top + 8, pad, 28),
        children: [
          _title(),
          const SizedBox(height: 14),
          if (wide)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: _device(context, files)),
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        _battery(),
                        const SizedBox(height: 14),
                        Expanded(child: _storage()),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else ...[
            _device(context, files),
            const SizedBox(height: 12),
            _battery(),
            const SizedBox(height: 12),
            _storage(),
          ],
          const SizedBox(height: 14),
          _list(context, files),
        ],
      );
    },
  );

  // ───────── 标题行 ─────────

  (String, Color) _status() {
    if (bean.off) return ('已暂停连接', K.faint);
    if (bean.connected)
      return (
        bean.info?.recording == true
            ? '正在录音…'
            : (bean.phase.isEmpty ? '已连接' : bean.phase),
        K.live,
      );
    if (bean.busy) return (bean.phase.isEmpty ? '正在找…' : bean.phase, K.todo);
    if (bean.mac == null) return ('还没连过', K.faint);
    if (bean.error != null) return ('上次没连成，点「刷新」再试', K.accent);
    if (bean.here == true && bean.lastSeen != null)
      return ('在旁边 · ${_hm(bean.lastSeen!)} 同步过', K.live);
    if (bean.here == null) return ('等着连…', K.faint);
    return ('不在旁边', K.faint);
  }

  Widget _title() {
    final (text, color) = _status();
    final fw = bean.info?.firmware;
    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('录音豆', style: K.title(24)),
            Text(
              '$text${fw == null ? '' : ' · $fw'}',
              style: TextStyle(color: color, fontSize: 12.5),
            ),
          ],
        ),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: bean.busy || bean.off ? null : bean.run,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('刷新'),
          style: OutlinedButton.styleFrom(
            foregroundColor: K.ink,
            side: BorderSide(color: K.lineStrong),
          ),
        ),
      ],
    );
  }

  // ───────── 设备卡片 ─────────

  Widget _card({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(18),
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: K.tile,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: K.line),
    ),
    child: child,
  );

  Widget _device(BuildContext context, List<BeanFile> files) {
    final (text, color) = _status();
    final i = bean.info;
    final saved = files.where(bean.savedSafely).toList();
    final canAct = !bean.busy && !bean.off;
    final recording = i?.recording == true;
    Widget meta(String k, String v) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: TextStyle(color: K.faint, fontSize: 11.5)),
        const SizedBox(height: 2),
        Text(
          v,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
      ],
    );
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 104,
                height: 104,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: K.blush,
                  shape: BoxShape.circle,
                ),
                child: K.cute
                    ? Mascot(bean.connected || bean.here == true ? 'stand' : 'sleep', size: 84)
                    : Icon(Icons.graphic_eq_rounded, size: 40, color: bean.connected || bean.here == true ? K.accent : K.faint),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('录音豆', style: K.title(22)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          text,
                          style: TextStyle(color: color, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '安克 AI 录音豆（D3200 · 飞书版）',
                      style: TextStyle(color: K.mute, fontSize: 12.5),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 22,
                      runSpacing: 8,
                      children: [
                        meta('序列号', i?.serial ?? '—'),
                        meta('固件', i?.firmware ?? '—'),
                        meta(
                          '上次连上',
                          bean.lastSeen == null ? '—' : _hm(bean.lastSeen!),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: canAct ? () => bean.setRecording(!recording) : null,
                icon: Icon(
                  recording
                      ? Icons.stop_rounded
                      : Icons.fiber_manual_record_rounded,
                  size: 18,
                ),
                label: Text(recording ? '停止录音' : '开始录音'),
                style: FilledButton.styleFrom(backgroundColor: K.live),
              ),
              OutlinedButton.icon(
                onPressed: canAct && files.any(bean.pullable)
                    ? bean.pullAll
                    : null,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('全部拉下来'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: K.ink,
                  side: BorderSide(color: K.lineStrong),
                ),
              ),
              OutlinedButton.icon(
                onPressed: canAct && saved.isNotEmpty
                    ? () => _confirmDelete(context, saved)
                    : null,
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                label: Text(
                  '清理已存好的${saved.isEmpty ? '' : '（${saved.length}）'}',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: K.ink,
                  side: BorderSide(color: K.lineStrong),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: Icon(Icons.more_horiz_rounded, color: K.mute),
                color: K.card,
                onSelected: (v) {
                  if (v == 'auto') bean.setAuto(!bean.auto);
                  if (v == 'off') bean.setOff(!bean.off);
                },
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(
                    value: 'auto',
                    checked: bean.auto,
                    child: const Text('连上就自动拉新录音'),
                  ),
                  PopupMenuItem(
                    value: 'off',
                    child: Text(bean.off ? '继续连接录音豆' : '暂停连接（在手机飞书里用它时）'),
                  ),
                ],
              ),
            ],
          ),
          if (bean.error != null) ...[
            const SizedBox(height: 8),
            Text(
              bean.error!,
              style: TextStyle(color: K.accent, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // ───────── 电量 / 存储 ─────────

  Widget _battery() {
    final i = bean.info;
    Widget ring(String name, int? pct, bool charging) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 64,
          height: 64,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: pct == null ? 0 : pct / 100,
                  strokeWidth: 6,
                  backgroundColor: K.cardDeep,
                  color: (pct ?? 100) <= 20 ? K.accent : K.live,
                ),
              ),
              Text(
                pct == null ? '—' : '$pct',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              pct == null ? '—' : '电量 $pct%${charging ? ' · 充电中' : ''}',
              style: TextStyle(color: K.mute, fontSize: 12),
            ),
          ],
        ),
      ],
    );
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('电量', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              ring('录音豆', i?.battery, i?.charging == true),
              ring('充电盒', i?.caseBattery, i?.caseCharging == true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _storage() {
    final i = bean.info;
    final used = i == null || i.totalKB == 0
        ? 0.0
        : (i.totalKB - i.freeKB) / i.totalKB;
    String gb(int kb) => kb >= 1024 * 1024
        ? '${(kb / 1024 / 1024).toStringAsFixed(1)} GB'
        : '${(kb / 1024).round()} MB';
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              const Text('设备存储', style: TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(
                i == null
                    ? '—'
                    : '${gb(i.totalKB - i.freeKB)} / ${gb(i.totalKB)}',
                style: TextStyle(color: K.mute, fontSize: 12.5),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: used.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: K.cardDeep,
              color: K.live,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                i == null ? '' : '已用 ${(used * 100).toStringAsFixed(1)}%',
                style: TextStyle(color: K.faint, fontSize: 12),
              ),
              const Spacer(),
              Text(
                i == null ? '' : '剩余 ${gb(i.freeKB)}',
                style: TextStyle(color: K.faint, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ───────── 设备上的录音 ─────────

  Widget _list(BuildContext context, List<BeanFile> files) => _card(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              '设备上的录音',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(width: 8),
            Text('${files.length}', style: TextStyle(color: K.faint)),
            const Spacer(),
            Flexible(
              child: Text(
                bean.listedAt == null ? '' : '读于 ${_hm(bean.listedAt!)}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: K.mute, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final k in const ['全部', '待你决定', '已导入', '还没拉'])
              ChoiceChip(
                label: Text(
                  '$k ${k == '全部' ? files.length : files.where((f) => _kind(f) == k).length}',
                ),
                selected: _filter == k,
                onSelected: (_) => setState(() => _filter = k),
                showCheckmark: false,
                selectedColor: K.cardDeep,
                side: BorderSide(color: K.line),
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  color: _filter == k ? K.ink : K.mute,
                  fontWeight: _filter == k ? FontWeight.w700 : FontWeight.w400,
                ),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (files.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text(
                bean.mac == null ? '还没连过录音豆：开着放在电脑旁边，点「刷新」' : '还没读到录音列表，点「刷新」',
                style: TextStyle(color: K.mute),
              ),
            ),
          ),
        for (final (k, f)
            in files
                .where((f) => _filter == '全部' || _kind(f) == _filter)
                .indexed) ...[
          if (k > 0) Divider(height: 1, color: K.line),
          _row(context, f),
        ],
      ],
    ),
  );

  Widget _row(BuildContext context, BeanFile f) {
    final r = bean.recOf(f);
    final t = f.start;
    String p2(int n) => n.toString().padLeft(2, '0');
    final (label, color, frac) = _state(f, r);
    final scenes = r?.stage == 'done'
        ? store.scenesOf(f.stem).where((s) => !s.noise).toList()
        : const <Scene>[];
    final text = bean.hasText(f)
        ? bean.lines(f).map((l) => l[1]).join(' ')
        : null;
    return InkWell(
      onTap: text == null ? null : () => _openDetail(context, f),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.graphic_eq_rounded,
                  color: f.recording ? K.accent : K.mute,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${t.year}-${p2(t.month)}-${p2(t.day)} ${p2(t.hour)}:${p2(t.minute)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            f.recording ? '正在录' : beanDuration(f.seconds),
                            style: TextStyle(
                              color: K.mute,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              label,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: color, fontSize: 12.5),
                            ),
                          ),
                        ],
                      ),
                      if (text != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          text.isEmpty ? '（没转出文字，可能没人说话；点开能听原声）' : text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: K.mute,
                            fontSize: 13.5,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                ..._actions(context, f, r, scenes),
              ],
            ),
            if (frac != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 34),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: frac,
                    minHeight: 4,
                    backgroundColor: K.cardDeep,
                    color: color,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// (状态字, 颜色, 进度 0–1；没有进度条给 null)
  (String, Color, double?) _state(BeanFile f, Rec? r) {
    if (f.recording) return ('录完再拉', K.accent, null);
    if (bean.savedSafely(f)) {
      final n = store.scenesOf(f.stem).where((s) => !s.noise).length;
      return ('已导入${n > 1 ? ' · $n 段' : ''}', K.live, null);
    }
    switch (r?.stage) {
      case null:
        return (
          bean.queued(f) ? '排队中' : '还没拉',
          bean.queued(f) ? K.todo : K.faint,
          null,
        );
      case 'pulling':
        final frac = r!.size > 0 ? (r.got / r.size).clamp(0.0, 1.0) : null;
        final left = r.size - r.got;
        final eta = r.bps > 0 && left > 0
            ? ' · 约剩 ${(left / r.bps / 60).ceil()} 分钟'
            : (bean.connected ? '' : ' · 断了，下次接着拉');
        return ('拉取中 ${((frac ?? 0) * 100).round()}%$eta', K.todo, frac);
      case 'pulled' || 'uploading':
        return ('传到云端…', K.todo, null);
      case 'processing':
        return ('云端转写 ${r!.progress}%', K.todo, r.progress / 100);
      case 'review':
        return ('待你决定', K.ink, null);
      case 'transcribed':
        return ('等着整理', K.todo, null);
      case 'analyzing':
        return ('整理中 ${r!.progress}%', K.todo, r.progress / 100);
      case 'done':
        return ('原稿不全，先别删', K.accent, null);
      default:
        return (
          '出错了，稍后再试',
          K.accent,
          null,
        );
    }
  }

  List<Widget> _actions(
    BuildContext context,
    BeanFile f,
    Rec? r,
    List<Scene> scenes,
  ) {
    final canAct = !bean.busy && !bean.off;
    final pill = OutlinedButton.styleFrom(
      foregroundColor: K.ink,
      side: BorderSide(color: K.lineStrong),
      visualDensity: VisualDensity.compact,
    );
    if (f.recording) return const [];
    final look = OutlinedButton.icon(
      onPressed: () => _openDetail(context, f),
      icon: const Icon(Icons.subject_rounded, size: 16),
      label: const Text('看看'),
      style: pill,
    );
    Widget bin(String tip, VoidCallback go) => IconButton(
      tooltip: tip,
      onPressed: canAct ? go : null,
      icon: Icon(Icons.delete_outline_rounded, color: K.accent, size: 20),
    );
    if (bean.reviewing(f)) {
      return [
        look,
        const SizedBox(width: 6),
        FilledButton(
          onPressed: () => bean.moveIn(f),
          style: FilledButton.styleFrom(
            backgroundColor: K.ink,
            foregroundColor: K.card,
            visualDensity: VisualDensity.compact,
          ),
          child: const Text('导入录音卡'),
        ),
        bin('不要了：豆子上删掉，电脑里也不留', () => _confirmDiscard(context, f)),
      ];
    }
    if (bean.savedSafely(f)) {
      return [
        if (bean.hasText(f)) look,
        if (scenes.isNotEmpty)
          TextButton.icon(
            onPressed: () => onOpen(scenes.first),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('打开'),
            style: TextButton.styleFrom(foregroundColor: K.ink),
          ),
        bin('从录音豆上删掉（录音卡里的原稿和转写不受影响）', () => _confirmDelete(context, [f])),
      ];
    }
    final del = Tooltip(
      message: '先拉下来看看内容才能删',
      child: IconButton(
        onPressed: null,
        icon: Icon(
          Icons.delete_outline_rounded,
          color: K.faint.withValues(alpha: 0.5),
          size: 20,
        ),
      ),
    );
    if (bean.hasText(f)) return [look, del]; // 正在整理进录音卡：能看，整理完才能删
    if (r == null && !bean.queued(f)) {
      return [
        OutlinedButton.icon(
          onPressed: bean.off ? null : () => bean.pull(f),
          icon: const Icon(Icons.download_rounded, size: 16),
          label: const Text('拉下来看看'),
          style: pill,
        ),
        del,
      ];
    }
    return [del];
  }

  /// 点开一条：右边滑出详情（全文、播放、导入 / 不要了 / 删）。
  void _openDetail(BuildContext context, BeanFile f) {
    final red = OutlinedButton.styleFrom(
      foregroundColor: K.accent,
      side: BorderSide(color: K.lineStrong),
    );
    final dark = FilledButton.styleFrom(
      backgroundColor: K.ink,
      foregroundColor: K.card,
    );
    openRecSheet(
      context,
      store: store,
      stem: f.stem,
      listen: bean,
      start: f.start,
      seconds: f.seconds,
      status: () {
        final st = bean.recOf(f)?.stage;
        return bean.reviewing(f)
            ? '待你决定'
            : bean.savedSafely(f)
            ? '已导入录音卡'
            : st == 'transcribed' || st == 'analyzing'
            ? '正在整理进录音卡…'
            : '';
      },
      hint: () => bean.reviewing(f)
          ? '导入：按类别整理进录音卡（带「录音豆」来源）· 不要了：豆子上和电脑里都删掉'
          : bean.savedSafely(f)
          ? '录音卡里原稿和转写都在，豆子上的可以放心删'
          : null,
      actions: (c) {
        final canAct = !bean.busy && !bean.off;
        final scenes = store.scenesOf(f.stem).where((s) => !s.noise).toList();
        return [
          if (bean.reviewing(f)) ...[
            FilledButton.icon(
              onPressed: () => bean.moveIn(f),
              icon: const Icon(Icons.move_to_inbox_rounded, size: 18),
              label: const Text('导入录音卡'),
              style: dark,
            ),
            OutlinedButton.icon(
              onPressed: canAct
                  ? () => _confirmDiscard(c, f, close: true)
                  : null,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('不要了'),
              style: red,
            ),
          ],
          if (bean.savedSafely(f)) ...[
            if (scenes.isNotEmpty)
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(c);
                  onOpen(scenes.first);
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('在录音卡里打开'),
                style: dark,
              ),
            OutlinedButton.icon(
              onPressed: canAct ? () => _confirmDelete(c, [f]) : null,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('从豆子上删'),
              style: red,
            ),
          ],
        ];
      },
    );
  }

  Future<void> _confirmDiscard(
    BuildContext context,
    BeanFile f, {
    bool close = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: K.card,
        title: const Text('这条不要了？'),
        content: Text(
          '从录音豆上删掉这条录音（${beanDuration(f.seconds)}），拉下来的音频和文字也一起丢掉，不导入录音卡。'
          '删了飞书里也看不到了，不能撤回。',
          style: const TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('不要了', style: TextStyle(color: K.accent)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final done = await bean.discard(f);
    if (!context.mounted) return;
    if (done && close) Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(done ? '删掉了' : '没删成：录音豆不在旁边或没回话，什么都没动')),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    List<BeanFile> which,
  ) async {
    final total = which.fold<int>(0, (a, f) => a + f.seconds);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: K.card,
        title: Text(
          which.length == 1 ? '从录音豆上删掉这条？' : '从录音豆上删掉 ${which.length} 条？',
        ),
        content: Text(
          '这${which.length == 1 ? '条' : '些'}录音（共 ${beanDuration(total)}）在录音卡里已经存好原稿音频和转写稿，'
          '删掉的只是录音豆上的，录音卡里的不受影响。删了飞书里也看不到了，不能撤回。',
          style: const TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('不删'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('删掉', style: TextStyle(color: K.accent)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final n = await bean.delete(which);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          n == which.length
              ? '删掉了 $n 条'
              : '删掉了 $n 条，另外 ${which.length - n} 条没删成（录音豆不在旁边或没回话）',
        ),
      ),
    );
  }
}
