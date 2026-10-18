// 选卡：列出附近所有的卡，点哪张就认准哪张（第一次就扫到好几张 / 设置里「换一张卡」）。
import 'package:flutter/material.dart';

import 'sync.dart';
import 'theme.dart';

void showCardPicker(BuildContext context, Syncer syncer) {
  List<CardChoice>? seen = syncer.card.choices.isEmpty ? null : syncer.card.choices;
  var scanning = false, started = false;
  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      Future<void> rescan() async {
        set(() => scanning = true);
        final l = await syncer.scanNearby();
        if (ctx.mounted) {
          set(() {
            seen = l;
            scanning = false;
          });
        }
      }

      if (seen == null && !started) {
        started = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => rescan());
      }
      final list = seen ?? [];
      return AlertDialog(
        backgroundColor: K.card,
        title: const Text('选你的录音卡'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('把你的卡拿到设备旁边，一般排第一个、标着「最近」的就是。选好以后只连这一张。',
                style: TextStyle(color: K.mute, fontSize: 13, height: 1.5)),
            const SizedBox(height: 12),
            if (scanning)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Row(children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: K.green)),
                  SizedBox(width: 10),
                  Text('正在找附近的卡…', style: TextStyle(color: K.mute)),
                ]),
              )
            else if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text('附近没找到卡。确认卡开着机、没在录音，再找一次。', style: TextStyle(color: K.mute)),
              )
            else
              for (final (i, c) in list.indexed)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  leading: Icon(Icons.graphic_eq, color: c.id == syncer.boundId ? K.green : K.mute),
                  title: Text(c.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    [if (i == 0 && list.length > 1) '最近', if (c.id == syncer.boundId) '现在用的', _near(c.rssi)].join(' · '),
                    style: const TextStyle(color: K.faint, fontSize: 12),
                  ),
                  onTap: () {
                    syncer.bind(c);
                    Navigator.pop(ctx);
                  },
                ),
          ]),
        ),
        actions: [
          TextButton(onPressed: scanning ? null : rescan, child: const Text('再找一次')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      );
    }),
  );
}

String _near(int? rssi) {
  if (rssi == null) return '信号未知';
  if (rssi > -60) return '就在旁边';
  if (rssi > -78) return '不远';
  return '有点远';
}
