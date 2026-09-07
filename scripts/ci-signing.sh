#!/bin/bash
# Import company signing credentials on disposable GitHub runners only.
set -euo pipefail
: "${APPLE_CERTIFICATE_P12:?}" "${APPLE_CERTIFICATE_PASSWORD:?}" "${APPLE_SIGNING_IDENTITY:?}"
: "${APPLE_TEAM_ID:?}"
[ "${NOTARIZE:-1}" = 1 ] || { echo 'Release requires Apple notarization; NOTARIZE must be 1.' >&2; exit 1; }
export NOTARIZE=1
: "${APPLE_ID:?Notarization requires APPLE_ID}" "${APPLE_APP_PASSWORD:?Notarization requires APPLE_APP_PASSWORD}"
KEYCHAIN="$RUNNER_TEMP/xdvpn-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
printf '%s' "$APPLE_CERTIFICATE_P12" | base64 --decode > "$RUNNER_TEMP/certificate.p12"
trap 'rm -f "$RUNNER_TEMP/certificate.p12"' EXIT
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$RUNNER_TEMP/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN"
printf 'SIGNING_IDENTITY=%s\nAPPLE_TEAM_ID=%s\n' "$APPLE_SIGNING_IDENTITY" "$APPLE_TEAM_ID" >> "$GITHUB_ENV"
if [ "${NOTARIZE:-0}" = 1 ]; then
    xcrun notarytool store-credentials xdvpn-notary --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --keychain "$KEYCHAIN"
    # Make it the default so notarytool can locate the profile without exposing secrets.
    security default-keychain -d user -s "$KEYCHAIN"
    printf 'NOTARY_KEYCHAIN_PROFILE=xdvpn-notary\n' >> "$GITHUB_ENV"
fi
