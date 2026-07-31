// SPDX-License-Identifier: MPL-2.0

import Foundation
import VolEqCore
import VolEqSpeech

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors raised while preparing speech-aware leveling outside the audio callback.
public enum DynamicsProcessorError: Error, Equatable, LocalizedError {
    case analyzerSampleRateMismatch(expected: Double, actual: Double)
    case invalidAnalyzerConfiguration
    case analysisLatencyExceedsCapacity(latencyFrames: Int, capacityFrames: Int)

    public var errorDescription: String? {
        switch self {
        case let .analyzerSampleRateMismatch(expected, actual):
            return "Speech analyzer sample rate mismatch (expected \(expected), got \(actual))."
        case .invalidAnalyzerConfiguration:
            return "The speech analyzer reported an invalid block size or latency."
        case let .analysisLatencyExceedsCapacity(latencyFrames, capacityFrames):
            return "Speech-analysis latency of \(latencyFrames) frames exceeds the \(capacityFrames)-frame delay capacity."
        }
    }
}

/// A platform-neutral linked-stereo speech leveler followed by a safety limiter.
///
/// Loud signals are compressed downward while audible quiet speech is compressed
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
        let speechGainRiseCoefficient: Float
        let limiterAmplitude: Float
        let lookaheadFrameCount: Int
    }

    private struct GainDecision {
        let smoothedGain: Float
        let maximumGain: Float
    }

    private let sampleRate: Float
    private let speechAnalyzer: (any SpeechAnalyzing)?
    private let appliesSpeechLeveling: Bool
    private let minimumLookaheadFrameCount: Int
    private let fixedSpeechLookaheadSeconds: Float?
    private let parameterLock = NSLock()
    private var sharedParameters: RuntimeParameters
    /// Only the audio callback mutates these values after initialization.
    private var realtimeParameters: RuntimeParameters
    private var powerEnvelope: Float = 0
    private var smoothedGain: Float = 1
    private var smoothedSpeechOutputGain: Float = 1
    private var delayedLeft: [Float]
    private var delayedRight: [Float]
    private var delayedMaximumGain: [Float]
    private var delayedUpwardEligibility: [Float]
    private var delayWriteIndex = 0
    private var delayedFrameCount = 0
    private var activeLookaheadFrameCount: Int
    private var currentUpwardEligibility: Float
    private var speechGate: SpeechLevelingGate
    private var processingFailed = false
    private var analysisLeftBlock: [Float]
    private var analysisRightBlock: [Float]
    private var analysisBlockFrameCount = 0

    public convenience init(sampleRate: Double, settings: LevelingSettings = LevelingSettings()) {
        self.init(
            sampleRate: sampleRate,
            settings: settings,
            speechAnalyzer: nil,
            appliesSpeechLeveling: false,
            minimumLookaheadFrameCount: 0
        )
    }

    /// Creates a processor whose delay timeline is aligned with prepared speech analysis.
    ///
    /// The resulting lookahead is fixed for the lifetime of this instance. Rebuild the
    /// processor and analyzer together to change latency.
    public convenience init(
        sampleRate: Double,
        settings: LevelingSettings = LevelingSettings(),
        speechAnalyzer: any SpeechAnalyzing
    ) throws {
        try self.init(
            sampleRate: sampleRate,
            settings: settings,
            speechAnalyzer: speechAnalyzer,
            appliesSpeechLeveling: true
        )
    }

    convenience init(
        sampleRate: Double,
        settings: LevelingSettings = LevelingSettings(),
        speechAnalyzer: any SpeechAnalyzing,
        appliesSpeechLeveling: Bool
    ) throws {
        let rate = Self.normalizedSampleRate(sampleRate)
        let maximumLookaheadFrameCount = max(Int((rate * 0.050).rounded(.up)), 1)
        guard speechAnalyzer.sourceBlockFrameCount > 0,
              speechAnalyzer.analysisLatencyFrameCount >= 0 else {
            throw DynamicsProcessorError.invalidAnalyzerConfiguration
        }
        guard abs(speechAnalyzer.sourceSampleRate - Double(rate)) < 0.5 else {
            throw DynamicsProcessorError.analyzerSampleRateMismatch(
                expected: Double(rate),
                actual: speechAnalyzer.sourceSampleRate
            )
        }
        guard speechAnalyzer.analysisLatencyFrameCount <= maximumLookaheadFrameCount else {
            throw DynamicsProcessorError.analysisLatencyExceedsCapacity(
                latencyFrames: speechAnalyzer.analysisLatencyFrameCount,
                capacityFrames: maximumLookaheadFrameCount
            )
        }
        self.init(
            sampleRate: sampleRate,
            settings: settings,
            speechAnalyzer: speechAnalyzer,
            appliesSpeechLeveling: appliesSpeechLeveling,
            minimumLookaheadFrameCount: speechAnalyzer.analysisLatencyFrameCount
        )
    }

    private init(
        sampleRate: Double,
        settings: LevelingSettings,
        speechAnalyzer: (any SpeechAnalyzing)?,
        appliesSpeechLeveling: Bool,
        minimumLookaheadFrameCount: Int
    ) {
        let rate = Self.normalizedSampleRate(sampleRate)
        let maximumLookaheadFrameCount = max(Int((rate * 0.050).rounded(.up)), 1)
        let parameters = Self.makeRuntimeParameters(
            settings: settings,
            sampleRate: rate,
            minimumLookaheadFrameCount: minimumLookaheadFrameCount
        )
        self.sampleRate = rate
        self.speechAnalyzer = speechAnalyzer
        self.appliesSpeechLeveling = appliesSpeechLeveling && speechAnalyzer != nil
        self.minimumLookaheadFrameCount = minimumLookaheadFrameCount
        fixedSpeechLookaheadSeconds = speechAnalyzer == nil
            ? nil
            : parameters.settings.lookaheadSeconds
        sharedParameters = parameters
        realtimeParameters = parameters
        activeLookaheadFrameCount = parameters.lookaheadFrameCount
        currentUpwardEligibility = self.appliesSpeechLeveling ? 0 : 1
        speechGate = SpeechLevelingGate(sampleRate: rate)
        let analysisBlockCapacity = speechAnalyzer?.sourceBlockFrameCount ?? 1
        analysisLeftBlock = Array(repeating: 0, count: analysisBlockCapacity)
        analysisRightBlock = Array(repeating: 0, count: analysisBlockCapacity)
        delayedLeft = Array(repeating: 0, count: maximumLookaheadFrameCount)
        delayedRight = Array(repeating: 0, count: maximumLookaheadFrameCount)
        delayedMaximumGain = Array(
            repeating: Float.greatestFiniteMagnitude,
            count: maximumLookaheadFrameCount
        )
        delayedUpwardEligibility = Array(
            repeating: self.appliesSpeechLeveling ? 0 : 1,
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
    ///
    /// For speech-aware instances, `lookaheadSeconds` remains at its construction-time
    /// value so analyzer metadata cannot become misaligned with delayed audio. Rebuild
    /// the processor and analyzer together to change latency. Other settings update.
    public func updateSettings(_ settings: LevelingSettings) {
        var effectiveSettings = settings
        if let fixedSpeechLookaheadSeconds {
            // Analyzer history and delayed eligibility are one aligned timeline.
            // Rebuild the processor to change speech-aware latency.
            effectiveSettings.lookaheadSeconds = fixedSpeechLookaheadSeconds
        }
        let parameters = Self.makeRuntimeParameters(
            settings: effectiveSettings,
            sampleRate: sampleRate,
            minimumLookaheadFrameCount: minimumLookaheadFrameCount
        )
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
        speechAnalyzer?.reset()
    }

    /// Processes one linked-stereo frame with the current real-time parameter snapshot.
    public func processFrame(left: Float, right: Float) -> (left: Float, right: Float) {
        guard !processingFailed, left.isFinite, right.isFinite else {
            processingFailed = true
            return (0, 0)
        }
        analyzeSpeech(left: left, right: right, parameters: realtimeParameters)
        guard !processingFailed else { return (0, 0) }

        let gainDecision = analyzedGain(left: left, right: right, parameters: realtimeParameters)
        let delayedFrame = delay(
            left: left,
            right: right,
            maximumGain: gainDecision.maximumGain,
            upwardEligibility: currentUpwardEligibility
        )
        let constrainedGain = min(gainDecision.smoothedGain, delayedFrame.maximumGain)
        let eligibleGain = constrainedGain > 1
            ? 1 + (constrainedGain - 1) * delayedFrame.upwardEligibility
            : constrainedGain
        let outputGain = smoothedSpeechGain(
            target: eligibleGain,
            upwardEligibility: delayedFrame.upwardEligibility,
            parameters: realtimeParameters
        )
        return apply(
            gain: outputGain,
            left: delayedFrame.left,
            right: delayedFrame.right,
            parameters: realtimeParameters
        )
    }

    /// Reports a fatal callback-thread processing state. It remains latched until reset.
    public func consumeProcessingFailure() -> Bool {
        processingFailed
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
        let desiredGain = gainForDetectedLevel(
            inputDB,
            settings: settings,
            upwardEligibility: currentUpwardEligibility > 0 ? 1 : 0
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
        return GainDecision(smoothedGain: smoothedGain, maximumGain: maximumGain)
    }

    private func gainForDetectedLevel(
        _ inputDB: Float,
        settings: LevelingSettings,
        upwardEligibility: Float = 1
    ) -> Float {
        let shapedDB: Float
        if inputDB > settings.thresholdDB {
            return gainForLoudLevel(inputDB, settings: settings)
        } else if appliesSpeechLeveling, upwardEligibility <= 0 {
            let noiseGateDB = effectiveNoiseGateDB(settings: settings)
            guard speechGate.learnedNoiseFloorDB != nil, inputDB < noiseGateDB else {
                return 1
            }
            shapedDB = noiseGateDB
                + (inputDB - noiseGateDB) * settings.expanderRatio
        } else if !appliesSpeechLeveling,
                  inputDB < effectiveNoiseGateDB(settings: settings) {
            let noiseGateDB = effectiveNoiseGateDB(settings: settings)
            shapedDB = noiseGateDB
                + (inputDB - noiseGateDB) * settings.expanderRatio
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

    private func delay(
        left: Float,
        right: Float,
        maximumGain: Float,
        upwardEligibility: Float
    ) -> (left: Float, right: Float, maximumGain: Float, upwardEligibility: Float) {
        let lookaheadFrameCount = activeLookaheadFrameCount
        guard lookaheadFrameCount > 0 else {
            return (left, right, maximumGain, upwardEligibility)
        }

        if delayedFrameCount < lookaheadFrameCount {
            delayedLeft[delayWriteIndex] = left
            delayedRight[delayWriteIndex] = right
            delayedMaximumGain[delayWriteIndex] = maximumGain
            delayedUpwardEligibility[delayWriteIndex] = upwardEligibility
            delayWriteIndex += 1
            if delayWriteIndex == lookaheadFrameCount {
                delayWriteIndex = 0
            }
            delayedFrameCount += 1
            return (0, 0, Float.greatestFiniteMagnitude, 0)
        }

        let output = (
            left: delayedLeft[delayWriteIndex],
            right: delayedRight[delayWriteIndex],
            maximumGain: delayedMaximumGain[delayWriteIndex],
            upwardEligibility: delayedUpwardEligibility[delayWriteIndex]
        )
        delayedLeft[delayWriteIndex] = left
        delayedRight[delayWriteIndex] = right
        delayedMaximumGain[delayWriteIndex] = maximumGain
        delayedUpwardEligibility[delayWriteIndex] = upwardEligibility
        delayWriteIndex += 1
        if delayWriteIndex == lookaheadFrameCount {
            delayWriteIndex = 0
        }
        return output
    }

    private func resetRealtimeState(lookaheadFrameCount: Int) {
        powerEnvelope = 0
        smoothedGain = 1
        smoothedSpeechOutputGain = 1
        currentUpwardEligibility = appliesSpeechLeveling ? 0 : 1
        speechGate.reset()
        processingFailed = false
        analysisBlockFrameCount = 0
        delayWriteIndex = 0
        delayedFrameCount = 0
        activeLookaheadFrameCount = lookaheadFrameCount
    }

    private static func makeRuntimeParameters(
        settings: LevelingSettings,
        sampleRate: Float,
        minimumLookaheadFrameCount: Int = 0
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
            speechGainRiseCoefficient: coefficient(seconds: 0.030, sampleRate: sampleRate),
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

    private func effectiveNoiseGateDB(settings: LevelingSettings) -> Float {
        guard appliesSpeechLeveling else { return settings.noiseGateDB }
        return speechGate.effectiveNoiseGateDB(
            fixedNoiseGateDB: settings.noiseGateDB,
            compressionThresholdDB: settings.thresholdDB
        )
    }

    private func analyzeSpeech(
        left: Float,
        right: Float,
        parameters: RuntimeParameters
    ) {
        guard let speechAnalyzer else { return }
        analysisLeftBlock[analysisBlockFrameCount] = left
        analysisRightBlock[analysisBlockFrameCount] = right
        analysisBlockFrameCount += 1
        guard analysisBlockFrameCount == analysisLeftBlock.count else { return }
        analysisBlockFrameCount = 0

        var leftPower: Float = 0
        var rightPower: Float = 0
        var midPower: Float = 0
        for index in analysisLeftBlock.indices {
            let blockLeft = analysisLeftBlock[index]
            let blockRight = analysisRightBlock[index]
            let mid = (blockLeft + blockRight) * 0.5
            leftPower += blockLeft * blockLeft
            rightPower += blockRight * blockRight
            midPower += mid * mid
        }
        let dominantPower = max(leftPower, rightPower)
        let useCoherentDownmix = midPower >= dominantPower * 0.1
        let useLeftChannel = leftPower >= rightPower

        for index in analysisLeftBlock.indices {
            let mono: Float
            if useCoherentDownmix {
                mono = (analysisLeftBlock[index] + analysisRightBlock[index]) * 0.5
            } else {
                mono = useLeftChannel ? analysisLeftBlock[index] : analysisRightBlock[index]
            }
            handleSpeechEvent(
                speechAnalyzer.processMonoSample(mono),
                parameters: parameters
            )
            if processingFailed { return }
        }
    }

    private func handleSpeechEvent(
        _ event: SpeechAnalysisEvent,
        parameters: RuntimeParameters
    ) {
        switch event {
        case .pending:
            return
        case .failed:
            processingFailed = true
        case let .result(result):
            guard result.probability.isFinite,
                  (0...1).contains(result.probability),
                  result.sourcePower.isFinite,
                  result.sourcePower >= 0,
                  result.sourceFrameCount > 0,
                  result.analysisLatencyFrameCount >= result.sourceFrameCount,
                  result.analysisLatencyFrameCount <= activeLookaheadFrameCount else {
                processingFailed = true
                return
            }
            guard appliesSpeechLeveling else { return }
            let eligibility = speechGate.observe(
                result,
                fixedNoiseGateDB: parameters.settings.noiseGateDB,
                compressionThresholdDB: parameters.settings.thresholdDB
            )
            currentUpwardEligibility = eligibility
            backfillEligibility(
                eligibility,
                analysisLatencyFrameCount: result.analysisLatencyFrameCount
            )

        }
    }

    private func smoothedSpeechGain(
        target: Float,
        upwardEligibility: Float,
        parameters: RuntimeParameters
    ) -> Float {
        guard appliesSpeechLeveling else { return target }
        guard target >= 1 else {
            smoothedSpeechOutputGain = 1
            return target
        }
        guard upwardEligibility > 0 else {
            smoothedSpeechOutputGain = 1
            return 1
        }
        guard target > smoothedSpeechOutputGain else {
            smoothedSpeechOutputGain = target
            return target
        }
        smoothedSpeechOutputGain = parameters.speechGainRiseCoefficient
            * smoothedSpeechOutputGain
            + (1 - parameters.speechGainRiseCoefficient) * target
        return min(smoothedSpeechOutputGain, target)
    }

    private func backfillEligibility(
        _ eligibility: Float,
        analysisLatencyFrameCount: Int
    ) {
        let oldestCoveredFrameAge = analysisLatencyFrameCount - 1
        guard oldestCoveredFrameAge > 0, delayedFrameCount > 0 else { return }

        // The result applies to its covered block and remains the newest known
        // gate state through the resampler-latency gap up to the current frame.
        let firstAge = 1
        let lastAge = min(oldestCoveredFrameAge, delayedFrameCount)
        guard firstAge <= lastAge else { return }
        for age in firstAge...lastAge {
            let index = (delayWriteIndex - age + activeLookaheadFrameCount)
                % activeLookaheadFrameCount
            delayedUpwardEligibility[index] = eligibility
        }
    }
}
