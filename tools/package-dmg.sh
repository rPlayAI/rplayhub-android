#!/usr/bin/env bash
#
# Build rPlayHubAndroid.app (Release) and wrap it in a DMG.
#
#   ./tools/package-dmg.sh                                   # ad-hoc signed, LOCAL TESTING ONLY
#   SIGN_ID="Developer ID Application: VMLite Corporation (NL28FE3UZ7)" \
#   NOTARY_PROFILE=AC_PASSWORD ./tools/package-dmg.sh        # shippable: sign + notarize + staple
#
# Shippable = one ad-hoc Release build (the "Bundle agent + adb" phase bakes in the agent, adb and
# the companion APK), then re-signed inside out with raw codesign and the Developer ID identity.
# NOT xcodebuild's own Developer ID signing: the app carries an App Group for the store, a
# RESTRICTED entitlement that xcodebuild will only sign against a Developer ID provisioning
# profile — which it cannot create automatically. The DMG does not need the group (it exists only
# for App Store validation; the Finder mount runs without it), so it is stripped here and raw
# codesign signs the rest, which needs no profile. tools/archive-appstore.sh keeps the group.
#
# NOTARY_PROFILE is a notarytool keychain profile (AC_PASSWORD is the team's, shared with ~/rplay):
#   xcrun notarytool store-credentials AC_PASSWORD \
#       --apple-id "you@example.com" --team-id NL28FE3UZ7 --password "app-specific-password"
# Without SIGN_ID + NOTARY_PROFILE the DMG is ad-hoc signed and Gatekeeper blocks a DOWNLOADED copy.
#
# The DMG is NOT sandboxed (DMG_SANDBOX=0, the default): "+ Emulator" execs the user's own SDK
# emulator, which a sandboxed process cannot do, and that launcher is what sets the DMG apart
# from the store build. DMG_SANDBOX=1 builds the old sandboxed shape (helpers signed to inherit).
# The Finder extension stays sandboxed either way — an appex must be.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/app/rPlayHubAndroid.xcodeproj"
BUILD="$ROOT/build"
DD="$BUILD/DerivedData"
STAGE="$BUILD/dmg-stage"
APP_NAME="rPlayHubAndroid"
VOLNAME="rPlayHub Android"
TEAM="NL28FE3UZ7"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$ROOT/app/rPlayHubAndroid/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"

SIGN_ID="${SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DMG_SANDBOX="${DMG_SANDBOX:-0}"
AGENT_DIR="${RPLAYHUB_AGENT_DIR:-$ROOT/build/agent}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- runtime pieces
# The build phase bundles these; warn now if they are missing rather than after a long build.
[[ -f "$AGENT_DIR/screen-sharing-agent.jar" ]] || \
    say "WARNING: no built agent at $AGENT_DIR (tools/build-agent.sh) — mirroring will not work"
[[ -f "$ROOT/helper/app/build/outputs/apk/debug/app-debug.apk" ]] || \
    say "note: no companion apk (tools/build-helper.sh) — Install Companion App will be unavailable"

say "building $APP_NAME $VERSION (Release)"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
python3 "$ROOT/tools/gen-xcodeproj.py" >/dev/null

# One Release build, ad-hoc signed by Xcode (no provisioning profile is demanded that way).
# The "Bundle agent + adb" phase bakes in the agent, adb and the companion APK. Start from a
# fresh bundle: xcodebuild never removes files it did not put there, and a stale copy from an
# older layout (an unsigned Resources/adb/adb) once failed notarization.
rm -rf "$DD/Build/Products/Release/$APP_NAME.app"
xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$DD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" RPLAYHUB_AGENT_DIR="$AGENT_DIR" build
APP="$DD/Build/Products/Release/$APP_NAME.app"
APPEX="$APP/Contents/PlugIns/FinderMount.appex"
# The legacy adb location; never ship an unsigned copy from it.
rm -rf "$APP/Contents/Resources/adb"

# The entitlements the DMG's app and helpers are re-signed with (both the Developer ID and the
# ad-hoc path): the store's minus the App Group, and minus the sandbox unless DMG_SANDBOX=1.
ENT_DIR="$BUILD/dmg-entitlements"; rm -rf "$ENT_DIR"; mkdir -p "$ENT_DIR"
cp "$ROOT/app/rPlayHubAndroid/rPlayHubAndroid.entitlements" "$ENT_DIR/app.entitlements"
cp "$ROOT/app/FinderMount/FinderMount.entitlements" "$ENT_DIR/appex.entitlements"
if [[ "$DMG_SANDBOX" == "1" ]]; then
    HELPER_ENT=("--entitlements" "$ROOT/app/rPlayHubAndroid/adb-inherit.entitlements")
else
    say "unsandboxed DMG (DMG_SANDBOX=0): the app may launch the SDK emulator"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" "$ENT_DIR/app.entitlements"
    # No sandbox to inherit: a helper carrying app-sandbox+inherit under an unsandboxed parent
    # would be refused at exec, so adb and the bridge are signed with no entitlements at all.
    HELPER_ENT=()
fi

if [[ -n "$SIGN_ID" ]]; then
    # Re-sign for Developer ID with raw codesign, inside out — the recipe that shipped 0.2.0.
    #
    # The App Group (com.apple.security.application-groups) is stripped first, from the app's and
    # the extension's entitlements AND from the extension's NSExtensionFileProviderDocumentGroup:
    # it exists only to satisfy App Store validation, the Finder mount runs without it, and it is
    # a RESTRICTED entitlement — signing it needs a Developer ID provisioning profile, which Xcode
    # cannot create automatically (only App Store profiles are). Without it every entitlement
    # left is unrestricted and Developer ID needs no profile at all.
    say "re-signing with $SIGN_ID (app group stripped for the Developer ID build)"
    for f in "$ENT_DIR/app.entitlements" "$ENT_DIR/appex.entitlements"; do
        /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "$f" 2>/dev/null || true
    done
    /usr/libexec/PlistBuddy -c "Delete :NSExtension:NSExtensionFileProviderDocumentGroup" \
        "$APPEX/Contents/Info.plist" 2>/dev/null || true

    for helper in adb emulator-bridge; do
        [[ -f "$APP/Contents/MacOS/$helper" ]] && \
            codesign --force --sign "$SIGN_ID" --timestamp --options=runtime \
                "${HELPER_ENT[@]}" "$APP/Contents/MacOS/$helper"
    done
    codesign --force --sign "$SIGN_ID" --timestamp --options=runtime \
        --entitlements "$ENT_DIR/appex.entitlements" "$APPEX"
    codesign --force --sign "$SIGN_ID" --timestamp --options=runtime \
        --entitlements "$ENT_DIR/app.entitlements" "$APP"
else
    say "no SIGN_ID set — ad-hoc signed (LOCAL TESTING ONLY)"
    if [[ "$DMG_SANDBOX" != "1" ]]; then
        # Xcode signed the Release build with the store entitlements; drop the sandbox here too
        # so a local DMG behaves like the shipped one.
        for helper in adb emulator-bridge; do
            [[ -f "$APP/Contents/MacOS/$helper" ]] && \
                codesign --force --sign - --options=runtime "$APP/Contents/MacOS/$helper"
        done
        codesign --force --sign - --options=runtime --entitlements "$ENT_DIR/app.entitlements" "$APP"
    fi
fi
[[ -d "$APP" ]] || { echo "build did not produce $APP" >&2; exit 1; }

# ---------------------------------------------------------------- verify
say "verifying signature and bundled pieces"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
for f in "Contents/MacOS/adb" "Contents/MacOS/emulator-bridge" \
         "Contents/Resources/agent/screen-sharing-agent.jar" "Contents/Resources/companion.apk"; do
    [[ -e "$APP/$f" ]] && echo "    bundled: $f" || say "WARNING: missing $f"
done
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q app-sandbox; then
    echo "    app is sandboxed"
    if codesign -d --entitlements :- "$APP/Contents/MacOS/adb" 2>/dev/null | grep -q inherit; then
        echo "    adb keeps its sandbox+inherit entitlement"
    else
        say "WARNING: bundled adb lost its inherit entitlement — it will not run inside the sandbox"
    fi
else
    echo "    app is not sandboxed (+ Emulator available behind RPLAYHUB_EMU)"
    if codesign -d --entitlements :- "$APP/Contents/MacOS/adb" 2>/dev/null | grep -q inherit; then
        say "WARNING: bundled adb carries sandbox+inherit under an unsandboxed app — it will not exec"
    fi
fi
if [[ -n "$SIGN_ID" ]]; then
    if spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/    /'; then
        say "Gatekeeper assessment passed"
    else
        say "Gatekeeper assessment pending — notarization is what clears it"
    fi
fi

# ---------------------------------------------------------------- stage + dmg
say "staging"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

say "creating $DMG"
hdiutil create -volname "$VOLNAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ \
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
