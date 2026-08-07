// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import XCTest
@testable import VolEqMacAudio

@available(macOS 14.2, *)
@MainActor
final class AudioPermissionStartupTests: XCTestCase {
    func testNotNowCreatesNoProbeOrProcessingResources() async {
        var explanationCount = 0
        var probeCount = 0
        var pipelineCount = 0
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in pipelineCount += 1 },
            permissionExplanationRequest: {
                explanationCount += 1
                return false
            },
            permissionProbeFactory: { _ in
                probeCount += 1
                return ImmediateSystemAudioPermissionProbe()
            }
        )

        controller.start()
        await waitForRuntimeState(controller, .stopped)

        XCTAssertEqual(explanationCount, 1)
        XCTAssertEqual(probeCount, 0)
        XCTAssertEqual(pipelineCount, 0)
        XCTAssertEqual(controller.systemAudioAccessState, .explanationRequired)
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller._testOnlyCaptureResourcesAreInactive())
        XCTAssertTrue(controller.status.contains("Original audio remains unchanged"))
    }

    func testMutingPipelineCannotBeginUntilVerifiedProbeIsDestroyed() async {
        let events = PermissionProbeEventRecorder()
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in events.append("pipeline start") },
            permissionExplanationRequest: {
                events.append("explanation accepted")
                return true
            },
            permissionProbeFactory: { _ in
                events.append("probe create")
                return ImmediateSystemAudioPermissionProbe(recorder: events)
            }
        )

        controller.start()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(events.events, [
            "explanation accepted",
            "probe create",
            "probe verify",
            "probe teardown",
            "pipeline start"
        ])
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.systemAudioAccessState, .verified)
    }

    func testVerifiedOutcomeIsRejectedIfProbeReportsResourcesStillAlive() async {
        var pipelineCount = 0
        let probe = ImmediateSystemAudioPermissionProbe(
            outcome: .verified,
            tearsDownBeforeReturning: false
        )
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in pipelineCount += 1 },
            permissionProbeFactory: { _ in probe }
        )

        controller.start()
        await waitForRuntimeState(controller, .permissionRequired)

        XCTAssertEqual(pipelineCount, 0)
        XCTAssertEqual(probe.cancelCount, 1)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(
            controller.systemAudioAccessState,
            .actionRequired(.cleanupFailed)
        )
    }

    func testEveryUnverifiedOutcomeLeavesProcessingStopped() async {
        let cases: [(SystemAudioPermissionProbeOutcome, CaptureRuntimeState)] = [
            (.denied, .permissionRequired),
            (.timedOut, .permissionRequired),
            (.cancelled, .stopped),
            (.malformed, .permissionRequired),
            (.coreAudioFailure(operation: "Probe", status: -1), .permissionRequired)
        ]

        for (outcome, expectedRuntimeState) in cases {
            var pipelineCount = 0
            let controller = AudioCaptureController(
                installSystemObservers: false,
                startPipelineOverride: { _ in pipelineCount += 1 },
                permissionProbeFactory: { _ in
                    ImmediateSystemAudioPermissionProbe(outcome: outcome)
                }
            )

            controller.start()
            await waitForRuntimeState(controller, expectedRuntimeState)

            XCTAssertFalse(controller.isRunning, "Unexpected running state for \(outcome)")
            XCTAssertEqual(pipelineCount, 0, "Unexpected pipeline for \(outcome)")
            XCTAssertTrue(controller.status.contains("original audio remains unchanged")
                || controller.status.contains("Original audio remains unchanged"))
        }
    }

    func testCheckingKeepsIsRunningFalseAndRejectsDuplicateStart() async {
        let probe = SuspendedSystemAudioPermissionProbe()
        var factoryCount = 0
        var pipelineCount = 0
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in pipelineCount += 1 },
            permissionProbeFactory: { _ in
                factoryCount += 1
                return probe
            }
        )

        controller.start()
        await waitForRuntimeState(controller, .checkingAccess)
        controller.start()
        controller.checkAudioAccessAgain()

        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(pipelineCount, 0)

        probe.complete(with: .verified)
        await waitForRuntimeState(controller, .active)
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(pipelineCount, 1)
    }

    func testCancelTearsDownActiveProbeImmediately() async {
        let probe = SuspendedSystemAudioPermissionProbe()
        var pipelineCount = 0
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in pipelineCount += 1 },
            permissionProbeFactory: { _ in probe }
        )

        controller.start()
        await waitForRuntimeState(controller, .checkingAccess)
        controller.cancelAudioAccessCheck()

        XCTAssertEqual(probe.cancelCount, 1)
        XCTAssertTrue(probe.isTornDown)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.runtimeState, .stopped)
        XCTAssertEqual(pipelineCount, 0)
        XCTAssertTrue(controller.status.contains("cancelled"))
    }

    func testRealPipelineFailureAfterVerificationRestoresOriginalPath() async {
        enum PipelineFailure: Error { case failed }
        var teardownSteps: [AudioCaptureTeardownStep] = []
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { controller in
                controller._testOnlySimulatePartiallyPreparedCaptureResources()
                throw PipelineFailure.failed
            },
            teardownStepRecorder: { teardownSteps.append($0) },
            permissionProbeFactory: { _ in
                ImmediateSystemAudioPermissionProbe()
            }
        )

        controller.start()
        await waitForRuntimeState(controller, .failed)

        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller._testOnlyCaptureResourcesAreInactive())
        XCTAssertEqual(teardownSteps, [
            .activeOutputListeners,
            .stopIOProc,
            .destroyIOProc,
            .destroyAggregate,
            .destroyTap
        ])
    }

    func testEveryFreshStartCreatesANewPermissionProbe() async {
        var probeCount = 0
        var pipelineCount = 0
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in pipelineCount += 1 },
            permissionProbeFactory: { _ in
                probeCount += 1
                return ImmediateSystemAudioPermissionProbe()
            }
        )

        controller.start()
        await waitForRuntimeState(controller, .active)
        controller.stop()
        controller.start()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(pipelineCount, 2)
    }

    func testRouteRecoveryReverifiesBeforeRebuildingPipeline() async throws {
        let events = PermissionProbeEventRecorder()
        var probeCount = 0
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in events.append("pipeline") },
            permissionProbeFactory: { _ in
                probeCount += 1
                events.append("probe \(probeCount)")
                return ImmediateSystemAudioPermissionProbe(recorder: events)
            },
            routeRecoveryDelayNanoseconds: 0
        )

        controller.start()
        await waitForRuntimeState(controller, .active)
        controller._testOnlyHandleOutputRouteChange()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(events.events.filter { $0 == "pipeline" }.count, 2)
        let secondProbeIndex = try XCTUnwrap(events.events.firstIndex(of: "probe 2"))
        let lastPipelineIndex = try XCTUnwrap(events.events.lastIndex(of: "pipeline"))
        XCTAssertLessThan(secondProbeIndex, lastPipelineIndex)
    }

    func testFailedRouteRecoveryLeavesOriginalAudioRestored() async {
        var outcomes: [SystemAudioPermissionProbeOutcome] = [.verified, .timedOut]
        var pipelineCount = 0
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in pipelineCount += 1 },
            permissionProbeFactory: { _ in
                ImmediateSystemAudioPermissionProbe(outcome: outcomes.removeFirst())
            },
            routeRecoveryDelayNanoseconds: 0
        )

        controller.start()
        await waitForRuntimeState(controller, .active)
        controller._testOnlyHandleOutputRouteChange()
        await waitForRuntimeState(controller, .permissionRequired)

        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(pipelineCount, 1)
        XCTAssertEqual(
            controller.systemAudioAccessState,
            .actionRequired(.couldNotVerify)
        )
        XCTAssertTrue(controller.status.contains("original audio remains unchanged"))
    }

    func testProbeTargetsSelectedApplicationAndDeviceWideExclusion() async {
        var configurations: [SystemAudioPermissionProbeConfiguration] = []
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in },
            permissionProbeFactory: { configuration in
                configurations.append(configuration)
                return ImmediateSystemAudioPermissionProbe()
            }
        )

        controller.selectedProcessID = 77
        controller.mode = .application
        controller.start()
        await waitForRuntimeState(controller, .active)
        controller.stop()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(configurations.map(\.target), [
            .application(77),
            .deviceWide(excluding: 1)
        ])
    }

    func testProductionTargetResolutionRejectsNilAndStaleSelection() throws {
        let process = AudioProcess(
            id: 77,
            pid: 700,
            name: "Meeting",
            bundleID: "example.meeting"
        )

        XCTAssertThrowsError(try AudioCaptureController.resolvePermissionProbeTarget(
            mode: .application,
            selectedProcessID: nil,
            processes: [process],
            ownProcessObject: { XCTFail("App mode must not query self"); return 88 }
        ))
        XCTAssertThrowsError(try AudioCaptureController.resolvePermissionProbeTarget(
            mode: .application,
            selectedProcessID: 78,
            processes: [process],
            ownProcessObject: { XCTFail("App mode must not query self"); return 88 }
        ))
        XCTAssertEqual(
            try AudioCaptureController.resolvePermissionProbeTarget(
                mode: .application,
                selectedProcessID: 77,
                processes: [process],
                ownProcessObject: { XCTFail("App mode must not query self"); return 88 }
            ),
            .application(77)
        )
    }

    func testProductionDeviceWideTargetRequiresAndUsesOwnProcessObject() throws {
        XCTAssertThrowsError(try AudioCaptureController.resolvePermissionProbeTarget(
            mode: .system,
            selectedProcessID: nil,
            processes: [],
            ownProcessObject: { nil }
        ))
        XCTAssertEqual(
            try AudioCaptureController.resolvePermissionProbeTarget(
                mode: .system,
                selectedProcessID: nil,
                processes: [],
                ownProcessObject: { 88 }
            ),
            .deviceWide(excluding: 88)
        )
    }

    func testRouteChangeWhileCheckingCancelsAndReverifies() async {
        let firstProbe = SuspendedSystemAudioPermissionProbe()
        var probeCount = 0
        var pipelineCount = 0
        let controller = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in pipelineCount += 1 },
            permissionProbeFactory: { _ in
                probeCount += 1
                return probeCount == 1
                    ? firstProbe
                    : ImmediateSystemAudioPermissionProbe()
            },
            routeRecoveryDelayNanoseconds: 0
        )

        controller.start()
        await waitForRuntimeState(controller, .checkingAccess)
        controller._testOnlyHandleOutputRouteChange()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(firstProbe.cancelCount, 1)
        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(pipelineCount, 1)
    }
}
