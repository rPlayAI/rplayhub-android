#!/usr/bin/env bash
#
# archive-appstore.sh — build a Mac App Store archive and export a signed .pkg for upload.
#
# Produces build/appstore/rPlayHub Android.pkg, signed with the VMLite team's Apple Distribution
# + 3rd Party Mac Developer Installer certs and a Mac App Store provisioning profile — both
# created automatically the first time (the Apple ID for team NL28FE3UZ7 must be signed into
# Xcode ▸ Settings ▸ Accounts). The Release build's "Bundle agent + adb" phase puts the device
# agent in Resources/agent and adb (inherit-signed) in Contents/MacOS, exactly as the store build
# needs; adb keeps its sandbox+inherit entitlement through the distribution re-sign.
#
# Prereqs: a built agent (tools/build-agent.sh) and a universal adb on PATH (platform-tools).
#
# After this, upload the .pkg with an App Store Connect API key:
#   xcrun altool --upload-app -f "build/appstore/rPlayHub Android.pkg" -t macos \
#       --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
# (the .p8 goes in ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8). The App Store Connect
# app record for ai.rplay.rplayhub.android must exist first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM="NL28FE3UZ7"
ARCHIVE="$ROOT/build/appstore/rPlayHubAndroid.xcarchive"
EXPORT="$ROOT/build/appstore/export"
AGENT_DIR="${RPLAYHUB_AGENT_DIR:-$ROOT/build/agent}"

[ -f "$AGENT_DIR/screen-sharing-agent.jar" ] || {
    echo "archive-appstore: no built agent at $AGENT_DIR — run tools/build-agent.sh" >&2; exit 1; }

COMPANION="$ROOT/helper/app/build/outputs/apk/debug/app-debug.apk"
if [ ! -f "$COMPANION" ]; then
    echo "archive-appstore: building the companion apk"
    "$ROOT/tools/build-helper.sh"
fi

echo "archive-appstore: regenerating the project"
python3 "$ROOT/tools/gen-xcodeproj.py" >/dev/null

echo "archive-appstore: archiving (Release, team $TEAM)"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project "$ROOT/app/rPlayHubAndroid.xcodeproj" -scheme rPlayHubAndroid \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates \
    RPLAYHUB_AGENT_DIR="$AGENT_DIR" \
    archive

echo "archive-appstore: exporting a signed App Store .pkg"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$ROOT/tools/ExportOptions-appstore.plist" \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates

echo "archive-appstore: done"
ls -1 "$EXPORT"/*.pkg
