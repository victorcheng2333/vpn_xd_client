#!/bin/bash
# Build a relocatable engine from pinned sources; Homebrew is not used.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD/.build/openconnect"
DOWNLOADS="$ROOT/downloads"
SOURCES="$ROOT/sources"
RUNTIME="$ROOT/runtime"
mkdir -p "$DOWNLOADS" "$SOURCES" "$RUNTIME" "$ROOT/licenses"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# Do not inherit Homebrew/compiler search paths from the developer's shell.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH
export CONFIG_SITE=/dev/null
# Libtool's Darwin probe uses a sandbox-restricted sysctl; use a conservative
# command length so archive splitting never receives an empty numeric limit.
export lt_cv_sys_max_cmd_len=16384
export MACOSX_DEPLOYMENT_TARGET=14.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
OPENCONNECT_VERSION=9.21
OPENSSL_VERSION=3.6.2
PKGCONF_VERSION=3.0.6
OPENCONNECT_SHA=5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
OPENSSL_SHA=aaf51a1fe064384f811daeaeb4ec4dce7340ec8bd893027eee676af31e83a04f
VPNC_SHA=f0c4d936a382f07711263242699b5e2d85d1ace37136bb78785d352997c17742

download() {
    local url="$1" name="$2" expected="$3"
    if [ ! -f "$DOWNLOADS/$name" ]; then
        curl --fail --location --connect-timeout 20 --max-time 300 "$url" -o "$DOWNLOADS/$name.part"
        mv "$DOWNLOADS/$name.part" "$DOWNLOADS/$name"
    fi
    [ "$(shasum -a 256 "$DOWNLOADS/$name" | awk '{print $1}')" = "$expected" ] || {
        echo "Source checksum mismatch: $name" >&2; exit 1;
    }
}
download "https://www.infradead.org/openconnect/download/openconnect-$OPENCONNECT_VERSION.tar.gz" "openconnect-$OPENCONNECT_VERSION.tar.gz" "$OPENCONNECT_SHA"
download "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA"
download "https://distfiles.ariadne.space/pkgconf/pkgconf-$PKGCONF_VERSION.tar.xz" "pkgconf-$PKGCONF_VERSION.tar.xz" c88a653fbabfa2a5857a30f6b6ad6c40dbacc3b7c72cc066e5c7dc4571cbddaa
download "https://gitlab.com/openconnect/vpnc-scripts/-/raw/ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101/vpnc-script" vpnc-script "$VPNC_SHA"
download "https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt" GPL-2.0.txt edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6

# Invalidate compilation when the build recipe or target changes.
RECIPE="$(shasum -a 256 scripts/build-openconnect.sh | awk '{print $1}')-$(uname -m)"
if [ ! -f "$ROOT/recipe" ] || [ "$(cat "$ROOT/recipe")" != "$RECIPE" ]; then
    rm -rf "$SOURCES/openssl-$OPENSSL_VERSION" "$SOURCES/openconnect-$OPENCONNECT_VERSION" "$SOURCES/pkgconf-$PKGCONF_VERSION"
    tar -xzf "$DOWNLOADS/openssl-$OPENSSL_VERSION.tar.gz" -C "$SOURCES"
    tar -xzf "$DOWNLOADS/openconnect-$OPENCONNECT_VERSION.tar.gz" -C "$SOURCES"
    tar -xf "$DOWNLOADS/pkgconf-$PKGCONF_VERSION.tar.xz" -C "$SOURCES"
    case "$(uname -m)" in
        arm64) OPENSSL_TARGET=darwin64-arm64-cc ;;
        x86_64) OPENSSL_TARGET=darwin64-x86_64-cc ;;
        *) echo "Unsupported architecture" >&2; exit 1 ;;
    esac
    JOBS="${XDVPN_BUILD_JOBS:-8}"
    (
        cd "$SOURCES/pkgconf-$PKGCONF_VERSION"
        ./configure --prefix="$ROOT/build-tools" --disable-shared --enable-static
        make -j "$JOBS"
        make install
    )
    (
        cd "$SOURCES/openssl-$OPENSSL_VERSION"
        ./Configure "$OPENSSL_TARGET" no-shared no-module no-dso no-tests no-autoload-config \
            --openssldir=/etc/ssl --prefix="$ROOT/openssl-prefix" -mmacosx-version-min=14.0
        make -j "$JOBS" build_libs
    )
    (
        cd "$SOURCES/openconnect-$OPENCONNECT_VERSION"
        # All third-party code is static. libxml2 and zlib come from the macOS SDK.
        PKG_CONFIG="$ROOT/build-tools/bin/pkgconf" PKG_CONFIG_LIBDIR="$ROOT/build-tools/lib/pkgconfig" \
        LIBXML2_CFLAGS="-I$SDKROOT/usr/include/libxml2" LIBXML2_LIBS=-lxml2 \
        ZLIB_CFLAGS="-I$SDKROOT/usr/include" ZLIB_LIBS=-lz \
        OPENSSL_CFLAGS="-I$SOURCES/openssl-$OPENSSL_VERSION/include" \
        OPENSSL_LIBS="-L$SOURCES/openssl-$OPENSSL_VERSION -lssl -lcrypto -lz -pthread" \
        ac_cv_func_strchrnul=no \
        CFLAGS="-O2 -mmacosx-version-min=14.0 -Werror=unguarded-availability-new" \
        ./configure --prefix="$ROOT/openconnect-prefix" --disable-maintainer-mode \
            --disable-shared --enable-static --disable-nls --without-gnutls \
            --with-openssl --with-builtin-json \
            --without-gssapi --without-libproxy --without-stoken --without-libpskc \
            --without-libpcsclite --without-lz4 --with-vpnc-script=/usr/bin/false
        make -j "$JOBS" openconnect
    )
    cp "$SOURCES/openconnect-$OPENCONNECT_VERSION/openconnect" "$RUNTIME/openconnect"
    strip -x "$RUNTIME/openconnect"
    printf '%s' "$RECIPE" > "$ROOT/recipe"
fi
cp "$DOWNLOADS/vpnc-script" "$RUNTIME/vpnc-script"
chmod 755 "$RUNTIME/openconnect" "$RUNTIME/vpnc-script"
codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier com.xd.vpn.openconnect "$RUNTIME/openconnect"
codesign --verify --strict "$RUNTIME/openconnect"
# Reject a binary that would load a developer-machine library after delivery.
otool -L "$RUNTIME/openconnect" | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { print "External library: " $1; bad=1 } END { exit bad }'
# macOS only exports strchrnul from 15.4; the engine must use its own fallback.
nm -u "$RUNTIME/openconnect" | awk '$NF == "_strchrnul" { print "Unsupported macOS 14 import: " $NF; bad=1 } END { exit bad }'
cp "$SOURCES/openconnect-$OPENCONNECT_VERSION/COPYING.LGPL" "$ROOT/licenses/OpenConnect-LGPL-2.1.txt"
cp "$SOURCES/openconnect-$OPENCONNECT_VERSION/README.md" "$ROOT/licenses/OpenConnect-README.md"
cp "$SOURCES/openconnect-$OPENCONNECT_VERSION/www/licence.xml" "$ROOT/licenses/OpenConnect-Licence-and-Notices.xml"
cp "$SOURCES/openssl-$OPENSSL_VERSION/LICENSE.txt" "$ROOT/licenses/OpenSSL-Apache-2.0.txt"
cp "$DOWNLOADS/GPL-2.0.txt" "$ROOT/licenses/vpnc-script-GPL-2.0.txt"
cp "$DOWNLOADS/vpnc-script" "$ROOT/licenses/vpnc-script-source.sh"
printf 'OpenConnect %s / OpenSSL %s / macOS 14+ / %s\n' "$OPENCONNECT_VERSION" "$OPENSSL_VERSION" "$(uname -m)" > "$ROOT/licenses/VERSIONS.txt"
"$RUNTIME/openconnect" --version
