#!/bin/bash
# Mac 版发布：编译 → 改成「小耳录音卡.app」→ Developer ID 签名 → DMG → Apple 公证 → 钉票。
# 产物：dist/小耳录音卡-<版本>.dmg（别人下载双击、拖进「应用程序」就能用，不弹「无法验证开发者」）。
# 签名凭据跟 Omia 共用：~/.shared-skills/api-registry/.env 里的 OMON_APPLE_SIGNING_IDENTITY / _ID / _PASSWORD / _TEAM_ID。
# 没填公证凭据时只签名不公证（自己机器能开，别人第一次打开要去「隐私与安全性」点仍要打开）。
set -euo pipefail
cd "$(dirname "$0")"
source ~/.shared-skills/api-registry/.env
CLOUD=${LUYINKA_CLOUD:-https://luyinka.blitzer.studio:8443}
VER=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
APP=build/macos/Build/Products/Release/XiaoerLuyinka.app
OUT=dist/小耳录音卡.app
DMG=dist/小耳录音卡-$VER.dmg
ID=${OMON_APPLE_SIGNING_IDENTITY:?缺 OMON_APPLE_SIGNING_IDENTITY}

echo "== 编译（云端 $CLOUD）"
flutter build macos --release --dart-define=LUYINKA_CLOUD="$CLOUD"
rm -rf dist && mkdir -p dist
ditto "$APP" "$OUT"

echo "== 签名"
codesign --force --deep --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements --sign "$ID" "$OUT"
codesign --verify --deep --strict "$OUT"

echo "== DMG"
STAGE=$(mktemp -d)
ditto "$OUT" "$STAGE/小耳录音卡.app"
ln -s /Applications "$STAGE/应用程序"
hdiutil create -volname "小耳录音卡" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$ID" "$DMG"

if [ -n "${OMON_APPLE_ID:-}" ] && [ -n "${OMON_APPLE_PASSWORD:-}" ] && [ -n "${OMON_APPLE_TEAM_ID:-}" ]; then
  echo "== 公证（第一次可能要几十分钟，别中断）"
  xcrun notarytool submit "$DMG" --apple-id "$OMON_APPLE_ID" --password "$OMON_APPLE_PASSWORD" \
    --team-id "$OMON_APPLE_TEAM_ID" --wait
  xcrun stapler staple "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | tail -2
else
  echo "⚠️  没有公证凭据：只签名，没公证"
fi
echo "✅ $DMG"
