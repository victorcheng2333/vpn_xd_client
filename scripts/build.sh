#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
source scripts/swift-env.sh
source scripts/architectures.sh
ARCH="$(xdvpn_architectures "${ARCHS-$(uname -m)}")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
export BUILD_CHANNEL="${BUILD_CHANNEL:-development}"
python3 scripts/version.py > /dev/null
if [ "$BUILD_CHANNEL" = release ]; then
    python3 scripts/version.py --check-git > /dev/null
fi
case "$BUILD_CHANNEL" in
    development) DEFAULT_APP="$PWD/build/dev/$ARCH/XD VPN.app" ;;
    test) DEFAULT_APP="$PWD/build/test/$ARCH/XD VPN.app" ;;
    release) DEFAULT_APP="$PWD/build/XD VPN $VERSION-$ARCH.app" ;;
    *) echo "Invalid build channel: $BUILD_CHANNEL" >&2; exit 1 ;;
esac
BUILD_NUMBER="$(python3 scripts/version.py --field build)"
REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
    REVISION="$REVISION-dirty"
fi
BUILD_IDENTIFIER="$BUILD_NUMBER-$BUILD_CHANNEL-$(date -u +%Y%m%dT%H%M%SZ)-$REVISION"
APP="${APP_OUTPUT:-$DEFAULT_APP}"
source scripts/signing.sh
xdvpn_configure_signing
bash scripts/build-openconnect.sh
BUILD_OPTIONS=(-c "$CONFIGURATION" --triple "$ARCH-apple-macosx14.0" --scratch-path "$XDVPN_BUILD_ROOT" --cache-path "$XDVPN_BUILD_ROOT/cache")
swift build "${BUILD_OPTIONS[@]}" --disable-sandbox
BIN_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
# Always assemble a fresh bundle; stale signed resources must not survive rebuilds.
if [ -e "$APP" ]; then
    [[ "$APP" = "$PWD/build/"*.app || "$APP" = "$PWD/.build/"*.app ]] || { echo "Refusing to replace an existing app outside build directories." >&2; exit 1; }
    rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/OpenConnect" "$APP/Contents/Resources/ThirdParty"
cp "$BIN_DIR/XDVPN" "$APP/Contents/MacOS/XDVPN"
cp "$BIN_DIR/XDVPNHelper" "$APP/Contents/Helpers/XDVPNHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
BUILD_NUMBER="$BUILD_NUMBER" python3 scripts/version.py --write-plist "$APP/Contents/Info.plist" > /dev/null
/usr/libexec/PlistBuddy -c "Add :XDVPNBuildIdentifier string $BUILD_IDENTIFIER" "$APP/Contents/Info.plist"
SOURCE_REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Add :XDVPNSourceRevision string $SOURCE_REVISION" "$APP/Contents/Info.plist"
cp ".build/openconnect/$ARCH/runtime/openconnect" ".build/openconnect/$ARCH/runtime/vpnc-script" "$APP/Contents/Resources/OpenConnect/"
cp ".build/openconnect/$ARCH/licenses/"* "$APP/Contents/Resources/ThirdParty/"
xdvpn_verify_architectures "$APP/Contents/MacOS/XDVPN" "$ARCH"
xdvpn_verify_architectures "$APP/Contents/Helpers/XDVPNHelper" "$ARCH"
xdvpn_verify_engine "$APP/Contents/Resources/OpenConnect/openconnect" "$ARCH"
swift scripts/icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
xdvpn_sign com.xd.vpn.helper "$APP/Contents/Helpers/XDVPNHelper"
codesign --verify --strict "$APP/Contents/Resources/OpenConnect/openconnect"
xdvpn_sign com.xd.vpn "$APP"
codesign --verify --deep --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
printf 'Version: %s / Build: %s\n' "$VERSION" "$BUILD_IDENTIFIER"
