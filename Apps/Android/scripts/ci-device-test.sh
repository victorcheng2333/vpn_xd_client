#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
API="${1:-36}"
case "$API" in 28|36) ;; *) echo 'Test API must be 28 or 36' >&2; exit 2 ;; esac
# Keep avdmanager and emulator on the same explicit directory regardless of
# runner defaults for ANDROID_USER_HOME / ANDROID_EMULATOR_HOME.
export ANDROID_AVD_HOME="$PWD/.build/ci-avd"
mkdir -p "$ANDROID_AVD_HOME"
sdkmanager "system-images;android-$API;google_apis;x86_64"
printf 'no\n' | avdmanager create avd --force --name xdvpn-ci --path "$ANDROID_AVD_HOME/xdvpn-ci.avd" --package "system-images;android-$API;google_apis;x86_64"
if [ ! -f "$ANDROID_AVD_HOME/xdvpn-ci.ini" ]; then
  echo "avdmanager did not create $ANDROID_AVD_HOME/xdvpn-ci.ini" >&2
  avdmanager list avd
  exit 1
fi
if ! "$ANDROID_HOME/emulator/emulator" -list-avds | grep -Fxq xdvpn-ci; then
  echo "emulator cannot see xdvpn-ci in $ANDROID_AVD_HOME" >&2
  exit 1
fi
"$ANDROID_HOME/emulator/emulator" -avd xdvpn-ci -port 5554 -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader_indirect > .build/emulator.log 2>&1 &
EMULATOR_PID=$!
trap 'adb -s emulator-5554 emu kill >/dev/null 2>&1 || true; kill "$EMULATOR_PID" 2>/dev/null || true' EXIT
export ANDROID_SERIAL=emulator-5554
for attempt in $(seq 1 150); do
  if ! kill -0 "$EMULATOR_PID" 2>/dev/null; then
    echo 'Emulator exited before Android finished booting:' >&2
    cat .build/emulator.log >&2
    exit 1
  fi
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then break; fi
  sleep 2
done
if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != 1 ]; then
  echo 'Emulator did not finish booting within 300 seconds:' >&2
  cat .build/emulator.log >&2
  exit 1
fi
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell input keyevent 82
./gradlew :app:connectedDebugAndroidTest
