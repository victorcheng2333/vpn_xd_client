#!/bin/bash
# Local release: prepare notarized artifacts, then publish the verified files.
set -euo pipefail
cd "$(dirname "$0")/.."
ACTION="${1:-}"
case "$ACTION" in
    prepare|publish) ;;
    *) echo 'Usage: bash scripts/release.sh prepare|publish vMAJOR.MINOR.PATCH' >&2; exit 1 ;;
esac
export BUILD_CHANNEL=release RELEASE_TAG="${2:?Provide an existing release tag}"
[ "${NOTARIZE:-1}" = 1 ] || { echo 'Release requires Apple notarization.' >&2; exit 1; }
export NOTARIZE=1 NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-xdvpn-notary}"
python3 scripts/version.py --check-git
python3 scripts/github-release.py check
if [ "$ACTION" = publish ]; then
    # Publisher independently checks tickets, signatures, embedded versions and source revision.
    python3 scripts/github-release.py publish
    exit 0
fi
source scripts/signing.sh
xdvpn_configure_signing
# Fail early rather than build for minutes with missing credentials or test runtimes.
xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --output-format json > /dev/null
for ARCH in arm64 x86_64; do
    /usr/bin/arch "-$ARCH" /usr/bin/true || {
        echo "Cannot execute $ARCH tests on this Mac. Local dual-architecture releases require Apple Silicon with Rosetta; alternatively use the Release workflow's native runners." >&2
        exit 1
    }
done
VERSION="$(python3 scripts/version.py --field version)"
python3 -m unittest discover -s Tests/ReleaseTests -v
bash scripts/test-packaging.sh
for ARCH in arm64 x86_64; do
    APP="$PWD/build/XD VPN $VERSION-$ARCH.app"
    ARCHS="$ARCH" APP_OUTPUT="$APP" bash scripts/build.sh
    /usr/bin/arch "-$ARCH" /bin/bash scripts/test.sh -c release --triple "$ARCH-apple-macosx14.0"
    python3 scripts/verify-bundled-engine.py "$APP" --arch "$ARCH"
    ARCHS="$ARCH" APP_OUTPUT="$APP" SKIP_BUILD=1 bash scripts/package.sh
    python3 scripts/verify-release-dmg.py "build/XD-VPN-$VERSION-macOS-$ARCH.dmg"
done
tar -czf build/third-party-sources.tar.gz -C .build/openconnect downloads
# Android ships in the same release: signed release APK, verified and staged as build/XD-VPN-<version>-Android.apk.
bash scripts/release-android.sh
# Download release-windows from Windows Release Build for this exact tag into build/.
python3 scripts/verify-release-windows.py "build/XD-VPN-$VERSION-Windows-x64.exe"
python3 scripts/release-notes.py > build/release-notes.md
printf '\nPrepared and verified macOS, Android and Windows installers. Push the matching tag, then publish:\n'
printf 'bash scripts/release.sh publish %s\n' "$RELEASE_TAG"
