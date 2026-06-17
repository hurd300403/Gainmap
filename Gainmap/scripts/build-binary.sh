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
# Sign by cert SHA-1 hash, not name: there are two "Developer ID Application:
# Sam Hurd" certs in the keychain and the name alone is ambiguous to codesign.
SIGN_ID="38FED0F232826AF0D22DF117CE055D78F0823FAC"

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
