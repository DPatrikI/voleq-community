// SPDX-License-Identifier: MPL-2.0

import AppKit
import XCTest
@testable import VolEqCommunityMac

@MainActor
final class WorkspaceLifecycleForwarderTests: XCTestCase {
    func testSleepAndWakeForwardAudioAndUpdatesIndependently() {
        let center = NotificationCenter()
        var sleepCount = 0
        var audioWakeCount = 0
        var updateWakeCount = 0
        let forwarder = WorkspaceLifecycleForwarder(
            notificationCenter: center,
            prepareAudioForSleep: { sleepCount += 1 },
            resumeAudioAfterWake: { audioWakeCount += 1 },
            updateApplicationActivatedOrWoke: { updateWakeCount += 1 }
        )
        forwarder.start()

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(sleepCount, 1)
        XCTAssertEqual(audioWakeCount, 1)
        XCTAssertEqual(updateWakeCount, 1)

        forwarder.applicationActivated()
        XCTAssertEqual(audioWakeCount, 2)
        XCTAssertEqual(updateWakeCount, 2)
    }

    func testStartingForwarderTwiceDoesNotDuplicateSubscriptions() {
        let center = NotificationCenter()
        var sleepCount = 0
        var audioWakeCount = 0
        var updateWakeCount = 0
        let forwarder = WorkspaceLifecycleForwarder(
            notificationCenter: center,
            prepareAudioForSleep: { sleepCount += 1 },
            resumeAudioAfterWake: { audioWakeCount += 1 },
            updateApplicationActivatedOrWoke: { updateWakeCount += 1 }
        )
        forwarder.start()
        forwarder.start()

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(sleepCount, 1)
        XCTAssertEqual(audioWakeCount, 1)
        XCTAssertEqual(updateWakeCount, 1)
    }
}
