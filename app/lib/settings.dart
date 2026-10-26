// 设置：整理用的模型（小耳提供 / 自己的 key）· 资料文件夹 · 整理规则（交给 Agent 时带上）· 同步完删卡上的文件 · 云端地址。
import 'dart:io';

import 'package:flutter/material.dart';

import 'cards.dart';
import 'cloud.dart';
import 'handoff.dart';
import 'live_view.dart' show VocabDialog;
import 'llm.dart';
import 'store.dart';
import 'sync.dart';
import 'templates.dart';
import 'theme.dart';

void showSettings(BuildContext context, Store store, Syncer syncer) {
  final rules = TextEditingController(text: (store.settings['rules'] as String?) ?? defaultRules);
  final cloud = TextEditingController(text: Cloud.instance?.base ?? '');
  var deleteAfter = store.settings['deleteAfter'] == true;
  final m = Map<String, dynamic>.from(store.settings['llm'] ?? {});
  var own = m['own'] == true;
  var provider = (m['provider'] as String?) ?? providers.first.name;
  final base = TextEditingController(text: (m['base'] as String?) ?? providers.first.base);
  final key = TextEditingController(text: (m['key'] as String?) ?? '');
  final model = TextEditingController(text: (m['model'] as String?) ?? providers.first.model);
  String? test; // 「试一下」的结果
  var testing = false;
  final folder = TextEditingController(text: store.lib.path);
  Map<String, dynamic> llmSettings() =>
      {'own': own, 'provider': provider, 'base': base.text.trim(), 'key': key.text.trim(), 'model': model.text.trim()};
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
              const Text('整理用的模型', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              const Text('转成文字以后，按类别整理、回答提问用它。', style: TextStyle(color: K.mute, fontSize: 13)),
              RadioGroup<bool>(
                groupValue: own,
                onChanged: (v) => set(() => own = v ?? false),
                child: const Column(children: [
                  RadioListTile(contentPadding: EdgeInsets.zero, value: false, title: Text('用小耳提供的'),
                      subtitle: Text('不用设置，每天有次数上限。内容经小耳云端转给模型，不留记录。', style: TextStyle(color: K.mute, fontSize: 13))),
                  RadioListTile(contentPadding: EdgeInsets.zero, value: true, title: Text('用我自己的模型'),
                      subtitle: Text('填你自己的 API key：直接从这台设备调，key 和内容都不经过小耳。', style: TextStyle(color: K.mute, fontSize: 13))),
                ]),
              ),
              if (own) ...[
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final p in providers)
                    ChoiceChip(
                      label: Text(p.name),
                      selected: provider == p.name,
                      onSelected: (_) => set(() {
                        provider = p.name;
                        if (p.base.isNotEmpty) {
                          base.text = p.base;
                          model.text = p.model;
                        }
                      }),
                    ),
                ]),
                const SizedBox(height: 8),
                TextField(controller: base, decoration: const InputDecoration(labelText: '接口地址（OpenAI 兼容，到 /v1 为止）')),
                TextField(controller: key, obscureText: true, decoration: const InputDecoration(labelText: 'API key')),
                TextField(controller: model, decoration: const InputDecoration(labelText: '模型名')),
                const SizedBox(height: 6),
                Row(children: [
                  OutlinedButton(
                    onPressed: testing
                        ? null
                        : () async {
                            set(() {
                              testing = true;
                              test = null;
                            });
                            String r;
                            try {
                              final llm = Llm(Cloud.instance!, llmSettings);
                              r = '✅ 通了：${(await llm.chat('只回两个字：好的', '试一下')).trim()}';
                            } catch (e) {
                              r = '❌ $e';
                            }
                            Llm.instance = syncer.llm; // 试完换回正在用的
                            set(() {
                              testing = false;
                              test = r;
                            });
                          },
                    child: Text(testing ? '在试…' : '试一下'),
                  ),
                  const SizedBox(width: 10),
                  if (test != null) Expanded(child: Text(test!, maxLines: 3, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: K.mute))),
                ]),
              ],
              const SizedBox(height: 16),
              const Text('资料文件夹', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              const Text('整理好的笔记、逐字稿、录音都在这，是普通文件，不开 App 也能看。「模板」文件夹里改每一类怎么整理；「改写作风格」写你的口吻，小耳写文章、朋友圈时照着写；「词汇表」写你常提到的人名、品牌，现场会议出字、录音转写和整理时都照它纠正听错的字。',
                  style: TextStyle(color: K.mute, fontSize: 13)),
              // 手机上这一栏改不了（disabled 的单行框不能横着滚），路径又长：折行显示全
              TextField(controller: folder, enabled: Platform.isMacOS, maxLines: Platform.isMacOS ? 1 : null, style: const TextStyle(fontSize: 14)),
              if (Platform.isMacOS)
                Row(children: [
                  TextButton.icon(
                    onPressed: () => Process.run('open', [store.lib.path]),
                    icon: const Icon(Icons.folder_open_outlined, size: 16),
                    label: const Text('打开'),
                  ),
                  TextButton.icon(
                    onPressed: () => Process.run('open', ['${store.lib.path}/模板']),
                    icon: const Icon(Icons.edit_note, size: 16),
                    label: const Text('改模板'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final f = store.lib.styleFile;
                      if (!await f.exists()) await f.writeAsString(defaultStyle);
                      await Process.run('open', [f.path]);
                    },
                    icon: const Icon(Icons.draw_outlined, size: 16),
                    label: const Text('改写作风格'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      // 一份词汇表：现场会议出字、录音转写、整理都用它（资料文件夹/词汇表.md）
                      final entries = await showDialog<List<VocabEntry>>(
                        context: ctx,
                        builder: (_) => VocabDialog(initial: store.lib.vocabEntries()),
                      );
                      if (entries != null) await store.lib.saveVocab(entries);
                    },
                    icon: const Icon(Icons.spellcheck, size: 16),
                    label: const Text('词汇表'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      for (final stem in [for (final r in store.recs.values.where((r) => r.stage == 'done')) r.stem]) {
                        await syncer.reanalyze(stem);
                      }
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('全部按模板重新整理'),
                  ),
                ]),
              const SizedBox(height: 16),
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
                activeThumbColor: K.accent,
                onChanged: (v) => set(() => deleteAfter = v),
                title: const Text('整理好以后，删掉卡上的原文件'),
                subtitle: const Text('给卡腾地方。整理好的内容和录音都留在这台设备上。', style: TextStyle(color: K.mute, fontSize: 13)),
              ),
              const SizedBox(height: 8),
              const Text('云端地址（一般不用动）', style: TextStyle(fontWeight: FontWeight.w600)),
              TextField(controller: cloud, style: const TextStyle(fontSize: 14, color: K.mute)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: Text(
                    syncer.boundId == null
                        ? '卡：还没选'
                        : '卡：${syncer.boundName}${syncer.card.info?.version == null ? '' : ' · ${syncer.card.info!.version}'} · 剩余空间 ${syncer.card.info?.freeKb == null ? '—' : '${(syncer.card.info!.freeKb! / 1024 / 1024).toStringAsFixed(1)} GB'}',
                    style: const TextStyle(color: K.faint, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    showCardPicker(context, syncer);
                  },
                  child: Text(syncer.boundId == null ? '选卡' : '换一张卡'),
                ),
              ]),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: K.accent),
            onPressed: () async {
              store.settings['llm'] = llmSettings();
              final f = folder.text.trim();
              if (f.isNotEmpty && f != store.lib.path) await store.moveLibrary(f);
              store.settings['rules'] = rules.text.trim();
              store.settings['deleteAfter'] = deleteAfter;
              final url = cloud.text.trim().replaceAll(RegExp(r'/+$'), '');
              if (url.isNotEmpty && url != Cloud.instance?.base) {
                store.settings['cloud'] = url;
                Cloud.instance?.base = url;
              }
              store.save();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}
