#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
APP="${APP_OUTPUT:-$PWD/dist/XD VPN.app}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
swift build -c "$CONFIGURATION" --disable-sandbox
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/XDVPN" "$APP/Contents/MacOS/XDVPN"
cp "$BIN_DIR/XDVPNHelper" "$APP/Contents/Helpers/XDVPNHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift scripts/icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Local, ad-hoc signing. Set SIGNING_IDENTITY to your Developer ID to distribute.
codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier com.xd.vpn.helper "$APP/Contents/Helpers/XDVPNHelper"
codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier com.xd.vpn "$APP"
codesign --verify --deep --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
