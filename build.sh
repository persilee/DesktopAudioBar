#!/bin/bash
# 编译 DesktopAudioBar.app（含自动生成应用图标）
# 用法：./build.sh   （产物在 build/DesktopAudioBar.app）
# 图标：项目根目录放置 AppIcon-1024.png 即自动打包为 .icns
set -euo pipefail
cd "$(dirname "$0")"

APP="DesktopAudioBar"
OUT="build/${APP}.app"

echo "==> 清理旧产物"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "==> 编译 ${APP}"
swiftc -O \
  -framework AppKit \
  -framework ScreenCaptureKit \
  -framework Accelerate \
  -o "$OUT/Contents/MacOS/$APP" \
  Sources/main.swift

cp Sources/Info.plist "$OUT/Contents/Info.plist"

# —— 应用图标（可选）：根目录存在 AppIcon-1024.png 时自动打包 ——
if [ -f "AppIcon-1024.png" ]; then
  echo "==> 生成应用图标"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$OUT/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$OUT/Contents/Info.plist"
  echo "   -> AppIcon.icns 已打包"
fi

# 用固定自签名证书签名（创建一次后权限不再随编译变化而重新询问）
CERT="DesktopAudioBar Dev"
if ! security find-certificate -c "$CERT" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  echo "==> 首次创建自签名证书 $CERT"
  openssl req -x509 -newkey rsa:2048 -keyout /tmp/dab-key.pem -out /tmp/dab-cert.pem \
    -days 3650 -nodes -subj "/CN=DesktopAudioBar Dev" \
    -addext "extendedKeyUsage=codeSigning" 2>/dev/null
  security import /tmp/dab-cert.pem -k "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null
  rm -f /tmp/dab-key.pem /tmp/dab-cert.pem
fi
codesign --force --sign "$CERT" "$OUT" 2>/dev/null || codesign --force --sign - "$OUT" 2>/dev/null || true

echo "✅ 生成完毕：$OUT"
echo "   运行：open \"$OUT\""
