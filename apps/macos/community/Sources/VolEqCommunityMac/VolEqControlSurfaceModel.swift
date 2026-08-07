// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import SwiftUI
import VolEqMacAudio

@MainActor
protocol VolEqControlSurfaceModel: ObservableObject {
    var processes: [AudioProcess] { get }
    var selectedProcessID: AudioObjectID? { get set }
    var mode: CaptureMode { get set }
    var speechAwarenessEnabled: Bool { get set }
    var isRunning: Bool { get }
    var runtimeState: CaptureRuntimeState { get }
    var systemAudioAccessState: SystemAudioAccessState { get }
    var status: String { get }

    func refreshProcesses()
    func toggle()
    func checkAudioAccessAgain()
    func cancelAudioAccessCheck()
}

@available(macOS 14.2, *)
extension AudioCaptureController: VolEqControlSurfaceModel { }

extension VolEqControlSurfaceModel {
    var canStart: Bool {
        !controlsLocked && (mode == .system || selectedProcessID != nil)
    }

    var isCheckingAudioAccess: Bool {
        systemAudioAccessState == .checking
    }

    var controlsLocked: Bool {
        isRunning
            || runtimeState == .preparing
            || runtimeState == .recovering
            || isCheckingAudioAccess
            || cleanupRequiresQuit
    }

    private var cleanupRequiresQuit: Bool {
        systemAudioAccessState == .actionRequired(.cleanupFailed)
    }

    var runtimeTitle: String {
        switch runtimeState {
        case .stopped:
            "Stopped"
        case .ready:
            "Ready"
        case .preparing:
            "Starting"
        case .checkingAccess:
            "Checking Audio Access"
        case .active:
            "Active"
        case .recovering:
            "Reconnecting"
        case .permissionRequired:
            "Audio Access Required"
        case .failed:
            "Needs attention"
        }
    }

    var targetSummary: String {
        switch mode {
        case .application:
            guard let selectedProcessID,
                  let process = processes.first(where: { $0.id == selectedProcessID })
            else {
                return "Choose an audio-producing application"
            }
            return isRunning ? "Leveling \(process.name)" : process.name
        case .system:
            return isRunning ? "Leveling device-wide audio" : "Device-wide audio"
        }
    }

    var statusColor: Color {
        switch runtimeState {
        case .active:
            .green
        case .preparing, .checkingAccess, .recovering:
            .orange
        case .permissionRequired, .failed:
            .red
        case .stopped, .ready:
            .secondary
        }
    }
}
