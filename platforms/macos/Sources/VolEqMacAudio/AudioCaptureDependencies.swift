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

    @available(macOS 14.2, *)
    @MainActor
    static func live(
        permissionExplanationRequest: @escaping @MainActor () async -> Bool
    ) -> AudioCaptureDependencies {
        let clock = ContinuousAudioLifecycleClock()
        let scheduler = ContinuousAudioLifecycleScheduler()
        return AudioCaptureDependencies(
            processCatalog: CoreAudioProcessCatalog(),
            preflight: CoreAudioCapturePreflight(),
            pipelineBuilder: CoreAudioCapturePipelineBuilder(),
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
            wakeRecoveryDelayNanoseconds: 1_000_000_000
        )
    }
}
