#!/usr/bin/env bash
#
# release.sh — build, validate, notarize, and publish Gainmap for macOS.
#
# The canonical credentials and signing assets are:
#   notarytool profile:       legacylab-notary
#   Developer ID profile:    Gainmap Developer ID
#   Developer ID certificate: Developer ID Application: Sam Hurd (S8HQ5TEYDE)
#
# Run `./scripts/release.sh --preflight-only` before a release. The full command
# writes into dist/releases/v<marketing>-b<build>/ and refuses to overwrite an
# existing directory or GitHub tag. The Lightroom plugin remains intentionally
# excluded from publication.

set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    echo "usage: release.sh [--preflight-only] [notarytool-keychain-profile]" >&2
}

PREFLIGHT_ONLY=0
if [[ "${1:-}" == "--preflight-only" ]]; then
    PREFLIGHT_ONLY=1
    shift
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
elif [[ "${1:-}" == -* ]]; then
    usage
    exit 2
fi
[[ $# -le 1 ]] || { usage; exit 2; }

NOTARY_PROFILE="${1:-legacylab-notary}"
TEAM_ID="S8HQ5TEYDE"
BUNDLE_ID="com.legacylab.gainmap"
SIGNING_IDENTITY="Developer ID Application: Sam Hurd (S8HQ5TEYDE)"
PROVISIONING_PROFILE_NAME="Gainmap Developer ID"
SPARKLE_VERSION="2.9.3"
SPARKLE_ACCOUNT="ed25519"
GITHUB_REPOSITORY="hurd300403/Gainmap"
DOWNLOAD_URL_PREFIX="https://github.com/$GITHUB_REPOSITORY/releases/latest/download/"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJ="$ROOT/Gainmap"
PROJECT_YML="$PROJ/project.yml"
ENTITLEMENTS="$PROJ/Mac/Support/Gainmap.entitlements"
DIST_ROOT="$ROOT/dist/releases"

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

project_setting() {
    local key="$1"
    awk -F: -v key="$key" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            value = $2
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/\"/, "", value)
            print value
            exit
        }
    ' "$PROJECT_YML"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

expect_equal() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$label mismatch (expected '$expected', got '${actual:-<missing>}')"
}

for command_name in awk cmake codesign date ditto find gh hdiutil mktemp \
    openssl plutil security shasum spctl stat xcodebuild xcrun xmllint; do
    require_command "$command_name"
done

MARKETING_VERSION="$(project_setting MARKETING_VERSION)"
BUILD_NUMBER="$(project_setting CURRENT_PROJECT_VERSION)"
[[ -n "$MARKETING_VERSION" ]] || fail "MARKETING_VERSION is missing from project.yml"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION must be numeric"
TAG="v$MARKETING_VERSION-b$BUILD_NUMBER"
RELEASE_DIR="$DIST_ROOT/$TAG"

expect_equal "$(plist_value "$ENTITLEMENTS" 'keychain-access-groups:0')" \
    '$(AppIdentifierPrefix)com.legacylab.gainmap' \
    "Release keychain access group"
grep -Fq 'PROVISIONING_PROFILE_SPECIFIER: "Gainmap Developer ID"' "$PROJECT_YML" \
    || fail "Release must select the '$PROVISIONING_PROFILE_NAME' profile"
grep -Fq 'CODE_SIGN_IDENTITY: "Developer ID Application: Sam Hurd (S8HQ5TEYDE)"' "$PROJECT_YML" \
    || fail "Release must use the canonical Developer ID certificate name"
grep -Fq 'CODE_SIGN_STYLE: Manual' "$PROJECT_YML" \
    || fail "Release signing must be manual"

PREFLIGHT_DIR="$(mktemp -d /tmp/gainmap-release-preflight.XXXXXX)"
FEED_WORK=""
MOUNT_POINT=""
cleanup() {
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    if [[ -n "$FEED_WORK" && -d "$FEED_WORK" ]]; then
        rm -rf "$FEED_WORK"
    fi
    if [[ -d "$PREFLIGHT_DIR" ]]; then
        rm -rf "$PREFLIGHT_DIR"
    fi
}
trap cleanup EXIT

echo "▸ validating Developer ID provisioning profile…"
PROFILE_ROOTS=()
for profile_root in \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$HOME/Library/MobileDevice/Provisioning Profiles"
do
    [[ -d "$profile_root" ]] && PROFILE_ROOTS+=("$profile_root")
done
[[ ${#PROFILE_ROOTS[@]} -gt 0 ]] || fail "no provisioning-profile directory exists"

PROFILE_PATH=""
while IFS= read -r -d '' candidate; do
    candidate_name="$(security cms -D -i "$candidate" 2>/dev/null \
        | plutil -extract Name raw -o - - 2>/dev/null || true)"
    if [[ "$candidate_name" == "$PROVISIONING_PROFILE_NAME" ]]; then
        [[ -z "$PROFILE_PATH" ]] \
            || fail "multiple profiles named '$PROVISIONING_PROFILE_NAME' are installed"
        PROFILE_PATH="$candidate"
    fi
done < <(find "${PROFILE_ROOTS[@]}" -type f \
    \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) -print0)
[[ -n "$PROFILE_PATH" ]] \
    || fail "install the portal-created '$PROVISIONING_PROFILE_NAME' profile first"

PROFILE_PLIST="$PREFLIGHT_DIR/profile.plist"
security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST"
expect_equal "$(plist_value "$PROFILE_PLIST" Name)" "$PROVISIONING_PROFILE_NAME" \
    "Provisioning profile name"
expect_equal "$(plist_value "$PROFILE_PLIST" 'TeamIdentifier:0')" "$TEAM_ID" \
    "Provisioning profile team"
expect_equal "$(plist_value "$PROFILE_PLIST" 'ApplicationIdentifierPrefix:0')" "$TEAM_ID" \
    "Provisioning profile application prefix"
expect_equal "$(plist_value "$PROFILE_PLIST" 'Entitlements:com.apple.application-identifier')" \
    "$TEAM_ID.$BUNDLE_ID" "Provisioning profile application identifier"
expect_equal "$(plist_value "$PROFILE_PLIST" 'Entitlements:com.apple.developer.team-identifier')" \
    "$TEAM_ID" "Provisioning profile entitlement team"
expect_equal "$(plist_value "$PROFILE_PLIST" 'Entitlements:keychain-access-groups:0')" \
    "$TEAM_ID.*" "Provisioning profile keychain authorization"
expect_equal "$(plist_value "$PROFILE_PLIST" 'Platform:0')" "OSX" \
    "Provisioning profile platform"
expect_equal "$(plist_value "$PROFILE_PLIST" ProvisionsAllDevices)" "true" \
    "Provisioning profile distribution scope"

PROFILE_UUID="$(plist_value "$PROFILE_PLIST" UUID)"
PROFILE_EXPIRY="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST")"
PROFILE_EXPIRY_EPOCH="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRY" '+%s')" \
    || fail "could not parse provisioning profile expiration"
NOW_EPOCH="$(date '+%s')"
(( PROFILE_EXPIRY_EPOCH > NOW_EPOCH )) \
    || fail "'$PROVISIONING_PROFILE_NAME' expired at $PROFILE_EXPIRY"
if (( PROFILE_EXPIRY_EPOCH - NOW_EPOCH < 7776000 )); then
    echo "warning: '$PROVISIONING_PROFILE_NAME' expires within 90 days ($PROFILE_EXPIRY)" >&2
fi

PROFILE_CERT="$PREFLIGHT_DIR/profile-certificate.der"
/usr/libexec/PlistBuddy -c 'Print :DeveloperCertificates:0' "$PROFILE_PLIST" \
    > "$PROFILE_CERT"
openssl x509 -inform DER -in "$PROFILE_CERT" -noout -checkend 0 >/dev/null \
    || fail "the Developer ID certificate embedded in the profile is expired"
CERT_SUBJECT="$(openssl x509 -inform DER -in "$PROFILE_CERT" -noout \
    -subject -nameopt RFC2253)"
[[ "$CERT_SUBJECT" == *"CN=$SIGNING_IDENTITY"* ]] \
    || fail "the profile embeds a different Developer ID certificate"
[[ "$CERT_SUBJECT" == *"OU=$TEAM_ID"* ]] \
    || fail "the profile certificate has the wrong organizational unit"
SIGN_ID="$(openssl x509 -inform DER -in "$PROFILE_CERT" -noout -fingerprint -sha1 \
    | sed 's/^.*=//; s/://g')"
VALID_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -v fingerprint="$SIGN_ID" -v label="\"$SIGNING_IDENTITY\"" \
        '$2 == fingerprint && index($0, label) { print; exit }')"
[[ -n "$VALID_IDENTITY" ]] \
    || fail "the profile's current '$SIGNING_IDENTITY' private key is unavailable"
echo "  profile: $PROVISIONING_PROFILE_NAME ($PROFILE_UUID, expires $PROFILE_EXPIRY)"
echo "  identity: $SIGNING_IDENTITY (selected from the profile at runtime)"

echo "▸ validating notarytool profile '$NOTARY_PROFILE'…"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
    --team-id "$TEAM_ID" >/dev/null \
    || fail "notarytool profile '$NOTARY_PROFILE' failed its credential preflight"

echo "▸ resolving and validating Sparkle $SPARKLE_VERSION tools…"
xcodebuild -resolvePackageDependencies -project "$PROJ/Gainmap.xcodeproj" \
    -scheme Gainmap >/dev/null
BUILD_DIR="$(xcodebuild -project "$PROJ/Gainmap.xcodeproj" -scheme Gainmap \
    -configuration Release -showBuildSettings \
    | awk -F ' = ' '/^[[:space:]]*BUILD_DIR = / { print $2; exit }')"
[[ "$BUILD_DIR" == */Build/Products ]] \
    || fail "could not resolve Gainmap's DerivedData package location"
DERIVED_DATA_ROOT="${BUILD_DIR%/Build/Products}"
SPARKLE_ROOT="$DERIVED_DATA_ROOT/SourcePackages/artifacts/sparkle/Sparkle"
GEN_APPCAST="$SPARKLE_ROOT/bin/generate_appcast"
GEN_KEYS="$SPARKLE_ROOT/bin/generate_keys"
SPARKLE_INFO="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Resources/Info.plist"
[[ -x "$GEN_APPCAST" && -x "$GEN_KEYS" && -f "$SPARKLE_INFO" ]] \
    || fail "Sparkle tools were not materialized by package resolution"
expect_equal "$(plist_value "$SPARKLE_INFO" CFBundleShortVersionString)" \
    "$SPARKLE_VERSION" "Sparkle tool version"
codesign --verify --strict --verbose=2 "$GEN_APPCAST"
SPARKLE_PUBLIC_KEY="$($GEN_KEYS --account "$SPARKLE_ACCOUNT" -p)" \
    || fail "Sparkle signing key '$SPARKLE_ACCOUNT' is unavailable"
expect_equal "$SPARKLE_PUBLIC_KEY" \
    "$(plist_value "$PROJ/Mac/Support/Info.plist" SUPublicEDKey)" \
    "Sparkle public signing key"

echo "▸ validating GitHub release destination…"
gh auth status --hostname github.com >/dev/null
if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    fail "GitHub release $TAG already exists; build numbers are immutable"
fi
PREVIOUS_TAG="$(gh release view --repo "$GITHUB_REPOSITORY" \
    --json tagName --jq .tagName 2>/dev/null || true)"
[[ "$PREVIOUS_TAG" != "$TAG" ]] || fail "latest release already uses $TAG"
[[ ! -e "$RELEASE_DIR" ]] \
    || fail "release directory already exists: $RELEASE_DIR"

# Fetch the current public feed into the disposable preflight directory. This
# proves the prior archive and appcast are intact before a release performs an
# archive or notarization, and gives full releases a clean delta seed.
PREVIOUS_DOWNLOAD="$PREFLIGHT_DIR/previous-release"
PREVIOUS_BUILD=""
PREVIOUS_VERSION=""
if [[ -n "$PREVIOUS_TAG" ]]; then
    mkdir -p "$PREVIOUS_DOWNLOAD"
    gh release download "$PREVIOUS_TAG" --repo "$GITHUB_REPOSITORY" \
        --pattern Gainmap.dmg --pattern appcast.xml --dir "$PREVIOUS_DOWNLOAD" \
        || fail "could not download the prior release assets from $PREVIOUS_TAG"
    [[ -f "$PREVIOUS_DOWNLOAD/Gainmap.dmg" && \
       -f "$PREVIOUS_DOWNLOAD/appcast.xml" ]] \
        || fail "$PREVIOUS_TAG must contain Gainmap.dmg and appcast.xml"
    for previous_asset_name in Gainmap.dmg appcast.xml; do
        remote_digest="$(gh release view "$PREVIOUS_TAG" \
            --repo "$GITHUB_REPOSITORY" --json assets \
            --jq ".assets[] | select(.name == \"$previous_asset_name\") | .digest")"
        [[ "$remote_digest" == sha256:* ]] \
            || fail "$PREVIOUS_TAG/$previous_asset_name has no SHA-256 digest"
        local_digest="sha256:$(shasum -a 256 \
            "$PREVIOUS_DOWNLOAD/$previous_asset_name" | awk '{ print $1 }')"
        expect_equal "$local_digest" "$remote_digest" \
            "Downloaded $previous_asset_name digest"
    done
    hdiutil verify "$PREVIOUS_DOWNLOAD/Gainmap.dmg" >/dev/null
    xmllint --noout "$PREVIOUS_DOWNLOAD/appcast.xml"
    TOP_ITEM="/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]"
    PREVIOUS_BUILD="$(xmllint --xpath \
        "string($TOP_ITEM/*[local-name()='version'])" \
        "$PREVIOUS_DOWNLOAD/appcast.xml")"
    PREVIOUS_VERSION="$(xmllint --xpath \
        "string($TOP_ITEM/*[local-name()='shortVersionString'])" \
        "$PREVIOUS_DOWNLOAD/appcast.xml")"
    [[ "$PREVIOUS_BUILD" =~ ^[0-9]+$ ]] \
        || fail "$PREVIOUS_TAG appcast has an invalid top build"
    (( 10#$PREVIOUS_BUILD < 10#$BUILD_NUMBER )) \
        || fail "$PREVIOUS_TAG build $PREVIOUS_BUILD is not older than $BUILD_NUMBER"
    if [[ "$PREVIOUS_TAG" =~ ^v(.+)-b([0-9]+)$ ]]; then
        PREVIOUS_TAG_VERSION="${BASH_REMATCH[1]}"
        PREVIOUS_TAG_BUILD="${BASH_REMATCH[2]}"
        expect_equal "$PREVIOUS_VERSION" "$PREVIOUS_TAG_VERSION" \
            "Previous appcast marketing version"
        expect_equal "$PREVIOUS_BUILD" "$PREVIOUS_TAG_BUILD" \
            "Previous appcast build"
    fi
    expect_equal "$(xmllint --xpath \
        "string($TOP_ITEM/*[local-name()='enclosure']/@length)" \
        "$PREVIOUS_DOWNLOAD/appcast.xml")" \
        "$(stat -f '%z' "$PREVIOUS_DOWNLOAD/Gainmap.dmg")" \
        "Previous appcast enclosure length"
    [[ -n "$(xmllint --xpath \
        "string($TOP_ITEM/*[local-name()='enclosure']/@*[local-name()='edSignature'])" \
        "$PREVIOUS_DOWNLOAD/appcast.xml")" ]] \
        || fail "$PREVIOUS_TAG appcast is missing its EdDSA signature"
    echo "  delta seed: $PREVIOUS_TAG ($PREVIOUS_VERSION, build $PREVIOUS_BUILD)"
fi

echo "✓ release preflight passed for Gainmap $MARKETING_VERSION ($BUILD_NUMBER)"
echo "  output: $RELEASE_DIR"
if (( PREFLIGHT_ONLY )); then
    exit 0
fi

mkdir -p "$RELEASE_DIR"

# ---------------------------------------------------------------------------
# 1. Build helper, archive with the profile-selected certificate, then re-sign
#    all nested code inside-out with the same current identity.
# ---------------------------------------------------------------------------
GAINMAP_SIGN_ID="$SIGN_ID" "$PROJ/scripts/build-binary.sh"

ARCHIVE="$RELEASE_DIR/Gainmap.xcarchive"
echo "▸ archiving Gainmap.app…"
xcodebuild -project "$PROJ/Gainmap.xcodeproj" -scheme Gainmap \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" archive \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=$SIGN_ID" \
    "DEVELOPMENT_TEAM=$TEAM_ID" \
    "PROVISIONING_PROFILE_SPECIFIER=$PROVISIONING_PROFILE_NAME" \
    "MARKETING_VERSION=$MARKETING_VERSION" \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"

ARCHIVED_APP="$ARCHIVE/Products/Applications/Gainmap.app"
[[ -d "$ARCHIVED_APP" ]] || fail "archive did not contain Gainmap.app"
APP="$RELEASE_DIR/Gainmap.app"
ditto "$ARCHIVED_APP" "$APP"

[[ -f "$APP/Contents/embedded.provisionprofile" ]] \
    || fail "archive omitted the Developer ID provisioning profile"
ARCHIVE_ENTITLEMENTS="$PREFLIGHT_DIR/archive-entitlements.plist"
codesign -d --entitlements :- "$APP" > "$ARCHIVE_ENTITLEMENTS" 2>/dev/null
plutil -lint "$ARCHIVE_ENTITLEMENTS" >/dev/null
expect_equal "$(plist_value "$ARCHIVE_ENTITLEMENTS" 'keychain-access-groups:0')" \
    "$TEAM_ID.$BUNDLE_ID" "Archived app keychain entitlement"

echo "▸ re-signing nested helpers and app…"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    SPARKLE_CURRENT="$SPARKLE_FRAMEWORK/Versions/Current"
    for component in \
        "XPCServices/Downloader.xpc" \
        "XPCServices/Installer.xpc" \
        "Updater.app" \
        "Autoupdate"
    do
        [[ -e "$SPARKLE_CURRENT/$component" ]] && \
            codesign --force --options runtime --timestamp \
                --sign "$SIGN_ID" "$SPARKLE_CURRENT/$component"
    done
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" "$SPARKLE_FRAMEWORK"
fi
for framework_name in Sentry.framework GainmapCore.framework; do
    framework="$APP/Contents/Frameworks/$framework_name"
    [[ -d "$framework" ]] && codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" "$framework"
done
codesign --force --options runtime --timestamp --sign "$SIGN_ID" \
    "$APP/Contents/Resources/Helpers/uhdrtool"
codesign --force --options runtime --timestamp --generate-entitlement-der \
    --entitlements "$ARCHIVE_ENTITLEMENTS" --sign "$SIGN_ID" "$APP"

validate_signed_app() {
    local app="$1"
    local embedded_profile="$app/Contents/embedded.provisionprofile"
    local embedded_plist="$PREFLIGHT_DIR/embedded-profile.plist"
    local signed_entitlements="$PREFLIGHT_DIR/signed-entitlements.plist"
    local signature_info leaf_prefix leaf_fingerprint

    codesign --verify --deep --strict --verbose=2 "$app"
    signature_info="$(codesign -dv --verbose=4 "$app" 2>&1)"
    printf '%s\n' "$signature_info" | grep -Fq "Authority=$SIGNING_IDENTITY" \
        || fail "final app has the wrong signing authority"
    printf '%s\n' "$signature_info" | grep -Fq "TeamIdentifier=$TEAM_ID" \
        || fail "final app has the wrong TeamIdentifier"
    printf '%s\n' "$signature_info" | grep -Fq 'flags=0x10000(runtime)' \
        || fail "final app is missing hardened runtime"

    security cms -D -i "$embedded_profile" > "$embedded_plist"
    expect_equal "$(plist_value "$embedded_plist" UUID)" "$PROFILE_UUID" \
        "Embedded provisioning profile UUID"
    expect_equal "$(plist_value "$embedded_plist" 'TeamIdentifier:0')" "$TEAM_ID" \
        "Embedded provisioning profile team"
    expect_equal "$(plist_value "$embedded_plist" 'Entitlements:com.apple.application-identifier')" \
        "$TEAM_ID.$BUNDLE_ID" "Embedded provisioning profile app identifier"
    expect_equal "$(plist_value "$embedded_plist" 'Entitlements:keychain-access-groups:0')" \
        "$TEAM_ID.*" "Embedded provisioning profile keychain authorization"

    codesign -d --entitlements :- "$app" > "$signed_entitlements" 2>/dev/null
    plutil -lint "$signed_entitlements" >/dev/null
    expect_equal "$(plist_value "$signed_entitlements" 'com.apple.application-identifier')" \
        "$TEAM_ID.$BUNDLE_ID" "Signed application identifier"
    expect_equal "$(plist_value "$signed_entitlements" 'com.apple.developer.team-identifier')" \
        "$TEAM_ID" "Signed entitlement team"
    expect_equal "$(plist_value "$signed_entitlements" 'keychain-access-groups:0')" \
        "$TEAM_ID.$BUNDLE_ID" "Signed keychain access group"
    expect_equal "$(plist_value "$signed_entitlements" 'com.apple.security.app-sandbox')" \
        "false" "Signed sandbox entitlement"

    leaf_prefix="$PREFLIGHT_DIR/final-signing-certificate-"
    codesign -d --extract-certificates="$leaf_prefix" "$app" >/dev/null 2>&1
    [[ -f "${leaf_prefix}0" ]] || fail "could not extract the final signing certificate"
    leaf_fingerprint="$(openssl x509 -inform DER -in "${leaf_prefix}0" -noout \
        -fingerprint -sha1 | sed 's/^.*=//; s/://g')"
    expect_equal "$leaf_fingerprint" "$SIGN_ID" "Final signing certificate"

    expect_equal "$(plist_value "$app/Contents/Info.plist" CFBundleIdentifier)" \
        "$BUNDLE_ID" "Final bundle identifier"
    expect_equal "$(plist_value "$app/Contents/Info.plist" CFBundleShortVersionString)" \
        "$MARKETING_VERSION" "Final marketing version"
    expect_equal "$(plist_value "$app/Contents/Info.plist" CFBundleVersion)" \
        "$BUILD_NUMBER" "Final build number"
}

validate_signed_app "$APP"

echo "▸ building and signing Gainmap.dmg…"
DMG="$RELEASE_DIR/Gainmap.dmg"
DMG_STAGE="$PREFLIGHT_DIR/dmg-stage"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/Gainmap.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Gainmap" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
codesign --verify --verbose=2 "$DMG"
hdiutil verify "$DMG"

echo "▸ notarizing and stapling Gainmap.dmg…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" \
    --team-id "$TEAM_ID" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

MOUNT_POINT="$PREFLIGHT_DIR/mounted-dmg"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
spctl -a -vvv --type execute "$MOUNT_POINT/Gainmap.app"
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNT_POINT=""

# ---------------------------------------------------------------------------
# 2. Upload symbols. Telemetry plumbing remains non-fatal, but its release ID
#    exactly matches what the SDK reports at runtime.
# ---------------------------------------------------------------------------
if command -v sentry-cli >/dev/null 2>&1; then
    echo "▸ uploading dSYMs to Sentry…"
    SENTRY_ORG_SLUG="sam-hurd-photo"
    SENTRY_PROJECT_SLUG="gainmap"
    SENTRY_RELEASE="$BUNDLE_ID@$MARKETING_VERSION+$BUILD_NUMBER"
    sentry-cli debug-files upload \
        --org "$SENTRY_ORG_SLUG" --project "$SENTRY_PROJECT_SLUG" \
        --include-sources --wait "$ARCHIVE/dSYMs" \
        || echo "  (dSYM upload failed — continuing)"
    sentry-cli releases new --org "$SENTRY_ORG_SLUG" \
        --project "$SENTRY_PROJECT_SLUG" "$SENTRY_RELEASE" || true
    ( cd "$ROOT" && sentry-cli releases set-commits \
        --org "$SENTRY_ORG_SLUG" --project "$SENTRY_PROJECT_SLUG" \
        "$SENTRY_RELEASE" --auto ) || true
    sentry-cli releases finalize --org "$SENTRY_ORG_SLUG" \
        --project "$SENTRY_PROJECT_SLUG" "$SENTRY_RELEASE" || true
else
    echo "▸ sentry-cli not found — skipping dSYM upload"
fi

# ---------------------------------------------------------------------------
# 3. Build an isolated Sparkle feed. Seed it from the actual latest GitHub
#    release so a v1.5 -> v1.6 delta is generated when Sparkle deems it safe.
# ---------------------------------------------------------------------------
echo "▸ generating isolated Sparkle appcast…"
FEED_WORK="$(mktemp -d /tmp/gainmap-sparkle-feed.XXXXXX)"
FEED_SOURCE="$FEED_WORK/source"
mkdir -p "$FEED_SOURCE"
ditto "$DMG" "$FEED_SOURCE/Gainmap.dmg"

if [[ -n "$PREVIOUS_TAG" ]]; then
    ditto "$PREVIOUS_DOWNLOAD/appcast.xml" "$FEED_SOURCE/appcast.xml"
    ditto "$PREVIOUS_DOWNLOAD/Gainmap.dmg" \
        "$FEED_SOURCE/Gainmap-$PREVIOUS_TAG.dmg"
    echo "  seeding delta generation from $PREVIOUS_TAG (build $PREVIOUS_BUILD)"
fi

"$GEN_APPCAST" --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --maximum-versions 3 --maximum-deltas 1 \
    --versions "$BUILD_NUMBER" "$FEED_SOURCE"

GENERATED_APPCAST="$FEED_SOURCE/appcast.xml"
[[ -f "$GENERATED_APPCAST" ]] || fail "Sparkle did not generate appcast.xml"
xmllint --noout "$GENERATED_APPCAST"
TOP_ITEM="/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]"
APPCAST_BUILD="$(xmllint --xpath \
    "string($TOP_ITEM/*[local-name()='version'])" "$GENERATED_APPCAST")"
APPCAST_VERSION="$(xmllint --xpath \
    "string($TOP_ITEM/*[local-name()='shortVersionString'])" "$GENERATED_APPCAST")"
APPCAST_URL="$(xmllint --xpath \
    "string($TOP_ITEM/*[local-name()='enclosure']/@url)" "$GENERATED_APPCAST")"
APPCAST_LENGTH="$(xmllint --xpath \
    "string($TOP_ITEM/*[local-name()='enclosure']/@length)" "$GENERATED_APPCAST")"
APPCAST_SIGNATURE="$(xmllint --xpath \
    "string($TOP_ITEM/*[local-name()='enclosure']/@*[local-name()='edSignature'])" \
    "$GENERATED_APPCAST")"
expect_equal "$APPCAST_BUILD" "$BUILD_NUMBER" "Sparkle appcast build"
expect_equal "$APPCAST_VERSION" "$MARKETING_VERSION" "Sparkle appcast version"
expect_equal "$APPCAST_URL" "${DOWNLOAD_URL_PREFIX}Gainmap.dmg" \
    "Sparkle appcast enclosure URL"
expect_equal "$APPCAST_LENGTH" "$(stat -f '%z' "$DMG")" \
    "Sparkle appcast enclosure length"
[[ -n "$APPCAST_SIGNATURE" ]] || fail "Sparkle appcast is missing its EdDSA signature"

APPCAST="$RELEASE_DIR/appcast.xml"
ditto "$GENERATED_APPCAST" "$APPCAST"
DELTA_ASSETS=()
for delta in "$FEED_SOURCE"/*.delta; do
    [[ -f "$delta" ]] || continue
    delta_destination="$RELEASE_DIR/$(basename "$delta")"
    ditto "$delta" "$delta_destination"
    DELTA_ASSETS+=("$delta_destination")
done
DELTA_FROM="$(xmllint --xpath \
    "string($TOP_ITEM/*[local-name()='deltas']/*[local-name()='enclosure'][1]/@*[local-name()='deltaFrom'])" \
    "$GENERATED_APPCAST")"
if [[ -n "$PREVIOUS_BUILD" && "$PREVIOUS_BUILD" != "$BUILD_NUMBER" ]]; then
    if [[ "$DELTA_FROM" == "$PREVIOUS_BUILD" ]]; then
        echo "  preserved Sparkle delta: build $PREVIOUS_BUILD -> $BUILD_NUMBER"
    else
        echo "warning: Sparkle declined a safe delta from build $PREVIOUS_BUILD; full DMG remains available" >&2
    fi
fi

# ---------------------------------------------------------------------------
# 4. Publish exactly once. A reused build/tag is an error, never a clobber.
# ---------------------------------------------------------------------------
echo "▸ publishing GitHub Release $TAG…"
RELEASE_ASSETS=("$DMG" "$APPCAST")
for delta_asset in "${DELTA_ASSETS[@]}"; do
    RELEASE_ASSETS+=("$delta_asset")
done
gh release create "$TAG" "${RELEASE_ASSETS[@]}" \
    --repo "$GITHUB_REPOSITORY" \
    --title "Gainmap $MARKETING_VERSION" \
    --notes "Gainmap $MARKETING_VERSION"

PUBLISHED_TAG="$(gh release view --repo "$GITHUB_REPOSITORY" \
    --json tagName --jq .tagName)"
expect_equal "$PUBLISHED_TAG" "$TAG" "Latest GitHub release tag"

echo
echo "✓ Gainmap $MARKETING_VERSION ($BUILD_NUMBER) released from:"
echo "  $RELEASE_DIR"
echo "  • Gainmap.dmg (Developer ID signed, notarized, and stapled)"
echo "  • appcast.xml (Sparkle $SPARKLE_VERSION, EdDSA signed)"
for delta_asset in "${DELTA_ASSETS[@]}"; do
    echo "  • $(basename "$delta_asset")"
done
