// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VolEqMacAudio

private final class AdvancingAudioLifecycleTime:
    AudioLifecycleClock,
    AudioLifecycleScheduling,
    @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    private(set) var sleeps: [UInt64] = []

    func nowNanoseconds() -> UInt64 { lock.withLock { now } }

    func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        lock.withLock {
            now += nanoseconds
            sleeps.append(nanoseconds)
        }
        await Task.yield()
    }

    func advance(nanoseconds: UInt64) {
        lock.withLock { now += nanoseconds }
    }
}

private struct SuspendedAudioLifecycleScheduler: AudioLifecycleScheduling {
    func sleep(nanoseconds: UInt64) async throws {
        // `UInt64.max` is not a portable "sleep forever" value: older Swift
        // runtimes can reject it immediately instead of suspending. This
        // deadline is deliberately much longer than the focused test and is
        // cancelled as soon as the immediate observation completes.
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

@MainActor
private final class SuspendedInitialProgress {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SuspendedRouteComparison {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    func wait() async {
        requestCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SuspendedRouteReadiness {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    func wait() async {
        requestCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SequenceRouteObserver: AudioOutputRouteObserving, @unchecked Sendable {
    var results: [Result<AudioOutputRouteObservation, Error>]
    private(set) var observationCount = 0

    init(_ results: [Result<AudioOutputRouteObservation, Error>]) {
        self.results = results
    }

    func observe() async throws -> AudioOutputRouteObservation {
        observationCount += 1
        guard !results.isEmpty else { throw AudioCaptureTestError.unavailable }
        return try results.removeFirst().get()
    }
}

private final class SlowRouteObserver: AudioOutputRouteObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let time: AdvancingAudioLifecycleTime
    private let route: AudioOutputRouteObservation
    private let duration: UInt64
    private var storedObservationCount = 0
    var observationCount: Int { lock.withLock { storedObservationCount } }

    init(
        time: AdvancingAudioLifecycleTime,
        route: AudioOutputRouteObservation,
        duration: UInt64
    ) {
        self.time = time
        self.route = route
        self.duration = duration
    }

    func observe() async throws -> AudioOutputRouteObservation {
        lock.withLock { storedObservationCount += 1 }
        time.advance(nanoseconds: duration)
        return route
    }
}

private final class CancellationAwareSuspendedRouteObserver:
    AudioOutputRouteObserving,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedObservationCount = 0
    var observationCount: Int { lock.withLock { storedObservationCount } }

    func observe() async throws -> AudioOutputRouteObservation {
        lock.withLock { storedObservationCount += 1 }
        while !Task.isCancelled { await Task.yield() }
        throw CancellationError()
    }
}

@available(macOS 14.2, *)
@MainActor
final class AudioLifecycleRouteRecoveryTests: XCTestCase {
    private let route = AudioOutputRouteObservation(
        deviceID: 9,
        uid: "route",
        sampleRate: 48_000,
        channelCount: 2
    )

    func testUnchangedRouteNotificationDuringExplanationIsIgnored() async throws {
        let rig = AudioCaptureTestRig()
        let explanation = SuspendedPermissionExplanation()
        rig.permissionExplanation = { await explanation.request() }
        rig.routeGate.routeHasChanged = false
        let controller = rig.makeController()
        controller.mode = .system

        controller.start()
        try await waitForAudioCondition("permission explanation request") {
            explanation.requestCount == 1
        }
        rig.routeMonitor.triggerChange()
        await Task.yield()

        XCTAssertEqual(explanation.requestCount, 1)
        XCTAssertEqual(rig.routeGate.routeChangeCheckCount, 0)
        XCTAssertTrue(rig.routeGate.initialDelays.isEmpty)

        explanation.respond(continued: true)
        await waitForRuntimeState(controller, .active)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }

    func testUnchangedRouteNotificationDuringPipelinePreparationIsIgnored() async throws {
        let rig = AudioCaptureTestRig()
        let progress = SuspendedInitialProgress()
        rig.healthMonitors.configure = { monitor in
            monitor.initialProgressWait = {
                await progress.wait()
            }
        }
        rig.routeGate.routeHasChanged = false
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .preparing)
        try await waitForAudioCondition("callback startup gate") {
            !rig.healthMonitors.monitors.isEmpty
        }

        let priorChecks = rig.routeGate.routeChangeCheckCount
        rig.routeMonitor.triggerChange()
        try await waitForAudioCondition("route comparison during preparation") {
            rig.routeGate.routeChangeCheckCount > priorChecks
        }

        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
        XCTAssertEqual(rig.pipelines.pipelines[0].stopCount, 0)
        XCTAssertTrue(rig.routeGate.initialDelays.isEmpty)
        progress.release()
        await waitForRuntimeState(controller, .active)
    }


    func testRouteNotificationStopsOldGraphAndRevalidatesBeforeReplacement() async throws {
        let rig = AudioCaptureTestRig()
        rig.routeRecoveryDelayNanoseconds = 350_000_000
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)
        guard let first = rig.pipelines.pipelines.first else {
            return XCTFail("Expected the initial pipeline")
        }

        rig.pipelines.triggerRouteChange()
        try await waitForAudioCondition("route replacement pipeline") {
            rig.pipelines.pipelines.count == 2
        }

        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(rig.routeGate.initialDelays, [350_000_000])
        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
    }

    func testRouteRecoveryContinuesWhenOnlyOldGenerationListenersRemain() async throws {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)
        let first = try XCTUnwrap(rig.pipelines.pipelines.first)
        first.teardownReport = AudioCaptureTeardownReport(
            unresolvedSteps: [.activeOutputListeners]
        )

        rig.pipelines.triggerRouteChange()
        try await waitForAudioCondition("listener-quarantined replacement") {
            rig.pipelines.pipelines.count == 2
                && controller.runtimeState == .active
        }

        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(controller.runtimeState, .active)
        XCTAssertNotEqual(
            controller.systemAudioAccessState,
            .actionRequired(.cleanupFailed)
        )
    }

    func testRouteRecoveryUsesSettingsChangedAfterActivation() async throws {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        var liveSettings = controller.levelingSettings
        liveSettings.limiterDB = -7
        controller.levelingSettings = liveSettings
        rig.pipelines.triggerRouteChange()

        try await waitForAudioCondition("route replacement with live settings") {
            rig.pipelines.requests.count == 2
                && controller.captureState.activity == .active
        }
        XCTAssertEqual(
            rig.pipelines.requests.last?.intent.levelingSettings.limiterDB,
            -7
        )
        XCTAssertEqual(controller.levelingSettings.limiterDB, -7)
    }

    func testSettingsChangedDuringBlockedRouteReadinessReachReplacement() async throws {
        let rig = AudioCaptureTestRig()
        let readiness = SuspendedRouteReadiness()
        defer { readiness.release() }
        rig.routeGate.wait = { await readiness.wait() }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        rig.pipelines.triggerRouteChange()
        try await waitForAudioCondition("blocked route readiness") {
            readiness.requestCount == 1
        }
        var settings = controller.levelingSettings
        settings.limiterDB = -9
        controller.levelingSettings = settings
        readiness.release()

        try await waitForAudioCondition("route replacement with latest settings") {
            rig.pipelines.requests.count == 2
                && controller.captureState.activity == .active
        }
        XCTAssertEqual(
            rig.pipelines.requests.last?.intent.levelingSettings.limiterDB,
            -9
        )
        XCTAssertEqual(controller.levelingSettings.limiterDB, -9)
    }

    func testSystemRecoveryDoesNotDependOnApplicationProcessEnumeration() async throws {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)
        rig.processCatalog.result = .failure(AudioCaptureTestError.unavailable)

        rig.pipelines.triggerRouteChange()
        try await waitForAudioCondition("system route replacement") {
            rig.pipelines.pipelines.count == 2
        }

        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
    }

    func testRouteNotificationDuringWakeDoesNotResetWakeDelay() async {
        let rig = AudioCaptureTestRig()
        rig.wakeRecoveryDelayNanoseconds = 1_000_000_000
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)
        controller.prepareForSystemSleep()

        controller.resumeAfterSystemWake()
        rig.routeMonitor.triggerChange()
        rig.pipelines.triggerRouteChange(for: 0)
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(rig.routeGate.initialDelays, [1_000_000_000])
        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
    }

    func testDuplicateRouteNotificationsCannotCreateCompetingPipelines() async throws {
        let rig = AudioCaptureTestRig()
        rig.routeGate.wait = {
            for _ in 0..<20 { await Task.yield() }
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        rig.pipelines.triggerRouteChange()
        rig.pipelines.triggerRouteChange(for: 0)
        rig.pipelines.triggerRouteChange(for: 0)
        try await waitForAudioCondition("coalesced route replacement") {
            rig.pipelines.pipelines.count == 2
                && rig.routeGate.initialDelays.count == 1
        }

        XCTAssertEqual(rig.routeGate.initialDelays.count, 1)
        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
    }

    func testDelayedDuplicateAfterReplacementDoesNotStartAnotherRecovery() async throws {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)
        rig.pipelines.triggerRouteChange()
        try await waitForAudioCondition("first route replacement") {
            rig.pipelines.pipelines.count == 2
        }
        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
        rig.routeGate.routeHasChanged = false

        let priorChecks = rig.routeGate.routeChangeCheckCount
        rig.pipelines.triggerRouteChange(for: 1)
        try await waitForAudioCondition("delayed duplicate route comparison") {
            rig.routeGate.routeChangeCheckCount > priorChecks
        }

        XCTAssertEqual(controller.runtimeState, .active)
        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
    }

    func testUnchangedRouteNotificationStormQueuesOnlyOneFollowUpComparison() async throws {
        let rig = AudioCaptureTestRig()
        let comparison = SuspendedRouteComparison()
        rig.routeGate.routeChangeCheck = {
            if comparison.requestCount == 0 { await comparison.wait() }
            return false
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        for _ in 0..<100 { rig.routeMonitor.triggerChange() }
        try await waitForAudioCondition("first storm comparison") {
            comparison.requestCount == 1
        }
        XCTAssertEqual(rig.routeGate.routeChangeCheckCount, 1)

        comparison.release()
        try await waitForAudioCondition("single storm recheck") {
            rig.routeGate.routeChangeCheckCount == 2
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(rig.routeGate.routeChangeCheckCount, 2)
        XCTAssertEqual(controller.runtimeState, .active)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }

    func testPermanentRouteFailureProducesOneBoundedRecoveryFailure() async {
        let rig = AudioCaptureTestRig()
        rig.routeGate.result = .failure(RecoveryFailure.routeUnavailable)
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        rig.pipelines.triggerRouteChange()
        await waitForRuntimeState(controller, .failed)
        rig.pipelines.triggerRouteChange(for: 0)
        await Task.yield()

        XCTAssertEqual(rig.routeGate.initialDelays.count, 1)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
        XCTAssertTrue(controller.status.contains("Leveling Did Not Resume"))
    }

    func testStabilityGateRequiresTwoMatchingObservations() async throws {
        let observer = SequenceRouteObserver([
            .failure(AudioCaptureTestError.unavailable),
            .success(route),
            .success(route),
        ])
        let time = AdvancingAudioLifecycleTime()
        let gate = AudioOutputRouteStabilityGate(
            observer: observer,
            clock: time,
            scheduler: time,
            observationTimeoutScheduler: SuspendedAudioLifecycleScheduler(),
            observationIntervalNanoseconds: 250,
            timeoutNanoseconds: 1_000
        )

        let result = try await gate.waitUntilStable(
            initialDelayNanoseconds: 1_000,
            isCurrent: { true }
        )

        XCTAssertEqual(result, route)
        XCTAssertEqual(observer.observationCount, 3)
        XCTAssertEqual(time.sleeps.first, 1_000)
    }

    func testBlockedRouteObservationDoesNotBlockMainActor() async throws {
        let release = DispatchSemaphore(value: 0)
        let entered = AudioTestFlag()
        let expectedRoute = route
        let observer = CoreAudioOutputRouteObserver(operations: .init(
            observe: {
                entered.set()
                release.wait()
                return expectedRoute
            }
        ))

        let observation = Task { try await observer.observe() }
        try await waitForAudioCondition("background route observation") {
            entered.value
        }
        let mainActorProgressed = await MainActor.run { true }
        XCTAssertTrue(mainActorProgressed)

        release.signal()
        let observedRoute = try await observation.value
        XCTAssertEqual(observedRoute, expectedRoute)
    }

    func testStabilityGateNeverSleepsPastDeadline() async {
        let observer = SequenceRouteObserver([
            .failure(AudioCaptureTestError.unavailable),
            .failure(AudioCaptureTestError.unavailable),
            .failure(AudioCaptureTestError.unavailable),
        ])
        let time = AdvancingAudioLifecycleTime()
        let gate = AudioOutputRouteStabilityGate(
            observer: observer,
            clock: time,
            scheduler: time,
            observationTimeoutScheduler: SuspendedAudioLifecycleScheduler(),
            observationIntervalNanoseconds: 250,
            timeoutNanoseconds: 500
        )

        do {
            _ = try await gate.waitUntilStable(
                initialDelayNanoseconds: 1_000,
                isCurrent: { true }
            )
            XCTFail("Expected bounded route failure")
        } catch {
            XCTAssertEqual(time.sleeps, [1_000, 250, 250])
        }
    }

    func testSlowObservationCannotCompleteBeyondStabilityDeadline() async {
        let time = AdvancingAudioLifecycleTime()
        let observer = SlowRouteObserver(
            time: time,
            route: route,
            duration: 600
        )
        let gate = AudioOutputRouteStabilityGate(
            observer: observer,
            clock: time,
            scheduler: time,
            observationTimeoutScheduler: SuspendedAudioLifecycleScheduler(),
            observationIntervalNanoseconds: 250,
            timeoutNanoseconds: 500
        )

        do {
            _ = try await gate.waitUntilStable(
                initialDelayNanoseconds: 0,
                isCurrent: { true }
            )
            XCTFail("Expected the slow observation to miss the deadline")
        } catch {
            XCTAssertEqual(observer.observationCount, 1)
            XCTAssertEqual(time.sleeps, [0])
        }
    }

    func testHungObservationIsCancelledAtStabilityDeadline() async {
        let time = AdvancingAudioLifecycleTime()
        let observer = CancellationAwareSuspendedRouteObserver()
        let gate = AudioOutputRouteStabilityGate(
            observer: observer,
            clock: time,
            scheduler: time,
            observationTimeoutScheduler: time,
            observationIntervalNanoseconds: 250,
            timeoutNanoseconds: 500
        )

        do {
            _ = try await gate.waitUntilStable(
                initialDelayNanoseconds: 0,
                isCurrent: { true }
            )
            XCTFail("Expected the hung observation to time out")
        } catch {
            XCTAssertEqual(observer.observationCount, 1)
            XCTAssertEqual(time.sleeps, [0, 500])
            XCTAssertEqual(time.nowNanoseconds(), 500)
        }
    }

    func testRefreshPreservesGenericRecoveryFailureAndRetryAction() async {
        let rig = AudioCaptureTestRig()
        rig.routeGate.result = .failure(RecoveryFailure.routeUnavailable)
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)
        rig.pipelines.triggerRouteChange()
        await waitForRuntimeState(controller, .failed)
        let status = controller.status

        controller.refreshProcesses()

        XCTAssertEqual(controller.captureState.activity, .recoveryFailed)
        XCTAssertEqual(controller.status, status)
    }
}
