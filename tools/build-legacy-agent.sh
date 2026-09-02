#!/usr/bin/env bash
#
# build-legacy-agent.sh — the Android 5.0-7.1 agent (API 21-25).
#
# Produces build/legacy-agent/rplayhub-legacy.dex, which the app pushes to the device and runs
# through app_process. Studio's screen-sharing agent cannot go below API 26 (its capture needs
# AMediaCodec_createInputSurface, which the NDK only exposes there), so old boards get this
# instead — Java, where MediaCodec.createInputSurface() has always existed.
#
# Needs only a JDK and the Android SDK's build-tools + a platform android.jar. No gradle, no NDK:
# it is one source file.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/legacy-agent/src"
out="$root/build/legacy-agent"
die() { echo "build-legacy-agent: $*" >&2; exit 1; }

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}"
[ -d "$sdk" ] || die "no Android SDK (set ANDROID_HOME)"

# Any recent platform will do: we compile against modern APIs but target API 21 at dex time, and
# the hidden pieces (SurfaceControl, InputManager) are reached by reflection, not linked.
android_jar="$(ls -1 "$sdk"/platforms/*/android.jar 2>/dev/null | sort -V | tail -1)"
[ -n "$android_jar" ] || die "no platforms/*/android.jar under $sdk"
d8="$(ls -1 "$sdk"/build-tools/*/d8 2>/dev/null | sort -V | tail -1)"
[ -n "$d8" ] || die "no build-tools/*/d8 under $sdk"

# An x86_64 JDK under Rosetta is preferred on this machine — see tools/build-agent.sh for why.
rosetta_jdk="$HOME/Library/Java/JavaVirtualMachines/temurin-21-x64/Contents/Home"
if [ -z "${JAVA_HOME:-}" ] && [ -x "$rosetta_jdk/bin/java" ]; then export JAVA_HOME="$rosetta_jdk"; fi
[ -n "${JAVA_HOME:-}" ] && export PATH="$JAVA_HOME/bin:$PATH"
command -v javac >/dev/null 2>&1 || die "no javac on PATH — install a JDK"

echo "==> android.jar: $android_jar"
echo "==> d8:          $d8"

rm -rf "$out"; mkdir -p "$out/classes"
javac -source 8 -target 8 -nowarn \
      -bootclasspath "$android_jar" -cp "$android_jar" \
      -d "$out/classes" "$src"/*.java 2>&1 | grep -v "^Note:" || true
[ -n "$(find "$out/classes" -name '*.class' -print -quit)" ] || die "javac produced no classes"

"$d8" --min-api 21 --output "$out" $(find "$out/classes" -name '*.class')
[ -f "$out/classes.dex" ] || die "d8 produced no dex"
mv "$out/classes.dex" "$out/rplayhub-legacy.dex"
rm -rf "$out/classes"

printf '==> built %s (%s bytes)\n' "$out/rplayhub-legacy.dex" "$(wc -c < "$out/rplayhub-legacy.dex" | tr -d ' ')"
