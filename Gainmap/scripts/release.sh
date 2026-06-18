#!/usr/bin/env bash
#
# release.sh — produce the notarized, distributable Gainmap.app → Gainmap.dmg.
#
# NOTE: the Lightroom .lrplugin is intentionally NOT packaged/published right now
# (revisit another day). The plugin section below is commented out; re-enable it
# and add "$ZIP" back to the appcast input + gh release publish to ship it again.
#
# Notarization needs a stored notarytool credential profile. The reusable one is
# "legacylab-notary" (Apple ID samhurd+apple2@gmail.com, team S8HQ5TEYDE). If it's
# missing, create it once:
#   xcrun notarytool store-credentials "legacylab-notary" \
#       --apple-id "samhurd+apple2@gmail.com" --team-id S8HQ5TEYDE \
#       --password <app-specific-password>     # from appleid.apple.com
#
# Then:  ./scripts/release.sh legacylab-notary
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

echo "▸ re-signing nested helpers + app (inside-out, hardened runtime, secure timestamp)…"
# Sparkle ships nested executables (Updater.app, Autoupdate, XPC services) that
# Xcode's archive signing does NOT re-sign with Developer ID — notarization hard-
# rejects them otherwise. Sign them inside-out BEFORE the outer app. (No custom
# entitlements: the app is non-sandboxed, so Sparkle uses its direct install path.)
SPK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPK" ]; then
  SPKV="$SPK/Versions/Current"
  for c in "XPCServices/Downloader.xpc" "XPCServices/Installer.xpc" \
           "Updater.app" "Autoupdate"; do
    [ -e "$SPKV/$c" ] && codesign --force --options runtime --timestamp \
        --sign "$SIGN_HASH" "$SPKV/$c"
  done
  codesign --force --options runtime --timestamp --sign "$SIGN_HASH" "$SPK"
fi
# Sentry ships as a dynamic xcframework (embedded Sentry.framework); re-sign it with
# Developer ID + hardened runtime so notarization accepts it.
SENTRY_FW="$APP/Contents/Frameworks/Sentry.framework"
[ -d "$SENTRY_FW" ] && codesign --force --options runtime --timestamp --sign "$SIGN_HASH" "$SENTRY_FW"
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
# Sentry: upload dSYMs (so crash stacks symbolicate) + create/finalize the
# release. org/project/token come from ~/.sentryclirc. The release id MUST match
# what the SDK reports at runtime: bundleId@CFBundleShortVersionString+CFBundleVersion.
# Non-fatal — never block a release on telemetry plumbing.
# ---------------------------------------------------------------------------
if command -v sentry-cli >/dev/null 2>&1; then
  echo "▸ uploading dSYMs to Sentry…"
  SHORT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
  REL="com.legacylab.gainmap@${SHORT}+${BUILD}"
  sentry-cli debug-files upload --include-sources "$ARCHIVE/dSYMs" || echo "  (dSYM upload failed — continuing)"
  sentry-cli releases new "$REL" || true
  ( cd "$ROOT" && sentry-cli releases set-commits "$REL" --auto ) || true
  sentry-cli releases finalize "$REL" || true
else
  echo "▸ sentry-cli not found — skipping dSYM upload"
fi

# ---------------------------------------------------------------------------
# 2. Lightroom plugin — DISABLED for now (revisit another day). To re-enable,
#    uncomment, and add "$ZIP" back to the appcast input + gh release publish.
# ---------------------------------------------------------------------------
# echo "▸ packaging + notarizing the Lightroom plugin…"
# PLUGIN="$ROOT/upstream/lua/lightroom-hdr.lrplugin"
# ZIP="$DIST/Lightroom-UltraHDR-mac.zip"; rm -f "$ZIP"
# ( cd "$(dirname "$PLUGIN")" && ditto -c -k --sequesterRsrc --keepParent "lightroom-hdr.lrplugin" "$ZIP" )
# xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
# # (.lrplugin can't be stapled; notarizing the binary inside clears Gatekeeper.)

# ---------------------------------------------------------------------------
# 3. Sparkle appcast — EdDSA-sign the DMG (keychain key) + write appcast.xml,
#    then publish the GitHub Release the app's SUFeedURL points at.
# ---------------------------------------------------------------------------
echo "▸ generating Sparkle appcast…"
GEN_APPCAST="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
TAG="v$VER"
# Enclosure URLs resolve to the *latest* release's assets (stable feed).
"$GEN_APPCAST" --download-url-prefix "https://github.com/hurd300403/Gainmap/releases/latest/download/" "$DIST"

echo "▸ publishing GitHub Release ${TAG} ..."
gh release create "$TAG" "$DMG" "$DIST/appcast.xml" \
    --repo hurd300403/Gainmap --title "Gainmap $VER" --notes "Gainmap $VER" \
  || gh release upload "$TAG" "$DMG" "$DIST/appcast.xml" --repo hurd300403/Gainmap --clobber

echo
echo "✓ artifacts in $DIST:"
echo "  • Gainmap.dmg                  (notarized + stapled)"
echo "  • appcast.xml                  (EdDSA-signed; published to GitHub Release $TAG)"
