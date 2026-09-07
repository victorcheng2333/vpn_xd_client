#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -n "${1:-}" ] || { echo 'Usage: test-native-session.sh SIMULATOR_UDID' >&2; exit 2; }
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/xdvpn-session.XXXXXX")"
fixture_pid=""
cleanup() {
  if [ -n "$fixture_pid" ]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture_dir"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
  -keyout "$fixture_dir/key.pem" -out "$fixture_dir/cert.pem" > "$fixture_dir/cert.log" 2>&1
python3 Tests/SessionExpiryServer.py "$fixture_dir/cert.pem" "$fixture_dir/key.pem" "${2:-expiry}" > "$fixture_dir/port" &
fixture_pid=$!
for _ in {1..30}; do
  [ -s "$fixture_dir/port" ] && break
  kill -0 "$fixture_pid" 2>/dev/null || { echo 'Fixture server failed' >&2; exit 1; }
  sleep 0.1
done
[ -s "$fixture_dir/port" ] || { echo 'Fixture startup timed out' >&2; exit 1; }
bash scripts/test-native.sh "$1" "" "" "$(cat "$fixture_dir/port")" "${2:-expiry}"
