#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleRelease
bash scripts/test-engine-settings.sh
python3 scripts/verify-apk.py app/build/outputs/apk/debug/app-debug.apk
RELEASE_APK=app/build/outputs/apk/release/app-release.apk
[ -f "$RELEASE_APK" ] || RELEASE_APK=app/build/outputs/apk/release/app-release-unsigned.apk
python3 scripts/verify-apk.py "$RELEASE_APK"
