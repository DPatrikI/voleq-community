// SPDX-License-Identifier: MPL-2.0

import Foundation
import VolEqSpeech

struct SpeechLevelingGate {
    static let openProbability: Float = 0.65
    static let closeProbability: Float = 0.35
    static let quietOpenProbability: Float = 0.25
    static let quietCloseProbability: Float = 0.10
    static let quietLevelMarginBelowThresholdDB: Float = 9
    static let absoluteSpeechFloorDB: Float = -80
    static let noiseLearningProbability: Float = 0.10
    static let holdSeconds: Float = 0.200
    static let quietHoldSeconds: Float = 0.600
    static let fadeSeconds: Float = 0.150
    static let noiseFloorTimeConstantSeconds: Float = 2
    static let noiseFloorMarginDB: Float = 6
    static let thresholdHeadroomDB: Float = 3

    let sampleRate: Float
    private(set) var isOpen = false
    private(set) var learnedNoiseFloorDB: Float?
    private var closingFrameCount = 0
    private var usesQuietSpeechHold = false

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    mutating func observe(
        _ result: SpeechAnalysisResult,
        fixedNoiseGateDB: Float,
        compressionThresholdDB: Float
    ) -> Float {
        let coveredFrames = max(result.sourceFrameCount, 1)
        let sourcePowerDB = 10 * log10f(max(result.sourcePower, 0.000_000_000_001))

        if result.probability <= Self.noiseLearningProbability {
            let duration = Float(coveredFrames) / sampleRate
            let coefficient = expf(-duration / Self.noiseFloorTimeConstantSeconds)
            if let learnedNoiseFloorDB {
                self.learnedNoiseFloorDB = coefficient * learnedNoiseFloorDB
                    + (1 - coefficient) * sourcePowerDB
            } else {
                learnedNoiseFloorDB = sourcePowerDB
            }
        }

        let effectiveGateDB = effectiveNoiseGateDB(
            fixedNoiseGateDB: fixedNoiseGateDB,
            compressionThresholdDB: compressionThresholdDB
        )
        let isAboveFixedGate = sourcePowerDB >= fixedNoiseGateDB
        let isAboveLearnedGate = sourcePowerDB >= effectiveGateDB
        let adaptiveSpeechGateDB = max(
            Self.absoluteSpeechFloorDB,
            learnedNoiseFloorDB.map { $0 + Self.noiseFloorMarginDB }
                ?? Self.absoluteSpeechFloorDB
        )
        let isAboveAdaptiveSpeechGate = sourcePowerDB >= adaptiveSpeechGateDB
        let isQuiet = sourcePowerDB
            <= compressionThresholdDB - Self.quietLevelMarginBelowThresholdDB
        let isQuietSpeechCandidate = isAboveFixedGate && isQuiet
        let strongSpeechDetected = isAboveAdaptiveSpeechGate
            && result.probability >= Self.openProbability
        let quietSpeechDetected = isQuietSpeechCandidate
            && result.probability >= Self.quietOpenProbability
        let shouldOpen = strongSpeechDetected || quietSpeechDetected
        let shouldRemainOpen = result.probability > Self.closeProbability
            || (
                isQuietSpeechCandidate
                    && result.probability > Self.quietCloseProbability
            )

        if shouldOpen {
            isOpen = true
            usesQuietSpeechHold = isQuietSpeechCandidate
                || (strongSpeechDetected && isQuiet)
            closingFrameCount = 0
        } else if isOpen, shouldRemainOpen {
            if isQuiet && isAboveAdaptiveSpeechGate {
                usesQuietSpeechHold = true
            }
            closingFrameCount = 0
        } else if isOpen {
            closingFrameCount += coveredFrames
            let holdFrames = activeHoldFrameCount
            let fadeFrames = max(Int((Self.fadeSeconds * sampleRate).rounded()), 1)
            if closingFrameCount >= holdFrames + fadeFrames {
                isOpen = false
                usesQuietSpeechHold = false
            }
        }

        let activityEligibility: Float
        if !isOpen {
            activityEligibility = 0
        } else {
            let holdFrames = activeHoldFrameCount
            let fadeFrames = max(Int((Self.fadeSeconds * sampleRate).rounded()), 1)
            let fadeFrameCount = max(closingFrameCount - holdFrames, 0)
            activityEligibility = 1 - min(Float(fadeFrameCount) / Float(fadeFrames), 1)
        }

        let speechEvidenceIsActive = strongSpeechDetected
            || quietSpeechDetected
            || shouldRemainOpen
        let quietSpeechHoldIsActive = isOpen && usesQuietSpeechHold
        let adaptiveSpeechFloorIsActive = strongSpeechDetected
            || (quietSpeechHoldIsActive && !isAboveFixedGate)
        let passesAudibilityGate: Bool
        if adaptiveSpeechFloorIsActive {
            passesAudibilityGate = isAboveAdaptiveSpeechGate
        } else if speechEvidenceIsActive || quietSpeechHoldIsActive {
            passesAudibilityGate = isAboveFixedGate
        } else {
            passesAudibilityGate = isAboveLearnedGate
        }
        return passesAudibilityGate ? activityEligibility : 0
    }

    func effectiveNoiseGateDB(
        fixedNoiseGateDB: Float,
        compressionThresholdDB: Float
    ) -> Float {
        let noiseRelativeGate = learnedNoiseFloorDB.map { $0 + Self.noiseFloorMarginDB }
            ?? fixedNoiseGateDB
        return min(
            max(fixedNoiseGateDB, noiseRelativeGate),
            compressionThresholdDB - Self.thresholdHeadroomDB
        )
    }

    mutating func reset() {
        isOpen = false
        learnedNoiseFloorDB = nil
        closingFrameCount = 0
        usesQuietSpeechHold = false
    }

    private var activeHoldFrameCount: Int {
        let seconds = usesQuietSpeechHold ? Self.quietHoldSeconds : Self.holdSeconds
        return Int((seconds * sampleRate).rounded())
    }
}
