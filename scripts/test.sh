#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh
export XDVPN_TEST_OPENCONNECT="${XDVPN_TEST_OPENCONNECT:-$PWD/.build/openconnect/runtime/openconnect}"
export XDVPN_TEST_VPNC_SCRIPT="${XDVPN_TEST_VPNC_SCRIPT:-$PWD/.build/openconnect/runtime/vpnc-script}"
if [[ ! -x "$XDVPN_TEST_OPENCONNECT" || ! -s "$XDVPN_TEST_OPENCONNECT" || ! -x "$XDVPN_TEST_VPNC_SCRIPT" || ! -s "$XDVPN_TEST_VPNC_SCRIPT" ]]; then
    echo 'Bundled test runtime is missing. Run bash scripts/build-openconnect.sh, then rerun scripts/test.sh.' >&2
    exit 1
fi
swift test --disable-sandbox --scratch-path "$XDVPN_BUILD_ROOT" --cache-path "$XDVPN_BUILD_ROOT/cache" "$@"
