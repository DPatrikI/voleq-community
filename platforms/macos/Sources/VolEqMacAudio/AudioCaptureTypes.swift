// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation

public struct AudioProcess: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let pid: pid_t
    public let name: String
    public let bundleID: String

    public var label: String {
        bundleID.isEmpty ? name : "\(name) — \(bundleID)"
    }
}

public enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case application = "Application"
    case system = "Device-wide"

    public var id: Self { self }
}

public enum CaptureRuntimeState: Equatable, Sendable {
    case stopped
    case ready
    case preparing
    case active
    case recovering
    case failed
}

public enum AudioCaptureActivity: Equatable, Sendable {
    case stopped
    case ready
    case preparing
    case active
    case suspended
    case recovering
    case recoveryFailed
    case failed
}

public struct AudioCaptureStateSnapshot: Equatable, Sendable {
    public let activity: AudioCaptureActivity
    public let systemAudioAccessState: SystemAudioAccessState
    public let status: String
    public let acceptsPrimaryAction: Bool

    public var isRunning: Bool { activity == .active }

    public var runtimeState: CaptureRuntimeState {
        switch activity {
        case .stopped: .stopped
        case .ready: .ready
        case .preparing: .preparing
        case .active: .active
        case .suspended, .recovering: .recovering
        case .recoveryFailed, .failed: .failed
        }
    }

    init(
        activity: AudioCaptureActivity,
        systemAudioAccessState: SystemAudioAccessState,
        status: String,
        acceptsPrimaryAction: Bool = true
    ) {
        self.activity = activity
        self.systemAudioAccessState = systemAudioAccessState
        self.status = status
        self.acceptsPrimaryAction = acceptsPrimaryAction
    }

    init(
        runtimeState: CaptureRuntimeState,
        systemAudioAccessState: SystemAudioAccessState,
        status: String,
        acceptsPrimaryAction: Bool = true
    ) {
        self.init(
            activity: AudioCaptureActivity(runtimeState),
            systemAudioAccessState: systemAudioAccessState,
            status: status,
            acceptsPrimaryAction: acceptsPrimaryAction
        )
    }
}

private extension AudioCaptureActivity {
    init(_ runtimeState: CaptureRuntimeState) {
        switch runtimeState {
        case .stopped: self = .stopped
        case .ready: self = .ready
        case .preparing: self = .preparing
        case .active: self = .active
        case .recovering: self = .recovering
        case .failed: self = .failed
        }
    }
}
