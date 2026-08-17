#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
source "$REPOSITORY_ROOT/scripts/lib/product-naming.zsh"
source "$REPOSITORY_ROOT/scripts/lib/toolchain.zsh"

ARTIFACT_DIRECTORY="$REPOSITORY_ROOT/artifacts/diagnostics/v0.1.1-audio-liveness"
APP="$ARTIFACT_DIRECTORY/$VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC_APP_BUNDLE"
EXECUTABLE="$REPOSITORY_ROOT/.build/release/$VOLEQ_EXECUTABLE_NAME"
TEST_SOURCE_EXECUTABLE="$REPOSITORY_ROOT/.build/release/VolEqLivenessTestSource"
SPEECH_RESOURCE_BUNDLE="$REPOSITORY_ROOT/.build/release/VolEq_VolEqSpeech.bundle"
COMMUNITY_RESOURCES="$REPOSITORY_ROOT/apps/macos/community/Resources"
INFO_PLIST="$COMMUNITY_RESOURCES/Info.plist"
SOURCE_COMMIT="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"
if [[ -n "$(git -C "$REPOSITORY_ROOT" status --porcelain --untracked-files=normal)" ]]; then
    SOURCE_COMMIT="${SOURCE_COMMIT}-dirty"
fi
BRAND_RESOURCE_KEYS=(CFBundleIconFile VolEqMenuBarTemplateFile)
BRAND_RESOURCE_EXTENSIONS=(icns png)

voleq_validate_toolchain quiet
cd "$REPOSITORY_ROOT"
env CLANG_MODULE_CACHE_PATH="$REPOSITORY_ROOT/.build/clang-module-cache" \
    SWIFT_MODULECACHE_PATH="$REPOSITORY_ROOT/.build/swift-module-cache" \
    "$VOLEQ_SWIFT_BINARY" "$REPOSITORY_ROOT/scripts/generate-macos-icon.swift" --check
env CLANG_MODULE_CACHE_PATH="$REPOSITORY_ROOT/.build/clang-module-cache" \
    SWIFT_MODULECACHE_PATH="$REPOSITORY_ROOT/.build/swift-module-cache" \
    "$VOLEQ_SWIFT_BINARY" build \
        --product "$VOLEQ_EXECUTABLE_NAME" \
        -c release \
        -Xswiftc -DVOLEQ_AUDIO_LIVENESS_DIAGNOSTIC
env CLANG_MODULE_CACHE_PATH="$REPOSITORY_ROOT/.build/clang-module-cache" \
    SWIFT_MODULECACHE_PATH="$REPOSITORY_ROOT/.build/swift-module-cache" \
    "$VOLEQ_SWIFT_BINARY" build \
        --product VolEqLivenessTestSource \
        -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$EXECUTABLE" "$APP/Contents/MacOS/$VOLEQ_EXECUTABLE_NAME"
cp "$TEST_SOURCE_EXECUTABLE" "$APP/Contents/Helpers/VolEqLivenessTestSource"
cp -R "$SPEECH_RESOURCE_BUNDLE" "$APP/Contents/Resources/VolEq_VolEqSpeech.bundle"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier \
    -string "$VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC_BUNDLE_IDENTIFIER" \
    "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName \
    -string "$VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC_PRODUCT_NAME" \
    "$APP/Contents/Info.plist"
plutil -replace CFBundleName \
    -string "$VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC_PRODUCT_NAME" \
    "$APP/Contents/Info.plist"
plutil -insert VolEqDiagnosticVariant \
    -string "audio-liveness" \
    "$APP/Contents/Info.plist"
plutil -insert VolEqDiagnosticSourceCommit \
    -string "$SOURCE_COMMIT" \
    "$APP/Contents/Info.plist"
voleq_validate_product_plist \
    "$APP/Contents/Info.plist" \
    audio-liveness-diagnostic

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
"$APP/Contents/MacOS/$VOLEQ_EXECUTABLE_NAME" --verify-speech-resources
"$APP/Contents/MacOS/$VOLEQ_EXECUTABLE_NAME" --verify-app-resources
codesign --force --sign - "$APP/Contents/Helpers/VolEqLivenessTestSource"
codesign --force --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"

echo "$APP"
