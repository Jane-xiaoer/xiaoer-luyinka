// 左栏「录音卡」：跟录音豆一样，把卡上的录音摆出来——卡在不在、电量存储，
// 卡上有哪些、拉到哪一步了、哪些已经导入录音卡；点开能看全文、听原声。
// 卡的录音还是自动拉、自动导入（原来的流程不变），这里只是让人看得见。
import 'package:flutter/material.dart';

import '../cards.dart';
import 'client.dart' show CardInfo;
import '../home.dart' show cardStatus, pullLine;
import '../rec_sheet.dart';
import '../store.dart';
import '../sync.dart';
import '../theme.dart';

/// 卡上录音的名字是开录时刻（2026-10-18 07.40.00）
DateTime cardStemTime(Store store, String stem) {
  final m = RegExp(r'^(\d{4}-\d{2}-\d{2}) (\d{2})\.(\d{2})\.(\d{2})')
      .firstMatch(stem);
  if (m != null) return DateTime.parse('${m[1]}T${m[2]}:${m[3]}:${m[4]}');
  final s = (store.peekResult(stem)?['start'] ?? '').toString();
  return DateTime.tryParse(s.length >= 19 ? s.substring(0, 19) : s) ??
      DateTime(2000);
}

class CardView extends StatefulWidget {
  final Syncer syncer;
  final Store store;
  final void Function(Scene) onOpen;
  final double top;
  const CardView({
    super.key,
    required this.syncer,
    required this.store,
    required this.onOpen,
    this.top = 0,
  });

  @override
  State<CardView> createState() => _CardViewState();
}

class _CardViewState extends State<CardView> {
  Syncer get syncer => widget.syncer;
  Store get store => widget.store;
  String _filter = '全部';

  /// 多长（秒）：转写好了按云端给的，没转写按卡上的大小（每秒 2000 字节）
  int _seconds(Rec r) =>
      (store.peekResult(r.stem)?['seconds'] as num?)?.round() ?? r.size ~/ 2000;

  bool _hasText(Rec r) => store.peekResult(r.stem) != null;
  bool _onCard(Rec r) => !r.deletedOnCard;
  String _kind(Rec r) => r.stage == 'done'
      ? '已导入'
      : r.stage == 'card'
      ? '还在卡上'
      : '处理中';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final pad = MediaQuery.sizeOf(context).width >= 900 ? 26.0 : 14.0;
      final wide = MediaQuery.sizeOf(context).width >= 1100;
      // 正在走流程的 + 早就导入好的（导入好的同步记录可能已经清掉了，从资料里补出来）
      final recs =
          [
            ...store.recs.values.where((r) => sourceOf(r.stem) == '录音卡'),
            for (final stem in store.stems)
              if (sourceOf(stem) == '录音卡' && !store.recs.containsKey(stem))
                Rec(stem, 0, 'done')..deletedOnCard = true,
          ]..sort(
            (a, b) => cardStemTime(
              store,
              b.stem,
            ).compareTo(cardStemTime(store, a.stem)),
          );
      return ListView(
        padding: EdgeInsets.fromLTRB(pad, widget.top + 8, pad, 28),
        children: [
          _title(),
          const SizedBox(height: 14),
          if (wide)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: _device(context, recs)),
                  const SizedBox(width: 14),
                  Expanded(flex: 2, child: _battery()),
                ],
              ),
            )
          else ...[
            _device(context, recs),
            const SizedBox(height: 12),
            _battery(),
          ],
          const SizedBox(height: 14),
          _list(context, recs),
        ],
      );
    },
  );

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

  /// 卡的电量 / 存储：这次连上读的，没有就用上次记下的
  CardInfo? get _info {
    if (syncer.card.info != null) return syncer.card.info;
    final x = store.settings['cardInfo'];
    return x is List && x.length >= 4 ? CardInfo(x[0], x[1], x[2], x[3]) : null;
  }

  bool get _here => syncer.card.connected || syncer.card.lastSeen != null;

  Widget _title() {
    final (_, sub) = cardStatus(syncer, store);
    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('录音卡', style: K.title(24)),
            Text(
              sub,
              style: TextStyle(color: _here ? K.live : K.faint, fontSize: 12.5),
            ),
          ],
        ),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: () => syncer.run(),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('现在同步'),
          style: OutlinedButton.styleFrom(
            foregroundColor: K.ink,
            side: BorderSide(color: K.lineStrong),
          ),
        ),
      ],
    );
  }

  Widget _device(BuildContext context, List<Rec> recs) {
    final (title, sub) = cardStatus(syncer, store);
    final i = _info;
    final last = syncer.card.lastSeen;
    String hm(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
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
    final deleteAfter = store.settings['deleteAfter'] == true;
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
                    ? Mascot(_here ? 'stand' : 'sleep', size: 84)
                    : Icon(Icons.sd_card_outlined, size: 40, color: _here ? K.accent : K.faint),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: K.title(22)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _here ? K.live : K.faint,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            sub,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _here ? K.live : K.faint,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '小耳录音卡',
                      style: TextStyle(color: K.mute, fontSize: 12.5),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 22,
                      runSpacing: 8,
                      children: [
                        meta('固件', i?.version ?? '—'),
                        meta('上次连上', last == null ? '—' : hm(last)),
                        meta('卡上还留着', '${recs.where(_onCard).length} 条'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                label: const Text('导入后从卡上删'),
                selected: deleteAfter,
                onSelected: (v) {
                  store.settings['deleteAfter'] = v;
                  store.save();
                  setState(() {});
                },
                selectedColor: K.picked,
                side: BorderSide(color: K.line),
                visualDensity: VisualDensity.compact,
              ),
              TextButton.icon(
                onPressed: () => showCardPicker(context, syncer),
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: const Text('换一张卡'),
                style: TextButton.styleFrom(foregroundColor: K.mute),
              ),
            ],
          ),
          if (syncer.card.error != null) ...[
            const SizedBox(height: 6),
            Text(
              syncer.card.error!,
              style: TextStyle(color: K.accent, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _battery() {
    final i = _info;
    final pct = i?.battery == null
        ? null
        : (i!.charging ? 100 : i.battery!.clamp(0, 100));
    final used = i?.totalKb == null || i!.totalKb == 0
        ? null
        : (i.totalKb! - (i.freeKb ?? 0)) / i.totalKb!;
    String gb(int kb) => kb >= 1024 * 1024
        ? '${(kb / 1024 / 1024).toStringAsFixed(1)} GB'
        : '${(kb / 1024).round()} MB';
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('电量 · 存储', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Row(
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
              Text(
                pct == null ? '连上才知道' : (i!.charging ? '充电中' : '电量 $pct%'),
                style: TextStyle(color: K.mute, fontSize: 12.5),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: (used ?? 0).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: K.cardDeep,
              color: K.live,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            used == null
                ? '存储：连上才知道'
                : '已用 ${gb(i!.totalKb! - (i.freeKb ?? 0))} / ${gb(i.totalKb!)}',
            style: TextStyle(color: K.faint, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ───────── 卡上来的录音 ─────────

  Widget _list(BuildContext context, List<Rec> recs) {
    final shown = recs
        .where((r) => _filter == '全部' || _kind(r) == _filter)
        .toList();
    return _card(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                '卡上来的录音',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
              const SizedBox(width: 8),
              Text('${recs.length}', style: TextStyle(color: K.faint)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final k in const ['全部', '还在卡上', '处理中', '已导入'])
                ChoiceChip(
                  label: Text(
                    '$k ${k == '全部' ? recs.length : recs.where((r) => _kind(r) == k).length}',
                  ),
                  selected: _filter == k,
                  onSelected: (_) => setState(() => _filter = k),
                  showCheckmark: false,
                  selectedColor: K.picked,
                  side: BorderSide(color: K.line),
                  labelStyle: TextStyle(
                    fontSize: 12.5,
                    color: _filter == k ? K.ink : K.mute,
                    fontWeight: _filter == k
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 4),
          if (shown.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text('这里还没有', style: TextStyle(color: K.mute)),
              ),
            ),
          for (final (k, r) in shown.indexed) ...[
            if (k > 0) Divider(height: 1, color: K.line),
            _row(context, r),
          ],
        ],
      ),
    );
  }

  (String, Color, double?) _state(Rec r) => switch (r.stage) {
    'card' => ('在卡上', K.faint, null),
    'pulling' => (
      pullLine(r),
      K.todo,
      r.size > 0 ? (r.got / r.size).clamp(0.0, 1.0) : null,
    ),
    'pulled' || 'uploading' => ('传到云端…', K.todo, null),
    'processing' => ('云端转写 ${r.progress}%', K.todo, r.progress / 100),
    'transcribed' => (r.error ?? '等着整理', K.todo, null),
    'analyzing' => ('整理中 ${r.progress}%', K.todo, r.progress / 100),
    'done' => (_onCard(r) ? '已导入 · 卡上还留着' : '已导入', K.live, null),
    _ => ('出错了，稍后再试', K.accent, null),
  };

  void _open(BuildContext context, Rec r) {
    final t = cardStemTime(store, r.stem);
    openRecSheet(
      context,
      store: store,
      stem: r.stem,
      listen: store,
      start: t,
      seconds: _seconds(r),
      status: () => _state(r).$1,
      actions: (c) {
        final scenes = store.scenesOf(r.stem).where((s) => !s.noise).toList();
        return [
          if (scenes.isNotEmpty)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(c);
                widget.onOpen(scenes.first);
              },
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(
                scenes.length > 1
                    ? '在录音卡里打开（整理成 ${scenes.length} 段）'
                    : '在录音卡里打开',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: K.strong,
                foregroundColor: K.onStrong,
              ),
            ),
        ];
      },
    );
  }

  Widget _row(BuildContext context, Rec r) {
    final t = cardStemTime(store, r.stem);
    String p2(int n) => n.toString().padLeft(2, '0');
    final (label, color, frac) = _state(r);
    final has = _hasText(r);
    final text = has
        ? recLines(store, r.stem).map((l) => l[1]).join(' ')
        : null;
    final scenes = r.stage == 'done'
        ? store.scenesOf(r.stem).where((s) => !s.noise).toList()
        : const <Scene>[];
    final pill = OutlinedButton.styleFrom(
      foregroundColor: K.ink,
      side: BorderSide(color: K.lineStrong),
      visualDensity: VisualDensity.compact,
    );
    return InkWell(
      onTap: has ? () => _open(context, r) : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.sd_card_outlined, color: K.mute, size: 22),
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
                            recDuration(_seconds(r)),
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
                      if (scenes.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          scenes.map((s) => s.title).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: K.ink,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      if (text != null && text.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          text,
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
                if (has)
                  OutlinedButton.icon(
                    onPressed: () => _open(context, r),
                    icon: const Icon(Icons.subject_rounded, size: 16),
                    label: const Text('看看'),
                    style: pill,
                  ),
                if (scenes.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => widget.onOpen(scenes.first),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('打开'),
                    style: TextButton.styleFrom(foregroundColor: K.ink),
                  ),
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
}
