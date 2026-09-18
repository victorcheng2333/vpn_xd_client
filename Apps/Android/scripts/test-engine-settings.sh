#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${XDVPN_ANDROID_TEST_ENGINE:-$PWD/.build/engine/arm64-v8a}"
OC="$TARGET/src/openconnect-9.21"
[ -f "$OC/tun.c" ] || { echo 'Build the Android engine first (scripts/build-engine.sh).' >&2; exit 1; }
TEST_BUILD="$PWD/.build/tests/engine-settings"
mkdir -p "$TEST_BUILD"
JDK="${JAVA_HOME:-}"
case "$(uname -s)" in
  Darwin) [ -n "$JDK" ] || JDK="$(/usr/libexec/java_home -v 17)"; JNI_OS=darwin ;;
  Linux) [ -n "$JDK" ] || JDK="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"; JNI_OS=linux ;;
  *) echo 'Host isolation test supports macOS/Linux.' >&2; exit 2 ;;
esac
# Compile exact production function bodies, with only the platform/JNI/polling
# environment replaced. No duplicate implementation of the settings logic.
python3 - "$OC" "$TEST_BUILD/engine-settings-production.inc" <<'PY'
from pathlib import Path
import re, sys
adapter = Path('native/engine.c').read_text()
tun = (Path(sys.argv[1]) / 'tun.c').read_text()
def function(source, name):
    masked = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', lambda m: ' ' * len(m[0]), source, flags=re.S)
    matches = list(re.finditer(r'^(?:static\s+)?(?:int|void|jobjectArray)\s+' + name + r'\([^;{}]*\)\s*\{', masked, re.M))
    assert len(matches) == 1, name
    match = matches[0]
    position = masked.index('{', match.start()) + 1
    depth = 1
    while depth:
        depth += (masked[position] == '{') - (masked[position] == '}')
        position += 1
    return source[match.start():position]
declarations = adapter[adapter.index('enum {'):adapter.index('static struct engine *from')]
names = ['exception', 'event', 'strings', 'routes', 'apply_settings', 'setup_tun', 'mtu_changed', 'reconnected']
Path(sys.argv[2]).write_text(function(tun, 'openconnect_setup_tun_fd') + '\n' + declarations + '\n' + '\n'.join(function(adapter, name) for name in names) + '\n')
PY
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter \
  -I"$JDK/include" -I"$JDK/include/$JNI_OS" -I"$OC" -I"$TEST_BUILD" \
  native/test-engine-settings.c -pthread -o "$TEST_BUILD/test-engine-settings"
"$TEST_BUILD/test-engine-settings"
