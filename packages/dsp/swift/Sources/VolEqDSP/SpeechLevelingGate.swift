// SPDX-License-Identifier: MPL-2.0

import Foundation
import VolEqSpeech

struct SpeechLevelingGate {
    static let openProbability: Float = 0.65
    static let quietOpenProbability: Float = 0.90
    static let closeProbability: Float = 0.35
    static let quietLevelMarginBelowThresholdDB: Float = 9
    static let quietOpeningConfirmationSeconds: Float = 0.020
    static let absoluteSpeechFloorDB: Float = -80
    static let noiseLearningProbability: Float = 0.20
    static let holdSeconds: Float = 0.200
    static let fadeSeconds: Float = 0.150
    static let noiseFloorTimeConstantSeconds: Float = 2
    static let noiseFloorMarginDB: Float = 6
    static let thresholdHeadroomDB: Float = 3

    let sampleRate: Float
    private(set) var isOpen = false
    private(set) var learnedNoiseFloorDB: Float?
    private(set) var openingBackfillSourceFrameCount = 0
    private var closingFrameCount = 0
    private var quietOpeningFrameCount = 0
    private var isQuietUtterance = false

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    mutating func observe(
        _ result: SpeechAnalysisResult,
        fixedNoiseGateDB: Float,
        compressionThresholdDB: Float
    ) -> Float {
        openingBackfillSourceFrameCount = 0
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
        let regularSpeechDetected = !isQuiet
            && isAboveFixedGate
            && result.probability >= Self.openProbability
        let quietSpeechCandidate = isQuiet
            && isAboveAdaptiveSpeechGate
            && result.probability >= Self.quietOpenProbability
        let shouldRemainOpen = result.probability > Self.closeProbability

        if !isOpen {
            if regularSpeechDetected {
                isOpen = true
                isQuietUtterance = false
                quietOpeningFrameCount = 0
                closingFrameCount = 0
            } else if quietSpeechCandidate {
                quietOpeningFrameCount += coveredFrames
                let confirmationFrames = max(
                    Int((Self.quietOpeningConfirmationSeconds * sampleRate).rounded()),
                    coveredFrames
                )
                if quietOpeningFrameCount >= confirmationFrames {
                    isOpen = true
                    isQuietUtterance = true
                    openingBackfillSourceFrameCount = quietOpeningFrameCount
                    quietOpeningFrameCount = 0
                    closingFrameCount = 0
                }
            } else {
                quietOpeningFrameCount = 0
            }
        } else if regularSpeechDetected || quietSpeechCandidate || shouldRemainOpen {
            if isQuiet && isAboveAdaptiveSpeechGate {
                isQuietUtterance = true
            }
            closingFrameCount = 0
        } else {
            closingFrameCount += coveredFrames
            let holdFrames = Int((Self.holdSeconds * sampleRate).rounded())
            let fadeFrames = max(Int((Self.fadeSeconds * sampleRate).rounded()), 1)
            if closingFrameCount >= holdFrames + fadeFrames {
                isOpen = false
                isQuietUtterance = false
            }
        }

        let activityEligibility: Float
        if !isOpen {
            activityEligibility = 0
        } else {
            let holdFrames = Int((Self.holdSeconds * sampleRate).rounded())
            let fadeFrames = max(Int((Self.fadeSeconds * sampleRate).rounded()), 1)
            let fadeFrameCount = max(closingFrameCount - holdFrames, 0)
            activityEligibility = 1 - min(Float(fadeFrameCount) / Float(fadeFrames), 1)
        }

        let speechEvidenceIsActive = regularSpeechDetected
            || quietSpeechCandidate
            || shouldRemainOpen
        let passesAudibilityGate: Bool
        if isOpen && isQuietUtterance {
            passesAudibilityGate = isAboveFixedGate || isAboveAdaptiveSpeechGate
        } else if speechEvidenceIsActive {
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
        openingBackfillSourceFrameCount = 0
        closingFrameCount = 0
        quietOpeningFrameCount = 0
        isQuietUtterance = false
    }
}
