// SPDX-License-Identifier: MPL-2.0

import Foundation

protocol AudioCallbackHealthMonitorBuilding: Sendable {
    @MainActor func makeMonitor() -> any AudioCallbackHealthMonitoring
}

struct LiveAudioCallbackHealthMonitorBuilder: AudioCallbackHealthMonitorBuilding {
    let clock: any AudioLifecycleClock
    let scheduler: any AudioLifecycleScheduling

    @MainActor
    func makeMonitor() -> any AudioCallbackHealthMonitoring {
        AudioCallbackHealthMonitor(clock: clock, scheduler: scheduler)
    }
}

struct AudioCaptureDependencies {
    let processCatalog: any AudioProcessCatalog
    let preflight: any AudioCapturePreflighting
    let pipelineBuilder: any AudioCapturePipelineBuilding
    let routeMonitor: any AudioOutputRouteMonitoring
    let routeStabilityGate: any AudioOutputRouteStabilityChecking
    let callbackHealthMonitorBuilder: any AudioCallbackHealthMonitorBuilding
    let permissionExplanationRequest: @MainActor () async -> Bool
    let routeRecoveryDelayNanoseconds: UInt64
    let wakeRecoveryDelayNanoseconds: UInt64
    let livenessVerificationProbeBuilder:
        (any AudioLivenessVerificationProbeBuilding)?
    let livenessDiagnostics: (any AudioLivenessDiagnosticsRecording)?

    init(
        processCatalog: any AudioProcessCatalog,
        preflight: any AudioCapturePreflighting,
        pipelineBuilder: any AudioCapturePipelineBuilding,
        routeMonitor: any AudioOutputRouteMonitoring,
        routeStabilityGate: any AudioOutputRouteStabilityChecking,
        callbackHealthMonitorBuilder: any AudioCallbackHealthMonitorBuilding,
        permissionExplanationRequest: @escaping @MainActor () async -> Bool,
        routeRecoveryDelayNanoseconds: UInt64,
        wakeRecoveryDelayNanoseconds: UInt64,
        livenessVerificationProbeBuilder:
            (any AudioLivenessVerificationProbeBuilding)? = nil,
        livenessDiagnostics: (any AudioLivenessDiagnosticsRecording)? = nil
    ) {
        self.processCatalog = processCatalog
        self.preflight = preflight
        self.pipelineBuilder = pipelineBuilder
        self.routeMonitor = routeMonitor
        self.routeStabilityGate = routeStabilityGate
        self.callbackHealthMonitorBuilder = callbackHealthMonitorBuilder
        self.permissionExplanationRequest = permissionExplanationRequest
        self.routeRecoveryDelayNanoseconds = routeRecoveryDelayNanoseconds
        self.wakeRecoveryDelayNanoseconds = wakeRecoveryDelayNanoseconds
        self.livenessVerificationProbeBuilder = livenessVerificationProbeBuilder
        self.livenessDiagnostics = livenessDiagnostics
    }

    @available(macOS 14.2, *)
    @MainActor
    static func live(
        permissionExplanationRequest: @escaping @MainActor () async -> Bool,
        diagnostics: (any AudioLivenessDiagnosticsRecording)? = nil
    ) -> AudioCaptureDependencies {
        let clock = ContinuousAudioLifecycleClock()
        let scheduler = ContinuousAudioLifecycleScheduler()
        return AudioCaptureDependencies(
            processCatalog: CoreAudioProcessCatalog(),
            preflight: CoreAudioCapturePreflight(),
            pipelineBuilder: CoreAudioCapturePipelineBuilder(
                diagnostics: diagnostics
            ),
            routeMonitor: CoreAudioOutputRouteMonitor(),
            routeStabilityGate: AudioOutputRouteStabilityGate(
                observer: CoreAudioOutputRouteObserver(),
                clock: clock,
                scheduler: scheduler,
                observationIntervalNanoseconds: 250_000_000,
                timeoutNanoseconds: 10_000_000_000
            ),
            callbackHealthMonitorBuilder: LiveAudioCallbackHealthMonitorBuilder(
                clock: clock,
                scheduler: scheduler
            ),
            permissionExplanationRequest: permissionExplanationRequest,
            routeRecoveryDelayNanoseconds: 350_000_000,
            wakeRecoveryDelayNanoseconds: 1_000_000_000,
            livenessVerificationProbeBuilder: diagnostics == nil
                ? nil
                : CoreAudioLivenessVerificationProbeBuilder(),
            livenessDiagnostics: diagnostics
        )
    }
}
