#!/bin/bash
# Build, verify and stage the Android release APK next to the macOS DMGs in build/.
# Requires RELEASE_TAG=v<version> matching Resources/Info.plist, like the macOS release steps.
set -euo pipefail
cd "$(dirname "$0")/.."
export BUILD_CHANNEL=release
unset BUILD_NUMBER # release builds take the build number from Resources/Info.plist only
VERSION="$(python3 scripts/version.py --field version)"
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[ -d "$ANDROID_HOME" ] || { echo 'Android SDK not found; set ANDROID_HOME.' >&2; exit 1; }
if [ -z "${JAVA_HOME:-}" ]; then
    for candidate in /Library/Java/JavaVirtualMachines/jdk-17*/Contents/Home /Library/Java/JavaVirtualMachines/jdk-21*/Contents/Home /usr/lib/jvm/temurin-17-jdk-* /usr/lib/jvm/temurin-21-jdk-*; do
        if [ -x "$candidate/bin/java" ]; then export JAVA_HOME="$candidate"; break; fi
    done
fi
[ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] || { echo 'JDK 17 or 21 required; set JAVA_HOME.' >&2; exit 1; }
# Unit tests, release lint (lintVital also runs inside assembleRelease) and the R8 release APK.
(cd Apps/Android && ./gradlew --console=plain :app:testDebugUnitTest :app:lintRelease :app:assembleRelease)
APK=Apps/Android/app/build/outputs/apk/release/app-release.apk
[ -s "$APK" ] || { echo 'Release APK is unsigned. Configure Apps/Android/signing.properties, ANDROID_KEYSTORE_* variables, or keep a local debug keystore.' >&2; exit 1; }
python3 Apps/Android/scripts/verify-apk.py "$APK"
mkdir -p build
OUTPUT="build/XD-VPN-$VERSION-Android.apk"
cp "$APK" "$OUTPUT"
python3 scripts/verify-release-apk.py "$OUTPUT"
(cd build && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
echo "Prepared $OUTPUT"
