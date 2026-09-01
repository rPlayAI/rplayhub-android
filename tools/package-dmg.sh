#!/usr/bin/env bash
#
# Build rPlayHubAndroid.app (Release) and wrap it in a DMG.
#
#   ./tools/package-dmg.sh                       # ad-hoc signed, LOCAL TESTING ONLY
#   SIGN_ID="Developer ID Application: Huihong Luo (TEAMID)" ./tools/package-dmg.sh
#   SIGN_ID="…" NOTARY_PROFILE=rplayhub-android ./tools/package-dmg.sh   # sign + notarize + staple
#
# Adapted from ~/rplay-hub/scripts/package-dmg.sh. This variant is for a PERSONAL Apple account,
# not VMLite: pass a personal "Developer ID Application" identity as SIGN_ID and a matching
# notarytool keychain profile as NOTARY_PROFILE. Create the profile once with:
#
#   xcrun notarytool store-credentials rplayhub-android \
#       --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
# A "Developer ID Application" cert needs a paid Apple Developer Program membership; an
# "Apple Development" cert cannot notarize a downloadable app. Without SIGN_ID + NOTARY_PROFILE the
# DMG is ad-hoc signed and Gatekeeper will block anyone who DOWNLOADS it — fine on this Mac only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/app/rPlayHubAndroid.xcodeproj"
BUILD="$ROOT/build"
DD="$BUILD/DerivedData"
STAGE="$BUILD/dmg-stage"
APP_NAME="rPlayHubAndroid"
VOLNAME="rPlayHub Android"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$ROOT/app/rPlayHubAndroid/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"

SIGN_ID="${SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- agent artifacts
# The app locates the screen-sharing agent at runtime (RPLAYHUB_AGENT_DIR or a built path). A
# downloaded copy on another Mac will have neither unless the agent is bundled or the user builds
# it. Warn if it is missing here, but still package — this is enough to test the app itself.
if [[ ! -f "$ROOT/refs/studio/out/screen-sharing-agent.jar" && -z "${RPLAYHUB_AGENT_DIR:-}" ]]; then
    say "note: no built agent found (tools/build-agent.sh) — the app packages, but mirroring needs the agent present at runtime"
fi

# ---------------------------------------------------------------- build
say "building $APP_NAME $VERSION (Release)"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

if [[ -n "$SIGN_ID" ]]; then
    # Hardened runtime (required for notarization) is already on in the project.
    xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
        -derivedDataPath "$DD" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGN_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
        build
else
    say "no SIGN_ID set — building ad-hoc signed (LOCAL TESTING ONLY)"
    xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
        -derivedDataPath "$DD" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="-" \
        DEVELOPMENT_TEAM="" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        build
fi

APP="$DD/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "build did not produce $APP" >&2; exit 1; }

# ---------------------------------------------------------------- bundle the runtime pieces
# The app is useless without the device agent and an adb binary; bake both into Resources so the
# DMG runs on a Mac with no Android tooling. agentDirectory() checks Resources/agent first, and
# Adb.binaryPath() checks Resources/adb/adb first.
say "bundling the agent and adb into the app"
AGENT_SRC="${RPLAYHUB_AGENT_DIR:-$ROOT/build/agent}"
if [[ -f "$AGENT_SRC/screen-sharing-agent.jar" ]]; then
    mkdir -p "$APP/Contents/Resources/agent"
    cp -R "$AGENT_SRC/." "$APP/Contents/Resources/agent/"
else
    say "WARNING: no built agent at $AGENT_SRC — mirroring will need one on the target machine"
fi
ADB_BIN=""
for c in "${ANDROID_HOME:-}/platform-tools/adb" \
         /opt/homebrew/share/android-commandlinetools/platform-tools/adb \
         /opt/homebrew/bin/adb /usr/local/bin/adb; do
    [[ -x "$c" ]] && { ADB_BIN="$c"; break; }
done
if [[ -n "$ADB_BIN" ]]; then
    cp "$ADB_BIN" "$APP/Contents/MacOS/adb"
fi
COMPANION="$ROOT/helper/app/build/outputs/apk/debug/app-debug.apk"
if [[ -f "$COMPANION" ]]; then
    cp "$COMPANION" "$APP/Contents/Resources/companion.apk"
else
    say "note: no companion apk (tools/build-helper.sh) — Install Companion App will be unavailable"
else
    say "WARNING: no adb binary found to bundle — the target machine will need platform-tools"
fi
# Adding files broke the code seal; sign the nested binaries, then the bundle again — inside
# out. The File Provider extension keeps its own entitlements (sandbox + network client): a
# re-sign without them leaves an extension fileproviderd refuses to launch.
APPEX="$APP/Contents/PlugIns/FinderMount.appex"
if [[ -n "$SIGN_ID" ]]; then
    [[ -f "$APP/Contents/MacOS/adb" ]] && \
        codesign --force --sign "$SIGN_ID" --timestamp --options=runtime \
            --entitlements "$ROOT/app/rPlayHubAndroid/adb-inherit.entitlements" \
            "$APP/Contents/MacOS/adb"
    [[ -d "$APPEX" ]] && \
        codesign --force --sign "$SIGN_ID" --timestamp --options=runtime \
            --preserve-metadata=entitlements "$APPEX"
    codesign --force --sign "$SIGN_ID" --timestamp --options=runtime "$APP"
else
    [[ -f "$APP/Contents/MacOS/adb" ]] && codesign --force --sign - \
        --entitlements "$ROOT/app/rPlayHubAndroid/adb-inherit.entitlements" "$APP/Contents/MacOS/adb"
    [[ -d "$APPEX" ]] && codesign --force --sign - --preserve-metadata=entitlements "$APPEX"
    codesign --force --sign - "$APP"
fi

# ---------------------------------------------------------------- verify signature
say "verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
if [[ -n "$SIGN_ID" ]]; then
    if spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/    /'; then
        say "Gatekeeper assessment passed"
    else
        say "Gatekeeper assessment failed — notarization is still needed"
    fi
fi

# ---------------------------------------------------------------- stage + dmg
say "staging"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

say "creating $DMG"
hdiutil create -volname "$VOLNAME $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -fs HFS+ \
    "$DMG" >/dev/null

# ---------------------------------------------------------------- notarize
if [[ -n "$NOTARY_PROFILE" ]]; then
    if [[ -z "$SIGN_ID" ]]; then
        echo "refusing to notarize an ad-hoc signed build — set SIGN_ID too" >&2
        exit 1
    fi
    say "signing the DMG"
    codesign --sign "$SIGN_ID" --timestamp "$DMG"

    say "submitting for notarization (this waits for Apple)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

    say "stapling the ticket"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
else
    say "NOTARY_PROFILE not set — skipping notarization"
    say "a user who downloads this DMG will be blocked by Gatekeeper"
fi

rm -rf "$STAGE"
say "done: $DMG"
ls -lh "$DMG"
