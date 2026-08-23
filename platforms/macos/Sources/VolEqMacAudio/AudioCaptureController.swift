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
    private let diagnostics: (any AudioLivenessDiagnosticsRecording)?
    private var diagnosticCaptureWasStarted = false
    private var diagnosticCaptureCleanupComplete = true

    public convenience init(
        permissionExplanationRequest: @escaping @MainActor () async -> Bool = { true },
        audioLivenessDiagnostics: AudioLivenessDiagnostics? = nil
    ) {
        self.init(
            dependencies: .live(
                permissionExplanationRequest: permissionExplanationRequest,
                diagnostics: audioLivenessDiagnostics
            ),
            diagnostics: audioLivenessDiagnostics
        )
    }

    init(
        dependencies: AudioCaptureDependencies,
        diagnostics: (any AudioLivenessDiagnosticsRecording)? = nil
    ) {
        self.diagnostics = diagnostics
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

    @discardableResult
    public func verifyAndReconnectIfNeeded() -> Bool {
        coordinator.requestLivenessVerification()
    }

    @discardableResult
    public func runControlledLivenessRecoveryTest() -> Bool {
        coordinator.beginControlledLivenessFailureTest()
    }

    public func cancelControlledLivenessRecoveryTest() {
        coordinator.cancelControlledLivenessFailureTest()
    }

    @discardableResult
    public func reconnectAudio() -> Bool {
        coordinator.reconnect()
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
        diagnostics?.recordLifecycle(
            activity: Self.diagnosticLifecycleName(snapshot.phase),
            captureMode: mode.rawValue
        )
        switch snapshot.phase {
        case .preparing, .active, .stopping, .suspending, .suspended,
             .recovering:
            if !diagnosticCaptureWasStarted {
                diagnosticCaptureCleanupComplete = true
            }
            diagnosticCaptureWasStarted = true
        case .stopped where diagnosticCaptureWasStarted:
            diagnostics?.finalizeCaptureRun(
                reason: diagnosticCaptureCleanupComplete
                    ? "Audio capture stopped normally."
                    : "The audio graph stopped, but one or more diagnostic route listeners remained quarantined.",
                cleanupComplete: diagnosticCaptureCleanupComplete
            )
            diagnosticCaptureWasStarted = false
            diagnosticCaptureCleanupComplete = true
        case .cleanupFailed where diagnosticCaptureWasStarted:
            diagnostics?.finalizeCaptureRun(
                reason: "Core Audio cleanup remained incomplete; Quit is required.",
                cleanupComplete: false
            )
            diagnosticCaptureWasStarted = false
            diagnosticCaptureCleanupComplete = true
        default:
            break
        }
    }

    func lifecycleDidCompleteTeardown(_ report: AudioCaptureTeardownReport) {
        guard diagnosticCaptureWasStarted else { return }
        diagnosticCaptureCleanupComplete =
            diagnosticCaptureCleanupComplete && report.isComplete
    }

    func lifecycleDidRefreshProcesses(
        _ processes: [AudioProcess],
        selectedProcessID: AudioObjectID?
    ) {
        self.processes = processes
        self.selectedProcessID = selectedProcessID
    }

    private static func diagnosticLifecycleName(
        _ phase: CaptureLifecyclePhase
    ) -> String {
        switch phase {
        case .stopped: "stopped"
        case .explanationDeclined: "explanationDeclined"
        case .ready: "ready"
        case .installingRouteMonitor: "installingRouteMonitor"
        case .explaining: "explainingPermission"
        case .preparing: "preparing"
        case .active: "active"
        case .stopping: "stopping"
        case .suspending: "suspending"
        case .suspended: "suspended"
        case let .recovering(_, reason):
            switch reason {
            case .outputRouteChanged: "recoveringOutputRouteChange"
            case .systemWake: "recoveringSystemWake"
            case .stalledCallbacks: "recoveringCallbackStall"
            case .userRetry: "recoveringUserRetry"
            case .userReconnect: "recoveringUserReconnect"
            case .confirmedUnusableCapture: "recoveringConfirmedUnusableCapture"
            }
        case .recoveryFailed: "recoveryFailed"
        case .processDiscoveryFailed: "processDiscoveryFailed"
        case .routeMonitoringFailed: "routeMonitoringFailed"
        case .failed: "failed"
        case .verifiedFailure: "verifiedFailure"
        case .cleanupFailed: "cleanupFailed"
        }
    }

    func lifecycleDidRestoreIntent(_ intent: CaptureIntent) {
        mode = intent.mode
        speechAwarenessEnabled = intent.speechAwarenessEnabled
        levelingSettings = intent.levelingSettings
        selectedProcessID = intent.application?.processObjectID
    }
}
