// SPDX-License-Identifier: MPL-2.0

import Foundation
import VolEqSpeech

struct SpeechLevelingGate {
    static let openProbability: Float = 0.65
    static let closeProbability: Float = 0.35
    static let noiseLearningProbability: Float = 0.20
    static let holdSeconds: Float = 0.200
    static let fadeSeconds: Float = 0.150
    static let noiseFloorTimeConstantSeconds: Float = 2
    static let noiseFloorMarginDB: Float = 6
    static let thresholdHeadroomDB: Float = 3

    let sampleRate: Float
    private(set) var isOpen = false
    private(set) var learnedNoiseFloorDB: Float?
    private var closingFrameCount = 0

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

        if result.probability >= Self.openProbability {
            isOpen = true
            closingFrameCount = 0
        } else if isOpen, result.probability > Self.closeProbability {
            closingFrameCount = 0
        } else if isOpen {
            closingFrameCount += coveredFrames
            let holdFrames = Int((Self.holdSeconds * sampleRate).rounded())
            let fadeFrames = max(Int((Self.fadeSeconds * sampleRate).rounded()), 1)
            if closingFrameCount >= holdFrames + fadeFrames {
                isOpen = false
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

        let noiseRelativeGate = learnedNoiseFloorDB.map { $0 + Self.noiseFloorMarginDB }
            ?? fixedNoiseGateDB
        let effectiveGateDB = min(
            max(fixedNoiseGateDB, noiseRelativeGate),
            compressionThresholdDB - Self.thresholdHeadroomDB
        )
        return sourcePowerDB >= effectiveGateDB ? activityEligibility : 0
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
    }
}
