// SPDX-License-Identifier: MPL-2.0

import Foundation
import VolEqCore

struct DynamicsGainDecision {
    let smoothedGain: Float
    let maximumGain: Float
}

struct DynamicsGainDetector {
    private var powerEnvelope: Float = 0
    private(set) var smoothedGain: Float = 1

    mutating func analyze(
        left: Float,
        right: Float,
        parameters: DynamicsRuntimeParameters,
        appliesSpeechLeveling: Bool,
        upwardEligibility: Float,
        effectiveNoiseGateDB: Float,
        hasLearnedNoiseFloor: Bool
    ) -> DynamicsGainDecision {
        let settings = parameters.settings
        let framePower = (left * left + right * right) * 0.5
        let detectorCoefficient = framePower > powerEnvelope
            ? parameters.detectorAttackCoefficient
            : parameters.detectorReleaseCoefficient
        powerEnvelope = detectorCoefficient * powerEnvelope
            + (1 - detectorCoefficient) * framePower

        let inputDB = 10 * log10f(max(powerEnvelope, 0.000_000_000_001))
        let gainEligibility: Float = upwardEligibility > 0 ? 1 : 0
        let desiredGain = gainForDetectedLevel(
            inputDB,
            settings: settings,
            appliesSpeechLeveling: appliesSpeechLeveling,
            upwardEligibility: gainEligibility,
            effectiveNoiseGateDB: effectiveNoiseGateDB,
            hasLearnedNoiseFloor: hasLearnedNoiseFloor
        )
        let gainCoefficient = desiredGain < smoothedGain
            ? parameters.attackCoefficient
            : parameters.releaseCoefficient
        smoothedGain = gainCoefficient * smoothedGain + (1 - gainCoefficient) * desiredGain

        // The detector envelope is intentionally smooth, but a future peak must be
        // allowed to lower gain immediately. Its cap travels with the delayed frame,
        // so release smoothing cannot recover before that peak reaches the output.
        // Protection cannot raise gain, and the final limiter remains the last guard.
        var maximumGain = Float.greatestFiniteMagnitude
        let futurePeak = max(abs(left), abs(right))
        if futurePeak > 0 {
            let futurePeakDB = 20 * log10f(futurePeak)
            if futurePeakDB > settings.thresholdDB {
                let protectiveGain = min(
                    gainForLoudLevel(futurePeakDB, settings: settings),
                    parameters.limiterAmplitude / futurePeak
                )
                smoothedGain = min(smoothedGain, protectiveGain)
                maximumGain = protectiveGain
            }
        }
        return DynamicsGainDecision(
            smoothedGain: smoothedGain,
            maximumGain: maximumGain
        )
    }

    mutating func reset() {
        powerEnvelope = 0
        smoothedGain = 1
    }

    private func gainForDetectedLevel(
        _ inputDB: Float,
        settings: LevelingSettings,
        appliesSpeechLeveling: Bool,
        upwardEligibility: Float,
        effectiveNoiseGateDB: Float,
        hasLearnedNoiseFloor: Bool
    ) -> Float {
        let shapedDB: Float
        if inputDB > settings.thresholdDB {
            return gainForLoudLevel(inputDB, settings: settings)
        } else if appliesSpeechLeveling, upwardEligibility <= 0 {
            guard hasLearnedNoiseFloor, inputDB < effectiveNoiseGateDB else { return 1 }
            shapedDB = effectiveNoiseGateDB
                + (inputDB - effectiveNoiseGateDB) * settings.expanderRatio
        } else if !appliesSpeechLeveling, inputDB < effectiveNoiseGateDB {
            shapedDB = effectiveNoiseGateDB
                + (inputDB - effectiveNoiseGateDB) * settings.expanderRatio
        } else {
            let upwardTargetDB = settings.thresholdDB
                + (inputDB - settings.thresholdDB) / settings.quietCompressionRatio
            let upwardBoostDB = max(0, upwardTargetDB - inputDB)
            let gateOpen: Float = appliesSpeechLeveling
                ? 1
                : smoothstep(min(max((inputDB - settings.noiseGateDB) / 12, 0), 1))
            let quietDepth = smoothstep(
                min(max((settings.thresholdDB - inputDB) / 18, 0), 1)
            )
            let quietBiasDB = settings.quietPriorityDB * quietDepth
            shapedDB = inputDB
                + (upwardBoostDB + quietBiasDB) * gateOpen * upwardEligibility
        }

        let makeupGainDB = settings.makeupGainDB * upwardEligibility
        return powf(10, (shapedDB - inputDB + makeupGainDB) / 20)
    }

    private func gainForLoudLevel(
        _ inputDB: Float,
        settings: LevelingSettings
    ) -> Float {
        let distanceAboveThreshold = inputDB - settings.thresholdDB
        let reductionProgress = smoothstep(
            min(max(distanceAboveThreshold / 12, 0), 1)
        )
        let additionalReductionDB = settings.loudReductionDB * reductionProgress
        let shapedDB = settings.thresholdDB
            + distanceAboveThreshold / settings.compressorRatio
            - additionalReductionDB
        return powf(10, (shapedDB - inputDB + settings.makeupGainDB) / 20)
    }

    private func smoothstep(_ value: Float) -> Float {
        value * value * (3 - 2 * value)
    }
}
