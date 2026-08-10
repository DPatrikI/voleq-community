// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import SwiftUI
import VolEqMacAudio

enum CaptureStatusTone: Equatable {
    case neutral
    case progressing
    case active
    case attention

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .progressing: .orange
        case .active: .green
        case .attention: .red
        }
    }
}

struct CapturePresentation: Equatable {
    let runtimeTitle: String
    let primaryActionTitle: String
    let compactPrimaryActionTitle: String
    let targetSummary: String
    let statusTone: CaptureStatusTone
    let controlsLocked: Bool
    let canPerformPrimaryAction: Bool
    let accessibilityText: String

    init(
        state: AudioCaptureStateSnapshot,
        mode: CaptureMode,
        selectedProcessID: AudioObjectID?,
        processes: [AudioProcess]
    ) {
        let runtimeState = state.activity
        let isRunning = state.isRunning
        let accessState = state.systemAudioAccessState
        let isStopping = runtimeState == .stopped && !state.acceptsPrimaryAction
        runtimeTitle = isStopping
            ? "Stopping"
            : Self.runtimeTitle(for: runtimeState)
        let action = isStopping
            ? (full: "Restoring Audio…", compact: "Restoring…")
            : Self.primaryAction(for: runtimeState)
        primaryActionTitle = action.full
        compactPrimaryActionTitle = action.compact
        statusTone = isStopping
            ? .progressing
            : Self.statusTone(for: runtimeState)

        let cleanupRequiresQuit = accessState == .actionRequired(.cleanupFailed)
        controlsLocked = !state.acceptsPrimaryAction
            || isRunning
            || runtimeState == .preparing
            || runtimeState == .suspended
            || runtimeState == .recovering
            || cleanupRequiresQuit

        let selectedProcess = selectedProcessID.flatMap { selectedID in
            processes.first(where: { $0.id == selectedID })
        }
        let hasCaptureTarget = mode == .system || selectedProcess != nil
        switch runtimeState {
        case .active, .preparing, .suspended, .recovering:
            canPerformPrimaryAction = state.acceptsPrimaryAction
        case .recoveryFailed, .stopped, .ready, .failed:
            canPerformPrimaryAction = state.acceptsPrimaryAction
                && !controlsLocked
                && hasCaptureTarget
        }

        switch mode {
        case .application:
            if let process = selectedProcess {
                targetSummary = isRunning ? "Leveling \(process.name)" : process.name
            } else {
                targetSummary = "Choose an audio-producing application"
            }
        case .system:
            targetSummary = isRunning
                ? "Leveling device-wide audio"
                : "Device-wide audio"
        }
        accessibilityText = "\(runtimeTitle). \(targetSummary). \(state.status)"
    }

    private static func runtimeTitle(for state: AudioCaptureActivity) -> String {
        switch state {
        case .stopped: "Stopped"
        case .ready: "Ready"
        case .preparing: "Starting"
        case .active: "Active"
        case .suspended: "Paused for System Sleep"
        case .recovering: "Restoring Leveling"
        case .recoveryFailed: "Leveling Did Not Resume"
        case .failed: "Needs attention"
        }
    }

    private static func primaryAction(
        for state: AudioCaptureActivity
    ) -> (full: String, compact: String) {
        switch state {
        case .active, .preparing, .suspended, .recovering:
            ("Stop Leveling", "Stop")
        case .recoveryFailed:
            ("Try Again", "Try Again")
        case .stopped, .ready, .failed:
            ("Start Leveling", "Start")
        }
    }

    private static func statusTone(
        for state: AudioCaptureActivity
    ) -> CaptureStatusTone {
        switch state {
        case .active: .active
        case .preparing, .suspended, .recovering: .progressing
        case .recoveryFailed, .failed: .attention
        case .stopped, .ready: .neutral
        }
    }
}
