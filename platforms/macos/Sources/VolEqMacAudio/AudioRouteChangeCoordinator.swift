// SPDX-License-Identifier: MPL-2.0

import Foundation

@MainActor
final class AudioRouteChangeCoordinator {
    private var operationID: UInt64 = 0
    private var task: Task<Void, Never>?
    private var pendingRecheck = false

    var isIdle: Bool { task == nil }

    func signal(
        comparison: @escaping @MainActor () async -> Bool,
        onRecoveryRequired: @escaping @MainActor () -> Void
    ) {
        guard task == nil else {
            pendingRecheck = true
            return
        }

        operationID &+= 1
        let currentID = operationID
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var isInitialComparison = true
            while isCurrent(currentID) {
                let queuedBeforeInitialComparison =
                    isInitialComparison && pendingRecheck
                pendingRecheck = false
                let requiresRecovery = await comparison()
                guard isCurrent(currentID) else { return }
                if requiresRecovery {
                    finish(currentID)
                    onRecoveryRequired()
                    return
                }
                isInitialComparison = false
                guard queuedBeforeInitialComparison || pendingRecheck else {
                    finish(currentID)
                    return
                }
            }
        }
    }

    func cancel() {
        operationID &+= 1
        task?.cancel()
        task = nil
        pendingRecheck = false
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == operationID && !Task.isCancelled
    }

    private func finish(_ candidate: UInt64) {
        guard candidate == operationID else { return }
        task = nil
        pendingRecheck = false
    }
}
