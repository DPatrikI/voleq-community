// SPDX-License-Identifier: MPL-2.0

enum AudioCaptureTeardownStep: Equatable, Sendable {
    case activeOutputListeners
    case finishPlaybackActivityWatcher
    case finishIOProcStart
    case stopIOProc
    case destroyIOProc
    case destroyAggregate
    case destroyTap
}

struct AudioCaptureTeardownReport: Equatable, Sendable {
    let unresolvedSteps: [AudioCaptureTeardownStep]
    init(unresolvedSteps: [AudioCaptureTeardownStep]) {
        self.unresolvedSteps = unresolvedSteps
    }

    static let complete = AudioCaptureTeardownReport(unresolvedSteps: [])

    var isComplete: Bool { unresolvedSteps.isEmpty }

    /// Listener callbacks are generation-gated and their ownership ledger is
    /// retained for process lifetime when Core Audio refuses removal. Once the
    /// callback, aggregate, and tap are gone, an orphaned route listener cannot
    /// mute audio or access freed callback state, so a replacement graph is safe.
    var permitsReplacementPipeline: Bool {
        unresolvedSteps.allSatisfy { $0 == .activeOutputListeners }
    }

    func merging(
        _ other: AudioCaptureTeardownReport
    ) -> AudioCaptureTeardownReport {
        var combinedSteps = unresolvedSteps
        for step in other.unresolvedSteps where !combinedSteps.contains(step) {
            combinedSteps.append(step)
        }
        return AudioCaptureTeardownReport(unresolvedSteps: combinedSteps)
    }
}
