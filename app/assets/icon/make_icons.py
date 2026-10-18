# 从 source.jpg（2048² 毛绒绿猫耳）出全套图标：Mac AppIcon / 安卓自适应 + 老安卓 / 下载页网页图标。
# 换图标：替换 source.jpg，在 app/ 下跑 python3 assets/icon/make_icons.py，再 cp assets/icon/favicon-180.png ../server/icon.png
from PIL import Image, ImageDraw, ImageFilter

src = Image.open('assets/icon/source.jpg').convert('RGB')
BG = (240, 236, 229)  # 安卓自适应图标底色 = 图里的暖白，values/ic_launcher_background.xml 同步

# Mac：824 圆角方块放在 1024 画布中间，带一点投影（macOS 不会替你裁圆角）
art = src.resize((824, 824), Image.LANCZOS)
m = Image.new('L', (824, 824), 0)
ImageDraw.Draw(m).rounded_rectangle((0, 0, 823, 823), 185, fill=255)
mac = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
sh = Image.new('L', (1024, 1024), 0)
ImageDraw.Draw(sh).rounded_rectangle((100, 114, 923, 937), 185, fill=80)
shadow = Image.new('RGBA', (1024, 1024), (0, 0, 0, 255))
shadow.putalpha(sh.filter(ImageFilter.GaussianBlur(16)))
mac.alpha_composite(shadow)
mac.paste(art, (100, 100), m)
mac.save('assets/icon/mac-1024.png')
for s in (16, 32, 64, 128, 256, 512, 1024):
    mac.resize((s, s), Image.LANCZOS).save(f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{s}.png')

# 安卓：前景 108dp 画布，中间 72dp 可见；小怪缩到 86/108，桌面裁成圆也切不到它
res = 'android/app/src/main/res'
for name, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
    fg_size = px * 108 // 48
    fg = Image.new('RGBA', (fg_size, fg_size), BG + (255,))
    a = src.resize((fg_size * 86 // 108,) * 2, Image.LANCZOS)
    fg.paste(a, ((fg_size - a.width) // 2,) * 2)
    fg.save(f'{res}/mipmap-{name}/ic_launcher_foreground.png')
    # 安卓 8.0 以下直接用这张圆角方块
    big = px * 4
    lm = Image.new('L', (big, big), 0)
    ImageDraw.Draw(lm).rounded_rectangle((0, 0, big - 1, big - 1), big * 0.22, fill=255)
    out = Image.new('RGBA', (px, px), (0, 0, 0, 0))
    out.paste(src.resize((px, px), Image.LANCZOS), (0, 0), lm.resize((px, px), Image.LANCZOS))
    out.save(f'{res}/mipmap-{name}/ic_launcher.png')

mac.resize((180, 180), Image.LANCZOS).save('assets/icon/favicon-180.png')
