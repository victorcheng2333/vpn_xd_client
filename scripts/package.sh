#!/bin/bash
# Distribute the self-contained application and installation instructions.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/architectures.sh
export BUILD_CHANNEL="${BUILD_CHANNEL:-test}"
case "$BUILD_CHANNEL" in
    release|test) ;;
    *) echo 'Packaging requires BUILD_CHANNEL=release or test.' >&2; exit 1 ;;
esac
python3 scripts/version.py > /dev/null
if [ "$BUILD_CHANNEL" = release ]; then
    [ "${NOTARIZE:-1}" = 1 ] || { echo 'Release requires Apple notarization; NOTARIZE must be 1.' >&2; exit 1; }
    export NOTARIZE=1
    export NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-xdvpn-notary}"
    python3 scripts/version.py --check-git > /dev/null
fi
source scripts/signing.sh
xdvpn_configure_signing
# Default delivery: an ARM app plus ARM and Intel DMGs.
if [ "${ARCHS+x}" != x ] && [ "${APP_OUTPUT+x}" != x ]; then
    ARCHS=arm64 bash scripts/package.sh
    ARCHS=x86_64 bash scripts/package.sh
    exit 0
fi
TARGET_ARCHS="$(xdvpn_architectures "${ARCHS-$(uname -m)}")"
SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP_DIRECTORY="$PWD/build"
if [ "$TARGET_ARCHS" = x86_64 ]; then
    APP_DIRECTORY="$PWD/.build/package-apps"
fi
if [ "$BUILD_CHANNEL" = test ]; then
    APP_DIRECTORY="$PWD/build/test/$TARGET_ARCHS"
fi
APP="${APP_OUTPUT:-$APP_DIRECTORY/XD VPN $SOURCE_VERSION-$TARGET_ARCHS.app}"
# A release command builds the complete payload before packaging it. Use
# SKIP_BUILD=1 only to repackage an existing, verified application.
if [ "${SKIP_BUILD:-0}" != 1 ]; then
    APP_OUTPUT="$APP" bash scripts/build.sh
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
APP_CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :XDVPNBuildChannel' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
if [ "$APP_CHANNEL" != "$BUILD_CHANNEL" ]; then
    echo "Build channel mismatch: expected $BUILD_CHANNEL, got $APP_CHANNEL" >&2; exit 1
fi
if [ "$BUILD_CHANNEL" = release ]; then
    APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
    EXPECTED_BUILD="$(python3 scripts/version.py --field build)"
    [ "$VERSION" = "$SOURCE_VERSION" ] && [ "$APP_BUILD" = "$EXPECTED_BUILD" ] || { echo 'Release app version/build mismatch.' >&2; exit 1; }
    APP_REVISION="$(/usr/libexec/PlistBuddy -c 'Print :XDVPNSourceRevision' "$APP/Contents/Info.plist")"
    APP_REPOSITORY="$(/usr/libexec/PlistBuddy -c 'Print :XDVPNReleaseRepository' "$APP/Contents/Info.plist")"
    [ "$APP_REVISION" = "$(git rev-parse HEAD)" ] && [ "$APP_REPOSITORY" = "$(python3 scripts/version.py --field repository)" ] || {
        echo 'Release app source revision/repository mismatch.' >&2; exit 1;
    }
fi
PACKAGE_VERSION="$VERSION"
OUTPUT_DIRECTORY="$PWD/build"
if [ "$BUILD_CHANNEL" = test ]; then
    APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
    [[ "$APP_BUILD" =~ ^[1-9][0-9]*$ ]] || exit 1
    PACKAGE_VERSION="$VERSION-test.$APP_BUILD"
fi
TARGET_ARCHS="$(xdvpn_architectures "$(/usr/bin/lipo -archs "$APP/Contents/MacOS/XDVPN")")"
xdvpn_verify_architectures "$APP/Contents/MacOS/XDVPN" "$TARGET_ARCHS"
if [ "${ARCHS+x}" = x ]; then
    xdvpn_verify_architectures "$APP/Contents/MacOS/XDVPN" "$(xdvpn_architectures "$ARCHS")"
fi
xdvpn_verify_architectures "$APP/Contents/Library/LaunchServices/com.xd.vpn.helper" "$TARGET_ARCHS"
xdvpn_verify_engine "$APP/Contents/Resources/OpenConnect/openconnect" "$TARGET_ARCHS"
case "$TARGET_ARCHS" in
    arm64) ARCH=arm64; MACHINE='Apple Silicon（M 系列）Mac' ;;
    x86_64) ARCH=x86_64; MACHINE='Intel Mac' ;;
esac
codesign --verify --deep --strict "$APP"
if [ "$BUILD_CHANNEL" = release ]; then
    source scripts/signing.sh
    for target in "$APP" "$APP/Contents/Library/LaunchServices/com.xd.vpn.helper" "$APP/Contents/Resources/OpenConnect/openconnect"; do
        xdvpn_verify_release_signature "$target"
    done
fi
test -x "$APP/Contents/Resources/OpenConnect/openconnect"
test -x "$APP/Contents/Resources/OpenConnect/vpnc-script"
SIGNING_NOTE='此包使用本地签名，未做 Apple 公证；若 macOS 阻止打开，请联系发布者或公司 IT。'
APP_SIGNING_DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1)"
if [[ "$APP_SIGNING_DETAILS" = *'Authority=Developer ID Application:'* ]]; then
    SIGNING_NOTE='此包使用公司 Developer ID 签名，未做 Apple 公证；若 macOS 阻止打开，请联系发布者或公司 IT。'
fi
if [ "${NOTARIZE:-0}" = 1 ]; then
    bash scripts/notarize.sh "$APP"
    SIGNING_NOTE='此包已使用 Developer ID 签名并通过 Apple 公证。'
fi
STAGE="$PWD/.build/distribution/$BUILD_CHANNEL/$ARCH/XD VPN $PACKAGE_VERSION"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUTPUT_DIRECTORY"
ditto "$APP" "$STAGE/XD VPN.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/开始使用.txt" <<EOF
XD VPN 内置引擎版
版本：${PACKAGE_VERSION}

适用：${MACHINE}，最低系统目标为 macOS 14。
无需安装 Homebrew 或 OpenConnect。

1. 将「XD VPN.app」拖到旁边的「Applications」文件夹，再从「应用程序」打开应用。
2. 在「VPN 配置」填写自己的 VPN 账号与密码并保存。
3. 在连接页点击「启用系统服务」，按提示在 macOS 系统设置中批准后台服务。
   返回应用后自动检测；若提示旧授权待迁移，先退出旧版，再点击「迁移旧版授权」。
4. 返回连接页，点击「连接 VPN」。

升级前请先断开并退出旧版。原有 XD VPN 配置和钥匙串密码可继续使用。
${SIGNING_NOTE}
不支持验证码、浏览器 SSO 或交互式 MFA 登录。

运行所需的引擎、网络脚本和第三方许可证均保留在 XD VPN.app 内，
无需另外安装依赖。
EOF
OUTPUT="$OUTPUT_DIRECTORY/XD-VPN-$PACKAGE_VERSION-macOS-$ARCH.dmg"
hdiutil create -ov -volname "XD VPN $PACKAGE_VERSION" -srcfolder "$STAGE" -format UDZO "$OUTPUT"
hdiutil verify "$OUTPUT"
if [ "$BUILD_CHANNEL" = release ] || [ "${NOTARIZE:-0}" = 1 ]; then
    source scripts/signing.sh
    xdvpn_sign com.xd.vpn.disk-image "$OUTPUT"
    codesign --verify --strict "$OUTPUT"
fi
if [ "${NOTARIZE:-0}" = 1 ]; then
    bash scripts/notarize.sh "$OUTPUT"
fi
(cd "$OUTPUT_DIRECTORY" && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
printf 'Packaged: %s\n' "$OUTPUT"
