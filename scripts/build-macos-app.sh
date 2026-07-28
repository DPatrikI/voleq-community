#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
APP="$REPOSITORY_ROOT/dist/VolEq Community.app"
EXECUTABLE="$REPOSITORY_ROOT/.build/release/VolEqCommunityMac"

source "$REPOSITORY_ROOT/scripts/lib/toolchain.zsh"
voleq_validate_toolchain quiet

cd "$REPOSITORY_ROOT"
env CLANG_MODULE_CACHE_PATH="$REPOSITORY_ROOT/.build/clang-module-cache" \
    SWIFT_MODULECACHE_PATH="$REPOSITORY_ROOT/.build/swift-module-cache" \
    "$VOLEQ_SWIFT_BINARY" build --product VolEqCommunityMac -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$EXECUTABLE" "$APP/Contents/MacOS/VolEqCommunityMac"
cp "$REPOSITORY_ROOT/apps/macos/community/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"

echo "$APP"
