#!/usr/bin/env bash
# Run inside the MSYS2 UCRT64 shell on Windows. Sources are pinned; dependency versions are recorded.
set -euo pipefail
[ "${MSYSTEM:-}" = UCRT64 ] || { echo 'Use the MSYS2 UCRT64 environment'; exit 1; }
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="$ROOT/.build/windows-engine"
mkdir -p "$BUILD/downloads"
rm -rf "$BUILD/runtime" "$BUILD/licenses"
mkdir -p "$BUILD/runtime" "$BUILD/licenses"
fetch() {
  local url="$1" file="$2" sha="$3"
  if [ ! -f "$BUILD/downloads/$file" ]; then curl --fail --location --retry 3 "$url" -o "$BUILD/downloads/$file.part"; mv "$BUILD/downloads/$file.part" "$BUILD/downloads/$file"; fi
  echo "$sha  $BUILD/downloads/$file" | sha256sum -c -
}
fetch https://www.infradead.org/openconnect/download/openconnect-9.21.tar.gz openconnect-9.21.tar.gz 5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
fetch https://www.wintun.net/builds/wintun-0.14.1.zip wintun-0.14.1.zip 07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51
rm -rf "$BUILD/source"
mkdir -p "$BUILD/source"
tar -xzf "$BUILD/downloads/openconnect-9.21.tar.gz" -C "$BUILD/source" --strip-components=1
python "$ROOT/Apps/Windows/native/patch-openconnect.py" "$BUILD/source"
cd "$BUILD/source"
./configure --host=x86_64-w64-mingw32 --disable-shared --enable-static --disable-nls --disable-maintainer-mode \
 --with-gnutls --without-openssl --without-libproxy --without-stoken --without-libpskc --without-gssapi --without-pcsclite --with-builtin-json
make -j2 openconnect.exe
cp openconnect.exe "$BUILD/runtime/openconnect.exe"
python - "$BUILD/runtime" <<'PY'
from pathlib import Path
import subprocess,sys,shutil
out=Path(sys.argv[1]); lib=Path('/ucrt64/bin'); dlls={p.name.lower():p for p in lib.glob('*.dll')}
pending=[out/'openconnect.exe']; seen=set()
while pending:
    file=pending.pop()
    for line in subprocess.check_output(['objdump','-p',str(file)],text=True).splitlines():
        if 'DLL Name:' not in line: continue
        name=line.split('DLL Name:',1)[1].strip().lower()
        if name in seen: continue
        seen.add(name)
        if name in dlls:
            target=out/dlls[name].name;shutil.copy2(dlls[name],target);pending.append(target)
PY
unzip -o "$BUILD/downloads/wintun-0.14.1.zip" -d "$BUILD/wintun" >/dev/null
cp "$BUILD/wintun/wintun/bin/amd64/wintun.dll" "$BUILD/runtime/"
cp "$BUILD/wintun/wintun/LICENSE.txt" "$BUILD/licenses/Wintun.txt"
cp COPYING* "$BUILD/licenses/"
cp "$ROOT/Apps/Windows/native/patch-openconnect.py" "$BUILD/licenses/"
cp "$BUILD/downloads/openconnect-9.21.tar.gz" "$BUILD/licenses/"
cp "$ROOT/Apps/Windows/scripts/build-engine.sh" "$BUILD/licenses/"
# Ship MSYS2 package license files alongside the corresponding runtime DLLs.
cp -R /ucrt64/share/licenses "$BUILD/licenses/msys2"
pacman -Q > "$BUILD/licenses/dependency-versions.txt"
"$BUILD/runtime/openconnect.exe" --version
