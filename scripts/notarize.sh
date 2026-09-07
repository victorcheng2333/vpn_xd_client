#!/bin/bash
set -euo pipefail
TARGET="$1"
: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE to stored notarytool credentials}"
UPLOAD="$TARGET"
TEMP_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT
if [[ "$TARGET" = *.app ]]; then
    UPLOAD="$TEMP_DIRECTORY/application.zip"
    ditto -c -k --keepParent "$TARGET" "$UPLOAD"
fi
xcrun notarytool submit "$UPLOAD" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
