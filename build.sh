#!/bin/bash
# Builds "XD VPN.app" into ./build using SwiftPM (no Xcode project needed).
#   ./build.sh            release build
#   CONFIG=debug ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="XD VPN"
APP="build/$APP_NAME.app"

echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG" --product XDVPN
BIN="$(swift build -c "$CONFIG" --show-bin-path)/XDVPN"

if [ ! -f Support/AppIcon.icns ]; then
  echo "▸ generating app icon"
  swift Support/make-icon.swift Support/AppIcon.icns
fi

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XDVPN"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ codesign (ad-hoc)"
codesign --force --sign - --identifier com.chengfei.xdvpn "$APP"

echo "✓ built $APP"
