#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
TEMPORARY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/voleq-release-artifact-tests.XXXXXX")"
RELEASE_DIRECTORY="$TEMPORARY_ROOT/release"
DMG="$RELEASE_DIRECTORY/VolEq-Community-0.1.0-rc1-macOS-arm64.dmg"
CHECKSUMS="$RELEASE_DIRECTORY/SHA256SUMS.txt"
NOTARIZATION_DIRECTORY="$RELEASE_DIRECTORY/notarization"
OUTSIDE_FILE="$TEMPORARY_ROOT/outside.dmg"
DEVELOPMENT_INFO_PLIST="$TEMPORARY_ROOT/Development-Info.plist"
TEST_COUNT=0

cleanup() {
    rm -rf "$TEMPORARY_ROOT"
}
trap cleanup EXIT

source "$REPOSITORY_ROOT/scripts/lib/release-artifacts.zsh"
source "$REPOSITORY_ROOT/scripts/lib/product-naming.zsh"

pass() {
    (( TEST_COUNT += 1 ))
    print -r -- "ok $TEST_COUNT - $1"
}

voleq_validate_product_plist \
    "$REPOSITORY_ROOT/apps/macos/community/Resources/Info.plist" \
    distribution
cp \
    "$REPOSITORY_ROOT/apps/macos/community/Resources/Info.plist" \
    "$DEVELOPMENT_INFO_PLIST"
plutil -replace CFBundleDisplayName \
    -string "$VOLEQ_DEVELOPMENT_PRODUCT_NAME" \
    "$DEVELOPMENT_INFO_PLIST"
plutil -replace CFBundleName \
    -string "$VOLEQ_DEVELOPMENT_PRODUCT_NAME" \
    "$DEVELOPMENT_INFO_PLIST"
plutil -replace CFBundleIdentifier \
    -string "$VOLEQ_DEVELOPMENT_BUNDLE_IDENTIFIER" \
    "$DEVELOPMENT_INFO_PLIST"
voleq_validate_product_plist "$DEVELOPMENT_INFO_PLIST" development
plutil -replace CFBundleDisplayName \
    -string "VolEq Community Dev" \
    "$DEVELOPMENT_INFO_PLIST"
if voleq_validate_product_plist \
    "$DEVELOPMENT_INFO_PLIST" \
    development >/dev/null 2>&1; then
    print -u2 -- "not ok - accepted the legacy development display name"
    exit 1
fi
[[ "$VOLEQ_RELEASE_APP_BUNDLE" == "VolEq.app" ]] \
    || { print -u2 -- "not ok - unexpected release app bundle"; exit 1; }
[[ "$VOLEQ_DEVELOPMENT_APP_BUNDLE" == "VolEq Dev.app" ]] \
    || { print -u2 -- "not ok - unexpected development app bundle"; exit 1; }
[[ "$VOLEQ_COMMUNITY_ARTIFACT_PREFIX" == "VolEq-Community" ]] \
    || { print -u2 -- "not ok - unexpected Community artifact prefix"; exit 1; }
pass "validates release, development, and Community artifact naming"

mkdir -p "$NOTARIZATION_DIRECTORY"
print -r -- "old dmg" > "$DMG"
print -r -- "old checksum" > "$CHECKSUMS"
print -r -- "old evidence" > "$NOTARIZATION_DIRECTORY/app-log.json"

voleq_invalidate_release_outputs \
    "$RELEASE_DIRECTORY" \
    "$DMG" \
    "$CHECKSUMS" \
    "$NOTARIZATION_DIRECTORY"

[[ ! -e "$DMG" ]] || { print -u2 -- "not ok - stale DMG survived"; exit 1; }
[[ ! -e "$CHECKSUMS" ]] || { print -u2 -- "not ok - stale checksum survived"; exit 1; }
[[ -d "$NOTARIZATION_DIRECTORY" ]] \
    || { print -u2 -- "not ok - notarization directory was not recreated"; exit 1; }
[[ -z "$(find "$NOTARIZATION_DIRECTORY" -mindepth 1 -print -quit)" ]] \
    || { print -u2 -- "not ok - stale notarization evidence survived"; exit 1; }
pass "invalidates every stale publishable release output"

print -r -- "keep" > "$OUTSIDE_FILE"
if voleq_invalidate_release_outputs \
    "$RELEASE_DIRECTORY" \
    "$OUTSIDE_FILE" \
    "$CHECKSUMS" \
    "$NOTARIZATION_DIRECTORY" >/dev/null 2>&1; then
    print -u2 -- "not ok - accepted a DMG outside the release directory"
    exit 1
fi
[[ -f "$OUTSIDE_FILE" ]] \
    || { print -u2 -- "not ok - unsafe path validation removed an outside file"; exit 1; }
pass "rejects unsafe cleanup paths without deleting them"

print -r -- "$TEST_COUNT release artifact checks passed."
