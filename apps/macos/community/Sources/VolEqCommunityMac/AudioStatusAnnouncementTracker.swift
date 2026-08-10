// SPDX-License-Identifier: MPL-2.0

import VolEqMacAudio

struct AudioStatusAnnouncementTracker {
    private var previousState: AudioCaptureStateSnapshot?
    private var restorationIsInFlight = false

    mutating func message(
        for state: AudioCaptureStateSnapshot
    ) -> String? {
        defer { previousState = state }
        guard let previousState else { return nil }
        guard state != previousState else { return nil }
        let current = state.activity

        if current == .recovering {
            restorationIsInFlight = true
            return state.status
        }
        if restorationIsInFlight,
           current == .active
            || (current == .stopped && state.acceptsPrimaryAction) {
            restorationIsInFlight = false
            return state.status
        }
        if restorationIsInFlight,
           current == .stopped,
           !state.acceptsPrimaryAction {
            return nil
        }
        if current == .recoveryFailed || current == .failed {
            restorationIsInFlight = false
        }

        switch current {
        case .suspended, .recoveryFailed, .failed:
            return state.status
        case .stopped, .ready, .preparing, .active, .recovering:
            return nil
        }
    }
}
