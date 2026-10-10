#!/bin/bash
# 编译 DesktopAudioBar.app
# 用法：./build.sh   （产物在 build/DesktopAudioBar.app）
set -euo pipefail
cd "$(dirname "$0")"

APP="DesktopAudioBar"
OUT="build/${APP}.app"

echo "==> 清理旧产物"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"

echo "==> 编译 ${APP}"
swiftc -O \
  -framework AppKit \
  -framework ScreenCaptureKit \
  -framework Accelerate \
  -o "$OUT/Contents/MacOS/$APP" \
  Sources/main.swift

cp Sources/Info.plist "$OUT/Contents/Info.plist"

# 用固定自签名证书签名（创建一次后权限不再随编译变化而重新询问）
CERT="DesktopAudioBar Dev"
if ! security find-certificate -c "$CERT" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  echo "==> 首次创建自签名证书 $CERT"
  openssl req -x509 -newkey rsa:2048 -keyout /tmp/dab-key.pem -out /tmp/dab-cert.pem \
    -days 3650 -nodes -subj "/CN=DesktopAudioBar Dev" \
    -addext "extendedKeyUsage=codeSigning" 2>/dev/null
  security import /tmp/dab-cert.pem -k "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null
  rm -f /tmp/dab-key.pem /tmp/dab-cert.pem
  # 首次使用后仍需在钥匙串里信任该证书（GUI 提示时允许）
fi

codesign --force --sign "$CERT" "$OUT" 2>/dev/null || codesign --force --sign - "$OUT" 2>/dev/null || true

echo "✅ 生成完毕：$OUT"
echo "   运行：open \"$OUT\""
