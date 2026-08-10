// SPDX-License-Identifier: MPL-2.0

enum CaptureLifecyclePhase: Equatable, Sendable {
    case stopped
    case explanationDeclined
    case ready
    case installingRouteMonitor(CaptureIntent)
    case explaining(CaptureIntent)
    case preparing(CaptureIntent)
    case active(CaptureIntent)
    case stopping(CaptureIntent?)
    case suspending(CaptureIntent)
    case suspended(CaptureIntent)
    case recovering(CaptureIntent, AudioRecoveryReason)
    case recoveryFailed(CaptureIntent, RecoveryFailure)
    case processDiscoveryFailed(CaptureIntent?)
    case routeMonitoringFailed(CaptureIntent?)
    case failed(CaptureIntent?)
    case verifiedFailure(CaptureIntent)
    case cleanupFailed

    var runtimeState: CaptureRuntimeState {
        switch self {
        case .stopped, .explanationDeclined, .stopping: .stopped
        case .ready: .ready
        case .installingRouteMonitor, .explaining, .preparing: .preparing
        case .active: .active
        case .suspending, .suspended, .recovering: .recovering
        case .recoveryFailed: .failed
        case .processDiscoveryFailed, .routeMonitoringFailed, .failed,
             .verifiedFailure, .cleanupFailed: .failed
        }
    }

    var activity: AudioCaptureActivity {
        switch self {
        case .stopped, .explanationDeclined, .stopping: .stopped
        case .ready: .ready
        case .installingRouteMonitor, .explaining, .preparing: .preparing
        case .active: .active
        case .suspending, .suspended: .suspended
        case .recovering: .recovering
        case .recoveryFailed: .recoveryFailed
        case .processDiscoveryFailed, .routeMonitoringFailed, .failed,
             .verifiedFailure, .cleanupFailed: .failed
        }
    }

    var systemAudioAccessState: SystemAudioAccessState {
        switch self {
        case .explaining, .explanationDeclined: .explanationRequired
        case .cleanupFailed: .actionRequired(.cleanupFailed)
        case .stopped, .ready, .installingRouteMonitor,
             .preparing, .active, .verifiedFailure, .stopping,
             .suspending, .suspended,
             .recovering, .recoveryFailed, .processDiscoveryFailed,
             .routeMonitoringFailed, .failed: .notRequested
        }
    }

    var acceptsPrimaryAction: Bool {
        switch self {
        case .stopping, .cleanupFailed: false
        default: true
        }
    }
}

struct AudioCaptureLifecycleSnapshot: Equatable, Sendable {
    let phase: CaptureLifecyclePhase
    let status: String

    var runtimeState: CaptureRuntimeState { phase.runtimeState }
    var activity: AudioCaptureActivity { phase.activity }
    var systemAudioAccessState: SystemAudioAccessState {
        phase.systemAudioAccessState
    }
    var isRunning: Bool { runtimeState == .active }

    var publicState: AudioCaptureStateSnapshot {
        AudioCaptureStateSnapshot(
            activity: phase.activity,
            systemAudioAccessState: systemAudioAccessState,
            status: status,
            acceptsPrimaryAction: phase.acceptsPrimaryAction
        )
    }
}
