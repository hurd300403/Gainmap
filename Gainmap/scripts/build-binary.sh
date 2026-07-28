#!/usr/bin/env bash
#
# build-binary.sh — build the native uhdrtool (arm64), Developer-ID-sign it, and
# stage it into BOTH deliverables: the Gainmap app's Resources/Helpers and the
# Lightroom plugin bundle's bin/mac. Run this before `xcodegen generate` /
# archiving so the bundled helper is fresh and signed.
#
# Prereqs (one-time):  brew install nasm
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"            # .../sdrhdr
UPSTREAM="$ROOT/upstream"
BUILD="$ROOT/build"
APP_HELPERS="$ROOT/Gainmap/Resources/Helpers"
PLUGIN_BIN="$UPSTREAM/lua/lightroom-hdr.lrplugin/bin/mac"
# Signing identity, resolved dynamically (P1): override with GAINMAP_SIGN_ID,
# else pick the "Developer ID Application: Sam Hurd" cert from the keychain by
# SHA-1 hash (codesign needs the hash — the NAME alone is ambiguous when two
# certs exist). With multiple matches the last one listed wins, and the choice
# is printed so a wrong pick is visible. Any valid Developer ID signature on
# the helper notarizes fine; only the APP archive pins a specific cert (that
# pin lives in exportOptions.plist, matched to the provisioning profile).
resolve_sign_id() {
    security find-identity -v -p codesigning \
        | awk '/Developer ID Application: Sam Hurd/ {print $2}' | tail -1
}
SIGN_ID="${GAINMAP_SIGN_ID:-$(resolve_sign_id)}"
if [[ -z "$SIGN_ID" ]]; then
    echo "error: no 'Developer ID Application: Sam Hurd' identity in the keychain" >&2
    echo "       (set GAINMAP_SIGN_ID=<cert SHA-1> to override)" >&2
    exit 1
fi
echo "▸ signing identity: $SIGN_ID"

echo "▸ configuring + building uhdrtool (arm64, Release)…"
cmake -B "$BUILD" -S "$UPSTREAM" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$BUILD" --config Release --target uhdrtool

echo "▸ Developer-ID signing the binary (hardened runtime)…"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$BUILD/uhdrtool"
codesign --verify --verbose=2 "$BUILD/uhdrtool"

echo "▸ staging into app + plugin bundles…"
mkdir -p "$APP_HELPERS" "$PLUGIN_BIN"
cp "$BUILD/uhdrtool" "$APP_HELPERS/uhdrtool"
cp "$BUILD/uhdrtool" "$PLUGIN_BIN/uhdrtool"
chmod +x "$APP_HELPERS/uhdrtool" "$PLUGIN_BIN/uhdrtool"

echo "✓ uhdrtool $("$BUILD/uhdrtool" --version)"
echo "  app helper : $APP_HELPERS/uhdrtool"
echo "  plugin bin : $PLUGIN_BIN/uhdrtool"
