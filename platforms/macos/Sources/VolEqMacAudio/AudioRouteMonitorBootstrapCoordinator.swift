// SPDX-License-Identifier: MPL-2.0

@MainActor
final class AudioRouteMonitorBootstrapCoordinator {
    private var operationID: UInt64 = 0
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func start(
        install: @escaping @MainActor () async throws -> Void,
        onSuccess: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        cancel()
        operationID &+= 1
        let currentID = operationID
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await install()
                guard isCurrent(currentID) else { return }
                task = nil
                onSuccess()
            } catch {
                guard isCurrent(currentID) else { return }
                task = nil
                onFailure(error)
            }
        }
    }

    func cancel() {
        operationID &+= 1
        task?.cancel()
        task = nil
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == operationID && !Task.isCancelled
    }
}
