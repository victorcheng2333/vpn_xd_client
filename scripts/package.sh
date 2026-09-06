#!/bin/bash
# Distribute the application together with notices and corresponding sources.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/architectures.sh
# With no target/output override, produce two independent application archives.
if [ "${ARCHS+x}" != x ] && [ "${APP_OUTPUT+x}" != x ]; then
    for TARGET in arm64 x86_64; do
        ARCHS="$TARGET" bash scripts/package.sh
    done
    exit 0
fi
TARGET_ARCHS="$(xdvpn_architectures "${ARCHS-$(uname -m)}")"
SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP="${APP_OUTPUT:-$PWD/dist/XD VPN $SOURCE_VERSION-$TARGET_ARCHS.app}"
# A release command builds the complete payload before packaging it. Use
# SKIP_BUILD=1 only to repackage an existing, verified application.
if [ "${SKIP_BUILD:-0}" != 1 ]; then
    APP_OUTPUT="$APP" bash scripts/build.sh
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
TARGET_ARCHS="$(xdvpn_architectures "$(/usr/bin/lipo -archs "$APP/Contents/MacOS/XDVPN")")"
xdvpn_verify_architectures "$APP/Contents/MacOS/XDVPN" "$TARGET_ARCHS"
if [ "${ARCHS+x}" = x ]; then
    xdvpn_verify_architectures "$APP/Contents/MacOS/XDVPN" "$(xdvpn_architectures "$ARCHS")"
fi
xdvpn_verify_architectures "$APP/Contents/Helpers/XDVPNHelper" "$TARGET_ARCHS"
xdvpn_verify_engine "$APP/Contents/Resources/OpenConnect/openconnect" "$TARGET_ARCHS"
case "$TARGET_ARCHS" in
    arm64) ARCH=arm64; MACHINE='Apple Silicon（M 系列）Mac' ;;
    x86_64) ARCH=x86_64; MACHINE='Intel Mac' ;;
esac
codesign --verify --deep --strict "$APP"
test -x "$APP/Contents/Resources/OpenConnect/openconnect"
test -x "$APP/Contents/Resources/OpenConnect/vpnc-script"
STAGE="$PWD/.build/distribution/$ARCH/XD VPN $VERSION"
SOURCES="$STAGE/ThirdPartySources"
rm -rf "$STAGE"
mkdir -p "$SOURCES/archives" "$SOURCES/scripts" dist
ditto "$APP" "$STAGE/XD VPN.app"
cp .build/openconnect/downloads/openconnect-9.21.tar.gz \
   .build/openconnect/downloads/openssl-3.6.2.tar.gz \
   .build/openconnect/downloads/pkgconf-3.0.6.tar.xz \
   .build/openconnect/downloads/vpnc-script \
   .build/openconnect/downloads/GPL-2.0.txt "$SOURCES/archives/"
cp scripts/build-openconnect.sh scripts/architectures.sh "$SOURCES/scripts/"
cp -R "$APP/Contents/Resources/ThirdParty" "$STAGE/ThirdPartyLicenses"
# Include the actual GPL script source emitted by the network wrapper as well.
python3 - "$SOURCES/vpnc-script-xdvpn" <<'PY'
from pathlib import Path
import re, sys, textwrap
swift = Path('Sources/VPNCore/TunnelNetworkSession.swift').read_text()
override = re.search(r'let overrides = """\n(.*?)\n        """', swift, re.S)
assert override
source = Path('.build/openconnect/downloads/vpnc-script').read_text()
assert source.count('#### Main') == 1
modified = source.replace('#### Main', textwrap.dedent(override.group(1)) + '\n#### Main')
Path(sys.argv[1]).write_text(modified.replace('#!/bin/sh\n', '#!/bin/sh\n# XD VPN runtime variant, 2026-09-06; modifications are below before Main.\n', 1))
PY
cat > "$SOURCES/README.txt" <<'EOF'
Corresponding source for the bundled OpenConnect engine

OpenConnect 9.21 (LGPL 2.1), OpenSSL 3.6.2 (Apache 2.0),
vpnc-script (GPL 2 or later), and pkgconf 3.0.6 (build tool only).
Source archives are unmodified upstream releases, verified by SHA-256 in
scripts/build-openconnect.sh. That script statically links OpenSSL and
OpenConnect; macOS supplies libSystem, libxml2, libz and libiconv.
External OpenSSL modules and automatic configuration loading are disabled.

To rebuild on a Mac with Xcode / Command Line Tools (Homebrew is not needed):
  cd ThirdPartySources
  # Upstream build tools require a source path without spaces.
  build_dir="$(mktemp -d /private/tmp/xdvpn-source.XXXXXXXX)"
  cp -R . "$build_dir/"
  cd "$build_dir"
  mkdir -p .build/openconnect/downloads
  cp archives/* .build/openconnect/downloads/
  bash scripts/build-openconnect.sh

The default rebuild targets the build machine's architecture.
To select a target, use ARCHS=arm64 or ARCHS=x86_64 before bash.
Both targets can be cross-compiled on either Mac architecture; Rosetta is
only needed to run x86_64 validation on an Apple Silicon build machine.
The executable and original vpnc-script are produced in
.build/openconnect/<architecture>/runtime.
The supplied archives permit this rebuild without downloading third-party code.
Build output and installed application files are not assumed to be trusted merely
because they were built here; the app's administrator installation verifies them.

vpnc-script-xdvpn is the corresponding source of the script generated at runtime
by XD VPN when it manages the server route. It overrides the original gateway,
default-route restoration and persistent networksetup DNS operations. The original
script, copyright notices and full GPL text are also included.

Sources: https://www.infradead.org/openconnect/download.html
https://github.com/openssl/openssl/releases/tag/openssl-3.6.2
https://gitlab.com/openconnect/vpnc-scripts
https://github.com/pkgconf/pkgconf
EOF
cat > "$STAGE/开始使用.txt" <<EOF
XD VPN 内置引擎版

适用：${MACHINE}，最低系统目标为 macOS 14。
无需安装 Homebrew 或 OpenConnect。

1. 将「XD VPN.app」复制到「应用程序」目录，打开应用。
2. 在「VPN 配置」填写自己的 VPN 账号与密码并保存。
3. 打开「系统授权」，点击「安装系统助手」，完成一次 Mac 管理员确认。
   助手、内置引擎和网络脚本会一起安装。已有旧版则点击「升级系统助手」。
4. 返回连接页，点击「连接 VPN」。

升级前请先断开并退出旧版。原有 XD VPN 配置和钥匙串密码可继续使用。
当前版本为本地签名，未做 Apple 公证；若 macOS 阻止打开，请联系发送者或公司 IT。
不支持验证码、浏览器 SSO 或交互式 MFA 登录。

ThirdPartySources 和 ThirdPartyLicenses 是随包提供的开源组件源码与许可证，
无需安装。转发本软件时请一并保留。
EOF
OUTPUT="$PWD/dist/XD-VPN-$VERSION-macOS-$ARCH-bundled.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$OUTPUT"
unzip -t "$OUTPUT" > "$PWD/.build/bundled-zip-test.log"
printf 'Packaged: %s\n' "$OUTPUT"
