#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
source "$REPOSITORY_ROOT/scripts/lib/product-naming.zsh"

INFO_PLIST="$REPOSITORY_ROOT/apps/macos/community/Resources/Info.plist"
SCREENSHOT="$REPOSITORY_ROOT/docs/assets/voleq-community-window.png"
EXPECTED_VERSION="0.1.1"
EXPECTED_BUILD="2"

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

[[ "$VERSION" == "$EXPECTED_VERSION" ]] || fail "expected version $EXPECTED_VERSION, found $VERSION"
[[ "$BUILD" == "$EXPECTED_BUILD" ]] || fail "expected build $EXPECTED_BUILD, found $BUILD"
voleq_validate_product_plist "$INFO_PLIST" distribution \
    || fail "committed application identity is invalid"

grep -Fq "## [$VERSION]" "$REPOSITORY_ROOT/CHANGELOG.md" \
    || fail "CHANGELOG.md does not contain version $VERSION"
grep -Fq "[0.1.1]: https://github.com/DPatrikI/voleq-community/compare/v0.1.0...v0.1.1" \
    "$REPOSITORY_ROOT/CHANGELOG.md" \
    || fail "CHANGELOG.md does not contain the 0.1.1 comparison link"
grep -Fq "docs/assets/voleq-community-window.png" "$REPOSITORY_ROOT/README.md" \
    || fail "README.md does not reference the release screenshot"
grep -Fq "docs/COMPATIBILITY.md" "$REPOSITORY_ROOT/README.md" \
    || fail "README.md does not link the compatibility matrix"
grep -Fq '`dist/VolEq.app`' "$REPOSITORY_ROOT/README.md" \
    || fail "README.md does not document the VolEq application bundle"
grep -Fq '| macOS | Supported | Apple Silicon, macOS 14.2 or newer |' \
    "$REPOSITORY_ROOT/README.md" \
    || fail "README.md does not document supported macOS requirements"
grep -Fq '| Windows | Planned | Not yet available |' \
    "$REPOSITORY_ROOT/README.md" \
    || fail "README.md does not document planned Windows support"
grep -Fq '| Linux | Planned | Not yet available |' \
    "$REPOSITORY_ROOT/README.md" \
    || fail "README.md does not document planned Linux support"
grep -Fq 'VolEq-Community-0.1.1-rc1-macOS-arm64.dmg' \
    "$REPOSITORY_ROOT/docs/RELEASING.md" \
    || fail "release procedure does not document the 0.1.1 RC artifact"
grep -Fq 'VolEq-Community-0.1.1-macOS-arm64.dmg' \
    "$REPOSITORY_ROOT/docs/RELEASING.md" \
    || fail "release procedure does not document the 0.1.1 final artifact"

SCREENSHOT_FORMAT="$(sips -g format "$SCREENSHOT" 2>/dev/null | awk '/format:/ { print $2 }')"
[[ "$SCREENSHOT_FORMAT" == "png" ]] || fail "release screenshot must be a PNG"

zsh -n "$REPOSITORY_ROOT/scripts/package-macos-release.sh"

echo "Release metadata is ready for VolEq $VERSION ($BUILD)."
