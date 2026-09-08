#!/usr/bin/env bash
# Run after build-engine.sh compiles its pinned OpenConnect static library.
set -euo pipefail
export PYTHONUTF8=1
[ "${MSYSTEM:-}" = UCRT64 ] || { echo 'Use the MSYS2 UCRT64 environment'; exit 1; }
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
SOURCE="${1:-$ROOT/.build/windows-engine/source}"
OUT="$ROOT/.build/windows-engine/tests"
mkdir -p "$OUT"
python - "$SOURCE" "$OUT" <<'PY'
from pathlib import Path
import sys
source, out = map(Path, sys.argv[1:])
main = (source / 'main.c').read_text(encoding='utf-8')
a = main.index('static HANDLE xdvpn_start_gate;')
b = main.index('\n#endif', a)
bridge = main[a:b]
assert bridge.count('sig_vpninfo->need_poll_cmd_fd = 1;') == 2
assert bridge.count('sig_vpninfo->cmd_fd_internal = 0;') == 1
assert "else if (wire == 'S') cmd = OC_CMD_STATS;" in bridge
(out / 'control-bridge.inc').write_text(bridge, encoding='utf-8', newline='\n')
# Negative control: restore the missing polling behavior without changing any
# library code or command mapping. The test must observe the old stalled loop.
legacy = bridge.replace('sig_vpninfo->need_poll_cmd_fd = 1;', '')
legacy = legacy.replace('sig_vpninfo->cmd_fd_internal = 0;', '')
(out / 'control-bridge-legacy.inc').write_text(legacy, encoding='utf-8', newline='\n')
PY
# The dependency list comes from the same configure/libtool build as the library.
read -r -a dependencies <<< "$(sed -n "s/^dependency_libs='\(.*\)'$/\1/p" "$SOURCE/libopenconnect.la")"
[ "${#dependencies[@]}" -gt 0 ] || { echo 'Missing native link dependencies'; exit 1; }
common=(-O2 -Wall -Wextra -Wno-unused-parameter -I"$SOURCE" -I"$SOURCE/json" -I/ucrt64/include/libxml2 -I"$OUT")
gcc "${common[@]}" "$ROOT/Apps/Windows/native/test-control.c" "$SOURCE/.libs/libopenconnect.a" "${dependencies[@]}" -o "$OUT/test-control.exe"
gcc "${common[@]}" -DTEST_CONTROL_LEGACY=1 "$ROOT/Apps/Windows/native/test-control.c" "$SOURCE/.libs/libopenconnect.a" "${dependencies[@]}" -o "$OUT/test-control-legacy.exe"
gcc "${common[@]}" "$ROOT/Apps/Windows/native/test-wintun.c" "$SOURCE/.libs/libopenconnect.a" "${dependencies[@]}" -o "$OUT/test-wintun.exe"
{
  for command in C R E S; do
    "$OUT/test-control.exe" "$command"
    "$OUT/test-control-legacy.exe" "$command"
  done
  "$OUT/test-wintun.exe"
} 2>&1 | tee "$OUT/results.txt"