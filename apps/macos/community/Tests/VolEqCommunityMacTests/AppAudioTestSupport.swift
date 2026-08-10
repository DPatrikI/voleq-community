// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation
import VolEqCore
@testable import VolEqMacAudio

final class AppAudioTestPipeline: AudioCapturePipeline, @unchecked Sendable {
    private let lock = NSLock()
    let heartbeat: AudioCallbackHeartbeat
    var processor: AudioIOProcessor? { nil }
    var runningStatusSuffix: String { "" }
    var stopCount: Int { lock.withLock { storedStopCount } }
    private var storedStopCount = 0

    init() throws { heartbeat = try AudioCallbackHeartbeat() }
    func start() throws -> UInt64 {
        let count = heartbeat.callbackCount
        heartbeat.recordCallback()
        return count
    }
    func stop() -> AudioCaptureTeardownReport {
        lock.withLock { storedStopCount += 1 }
        return .complete
    }
    func updateSettings(_ settings: LevelingSettings) { }
}

@MainActor
final class AppAudioTestRig {
    var blocksRouteRecovery = false
    private let pipelineStore = AppAudioTestPipelineStore()
    var pipelines: [AppAudioTestPipeline] { pipelineStore.pipelines }

    @available(macOS 14.2, *)
    func makeController() -> AudioCaptureController {
        AudioCaptureController(
            dependencies: AudioCaptureDependencies(
                processCatalog: AppTestProcessCatalog(),
                preflight: AppTestPreflight(),
                pipelineBuilder: AppTestPipelineBuilder(store: pipelineStore),
                routeMonitor: AppTestRouteMonitor(),
                routeStabilityGate: AppTestRouteGate(rig: self),
                callbackHealthMonitorBuilder: AppTestHealthBuilder(),
                permissionExplanationRequest: { true },
                routeRecoveryDelayNanoseconds: 0,
                wakeRecoveryDelayNanoseconds: 0
            )
        )
    }
}

private final class AppAudioTestPipelineStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPipelines: [AppAudioTestPipeline] = []

    var pipelines: [AppAudioTestPipeline] {
        lock.withLock { storedPipelines }
    }

    func append(_ pipeline: AppAudioTestPipeline) {
        lock.withLock { storedPipelines.append(pipeline) }
    }
}

private struct AppTestProcessCatalog: AudioProcessCatalog {
    func activeOutputProcesses() async throws -> [AudioProcess] { [] }
}

private struct AppTestPreflight: AudioCapturePreflighting {
    func prepare(
        resolvedIntent: ResolvedCaptureIntent
    ) throws -> PreparedCaptureRequest {
        let intent = resolvedIntent.intent
        return PreparedCaptureRequest(
            speechModel: nil,
            outputDeviceID: 1,
            outputDeviceUID: "test",
            outputFormat: AudioStreamBasicDescription(),
            captureTarget: .deviceWide,
            intent: intent
        )
    }
}

private struct AppTestPipelineBuilder: AudioCapturePipelineBuilding {
    let store: AppAudioTestPipelineStore
    func build(
        request: PreparedCaptureRequest,
        onRouteChange: @escaping @MainActor @Sendable () -> Void
    ) throws -> any AudioCapturePipeline {
        let pipeline = try AppAudioTestPipeline()
        store.append(pipeline)
        return pipeline
    }
}

@MainActor
private final class AppTestRouteMonitor: AudioOutputRouteMonitoring {
    var isMonitoring: Bool { true }
    func start(onChange: @escaping @MainActor @Sendable () -> Void) throws { }
    func stop() -> AudioOutputRouteMonitorTeardownReport { .complete }
}

private struct AppTestRouteGate: AudioOutputRouteStabilityChecking {
    weak var rig: AppAudioTestRig?

    @MainActor
    func hasRouteChanged(
        since observation: AudioOutputRouteObservation
    ) async throws -> Bool {
        true
    }

    func waitUntilStable(
        initialDelayNanoseconds: UInt64,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> AudioOutputRouteObservation {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while rig?.blocksRouteRecovery == true, !Task.isCancelled {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw AppAudioTestError.routeRecoveryTimedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        return AudioOutputRouteObservation(
            deviceID: 1,
            uid: "test",
            sampleRate: 48_000,
            channelCount: 2
        )
    }
}

private struct AppTestHealthBuilder: AudioCallbackHealthMonitorBuilding {
    func makeMonitor() -> any AudioCallbackHealthMonitoring { AppTestHealthMonitor() }
}

@MainActor
private final class AppTestHealthMonitor: AudioCallbackHealthMonitoring {
    func waitForInitialProgress(
        heartbeat: AudioCallbackHeartbeat,
        initialCount: UInt64,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool { isCurrent() }
    func startWatchdog(
        heartbeat: AudioCallbackHeartbeat,
        isCurrent: @escaping @MainActor () -> Bool,
        onStall: @escaping @MainActor () -> Void
    ) { }
    func stop() { }
}

private enum AppAudioTestError: Error {
    case routeRecoveryTimedOut
}
