#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/.build/engine"
DOWNLOADS="$BUILD/downloads"
NDK_VERSION=28.2.13676358
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/$NDK_VERSION}"
[ -d "$NDK" ] || NDK="$ROOT/.build/tools/android-ndk-r28c"
[ -d "$NDK" ] || { echo "Install NDK $NDK_VERSION using sdkmanager, or set ANDROID_NDK_HOME." >&2; exit 1; }
grep -q "$NDK_VERSION" "$NDK/source.properties" || { echo 'Unexpected NDK version' >&2; exit 1; }
case "$(uname -s)" in Darwin) HOST=darwin-x86_64 ;; Linux) HOST=linux-x86_64 ;; *) exit 2 ;; esac
TC="$NDK/toolchains/llvm/prebuilt/$HOST"
export PATH="$TC/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH SDKROOT MACOSX_DEPLOYMENT_TARGET
export CONFIG_SITE=/dev/null lt_cv_sys_max_cmd_len=16384
JOBS="${XDVPN_BUILD_JOBS:-8}"
mkdir -p "$DOWNLOADS"
fetch() {
  local name="$1" url="$2" sha="$3"
  if [ ! -f "$DOWNLOADS/$name" ]; then
    if [ -n "${XDVPN_SOURCE_CACHE:-}" ] && [ -f "$XDVPN_SOURCE_CACHE/$name" ]; then
      cp "$XDVPN_SOURCE_CACHE/$name" "$DOWNLOADS/$name"
    else
      curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 "$url" -o "$DOWNLOADS/$name.part"
      mv "$DOWNLOADS/$name.part" "$DOWNLOADS/$name"
    fi
  fi
  [ "$(shasum -a 256 "$DOWNLOADS/$name" | awk '{print $1}')" = "$sha" ] || { echo "Checksum mismatch: $name" >&2; exit 1; }
}
fetch openconnect-9.21.tar.gz https://www.infradead.org/openconnect/download/openconnect-9.21.tar.gz 5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
fetch openssl-3.6.2.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.6.2/openssl-3.6.2.tar.gz aaf51a1fe064384f811daeaeb4ec4dce7340ec8bd893027eee676af31e83a04f
fetch libxml2-2.15.4.tar.xz https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.tar.xz 98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821
fetch pkgconf-3.0.6.tar.xz https://distfiles.ariadne.space/pkgconf/pkgconf-3.0.6.tar.xz c88a653fbabfa2a5857a30f6b6ad6c40dbacc3b7c72cc066e5c7dc4571cbddaa
TOOLS="$BUILD/host-tools"
if [ ! -x "$TOOLS/bin/pkgconf" ]; then
    mkdir -p "$TOOLS/src"
    tar -xf "$DOWNLOADS/pkgconf-3.0.6.tar.xz" -C "$TOOLS/src"
    (cd "$TOOLS/src/pkgconf-3.0.6"; PATH=/usr/bin:/bin:/usr/sbin:/sbin CC=cc ./configure --prefix="$TOOLS" --disable-shared; make -j "$JOBS"; make install)
fi
export PKG_CONFIG="$TOOLS/bin/pkgconf"
mkdir -p "$ROOT/.build/assets/licenses"
ABIS="${XDVPN_ANDROID_ABIS:-arm64-v8a x86_64}"
for ABI in $ABIS; do
  case "$ABI" in
    arm64-v8a) TRIPLE=aarch64-linux-android; SSL_TARGET=android-arm64 ;;
    x86_64) TRIPLE=x86_64-linux-android; SSL_TARGET=android-x86_64 ;;
    *) echo "Unsupported ABI $ABI" >&2; exit 2 ;;
  esac
  TARGET="$BUILD/$ABI"
  OUT="$ROOT/.build/jniLibs/$ABI"
  STAMP="$(shasum -a 256 scripts/build-engine.sh scripts/patch-openconnect.py native/engine.c)-$ROOT-$NDK-$ABI"
  if [ -d "$TARGET/licenses" ]; then cp "$TARGET/licenses/"*.txt "$ROOT/.build/assets/licenses/"; fi
  if [ -s "$OUT/libxdvpn.so" ] && [ -f "$TARGET/recipe" ] && [ "$(cat "$TARGET/recipe")" = "$STAMP" ]; then
    echo "Engine cached: $ABI"; continue
  fi
  mkdir -p "$TARGET/src" "$TARGET/lib" "$TARGET/include" "$TARGET/licenses" "$OUT"
  DEPENDENCY_RECIPE="$(shasum -a 256 scripts/build-engine.sh)-$NDK-$ABI"
  if [ ! -f "$TARGET/dependency-recipe" ] || [ "$(cat "$TARGET/dependency-recipe")" != "$DEPENDENCY_RECIPE" ]; then
    rm -rf "$TARGET/src/openssl-3.6.2" "$TARGET/src/libxml2-2.15.4"
  fi
  for archive in openssl-3.6.2.tar.gz libxml2-2.15.4.tar.xz; do
    name="${archive%.tar.*}"
    [ -d "$TARGET/src/$name" ] || tar -xf "$DOWNLOADS/$archive" -C "$TARGET/src"
  done
  rm -rf "$TARGET/src/openconnect-9.21"
  tar -xf "$DOWNLOADS/openconnect-9.21.tar.gz" -C "$TARGET/src"
  SSL="$TARGET/src/openssl-3.6.2"; XML="$TARGET/src/libxml2-2.15.4"; OC="$TARGET/src/openconnect-9.21"
  python3 scripts/patch-openconnect.py "$OC"
  FLAGS='-O2 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2'
  export AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" STRIP="$TC/bin/llvm-strip"
  (
    cd "$SSL"
    if [ ! -s libssl.a ]; then
      ANDROID_NDK_ROOT="$NDK" CC=clang CFLAGS="$FLAGS" ./Configure "$SSL_TARGET" -D__ANDROID_API__=28 no-shared no-module no-dso no-engine no-tests no-apps no-autoload-config
      make -j "$JOBS" build_libs
    fi
  )
  (
    cd "$XML"
    if [ ! -s .libs/libxml2.a ]; then
      CC="$TC/bin/${TRIPLE}28-clang" CFLAGS="$FLAGS" ./configure --host="$TRIPLE" --prefix="$TARGET/xml-prefix" --disable-shared --enable-static --without-python --without-programs --without-iconv --without-readline --without-lzma --without-zlib --without-http --without-ftp
      make -j "$JOBS"
    fi
  )
  (
    cd "$OC"
    PKG_CONFIG="$TOOLS/bin/pkgconf" PKG_CONFIG_LIBDIR="$TOOLS/lib/pkgconfig" \
    LIBXML2_CFLAGS="-I$XML/include" LIBXML2_LIBS="-L$XML/.libs -lxml2 -lm" \
    ZLIB_CFLAGS=" " ZLIB_LIBS=-lz \
    OPENSSL_CFLAGS="-I$SSL/include" OPENSSL_LIBS="-L$SSL -lssl -lcrypto -lz" \
    CC="$TC/bin/${TRIPLE}28-clang" CFLAGS="$FLAGS" \
    ./configure --build="$(/bin/sh ./config.guess)" --host="$TRIPLE" --prefix="$TARGET/oc-prefix" \
      --disable-maintainer-mode --disable-shared --enable-static --disable-nls --without-gnutls --with-openssl --with-builtin-json --without-gssapi --without-libproxy \
      --without-stoken --without-libpskc --without-libpcsclite --without-lz4 --without-openssl-version-check --without-java --with-vpnc-script=/system/bin/false
    make -j "$JOBS" libopenconnect.la
  )
  cp "$OC/.libs/libopenconnect.a" "$SSL/libssl.a" "$SSL/libcrypto.a" "$XML/.libs/libxml2.a" "$TARGET/lib/"
  cp "$OC/openconnect.h" "$TARGET/include/"
  cp "$OC/COPYING.LGPL" "$TARGET/licenses/OpenConnect-LGPL-2.1.txt"
  cp "$SSL/LICENSE.txt" "$TARGET/licenses/OpenSSL-Apache-2.0.txt"
  cp "$XML/Copyright" "$TARGET/licenses/libxml2-MIT.txt"
  cp "$TARGET/licenses/"*.txt "$ROOT/.build/assets/licenses/"
  "$TC/bin/${TRIPLE}28-clang" $FLAGS -Wall -Wextra -Werror -Wno-unused-parameter -shared \
    -I"$TARGET/include" -I"$SSL/include" native/engine.c -o "$OUT/libxdvpn.so" \
    -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -Wl,-z,relro,-z,now -Wl,--build-id=sha1 \
    -Wl,--exclude-libs,ALL -Wl,--no-undefined -Wl,-soname,libxdvpn.so \
    "$TARGET/lib/libopenconnect.a" "$TARGET/lib/libssl.a" "$TARGET/lib/libcrypto.a" "$TARGET/lib/libxml2.a" -lz -lm -ldl -landroid
  if "$TC/bin/llvm-nm" -u "$OUT/libxdvpn.so" | grep -E ' U (fork|vfork|execv|execl|execve|posix_spawn|system|popen)$'; then
      echo 'Forbidden external process API in engine' >&2; exit 1
  fi
  cp "$OUT/libxdvpn.so" "$TARGET/libxdvpn-unstripped.so"
  "$STRIP" --strip-unneeded "$OUT/libxdvpn.so"
  printf '%s' "$DEPENDENCY_RECIPE" > "$TARGET/dependency-recipe"
  printf '%s' "$STAMP" > "$TARGET/recipe"
  echo "Built Android engine: $ABI"
done
