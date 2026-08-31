#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
TEMPORARY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/voleq-release-artifact-tests.XXXXXX")"
RELEASE_DIRECTORY="$TEMPORARY_ROOT/release"
INFO_PLIST="$REPOSITORY_ROOT/apps/macos/community/Resources/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
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

RC_DMG_FILENAME="$(
    voleq_release_dmg_filename \
        "$VOLEQ_COMMUNITY_ARTIFACT_PREFIX" \
        "$VERSION" \
        rc1
)"
FINAL_DMG_FILENAME="$(
    voleq_release_dmg_filename \
        "$VOLEQ_COMMUNITY_ARTIFACT_PREFIX" \
        "$VERSION"
)"
DMG="$RELEASE_DIRECTORY/$RC_DMG_FILENAME"

pass() {
    (( TEST_COUNT += 1 ))
    print -r -- "ok $TEST_COUNT - $1"
}

voleq_validate_product_plist \
    "$INFO_PLIST" \
    distribution
cp \
    "$INFO_PLIST" \
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

for removed_path in \
    "$REPOSITORY_ROOT/scripts/build-macos-audio-liveness-diagnostic.sh" \
    "$REPOSITORY_ROOT/tools/audio-liveness-test-source" \
    "$REPOSITORY_ROOT/artifacts/diagnostics"
do
    [[ ! -e "$removed_path" ]] \
        || { print -u2 -- "not ok - private diagnostic output remains: $removed_path"; exit 1; }
done
for diagnostic_key in VolEqDiagnosticVariant VolEqSourceCommit
do
    if plutil -extract "$diagnostic_key" raw -o - "$INFO_PLIST" \
        >/dev/null 2>&1; then
        print -u2 -- "not ok - public Info.plist contains $diagnostic_key"
        exit 1
    fi
done
if grep -R -E \
    "VolEq Audio Liveness Diagnostic|Export Diagnostic Report|Clear Diagnostic Data|Run Controlled Recovery Test|Verify & Reconnect|Reconnect Audio|VolEqLivenessTestSource|VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC" \
    "$REPOSITORY_ROOT/Package.swift" \
    "$REPOSITORY_ROOT/apps/macos/community/Sources" \
    "$REPOSITORY_ROOT/dev" >/dev/null; then
    print -u2 -- "not ok - private diagnostic product surface remains"
    exit 1
fi
pass "keeps the public application identity and product surface release-only"

[[ "$RC_DMG_FILENAME" == "VolEq-Community-0.1.1-rc1-macOS-arm64.dmg" ]] \
    || { print -u2 -- "not ok - unexpected release-candidate DMG name"; exit 1; }
[[ "$FINAL_DMG_FILENAME" == "VolEq-Community-0.1.1-macOS-arm64.dmg" ]] \
    || { print -u2 -- "not ok - unexpected final DMG name"; exit 1; }
pass "derives release-candidate and final DMG names from application metadata"

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

print -r -- "failed candidate" > "$DMG"
print -r -- "failed checksum" > "$CHECKSUMS"
print -r -- "current evidence" > "$NOTARIZATION_DIRECTORY/dmg-log.json"

voleq_cleanup_publishable_release_outputs_after_attempt \
    "$RELEASE_DIRECTORY" \
    "$DMG" \
    "$CHECKSUMS" \
    false

[[ ! -e "$DMG" ]] \
    || { print -u2 -- "not ok - failed candidate DMG survived"; exit 1; }
[[ ! -e "$CHECKSUMS" ]] \
    || { print -u2 -- "not ok - failed candidate checksum survived"; exit 1; }
[[ -f "$NOTARIZATION_DIRECTORY/dmg-log.json" ]] \
    || { print -u2 -- "not ok - current notarization evidence was removed"; exit 1; }
pass "removes failed publishable outputs while preserving notarization evidence"

print -r -- "failed candidate" > "$DMG"
print -r -- "failed checksum" > "$CHECKSUMS"
BLOCKED_WORKSPACE_PARENT="$TEMPORARY_ROOT/locked-workspace-parent"
BLOCKED_WORKSPACE="$BLOCKED_WORKSPACE_PARENT/workspace"
mkdir -p "$BLOCKED_WORKSPACE"
chmod 500 "$BLOCKED_WORKSPACE_PARENT"

if voleq_cleanup_release_attempt \
    "$RELEASE_DIRECTORY" \
    "$DMG" \
    "$CHECKSUMS" \
    false \
    "$BLOCKED_WORKSPACE" >/dev/null 2>&1; then
    chmod 700 "$BLOCKED_WORKSPACE_PARENT"
    print -u2 -- "not ok - accepted a release cleanup with an undeletable workspace"
    exit 1
fi
chmod 700 "$BLOCKED_WORKSPACE_PARENT"
[[ ! -e "$DMG" ]] \
    || { print -u2 -- "not ok - workspace failure left a candidate DMG"; exit 1; }
[[ ! -e "$CHECKSUMS" ]] \
    || { print -u2 -- "not ok - workspace failure left a candidate checksum"; exit 1; }
[[ -d "$BLOCKED_WORKSPACE" ]] \
    || { print -u2 -- "not ok - workspace failure fixture was removed"; exit 1; }
pass "removes failed publishable outputs before workspace cleanup"

print -r -- "accepted candidate" > "$DMG"
print -r -- "accepted checksum" > "$CHECKSUMS"
voleq_cleanup_publishable_release_outputs_after_attempt \
    "$RELEASE_DIRECTORY" \
    "$DMG" \
    "$CHECKSUMS" \
    true
[[ -f "$DMG" && -f "$CHECKSUMS" ]] \
    || { print -u2 -- "not ok - successful publishable outputs were removed"; exit 1; }
pass "preserves publishable outputs only after complete packaging success"

rm -f "$DMG" "$CHECKSUMS"

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
