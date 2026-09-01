// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import XCTest
@testable import VolEqMacAudio

private let pipelineTestIOProc: AudioDeviceIOProcID = {
    _, _, _, _, _, _, _ in noErr
}

@available(macOS 14.2, *)
final class CoreAudioCapturePipelineTeardownTests: XCTestCase {
    func testPendingStartIsStoppedAfterItCompletesBeforeDestruction() async {
        let startEntered = expectation(description: "start entered")
        let stopEntered = expectation(description: "preemptive stop entered")
        let allowStart = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var events: [String] = []
        var stopCount = 0
        let owner = makeOwner(
            callbackStarted: false,
            operations: .init(
                start: { _, _ in
                    lock.withLock { events.append("start") }
                    startEntered.fulfill()
                    allowStart.wait()
                    lock.withLock { events.append("start-finished") }
                    return noErr
                },
                stop: { _, _ in
                    let count = lock.withLock { () -> Int in
                        stopCount += 1
                        events.append("stop-\(stopCount)")
                        return stopCount
                    }
                    if count == 1 {
                        stopEntered.fulfill()
                        allowStart.signal()
                    }
                    return noErr
                },
                destroyIOProc: { _, _ in
                    lock.withLock { events.append("io") }
                    return noErr
                },
                destroyAggregate: { _ in
                    lock.withLock { events.append("aggregate") }
                    return noErr
                },
                destroyTap: { _ in
                    lock.withLock { events.append("tap") }
                    return noErr
                }
            )
        )

        let startTask = Task.detached { owner.startIOProc() }
        await fulfillment(of: [startEntered], timeout: 1)
        let teardownTask = Task.detached { owner.teardown() }
        await fulfillment(of: [stopEntered], timeout: 1)

        let startStatus = await startTask.value
        let teardownReport = await teardownTask.value
        XCTAssertEqual(startStatus, noErr)
        XCTAssertEqual(teardownReport, .complete)
        XCTAssertEqual(lock.withLock { events }, [
            "start", "stop-1", "start-finished", "stop-2",
            "io", "aggregate", "tap",
        ])
    }

    func testConcurrentTeardownCallsSerializeTheOwnershipLedger() async {
        let entered = expectation(description: "first teardown entered HAL")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var destroyTapCount = 0
        let owner = CoreAudioCaptureResourceOwner(
            operations: .init(
                start: { _, _ in noErr },
                stop: { _, _ in noErr },
                destroyIOProc: { _, _ in noErr },
                destroyAggregate: { _ in noErr },
                destroyTap: { _ in
                    lock.withLock { destroyTapCount += 1 }
                    entered.fulfill()
                    release.wait()
                    return noErr
                }
            ),
            routeQueue: DispatchQueue(label: "test.route")
        )
        owner.didCreateTap(11)

        let first = Task.detached { owner.teardown() }
        await fulfillment(of: [entered], timeout: 1)
        let second = Task.detached { owner.teardown() }
        release.signal()

        let firstReport = await first.value
        let secondReport = await second.value
        XCTAssertEqual(firstReport, .complete)
        XCTAssertEqual(secondReport, .complete)
        XCTAssertEqual(lock.withLock { destroyTapCount }, 1)
    }

    func testStopAttemptsEveryResourceInSafetyOrder() {
        let recorder = EventRecorder()
        let owner = makeOwner(operations: .recording(into: recorder))

        XCTAssertEqual(owner.teardown(), .complete)
        XCTAssertEqual(recorder.events, ["stop", "io", "aggregate", "tap"])
        XCTAssertEqual(owner.teardown(), .complete)
        XCTAssertEqual(recorder.events, ["stop", "io", "aggregate", "tap"])
    }

    func testFailedIOProcDestructionRetainsParentsAndRetriesInOrder() {
        var events: [String] = []
        var destroyAttempts = 0
        let owner = makeOwner(operations: .init(
            start: { _, _ in noErr },
            stop: { _, _ in events.append("stop"); return noErr },
            destroyIOProc: { _, _ in
                events.append("io")
                destroyAttempts += 1
                return destroyAttempts == 1 ? -2 : noErr
            },
            destroyAggregate: { _ in events.append("aggregate"); return noErr },
            destroyTap: { _ in events.append("tap"); return noErr }
        ))

        XCTAssertEqual(owner.teardown().unresolvedSteps, [
            .destroyIOProc, .destroyAggregate, .destroyTap,
        ])
        XCTAssertEqual(events, ["stop", "io"])

        XCTAssertEqual(owner.teardown(), .complete)
        XCTAssertEqual(events, ["stop", "io", "io", "aggregate", "tap"])
    }

    func testSuccessfulIOProcDestructionSupersedesStopFailure() {
        let owner = makeOwner(operations: .init(
            start: { _, _ in noErr },
            stop: { _, _ in -1 },
            destroyIOProc: { _, _ in noErr },
            destroyAggregate: { _ in noErr },
            destroyTap: { _ in noErr }
        ))

        XCTAssertEqual(owner.teardown(), .complete)
    }

    func testAggregateFailureRetainsTapAndRetriesInOrder() {
        var events: [String] = []
        var aggregateAttempts = 0
        let owner = makeOwner(operations: .init(
            start: { _, _ in noErr },
            stop: { _, _ in events.append("stop"); return noErr },
            destroyIOProc: { _, _ in events.append("io"); return noErr },
            destroyAggregate: { _ in
                events.append("aggregate")
                aggregateAttempts += 1
                return aggregateAttempts == 1 ? -3 : noErr
            },
            destroyTap: { _ in events.append("tap"); return noErr }
        ))

        XCTAssertEqual(owner.teardown().unresolvedSteps, [
            .destroyAggregate, .destroyTap,
        ])
        XCTAssertEqual(events, ["stop", "io", "aggregate"])
        XCTAssertEqual(owner.teardown(), .complete)
        XCTAssertEqual(events, ["stop", "io", "aggregate", "aggregate", "tap"])
    }

    func testListenerRemovalFailureDoesNotPreventGraphTeardown() {
        var events: [String] = []
        let owner = makeOwner(
            includeListener: true,
            operations: .init(
                start: { _, _ in noErr },
                stop: { _, _ in events.append("stop"); return noErr },
                destroyIOProc: { _, _ in events.append("io"); return noErr },
                destroyAggregate: { _ in events.append("aggregate"); return noErr },
                destroyTap: { _ in events.append("tap"); return noErr },
                removePropertyListenerStatus: { _, _ in -5 }
            )
        )

        let report = owner.teardown()
        XCTAssertEqual(report.unresolvedSteps, [.activeOutputListeners])
        XCTAssertTrue(report.permitsReplacementPipeline)
        XCTAssertEqual(events, ["stop", "io", "aggregate", "tap"])
    }

    func testCriticalGraphFailureDoesNotPermitReplacementPipeline() {
        let owner = makeOwner(operations: .init(
            start: { _, _ in noErr },
            stop: { _, _ in noErr },
            destroyIOProc: { _, _ in -77 },
            destroyAggregate: { _ in noErr },
            destroyTap: { _ in noErr }
        ))

        let report = owner.teardown()

        XCTAssertFalse(report.permitsReplacementPipeline)
        XCTAssertTrue(report.unresolvedSteps.contains(.destroyIOProc))
    }

    func testUnstartedOwnerSkipsStopButDestroysGraph() {
        let recorder = EventRecorder()
        let owner = makeOwner(
            callbackStarted: false,
            operations: .recording(into: recorder)
        )

        XCTAssertEqual(owner.teardown(), .complete)
        XCTAssertEqual(recorder.events, ["io", "aggregate", "tap"])
    }

    func testStartAdmittedAfterGraphTeardownFailsWithoutCallingHAL() {
        let lock = NSLock()
        var startCount = 0
        let owner = makeOwner(
            callbackStarted: false,
            operations: .init(
                start: { _, _ in
                    lock.withLock { startCount += 1 }
                    return noErr
                },
                stop: { _, _ in noErr },
                destroyIOProc: { _, _ in noErr },
                destroyAggregate: { _ in noErr },
                destroyTap: { _ in noErr }
            )
        )

        XCTAssertEqual(owner.teardown(), .complete)
        XCTAssertNotEqual(owner.startIOProc(), noErr)
        XCTAssertEqual(lock.withLock { startCount }, 0)
    }

    func testTapOnlyProductionStageDestroysOnlyTap() {
        let recorder = EventRecorder()
        let owner = CoreAudioCaptureResourceOwner(
            operations: .recording(into: recorder),
            routeQueue: DispatchQueue(label: "test.route")
        )
        owner.didCreateTap(11)

        XCTAssertEqual(owner.teardown(), .complete)
        XCTAssertEqual(recorder.events, ["tap"])
    }

    func testTapAndAggregateProductionStagesDestroyInOrder() {
        let recorder = EventRecorder()
        let owner = CoreAudioCaptureResourceOwner(
            operations: .recording(into: recorder),
            routeQueue: DispatchQueue(label: "test.route")
        )
        owner.didCreateTap(11)
        owner.didCreateAggregate(12)

        XCTAssertEqual(owner.teardown(), .complete)
        XCTAssertEqual(recorder.events, ["aggregate", "tap"])
    }

    private func makeOwner(
        callbackStarted: Bool = true,
        includeListener: Bool = false,
        operations: CoreAudioCapturePipelineOperations
    ) -> CoreAudioCaptureResourceOwner {
        let owner = CoreAudioCaptureResourceOwner(
            operations: operations,
            routeQueue: DispatchQueue(label: "test.route")
        )
        if includeListener {
            owner.didInstallOutputListener(deviceID: 13) { _, _ in }
            owner.didInstallOutputListenerAddress(
                propertyAddress(kAudioDevicePropertyDeviceIsAlive)
            )
        }
        owner.didCreateTap(11)
        owner.didCreateAggregate(12)
        owner.didCreateIOProc(pipelineTestIOProc)
        if callbackStarted {
            XCTAssertEqual(owner.startIOProc(), noErr)
        }
        return owner
    }
}

@available(macOS 14.2, *)
private extension CoreAudioCapturePipelineOperations {
    static func recording(into recorder: EventRecorder) -> Self {
        .init(
            start: { _, _ in noErr },
            stop: { _, _ in recorder.events.append("stop"); return noErr },
            destroyIOProc: { _, _ in recorder.events.append("io"); return noErr },
            destroyAggregate: { _ in recorder.events.append("aggregate"); return noErr },
            destroyTap: { _ in recorder.events.append("tap"); return noErr }
        )
    }
}

private final class EventRecorder {
    var events: [String] = []
}
