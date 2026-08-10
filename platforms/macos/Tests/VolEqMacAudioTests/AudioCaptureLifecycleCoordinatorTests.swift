// SPDX-License-Identifier: MPL-2.0

import VolEqCore
import XCTest
@testable import VolEqMacAudio

@MainActor
private final class SuspendedRouteMonitorOperation {
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

@available(macOS 14.2, *)
@MainActor
final class AudioCaptureLifecycleCoordinatorTests: XCTestCase {
    func testCancelledInitialRouteInstallCannotPublishSuccessOrFailure() async throws {
        for shouldFail in [false, true] {
            let operation = SuspendedRouteMonitorOperation()
            let bootstrap = AudioRouteMonitorBootstrapCoordinator()
            var successes = 0
            var failures = 0
            bootstrap.start {
                await operation.wait()
                if shouldFail { throw AudioCaptureTestError.unavailable }
            } onSuccess: {
                successes += 1
            } onFailure: { _ in
                failures += 1
            }
            try await waitForAudioCondition("initial route install") {
                operation.requestCount == 1
            }

            bootstrap.cancel()
            operation.release()
            for _ in 0..<20 { await Task.yield() }

            XCTAssertEqual(successes, 0)
            XCTAssertEqual(failures, 0)
            XCTAssertFalse(bootstrap.isRunning)
        }
    }

    func testPipelineWaitsForAsynchronousRouteMonitorInstallation() async throws {
        let rig = AudioCaptureTestRig()
        let installation = SuspendedRouteMonitorOperation()
        rig.routeMonitor.startWait = { await installation.wait() }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .preparing)
        try await waitForAudioCondition("route-monitor installation") {
            installation.requestCount == 1
        }

        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)

        installation.release()
        await waitForRuntimeState(controller, .active)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }

    func testTerminationWaitsForAsynchronousRouteMonitorRemoval() async throws {
        let rig = AudioCaptureTestRig()
        let removal = SuspendedRouteMonitorOperation()
        let controller = rig.makeController()
        try await waitForAudioCondition("initial route monitoring") {
            rig.routeMonitor.isMonitoring
        }
        rig.routeMonitor.stopWait = { await removal.wait() }
        var didFinish = false

        let termination = Task {
            await controller.prepareForApplicationTermination()
            didFinish = true
        }
        try await waitForAudioCondition("route-monitor removal") {
            removal.requestCount == 1
        }
        XCTAssertFalse(didFinish)

        removal.release()
        await termination.value
        XCTAssertTrue(didFinish)
        XCTAssertFalse(rig.routeMonitor.isMonitoring)
    }

    func testSystemStartDoesNotDependOnApplicationProcessEnumeration() async {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system
        rig.processCatalog.result = .failure(AudioCaptureTestError.unavailable)

        controller.start()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }

    func testApplicationStartWithoutExplicitTargetCreatesNoAudioResources() async {
        let rig = AudioCaptureTestRig()
        let observer = TestLifecycleObserver()
        let coordinator = AudioCaptureLifecycleCoordinator(
            dependencies: rig.makeDependencies()
        )
        coordinator.observer = observer
        coordinator.publishCurrentState()
        await waitForSnapshot(observer, state: .ready)
        let missingTargetIntent = CaptureIntent(
            mode: .application,
            speechAwarenessEnabled: false,
            levelingSettings: LevelingSettings(),
            application: nil
        )

        coordinator.start(intent: missingTargetIntent)
        await Task.yield()

        XCTAssertNil(observer.selectedProcessID)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
        XCTAssertTrue(observer.snapshots.last?.status.contains("Select the application") == true)
    }

    func testRouteMonitoringFailureSurvivesRefreshAndBlocksAllAudioWork() async throws {
        let rig = AudioCaptureTestRig()
        rig.routeMonitor.startError = AudioCaptureTestError.unavailable
        let controller = rig.makeController()
        controller.mode = .system
        await waitForRuntimeState(controller, .failed)

        controller.refreshProcesses()
        XCTAssertEqual(controller.runtimeState, .failed)

        controller.start()
        try await waitForAudioCondition("route-monitor retry") {
            rig.routeMonitor.startCount == 2
        }
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
        XCTAssertEqual(rig.routeMonitor.startCount, 2)

        rig.routeMonitor.startError = nil
        controller.start()
        await waitForRuntimeState(controller, .active)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }
    func testStartWhileSuspendedCannotBypassWakeRecoveryGate() async {
        let (coordinator, observer, rig, intent) = makeSystemRig()
        coordinator.start(intent: intent)
        await waitForSnapshot(observer, state: .active)
        coordinator.prepareForSystemSleep(fallbackIntent: nil)

        coordinator.start(intent: intent)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(observer.snapshots.last?.activity, .suspended)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
        XCTAssertEqual(rig.routeGate.initialDelays.count, 0)
    }

    func testStartWhileRecoveryFailedCannotBypassRetryRecoveryGate() async {
        let (coordinator, observer, rig, intent) = makeSystemRig()
        coordinator.start(intent: intent)
        await waitForSnapshot(observer, state: .active)
        rig.routeGate.result = .failure(AudioCaptureTestError.unavailable)
        rig.pipelines.triggerRouteChange()
        await waitForSnapshot(observer, state: .recoveryFailed)

        coordinator.start(intent: intent)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(observer.snapshots.last?.activity, .recoveryFailed)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
        XCTAssertEqual(rig.routeGate.initialDelays.count, 1)
    }

    func testStaleRouteCallbackFromReplacedPipelineCannotInvalidateReplacement() async {
        let (coordinator, observer, rig, intent) = makeSystemRig()
        coordinator.start(intent: intent)
        await waitForSnapshot(observer, state: .active)
        rig.pipelines.triggerRouteChange(for: 0)
        await waitForPipelineCount(rig, count: 2)
        await waitForSnapshot(observer, state: .active)

        rig.pipelines.triggerRouteChange(for: 0)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(observer.snapshots.last?.runtimeState, .active)
        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
        XCTAssertEqual(rig.pipelines.pipelines[1].stopCount, 0)
        XCTAssertEqual(rig.routeGate.initialDelays.count, 1)
    }

    func testRefreshFailureWhileActivePreservesGraphAndLifecycle() async {
        let (coordinator, observer, rig, intent) = makeSystemRig()
        coordinator.start(intent: intent)
        await waitForSnapshot(observer, state: .active)
        rig.processCatalog.result = .failure(AudioCaptureTestError.unavailable)

        coordinator.refreshProcesses(currentSelection: nil, mode: .system)

        XCTAssertEqual(observer.snapshots.last?.runtimeState, .active)
        XCTAssertTrue(observer.snapshots.last?.isRunning ?? false)
        XCTAssertEqual(rig.pipelines.pipelines[0].stopCount, 0)

        rig.processCatalog.result = .success([])
        coordinator.refreshProcesses(currentSelection: nil, mode: .system)

        XCTAssertEqual(observer.snapshots.last?.runtimeState, .active)
        XCTAssertTrue(observer.snapshots.last?.isRunning ?? false)
        XCTAssertEqual(rig.pipelines.pipelines[0].stopCount, 0)
    }

    func testWakeFromIdleIsAnIllegalTransitionAndCreatesNoPipeline() async {
        let rig = AudioCaptureTestRig()
        let observer = TestLifecycleObserver()
        let coordinator = AudioCaptureLifecycleCoordinator(
            dependencies: rig.makeDependencies()
        )
        coordinator.observer = observer
        coordinator.publishCurrentState()
        await waitForSnapshot(observer, state: .ready)

        coordinator.resumeAfterSystemWake()
        await Task.yield()

        XCTAssertEqual(observer.snapshots.last?.runtimeState, .ready)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
    }

    func testPublishedSnapshotsNeverClaimRunningOutsideActivePhase() async {
        let rig = AudioCaptureTestRig()
        let observer = TestLifecycleObserver()
        let coordinator = AudioCaptureLifecycleCoordinator(
            dependencies: rig.makeDependencies()
        )
        coordinator.observer = observer
        let intent = CaptureIntent(
            mode: .system,
            speechAwarenessEnabled: false,
            levelingSettings: LevelingSettings(),
            application: nil
        )

        coordinator.start(intent: intent)
        await waitForSnapshot(observer, state: .active)
        coordinator.prepareForSystemSleep(fallbackIntent: nil)

        XCTAssertTrue(observer.snapshots.contains(where: { $0.isRunning }))
        for snapshot in observer.snapshots where snapshot.isRunning {
            guard case .active = snapshot.phase else {
                return XCTFail("Only the active phase may derive isRunning")
            }
            XCTAssertEqual(snapshot.runtimeState, .active)
        }
        XCTAssertEqual(observer.snapshots.last?.activity, .suspended)
        XCTAssertFalse(observer.snapshots.last?.isRunning ?? true)
    }

    private func waitForSnapshot(
        _ observer: TestLifecycleObserver,
        state: AudioCaptureActivity
    ) async {
        for _ in 0..<2_000 {
            if observer.snapshots.last?.activity == state { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for coordinator state \(state)")
    }

    private func waitForPipelineCount(
        _ rig: AudioCaptureTestRig,
        count: Int
    ) async {
        for _ in 0..<2_000 {
            if rig.pipelines.pipelines.count == count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(count) pipelines")
    }

    private func makeSystemRig() -> (
        AudioCaptureLifecycleCoordinator,
        TestLifecycleObserver,
        AudioCaptureTestRig,
        CaptureIntent
    ) {
        let rig = AudioCaptureTestRig()
        let observer = TestLifecycleObserver()
        let coordinator = AudioCaptureLifecycleCoordinator(
            dependencies: rig.makeDependencies()
        )
        coordinator.observer = observer
        coordinator.publishCurrentState()
        let intent = CaptureIntent(
            mode: .system,
            speechAwarenessEnabled: false,
            levelingSettings: LevelingSettings(),
            application: nil
        )
        return (coordinator, observer, rig, intent)
    }
}
