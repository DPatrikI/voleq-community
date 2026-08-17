// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation
import VolEqCore

struct ApplicationCaptureIdentity: Equatable, Sendable {
    let processObjectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let displayName: String
}

struct CaptureIntent: Equatable, Sendable {
    let mode: CaptureMode
    let speechAwarenessEnabled: Bool
    let levelingSettings: LevelingSettings
    let application: ApplicationCaptureIdentity?

    func replacingLevelingSettings(
        _ settings: LevelingSettings
    ) -> CaptureIntent {
        CaptureIntent(
            mode: mode,
            speechAwarenessEnabled: speechAwarenessEnabled,
            levelingSettings: settings,
            application: application
        )
    }

    func matchesOperationIdentity(of other: CaptureIntent) -> Bool {
        mode == other.mode
            && speechAwarenessEnabled == other.speechAwarenessEnabled
            && application == other.application
    }
}

enum ApplicationTargetResolution: Equatable {
    case resolved(AudioProcess)
    case missing
    case ambiguous
}

enum ResolvedCaptureTarget: Equatable, Sendable {
    case application(AudioProcess)
    case deviceWide
}

enum CaptureTargetIdentity: Equatable, Sendable {
    case application(objectID: AudioObjectID, pid: pid_t, bundleID: String)
    case deviceWide
}

extension ResolvedCaptureTarget {
    var captureIdentity: CaptureTargetIdentity {
        switch self {
        case let .application(process):
            .application(
                objectID: process.id,
                pid: process.pid,
                bundleID: process.bundleID
            )
        case .deviceWide:
            .deviceWide
        }
    }
}

struct ResolvedCaptureIntent: Equatable, Sendable {
    let intent: CaptureIntent
    let target: ResolvedCaptureTarget
}

enum AudioRecoveryReason: Equatable, Sendable {
    case outputRouteChanged
    case systemWake
    case stalledCallbacks
    case userRetry
    case userReconnect
    case confirmedUnusableCapture
}

enum RecoveryFailure: Error, Equatable, Sendable {
    case routeUnavailable
    case applicationMissing(String)
    case applicationAmbiguous(String)
    case callbacksDidNotStart
    case pipeline(String)

    var message: String {
        switch self {
        case .routeUnavailable:
            "The output route did not become stable within 10 seconds."
        case let .applicationMissing(name):
            "\(name) is no longer producing audio. Select the application again."
        case let .applicationAmbiguous(name):
            "More than one \(name) audio process is available. Select the application again."
        case .callbacksDidNotStart:
            "Audio callbacks did not begin."
        case let .pipeline(message):
            message
        }
    }
}
