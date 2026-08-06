#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0

voleq_invalidate_release_outputs() {
    local release_directory="${1:A}"
    local dmg="${2:A}"
    local checksums="${3:A}"
    local notarization_directory="${4:A}"

    if [[ "${dmg:h}" != "$release_directory" ]]; then
        print -u2 -- "error: release DMG must be directly inside the release directory"
        return 1
    fi
    if [[ "${checksums:h}" != "$release_directory" ]]; then
        print -u2 -- "error: checksum file must be directly inside the release directory"
        return 1
    fi
    if [[ "${notarization_directory:h}" != "$release_directory" \
        || "${notarization_directory:t}" != "notarization" ]]; then
        print -u2 -- "error: notarization evidence must use the release notarization directory"
        return 1
    fi

    mkdir -p -- "$release_directory"
    rm -f -- "$dmg" "$checksums"
    rm -rf -- "$notarization_directory"
    mkdir -p -- "$notarization_directory"
}
