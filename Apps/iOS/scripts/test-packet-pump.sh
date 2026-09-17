#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
SDK=macosx
FLAGS=(-module-cache-path "$PWD/.build/tests/module-cache")
OUTPUT=.build/tests/packet-pump-tests
if [ -n "${1:-}" ]; then
  SDK=iphonesimulator
  FLAGS+=(-target arm64-apple-ios17.0-simulator)
  OUTPUT=.build/tests/packet-pump-tests-simulator
fi
xcrun swiftc "${FLAGS[@]}" -sdk "$(xcrun --sdk "$SDK" --show-sdk-path)" \
  Common/PacketCodec.swift PacketTunnel/PacketPump.swift Tests/PacketPumpTests.swift \
  -o "$OUTPUT"
if [ -n "${1:-}" ]; then
  xcrun simctl spawn "$1" "$PWD/$OUTPUT"
else
  "$OUTPUT"
fi
