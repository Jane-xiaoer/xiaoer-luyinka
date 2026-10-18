// 设置：整理规则（交给 Agent 时带上）· 同步完删卡上的文件 · 云端地址（一般不用动）。
import 'package:flutter/material.dart';

import 'cloud.dart';
import 'handoff.dart';
import 'store.dart';
import 'sync.dart';
import 'theme.dart';

void showSettings(BuildContext context, Store store, Syncer syncer) {
  final rules = TextEditingController(text: (store.settings['rules'] as String?) ?? defaultRules);
  final cloud = TextEditingController(text: Cloud.instance?.base ?? '');
  var deleteAfter = store.settings['deleteAfter'] == true;
  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        backgroundColor: K.card,
        title: const Text('设置'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              const Text('整理规则（交给 Agent 时一起给它）', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: K.paper, borderRadius: BorderRadius.circular(10), border: Border.all(color: K.line)),
                child: TextField(controller: rules, maxLines: 9, minLines: 6, style: const TextStyle(fontSize: 14, height: 1.6)),
              ),
              const SizedBox(height: 14),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: deleteAfter,
                activeThumbColor: K.green,
                onChanged: (v) => set(() => deleteAfter = v),
                title: const Text('整理好以后，删掉卡上的原文件'),
                subtitle: const Text('给卡腾地方。整理好的内容和录音都留在这台设备上。', style: TextStyle(color: K.mute, fontSize: 13)),
              ),
              const SizedBox(height: 8),
              const Text('云端地址（一般不用动）', style: TextStyle(fontWeight: FontWeight.w600)),
              TextField(controller: cloud, style: const TextStyle(fontSize: 14, color: K.mute)),
              const SizedBox(height: 10),
              Text('卡：${syncer.card.info?.version ?? '还没连过'} · 剩余空间 ${syncer.card.info?.freeKb == null ? '—' : '${(syncer.card.info!.freeKb! / 1024 / 1024).toStringAsFixed(1)} GB'}',
                  style: const TextStyle(color: K.faint, fontSize: 13)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: K.green),
            onPressed: () {
              store.settings['rules'] = rules.text.trim();
              store.settings['deleteAfter'] = deleteAfter;
              final url = cloud.text.trim().replaceAll(RegExp(r'/+$'), '');
              if (url.isNotEmpty && url != Cloud.instance?.base) {
                store.settings['cloud'] = url;
                Cloud.instance?.base = url;
              }
              store.save();
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}
