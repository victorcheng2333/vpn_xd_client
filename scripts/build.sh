#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
source scripts/swift-env.sh
source scripts/architectures.sh
ARCH="$(xdvpn_architectures "${ARCHS-$(uname -m)}")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP="${APP_OUTPUT:-$PWD/dist/XD VPN $VERSION-$ARCH.app}"
bash scripts/build-openconnect.sh
BUILD_OPTIONS=(-c "$CONFIGURATION" --triple "$ARCH-apple-macosx14.0" --scratch-path "$XDVPN_BUILD_ROOT" --cache-path "$XDVPN_BUILD_ROOT/cache")
swift build "${BUILD_OPTIONS[@]}" --disable-sandbox
BIN_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/OpenConnect" "$APP/Contents/Resources/ThirdParty"
cp "$BIN_DIR/XDVPN" "$APP/Contents/MacOS/XDVPN"
cp "$BIN_DIR/XDVPNHelper" "$APP/Contents/Helpers/XDVPNHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp ".build/openconnect/$ARCH/runtime/openconnect" ".build/openconnect/$ARCH/runtime/vpnc-script" "$APP/Contents/Resources/OpenConnect/"
cp ".build/openconnect/$ARCH/licenses/"* "$APP/Contents/Resources/ThirdParty/"
xdvpn_verify_architectures "$APP/Contents/MacOS/XDVPN" "$ARCH"
xdvpn_verify_architectures "$APP/Contents/Helpers/XDVPNHelper" "$ARCH"
xdvpn_verify_engine "$APP/Contents/Resources/OpenConnect/openconnect" "$ARCH"
swift scripts/icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Local, ad-hoc signing. Set SIGNING_IDENTITY to your Developer ID to distribute.
codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier com.xd.vpn.helper "$APP/Contents/Helpers/XDVPNHelper"
codesign --verify --strict "$APP/Contents/Resources/OpenConnect/openconnect"
codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier com.xd.vpn "$APP"
codesign --verify --deep --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
