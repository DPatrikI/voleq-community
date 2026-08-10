// SPDX-License-Identifier: MPL-2.0

enum AudioCaptureTeardownStep: Equatable, Sendable {
    case activeOutputListeners
    case finishIOProcStart
    case stopIOProc
    case destroyIOProc
    case destroyAggregate
    case destroyTap
}

struct AudioCaptureTeardownReport: Equatable, Sendable {
    let unresolvedSteps: [AudioCaptureTeardownStep]

    static let complete = AudioCaptureTeardownReport(unresolvedSteps: [])

    var isComplete: Bool { unresolvedSteps.isEmpty }
}
