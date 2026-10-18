#!/bin/bash
# 录音卡一键安装（macOS）：装好环境 → 放好 luyinka 命令 → 进设置向导。重跑 = 升级。
set -e
cd "$(dirname "$0")"
APP="$HOME/.luyinka"
echo "🎙 安装录音卡…"
[ "$(uname)" = Darwin ] || { echo "目前只支持 Mac"; exit 1; }
if ! command -v ffmpeg >/dev/null; then
  command -v brew >/dev/null || { echo "需要 ffmpeg：先装 Homebrew（https://brew.sh），再重跑"; exit 1; }
  brew install ffmpeg
fi
if command -v uv >/dev/null; then
  uv venv -q --allow-existing --python ">=3.10" "$APP/venv"
  uv pip install -q --python "$APP/venv/bin/python" .
else
  PY=$(command -v python3.13 || command -v python3.12 || command -v python3.11 || command -v python3)
  "$PY" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { echo "需要 Python 3.10 以上（brew install python）"; exit 1; }
  "$PY" -m venv "$APP/venv"
  "$APP/venv/bin/pip" install -q --upgrade pip
  "$APP/venv/bin/pip" install -q .
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$APP/venv/bin/luyinka" "$HOME/.local/bin/luyinka"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"; export PATH="$HOME/.local/bin:$PATH"
  echo "（已把 ~/.local/bin 加进 PATH，新开的终端生效）" ;;
esac
echo "✅ 装好了：luyinka"
[ "$1" = "--no-setup" ] || "$APP/venv/bin/luyinka" setup
