// SPDX-License-Identifier: MPL-2.0

import VolEqCore
import XCTest
@testable import VolEqMacAudio

final class CaptureLifecycleReducerTests: XCTestCase {
    private let intent = CaptureIntent(
        mode: .system,
        speechAwarenessEnabled: false,
        levelingSettings: LevelingSettings(),
        application: nil
    )

    func testStartIsAcceptedOnlyFromExplicitStartablePhases() {
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .ready,
                event: .start(intent)
            ),
            .beginStart(intent)
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .suspended(intent),
                event: .start(intent)
            ),
            .ignore
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .recoveryFailed(intent, .routeUnavailable),
                event: .start(intent)
            ),
            .ignore
        )
    }

    func testWakeAndRetryCannotBypassTheirRequiredPhases() {
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(phase: .ready, event: .wake),
            .ignore
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .suspended(intent),
                event: .wake
            ),
            .recover(intent, .systemWake)
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .ready,
                event: .retry(intent)
            ),
            .ignore
        )
    }

    func testRouteAndCallbackEventsRequireLiveWork() {
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .preparing(intent),
                event: .routeChanged
            ),
            .recover(intent, .outputRouteChanged)
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .active(intent),
                event: .callbacksStalled
            ),
            .recover(intent, .stalledCallbacks)
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .stopped,
                event: .callbacksStalled
            ),
            .ignore
        )
    }

    func testSleepAndStopCarryOnlyPhaseOwnedIntent() {
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .active(intent),
                event: .sleep(nil)
            ),
            .sleep(intent)
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .active(intent),
                event: .stop
            ),
            .stop(intent)
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .stopping(intent),
                event: .stop
            ),
            .ignore
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .suspending(intent),
                event: .sleep(intent)
            ),
            .cancelQueuedWake
        )
    }

    func testRefreshPreservesDeclinedExplanationAndLivePhases() {
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .explanationDeclined,
                event: .processRefreshSucceeded
            ),
            .ignore
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .active(intent),
                event: .processRefreshFailed(intent)
            ),
            .ignore
        )
    }

    func testRecoveryStartFlowRequiresTheOwningPreviousIntent() {
        let restored = CaptureIntent(
            mode: .system,
            speechAwarenessEnabled: true,
            levelingSettings: LevelingSettings(),
            application: nil
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .recovering(intent, .systemWake),
                event: .recoveryStartFlowBegan(
                    previous: intent,
                    restored: restored
                )
            ),
            .transition(.explaining(restored))
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .recovering(restored, .systemWake),
                event: .recoveryStartFlowBegan(
                    previous: intent,
                    restored: restored
                )
            ),
            .ignore
        )
    }

    func testProcessingFailureCanOnlyStopItsActiveIntent() {
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .active(intent),
                event: .processingFailed(intent)
            ),
            .stop(intent)
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .ready,
                event: .processingFailed(intent)
            ),
            .ignore
        )
    }

    func testAsynchronousResultsAdvanceOnlyFromOwningPhase() {
        let failure = CaptureLifecyclePhase.verifiedFailure(intent)
        let cases: [(
            CaptureLifecyclePhase,
            CaptureLifecycleEvent,
            CaptureLifecycleDirective
        )] = [
            (
                .explaining(intent),
                .explanationAccepted(intent),
                .transition(.preparing(intent))
            ),
            (
                .explaining(intent),
                .explanationDeclined(intent),
                .transition(.explanationDeclined)
            ),
            (
                .preparing(intent),
                .startupFailed(failure),
                .transition(failure)
            ),
            (
                .preparing(intent),
                .pipelineStarted(intent),
                .transition(.active(intent))
            ),
            (
                .preparing(intent),
                .pipelineStartFailed(intent),
                .transition(.stopping(intent))
            ),
            (
                .stopping(intent),
                .teardownCompleted(.failed(failure)),
                .transition(failure)
            ),
            (
                .suspending(intent),
                .teardownCompleted(.suspended(intent)),
                .transition(.suspended(intent))
            ),
            (
                .recovering(intent, .systemWake),
                .teardownCompleted(.recoveryReady(intent, .systemWake)),
                .recover(intent, .systemWake)
            ),
            (
                .recovering(intent, .outputRouteChanged),
                .recoveryFailed(intent, .routeUnavailable),
                .transition(.recoveryFailed(intent, .routeUnavailable))
            ),
        ]

        for (phase, event, expected) in cases {
            XCTAssertEqual(
                CaptureLifecycleReducer.reduce(phase: phase, event: event),
                expected,
                "Unexpected transition for \(phase) and \(event)"
            )
        }
    }

    func testStaleAsynchronousResultsAndInvalidCompletionsAreIgnored() {
        let staleEvents: [CaptureLifecycleEvent] = [
            .explanationAccepted(intent),
            .explanationDeclined(intent),
            .startupFailed(.verifiedFailure(intent)),
            .pipelineStarted(intent),
            .pipelineStartFailed(intent),
            .teardownCompleted(.stopped),
            .teardownFailed,
            .recoveryFailed(intent, .routeUnavailable),
        ]

        for event in staleEvents {
            XCTAssertEqual(
                CaptureLifecycleReducer.reduce(phase: .ready, event: event),
                .ignore,
                "Ready accepted stale event \(event)"
            )
        }
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .active(intent),
                event: .teardownCompleted(.stopped)
            ),
            .ignore
        )

        let differentIntent = CaptureIntent(
            mode: .system,
            speechAwarenessEnabled: true,
            levelingSettings: LevelingSettings(),
            application: nil
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .preparing(intent),
                event: .pipelineStarted(differentIntent)
            ),
            .ignore
        )
    }

    func testTerminationUsesThePhaseOwnedIntent() {
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .active(intent),
                event: .terminationRequested
            ),
            .stop(intent)
        )
        XCTAssertEqual(
            CaptureLifecycleReducer.reduce(
                phase: .stopping(intent),
                event: .terminationRequested
            ),
            .ignore
        )
    }

    func testStateMachinePublishesReducerApprovedAsyncTransitionsAtomically() {
        var machine = CaptureLifecycleStateMachine()
        _ = machine.apply(
            event: .startFlowBegan(intent),
            status: "Explaining"
        )

        let result = machine.apply(
            event: .explanationAccepted(intent),
            status: "Starting"
        )

        XCTAssertEqual(
            result.directive,
            .transition(.preparing(intent))
        )
        XCTAssertEqual(result.published, machine.snapshot)
        XCTAssertEqual(machine.phase, .preparing(intent))
        XCTAssertEqual(machine.snapshot.status, "Starting")
    }

    func testStateMachineDoesNotPublishOrMutateForStaleAsyncEvent() {
        var machine = CaptureLifecycleStateMachine()
        _ = machine.apply(event: .processRefreshSucceeded, status: "Ready")
        let before = machine.snapshot

        let result = machine.apply(
            event: .pipelineStarted(intent),
            status: "Must not publish"
        )

        XCTAssertEqual(result.directive, .ignore)
        XCTAssertNil(result.published)
        XCTAssertEqual(machine.snapshot, before)
    }

    func testStateMachineDerivesCommandTransitionWithoutRawPhaseMutation() {
        var machine = CaptureLifecycleStateMachine()
        _ = machine.apply(event: .processRefreshSucceeded, status: "Ready")

        let start = machine.apply(event: .start(intent), status: "Starting")
        XCTAssertEqual(start.directive, .beginStart(intent))
        XCTAssertNil(start.published)

        _ = machine.apply(event: .startFlowBegan(intent), status: "Preparing")
        let stop = machine.apply(event: .stop, status: "Stopping")
        XCTAssertEqual(stop.directive, .stop(intent))
        XCTAssertEqual(stop.published?.phase, .stopping(intent))
    }
}
