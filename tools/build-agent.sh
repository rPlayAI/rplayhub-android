#!/usr/bin/env bash
#
# build-agent.sh — build the device agent from the vendored Apache-2.0 source and lay it out
# where the app expects to find it.
#
# Produces:
#     build/agent/screen-sharing-agent.jar
#     build/agent/<abi>/libscreen-sharing-agent.so       for every ABI the build emitted
#
# That is the layout AgentSession.agentDirectory() looks for. Point the app somewhere else with
# RPLAYHUB_AGENT_DIR, or the "AgentDirectory" default.
#
# We build rather than lift Studio's prebuilt jar out of an installation. Same bits either way,
# but the source is unambiguously Apache 2.0 (see refs/studio/PROVENANCE.md) and an IDE install
# is not something we want in the dependency chain.
#
# Prerequisites, none of which this script installs:
#   - a JDK 17+                 (java -version)
#   - the Android SDK           (ANDROID_HOME or ANDROID_SDK_ROOT)
#   - the Android NDK           (the agent is mostly C++; the Gradle build finds it via the SDK)
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/refs/studio/screen-sharing-agent"
out="$root/build/agent"

die() { echo "build-agent: $*" >&2; exit 1; }

[ -d "$src" ] || die "no vendored agent source at $src"
# An arm64 JVM cannot start on this machine: boot-args has amfi_get_out_of_my_way=1, and with
# AMFI off the Apple-Silicon JIT write-protect path is broken, so every arm64 JDK dies with
# SIGBUS/BUS_ADRALN in CodeHeap::allocate. An x86_64 JDK under Rosetta handles W^X itself and is
# unaffected. Prefer one if it is installed; see the README.
rosetta_jdk="$HOME/Library/Java/JavaVirtualMachines/temurin-21-x64/Contents/Home"
if [ -z "${JAVA_HOME:-}" ] && [ -x "$rosetta_jdk/bin/java" ]; then
    export JAVA_HOME="$rosetta_jdk"
fi
[ -n "${JAVA_HOME:-}" ] && export PATH="$JAVA_HOME/bin:$PATH"
command -v java >/dev/null 2>&1 || die "no java on PATH — install a JDK 17 or newer"
java -version >/dev/null 2>&1 || die "java is installed but cannot start — see README, 'Toolchain on this machine'"

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}"
[ -d "$sdk" ] || die "no Android SDK — set ANDROID_HOME (looked in $sdk)"
[ -d "$sdk/ndk" ] || die "no NDK under $sdk/ndk — install one via sdkmanager"

echo "build-agent: SDK  $sdk"
echo "build-agent: src  $src"

# The vendored tree has no local.properties (it is gitignored upstream); Gradle needs one.
[ -f "$src/local.properties" ] || echo "sdk.dir=$sdk" > "$src/local.properties"

( cd "$src" && ./gradlew --no-daemon assembleDebug )

apk="$(find "$src/app/build/outputs/apk" -name '*.apk' -print -quit)"
[ -n "$apk" ] || die "gradle produced no apk"
echo "build-agent: apk  $apk"

rm -rf "$out"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unzip -q "$apk" -d "$work"

# app_process wants a jar whose payload is dex, which is exactly what the APK holds. Repackage
# the dex files into a jar rather than shipping the APK: the manifest and resources are dead
# weight on a binary that is never installed as an app.
[ -f "$work/classes.dex" ] || die "no classes.dex in the apk"
( cd "$work" && zip -q "$out/screen-sharing-agent.jar" classes*.dex )

found=0
for abidir in "$work"/lib/*; do
    [ -d "$abidir" ] || continue
    abi="$(basename "$abidir")"
    so="$abidir/libscreen-sharing-agent.so"
    [ -f "$so" ] || continue
    mkdir -p "$out/$abi"
    cp "$so" "$out/$abi/"
    echo "build-agent: abi  $abi"
    found=$((found + 1))
done
[ "$found" -gt 0 ] || die "the apk carried no libscreen-sharing-agent.so"

echo
echo "build-agent: done — $out"
ls -la "$out"
