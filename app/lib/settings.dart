// 设置：左边分几块，右边是这一块的内容，每块只留一句话说明。
//   外观（皮肤，点了马上换）· 大模型 · 词汇表 · 整理（模板 / 写作风格 / 交给 Agent 的规则）· 资料文件夹 · 设备与云端
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

void showSettings(BuildContext context, Store store, Syncer syncer, {String section = '外观'}) =>
    showDialog(context: context, builder: (_) => SettingsDialog(store: store, syncer: syncer, section: section));

class SettingsDialog extends StatefulWidget {
  final Store store;
  final Syncer syncer;
  final String section;
  const SettingsDialog({super.key, required this.store, required this.syncer, this.section = '外观'});
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  Store get store => widget.store;
  Syncer get syncer => widget.syncer;
  static const sections = ['外观', '大模型', '词汇表', '整理', '资料文件夹', '设备与云端'];
  late String at = widget.section;

  late final rules = TextEditingController(text: (store.settings['rules'] as String?) ?? defaultRules);
  late final cloud = TextEditingController(text: Cloud.instance?.base ?? '');
  late var deleteAfter = store.settings['deleteAfter'] == true;
  late final _m = Map<String, dynamic>.from(store.settings['llm'] ?? {});
  late var own = _m['own'] == true;
  late var provider = (_m['provider'] as String?) ?? providers.first.name;
  late final base = TextEditingController(text: (_m['base'] as String?) ?? providers.first.base);
  late final key = TextEditingController(text: (_m['key'] as String?) ?? '');
  late final model = TextEditingController(text: (_m['model'] as String?) ?? providers.first.model);
  late final folder = TextEditingController(text: store.lib.path);
  String? test; // 「试一下」的结果
  var testing = false;

  Map<String, dynamic> llmSettings() =>
      {'own': own, 'provider': provider, 'base': base.text.trim(), 'key': key.text.trim(), 'model': model.text.trim()};

  Future<void> _save() async {
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
    await store.save();
    if (mounted) Navigator.pop(context);
  }

  Widget _head(String t, [String? note]) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: K.title(20)),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(note, style: TextStyle(color: K.faint, fontSize: 13)),
          ],
        ]),
      );

  // ───────── 各块 ─────────

  Widget _look() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('外观', '点一下就换'),
        Wrap(spacing: 14, runSpacing: 14, children: [
          for (final k in skins)
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () async {
                skin.value = k;
                store.settings['skin'] = k.key;
                await store.save();
                setState(() {});
              },
              child: Container(
                width: 200,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: k.sage,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: skin.value.key == k.key ? K.accent : K.line, width: skin.value.key == k.key ? 2 : 1),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // 小预览：卡片 + 正文 + 强调色
                  Container(
                    height: 64,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: k.card, borderRadius: BorderRadius.circular(10)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(width: 70, height: 8, decoration: BoxDecoration(color: k.ink, borderRadius: BorderRadius.circular(4))),
                      const SizedBox(height: 8),
                      Container(width: 110, height: 6, decoration: BoxDecoration(color: k.faint, borderRadius: BorderRadius.circular(3))),
                      const Spacer(),
                      Container(width: 36, height: 10, decoration: BoxDecoration(color: k.accent, borderRadius: BorderRadius.circular(5))),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Text(k.name, style: TextStyle(fontWeight: FontWeight.w700, color: k.ink)),
                    const Spacer(),
                    if (skin.value.key == k.key) Icon(Icons.check_circle, size: 18, color: K.accent),
                  ]),
                ]),
              ),
            ),
        ]),
      ]);

  Widget _model() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('大模型', '按类别整理、写纪要、问问小耳用它；转写在本机做，不用它'),
        RadioGroup<bool>(
          groupValue: own,
          onChanged: (v) => setState(() => own = v ?? false),
          child: Column(children: [
            RadioListTile(
                contentPadding: EdgeInsets.zero,
                value: true,
                title: const Text('用我自己的 key'),
                subtitle: Text('直接从这台电脑调，key 不经过小耳', style: TextStyle(color: K.faint, fontSize: 13))),
            RadioListTile(
                contentPadding: EdgeInsets.zero,
                value: false,
                title: const Text('用小耳的体验额度'),
                subtitle: Text('不用设置，每天有限', style: TextStyle(color: K.faint, fontSize: 13))),
          ]),
        ),
        if (own) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in providers)
              ChoiceChip(
                label: Text(p.name),
                selected: provider == p.name,
                onSelected: (_) => setState(() {
                  provider = p.name;
                  if (p.base.isNotEmpty) {
                    base.text = p.base;
                    model.text = p.model;
                  }
                }),
              ),
          ]),
          const SizedBox(height: 8),
          TextField(controller: base, decoration: const InputDecoration(labelText: '接口地址（到 /v1）')),
          TextField(controller: key, obscureText: true, decoration: const InputDecoration(labelText: 'API key')),
          TextField(controller: model, decoration: const InputDecoration(labelText: '模型名')),
          const SizedBox(height: 10),
          Row(children: [
            OutlinedButton(
              onPressed: testing
                  ? null
                  : () async {
                      setState(() {
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
                      if (mounted) {
                        setState(() {
                          testing = false;
                          test = r;
                        });
                      }
                    },
              child: Text(testing ? '在试…' : '试一下'),
            ),
            const SizedBox(width: 10),
            if (test != null)
              Expanded(
                  child: Text(test!, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: K.mute))),
          ]),
        ],
      ]);

  Widget _vocab() {
    final n = store.lib.vocabEntries().length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _head('词汇表', '常提到的人名、品牌、专有名词；出字、转写、整理都照它改错字'),
      Text(n == 0 ? '还没有词' : '$n 个词', style: TextStyle(color: K.mute)),
      const SizedBox(height: 12),
      Row(children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: K.accent),
          onPressed: () async {
            final entries = await showDialog<List<VocabEntry>>(
              context: context,
              builder: (_) => VocabDialog(initial: store.lib.vocabEntries()),
            );
            if (entries != null) await store.lib.saveVocab(entries);
            if (mounted) setState(() {});
          },
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: const Text('编辑词汇表'),
        ),
        if (Platform.isMacOS) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: () => Process.run('open', ['-R', store.lib.vocabFile.path]), child: const Text('在文件夹里显示')),
        ],
      ]),
    ]);
  }

  Widget _organize() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('整理', '每一类怎么整理、你的写作口吻，都是资料文件夹里的 .md，改了下次就照着来'),
        if (Platform.isMacOS)
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: () => Process.run('open', ['${store.lib.path}/模板']),
              icon: const Icon(Icons.edit_note, size: 16),
              label: const Text('改模板'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final f = store.lib.styleFile;
                if (!await f.exists()) await f.writeAsString(defaultStyle);
                await Process.run('open', [f.path]);
              },
              icon: const Icon(Icons.draw_outlined, size: 16),
              label: const Text('改写作风格'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                for (final stem in [for (final r in store.recs.values.where((r) => r.stage == 'done')) r.stem]) {
                  await syncer.reanalyze(stem);
                }
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('全部重新整理'),
            ),
          ]),
        const SizedBox(height: 18),
        Text('交给 Agent 时一起给它的规则', style: TextStyle(fontWeight: FontWeight.w600, color: K.ink)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: K.cardDeep, borderRadius: BorderRadius.circular(10)),
          child: TextField(controller: rules, maxLines: 9, minLines: 6, style: const TextStyle(fontSize: 14, height: 1.6)),
        ),
      ]);

  Widget _folder() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('资料文件夹', '笔记、逐字稿、录音都是普通文件；Obsidian 能直接打开，别的 AI 读「给AI的接口.md」'),
        // 手机上改不了（disabled 的单行框不能横着滚），路径又长：折行显示全
        TextField(controller: folder, enabled: Platform.isMacOS, maxLines: Platform.isMacOS ? 1 : null, style: const TextStyle(fontSize: 14)),
        if (Platform.isMacOS) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Process.run('open', [store.lib.path]),
            icon: const Icon(Icons.folder_open_outlined, size: 16),
            label: const Text('打开'),
          ),
        ],
      ]);

  Widget _devices() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('设备与云端'),
        Row(children: [
          Expanded(
            child: Text(
              syncer.boundId == null
                  ? '录音卡：还没选'
                  : '录音卡：${syncer.boundName}${syncer.card.info?.version == null ? '' : ' · ${syncer.card.info!.version}'}',
              style: TextStyle(color: K.mute),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              showCardPicker(context, syncer);
            },
            child: Text(syncer.boundId == null ? '选卡' : '换一张卡'),
          ),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: deleteAfter,
          activeThumbColor: K.accent,
          onChanged: (v) => setState(() => deleteAfter = v),
          title: const Text('导入后删掉卡上的原文件'),
        ),
        const SizedBox(height: 10),
        Text('云端地址', style: TextStyle(fontWeight: FontWeight.w600, color: K.ink)),
        TextField(controller: cloud, style: TextStyle(fontSize: 14, color: K.mute)),
      ]);

  @override
  Widget build(BuildContext context) {
    final body = switch (at) {
      '外观' => _look(),
      '大模型' => _model(),
      '词汇表' => _vocab(),
      '整理' => _organize(),
      '资料文件夹' => _folder(),
      _ => _devices(),
    };
    return Dialog(
      backgroundColor: K.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        width: 760,
        height: 560,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            width: 170,
            padding: const EdgeInsets.fromLTRB(10, 20, 10, 12),
            decoration: BoxDecoration(
              color: K.cardDeep,
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 0, 14),
                child: Text('设置', style: K.title(18)),
              ),
              for (final s in sections)
                Material(
                  color: at == s ? K.card : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => at = s),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Text(s,
                          style: TextStyle(
                              fontWeight: at == s ? FontWeight.w700 : FontWeight.w500, color: at == s ? K.ink : K.mute)),
                    ),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(28, 24, 28, 12), child: body)),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 4, 20, 16),
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                  const SizedBox(width: 6),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: K.accent),
                    onPressed: _save,
                    child: const Text('保存'),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
