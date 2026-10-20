#!/usr/bin/env python3
"""给 e2e_fake_card_test 造三段「卡上的录音」：macOS say 合成中文口语 → 卡的格式（裸 Opus，16k 单声道，CBR 16kbps，20ms 一帧正好 40 字节）。

用法：python3 test/fixtures/make_fake_recordings.py [输出目录，默认 /tmp/luyinka-fake-card]
输出：<目录>/note20261019-093000.opus 等三份（文件名照真卡 noteYYYYMMDD-HHMMSS），素材不进 git。
"""
import subprocess
import sys
import tempfile
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/luyinka-fake-card")

# 几个人说话换不同的声音；没有的声音 say 会报错，按 `say -v '?'` 换
A, B, C, D = "Tingting", "Eddy (Chinese (China mainland))", "Reed (Chinese (China mainland))", "Flo (Chinese (China mainland))"

RECORDINGS = {
    # ① 开会：排期、定价、谁周三前交什么
    "note20261019-093000": [
        (A, "好，人都到齐了，我们开始。今天就三件事，第一是新版录音卡App的排期，第二是会员定价，第三是这周每个人要交的东西。"),
        (B, "排期这边，安卓版我这周四能出测试包，iOS那边审核大概要一周，所以正式上线我建议定在十一月三号。"),
        (A, "十一月三号可以。那测试包周四给到我，我拉二十个老用户先试。"),
        (C, "定价我做了一版方案。基础版免费，每个月可以转写三个小时；专业版一个月二十九块，一年二百四十九，不限时长。"),
        (A, "二十九有点贵，竞品都在十九到二十五之间。我们先按二十五块一个月，年付一百九十九，首发一个月再打八折。"),
        (C, "好的，那我按二十五和一百九十九改，周三之前把定价页的文案和截图交给你。"),
        (D, "我这边负责用户手册，周三前交初稿，另外我把客服常见问题整理成十条，一起发群里。"),
        (A, "好。那我总结一下：小王周四出安卓测试包；小李周三前交定价页文案；小周周三前交用户手册和十条常见问题；我负责拉二十个种子用户。十一月三号正式上线。还有问题吗？没有就散会。"),
    ],
    # ② 个人感悟：对 AI 和工作的判断
    "note20261019-123000": [
        (A, "今天中午吃饭的时候突然想明白一件事，记一下。"),
        (A, "这一年用AI用下来，我发现它最大的价值不是替我干活，而是让我不用再做那些我本来就不该做的事。以前我一半的时间花在整理会议记录、回消息、找资料上，现在这些都可以交给它。"),
        (A, "但是真正难的部分一点没变：判断该做什么、不该做什么，跟人建立信任，还有对结果负责。这些AI替不了，反而变得更重要了。"),
        (A, "所以我对未来的判断是，接下来三年，会用AI的人和不会用的人，差距不在效率，而在注意力。谁能把省下来的时间放到真正重要的判断上，谁就赢。"),
        (A, "还有一点，小团队会越来越有优势。以前一个产品要十个人，现在三个人加一堆AI就能做出来，而且决策更快。我们自己就是例子。"),
        (A, "这个观点下次分享的时候可以讲，标题就叫：AI省下来的不是时间，是注意力。"),
    ],
    # ③ 跟客户的电话：价格、交期
    "note20261019-160000": [
        (A, "喂，张总您好，我是小耳的Jane，上次您说的那批录音卡，我们这边报价出来了，跟您说一下。"),
        (B, "好好，你说。"),
        (A, "您要五百台，单价我们给到三百二十块一台，含一年的专业版会员。如果一次订一千台，可以降到二百九十八。"),
        (B, "三百二还是有点高。我们之前问的另一家是二百八十，你们能不能再让一点？"),
        (A, "他们那家不带转写服务的。这样吧，五百台我给您三百一，再送您团队十个管理员账号，这是最低了。"),
        (B, "三百一可以考虑。那交期呢？我们十一月二十号要在年会上发给员工。"),
        (A, "下单付了定金以后，十五个工作日交货，赶十一月二十号没问题。定金是百分之三十，交货前付清尾款。"),
        (B, "行，那你把正式报价单和合同发我邮箱，我周五之前给你答复。"),
        (A, "好的张总，我今天下班前就把报价单和合同发您，周五等您消息。"),
    ],
}


def ogg_packets(data: bytes) -> list[bytes]:
    pkts, cur, i = [], b"", 0
    while i < len(data):
        assert data[i:i + 4] == b"OggS"
        nseg = data[i + 26]
        lacing = data[i + 27:i + 27 + nseg]
        pos = i + 27 + nseg
        for n in lacing:
            cur += data[pos:pos + n]
            pos += n
            if n < 255:
                pkts.append(cur)
                cur = b""
        i = pos
    return pkts


def make(stem: str, lines, tmp: Path) -> Path:
    parts = []
    for i, (voice, text) in enumerate(lines):
        a = tmp / f"{stem}-{i}.aiff"
        subprocess.run(["say", "-v", voice, "-r", "200", "-o", str(a), text], check=True)
        parts.append(a)
    inputs, filt = [], ""
    for i, p in enumerate(parts):
        inputs += ["-i", str(p)]
        filt += f"[{i}:a]aresample=16000,aformat=channel_layouts=mono,apad=pad_dur=0.6[a{i}];"
    filt += "".join(f"[a{i}]" for i in range(len(parts))) + f"concat=n={len(parts)}:v=0:a=1[out]"
    ogg = tmp / f"{stem}.ogg"
    subprocess.run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", filt, "-map", "[out]",
                    "-ar", "16000", "-ac", "1", "-c:a", "libopus", "-b:a", "16k", "-vbr", "off",
                    "-frame_duration", "20", "-application", "voip", str(ogg)], check=True)
    pkts = ogg_packets(ogg.read_bytes())[2:]  # 去掉 OpusHead / OpusTags
    assert pkts and all(len(p) == 40 for p in pkts), {len(p) for p in pkts}
    out = OUT / f"{stem}.opus"
    out.write_bytes(b"".join(pkts))
    return out


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as t:
        for stem, lines in RECORDINGS.items():
            p = make(stem, lines, Path(t))
            n = p.stat().st_size
            print(f"{p}  {n} 字节  {n / 2000:.0f} 秒")
