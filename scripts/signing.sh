#!/bin/bash
# Resolve only Developer ID Application identities for production distribution.
xdvpn_configure_signing() {
    if [ "${BUILD_CHANNEL:-development}" = release ]; then
        export APPLE_TEAM_ID="${APPLE_TEAM_ID:-KQY8A3BNVG}"
        local identities resolved
        identities="$(security find-identity -v -p codesigning)"
        resolved="$(printf '%s\n' "$identities" | python3 -c '
import os, re, sys
identities = re.findall(r"([0-9A-F]{40}) \"(Developer ID Application: [^\"]+)\"", sys.stdin.read())
requested = os.environ.get("SIGNING_IDENTITY", "")
team = os.environ.get("APPLE_TEAM_ID", "")
choices = [(key, name) for key, name in identities if (not requested or requested in (key, name)) and (not team or name.endswith("(" + team + ")"))]
if len(choices) != 1:
    sys.exit("Release requires exactly one matching company Developer ID Application identity. Set SIGNING_IDENTITY and APPLE_TEAM_ID; Apple Development/ad-hoc signing is not accepted.")
print(choices[0][0])
')" || return 1
        export SIGNING_IDENTITY="$resolved"
    fi
    if [ "${NOTARIZE:-0}" = 1 ] && [ "${SIGNING_IDENTITY:--}" = - ]; then
        echo 'Notarization requires a Developer ID SIGNING_IDENTITY.' >&2; return 1
    fi
}

xdvpn_verify_release_signature() {
    local target="$1" details
    codesign --verify --deep --strict "$target" || return 1
    details="$(codesign -d --verbose=4 "$target" 2>&1)"
    [[ "$details" = *'Authority=Developer ID Application:'* && "$details" = *'runtime'* && "$details" = *'Timestamp='* ]] || {
        echo 'Release requires Developer ID signing, hardened runtime and a secure timestamp.' >&2; return 1;
    }
    local expected_team="${APPLE_TEAM_ID:-KQY8A3BNVG}"
    if [ -n "$expected_team" ]; then
        [[ "$details" = *"TeamIdentifier=$expected_team"* ]] || { echo 'Release signing team mismatch.' >&2; return 1; }
    fi
}

xdvpn_sign() {
    local identifier="$1" target="$2"
    if [ "${SIGNING_IDENTITY:--}" != - ]; then
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp --identifier "$identifier" "$target"
    elif [ "${NOTARIZE:-0}" = 1 ] || [ "${BUILD_CHANNEL:-development}" = release ]; then
        echo 'Release/notarization requires a Developer ID SIGNING_IDENTITY.' >&2; return 1
    else
        codesign --force --sign - --identifier "$identifier" "$target"
    fi
}
