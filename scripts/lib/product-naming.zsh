#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0

typeset -gr VOLEQ_PRODUCT_NAME="VolEq"
typeset -gr VOLEQ_DEVELOPMENT_PRODUCT_NAME="VolEq Dev"
typeset -gr VOLEQ_RELEASE_APP_BUNDLE="VolEq.app"
typeset -gr VOLEQ_DEVELOPMENT_APP_BUNDLE="VolEq Dev.app"
typeset -gr VOLEQ_LEGACY_RELEASE_APP_BUNDLE="VolEq Community.app"
typeset -gr VOLEQ_LEGACY_DEVELOPMENT_APP_BUNDLE="VolEq Community Dev.app"
typeset -gr VOLEQ_EXECUTABLE_NAME="VolEqCommunityMac"
typeset -gr VOLEQ_RELEASE_BUNDLE_IDENTIFIER="com.patrikistvandoczy.voleq.community"
typeset -gr VOLEQ_DEVELOPMENT_BUNDLE_IDENTIFIER="${VOLEQ_RELEASE_BUNDLE_IDENTIFIER}.development"
typeset -gr VOLEQ_COMMUNITY_ARTIFACT_PREFIX="VolEq-Community"
typeset -gr VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC_PRODUCT_NAME="VolEq Audio Liveness Diagnostic"
typeset -gr VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC_APP_BUNDLE="VolEq Audio Liveness Diagnostic.app"
typeset -gr VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC_BUNDLE_IDENTIFIER="${VOLEQ_RELEASE_BUNDLE_IDENTIFIER}.diagnostics.audio-liveness"

voleq_validate_product_plist() {
    local info_plist="$1"
    local variant="$2"
    local expected_name expected_identifier

    case "$variant" in
        distribution)
            expected_name="$VOLEQ_PRODUCT_NAME"
            expected_identifier="$VOLEQ_RELEASE_BUNDLE_IDENTIFIER"
            ;;
        development)
            expected_name="$VOLEQ_DEVELOPMENT_PRODUCT_NAME"
            expected_identifier="$VOLEQ_DEVELOPMENT_BUNDLE_IDENTIFIER"
            ;;
        audio-liveness-diagnostic)
            expected_name="$VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC_PRODUCT_NAME"
            expected_identifier="$VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC_BUNDLE_IDENTIFIER"
            ;;
        *)
            print -u2 -- "error: unknown product variant: $variant"
            return 2
            ;;
    esac

    [[ -f "$info_plist" ]] || {
        print -u2 -- "error: missing product Info.plist: $info_plist"
        return 1
    }
    [[ "$(plutil -extract CFBundleDisplayName raw -o - "$info_plist")" == "$expected_name" ]] || {
        print -u2 -- "error: unexpected $variant display name"
        return 1
    }
    [[ "$(plutil -extract CFBundleName raw -o - "$info_plist")" == "$expected_name" ]] || {
        print -u2 -- "error: unexpected $variant bundle name"
        return 1
    }
    [[ "$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")" == "$expected_identifier" ]] || {
        print -u2 -- "error: unexpected $variant bundle identifier"
        return 1
    }
    [[ "$(plutil -extract CFBundleExecutable raw -o - "$info_plist")" == "$VOLEQ_EXECUTABLE_NAME" ]] || {
        print -u2 -- "error: unexpected $variant executable name"
        return 1
    }
}
