#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
IOS_ROOT="$PWD"
BUILD="$IOS_ROOT/.build/engine"
DOWNLOADS="$BUILD/downloads"
SDK="${1:-iphoneos}"
case "$SDK" in
  iphoneos) TRIPLE=arm64-apple-ios17.0; SSL_TARGET=ios64-xcrun ;;
  iphonesimulator) TRIPLE=arm64-apple-ios17.0-simulator; SSL_TARGET=iossimulator-arm64-xcrun ;;
  *) echo 'Usage: build-engine.sh [iphoneos|iphonesimulator]' >&2; exit 2 ;;
esac
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH MACOSX_DEPLOYMENT_TARGET
export SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
export CONFIG_SITE=/dev/null lt_cv_sys_max_cmd_len=16384
JOBS="${XDVPN_BUILD_JOBS:-8}"
TARGET="$BUILD/$SDK"
mkdir -p "$DOWNLOADS" "$TARGET"
fetch() {
  local name="$1" url="$2" sha="$3"
  if [ ! -f "$DOWNLOADS/$name" ]; then
    if [ -n "${XDVPN_SOURCE_CACHE:-}" ] && [ -f "$XDVPN_SOURCE_CACHE/$name" ]; then
      cp "$XDVPN_SOURCE_CACHE/$name" "$DOWNLOADS/$name"
    else
      curl --fail --location --connect-timeout 20 --max-time 300 "$url" -o "$DOWNLOADS/$name.part"
      mv "$DOWNLOADS/$name.part" "$DOWNLOADS/$name"
    fi
  fi
  [ "$(shasum -a 256 "$DOWNLOADS/$name" | awk '{print $1}')" = "$sha" ] || { echo "Checksum mismatch: $name" >&2; exit 1; }
}
fetch openconnect-9.21.tar.gz https://www.infradead.org/openconnect/download/openconnect-9.21.tar.gz 5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
fetch openssl-3.6.2.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.6.2/openssl-3.6.2.tar.gz aaf51a1fe064384f811daeaeb4ec4dce7340ec8bd893027eee676af31e83a04f
fetch pkgconf-3.0.6.tar.xz https://distfiles.ariadne.space/pkgconf/pkgconf-3.0.6.tar.xz c88a653fbabfa2a5857a30f6b6ad6c40dbacc3b7c72cc066e5c7dc4571cbddaa
TOOLS="$BUILD/host-tools"
if [ ! -x "$TOOLS/bin/pkgconf" ]; then
  mkdir -p "$TOOLS/sources"
  tar -xf "$DOWNLOADS/pkgconf-3.0.6.tar.xz" -C "$TOOLS/sources"
  (
    cd "$TOOLS/sources/pkgconf-3.0.6"
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    CC="$(xcrun -f clang)" ./configure --prefix="$TOOLS" --disable-shared --enable-static
    make -j "$JOBS"
    make install
  )
fi
STAMP="$(shasum -a 256 scripts/build-engine.sh scripts/patch-openconnect.py)-$PWD-$SDKROOT-$(xcrun clang --version)"
if [ -s "$TARGET/lib/libopenconnect.a" ] && [ -f "$TARGET/recipe" ] && [ "$(cat "$TARGET/recipe")" = "$STAMP" ]; then
  echo "Engine cached: $SDK"; exit 0
fi
# Only generated sources inside this SDK's build cache are replaced.
rm -rf "$TARGET/sources/openconnect-9.21"
mkdir -p "$TARGET/sources" "$TARGET/lib" "$TARGET/include" "$TARGET/licenses"
[ -d "$TARGET/sources/openssl-3.6.2" ] || tar -xzf "$DOWNLOADS/openssl-3.6.2.tar.gz" -C "$TARGET/sources"
tar -xzf "$DOWNLOADS/openconnect-9.21.tar.gz" -C "$TARGET/sources"
SSL="$TARGET/sources/openssl-3.6.2"
OC="$TARGET/sources/openconnect-9.21"
python3 scripts/patch-openconnect.py "$OC"
FLAGS="-target $TRIPLE -isysroot $SDKROOT -O2 -fapplication-extension"
(
  cd "$SSL"
  SSL_STAMP="$SSL_TARGET|$FLAGS|$SDKROOT|$(xcrun clang --version)|3.6.2-no-shared-no-module-no-dso-no-engine-no-tests-no-apps-no-autoload-config"
  if [ ! -s libssl.a ] || [ ! -f .ios-recipe ] || [ "$(cat .ios-recipe)" != "$SSL_STAMP" ]; then
  [ ! -f Makefile ] || make clean
  CC="$(xcrun --sdk "$SDK" -f clang)" CFLAGS="$FLAGS" ./Configure "$SSL_TARGET" no-shared no-module no-dso no-engine no-tests no-apps no-autoload-config --prefix="$TARGET/openssl-prefix"
  make -j "$JOBS" build_libs
  printf '%s' "$SSL_STAMP" > .ios-recipe
  fi
)
(
  cd "$OC"
  BUILD_TRIPLE="$(/bin/sh ./config.guess)"
  PKG_CONFIG="$TOOLS/bin/pkgconf" PKG_CONFIG_LIBDIR="$TOOLS/lib/pkgconfig" \
  LIBXML2_CFLAGS="-I$SDKROOT/usr/include/libxml2" LIBXML2_LIBS=-lxml2 \
  ZLIB_CFLAGS="-I$SDKROOT/usr/include" ZLIB_LIBS=-lz \
  OPENSSL_CFLAGS="-I$SSL/include" OPENSSL_LIBS="-L$SSL -lssl -lcrypto -lz" \
  ac_cv_func_strchrnul=no ac_cv_func_fork=no ac_cv_func_vfork=no ac_cv_func_posix_spawn=no \
  CC="$(xcrun --sdk "$SDK" -f clang)" CFLAGS="$FLAGS" \
  ./configure --build="$BUILD_TRIPLE" --host=aarch64-apple-darwin \
    --prefix="$TARGET/openconnect-prefix" --disable-maintainer-mode --disable-shared --enable-static --disable-nls \
    --without-gnutls --with-openssl --with-builtin-json --without-gssapi --without-libproxy \
    --without-stoken --without-libpskc --without-libpcsclite --without-lz4 --without-openssl-version-check \
    --with-vpnc-script=/usr/bin/false
  make -j "$JOBS" libopenconnect.la
)
cp "$OC/.libs/libopenconnect.a" "$SSL/libssl.a" "$SSL/libcrypto.a" "$TARGET/lib/"
cp "$OC/openconnect.h" "$TARGET/include/"
cp "$OC/COPYING.LGPL" "$TARGET/licenses/OpenConnect-LGPL-2.1.txt"
cp "$SSL/LICENSE.txt" "$TARGET/licenses/OpenSSL-Apache-2.0.txt"
# Reject process creation in every compiled object, even unreferenced protocols.
if xcrun nm -u "$TARGET/lib/"*.a | /usr/bin/grep -E ' U _(fork|vfork|execv|execl|execve|posix_spawn|system|popen)$'; then
  echo 'Forbidden process API in iOS engine' >&2; exit 1
fi
printf '%s' "$STAMP" > "$TARGET/recipe"
echo "Built iOS engine: $SDK / $TRIPLE"
