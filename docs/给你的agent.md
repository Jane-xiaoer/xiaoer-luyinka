# 录音卡 × 你的 agent

> 这份是写给 agent 看的（Claude Code / Codex / Cursor / 任何能跑命令或接 MCP 的）。
> 把它丢给你的 agent，说一句「照这个把录音卡接进我的工作台」就行。

## 录音卡已经做好的

卡别在身上录一整天 → 放回电脑旁边，`luyinka` 自动：蓝牙拉录音 → 转写（带时间戳）→ 按话题切成**场景** → 每天出一份简报。
全部是本机文件，在配置的 `home` 目录下（`luyinka days --json` 里有路径）：

```
<home>/
  音频/2026-10-18 14.00.00 录音.ogg        原音，能直接播
  文字/2026-10-18 14.00.00 录音.md         转写全文，每段前面是录音内的时间
  场景/2026-10-18/scenes.json              ← 主要读这个
  场景/2026-10-18/1400 跟老王谈报价.md       一个场景一张卡（给人看的）
  简报/2026-10-18.md                        当天简报
```

## 你的 agent 要做的

**按用户的规则，把场景放进用户自己的工作台。** 规则在 `~/.luyinka/整理规则.md`（用户自己写的）；没有规则就先问用户：
放哪（飞书多维表格 / 飞书文档 / Notion / Obsidian / 某个文件夹）、哪些字段、行动和提醒进哪里。

每天整理完，录音卡会自动跑配置里的 `after_organize` 命令（`luyinka setup` 第 5 步配），把这一天交给你：

| 变量 | 是什么 |
|---|---|
| `{day}` / `$LUYINKA_DAY` | 日期 `2026-10-18` |
| `{scenes_json}` / `$LUYINKA_SCENES_JSON` | 当天 scenes.json 的路径 |
| `{day_dir}` / `$LUYINKA_DAY_DIR` | 当天场景卡所在文件夹（命令就在这里跑） |
| `{brief}` / `$LUYINKA_BRIEF` | 当天简报 |

命令的输出记在 `~/.luyinka/logs/agent.log`。

**做成幂等的**：同一天可能被交给你不止一次（当天又拉到了新录音）。用场景的 `id` 当唯一键，有就更新、没有才新建。

## 三种取数据的方式

1. **直接读文件**：`scenes.json`（格式见下）。
2. **命令行**（都支持 `--json`）：
   ```
   luyinka days --json              哪几天有
   luyinka day 2026-10-18 --json    那天的场景（不带全文；--full 带）
   luyinka scene <id> --json        一个场景全部内容
   luyinka search 报价 老王 --json   搜所有场景（空格分开的词都要命中）
   luyinka pull                     现在就从卡上拉
   ```
3. **MCP**：`claude mcp add -s user luyinka -- luyinka mcp`（setup 里可一键加）。
   工具：`list_days` · `get_day` · `get_scene` · `search` · `pull`。

## 数据格式：scenes.json

```json
{
  "day": "2026-10-18",
  "recordings": ["2026-10-18 14.00.00 录音"],
  "scenes": [{
    "id": "20261018-140005-lyk",              // 唯一键，当去重用
    "start": "2026-10-18T14:00:05+08:00",      // 带时区
    "end":   "2026-10-18T14:10:00+08:00",
    "category": "商业洽谈",                     // 固定词表，见 ~/.luyinka/config.json 的 categories；「杂音」请跳过
    "title": "跟老王谈报价",
    "event": "谈月费和合同，约定下周三前发合同。",   // 一句话：发生了什么
    "place": "",                               // 录音里明说的地点，没说就空
    "people": ["老王"],
    "views": ["老王认为年付更划算"],             // 核心观点
    "valuable": ["月费 2000，年付 8 折"],        // 有价值的内容：信息、数据、方法、报价…
    "memorable": [{"t": "14:00:05", "text": "原话"}],                 // 值得记住的原话
    "actions":   [{"t": "14:10:00", "text": "把合同发给他", "who": "我"}],   // 下一步行动
    "reminders": [{"t": "14:10:00", "text": "下周三之前发合同", "when": "下周三之前"}],  // 提醒事项（when 是原话里的时间，要你换算成具体日期）
    "text": [["14:00:05", "这一段原文"], ["14:10:00", "…"]],   // 全文（day / list 接口不带，scene 接口带）
    "recording": "2026-10-18 14.00.00 录音",
    "audio": "/…/音频/2026-10-18 14.00.00 录音.ogg",
    "offset": 5.0,                             // 这个场景从录音的第几秒开始
    "card": "/…/场景/2026-10-18/1400 跟老王谈报价.md"
  }]
}
```

注意：转写分不出谁在说话；人名、品牌名可能有错字（按上下文理解，引用原话保留原样）。

## 接法示例

### 飞书多维表格（lark-cli）
```bash
npm i -g @larksuite/cli && lark-cli auth login      # 用户自己登一次
# 建表（一次）：字段建议 = 标题 开始 结束 时长 地点 人物 事件 分类 核心观点 有价值的内容 值得记住的 下一步行动 提醒事项 编号
lark-cli base +record-upsert --base-token <base> --table-id <table> --json '{"标题":"跟老王谈报价","编号":"20261018-140005-lyk", ...}'
```
用 `编号` 去重：先 `+record-list` 查有没有这个编号，有就带 `--record-id` 更新。
- 一天一页知识库：`lark-cli docs +create --wiki-node <节点> --title "2026-10-18 | 录音记录" --markdown "..."`，
  每个场景一个 `## HH:MM | 标题` 小标题，飞书左边自动出目录。
- 日历：建一本「🎙 录音」日历，每个场景一个日程，标题「分类 · 标题」，回头翻日历就知道哪天几点在聊什么。
  `lark-cli calendar events create --as user --params '{"calendar_id":"…","idempotency_key":"<按 id 生成的 uuid>"}' --data '{"summary":…,"start_time":{"timestamp":"…"},"end_time":…}'`
- 提醒事项 → 用户的日历或待办（`when` 换算成具体日期再写）。

### Notion
用 Notion API / MCP，往用户指定的数据库里每个场景建一页：属性放标题、日期、分类、人物，正文放事件、观点、行动、提醒。用 `id` 存一个文本属性去重。

### 本地笔记（Obsidian 等）
把 `场景/<day>/*.md` 复制或改写进用户的笔记库，比如 `录音/2026/10/2026-10-18.md`，行动项写成 `- [ ]`。

## 不要做的
- 不对外发任何东西（消息、邮件、帖子），除非用户的规则明确要你发。
- 原文里没有的不写；不确定的标「推断」。
- 不改 `<home>/` 下录音卡自己的文件。
