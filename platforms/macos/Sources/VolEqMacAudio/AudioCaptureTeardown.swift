// SPDX-License-Identifier: MPL-2.0

enum AudioCaptureTeardownStep: Equatable, Sendable {
    case activeOutputListeners
    case finishIOProcStart
    case stopIOProc
    case destroyIOProc
    case destroyAggregate
    case destroyTap

    var diagnosticName: String {
        switch self {
        case .activeOutputListeners: "activeOutputListeners"
        case .finishIOProcStart: "finishIOProcStart"
        case .stopIOProc: "stopIOProc"
        case .destroyIOProc: "destroyIOProc"
        case .destroyAggregate: "destroyAggregate"
        case .destroyTap: "destroyTap"
        }
    }
}

struct AudioCaptureTeardownFailure: Equatable, Sendable {
    let step: AudioCaptureTeardownStep
    let statusCode: Int32?
    let objectID: UInt32?
    let propertySelector: UInt32?
    let propertyScope: UInt32?
    let propertyElement: UInt32?

    init(
        step: AudioCaptureTeardownStep,
        statusCode: Int32? = nil,
        objectID: UInt32? = nil,
        propertySelector: UInt32? = nil,
        propertyScope: UInt32? = nil,
        propertyElement: UInt32? = nil
    ) {
        self.step = step
        self.statusCode = statusCode
        self.objectID = objectID
        self.propertySelector = propertySelector
        self.propertyScope = propertyScope
        self.propertyElement = propertyElement
    }
}

struct AudioCaptureTeardownReport: Equatable, Sendable {
    let unresolvedSteps: [AudioCaptureTeardownStep]
    let failures: [AudioCaptureTeardownFailure]

    init(
        unresolvedSteps: [AudioCaptureTeardownStep],
        failures: [AudioCaptureTeardownFailure] = []
    ) {
        self.unresolvedSteps = unresolvedSteps
        self.failures = failures
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
        return AudioCaptureTeardownReport(
            unresolvedSteps: combinedSteps,
            failures: failures + other.failures
        )
    }
}
