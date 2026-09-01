#!/usr/bin/env bash
#
# build-helper.sh — build the companion "rPlayHub Share" APK (helper/).
#
# The companion is a Share-sheet target: from any Android app you tap Share ▸ Send to Mac and it
# drops the shared items in its outbox (/sdcard/Android/data/<pkg>/files/outbox), which the Mac
# app pulls over adb (ShareInbox) and offers as a draggable thumbnail on the fusion window. Pure
# Java, no NDK — much simpler than the device agent.
#
# Produces helper/app/build/outputs/apk/debug/app-debug.apk. Install with:
#     adb install -r helper/app/build/outputs/apk/debug/app-debug.apk
#
# Prerequisites: a JDK 17+ and the Android SDK (ANDROID_HOME). Same toolchain note as
# build-agent.sh — prefer the Rosetta JDK on this machine.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$root/helper"

rosetta_jdk="$HOME/Library/Java/JavaVirtualMachines/temurin-21-x64/Contents/Home"
if [ -z "${JAVA_HOME:-}" ] && [ -x "$rosetta_jdk/bin/java" ]; then
    export JAVA_HOME="$rosetta_jdk"
fi
[ -n "${JAVA_HOME:-}" ] && export PATH="$JAVA_HOME/bin:$PATH"
command -v java >/dev/null 2>&1 || { echo "build-helper: no java on PATH" >&2; exit 1; }

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}"
[ -d "$sdk" ] || { echo "build-helper: no Android SDK — set ANDROID_HOME (looked in $sdk)" >&2; exit 1; }
[ -f "$helper/local.properties" ] || echo "sdk.dir=$sdk" > "$helper/local.properties"

( cd "$helper" && ./gradlew --no-daemon assembleDebug )
apk="$helper/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$apk" ] || { echo "build-helper: gradle produced no apk" >&2; exit 1; }
echo "build-helper: apk  $apk"
