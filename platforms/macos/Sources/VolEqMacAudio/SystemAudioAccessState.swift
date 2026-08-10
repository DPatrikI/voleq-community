// SPDX-License-Identifier: MPL-2.0

public enum SystemAudioAccessIssue: Equatable, Sendable {
    case permissionNotGranted
    case couldNotVerify
    case malformedAudio
    case coreAudioFailure
    case cleanupFailed
}

public enum SystemAudioAccessState: Equatable, Sendable {
    case notRequested
    case explanationRequired
    case checking
    case verified
    case actionRequired(SystemAudioAccessIssue)
}
