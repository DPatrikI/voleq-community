// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import Foundation

enum AudioCadenceResolution: Equatable {
    case pending
    case resolved(AudioSampleRatePath)
    case failed
}

/// Resolves the effective input/output clock relationship from hardware time.
///
/// Buffer sizes alone are not authoritative: equal frame counts at different
/// rates can describe different durations. Host-time deltas are in one common
/// clock domain, so comparing delivered frames per host tick distinguishes an
/// aggregate tap already synchronized to the output from a route that still
/// needs sample-rate conversion.
struct AudioCallbackCadenceAnalyzer {
    private static let requiredIntervalCount = 3
    private static let maximumObservationCount = 8
    private static let maximumRelativeError = 0.02
    private static let minimumErrorSeparationFraction = 0.5

    private let inputSampleRate: Double
    private let outputSampleRate: Double
    private var previousInputHostTime: UInt64?
    private var previousOutputHostTime: UInt64?
    private var previousInputFrameCount = 0
    private var previousOutputFrameCount = 0
    private var accumulatedInputFrames = 0.0
    private var accumulatedOutputFrames = 0.0
    private var accumulatedInputHostTicks = 0.0
    private var accumulatedOutputHostTicks = 0.0
    private var intervalCount = 0
    private var observationCount = 0

    init(inputSampleRate: Double, outputSampleRate: Double) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
    }

    mutating func observe(
        inputFrameCount: Int,
        inputTime: AudioTimeStamp?,
        outputFrameCount: Int,
        outputTime: AudioTimeStamp?
    ) -> AudioCadenceResolution {
        observationCount += 1
        guard
            let inputHostTime = Self.validHostTime(inputTime),
            let outputHostTime = Self.validHostTime(outputTime)
        else {
            previousInputHostTime = nil
            previousOutputHostTime = nil
            previousInputFrameCount = 0
            previousOutputFrameCount = 0
            return observationCount >= Self.maximumObservationCount ? .failed : .pending
        }

        defer {
            previousInputHostTime = inputHostTime
            previousOutputHostTime = outputHostTime
            previousInputFrameCount = inputFrameCount
            previousOutputFrameCount = outputFrameCount
        }

        guard
            let previousInputHostTime,
            let previousOutputHostTime,
            inputHostTime > previousInputHostTime,
            outputHostTime > previousOutputHostTime,
            previousInputFrameCount > 0,
            previousOutputFrameCount > 0
        else {
            return observationCount >= Self.maximumObservationCount ? .failed : .pending
        }

        accumulatedInputFrames += Double(previousInputFrameCount)
        accumulatedOutputFrames += Double(previousOutputFrameCount)
        accumulatedInputHostTicks += Double(inputHostTime - previousInputHostTime)
        accumulatedOutputHostTicks += Double(outputHostTime - previousOutputHostTime)
        intervalCount += 1

        guard intervalCount >= Self.requiredIntervalCount else { return .pending }
        let observedRateRatio = accumulatedInputFrames * accumulatedOutputHostTicks
            / (accumulatedOutputFrames * accumulatedInputHostTicks)
        let nominalRateRatio = inputSampleRate / outputSampleRate
        let directError = Self.relativeError(observedRateRatio, expected: 1)
        let conversionError = Self.relativeError(
            observedRateRatio,
            expected: nominalRateRatio
        )
        let selectedError = min(directError, conversionError)
        let errorSeparation = abs(directError - conversionError)
        // The two valid answers converge as the nominal rates get closer. Use
        // their actual distance instead of a fixed threshold so a 1 Hz
        // difference remains classifiable without accepting the midpoint.
        let expectedPathSeparation = abs(nominalRateRatio - 1)
            / max(abs(nominalRateRatio), 1)
        let requiredErrorSeparation = expectedPathSeparation
            * Self.minimumErrorSeparationFraction

        guard
            selectedError <= Self.maximumRelativeError,
            errorSeparation >= requiredErrorSeparation
        else {
            return observationCount >= Self.maximumObservationCount ? .failed : .pending
        }
        return .resolved(
            directError < conversionError
                ? .directAggregateClock
                : .sampleRateConverter
        )
    }

    private static func validHostTime(_ timestamp: AudioTimeStamp?) -> UInt64? {
        guard let timestamp else { return nil }
        let hostTimeValid = timestamp.mFlags.contains(.hostTimeValid)
        return hostTimeValid ? timestamp.mHostTime : nil
    }

    private static func relativeError(_ observed: Double, expected: Double) -> Double {
        abs(observed - expected) / max(abs(expected), 0.000_001)
    }
}
