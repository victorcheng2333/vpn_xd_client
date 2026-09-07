#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${1:-iphonesimulator}"
case "$SDK" in iphoneos|iphonesimulator) ;; *) echo 'Usage: build.sh [iphoneos|iphonesimulator]' >&2; exit 2 ;; esac
# Xcode's build phase builds the engine. Override CODE_SIGNING_ALLOWED=YES in Xcode for device deployment.
xcodebuild -project XDVPN.xcodeproj -scheme XDVPN-iOS -configuration Debug -sdk "$SDK" \
  -destination "generic/platform=$([ "$SDK" = iphoneos ] && echo iOS || echo 'iOS Simulator')" \
  -derivedDataPath "$PWD/.build/xcode-$SDK" CODE_SIGNING_ALLOWED=NO build
