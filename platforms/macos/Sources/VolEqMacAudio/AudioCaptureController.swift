// SPDX-License-Identifier: MPL-2.0

import Combine
import CoreAudio
import Foundation
import VolEqCore

@MainActor
@available(macOS 14.2, *)
public final class AudioCaptureController: ObservableObject {
    @Published public var processes: [AudioProcess] = []
    @Published public var selectedProcessID: AudioObjectID?
    @Published public var mode: CaptureMode = .application
    @Published public var speechAwarenessEnabled = true
    @Published public var levelingSettings = LevelingSettings() {
        didSet { coordinator.updateSettings(levelingSettings) }
    }
    @Published public private(set) var captureState = AudioCaptureStateSnapshot(
        activity: .stopped,
        systemAudioAccessState: .notRequested,
        status: "Choose an audio-producing app, then start."
    )
    @Published public private(set) var isRunning = false
    @Published public private(set) var runtimeState: CaptureRuntimeState = .stopped
    @Published public private(set) var systemAudioAccessState: SystemAudioAccessState = .notRequested
    @Published public private(set) var status = "Choose an audio-producing app, then start."

    private let coordinator: AudioCaptureLifecycleCoordinator

    public convenience init(
        permissionExplanationRequest: @escaping @MainActor () async -> Bool = { true }
    ) {
        self.init(
            dependencies: .live(
                permissionExplanationRequest: permissionExplanationRequest
            )
        )
    }

    init(dependencies: AudioCaptureDependencies) {
        coordinator = AudioCaptureLifecycleCoordinator(
            dependencies: dependencies
        )
        coordinator.observer = self
        coordinator.publishCurrentState()
    }

    public func refreshProcesses() {
        coordinator.refreshProcesses(
            currentSelection: selectedProcessID,
            mode: mode
        )
    }

    public func toggle() {
        switch captureState.activity {
        case .active, .preparing, .suspended, .recovering:
            stop()
        case .recoveryFailed:
            retryRecovery()
        case .stopped, .ready, .failed:
            start()
        }
    }

    public func start() {
        coordinator.start(intent: captureIntent())
    }

    public func retryRecovery() {
        coordinator.retry(intent: captureIntent())
    }

    public var canRetryRecovery: Bool {
        captureState.activity == .recoveryFailed
            && (mode == .system
                || selectedProcessID.map { selectedID in
                    processes.contains(where: { $0.id == selectedID })
                } == true)
    }

    public func stop() {
        coordinator.stop()
    }

    public func stopAndWait() async {
        await coordinator.stopAndWait()
    }

    public func prepareForApplicationTermination() async {
        await coordinator.prepareForApplicationTermination()
    }

    public func prepareForSystemSleep() {
        coordinator.prepareForSystemSleep(fallbackIntent: captureIntent())
    }

    public func resumeAfterSystemWake() {
        coordinator.resumeAfterSystemWake()
    }

    private func captureIntent() -> CaptureIntent {
        let application: ApplicationCaptureIdentity?
        if mode == .application,
           let selectedProcessID,
           let process = processes.first(where: { $0.id == selectedProcessID }) {
            application = ApplicationCaptureIdentity(
                processObjectID: process.id,
                pid: process.pid,
                bundleID: process.bundleID,
                displayName: process.name
            )
        } else if mode == .application, let selectedProcessID {
            application = ApplicationCaptureIdentity(
                processObjectID: selectedProcessID,
                pid: 0,
                bundleID: "",
                displayName: "The selected application"
            )
        } else {
            application = nil
        }
        return CaptureIntent(
            mode: mode,
            speechAwarenessEnabled: speechAwarenessEnabled,
            levelingSettings: levelingSettings,
            application: application
        )
    }
}

@available(macOS 14.2, *)
extension AudioCaptureController: AudioCaptureLifecycleObserving {
    func lifecycleDidPublish(_ snapshot: AudioCaptureLifecycleSnapshot) {
        let state = snapshot.publicState
        captureState = state
        isRunning = state.isRunning
        runtimeState = state.runtimeState
        systemAudioAccessState = state.systemAudioAccessState
        status = state.status
    }

    func lifecycleDidRefreshProcesses(
        _ processes: [AudioProcess],
        selectedProcessID: AudioObjectID?
    ) {
        self.processes = processes
        self.selectedProcessID = selectedProcessID
    }

    func lifecycleDidRestoreIntent(_ intent: CaptureIntent) {
        mode = intent.mode
        speechAwarenessEnabled = intent.speechAwarenessEnabled
        levelingSettings = intent.levelingSettings
        selectedProcessID = intent.application?.processObjectID
    }
}
