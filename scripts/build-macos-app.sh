#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
APP="$REPOSITORY_ROOT/dist/VolEq Community.app"
EXECUTABLE="$REPOSITORY_ROOT/.build/release/VolEqCommunityMac"
SPEECH_RESOURCE_BUNDLE="$REPOSITORY_ROOT/.build/release/VolEq_VolEqSpeech.bundle"
COMMUNITY_RESOURCES="$REPOSITORY_ROOT/apps/macos/community/Resources"
INFO_PLIST="$COMMUNITY_RESOURCES/Info.plist"
BRAND_RESOURCE_KEYS=(CFBundleIconFile VolEqMenuBarTemplateFile)
BRAND_RESOURCE_EXTENSIONS=(icns png)

source "$REPOSITORY_ROOT/scripts/lib/toolchain.zsh"
voleq_validate_toolchain quiet

cd "$REPOSITORY_ROOT"
env CLANG_MODULE_CACHE_PATH="$REPOSITORY_ROOT/.build/clang-module-cache" \
    SWIFT_MODULECACHE_PATH="$REPOSITORY_ROOT/.build/swift-module-cache" \
    "$VOLEQ_SWIFT_BINARY" "$REPOSITORY_ROOT/scripts/generate-macos-icon.swift" --check
env CLANG_MODULE_CACHE_PATH="$REPOSITORY_ROOT/.build/clang-module-cache" \
    SWIFT_MODULECACHE_PATH="$REPOSITORY_ROOT/.build/swift-module-cache" \
    "$VOLEQ_SWIFT_BINARY" build --product VolEqCommunityMac -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/VolEqCommunityMac"
cp -R "$SPEECH_RESOURCE_BUNDLE" "$APP/Contents/Resources/VolEq_VolEqSpeech.bundle"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
for (( INDEX = 1; INDEX <= ${#BRAND_RESOURCE_KEYS[@]}; INDEX++ )); do
    RESOURCE_KEY="${BRAND_RESOURCE_KEYS[$INDEX]}"
    EXPECTED_EXTENSION="${BRAND_RESOURCE_EXTENSIONS[$INDEX]}"
    RESOURCE_FILE="$(plutil -extract "$RESOURCE_KEY" raw -o - "$INFO_PLIST")"
    if [[ -z "$RESOURCE_FILE"
        || "$RESOURCE_FILE" == "."
        || "$RESOURCE_FILE" == ".."
        || "$RESOURCE_FILE" == */*
        || "$RESOURCE_FILE" == *\\*
        || "$RESOURCE_FILE" == *:*
        || "$RESOURCE_FILE" == [[:space:]]*
        || "$RESOURCE_FILE" == *[[:space:]]
        || "${RESOURCE_FILE:e}" != "$EXPECTED_EXTENSION" ]]; then
        echo "error: invalid branding resource for $RESOURCE_KEY" >&2
        exit 1
    fi
    cp "$COMMUNITY_RESOURCES/$RESOURCE_FILE" "$APP/Contents/Resources/$RESOURCE_FILE"
done
cp "$REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$REPOSITORY_ROOT/third_party/rnnoise/LICENSE" "$APP/Contents/Resources/RNNoise-LICENSE.txt"
cp "$REPOSITORY_ROOT/third_party/speexdsp/LICENSE" "$APP/Contents/Resources/SpeexDSP-LICENSE.txt"
printf '%s  %s\n' \
    "1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91" \
    "$APP/Contents/Resources/VolEq_VolEqSpeech.bundle/rnnoise-model.bin" \
    | shasum -a 256 --check --status
"$APP/Contents/MacOS/VolEqCommunityMac" --verify-speech-resources
"$APP/Contents/MacOS/VolEqCommunityMac" --verify-app-resources
codesign --force --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"

echo "$APP"
