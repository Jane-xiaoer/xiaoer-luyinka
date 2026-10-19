#!/bin/bash
# Mac 版发布：编译 → 改成「小耳录音卡.app」→ Developer ID 签名 → DMG → Apple 公证 → 钉票。
# 产物：dist/小耳录音卡-<版本>.dmg（别人下载双击、拖进「应用程序」就能用，不弹「无法验证开发者」）。
# 签名跟 Omia 共用：证书 Developer ID Application: Juan Li（有两张同名，用 Omia 验证过的 G2，指纹 DBF88C5E…），
# 公证凭据在钥匙串 profile「omia-notary」。没有这个 profile 就只签名不公证（别人第一次打开要去「隐私与安全性」点仍要打开）。
set -euo pipefail
cd "$(dirname "$0")"
CLOUD=${LUYINKA_CLOUD:-https://luyinka.xiaoeromia.com:8443}
VER=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
APP=build/macos/Build/Products/Release/XiaoerLuyinka.app
OUT=dist/小耳录音卡.app
DMG=dist/小耳录音卡-$VER.dmg
ID=${LUYINKA_SIGN_ID:-DBF88C5EF3B2A16F46817CD7C6938E880928D9D8}
NOTARY=${LUYINKA_NOTARY_PROFILE:-omia-notary}

echo "== 编译（云端 ${CLOUD}）"
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

if xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1; then
  echo "== 公证（一般几分钟，偶尔几十分钟，别中断）"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | tail -2
else
  echo "⚠️  没有公证凭据：只签名，没公证"
fi
echo "✅ $DMG"
