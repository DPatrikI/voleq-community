// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VolEqMacAudio

private final class SuspendedRouteComparisons: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var continuations: [Int: CheckedContinuation<Bool, Never>] = [:]

    var count: Int { lock.withLock { nextID } }

    func compare() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock {
                nextID += 1
                continuations[nextID] = continuation
            }
        }
    }

    func complete(_ id: Int, requiresRecovery: Bool) {
        lock.withLock { continuations.removeValue(forKey: id) }?
            .resume(returning: requiresRecovery)
    }
}

@MainActor
final class AudioRouteChangeCoordinatorTests: XCTestCase {
    func testCancelledComparisonCannotEraseNewOperationOwnership() async throws {
        let comparisons = SuspendedRouteComparisons()
        let coordinator = AudioRouteChangeCoordinator()
        var recoveries = 0

        coordinator.signal(
            comparison: { await comparisons.compare() },
            onRecoveryRequired: { recoveries += 1 }
        )
        try await waitForAudioCondition("first comparison") {
            comparisons.count == 1
        }
        coordinator.cancel()
        coordinator.signal(
            comparison: { await comparisons.compare() },
            onRecoveryRequired: { recoveries += 1 }
        )
        try await waitForAudioCondition("replacement comparison") {
            comparisons.count == 2
        }

        comparisons.complete(1, requiresRecovery: true)
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<1_000 {
            coordinator.signal(
                comparison: { await comparisons.compare() },
                onRecoveryRequired: { recoveries += 1 }
            )
        }
        XCTAssertEqual(comparisons.count, 2)

        comparisons.complete(2, requiresRecovery: false)
        try await waitForAudioCondition("single pending recheck") {
            comparisons.count == 3
        }
        comparisons.complete(3, requiresRecovery: false)
        try await waitForAudioCondition("comparison coordinator idle") {
            coordinator.isIdle
        }

        XCTAssertEqual(recoveries, 0)
        XCTAssertEqual(comparisons.count, 3)
    }
}
