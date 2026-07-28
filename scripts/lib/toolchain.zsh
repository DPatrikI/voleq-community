#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0

typeset -gr VOLEQ_MINIMUM_MACOS_VERSION="14.2"
typeset -gr VOLEQ_MINIMUM_SWIFT_VERSION="5.10"

typeset -g VOLEQ_DEVELOPER_DIRECTORY=""
typeset -g VOLEQ_MACOS_SDK_PATH=""
typeset -g VOLEQ_MACOS_VERSION=""
typeset -g VOLEQ_SWIFT_BINARY=""
typeset -g VOLEQ_SWIFT_VERSION=""

voleq_error() {
    print -u2 -- "error: $1"
}

voleq_require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        voleq_error "required command '$1' was not found in PATH"
        return 1
    fi
}

voleq_is_version() {
    [[ "$1" =~ '^[0-9]+([.][0-9]+){1,2}$' ]]
}

voleq_version_at_least() {
    local actual="$1"
    local minimum="$2"
    local -a actual_components minimum_components
    local index actual_component minimum_component

    actual_components=(${(s:.:)actual})
    minimum_components=(${(s:.:)minimum})

    for index in 1 2 3; do
        actual_component="${actual_components[$index]:-0}"
        minimum_component="${minimum_components[$index]:-0}"

        if (( actual_component > minimum_component )); then
            return 0
        fi
        if (( actual_component < minimum_component )); then
            return 1
        fi
    done

    return 0
}

voleq_swift_version_from() {
    local output="$1"
    local suffix

    if [[ "$output" == *"Apple Swift version "* ]]; then
        suffix="${output#*Apple Swift version }"
    elif [[ "$output" == *"Swift version "* ]]; then
        suffix="${output#*Swift version }"
    else
        return 1
    fi

    print -r -- "${suffix%%[[:space:]]*}"
}

voleq_validate_toolchain() {
    local output_mode="${1:-quiet}"
    local host_platform macos_version developer_directory swift_binary
    local sdk_path swift_output swift_version

    voleq_require_command uname || return 1
    host_platform="$(uname -s)" || {
        voleq_error "could not determine the host platform"
        return 1
    }
    if [[ "$host_platform" != "Darwin" ]]; then
        voleq_error "VolEq's macOS app requires macOS; detected $host_platform"
        return 1
    fi

    voleq_require_command sw_vers || return 1
    macos_version="$(sw_vers -productVersion)" || {
        voleq_error "could not determine the macOS version"
        return 1
    }
    if ! voleq_is_version "$macos_version"; then
        voleq_error "could not parse macOS version '$macos_version'"
        return 1
    fi
    if ! voleq_version_at_least "$macos_version" "$VOLEQ_MINIMUM_MACOS_VERSION"; then
        voleq_error "macOS $VOLEQ_MINIMUM_MACOS_VERSION or newer is required; found $macos_version"
        return 1
    fi

    voleq_require_command xcode-select || return 1
    developer_directory="$(xcode-select -p 2>/dev/null)" || {
        voleq_error "no active Apple developer directory; install Xcode or Command Line Tools, then run xcode-select"
        return 1
    }
    if [[ ! -d "$developer_directory" ]]; then
        voleq_error "selected developer directory does not exist: $developer_directory"
        return 1
    fi

    voleq_require_command xcrun || return 1
    swift_binary="$(xcrun --find swift 2>/dev/null)" || {
        voleq_error "the active developer tools cannot locate Swift; verify the xcode-select configuration"
        return 1
    }
    if [[ ! -x "$swift_binary" ]]; then
        voleq_error "Swift is not executable: $swift_binary"
        return 1
    fi

    sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || {
        voleq_error "the active developer tools cannot locate the macOS SDK"
        return 1
    }
    if [[ ! -d "$sdk_path" ]]; then
        voleq_error "the selected macOS SDK does not exist: $sdk_path"
        return 1
    fi

    swift_output="$("$swift_binary" --version 2>&1)" || {
        voleq_error "Swift could not run: $swift_binary"
        return 1
    }
    swift_version="$(voleq_swift_version_from "$swift_output")" || {
        voleq_error "could not parse the Swift version from: ${swift_output%%$'\n'*}"
        return 1
    }
    if ! voleq_is_version "$swift_version"; then
        voleq_error "could not parse Swift version '$swift_version'"
        return 1
    fi
    if ! voleq_version_at_least "$swift_version" "$VOLEQ_MINIMUM_SWIFT_VERSION"; then
        voleq_error "Swift $VOLEQ_MINIMUM_SWIFT_VERSION or newer is required; found $swift_version"
        return 1
    fi

    VOLEQ_MACOS_VERSION="$macos_version"
    VOLEQ_DEVELOPER_DIRECTORY="$developer_directory"
    VOLEQ_SWIFT_BINARY="$swift_binary"
    VOLEQ_MACOS_SDK_PATH="$sdk_path"
    VOLEQ_SWIFT_VERSION="$swift_version"

    if [[ "$output_mode" == "verbose" ]]; then
        print -r -- "[ok] macOS $VOLEQ_MACOS_VERSION"
        print -r -- "[ok] Developer tools: $VOLEQ_DEVELOPER_DIRECTORY"
        print -r -- "[ok] macOS SDK: $VOLEQ_MACOS_SDK_PATH"
        print -r -- "[ok] Swift $VOLEQ_SWIFT_VERSION: $VOLEQ_SWIFT_BINARY"
        print -r -- "Environment is ready."
    fi
}
