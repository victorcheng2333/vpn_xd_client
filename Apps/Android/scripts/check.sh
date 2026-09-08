#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleRelease
python3 scripts/verify-apk.py app/build/outputs/apk/debug/app-debug.apk
python3 scripts/verify-apk.py app/build/outputs/apk/release/app-release-unsigned.apk
