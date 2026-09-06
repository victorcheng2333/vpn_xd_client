#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
source scripts/swift-env.sh
source scripts/architectures.sh
ARCH="$(xdvpn_architectures "${ARCHS-$(uname -m)}")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_CHANNEL="${BUILD_CHANNEL:-development}"
case "$BUILD_CHANNEL" in
    development) DEFAULT_APP="$PWD/build/dev/$ARCH/XD VPN.app" ;;
    test) DEFAULT_APP="$PWD/build/test/$ARCH/XD VPN.app" ;;
    release) DEFAULT_APP="$PWD/build/XD VPN $VERSION-$ARCH.app" ;;
    *) echo "Invalid build channel: $BUILD_CHANNEL" >&2; exit 1 ;;
esac
SOURCE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
if [ "$BUILD_CHANNEL" = test ] && [ -z "${BUILD_NUMBER:-}" ]; then
    echo 'Test builds require an explicit BUILD_NUMBER.' >&2; exit 1
fi
BUILD_NUMBER="${BUILD_NUMBER:-$SOURCE_BUILD}"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'BUILD_NUMBER must be a positive integer.' >&2; exit 1; }
REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
    REVISION="$REVISION-dirty"
fi
BUILD_IDENTIFIER="$BUILD_NUMBER-$BUILD_CHANNEL-$(date -u +%Y%m%dT%H%M%SZ)-$REVISION"
APP="${APP_OUTPUT:-$DEFAULT_APP}"
bash scripts/build-openconnect.sh
BUILD_OPTIONS=(-c "$CONFIGURATION" --triple "$ARCH-apple-macosx14.0" --scratch-path "$XDVPN_BUILD_ROOT" --cache-path "$XDVPN_BUILD_ROOT/cache")
swift build "${BUILD_OPTIONS[@]}" --disable-sandbox
BIN_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/OpenConnect" "$APP/Contents/Resources/ThirdParty"
cp "$BIN_DIR/XDVPN" "$APP/Contents/MacOS/XDVPN"
cp "$BIN_DIR/XDVPNHelper" "$APP/Contents/Helpers/XDVPNHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :XDVPNBuildChannel string $BUILD_CHANNEL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :XDVPNBuildIdentifier string $BUILD_IDENTIFIER" "$APP/Contents/Info.plist"
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
printf 'Version: %s / Build: %s\n' "$VERSION" "$BUILD_IDENTIFIER"
