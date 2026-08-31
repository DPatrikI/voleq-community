// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation
import VolEqCore
import XCTest
@testable import VolEqMacAudio

enum AudioCaptureTestError: Error {
    case unavailable
    case pipelineFailure
}

final class AudioTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool { lock.withLock { storedValue } }
    func set() { lock.withLock { storedValue = true } }
}

final class TestAudioProcessCatalog: AudioProcessCatalog, @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<[AudioProcess], Error> = .success([AudioProcess(
        id: 1,
        pid: 101,
        name: "Test Audio",
        bundleID: "com.example.test-audio"
    )])
    private var storedLoadCount = 0

    var result: Result<[AudioProcess], Error> {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }
    var loadCount: Int { lock.withLock { storedLoadCount } }

    func activeOutputProcesses() async throws -> [AudioProcess] {
        try lock.withLock {
            storedLoadCount += 1
            return try storedResult.get()
        }
    }
}

final class TestCapturePreflight: AudioCapturePreflighting, @unchecked Sendable {
    private let lock = NSLock()
    var error: Error? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }
    var requests: [ResolvedCaptureIntent] { lock.withLock { storedRequests } }
    var completionCount: Int { lock.withLock { storedCompletionCount } }
    var onPrepare: (() -> Void)? {
        get { lock.withLock { storedOnPrepare } }
        set { lock.withLock { storedOnPrepare = newValue } }
    }
    private var storedError: Error?
    private var storedRequests: [ResolvedCaptureIntent] = []
    private var storedCompletionCount = 0
    private var storedOnPrepare: (() -> Void)?

    func prepare(
        resolvedIntent: ResolvedCaptureIntent
    ) throws -> PreparedCaptureRequest {
        let configuration = lock.withLock { () -> (Error?, (() -> Void)?) in
            storedRequests.append(resolvedIntent)
            return (storedError, storedOnPrepare)
        }
        configuration.1?()
        lock.withLock { storedCompletionCount += 1 }
        if let error = configuration.0 { throw error }
        let intent = resolvedIntent.intent
        let target: AudioCaptureTarget
        switch intent.mode {
        case .application:
            target = .application(intent.application?.processObjectID ?? 1)
        case .system:
            target = .deviceWide
        }
        return PreparedCaptureRequest(
            speechModel: nil,
            outputDeviceID: 1,
            outputDeviceUID: "test-output",
            outputFormat: AudioStreamBasicDescription(),
            captureTarget: target,
            intent: intent
        )
    }
}

final class TestCapturePipeline: AudioCapturePipeline, @unchecked Sendable {
    private let lock = NSLock()
    let heartbeat: AudioCallbackHeartbeat
    let processor: AudioIOProcessor?
    let playbackActivityConfiguration: AudioPlaybackActivityConfiguration?
    var runningStatusSuffix: String {
        get { lock.withLock { storedRunningStatusSuffix } }
        set { lock.withLock { storedRunningStatusSuffix = newValue } }
    }
    var startError: Error? {
        get { lock.withLock { storedStartError } }
        set { lock.withLock { storedStartError = newValue } }
    }
    var teardownReport: AudioCaptureTeardownReport {
        get { lock.withLock { storedTeardownReport } }
        set { lock.withLock { storedTeardownReport = newValue } }
    }
    var recordsCallbackOnStart: Bool {
        get { lock.withLock { storedRecordsCallbackOnStart } }
        set { lock.withLock { storedRecordsCallbackOnStart = newValue } }
    }
    var onStop: (() -> Void)? {
        get { lock.withLock { storedOnStop } }
        set { lock.withLock { storedOnStop = newValue } }
    }
    var onStart: (() -> Void)? {
        get { lock.withLock { storedOnStart } }
        set { lock.withLock { storedOnStart = newValue } }
    }
    var startCount: Int { lock.withLock { storedStartCount } }
    var stopCount: Int { lock.withLock { storedStopCount } }
    var settings: [LevelingSettings] { lock.withLock { storedSettings } }
    var livenessDrainCount: Int { lock.withLock { storedLivenessDrainCount } }
    var livenessObservation: AudioCaptureLivenessObservation? {
        get { lock.withLock { storedLivenessObservation } }
        set { lock.withLock { storedLivenessObservation = newValue } }
    }

    private var storedRunningStatusSuffix = ""
    private var storedStartError: Error?
    private var storedTeardownReport = AudioCaptureTeardownReport.complete
    private var storedRecordsCallbackOnStart = true
    private var storedOnStop: (() -> Void)?
    private var storedOnStart: (() -> Void)?
    private var storedStartCount = 0
    private var storedStopCount = 0
    private var storedSettings: [LevelingSettings] = []
    private var storedLivenessObservation: AudioCaptureLivenessObservation?
    private var storedLivenessSequence: UInt64 = 0
    private var storedLivenessDrainCount = 0

    init(
        processor: AudioIOProcessor? = nil,
        playbackActivityConfiguration:
            AudioPlaybackActivityConfiguration? = nil,
        livenessObservation: AudioCaptureLivenessObservation? = nil
    ) throws {
        heartbeat = try AudioCallbackHeartbeat()
        self.processor = processor
        self.playbackActivityConfiguration = playbackActivityConfiguration
        storedLivenessObservation = livenessObservation
    }

    func start() throws -> UInt64 {
        let initialCount = heartbeat.callbackCount
        let configuration = lock.withLock { () -> (Error?, Bool, (() -> Void)?) in
            storedStartCount += 1
            return (storedStartError, storedRecordsCallbackOnStart, storedOnStart)
        }
        configuration.2?()
        if let startError = configuration.0 { throw startError }
        if configuration.1 { heartbeat.recordCallback() }
        return initialCount
    }

    func stop() -> AudioCaptureTeardownReport {
        let result = lock.withLock { () -> (() -> Void, AudioCaptureTeardownReport) in
            storedStopCount += 1
            return (storedOnStop ?? {}, storedTeardownReport)
        }
        result.0()
        return result.1
    }

    func updateSettings(_ settings: LevelingSettings) {
        lock.withLock { storedSettings.append(settings) }
    }

    func drainLivenessObservations() -> [AudioCaptureLivenessObservation] {
        lock.withLock {
            storedLivenessDrainCount += 1
            guard let observation = storedLivenessObservation else { return [] }
            storedLivenessSequence &+= 1
            return [AudioCaptureLivenessObservation(
                callbackSequence: storedLivenessSequence,
                capturedFrameCount: observation.capturedFrameCount,
                requestedOutputFrameCount:
                    observation.requestedOutputFrameCount,
                capturedPeak: observation.capturedPeak,
                allZero: observation.allZero,
                noCapturedFrames: observation.noCapturedFrames,
                partialDelivery: observation.partialDelivery,
                nonfiniteInput: observation.nonfiniteInput,
                outputRequestActive: observation.outputRequestActive
            )]
        }
    }
}

final class TestCapturePipelineBuilder:
    AudioCapturePipelineBuilding,
    @unchecked Sendable {
    private let lock = NSLock()
    var make: () throws -> TestCapturePipeline {
        get { lock.withLock { storedMake } }
        set { lock.withLock { storedMake = newValue } }
    }
    var pipelines: [TestCapturePipeline] { lock.withLock { storedPipelines } }
    var requests: [PreparedCaptureRequest] { lock.withLock { storedRequests } }

    private var storedMake: () throws -> TestCapturePipeline = {
        try TestCapturePipeline()
    }
    private var storedPipelines: [TestCapturePipeline] = []
    private var storedRequests: [PreparedCaptureRequest] = []
    private var routeChanges: [@MainActor @Sendable () -> Void] = []

    func build(
        request: PreparedCaptureRequest,
        onRouteChange: @escaping @MainActor @Sendable () -> Void
    ) throws -> any AudioCapturePipeline {
        let make = lock.withLock { storedMake }
        let pipeline = try make()
        lock.withLock {
            storedRequests.append(request)
            storedPipelines.append(pipeline)
            routeChanges.append(onRouteChange)
        }
        return pipeline
    }

    @MainActor
    func triggerRouteChange(for index: Int? = nil) {
        let routeChange = lock.withLock { () -> (@MainActor @Sendable () -> Void)? in
            let target = index ?? max(routeChanges.count - 1, 0)
            guard routeChanges.indices.contains(target) else { return nil }
            return routeChanges[target]
        }
        routeChange?()
    }
}

@MainActor
final class TestOutputRouteMonitor: AudioOutputRouteMonitoring {
    private var onChange: (@MainActor @Sendable () -> Void)?
    private var installationTask: Task<Void, Error>?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?
    var removalStatus: OSStatus?
    var startWait: (@MainActor () async throws -> Void)?
    var stopWait: (@MainActor () async -> Void)?
    var isMonitoring: Bool { onChange != nil }

    func start(
        onChange: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        if self.onChange != nil { return }
        if let installationTask {
            try await installationTask.value
            return
        }
        startCount += 1
        let startWait = self.startWait
        let startError = self.startError
        let task = Task { @MainActor in
            try await startWait?()
            if let startError { throw startError }
            self.onChange = onChange
        }
        installationTask = task
        do {
            try await task.value
            installationTask = nil
        } catch {
            installationTask = nil
            throw error
        }
    }

    func stop() async -> AudioOutputRouteMonitorTeardownReport {
        stopCount += 1
        if let installationTask { _ = try? await installationTask.value }
        await stopWait?()
        if let removalStatus {
            return AudioOutputRouteMonitorTeardownReport(
                removalStatus: removalStatus
            )
        }
        onChange = nil
        return .complete
    }

    func triggerChange() {
        onChange?()
    }
}

@MainActor
final class TestRouteStabilityGate:
    AudioOutputRouteStabilityChecking,
    @unchecked Sendable {
    var result: Result<AudioOutputRouteObservation, Error> = .success(
        AudioOutputRouteObservation(
            deviceID: 1,
            uid: "test-output",
            sampleRate: 48_000,
            channelCount: 2
        )
    )
    var wait: (@MainActor () async throws -> Void)?
    var routeChangeCheck: (@MainActor () async throws -> Bool)?
    var routeHasChanged = true
    private(set) var initialDelays: [UInt64] = []
    private(set) var routeChangeCheckCount = 0

    func hasRouteChanged(
        since observation: AudioOutputRouteObservation
    ) async throws -> Bool {
        routeChangeCheckCount += 1
        if let routeChangeCheck { return try await routeChangeCheck() }
        return routeHasChanged
    }

    func waitUntilStable(
        initialDelayNanoseconds: UInt64,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> AudioOutputRouteObservation {
        initialDelays.append(initialDelayNanoseconds)
        try await wait?()
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        return try result.get()
    }
}

@MainActor
final class TestCallbackHealthMonitor: AudioCallbackHealthMonitoring {
    var initialProgress = true
    var initialProgressWait: (@MainActor () async -> Void)?
    private var onStall: (@MainActor () -> Void)?
    private(set) var stopCount = 0

    func waitForInitialProgress(
        heartbeat: AudioCallbackHeartbeat,
        initialCount: UInt64,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        await initialProgressWait?()
        return initialProgress && isCurrent()
    }

    func startWatchdog(
        heartbeat: AudioCallbackHeartbeat,
        isCurrent: @escaping @MainActor () -> Bool,
        onStall: @escaping @MainActor () -> Void
    ) {
        self.onStall = { if isCurrent() { onStall() } }
    }

    func stop() {
        stopCount += 1
        onStall = nil
    }

    func triggerStall() {
        onStall?()
    }
}

@MainActor
final class TestCallbackHealthMonitorBuilder:
    AudioCallbackHealthMonitorBuilding,
    @unchecked Sendable {
    var configure: (TestCallbackHealthMonitor) -> Void = { _ in }
    private(set) var monitors: [TestCallbackHealthMonitor] = []

    func makeMonitor() -> any AudioCallbackHealthMonitoring {
        let monitor = TestCallbackHealthMonitor()
        configure(monitor)
        monitors.append(monitor)
        return monitor
    }
}

@MainActor
@available(macOS 14.2, *)
final class AudioCaptureTestRig {
    let processCatalog = TestAudioProcessCatalog()
    let preflight = TestCapturePreflight()
    let pipelines = TestCapturePipelineBuilder()
    let routeMonitor = TestOutputRouteMonitor()
    let routeGate = TestRouteStabilityGate()
    let healthMonitors = TestCallbackHealthMonitorBuilder()
    var playbackActivityProbeBuilder:
        (any AudioPlaybackActivityProbeBuilding)?
    var livenessPolicy = AudioCaptureLivenessPolicy.production
    var livenessUptimeNanoseconds: @Sendable () -> UInt64 = {
        DispatchTime.now().uptimeNanoseconds
    }
    var permissionExplanation: @MainActor () async -> Bool = { true }
    var routeRecoveryDelayNanoseconds: UInt64 = 0
    var wakeRecoveryDelayNanoseconds: UInt64 = 0

    func makeDependencies() -> AudioCaptureDependencies {
        AudioCaptureDependencies(
            processCatalog: processCatalog,
            preflight: preflight,
            pipelineBuilder: pipelines,
            routeMonitor: routeMonitor,
            routeStabilityGate: routeGate,
            callbackHealthMonitorBuilder: healthMonitors,
            permissionExplanationRequest: { [weak self] in
                await self?.permissionExplanation() ?? false
            },
            routeRecoveryDelayNanoseconds: routeRecoveryDelayNanoseconds,
            wakeRecoveryDelayNanoseconds: wakeRecoveryDelayNanoseconds,
            playbackActivityProbeBuilder: playbackActivityProbeBuilder,
            livenessPolicy: livenessPolicy,
            livenessUptimeNanoseconds: livenessUptimeNanoseconds
        )
    }

    func makeController() -> AudioCaptureController {
        AudioCaptureController(dependencies: makeDependencies())
    }
}

@MainActor
final class TestLifecycleObserver: AudioCaptureLifecycleObserving {
    private(set) var snapshots: [AudioCaptureLifecycleSnapshot] = []
    private(set) var processes: [AudioProcess] = []
    private(set) var selectedProcessID: AudioObjectID?
    private(set) var restoredIntents: [CaptureIntent] = []

    func lifecycleDidPublish(_ snapshot: AudioCaptureLifecycleSnapshot) {
        snapshots.append(snapshot)
    }

    func lifecycleDidRefreshProcesses(
        _ processes: [AudioProcess],
        selectedProcessID: AudioObjectID?
    ) {
        self.processes = processes
        self.selectedProcessID = selectedProcessID
    }

    func lifecycleDidRestoreIntent(_ intent: CaptureIntent) {
        restoredIntents.append(intent)
    }
}

func audioProcess(
    id: AudioObjectID,
    pid: pid_t,
    name: String,
    bundleID: String = "com.example.meeting"
) -> AudioProcess {
    AudioProcess(id: id, pid: pid, name: name, bundleID: bundleID)
}

enum AudioLifecycleTestWaitError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case let .timedOut(description):
            "Timed out waiting for \(description)"
        }
    }
}

@MainActor
func waitForAudioCondition(
    _ description: String,
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @MainActor () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds
        .addingReportingOverflow(timeoutNanoseconds)
    while !(await condition()) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard !deadline.overflow, now < deadline.partialValue else {
            throw AudioLifecycleTestWaitError.timedOut(description)
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

@available(macOS 14.2, *)
@MainActor
func waitForRuntimeState(
    _ controller: AudioCaptureController,
    _ state: CaptureRuntimeState,
    attempts: Int = 2_000
) async {
    for _ in 0..<attempts {
        if controller.runtimeState == state { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Timed out waiting for audio runtime state \(state)")
}

@MainActor
final class SuspendedPermissionExplanation {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var requestCount = 0

    func request() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func respond(continued: Bool) {
        continuation?.resume(returning: continued)
        continuation = nil
    }
}
