#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
source "$REPOSITORY_ROOT/scripts/lib/product-naming.zsh"

APP="$REPOSITORY_ROOT/dist/$VOLEQ_RELEASE_APP_BUNDLE"
EXECUTABLE="$APP/Contents/MacOS/$VOLEQ_EXECUTABLE_NAME"
INFO_PLIST="$REPOSITORY_ROOT/apps/macos/community/Resources/Info.plist"
RELEASE_DIRECTORY="$REPOSITORY_ROOT/dist/release"
NOTARIZATION_DIRECTORY="$RELEASE_DIRECTORY/notarization"
NOTARY_PROFILE="${VOLEQ_NOTARY_PROFILE:-voleq-notary}"
ARTIFACT_SUFFIX="${VOLEQ_RELEASE_SUFFIX:-}"

source "$REPOSITORY_ROOT/scripts/lib/release-artifacts.zsh"

fail() {
    echo "error: $1" >&2
    exit 1
}

[[ -z "$(git -C "$REPOSITORY_ROOT" status --porcelain)" ]] \
    || fail "release packaging requires a clean working tree"

"$REPOSITORY_ROOT/scripts/validate-release-metadata.sh"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
SOURCE_COMMIT="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"

if [[ -n "$ARTIFACT_SUFFIX" && ! "$ARTIFACT_SUFFIX" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' ]]; then
    fail "VOLEQ_RELEASE_SUFFIX must contain only letters, numbers, periods, and hyphens"
fi

DMG_FILENAME="$(
    voleq_release_dmg_filename \
        "$VOLEQ_COMMUNITY_ARTIFACT_PREFIX" \
        "$VERSION" \
        "$ARTIFACT_SUFFIX"
)"
DMG="$RELEASE_DIRECTORY/$DMG_FILENAME"
CHECKSUMS="$RELEASE_DIRECTORY/SHA256SUMS.txt"

# A failed rerun must not leave an older candidate at the documented publish
# paths or pair it with evidence from a newer source commit.
voleq_invalidate_release_outputs \
    "$RELEASE_DIRECTORY" \
    "$DMG" \
    "$CHECKSUMS" \
    "$NOTARIZATION_DIRECTORY" \
    || fail "could not invalidate previous release outputs"

SIGNING_IDENTITY="${VOLEQ_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    IDENTITY_OUTPUT="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F\" '/Developer ID Application:/ { print $2 }'
    )"
    IDENTITIES=()
    if [[ -n "$IDENTITY_OUTPUT" ]]; then
        IDENTITIES=("${(@f)IDENTITY_OUTPUT}")
    fi
    if (( ${#IDENTITIES[@]} != 1 )); then
        fail "expected exactly one Developer ID Application identity; set VOLEQ_SIGNING_IDENTITY explicitly"
    fi
    SIGNING_IDENTITY="$IDENTITIES[1]"
fi

[[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]] \
    || fail "VOLEQ_SIGNING_IDENTITY must name a Developer ID Application certificate"

security find-identity -v -p codesigning \
    | grep -Fq "\"$SIGNING_IDENTITY\"" \
    || fail "Developer ID Application identity is not available in the current keychain"

WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/voleq-release.XXXXXX")"
PACKAGE_SUCCEEDED=false
cleanup() {
    local exit_status=$?
    if ! voleq_cleanup_release_attempt \
        "$RELEASE_DIRECTORY" \
        "$DMG" \
        "$CHECKSUMS" \
        "$PACKAGE_SUCCEEDED" \
        "$WORK_DIRECTORY"; then
        print -u2 -- "warning: release cleanup was incomplete"
    fi
    return "$exit_status"
}
trap cleanup EXIT

cat > "$NOTARIZATION_DIRECTORY/build-metadata.txt" <<EOF
source_commit=$SOURCE_COMMIT
version=$VERSION
build=$BUILD
bundle_identifier=$BUNDLE_IDENTIFIER
architecture=arm64
notary_profile=$NOTARY_PROFILE
EOF

"$REPOSITORY_ROOT/scripts/build-macos-app.sh" >/dev/null

[[ -f "$EXECUTABLE" ]] || fail "release executable was not built"
[[ "${APP:t}" == "$VOLEQ_RELEASE_APP_BUNDLE" ]] \
    || fail "release application bundle has an unexpected name"
voleq_validate_product_plist "$APP/Contents/Info.plist" distribution \
    || fail "release application identity is invalid"
ARCHITECTURES="$(lipo -archs "$EXECUTABLE")"
[[ "$ARCHITECTURES" == "arm64" ]] \
    || fail "release must contain exactly the arm64 architecture; found: $ARCHITECTURES"

codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$EXECUTABLE"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" == "$VERSION" ]] \
    || fail "packaged version does not match source metadata"
[[ "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" == "$BUILD" ]] \
    || fail "packaged build does not match source metadata"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" == "$BUNDLE_IDENTIFIER" ]] \
    || fail "packaged bundle identifier does not match source metadata"
printf '%s  %s\n' \
    "1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91" \
    "$APP/Contents/Resources/VolEq_VolEqSpeech.bundle/rnnoise-model.bin" \
    | shasum -a 256 --check --status
"$EXECUTABLE" --verify-speech-resources
"$EXECUTABLE" --verify-app-resources
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_DETAILS="$(codesign -dvvv "$APP" 2>&1)"
grep -Eq '^Authority=Developer ID Application:' <<< "$SIGNATURE_DETAILS" \
    || fail "application is not signed with a Developer ID Application certificate"
grep -Eq 'CodeDirectory .*flags=[^[:space:]]*\(runtime\)' <<< "$SIGNATURE_DETAILS" \
    || fail "application signature does not enable Hardened Runtime"
grep -Eq '^Timestamp=' <<< "$SIGNATURE_DETAILS" \
    || fail "application signature does not contain a secure timestamp"
[[ -z "$(codesign -d --entitlements - "$APP" 2>/dev/null)" ]] \
    || fail "release application contains unexpected entitlements"

SIGNED_APP_ZIP="$WORK_DIRECTORY/$VOLEQ_COMMUNITY_ARTIFACT_PREFIX-$VERSION-signed-app.zip"
ditto -c -k --keepParent "$APP" "$SIGNED_APP_ZIP"

APP_SUBMISSION="$NOTARIZATION_DIRECTORY/app-submission.json"
APP_LOG="$NOTARIZATION_DIRECTORY/app-log.json"
xcrun notarytool submit "$SIGNED_APP_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json > "$APP_SUBMISSION"
APP_STATUS="$(plutil -extract status raw -o - "$APP_SUBMISSION")"
APP_SUBMISSION_ID="$(plutil -extract id raw -o - "$APP_SUBMISSION")"
xcrun notarytool log "$APP_SUBMISSION_ID" \
    --keychain-profile "$NOTARY_PROFILE" \
    "$APP_LOG" >/dev/null
[[ "$APP_STATUS" == "Accepted" ]] || fail "app notarization was not accepted; inspect $APP_LOG"

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP"

STAGING_DIRECTORY="$WORK_DIRECTORY/dmg-root"
mkdir -p "$STAGING_DIRECTORY"
ditto "$APP" "$STAGING_DIRECTORY/$VOLEQ_RELEASE_APP_BUNDLE"
ln -s /Applications "$STAGING_DIRECTORY/Applications"

hdiutil create \
    -volname "$VOLEQ_PRODUCT_NAME $VERSION" \
    -srcfolder "$STAGING_DIRECTORY" \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"
DMG_SIGNATURE_DETAILS="$(codesign -dvvv "$DMG" 2>&1)"
grep -Eq '^Authority=Developer ID Application:' <<< "$DMG_SIGNATURE_DETAILS" \
    || fail "DMG is not signed with a Developer ID Application certificate"
grep -Eq '^Timestamp=' <<< "$DMG_SIGNATURE_DETAILS" \
    || fail "DMG signature does not contain a secure timestamp"

DMG_SUBMISSION="$NOTARIZATION_DIRECTORY/dmg-submission.json"
DMG_LOG="$NOTARIZATION_DIRECTORY/dmg-log.json"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json > "$DMG_SUBMISSION"
DMG_STATUS="$(plutil -extract status raw -o - "$DMG_SUBMISSION")"
DMG_SUBMISSION_ID="$(plutil -extract id raw -o - "$DMG_SUBMISSION")"
xcrun notarytool log "$DMG_SUBMISSION_ID" \
    --keychain-profile "$NOTARY_PROFILE" \
    "$DMG_LOG" >/dev/null
[[ "$DMG_STATUS" == "Accepted" ]] || fail "DMG notarization was not accepted; inspect $DMG_LOG"

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
hdiutil verify "$DMG" >/dev/null
codesign --verify --verbose=2 "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

(
    cd "$RELEASE_DIRECTORY"
    shasum -a 256 "${DMG:t}" > "${CHECKSUMS:t}"
    shasum -a 256 --check "${CHECKSUMS:t}"
)

PACKAGE_SUCCEEDED=true
echo "Packaged VolEq $VERSION ($BUILD) from the Community repository"
echo "Source commit: $SOURCE_COMMIT"
echo "Bundle identifier: $BUNDLE_IDENTIFIER"
echo "DMG: $DMG"
echo "Checksums: $CHECKSUMS"
echo "Notarization evidence: $NOTARIZATION_DIRECTORY"
