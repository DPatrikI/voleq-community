#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

REPOSITORY_ROOT="${0:A:h:h}"
TEMPORARY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/voleq-doctor-tests.XXXXXX")"
MOCK_BIN="$TEMPORARY_ROOT/bin"
MOCK_DEVELOPER_DIRECTORY="$TEMPORARY_ROOT/Developer"
MOCK_SWIFT_BINARY="$MOCK_DEVELOPER_DIRECTORY/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
MOCK_SDK_PATH="$MOCK_DEVELOPER_DIRECTORY/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
TEST_COUNT=0

cleanup() {
    rm -rf "$TEMPORARY_ROOT"
}
trap cleanup EXIT

mkdir -p "$MOCK_BIN" "${MOCK_SWIFT_BINARY:h}" "$MOCK_SDK_PATH"

print -r -- '#!/bin/zsh
[[ "${1:-}" == "-productVersion" ]] || exit 2
print -r -- "$MOCK_MACOS_VERSION"' > "$MOCK_BIN/sw_vers"

print -r -- '#!/bin/zsh
[[ "${1:-}" == "-p" ]] || exit 2
print -r -- "$MOCK_DEVELOPER_DIRECTORY"' > "$MOCK_BIN/xcode-select"

print -r -- '#!/bin/zsh
if [[ "$*" == "--find swift" ]]; then
    print -r -- "$MOCK_SWIFT_BINARY"
elif [[ "$*" == "--sdk macosx --show-sdk-path" ]]; then
    print -r -- "$MOCK_SDK_PATH"
else
    exit 2
fi' > "$MOCK_BIN/xcrun"

print -r -- '#!/bin/zsh
print -r -- "Apple Swift version $MOCK_SWIFT_VERSION (swiftlang-test clang-test)"
print -r -- "Target: arm64-apple-macosx14.0"' > "$MOCK_SWIFT_BINARY"

chmod +x "$MOCK_BIN/sw_vers" "$MOCK_BIN/xcode-select" "$MOCK_BIN/xcrun" "$MOCK_SWIFT_BINARY"

run_case() {
    local name="$1"
    local expected_status="$2"
    local expected_text="$3"
    local macos_version="$4"
    local swift_version="$5"
    local developer_directory="${6:-$MOCK_DEVELOPER_DIRECTORY}"
    local output exit_status=0

    output="$(
        PATH="$MOCK_BIN:/usr/bin:/bin" \
        MOCK_MACOS_VERSION="$macos_version" \
        MOCK_SWIFT_VERSION="$swift_version" \
        MOCK_DEVELOPER_DIRECTORY="$developer_directory" \
        MOCK_SWIFT_BINARY="$MOCK_SWIFT_BINARY" \
        MOCK_SDK_PATH="$MOCK_SDK_PATH" \
        "$REPOSITORY_ROOT/dev" doctor 2>&1
    )" || exit_status=$?

    if [[ "$exit_status" -ne "$expected_status" ]]; then
        print -u2 -- "not ok - $name (expected status $expected_status, got $exit_status)"
        print -u2 -- "$output"
        exit 1
    fi
    if [[ "$output" != *"$expected_text"* ]]; then
        print -u2 -- "not ok - $name (missing '$expected_text')"
        print -u2 -- "$output"
        exit 1
    fi

    (( TEST_COUNT += 1 ))
    print -r -- "ok $TEST_COUNT - $name"
}

run_case "accepts the minimum supported toolchain" 0 "Environment is ready." "14.2" "5.10"
run_case "accepts newer major versions" 0 "Environment is ready." "26.5.2" "6.3.3"
run_case "rejects an old macOS version" 1 "macOS 14.2 or newer is required; found 14.1" "14.1" "5.10"
run_case "rejects an old Swift version" 1 "Swift 5.10 or newer is required; found 5.9" "14.2" "5.9"
run_case "rejects a missing developer directory" 1 "selected developer directory does not exist" "14.2" "5.10" "$TEMPORARY_ROOT/missing"

print -r -- "$TEST_COUNT developer environment checks passed."
