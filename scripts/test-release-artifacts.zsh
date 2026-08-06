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
TEST_COUNT=0

cleanup() {
    rm -rf "$TEMPORARY_ROOT"
}
trap cleanup EXIT

source "$REPOSITORY_ROOT/scripts/lib/release-artifacts.zsh"

pass() {
    (( TEST_COUNT += 1 ))
    print -r -- "ok $TEST_COUNT - $1"
}

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
