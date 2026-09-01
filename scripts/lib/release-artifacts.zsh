#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0

voleq_release_dmg_filename() {
    local artifact_prefix="$1"
    local version="$2"
    local suffix="${3:-}"
    local label="$artifact_prefix-$version"

    if [[ -n "$suffix" ]]; then
        label="$label-$suffix"
    fi

    print -r -- "$label-macOS-arm64.dmg"
}

voleq_validate_publishable_release_output_paths() {
    local release_directory="${1:A}"
    local dmg="${2:A}"
    local checksums="${3:A}"

    if [[ "${dmg:h}" != "$release_directory" ]]; then
        print -u2 -- "error: release DMG must be directly inside the release directory"
        return 1
    fi
    if [[ "${checksums:h}" != "$release_directory" ]]; then
        print -u2 -- "error: checksum file must be directly inside the release directory"
        return 1
    fi
}

voleq_remove_publishable_release_outputs() {
    local release_directory="${1:A}"
    local dmg="${2:A}"
    local checksums="${3:A}"

    voleq_validate_publishable_release_output_paths \
        "$release_directory" \
        "$dmg" \
        "$checksums" \
        || return 1

    rm -f -- "$dmg" "$checksums"
}

voleq_cleanup_publishable_release_outputs_after_attempt() {
    local release_directory="$1"
    local dmg="$2"
    local checksums="$3"
    local succeeded="$4"

    case "$succeeded" in
        true)
            return 0
            ;;
        false)
            voleq_remove_publishable_release_outputs \
                "$release_directory" \
                "$dmg" \
                "$checksums"
            ;;
        *)
            print -u2 -- "error: release attempt success state must be true or false"
            return 2
            ;;
    esac
}

voleq_cleanup_release_attempt() {
    local release_directory="$1"
    local dmg="$2"
    local checksums="$3"
    local succeeded="$4"
    local work_directory="$5"
    local cleanup_failed=false

    if ! voleq_cleanup_publishable_release_outputs_after_attempt \
        "$release_directory" \
        "$dmg" \
        "$checksums" \
        "$succeeded"; then
        print -u2 -- "warning: could not remove failed publishable release outputs"
        cleanup_failed=true
    fi

    if ! rm -rf -- "$work_directory"; then
        print -u2 -- "warning: could not remove release workspace: $work_directory"
        cleanup_failed=true
    fi

    [[ "$cleanup_failed" == false ]]
}

voleq_invalidate_release_outputs() {
    local release_directory="${1:A}"
    local dmg="${2:A}"
    local checksums="${3:A}"
    local notarization_directory="${4:A}"

    voleq_validate_publishable_release_output_paths \
        "$release_directory" \
        "$dmg" \
        "$checksums" \
        || return 1
    if [[ "${notarization_directory:h}" != "$release_directory" \
        || "${notarization_directory:t}" != "notarization" ]]; then
        print -u2 -- "error: notarization evidence must use the release notarization directory"
        return 1
    fi

    mkdir -p -- "$release_directory"
    voleq_remove_publishable_release_outputs \
        "$release_directory" \
        "$dmg" \
        "$checksums" \
        || return 1
    rm -rf -- "$notarization_directory"
    mkdir -p -- "$notarization_directory"
}
