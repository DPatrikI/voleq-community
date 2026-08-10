// SPDX-License-Identifier: MPL-2.0

struct CaptureLifecycleStateMachine {
    private(set) var snapshot = AudioCaptureLifecycleSnapshot(
        phase: .stopped,
        status: "Choose an audio-producing app, then start."
    )

    var phase: CaptureLifecyclePhase { snapshot.phase }

    private mutating func transition(
        to phase: CaptureLifecyclePhase,
        status: String
    ) -> AudioCaptureLifecycleSnapshot {
        let next = AudioCaptureLifecycleSnapshot(phase: phase, status: status)
        snapshot = next
        return next
    }

    mutating func updateStatus(
        _ status: String
    ) -> AudioCaptureLifecycleSnapshot {
        transition(to: phase, status: status)
    }

    mutating func apply(
        event: CaptureLifecycleEvent,
        status: String
    ) -> (
        directive: CaptureLifecycleDirective,
        published: AudioCaptureLifecycleSnapshot?
    ) {
        let directive = CaptureLifecycleReducer.reduce(
            phase: phase,
            event: event
        )
        guard let nextPhase = resultingPhase(for: directive) else {
            return (directive, nil)
        }
        return (directive, transition(to: nextPhase, status: status))
    }

    private func resultingPhase(
        for directive: CaptureLifecycleDirective
    ) -> CaptureLifecyclePhase? {
        switch directive {
        case let .beginRetry(intent):
            .recovering(intent, .userRetry)
        case let .stop(intent):
            .stopping(intent)
        case let .sleep(intent):
            .suspending(intent)
        case let .recover(intent, reason):
            .recovering(intent, reason)
        case .refreshReadyStatus:
            .ready
        case let .transition(phase):
            phase
        case .ignore, .beginStart, .queueWake, .cancelQueuedWake:
            nil
        }
    }
}
