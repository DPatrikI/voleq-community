// SPDX-License-Identifier: MPL-2.0

import Foundation
import VolEqCore

struct DynamicsRuntimeParameters: Sendable {
    let settings: LevelingSettings
    let attackCoefficient: Float
    let releaseCoefficient: Float
    let detectorAttackCoefficient: Float
    let detectorReleaseCoefficient: Float
    let speechGainRiseCoefficient: Float
    let suppressionAttackStep: Float
    let suppressionReleaseStep: Float
    let limiterAmplitude: Float
    let lookaheadFrameCount: Int

    static func make(
        settings: LevelingSettings,
        sampleRate: Float,
        minimumLookaheadFrameCount: Int = 0
    ) -> DynamicsRuntimeParameters {
        let settings = settings.normalized()
        return DynamicsRuntimeParameters(
            settings: settings,
            attackCoefficient: coefficient(
                seconds: settings.attackSeconds,
                sampleRate: sampleRate
            ),
            releaseCoefficient: coefficient(
                seconds: settings.releaseSeconds,
                sampleRate: sampleRate
            ),
            detectorAttackCoefficient: coefficient(
                seconds: settings.detectorAttackSeconds,
                sampleRate: sampleRate
            ),
            detectorReleaseCoefficient: coefficient(
                seconds: settings.detectorReleaseSeconds,
                sampleRate: sampleRate
            ),
            speechGainRiseCoefficient: coefficient(seconds: 0.030, sampleRate: sampleRate),
            suppressionAttackStep: 0.5 / max(0.030 * sampleRate, 1),
            suppressionReleaseStep: 0.5 / max(0.100 * sampleRate, 1),
            limiterAmplitude: powf(10, settings.limiterDB / 20),
            lookaheadFrameCount: max(
                Int((settings.lookaheadSeconds * sampleRate).rounded()),
                minimumLookaheadFrameCount
            )
        )
    }

    private static func coefficient(seconds: Float, sampleRate: Float) -> Float {
        expf(-1 / (seconds * sampleRate))
    }
}
