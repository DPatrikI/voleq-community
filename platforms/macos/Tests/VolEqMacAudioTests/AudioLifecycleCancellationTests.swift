// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import XCTest
import VolEqCore
@testable import VolEqMacAudio

private final class BlockingPipelineTeardownGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var entered = false

    var hasEntered: Bool { lock.withLock { entered } }

    func block() {
        lock.withLock { entered = true }
        releaseSemaphore.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

@available(macOS 14.2, *)
@MainActor
final class AudioLifecycleCancellationTests: XCTestCase {
    func testTeardownBeforeQueuedPipelineStartCancelsStartWithoutTouchingDestroyedGraph() async throws {
        let lifecycleQueue = DispatchQueue(label: "test.pipeline.lifecycle")
        let startQueue = DispatchQueue(label: "test.pipeline.start")
        let queuedStartGate = DispatchSemaphore(value: 0)
        startQueue.async { queuedStartGate.wait() }

        let executor = AudioCapturePipelineExecutor(
            lifecycleQueue: lifecycleQueue,
            startQueue: startQueue
        )
        let builder = TestCapturePipelineBuilder()
        let healthMonitors = TestCallbackHealthMonitorBuilder()
        let runtime = AudioCaptureRuntime(
            pipelineBuilder: builder,
            healthMonitorBuilder: healthMonitors,
            pipelineExecutor: executor
        )
        let intent = CaptureIntent(
            mode: .system,
            speechAwarenessEnabled: false,
            levelingSettings: LevelingSettings(),
            application: nil
        )
        let request = PreparedCaptureRequest(
            speechModel: nil,
            outputDeviceID: 1,
            outputDeviceUID: "test-output",
            outputFormat: AudioStreamBasicDescription(),
            captureTarget: .deviceWide,
            intent: intent
        )
        let start = Task { @MainActor in
            await runtime.start(
                request: request,
                currentSettings: { LevelingSettings() },
                isCurrent: { true },
                onRouteChange: {},
                onStall: {},
                onStatus: { _ in },
                onProcessingFailure: { _ in },
                runningStatus: "Leveling"
            )
        }
        try await waitForAudioCondition("pipeline start to be queued") {
            builder.pipelines.count == 1
        }

        let teardown = Task { @MainActor in await runtime.teardown() }
        try await waitForAudioCondition("queued-start graph teardown") {
            builder.pipelines.first?.stopCount == 1
        }
        queuedStartGate.signal()

        let teardownReport = await teardown.value
        let startResult = await start.value
        XCTAssertTrue(teardownReport.isComplete)
        XCTAssertEqual(builder.pipelines.first?.startCount, 0)
        if case .cancelled = startResult {
            // Expected: the queued call never entered the destroyed graph.
        } else {
            XCTFail("Expected queued pipeline start to be cancelled")
        }
    }

    func testBlockedPipelineStartKeepsMainActorResponsiveAndStopOwnsGraph() async throws {
        let rig = AudioCaptureTestRig()
        let startGate = BlockingPipelineTeardownGate()
        rig.pipelines.make = {
            let pipeline = try TestCapturePipeline()
            pipeline.onStart = { startGate.block() }
            pipeline.onStop = { startGate.release() }
            return pipeline
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        try await waitForAudioCondition("pipeline start to block") {
            startGate.hasEntered
        }

        controller.stop()
        XCTAssertEqual(controller.runtimeState, .stopped)
        XCTAssertFalse(controller.captureState.acceptsPrimaryAction)

        try await waitForAudioCondition("blocked start cleanup") {
            controller.captureState.acceptsPrimaryAction
        }
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
        XCTAssertEqual(rig.pipelines.pipelines[0].startCount, 1)
        XCTAssertEqual(rig.pipelines.pipelines[0].stopCount, 1)
        XCTAssertEqual(controller.runtimeState, .stopped)
    }

    func testSleepDuringBlockedPipelineStartTearsDownBeforeSuspending() async throws {
        let rig = AudioCaptureTestRig()
        let startGate = BlockingPipelineTeardownGate()
        rig.pipelines.make = {
            let pipeline = try TestCapturePipeline()
            pipeline.onStart = { startGate.block() }
            pipeline.onStop = { startGate.release() }
            return pipeline
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        try await waitForAudioCondition("pipeline start before sleep") {
            startGate.hasEntered
        }

        controller.prepareForSystemSleep()
        XCTAssertFalse(controller.captureState.isRunning)
        try await waitForAudioCondition("blocked start sleep cleanup") {
            rig.pipelines.pipelines.first?.stopCount == 1
                && controller.status.contains("has been restored")
        }

        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
        XCTAssertEqual(rig.pipelines.pipelines[0].startCount, 1)
        XCTAssertEqual(rig.pipelines.pipelines[0].stopCount, 1)
    }

    func testTerminationDuringBlockedPipelineStartWaitsForTeardown() async throws {
        let rig = AudioCaptureTestRig()
        let startGate = BlockingPipelineTeardownGate()
        let cleanupGate = BlockingPipelineTeardownGate()
        rig.pipelines.make = {
            let pipeline = try TestCapturePipeline()
            pipeline.onStart = { startGate.block() }
            pipeline.onStop = {
                startGate.release()
                cleanupGate.block()
            }
            return pipeline
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        try await waitForAudioCondition("pipeline start before termination") {
            startGate.hasEntered
        }

        let termination = Task {
            await controller.prepareForApplicationTermination()
        }
        try await waitForAudioCondition("termination cleanup to begin") {
            cleanupGate.hasEntered
        }
        XCTAssertFalse(controller.captureState.isRunning)
        XCTAssertFalse(controller.captureState.acceptsPrimaryAction)
        cleanupGate.release()
        await termination.value

        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
        XCTAssertEqual(rig.pipelines.pipelines[0].startCount, 1)
        XCTAssertEqual(rig.pipelines.pipelines[0].stopCount, 1)
        XCTAssertEqual(controller.runtimeState, .stopped)
    }

    func testBlockedPipelineConstructionKeepsMainActorResponsiveAndStopOwnsResult() async throws {
        let rig = AudioCaptureTestRig()
        let gate = BlockingPipelineTeardownGate()
        rig.pipelines.make = {
            gate.block()
            return try TestCapturePipeline()
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        try await waitForAudioCondition("pipeline construction to begin") {
            gate.hasEntered
        }

        XCTAssertTrue(gate.hasEntered)
        controller.stop()
        XCTAssertEqual(controller.runtimeState, .stopped)
        XCTAssertFalse(controller.captureState.acceptsPrimaryAction)

        gate.release()
        try await waitForAudioCondition("constructed pipeline cleanup") {
            controller.captureState.acceptsPrimaryAction
        }
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
        XCTAssertEqual(rig.pipelines.pipelines.first?.startCount, 0)
        XCTAssertEqual(rig.pipelines.pipelines.first?.stopCount, 1)
    }

    func testSleepDuringBlockedPipelineConstructionNeverStartsStaleGraph() async throws {
        let rig = AudioCaptureTestRig()
        let gate = BlockingPipelineTeardownGate()
        rig.pipelines.make = {
            gate.block()
            return try TestCapturePipeline()
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        try await waitForAudioCondition("pipeline construction before sleep") {
            gate.hasEntered
        }

        controller.prepareForSystemSleep()
        gate.release()
        try await waitForAudioCondition("sleep construction cleanup") {
            rig.pipelines.pipelines.first?.stopCount == 1
        }

        XCTAssertEqual(rig.pipelines.pipelines.first?.startCount, 0)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
        XCTAssertEqual(controller.captureState.activity, .suspended)
    }

    func testRouteChangeDuringBlockedConstructionStartsOnlyReplacementGraph() async throws {
        let rig = AudioCaptureTestRig()
        let gate = BlockingPipelineTeardownGate()
        rig.pipelines.make = {
            gate.block()
            return try TestCapturePipeline()
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        try await waitForAudioCondition("pipeline construction before route change") {
            gate.hasEntered
        }
        rig.pipelines.make = { try TestCapturePipeline() }

        rig.routeMonitor.triggerChange()
        try await waitForAudioCondition("route comparison during construction") {
            rig.routeGate.routeChangeCheckCount == 1
        }
        gate.release()
        try await waitForAudioCondition("route replacement after construction") {
            rig.pipelines.pipelines.count == 2
                && controller.runtimeState == .active
        }

        XCTAssertEqual(rig.pipelines.pipelines[0].startCount, 0)
        XCTAssertEqual(rig.pipelines.pipelines[0].stopCount, 1)
        XCTAssertEqual(rig.pipelines.pipelines[1].startCount, 1)
    }

    func testTerminationDuringBlockedPipelineConstructionNeverStartsGraph() async throws {
        let rig = AudioCaptureTestRig()
        let gate = BlockingPipelineTeardownGate()
        rig.pipelines.make = {
            gate.block()
            return try TestCapturePipeline()
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        try await waitForAudioCondition("pipeline construction before termination") {
            gate.hasEntered
        }

        let termination = Task { await controller.prepareForApplicationTermination() }
        try await waitForAudioCondition("termination construction cancellation") {
            controller.status.hasPrefix("Stopping Leveling")
        }
        gate.release()
        await termination.value

        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
        XCTAssertEqual(rig.pipelines.pipelines.first?.startCount, 0)
        XCTAssertEqual(rig.pipelines.pipelines.first?.stopCount, 1)
        XCTAssertEqual(controller.runtimeState, .stopped)
    }

    func testBlockedPreflightKeepsMainActorResponsiveAndCannotActivateAfterStop() async throws {
        let rig = AudioCaptureTestRig()
        let gate = BlockingPipelineTeardownGate()
        rig.preflight.onPrepare = { gate.block() }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        try await waitForAudioCondition("capture preflight to begin") {
            gate.hasEntered
        }

        XCTAssertTrue(gate.hasEntered)
        controller.stop()
        gate.release()
        try await waitForAudioCondition("stale preflight completion") {
            rig.preflight.completionCount == 1
        }

        XCTAssertEqual(controller.runtimeState, .stopped)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
    }

    func testRepeatedStartStopCannotQueueStalePreflights() async throws {
        let rig = AudioCaptureTestRig()
        let gate = BlockingPipelineTeardownGate()
        rig.preflight.onPrepare = { gate.block() }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        try await waitForAudioCondition("first blocked preflight") {
            gate.hasEntered
        }
        controller.stop()
        try await waitForAudioCondition("first stop completed") {
            controller.captureState.acceptsPrimaryAction
        }

        for _ in 0..<10 {
            controller.start()
            await waitForRuntimeState(controller, .failed)
            controller.stop()
            try await waitForAudioCondition("bounded retry stop") {
                controller.captureState.acceptsPrimaryAction
            }
        }
        XCTAssertEqual(rig.preflight.completionCount, 0)

        gate.release()
        try await waitForAudioCondition("stale preflight released") {
            rig.preflight.completionCount == 1
        }
        rig.preflight.onPrepare = nil
        controller.start()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(rig.preflight.completionCount, 2)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }

    func testBlockedPipelineTeardownKeepsMainActorResponsive() async throws {
        let rig = AudioCaptureTestRig()
        let gate = BlockingPipelineTeardownGate()
        rig.pipelines.make = {
            let pipeline = try TestCapturePipeline()
            pipeline.onStop = { gate.block() }
            return pipeline
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        controller.stop()
        try await waitForAudioCondition("pipeline teardown to begin") {
            gate.hasEntered
        }

        XCTAssertEqual(controller.runtimeState, .stopped)
        XCTAssertFalse(controller.captureState.acceptsPrimaryAction)

        gate.release()
        try await waitForAudioCondition("pipeline teardown to finish") {
            controller.captureState.acceptsPrimaryAction
        }
        XCTAssertTrue(controller.captureState.acceptsPrimaryAction)
    }

    func testStopDuringRecoveryInvalidatesLateWork() async throws {
        let rig = AudioCaptureTestRig()
        rig.routeGate.wait = {
            while !Task.isCancelled { await Task.yield() }
            throw CancellationError()
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)
        controller.prepareForSystemSleep()
        controller.resumeAfterSystemWake()
        await waitForRuntimeState(controller, .recovering)

        controller.stop()
        try await waitForAudioCondition("recovery stop completion") {
            controller.captureState.acceptsPrimaryAction
        }

        XCTAssertEqual(controller.runtimeState, .stopped)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }

}
