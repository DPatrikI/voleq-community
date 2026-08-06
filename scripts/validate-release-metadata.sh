#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
INFO_PLIST="$REPOSITORY_ROOT/apps/macos/community/Resources/Info.plist"
SCREENSHOT="$REPOSITORY_ROOT/docs/assets/voleq-community-window.png"
EXPECTED_VERSION="0.1.0"
EXPECTED_BUILD="1"
EXPECTED_BUNDLE_IDENTIFIER="com.patrikistvandoczy.voleq.community"

fail() {
    echo "error: $1" >&2
    exit 1
}

[[ -f "$INFO_PLIST" ]] || fail "missing Community Info.plist"
[[ -f "$REPOSITORY_ROOT/CHANGELOG.md" ]] || fail "missing CHANGELOG.md"
[[ -f "$REPOSITORY_ROOT/docs/COMPATIBILITY.md" ]] || fail "missing compatibility matrix"
[[ -f "$REPOSITORY_ROOT/docs/RELEASING.md" ]] || fail "missing release procedure"
[[ -f "$SCREENSHOT" ]] || fail "missing README screenshot"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"

[[ "$VERSION" == "$EXPECTED_VERSION" ]] || fail "expected version $EXPECTED_VERSION, found $VERSION"
[[ "$BUILD" == "$EXPECTED_BUILD" ]] || fail "expected build $EXPECTED_BUILD, found $BUILD"
[[ "$BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
    || fail "unexpected bundle identifier: $BUNDLE_IDENTIFIER"

grep -Fq "## [0.1.0]" "$REPOSITORY_ROOT/CHANGELOG.md" \
    || fail "CHANGELOG.md does not contain version 0.1.0"
grep -Fq "docs/assets/voleq-community-window.png" "$REPOSITORY_ROOT/README.md" \
    || fail "README.md does not reference the release screenshot"
grep -Fq "docs/COMPATIBILITY.md" "$REPOSITORY_ROOT/README.md" \
    || fail "README.md does not link the compatibility matrix"

SCREENSHOT_FORMAT="$(sips -g format "$SCREENSHOT" 2>/dev/null | awk '/format:/ { print $2 }')"
[[ "$SCREENSHOT_FORMAT" == "png" ]] || fail "release screenshot must be a PNG"

zsh -n "$REPOSITORY_ROOT/scripts/package-macos-release.sh"

echo "Release metadata is ready for VolEq Community $VERSION ($BUILD)."
