// SPDX-License-Identifier: MPL-2.0

import CoreAudio

@MainActor
final class AudioProcessRefreshCoordinator {
    struct Context {
        let lifecycleGeneration: UInt64
        let currentSelection: AudioObjectID?
        let mode: CaptureMode
        let preservesRecoveryFailure: Bool
        let ownsLifecyclePhase: Bool
    }

    private struct Request {
        let id: UInt64
        let context: Context
        let isLifecycleCurrent: @MainActor () -> Bool
        let onSelectionChanged: @MainActor () -> Void
        let onSucceeded: @MainActor (_ ownsLifecyclePhase: Bool) -> Void
        let onFailed: @MainActor (
            _ error: Error,
            _ ownsLifecyclePhase: Bool
        ) -> Void
    }

    private let processSession: AudioCaptureProcessSession
    private var nextID: UInt64 = 0
    private var activeID: UInt64?
    private var task: Task<Void, Never>?
    private var pendingRequest: Request?

    init(processSession: AudioCaptureProcessSession) {
        self.processSession = processSession
    }

    func schedule(
        context: Context,
        isLifecycleCurrent: @escaping @MainActor () -> Bool,
        onSelectionChanged: @escaping @MainActor () -> Void,
        onSucceeded: @escaping @MainActor (_ ownsLifecyclePhase: Bool) -> Void,
        onFailed: @escaping @MainActor (
            _ error: Error,
            _ ownsLifecyclePhase: Bool
        ) -> Void
    ) {
        nextID &+= 1
        let request = Request(
            id: nextID,
            context: context,
            isLifecycleCurrent: isLifecycleCurrent,
            onSelectionChanged: onSelectionChanged,
            onSucceeded: onSucceeded,
            onFailed: onFailed
        )
        guard task == nil else {
            pendingRequest = request
            task?.cancel()
            return
        }
        begin(request)
    }

    func cancel() {
        nextID &+= 1
        pendingRequest = nil
        task?.cancel()
    }

    private func begin(_ request: Request) {
        activeID = request.id
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finish(request.id) }
            do {
                try await processSession.refresh(
                    currentSelection: request.context.currentSelection,
                    mode: request.context.mode,
                    preservingRecoveryFailure:
                        request.context.preservesRecoveryFailure,
                    isCurrent: { [weak self] in
                        self?.isCurrent(request) == true
                    }
                )
                guard isCurrent(request) else { return }
                request.onSelectionChanged()
                request.onSucceeded(request.context.ownsLifecyclePhase)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(request) else { return }
                request.onFailed(error, request.context.ownsLifecyclePhase)
            }
        }
    }

    private func finish(_ requestID: UInt64) {
        guard activeID == requestID else { return }
        task = nil
        activeID = nil
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        guard pendingRequest.id == nextID else { return }
        begin(pendingRequest)
    }

    private func isCurrent(_ request: Request) -> Bool {
        request.id == nextID
            && request.isLifecycleCurrent()
            && !Task.isCancelled
    }
}
