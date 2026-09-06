#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
APP="${APP_OUTPUT:-$PWD/dist/XD VPN.app}"
source scripts/swift-env.sh
bash scripts/build-openconnect.sh
swift build -c "$CONFIGURATION" --disable-sandbox --scratch-path "$XDVPN_BUILD_ROOT" --cache-path "$XDVPN_BUILD_ROOT/cache"
BIN_DIR="$(swift build -c "$CONFIGURATION" --scratch-path "$XDVPN_BUILD_ROOT" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/OpenConnect" "$APP/Contents/Resources/ThirdParty"
cp "$BIN_DIR/XDVPN" "$APP/Contents/MacOS/XDVPN"
cp "$BIN_DIR/XDVPNHelper" "$APP/Contents/Helpers/XDVPNHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/openconnect/runtime/openconnect .build/openconnect/runtime/vpnc-script "$APP/Contents/Resources/OpenConnect/"
cp .build/openconnect/licenses/* "$APP/Contents/Resources/ThirdParty/"
swift scripts/icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Local, ad-hoc signing. Set SIGNING_IDENTITY to your Developer ID to distribute.
codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier com.xd.vpn.helper "$APP/Contents/Helpers/XDVPNHelper"
codesign --verify --strict "$APP/Contents/Resources/OpenConnect/openconnect"
codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier com.xd.vpn "$APP"
codesign --verify --deep --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
