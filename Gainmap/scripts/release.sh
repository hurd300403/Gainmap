#!/usr/bin/env bash
#
# release.sh — produce notarized, distributable artifacts for BOTH deliverables:
#   1. Gainmap.app  → Gainmap.dmg   (standalone app)
#   2. the .lrplugin → Lightroom-UltraHDR-mac.zip   (Lightroom plugin)
#
# Notarization needs a stored notarytool credential profile. Create one once:
#   xcrun notarytool store-credentials "gainmap-notary" \
#       --apple-id "samhurd@gmail.com" --team-id S8HQ5TEYDE \
#       --password <app-specific-password>     # from appleid.apple.com
#
# Then:  ./scripts/release.sh gainmap-notary
#
set -euo pipefail
PROFILE="${1:?usage: release.sh <notarytool-keychain-profile>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"          # .../sdrhdr
PROJ="$ROOT/Gainmap"
DIST="$ROOT/dist"; mkdir -p "$DIST"
SIGN_HASH=38FED0F232826AF0D22DF117CE055D78F0823FAC   # Developer ID Application (by hash)

# 0. Fresh, signed binary staged into both bundles.
"$PROJ/scripts/build-binary.sh"

# ---------------------------------------------------------------------------
# 1. Gainmap.app → archive (Developer ID, hardened runtime) → export → DMG.
# ---------------------------------------------------------------------------
echo "▸ archiving Gainmap.app…"
ARCHIVE="$DIST/Gainmap.xcarchive"
xcodebuild -project "$PROJ/Gainmap.xcodeproj" -scheme Gainmap -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    archive \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=S8HQ5TEYDE

APP="$DIST/Gainmap.app"
rm -rf "$APP"
cp -R "$ARCHIVE/Products/Applications/Gainmap.app" "$APP"

echo "▸ re-signing nested helper + app (deep, hardened runtime)…"
codesign --force --options runtime --timestamp --sign "$SIGN_HASH" \
    "$APP/Contents/Resources/Helpers/uhdrtool"
codesign --force --options runtime --timestamp \
    --entitlements "$PROJ/Sources/Support/Gainmap.entitlements" \
    --sign "$SIGN_HASH" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▸ building DMG…"
DMG="$DIST/Gainmap.dmg"; rm -f "$DMG"
STAGE="$DIST/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Gainmap" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "▸ notarizing + stapling Gainmap.dmg…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -vvv --type install "$DMG" || true

# ---------------------------------------------------------------------------
# 2. Lightroom plugin → zip → notarize (the bundled binary is what's checked).
# ---------------------------------------------------------------------------
echo "▸ packaging + notarizing the Lightroom plugin…"
PLUGIN="$ROOT/upstream/lua/lightroom-hdr.lrplugin"
ZIP="$DIST/Lightroom-UltraHDR-mac.zip"; rm -f "$ZIP"
( cd "$(dirname "$PLUGIN")" && ditto -c -k --sequesterRsrc --keepParent "lightroom-hdr.lrplugin" "$ZIP" )
# Notarize the zip so Gatekeeper accepts the bundled uhdrtool on first run.
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
# (.lrplugin can't be stapled; notarizing the binary inside clears Gatekeeper.)

echo
echo "✓ artifacts in $DIST:"
echo "  • Gainmap.dmg                  (notarized + stapled)"
echo "  • Lightroom-UltraHDR-mac.zip   (notarized)"
