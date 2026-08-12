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
TEAM_ID="S8HQ5TEYDE"
SIGNING_IDENTITY="Developer ID Application: Sam Hurd (S8HQ5TEYDE)"

# release.sh passes the fingerprint embedded in the validated provisioning
# profile. Standalone builds use the complete certificate common name. In both
# cases, require the selected identity to be a currently valid exact match for
# Sam's canonical Developer ID team; no rotating fingerprint is persisted.
VALID_IDENTITIES="$(security find-identity -v -p codesigning)"
if [[ -n "${GAINMAP_SIGN_ID:-}" ]]; then
    SIGN_ID="$GAINMAP_SIGN_ID"
    if ! printf '%s\n' "$VALID_IDENTITIES" \
        | awk -v fingerprint="$SIGN_ID" -v label="\"$SIGNING_IDENTITY\"" \
            '$2 == fingerprint && index($0, label) { found = 1 } END { exit !found }'
    then
        echo "error: GAINMAP_SIGN_ID is not a valid '$SIGNING_IDENTITY' identity" >&2
        exit 1
    fi
else
    SIGN_ID="$(printf '%s\n' "$VALID_IDENTITIES" \
        | awk -v label="\"$SIGNING_IDENTITY\"" \
            'index($0, label) { print $2; exit }')"
    if [[ -z "$SIGN_ID" ]]; then
        echo "error: no current '$SIGNING_IDENTITY' identity in the keychain" >&2
        exit 1
    fi
fi
echo "▸ signing identity: $SIGNING_IDENTITY (Team $TEAM_ID)"

echo "▸ configuring + building uhdrtool (arm64, Release)…"
cmake -B "$BUILD" -S "$UPSTREAM" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$BUILD" --config Release --target uhdrtool

echo "▸ Developer-ID signing the binary (hardened runtime)…"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$BUILD/uhdrtool"
codesign --verify --verbose=2 "$BUILD/uhdrtool"
SIGNATURE_INFO="$(codesign -dv --verbose=4 "$BUILD/uhdrtool" 2>&1)"
printf '%s\n' "$SIGNATURE_INFO" | grep -Fq "Authority=$SIGNING_IDENTITY" || {
    echo "error: uhdrtool was not signed by '$SIGNING_IDENTITY'" >&2
    exit 1
}
printf '%s\n' "$SIGNATURE_INFO" | grep -Fq "TeamIdentifier=$TEAM_ID" || {
    echo "error: uhdrtool signature has the wrong Developer ID team" >&2
    exit 1
}

echo "▸ staging into app + plugin bundles…"
mkdir -p "$APP_HELPERS" "$PLUGIN_BIN"
cp "$BUILD/uhdrtool" "$APP_HELPERS/uhdrtool"
cp "$BUILD/uhdrtool" "$PLUGIN_BIN/uhdrtool"
chmod +x "$APP_HELPERS/uhdrtool" "$PLUGIN_BIN/uhdrtool"

echo "✓ uhdrtool $("$BUILD/uhdrtool" --version)"
echo "  app helper : $APP_HELPERS/uhdrtool"
echo "  plugin bin : $PLUGIN_BIN/uhdrtool"
