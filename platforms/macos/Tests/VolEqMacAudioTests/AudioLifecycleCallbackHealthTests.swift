// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VolEqMacAudio

private final class CallbackHealthTestTime:
    AudioLifecycleClock,
    AudioLifecycleScheduling,
    @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    private var sleepCount = 0
    private let onSleep: @Sendable (Int) -> Void

    init(onSleep: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.onSleep = onSleep
    }

    func nowNanoseconds() -> UInt64 { lock.withLock { now } }

    func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        let count = lock.withLock {
            now += nanoseconds
            sleepCount += 1
            return sleepCount
        }
        onSleep(count)
        await Task.yield()
        try Task.checkCancellation()
    }
}

@available(macOS 14.2, *)
@MainActor
final class AudioLifecycleCallbackHealthTests: XCTestCase {
    func testProductionMonitorTimesOutStartupAtTwoSecondsWithoutProgress() async throws {
        let time = CallbackHealthTestTime()
        let heartbeat = try AudioCallbackHeartbeat()
        let monitor = AudioCallbackHealthMonitor(clock: time, scheduler: time)

        let progressed = await monitor.waitForInitialProgress(
            heartbeat: heartbeat,
            initialCount: heartbeat.callbackCount,
            isCurrent: { true }
        )

        XCTAssertFalse(progressed)
        XCTAssertEqual(time.nowNanoseconds(), 2_000_000_000)
    }

    func testProductionMonitorAcceptsStartupOnlyAfterHeartbeatProgress() async throws {
        let heartbeat = try AudioCallbackHeartbeat()
        let time = CallbackHealthTestTime { count in
            if count == 2 { heartbeat.recordCallback() }
        }
        let monitor = AudioCallbackHealthMonitor(clock: time, scheduler: time)

        let progressed = await monitor.waitForInitialProgress(
            heartbeat: heartbeat,
            initialCount: heartbeat.callbackCount,
            isCurrent: { true }
        )

        XCTAssertTrue(progressed)
        XCTAssertEqual(time.nowNanoseconds(), 500_000_000)
    }

    func testProductionWatchdogResetsOnProgressAndNotifiesOnceAfterTwoSecondStall() async throws {
        let heartbeat = try AudioCallbackHeartbeat()
        let time = CallbackHealthTestTime { count in
            if count == 2 { heartbeat.recordCallback() }
        }
        let monitor = AudioCallbackHealthMonitor(clock: time, scheduler: time)
        var stallCount = 0

        monitor.startWatchdog(
            heartbeat: heartbeat,
            isCurrent: { true },
            onStall: { stallCount += 1 }
        )
        try await waitForAudioCondition("single callback stall") {
            stallCount == 1
        }
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(stallCount, 1)
        XCTAssertEqual(time.nowNanoseconds(), 2_500_000_000)
    }

    func testInitialCallbackProgressIsRequiredBeforeActive() async {
        let rig = AudioCaptureTestRig()
        rig.healthMonitors.configure = { $0.initialProgress = false }
        let controller = rig.makeController()
        controller.mode = .system

        controller.start()
        await waitForRuntimeState(controller, .failed)

        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(rig.pipelines.pipelines.first?.stopCount, 1)
        XCTAssertTrue(controller.status.contains("callbacks did not begin"))
    }

    func testCallbackProgressPublishesActiveAndStartsWatchdog() async {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system

        controller.start()
        await waitForRuntimeState(controller, .active)

        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(rig.healthMonitors.monitors.count, 1)
    }

    func testSingleStallStartsOneSafeRecoveryAttempt() async {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        guard let monitor = rig.healthMonitors.monitors.first else {
            return XCTFail("Expected an active callback-health monitor")
        }
        monitor.triggerStall()
        monitor.triggerStall()
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(rig.routeGate.initialDelays.count, 1)
        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
    }

    func testStoppedMonitorCannotActivateStaleRecovery() async {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)
        guard let monitor = rig.healthMonitors.monitors.first else {
            return XCTFail("Expected an active callback-health monitor")
        }

        controller.stop()
        monitor.triggerStall()
        await Task.yield()

        XCTAssertEqual(controller.runtimeState, .stopped)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }

}
