#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
APP="$REPOSITORY_ROOT/dist/VolEq Community.app"
EXECUTABLE="$REPOSITORY_ROOT/.build/release/VolEqCommunityMac"
SPEECH_RESOURCE_BUNDLE="$REPOSITORY_ROOT/.build/release/VolEq_VolEqSpeech.bundle"

source "$REPOSITORY_ROOT/scripts/lib/toolchain.zsh"
voleq_validate_toolchain quiet

cd "$REPOSITORY_ROOT"
env CLANG_MODULE_CACHE_PATH="$REPOSITORY_ROOT/.build/clang-module-cache" \
    SWIFT_MODULECACHE_PATH="$REPOSITORY_ROOT/.build/swift-module-cache" \
    "$VOLEQ_SWIFT_BINARY" build --product VolEqCommunityMac -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/VolEqCommunityMac"
cp -R "$SPEECH_RESOURCE_BUNDLE" "$APP/Contents/Resources/VolEq_VolEqSpeech.bundle"
cp "$REPOSITORY_ROOT/apps/macos/community/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$REPOSITORY_ROOT/third_party/rnnoise/LICENSE" "$APP/Contents/Resources/RNNoise-LICENSE.txt"
cp "$REPOSITORY_ROOT/third_party/speexdsp/LICENSE" "$APP/Contents/Resources/SpeexDSP-LICENSE.txt"
printf '%s  %s\n' \
    "1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91" \
    "$APP/Contents/Resources/VolEq_VolEqSpeech.bundle/rnnoise-model.bin" \
    | shasum -a 256 --check --status
"$APP/Contents/MacOS/VolEqCommunityMac" --verify-speech-resources
codesign --force --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"

echo "$APP"
