// SPDX-License-Identifier: MPL-2.0

import Foundation

final class AudioRouteChangeSignalCoalescer: @unchecked Sendable {
    private static let maximumDeliveriesPerActorTurn = 2
    private let lock = NSLock()
    private var deliveryScheduled = false
    private var pendingRecheck = false
    private let deliver: @MainActor @Sendable () -> Void

    init(deliver: @escaping @MainActor @Sendable () -> Void) {
        self.deliver = deliver
    }

    func signal() {
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !deliveryScheduled else {
                pendingRecheck = true
                return false
            }
            deliveryScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.drain()
        }
    }

    @MainActor
    private func drain() {
        for deliveryIndex in 0..<Self.maximumDeliveriesPerActorTurn {
            deliver()
            let shouldDeliverAgain = lock.withLock { () -> Bool in
                guard pendingRecheck else {
                    deliveryScheduled = false
                    return false
                }
                pendingRecheck = false
                return true
            }
            if !shouldDeliverAgain { return }
            if deliveryIndex == Self.maximumDeliveriesPerActorTurn - 1 {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.drain()
                }
                return
            }
        }
    }
}
