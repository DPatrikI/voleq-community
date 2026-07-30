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
/// meter slightly louder, which more closely matches its perceived prominence. A
/// preallocated delay line gives the detector time to lower gain before a loud onset
/// reaches the output.
public final class DynamicsProcessor: @unchecked Sendable {
    private struct RuntimeParameters: Sendable {
        let settings: LevelingSettings
        let attackCoefficient: Float
        let releaseCoefficient: Float
        let detectorAttackCoefficient: Float
        let detectorReleaseCoefficient: Float
        let limiterAmplitude: Float
        let lookaheadFrameCount: Int
    }

    private struct GainDecision {
        let smoothedGain: Float
        let maximumGain: Float
    }

    private let sampleRate: Float
    private let parameterLock = NSLock()
    private var sharedParameters: RuntimeParameters
    /// Only the audio callback mutates these values after initialization.
    private var realtimeParameters: RuntimeParameters
    private var powerEnvelope: Float = 0
    private var smoothedGain: Float = 1
    private var delayedLeft: [Float]
    private var delayedRight: [Float]
    private var delayedMaximumGain: [Float]
    private var delayWriteIndex = 0
    private var delayedFrameCount = 0
    private var activeLookaheadFrameCount: Int

    public init(sampleRate: Double, settings: LevelingSettings = LevelingSettings()) {
        let rate = Self.normalizedSampleRate(sampleRate)
        let parameters = Self.makeRuntimeParameters(settings: settings, sampleRate: rate)
        self.sampleRate = rate
        sharedParameters = parameters
        realtimeParameters = parameters
        activeLookaheadFrameCount = parameters.lookaheadFrameCount
        let maximumLookaheadFrameCount = max(
            Int((rate * 0.050).rounded(.up)),
            1
        )
        delayedLeft = Array(repeating: 0, count: maximumLookaheadFrameCount)
        delayedRight = Array(repeating: 0, count: maximumLookaheadFrameCount)
        delayedMaximumGain = Array(
            repeating: Float.greatestFiniteMagnitude,
            count: maximumLookaheadFrameCount
        )
    }

    public var settings: LevelingSettings {
        parameterLock.lock()
        defer { parameterLock.unlock() }
        return sharedParameters.settings
    }

    /// The algorithmic delay introduced by the current lookahead setting.
    /// Read this from a control or diagnostics thread; the getter takes the settings
    /// lock and is intentionally not part of the real-time processing API.
    public var latencyFrameCount: Int {
        parameterLock.lock()
        defer { parameterLock.unlock() }
        return sharedParameters.lookaheadFrameCount
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
        let parameters = sharedParameters
        parameterLock.unlock()

        if parameters.lookaheadFrameCount != activeLookaheadFrameCount {
            resetRealtimeState(lookaheadFrameCount: parameters.lookaheadFrameCount)
        }
        realtimeParameters = parameters
    }

    /// Clears detector, gain, and lookahead history while audio processing is stopped.
    /// A rebuilt output route creates a new processor and therefore starts in this state.
    public func reset() {
        parameterLock.lock()
        let parameters = sharedParameters
        realtimeParameters = parameters
        parameterLock.unlock()
        resetRealtimeState(lookaheadFrameCount: parameters.lookaheadFrameCount)
    }

    /// Processes one linked-stereo frame with the current real-time parameter snapshot.
    public func processFrame(left: Float, right: Float) -> (left: Float, right: Float) {
        let gainDecision = analyzedGain(left: left, right: right, parameters: realtimeParameters)
        let delayedFrame = delay(
            left: left,
            right: right,
            maximumGain: gainDecision.maximumGain
        )
        return apply(
            gain: min(gainDecision.smoothedGain, delayedFrame.maximumGain),
            left: delayedFrame.left,
            right: delayedFrame.right,
            parameters: realtimeParameters
        )
    }

    private func apply(
        gain: Float,
        left: Float,
        right: Float,
        parameters: RuntimeParameters
    ) -> (left: Float, right: Float) {
        let framePeak = max(abs(left), abs(right))
        let limiterGain = framePeak > 0
            ? min(gain, parameters.limiterAmplitude / framePeak)
            : gain
        return (left * limiterGain, right * limiterGain)
    }

    /// Returns the gain for one linked-stereo frame. Internal for deterministic tests.
    func gain(left: Float, right: Float) -> Float {
        parameterLock.lock()
        realtimeParameters = sharedParameters
        parameterLock.unlock()
        return analyzedGain(
            left: left,
            right: right,
            parameters: realtimeParameters
        ).smoothedGain
    }

    private func analyzedGain(
        left: Float,
        right: Float,
        parameters: RuntimeParameters
    ) -> GainDecision {
        let settings = parameters.settings
        let framePower = (left * left + right * right) * 0.5
        let detectorCoefficient = framePower > powerEnvelope
            ? parameters.detectorAttackCoefficient
            : parameters.detectorReleaseCoefficient
        powerEnvelope = detectorCoefficient * powerEnvelope
            + (1 - detectorCoefficient) * framePower

        let inputDB = 10 * log10f(max(powerEnvelope, 0.000_000_000_001))
        let desiredGain = gainForDetectedLevel(inputDB, settings: settings)
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
        return GainDecision(smoothedGain: smoothedGain, maximumGain: maximumGain)
    }

    private func gainForDetectedLevel(
        _ inputDB: Float,
        settings: LevelingSettings
    ) -> Float {
        let shapedDB: Float
        if inputDB > settings.thresholdDB {
            return gainForLoudLevel(inputDB, settings: settings)
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

        return powf(10, (shapedDB - inputDB + settings.makeupGainDB) / 20)
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

    private func delay(
        left: Float,
        right: Float,
        maximumGain: Float
    ) -> (left: Float, right: Float, maximumGain: Float) {
        let lookaheadFrameCount = activeLookaheadFrameCount
        guard lookaheadFrameCount > 0 else { return (left, right, maximumGain) }

        if delayedFrameCount < lookaheadFrameCount {
            delayedLeft[delayWriteIndex] = left
            delayedRight[delayWriteIndex] = right
            delayedMaximumGain[delayWriteIndex] = maximumGain
            delayWriteIndex += 1
            if delayWriteIndex == lookaheadFrameCount {
                delayWriteIndex = 0
            }
            delayedFrameCount += 1
            return (0, 0, Float.greatestFiniteMagnitude)
        }

        let output = (
            left: delayedLeft[delayWriteIndex],
            right: delayedRight[delayWriteIndex],
            maximumGain: delayedMaximumGain[delayWriteIndex]
        )
        delayedLeft[delayWriteIndex] = left
        delayedRight[delayWriteIndex] = right
        delayedMaximumGain[delayWriteIndex] = maximumGain
        delayWriteIndex += 1
        if delayWriteIndex == lookaheadFrameCount {
            delayWriteIndex = 0
        }
        return output
    }

    private func resetRealtimeState(lookaheadFrameCount: Int) {
        powerEnvelope = 0
        smoothedGain = 1
        delayWriteIndex = 0
        delayedFrameCount = 0
        activeLookaheadFrameCount = lookaheadFrameCount
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
            limiterAmplitude: powf(10, settings.limiterDB / 20),
            lookaheadFrameCount: Int((settings.lookaheadSeconds * sampleRate).rounded())
        )
    }

    private static func coefficient(seconds: Float, sampleRate: Float) -> Float {
        expf(-1 / (seconds * sampleRate))
    }

    private static func normalizedSampleRate(_ sampleRate: Double) -> Float {
        guard
            sampleRate.isFinite,
            sampleRate >= 1,
            sampleRate <= 768_000
        else {
            return 48_000
        }
        return Float(sampleRate)
    }

    private func smoothstep(_ value: Float) -> Float {
        value * value * (3 - 2 * value)
    }
}
