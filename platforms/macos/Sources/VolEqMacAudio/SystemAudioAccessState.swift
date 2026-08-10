// SPDX-License-Identifier: MPL-2.0

public enum SystemAudioAccessIssue: Equatable, Sendable {
    case cleanupFailed
}

public enum SystemAudioAccessState: Equatable, Sendable {
    case notRequested
    case explanationRequired
    case actionRequired(SystemAudioAccessIssue)
}
