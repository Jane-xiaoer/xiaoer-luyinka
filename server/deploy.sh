#!/bin/bash
# 把录音卡云端装到一台 Linux 服务器上（Ubuntu 22+/Debian 12+）：代码 → 环境 → 模型 → systemd 常驻。
# 用法：server/deploy.sh <ssh 主机名>        例：server/deploy.sh hostinger-us
# 需要本机 ~/.shared-skills/api-registry/.env 里有 DEEPSEEK_API_KEY（切场景 / 问答用的大模型）。
# 对外的 https 地址另配（Cloudflare 隧道，见 README「云端」）。服务本身只听 127.0.0.1:8790。
set -euo pipefail
HOST=${1:?用法：server/deploy.sh <ssh 主机名>}
cd "$(dirname "$0")/.."
source ~/.shared-skills/api-registry/.env
: "${DEEPSEEK_API_KEY:?缺 DEEPSEEK_API_KEY}"

echo "== 传代码"
ssh "$HOST" 'sudo mkdir -p /opt/luyinka-cloud /var/lib/luyinka-cloud && sudo chown -R "$(id -un)" /opt/luyinka-cloud /var/lib/luyinka-cloud'
rsync -az --delete --exclude __pycache__ luyinka server pyproject.toml "$HOST":/opt/luyinka-cloud/

echo "== 服务器配置（大模型 key 只放服务器上，权限 600）"
ssh "$HOST" "umask 077; cat > /opt/luyinka-cloud/server.json" <<EOF
{
  "owner": "主人",
  "asr": {"engine": "local", "model_dir": "/opt/luyinka-cloud/models/sensevoice",
          "vad_model": "/opt/luyinka-cloud/models/silero_vad.onnx"},
  "llm": {"base_url": "${DEEPSEEK_BASE_URL:-https://api.deepseek.com/v1}", "api_key": "$DEEPSEEK_API_KEY", "model": "deepseek-chat"}
}
EOF

echo "== 环境 + 模型"
ssh "$HOST" 'set -e
  export DEBIAN_FRONTEND=noninteractive
  command -v ffmpeg >/dev/null && python3 -c "import ensurepip" 2>/dev/null || (sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg python3-venv)
  cd /opt/luyinka-cloud
  [ -x venv/bin/python ] || python3 -m venv venv
  venv/bin/pip install -q --upgrade pip
  venv/bin/pip install -q "numpy>=1.26" "sherpa-onnx>=1.10"
  LUYINKA_CONFIG=/opt/luyinka-cloud/server.json venv/bin/python -c "from luyinka import models; models.download(True); print(\"模型好了\")"
'

echo "== systemd"
ssh "$HOST" 'sudo tee /etc/systemd/system/luyinka-cloud.service >/dev/null <<EOF
[Unit]
Description=录音卡云端（转写 + 切场景）
After=network-online.target

[Service]
User=$(id -un)
WorkingDirectory=/opt/luyinka-cloud
Environment=LUYINKA_CONFIG=/opt/luyinka-cloud/server.json
Environment=LUYINKA_CLOUD_DATA=/var/lib/luyinka-cloud
Environment=LUYINKA_APP_DIR=/var/lib/luyinka-cloud/app
ExecStart=/opt/luyinka-cloud/venv/bin/python -m server.app $(T=/var/lib/luyinka-cloud/tls; [ -f $T/fullchain.pem ] && echo "--host 0.0.0.0 --port 8443 --tls-cert $T/fullchain.pem --tls-key $T/key.pem" || echo "--host 127.0.0.1 --port 8790")
Restart=always
RestartSec=5
MemoryMax=2500M

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable luyinka-cloud && sudo systemctl restart luyinka-cloud && sleep 3 && (curl -sk https://127.0.0.1:8443/healthz || curl -s 127.0.0.1:8790/healthz)'
echo
echo "✅ 云端装好了（有证书就是 https 8443，没有就是本机 127.0.0.1:8790）"
