#!/bin/bash
# Exercise release rejection paths with real Mach-O fixtures; no VPN needed.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/architectures.sh
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/xdvpn-architecture-test.XXXXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
printf 'int main(void) { return 0; }\n' > "$FIXTURE/main.c"
for ARCH in arm64 x86_64; do
    xcrun clang -arch "$ARCH" -mmacosx-version-min=14.0 "$FIXTURE/main.c" -o "$FIXTURE/$ARCH"
    xdvpn_verify_architectures "$FIXTURE/$ARCH" "$ARCH"
done
xcrun clang -arch arm64 -mmacosx-version-min=15.0 "$FIXTURE/main.c" -o "$FIXTURE/newer-os"
lipo -create "$FIXTURE/arm64" "$FIXTURE/x86_64" -output "$FIXTURE/universal"

expect_rejection() {
    local message="$1"
    shift
    if "$@" > "$FIXTURE/result" 2>&1; then
        echo "Unexpected acceptance: $*" >&2; exit 1
    fi
    if ! /usr/bin/grep -q "$message" "$FIXTURE/result"; then
        cat "$FIXTURE/result" >&2; exit 1
    fi
}
expect_rejection 'Architecture mismatch' xdvpn_verify_architectures "$FIXTURE/arm64" x86_64
expect_rejection 'Invalid architecture' xdvpn_verify_architectures "$FIXTURE/universal" arm64
expect_rejection 'Expected macOS 14.0' xdvpn_verify_architectures "$FIXTURE/newer-os" arm64
expect_rejection 'Invalid architecture' env ARCHS='arm64 x86_64' bash scripts/build.sh
expect_rejection 'Invalid architecture' env ARCHS=i386 bash scripts/package.sh
expect_rejection 'Invalid build channel' env BUILD_CHANNEL=invalid bash scripts/build.sh
expect_rejection 'Test builds require' env -u BUILD_NUMBER BUILD_CHANNEL=test bash scripts/build.sh
expect_rejection 'positive integer' env BUILD_NUMBER=invalid bash scripts/build.sh
expect_rejection 'Packaging requires' env BUILD_CHANNEL=development bash scripts/package.sh

# Packaging must reject a helper or engine from the other chip before signing
# or creating an archive. A fixture bundle is enough to reach these guards.
APP="$FIXTURE/Mixed.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/OpenConnect"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :XDVPNBuildChannel string development' "$APP/Contents/Info.plist"
expect_rejection 'Build channel mismatch' env SKIP_BUILD=1 ARCHS=arm64 APP_OUTPUT="$APP" bash scripts/package.sh
/usr/libexec/PlistBuddy -c 'Set :XDVPNBuildChannel test' "$APP/Contents/Info.plist"
expect_rejection 'Build channel mismatch' env SKIP_BUILD=1 ARCHS=arm64 APP_OUTPUT="$APP" bash scripts/package.sh
/usr/libexec/PlistBuddy -c 'Delete :XDVPNBuildChannel' "$APP/Contents/Info.plist"
cp "$FIXTURE/arm64" "$APP/Contents/MacOS/XDVPN"
cp "$FIXTURE/x86_64" "$APP/Contents/Helpers/XDVPNHelper"
expect_rejection 'Architecture mismatch' env SKIP_BUILD=1 ARCHS=arm64 APP_OUTPUT="$APP" bash scripts/package.sh
cp "$FIXTURE/arm64" "$APP/Contents/Helpers/XDVPNHelper"
cp "$FIXTURE/x86_64" "$APP/Contents/Resources/OpenConnect/openconnect"
expect_rejection 'Architecture mismatch' env SKIP_BUILD=1 ARCHS=arm64 APP_OUTPUT="$APP" bash scripts/package.sh
printf 'Passed: 2 target fixtures and 13 architecture/deployment/channel/build-number rejection checks.\n'
