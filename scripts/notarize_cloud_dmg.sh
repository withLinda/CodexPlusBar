#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CLOUD_PROFILE:?Set CLOUD_PROFILE to the local Developer ID provisionprofile}"
: "${CLOUD_SIGN_IDENTITY:?Set CLOUD_SIGN_IDENTITY to the Developer ID Application identity}"
[[ -f "$CLOUD_PROFILE" ]] || { echo "Provisioning profile not found" >&2; exit 1; }
[[ $# -eq 0 || ( $# -eq 1 && "$1" == "--archive-only" ) || ( $# -eq 2 && "$1" == "--package-archive" ) ]] || { echo "Usage: $0 [--archive-only | --package-archive path.xcarchive]" >&2; exit 1; }
NOTARY_PROFILE="${NOTARY_PROFILE:-CodexPlusBar-notary}"
mkdir -p build/cloud-releases
RUN="$(mktemp -d "$PWD/build/cloud-releases/release-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
ARCHIVE="$RUN/CodexPlusBar.xcarchive"
APP="$ARCHIVE/Products/Applications/CodexPlusBar.app"
echo "Release workspace: $RUN"

if [[ "${1:-}" == "--package-archive" ]]; then
    APP="$RUN/CodexPlusBar.app"
    [[ -d "$2/Products/Applications/CodexPlusBar.app" ]] || { echo "Archived app not found" >&2; exit 1; }
    ditto "$2/Products/Applications/CodexPlusBar.app" "$APP"
else
    xcodegen generate
    xcodebuild archive -project CodexPlusBar.xcodeproj -scheme CodexPlusBar-CloudProduction \
    -configuration CloudProduction -destination 'generic/platform=macOS' \
    -derivedDataPath "$RUN/DerivedData" -archivePath "$ARCHIVE" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO SKIP_INSTALL=NO \
    SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    > "$RUN/archive.log" 2>&1
fi

# Explicit local profile embedding precedes the only distribution signing step.
# Debug/tests/previews continue to build without any CloudKit entitlements.
cp "$CLOUD_PROFILE" "$APP/Contents/embedded.provisionprofile"
codesign --force --sign "$CLOUD_SIGN_IDENTITY" --options runtime --timestamp \
    --entitlements Config/CloudSync-Production.entitlements "$APP"
preflight() {
    python3 scripts/cloud_signing_preflight.py --app "$1" --environment Production \
        --team 2Z8N5KTWQZ --container iCloud.com.linda.CodexPlusBar
}
xcrun lipo "$APP/Contents/MacOS/CodexPlusBar" -archs > "$RUN/architectures.txt"
python3 - "$RUN/architectures.txt" <<'PY'
import pathlib, sys
if set(pathlib.Path(sys.argv[1]).read_text().split()) != {'arm64', 'x86_64'}:
    sys.exit('Archive must contain exactly arm64 and x86_64')
PY
preflight "$APP" | tee "$RUN/preflight.txt"
if [[ "${1:-}" == "--archive-only" ]]; then
    echo "Signed archive: $ARCHIVE"
    exit 0
fi

# Notarize/staple the app first, so the app copied off the DMG has its own ticket.
ditto -c -k --keepParent "$APP" "$RUN/CodexPlusBar.zip"
xcrun notarytool submit "$RUN/CodexPlusBar.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$RUN/app-notary.json"
python3 - "$RUN/app-notary.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get('status') != 'Accepted':
    sys.exit('App notarization was not accepted; inspect app-notary.json')
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
preflight "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$RUN/CodexPlusBar-$VERSION-cloud.dmg"
bash scripts/create_dmg.sh --app "$APP" --output "$DMG" --volume-name CodexPlusBar
codesign --sign "$CLOUD_SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$RUN/dmg-notary.json"
python3 - "$RUN/dmg-notary.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get('status') != 'Accepted':
    sys.exit('DMG notarization was not accepted; inspect dmg-notary.json')
PY
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

# Inspect the actual packaged app on a private mountpoint, then detach it.
mkdir "$RUN/mount"
trap 'hdiutil detach "$RUN/mount" >/dev/null 2>&1 || true' EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$RUN/mount" > "$RUN/mount.log"
preflight "$RUN/mount/CodexPlusBar.app" | tee "$RUN/packaged-preflight.txt"
xcrun stapler validate "$RUN/mount/CodexPlusBar.app"
hdiutil detach "$RUN/mount"
trap - EXIT
(
    cd "$RUN"
    shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256"
    shasum -a 256 -c "$(basename "$DMG").sha256"
)
echo "Notarized DMG: $DMG"
