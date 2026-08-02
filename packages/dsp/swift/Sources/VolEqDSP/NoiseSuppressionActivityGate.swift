// SPDX-License-Identifier: MPL-2.0

import Foundation
import VolEqSpeech

/// Speech activity for suppression only. Its mix envelope supplies release, so
/// this gate deliberately does not inherit leveling's hold and eligibility fade.
struct NoiseSuppressionActivityGate {
    private var isOpen = false
    private var quietOpeningFrameCount = 0

    mutating func observe(
        _ result: SpeechAnalysisResult,
        sampleRate: Float,
        fixedNoiseGateDB: Float,
        compressionThresholdDB: Float,
        learnedNoiseFloorDB: Float?
    ) -> Bool {
        let coveredFrames = max(result.sourceFrameCount, 1)
        let sourcePowerDB = 10 * log10f(max(result.sourcePower, 0.000_000_000_001))
        let adaptiveGateDB = max(
            SpeechLevelingGate.absoluteSpeechFloorDB,
            learnedNoiseFloorDB.map { $0 + SpeechLevelingGate.noiseFloorMarginDB }
                ?? SpeechLevelingGate.absoluteSpeechFloorDB
        )
        let isQuiet = sourcePowerDB
            <= compressionThresholdDB - SpeechLevelingGate.quietLevelMarginBelowThresholdDB
        let regularSpeech = !isQuiet
            && sourcePowerDB >= fixedNoiseGateDB
            && result.probability >= SpeechLevelingGate.openProbability
        let quietSpeech = isQuiet
            && sourcePowerDB >= adaptiveGateDB
            && result.probability >= SpeechLevelingGate.quietOpenProbability

        if isOpen {
            if !(regularSpeech || quietSpeech || result.probability > SpeechLevelingGate.closeProbability) {
                isOpen = false
            }
        } else if regularSpeech {
            isOpen = true
            quietOpeningFrameCount = 0
        } else if quietSpeech {
            quietOpeningFrameCount += coveredFrames
            let requiredFrames = max(
                Int((SpeechLevelingGate.quietOpeningConfirmationSeconds * sampleRate).rounded()),
                coveredFrames
            )
            if quietOpeningFrameCount >= requiredFrames {
                isOpen = true
                quietOpeningFrameCount = 0
            }
        } else {
            quietOpeningFrameCount = 0
        }
        return isOpen
    }

    mutating func reset() {
        isOpen = false
        quietOpeningFrameCount = 0
    }
}
