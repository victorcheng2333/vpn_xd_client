#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
API="${1:-36}"
case "$API" in 28|36) ;; *) echo 'Test API must be 28 or 36' >&2; exit 2 ;; esac
sdkmanager "system-images;android-$API;google_apis;x86_64"
printf 'no\n' | avdmanager create avd --force --name xdvpn-ci --package "system-images;android-$API;google_apis;x86_64"
"$ANDROID_HOME/emulator/emulator" -avd xdvpn-ci -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader_indirect > .build/emulator.log 2>&1 &
EMULATOR_PID=$!
trap 'adb -s emulator-5554 emu kill >/dev/null 2>&1 || true; kill "$EMULATOR_PID" 2>/dev/null || true' EXIT
export ANDROID_SERIAL=emulator-5554
for attempt in $(seq 1 150); do
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then break; fi
  sleep 2
done
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell input keyevent 82
./gradlew :app:connectedDebugAndroidTest
