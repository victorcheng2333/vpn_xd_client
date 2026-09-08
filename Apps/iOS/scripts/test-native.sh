#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -n "${1:-}" ] || { echo 'Usage: test-native.sh SIMULATOR_UDID [untrusted-local-https-url] [trusted-https-url] [loopback-session-port]' >&2; exit 2; }
mkdir -p .build/tests
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" -fobjc-arc -fapplication-extension \
  -IOpenConnectAdapter -I.build/engine/iphonesimulator/include \
  OpenConnectAdapter/OCEngine.m Tests/EngineSmoke.m -o .build/tests/engine-smoke \
  -L.build/engine/iphonesimulator/lib -lopenconnect -lssl -lcrypto -lxml2 -lz -liconv -framework Foundation -framework Security
xcrun simctl spawn "$1" "$PWD/.build/tests/engine-smoke" "${2:-}" "${3:-}" "${4:-}" "${5:-expiry}"
