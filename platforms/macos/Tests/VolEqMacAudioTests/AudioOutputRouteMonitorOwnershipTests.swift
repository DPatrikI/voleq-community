// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import XCTest
@testable import VolEqMacAudio

@available(macOS 14.2, *)
@MainActor
final class AudioOutputRouteMonitorOwnershipTests: XCTestCase {
    func testNotificationIngressSchedulesAtMostOneDeliveryAndOneRecheck() async throws {
        var deliveries = 0
        let ingress = AudioRouteChangeSignalCoalescer {
            deliveries += 1
        }

        for _ in 0..<10_000 { ingress.signal() }
        try await waitForAudioCondition("coalesced route delivery") {
            deliveries == 2
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(deliveries, 2)
    }

    func testSustainedNotificationProducerYieldsBetweenBoundedActorTurns() async throws {
        var deliveries = 0
        var deliveriesWhenUnrelatedWorkRan: Int?
        var ingress: AudioRouteChangeSignalCoalescer?
        defer { ingress = nil }
        ingress = AudioRouteChangeSignalCoalescer {
            deliveries += 1
            if deliveries == 1 {
                Task { @MainActor in
                    deliveriesWhenUnrelatedWorkRan = deliveries
                }
            }
            if deliveries < 100 { ingress?.signal() }
        }

        ingress?.signal()
        try await waitForAudioCondition("unrelated main-actor work") {
            deliveriesWhenUnrelatedWorkRan != nil
        }
        XCTAssertLessThan(deliveriesWhenUnrelatedWorkRan ?? Int.max, 100)

        try await waitForAudioCondition("bounded sustained route delivery") {
            deliveries == 100
        }
        XCTAssertEqual(deliveries, 100)
    }

    func testAddAndRemoveOperationsDoNotBlockMainActor() async throws {
        let addEntered = AudioTestFlag()
        let removeEntered = AudioTestFlag()
        let addRelease = DispatchSemaphore(value: 0)
        let removeRelease = DispatchSemaphore(value: 0)
        let monitor = CoreAudioOutputRouteMonitor(operations: .init(
            add: { _, _, _, _ in
                addEntered.set()
                addRelease.wait()
                return noErr
            },
            remove: { _, _, _, _ in
                removeEntered.set()
                removeRelease.wait()
                return noErr
            }
        ))

        let start = Task { try await monitor.start { } }
        try await waitForAudioCondition("blocked route-listener add") {
            addEntered.value
        }
        let mainActorAdvancedDuringAdd = await MainActor.run { true }
        XCTAssertTrue(mainActorAdvancedDuringAdd)
        addRelease.signal()
        try await start.value

        let stop = Task { await monitor.stop() }
        try await waitForAudioCondition("blocked route-listener removal") {
            removeEntered.value
        }
        let mainActorAdvancedDuringRemoval = await MainActor.run { true }
        XCTAssertTrue(mainActorAdvancedDuringRemoval)
        removeRelease.signal()
        let stopReport = await stop.value
        XCTAssertEqual(stopReport, .complete)
    }

    func testFailedRemovalRetainsRegistrationAndRejectsReplacementUntilRetry() async throws {
        var addCount = 0
        var removeStatus: OSStatus = -1
        let monitor = CoreAudioOutputRouteMonitor(operations: .init(
            add: { _, _, _, _ in addCount += 1; return noErr },
            remove: { _, _, _, _ in removeStatus }
        ))

        try await monitor.start { }
        XCTAssertTrue(monitor.isMonitoring)
        let failedRemoval = await monitor.stop()
        XCTAssertFalse(failedRemoval.isComplete)
        XCTAssertTrue(monitor.isMonitoring)
        do {
            try await monitor.start { }
            XCTFail("Expected retained registration to reject replacement")
        } catch { }
        XCTAssertEqual(addCount, 1)

        removeStatus = noErr
        let completedRemoval = await monitor.stop()
        XCTAssertEqual(completedRemoval, .complete)
        XCTAssertFalse(monitor.isMonitoring)
        try await monitor.start { }
        XCTAssertEqual(addCount, 2)
    }
}
