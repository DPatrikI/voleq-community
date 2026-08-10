// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VolEqMacAudio

@available(macOS 14.2, *)
@MainActor
final class AudioLifecycleSleepWakeTests: XCTestCase {
    func testActivePipelineIsStoppedBeforeSleepAndReplacedAfterWake() async {
        let rig = AudioCaptureTestRig()
        rig.wakeRecoveryDelayNanoseconds = 1_000_000_000
        let controller = rig.makeController()
        controller.mode = .system

        controller.start()
        await waitForRuntimeState(controller, .active)
        guard let first = rig.pipelines.pipelines.first else {
            return XCTFail("Expected the initial pipeline")
        }

        controller.prepareForSystemSleep()
        XCTAssertEqual(controller.captureState.activity, .suspended)
        for _ in 0..<2_000 where first.stopCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertFalse(controller.isRunning)

        controller.resumeAfterSystemWake()
        await waitForRuntimeState(controller, .active)
        XCTAssertEqual(rig.routeGate.initialDelays, [1_000_000_000])
        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
    }

    func testSettingsChangedDuringBlockedSleepCleanupReachWakeReplacement() async throws {
        let rig = AudioCaptureTestRig()
        let teardownEntered = AudioTestFlag()
        let teardownRelease = DispatchSemaphore(value: 0)
        defer { teardownRelease.signal() }
        rig.pipelines.make = {
            let pipeline = try TestCapturePipeline()
            pipeline.onStop = {
                teardownEntered.set()
                teardownRelease.wait()
            }
            return pipeline
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        controller.prepareForSystemSleep()
        controller.resumeAfterSystemWake()
        try await waitForAudioCondition("blocked sleep teardown") {
            teardownEntered.value
        }
        var settings = controller.levelingSettings
        settings.limiterDB = -8
        controller.levelingSettings = settings

        teardownRelease.signal()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(rig.pipelines.requests.count, 2)
        XCTAssertEqual(
            rig.pipelines.requests.last?.intent.levelingSettings.limiterDB,
            -8
        )
        XCTAssertEqual(controller.levelingSettings.limiterDB, -8)
    }

    func testStoppedSessionDoesNotRestartAfterWake() async throws {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        try await waitForAudioCondition("initial ready state") {
            controller.runtimeState == .ready
        }
        controller.prepareForSystemSleep()
        controller.resumeAfterSystemWake()
        await Task.yield()

        XCTAssertEqual(controller.runtimeState, .ready)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
    }

    func testApplicationIdentityAndLatestConfigurationAreRestored() async throws {
        let rig = AudioCaptureTestRig()
        let original = audioProcess(id: 10, pid: 20, name: "Call")
        let relaunched = audioProcess(id: 11, pid: 21, name: "Call")
        rig.processCatalog.result = .success([original])
        let controller = rig.makeController()
        controller.refreshProcesses()
        try await waitForAudioCondition("original application selection") {
            controller.selectedProcessID == original.id
        }
        controller.speechAwarenessEnabled = false
        var settings = controller.levelingSettings
        settings.limiterDB = -4
        controller.levelingSettings = settings

        controller.start()
        await waitForRuntimeState(controller, .active)
        var liveSettings = controller.levelingSettings
        liveSettings.limiterDB = -7
        controller.levelingSettings = liveSettings
        XCTAssertEqual(rig.pipelines.pipelines.first?.settings.last?.limiterDB, -7)

        controller.prepareForSystemSleep()
        rig.processCatalog.result = .success([relaunched])
        controller.resumeAfterSystemWake()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(controller.selectedProcessID, relaunched.id)
        XCTAssertEqual(controller.mode, .application)
        XCTAssertFalse(controller.speechAwarenessEnabled)
        XCTAssertEqual(controller.levelingSettings.limiterDB, -7)
        XCTAssertEqual(rig.pipelines.requests.last?.intent.application?.pid, relaunched.pid)
        XCTAssertEqual(rig.pipelines.requests.last?.intent.levelingSettings.limiterDB, -7)
    }

    func testDuplicateWakeCreatesOneReplacementPipeline() async {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)
        controller.prepareForSystemSleep()

        controller.resumeAfterSystemWake()
        controller.resumeAfterSystemWake()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(rig.routeGate.initialDelays.count, 1)
        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
    }

    func testTeardownFailureBlocksWakeReplacement() async {
        let rig = AudioCaptureTestRig()
        rig.pipelines.make = {
            let pipeline = try TestCapturePipeline()
            pipeline.teardownReport = .init(unresolvedSteps: [.destroyTap])
            return pipeline
        }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        controller.prepareForSystemSleep()
        controller.resumeAfterSystemWake()
        await waitForRuntimeState(controller, .failed)

        XCTAssertEqual(controller.runtimeState, .failed)
        XCTAssertEqual(controller.systemAudioAccessState, .actionRequired(.cleanupFailed))
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }
}
