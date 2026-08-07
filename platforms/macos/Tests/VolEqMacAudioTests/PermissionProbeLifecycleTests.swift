// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation
import XCTest
@testable import VolEqMacAudio

private let testIOProc: AudioDeviceIOProcID = {
    _, _, _, _, _, _, _ in noErr
}

private final class AdvancingProbeTiming: PermissionProbeTiming, @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0

    func nowNanoseconds() -> UInt64 {
        lock.withLock {
            defer { current += 2 }
            return current
        }
    }

    func sleep(nanoseconds: UInt64) async throws {}
}

@available(macOS 14.2, *)
@MainActor
final class PermissionProbeLifecycleTests: XCTestCase {
    func testBlockedDeviceStartIsBoundedByVerifierTimeout() async throws {
        let startGate = DispatchSemaphore(value: 0)
        let recorder = LockedEventRecorder()
        let operations = CoreAudioPermissionProbeOperations(
            start: { _, _ in
                recorder.append("start begin")
                startGate.wait()
                recorder.append("start end")
                return noErr
            },
            stop: { _, _ in
                recorder.append("stop")
                startGate.signal()
                return noErr
            },
            destroyIOProc: { _, _ in
                recorder.append("destroyIOProc")
                return noErr
            },
            destroyAggregate: { _ in
                recorder.append("destroyAggregate")
                return noErr
            },
            destroyTap: { _ in
                recorder.append("destroyTap")
                return noErr
            }
        )
        let probe = try CoreAudioSystemPermissionProbe(
            configuration: configuration,
            timing: AdvancingProbeTiming(),
            timeoutNanoseconds: 1,
            pollNanoseconds: 1,
            operations: operations,
            prepareResourcesOverride: {}
        )
        probe._testOnlyAdoptResources(
            tapID: 11,
            aggregateDeviceID: 12,
            ioProcID: testIOProc
        )

        let outcome = await probe.verify()
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertTrue(probe.isTornDown)
        let events = recorder.events
        XCTAssertLessThan(
            try XCTUnwrap(events.firstIndex(of: "start end")),
            try XCTUnwrap(events.firstIndex(of: "destroyIOProc"))
        )
    }

    func testDeniedDeviceStartSkipsStopAndStillDestroysEveryResource() async throws {
        let recorder = LockedEventRecorder()
        let operations = CoreAudioPermissionProbeOperations(
            start: { _, _ in kAudioDevicePermissionsError },
            stop: { _, _ in
                recorder.append("stop")
                return noErr
            },
            destroyIOProc: { _, _ in
                recorder.append("destroyIOProc")
                return noErr
            },
            destroyAggregate: { _ in
                recorder.append("destroyAggregate")
                return noErr
            },
            destroyTap: { _ in
                recorder.append("destroyTap")
                return noErr
            }
        )
        let probe = try CoreAudioSystemPermissionProbe(
            configuration: configuration,
            timing: ContinuousPermissionProbeTiming(),
            timeoutNanoseconds: 1_000_000_000,
            pollNanoseconds: 1,
            operations: operations,
            prepareResourcesOverride: {}
        )
        probe._testOnlyAdoptResources(
            tapID: 13,
            aggregateDeviceID: 14,
            ioProcID: testIOProc
        )

        let outcome = await probe.verify()

        XCTAssertEqual(outcome, .denied)
        XCTAssertTrue(probe.isTornDown)
        XCTAssertEqual(
            recorder.events,
            ["destroyIOProc", "destroyAggregate", "destroyTap"]
        )
    }

    func testStopFailureKeepsProbeOwnedAndFailsClosed() throws {
        try assertProbeTeardownFailure(
            operations: operations(stop: { -51 }),
            expectedEvents: ["stop"]
        )
    }

    func testIOProcDestroyFailureKeepsProbeOwnedAndFailsClosed() throws {
        try assertProbeTeardownFailure(
            operations: operations(destroyIOProc: { -52 }),
            expectedEvents: ["destroyIOProc"],
            startAttempted: false
        )
    }

    func testAggregateDestroyFailureKeepsProbeOwnedAndFailsClosed() throws {
        try assertProbeTeardownFailure(
            operations: operations(destroyAggregate: { -53 }),
            expectedEvents: ["destroyIOProc", "destroyAggregate"],
            startAttempted: false
        )
    }

    func testTapDestroyFailureKeepsProbeOwnedAndFailsClosed() throws {
        try assertProbeTeardownFailure(
            operations: operations(destroyTap: { -54 }),
            expectedEvents: ["destroyIOProc", "destroyAggregate", "destroyTap"],
            startAttempted: false
        )
    }

    func testRealPipelineStopFailureDoesNotClaimOriginalAudioWasRestored() {
        let operations = AudioCaptureResourceOperations(
            stop: { _, _ in -55 },
            destroyIOProc: { _, _ in noErr },
            destroyAggregate: { _ in noErr },
            destroyTap: { _ in noErr }
        )
        let controller = AudioCaptureController(
            installSystemObservers: false,
            initiallyRunning: true,
            resourceOperations: operations
        )
        controller._testOnlyAdoptCaptureResources(
            tapID: 21,
            aggregateDeviceID: 22,
            ioProcID: testIOProc
        )

        controller.stop()

        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.runtimeState, .failed)
        XCTAssertEqual(
            controller.systemAudioAccessState,
            .actionRequired(.cleanupFailed)
        )
        XCTAssertTrue(controller.status.contains("could not fully stop"))
        XCTAssertTrue(controller.status.contains("Quit VolEq"))
        XCTAssertFalse(controller.status.contains(
            "Original application audio is restored"
        ))
        XCTAssertFalse(controller._testOnlyCaptureResourcesAreInactive())
    }

    func testUnstartedRealPipelineSkipsStopAndDestroysPartialResources() {
        let recorder = LockedEventRecorder()
        let operations = AudioCaptureResourceOperations(
            stop: { _, _ in
                recorder.append("stop")
                return -56
            },
            destroyIOProc: { _, _ in
                recorder.append("destroyIOProc")
                return noErr
            },
            destroyAggregate: { _ in
                recorder.append("destroyAggregate")
                return noErr
            },
            destroyTap: { _ in
                recorder.append("destroyTap")
                return noErr
            }
        )
        let controller = AudioCaptureController(
            installSystemObservers: false,
            resourceOperations: operations
        )
        controller._testOnlyAdoptCaptureResources(
            tapID: 23,
            aggregateDeviceID: 24,
            ioProcID: testIOProc,
            started: false
        )

        controller.stop()

        XCTAssertEqual(
            recorder.events,
            ["destroyIOProc", "destroyAggregate", "destroyTap"]
        )
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller._testOnlyCaptureResourcesAreInactive())
    }

    func testEveryRealPipelineDestroyFailureRequiresQuit() {
        for failingStep in ["destroyIOProc", "destroyAggregate", "destroyTap"] {
            let operations = AudioCaptureResourceOperations(
                stop: { _, _ in noErr },
                destroyIOProc: { _, _ in
                    failingStep == "destroyIOProc" ? -57 : noErr
                },
                destroyAggregate: { _ in
                    failingStep == "destroyAggregate" ? -58 : noErr
                },
                destroyTap: { _ in
                    failingStep == "destroyTap" ? -59 : noErr
                }
            )
            let controller = AudioCaptureController(
                installSystemObservers: false,
                initiallyRunning: true,
                resourceOperations: operations
            )
            controller._testOnlyAdoptCaptureResources(
                tapID: 25,
                aggregateDeviceID: 26,
                ioProcID: testIOProc
            )

            controller.stop()

            XCTAssertEqual(
                controller.systemAudioAccessState,
                .actionRequired(.cleanupFailed),
                "Expected cleanup-required state for \(failingStep)"
            )
            XCTAssertTrue(controller.status.contains("Quit VolEq"))
            XCTAssertFalse(controller._testOnlyCaptureResourcesAreInactive())
        }
    }

    private let configuration = SystemAudioPermissionProbeConfiguration(
        target: .application(7),
        outputDeviceUID: "test-output"
    )

    private func assertProbeTeardownFailure(
        operations: CoreAudioPermissionProbeOperations,
        expectedEvents: [String],
        startAttempted: Bool = true
    ) throws {
        let recorder = LockedEventRecorder()
        let recordingOperations = CoreAudioPermissionProbeOperations(
            start: operations.start,
            stop: { deviceID, ioProcID in
                recorder.append("stop")
                return operations.stop(deviceID, ioProcID)
            },
            destroyIOProc: { deviceID, ioProcID in
                recorder.append("destroyIOProc")
                return operations.destroyIOProc(deviceID, ioProcID)
            },
            destroyAggregate: { deviceID in
                recorder.append("destroyAggregate")
                return operations.destroyAggregate(deviceID)
            },
            destroyTap: { tapID in
                recorder.append("destroyTap")
                return operations.destroyTap(tapID)
            }
        )
        let probe = try CoreAudioSystemPermissionProbe(
            configuration: configuration,
            operations: recordingOperations
        )
        probe._testOnlyAdoptResources(
            tapID: 31,
            aggregateDeviceID: 32,
            ioProcID: testIOProc,
            startAttempted: startAttempted
        )

        probe.cancel()

        XCTAssertFalse(probe.isTornDown)
        XCTAssertEqual(recorder.events, expectedEvents)
    }

    private func operations(
        start: @escaping () -> OSStatus = { noErr },
        stop: @escaping () -> OSStatus = { noErr },
        destroyIOProc: @escaping () -> OSStatus = { noErr },
        destroyAggregate: @escaping () -> OSStatus = { noErr },
        destroyTap: @escaping () -> OSStatus = { noErr }
    ) -> CoreAudioPermissionProbeOperations {
        CoreAudioPermissionProbeOperations(
            start: { _, _ in start() },
            stop: { _, _ in stop() },
            destroyIOProc: { _, _ in destroyIOProc() },
            destroyAggregate: { _ in destroyAggregate() },
            destroyTap: { _ in destroyTap() }
        )
    }
}

private final class LockedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}
