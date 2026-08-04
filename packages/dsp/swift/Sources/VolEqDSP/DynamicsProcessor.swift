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

/// Supplies a real-time-safe, conservative permission for upward leveling.
///
/// Implementations may use slower platform analysis to distinguish speech from
/// music, but this property must remain allocation-free and non-blocking because
/// the audio callback reads it once per speech-analysis block.
public protocol UpwardGainAuthorizing: AnyObject, Sendable {
    var allowsUpwardGain: Bool { get }
}

/// A platform-neutral linked-stereo speech leveler followed by a safety limiter.
///
/// Loud signals are compressed downward while audible quiet speech is compressed
/// upward. A small quiet-priority bias can intentionally make quiet-origin speech
/// meter slightly louder, which more closely matches its perceived prominence. A
/// preallocated delay line gives the detector time to lower gain before a loud onset
/// reaches the output.
public final class DynamicsProcessor: @unchecked Sendable {
    private let sampleRate: Float
    private let appliesSpeechLeveling: Bool
    private let minimumLookaheadFrameCount: Int
    private let fixedSpeechLookaheadSeconds: Float?
    private let parameterLock = NSLock()
    private var sharedParameters: DynamicsRuntimeParameters
    /// Only the audio callback mutates these values after initialization.
    private var realtimeParameters: DynamicsRuntimeParameters
    private let speechCoordinator: SpeechDynamicsCoordinator
    private var gainDetector: DynamicsGainDetector
    private let lookaheadBuffer: DynamicsLookaheadBuffer
    private var suppressionMixer = DynamicsSuppressionMixer()
    private var smoothedSpeechOutputGain: Float = 1
    private var sourceFrameIndex: Int64 = -1
    private var processingFailed = false

    public convenience init(sampleRate: Double, settings: LevelingSettings = LevelingSettings()) {
        self.init(
            sampleRate: sampleRate,
            settings: settings,
            speechAnalyzer: nil,
            stereoSpeechProcessor: nil,
            upwardGainAuthorizer: nil,
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
        speechAnalyzer: any SpeechAnalyzing,
        upwardGainAuthorizer: (any UpwardGainAuthorizing)? = nil
    ) throws {
        try self.init(
            sampleRate: sampleRate,
            settings: settings,
            speechAnalyzer: speechAnalyzer,
            upwardGainAuthorizer: upwardGainAuthorizer,
            appliesSpeechLeveling: true
        )
    }

    /// Creates a processor whose stereo RNNoise output shares the delay timeline.
    public convenience init(
        sampleRate: Double,
        settings: LevelingSettings = LevelingSettings(),
        stereoSpeechProcessor: any StereoSpeechProcessing,
        upwardGainAuthorizer: (any UpwardGainAuthorizing)? = nil
    ) throws {
        let rate = Self.normalizedSampleRate(sampleRate)
        let maximumLookaheadFrameCount = max(Int((rate * 0.050).rounded(.up)), 1)
        guard stereoSpeechProcessor.sourceBlockFrameCount > 0,
              stereoSpeechProcessor.decisionLatencyFrameCount
                >= stereoSpeechProcessor.sourceBlockFrameCount,
              stereoSpeechProcessor.processingLatencyFrameCount
                >= stereoSpeechProcessor.decisionLatencyFrameCount else {
            throw DynamicsProcessorError.invalidAnalyzerConfiguration
        }
        guard abs(stereoSpeechProcessor.sourceSampleRate - Double(rate)) < 0.5 else {
            throw DynamicsProcessorError.analyzerSampleRateMismatch(
                expected: Double(rate),
                actual: stereoSpeechProcessor.sourceSampleRate
            )
        }
        guard stereoSpeechProcessor.processingLatencyFrameCount <= maximumLookaheadFrameCount else {
            throw DynamicsProcessorError.analysisLatencyExceedsCapacity(
                latencyFrames: stereoSpeechProcessor.processingLatencyFrameCount,
                capacityFrames: maximumLookaheadFrameCount
            )
        }
        self.init(
            sampleRate: sampleRate,
            settings: settings,
            speechAnalyzer: nil,
            stereoSpeechProcessor: stereoSpeechProcessor,
            upwardGainAuthorizer: upwardGainAuthorizer,
            appliesSpeechLeveling: true,
            minimumLookaheadFrameCount: stereoSpeechProcessor.processingLatencyFrameCount
        )
    }

    convenience init(
        sampleRate: Double,
        settings: LevelingSettings = LevelingSettings(),
        speechAnalyzer: any SpeechAnalyzing,
        upwardGainAuthorizer: (any UpwardGainAuthorizing)? = nil,
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
            stereoSpeechProcessor: nil,
            upwardGainAuthorizer: upwardGainAuthorizer,
            appliesSpeechLeveling: appliesSpeechLeveling,
            minimumLookaheadFrameCount: speechAnalyzer.analysisLatencyFrameCount
        )
    }

    private init(
        sampleRate: Double,
        settings: LevelingSettings,
        speechAnalyzer: (any SpeechAnalyzing)?,
        stereoSpeechProcessor: (any StereoSpeechProcessing)?,
        upwardGainAuthorizer: (any UpwardGainAuthorizing)?,
        appliesSpeechLeveling: Bool,
        minimumLookaheadFrameCount: Int
    ) {
        let rate = Self.normalizedSampleRate(sampleRate)
        let maximumLookaheadFrameCount = max(Int((rate * 0.050).rounded(.up)), 1)
        let parameters = DynamicsRuntimeParameters.make(
            settings: settings,
            sampleRate: rate,
            minimumLookaheadFrameCount: minimumLookaheadFrameCount
        )
        let effectiveSpeechLeveling = appliesSpeechLeveling
            && (speechAnalyzer != nil || stereoSpeechProcessor != nil)
        self.sampleRate = rate
        self.appliesSpeechLeveling = effectiveSpeechLeveling
        self.minimumLookaheadFrameCount = minimumLookaheadFrameCount
        self.fixedSpeechLookaheadSeconds = speechAnalyzer == nil && stereoSpeechProcessor == nil
            ? nil
            : parameters.settings.lookaheadSeconds
        self.sharedParameters = parameters
        self.realtimeParameters = parameters
        self.speechCoordinator = SpeechDynamicsCoordinator(
            sampleRate: rate,
            speechAnalyzer: speechAnalyzer,
            stereoSpeechProcessor: stereoSpeechProcessor,
            upwardGainAuthorizer: upwardGainAuthorizer,
            appliesSpeechLeveling: effectiveSpeechLeveling,
            analysisBlockCapacity: speechAnalyzer?.sourceBlockFrameCount ?? 1
        )
        self.gainDetector = DynamicsGainDetector()
        let lookaheadBuffer = DynamicsLookaheadBuffer(
            maximumFrameCount: maximumLookaheadFrameCount,
            initialUpwardEligibility: effectiveSpeechLeveling ? 0 : 1
        )
        lookaheadBuffer.reset(activeLookaheadFrameCount: parameters.lookaheadFrameCount)
        self.lookaheadBuffer = lookaheadBuffer
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
        let parameters = DynamicsRuntimeParameters.make(
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

        if parameters.lookaheadFrameCount != lookaheadBuffer.activeLookaheadFrameCount {
            resetRealtimeState(lookaheadFrameCount: parameters.lookaheadFrameCount)
        }
        realtimeParameters = parameters
    }

#if DEBUG
    /// Test-only proof that the callback snapshot uses `try()` and never waits.
    package func _testOnlyWithParameterLockHeld<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        parameterLock.lock()
        defer { parameterLock.unlock() }
        return try body()
    }
#endif

    /// Clears detector, gain, and lookahead history while audio processing is stopped.
    /// A rebuilt output route creates a new processor and therefore starts in this state.
    public func reset() {
        parameterLock.lock()
        let parameters = sharedParameters
        realtimeParameters = parameters
        parameterLock.unlock()
        resetRealtimeState(lookaheadFrameCount: parameters.lookaheadFrameCount)
        speechCoordinator.resetAnalyzers()
    }

    /// Processes one linked-stereo frame with the current real-time parameter snapshot.
    public func processFrame(left: Float, right: Float) -> (left: Float, right: Float) {
        let maximumSafeInputAmplitude = sqrtf(Float.greatestFiniteMagnitude * 0.25)
        guard !processingFailed,
              left.isFinite,
              right.isFinite,
              abs(left) <= maximumSafeInputAmplitude,
              abs(right) <= maximumSafeInputAmplitude else {
            processingFailed = true
            return (0, 0)
        }
        sourceFrameIndex += 1
        guard speechCoordinator.analyze(
            left: left,
            right: right,
            sourceFrameIndex: sourceFrameIndex,
            parameters: realtimeParameters,
            lookaheadBuffer: lookaheadBuffer
        ) else {
            processingFailed = true
            return (0, 0)
        }

        let gainDecision = gainDetector.analyze(
            left: left,
            right: right,
            parameters: realtimeParameters,
            appliesSpeechLeveling: appliesSpeechLeveling,
            upwardEligibility: speechCoordinator.currentUpwardEligibility,
            effectiveNoiseGateDB: speechCoordinator.effectiveNoiseGateDB(
                settings: realtimeParameters.settings
            ),
            hasLearnedNoiseFloor: speechCoordinator.hasLearnedNoiseFloor
        )
        let delayedFrame = lookaheadBuffer.delay(
            left: left,
            right: right,
            maximumGain: gainDecision.maximumGain,
            upwardEligibility: speechCoordinator.currentUpwardEligibility,
            sourceFrameIndex: sourceFrameIndex
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
        let suppressed = suppressionMixer.mix(delayedFrame, parameters: realtimeParameters)
        guard !suppressed.failed else {
            processingFailed = true
            return (0, 0)
        }
        return apply(
            gain: outputGain,
            left: suppressed.left,
            right: suppressed.right,
            parameters: realtimeParameters
        )
    }

    /// Reports a fatal callback-thread processing state. It remains latched until reset.
    public func consumeProcessingFailure() -> Bool {
        processingFailed
    }

    /// Returns the gain for one linked-stereo frame. Internal for deterministic tests.
    func gain(left: Float, right: Float) -> Float {
        parameterLock.lock()
        realtimeParameters = sharedParameters
        parameterLock.unlock()
        return gainDetector.analyze(
            left: left,
            right: right,
            parameters: realtimeParameters,
            appliesSpeechLeveling: appliesSpeechLeveling,
            upwardEligibility: speechCoordinator.currentUpwardEligibility,
            effectiveNoiseGateDB: speechCoordinator.effectiveNoiseGateDB(
                settings: realtimeParameters.settings
            ),
            hasLearnedNoiseFloor: speechCoordinator.hasLearnedNoiseFloor
        ).smoothedGain
    }

    private func apply(
        gain: Float,
        left: Float,
        right: Float,
        parameters: DynamicsRuntimeParameters
    ) -> (left: Float, right: Float) {
        let framePeak = max(abs(left), abs(right))
        let limiterGain = framePeak > 0
            ? min(gain, parameters.limiterAmplitude / framePeak)
            : gain
        return (left * limiterGain, right * limiterGain)
    }

    private func resetRealtimeState(lookaheadFrameCount: Int) {
        gainDetector.reset()
        smoothedSpeechOutputGain = 1
        suppressionMixer.reset()
        speechCoordinator.resetRealtimeState()
        sourceFrameIndex = -1
        processingFailed = false
        lookaheadBuffer.reset(activeLookaheadFrameCount: lookaheadFrameCount)
    }

    private func smoothedSpeechGain(
        target: Float,
        upwardEligibility: Float,
        parameters: DynamicsRuntimeParameters
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
}
