#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
INFO_PLIST="$REPOSITORY_ROOT/apps/macos/community/Resources/Info.plist"
EXPECTED_VERSION="0.1.0"
EXPECTED_BUILD="1"
EXPECTED_BUNDLE_IDENTIFIER="com.patrikistvandoczy.voleq.community"

fail() {
    echo "error: $1" >&2
    exit 1
}

[[ -f "$INFO_PLIST" ]] || fail "missing Community Info.plist"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"

[[ "$VERSION" == "$EXPECTED_VERSION" ]] || fail "expected version $EXPECTED_VERSION, found $VERSION"
[[ "$BUILD" == "$EXPECTED_BUILD" ]] || fail "expected build $EXPECTED_BUILD, found $BUILD"
[[ "$BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
    || fail "unexpected bundle identifier: $BUNDLE_IDENTIFIER"

zsh -n "$REPOSITORY_ROOT/scripts/package-macos-release.sh"

echo "Release metadata is ready for VolEq Community $VERSION ($BUILD)."
