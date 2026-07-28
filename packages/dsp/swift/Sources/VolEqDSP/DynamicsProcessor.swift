// SPDX-License-Identifier: MPL-2.0

import Foundation
import VolEqCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A platform-neutral linked-stereo speech leveler followed by a safety limiter.
///
/// Loud signals are compressed downward while audible quiet signals are compressed
/// upward. A small quiet-priority bias can intentionally make quiet-origin speech
/// meter slightly louder, which more closely matches its perceived prominence.
public final class DynamicsProcessor: @unchecked Sendable {
    private struct RuntimeParameters: Sendable {
        let settings: LevelingSettings
        let attackCoefficient: Float
        let releaseCoefficient: Float
        let detectorAttackCoefficient: Float
        let detectorReleaseCoefficient: Float
        let limiterAmplitude: Float
    }

    private let sampleRate: Float
    private let parameterLock = NSLock()
    private var sharedParameters: RuntimeParameters
    /// Only the audio callback mutates these values after initialization.
    private var realtimeParameters: RuntimeParameters
    private var powerEnvelope: Float = 0
    private var smoothedGain: Float = 1

    public init(sampleRate: Double, settings: LevelingSettings = LevelingSettings()) {
        let rate = Self.normalizedSampleRate(sampleRate)
        let parameters = Self.makeRuntimeParameters(settings: settings, sampleRate: rate)
        self.sampleRate = rate
        sharedParameters = parameters
        realtimeParameters = parameters
    }

    public var settings: LevelingSettings {
        parameterLock.lock()
        defer { parameterLock.unlock() }
        return sharedParameters.settings
    }

    /// Called outside the real-time audio thread.
    public func updateSettings(_ settings: LevelingSettings) {
        let parameters = Self.makeRuntimeParameters(settings: settings, sampleRate: sampleRate)
        parameterLock.lock()
        sharedParameters = parameters
        parameterLock.unlock()
    }

    /// Picks up a UI settings change without blocking the real-time audio thread.
    /// Call once before processing a new audio buffer.
    public func beginAudioBuffer() {
        guard parameterLock.try() else { return }
        realtimeParameters = sharedParameters
        parameterLock.unlock()
    }

    /// Processes one linked-stereo frame with the current real-time parameter snapshot.
    public func processFrame(left: Float, right: Float) -> (left: Float, right: Float) {
        let gain = gain(left: left, right: right, parameters: realtimeParameters)
        let framePeak = max(abs(left), abs(right))
        let limiterGain = framePeak > 0
            ? min(gain, realtimeParameters.limiterAmplitude / framePeak)
            : gain
        return (left * limiterGain, right * limiterGain)
    }

    /// Returns the gain for one linked-stereo frame. Internal for deterministic tests.
    func gain(left: Float, right: Float) -> Float {
        parameterLock.lock()
        realtimeParameters = sharedParameters
        parameterLock.unlock()
        return gain(left: left, right: right, parameters: realtimeParameters)
    }

    private func gain(left: Float, right: Float, parameters: RuntimeParameters) -> Float {
        let settings = parameters.settings
        let framePower = (left * left + right * right) * 0.5
        let detectorCoefficient = framePower > powerEnvelope
            ? parameters.detectorAttackCoefficient
            : parameters.detectorReleaseCoefficient
        powerEnvelope = detectorCoefficient * powerEnvelope
            + (1 - detectorCoefficient) * framePower

        let inputDB = 10 * log10f(max(powerEnvelope, 0.000_000_000_001))
        var shapedDB = inputDB
        if inputDB > settings.thresholdDB {
            shapedDB = settings.thresholdDB
                + (inputDB - settings.thresholdDB) / settings.compressorRatio
        } else if inputDB < settings.noiseGateDB {
            shapedDB = settings.noiseGateDB
                + (inputDB - settings.noiseGateDB) * settings.expanderRatio
        } else {
            let upwardTargetDB = settings.thresholdDB
                + (inputDB - settings.thresholdDB) / settings.quietCompressionRatio
            let upwardBoostDB = max(0, upwardTargetDB - inputDB)

            let gateOpen = smoothstep(
                min(max((inputDB - settings.noiseGateDB) / 12, 0), 1)
            )
            let quietDepth = smoothstep(
                min(max((settings.thresholdDB - inputDB) / 18, 0), 1)
            )
            let quietBiasDB = settings.quietPriorityDB * quietDepth
            shapedDB = inputDB + (upwardBoostDB + quietBiasDB) * gateOpen
        }

        let desiredGain = powf(10, (shapedDB - inputDB + settings.makeupGainDB) / 20)
        let gainCoefficient = desiredGain < smoothedGain
            ? parameters.attackCoefficient
            : parameters.releaseCoefficient
        smoothedGain = gainCoefficient * smoothedGain + (1 - gainCoefficient) * desiredGain
        return smoothedGain
    }

    private static func makeRuntimeParameters(
        settings: LevelingSettings,
        sampleRate: Float
    ) -> RuntimeParameters {
        let settings = settings.normalized()
        return RuntimeParameters(
            settings: settings,
            attackCoefficient: coefficient(seconds: settings.attackSeconds, sampleRate: sampleRate),
            releaseCoefficient: coefficient(seconds: settings.releaseSeconds, sampleRate: sampleRate),
            detectorAttackCoefficient: coefficient(
                seconds: settings.detectorAttackSeconds,
                sampleRate: sampleRate
            ),
            detectorReleaseCoefficient: coefficient(
                seconds: settings.detectorReleaseSeconds,
                sampleRate: sampleRate
            ),
            limiterAmplitude: powf(10, settings.limiterDB / 20)
        )
    }

    private static func coefficient(seconds: Float, sampleRate: Float) -> Float {
        expf(-1 / (seconds * sampleRate))
    }

    private static func normalizedSampleRate(_ sampleRate: Double) -> Float {
        guard
            sampleRate.isFinite,
            sampleRate >= 1,
            sampleRate <= Double(Float.greatestFiniteMagnitude)
        else {
            return 48_000
        }
        return Float(sampleRate)
    }

    private func smoothstep(_ value: Float) -> Float {
        value * value * (3 - 2 * value)
    }
}
