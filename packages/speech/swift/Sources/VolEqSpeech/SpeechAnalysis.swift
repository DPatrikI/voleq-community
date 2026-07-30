// SPDX-License-Identifier: MPL-2.0

/// The result of analyzing one source-time audio interval.
public struct SpeechAnalysisResult: Sendable, Equatable {
    /// RNNoise voice-activity probability normalized to the closed range 0...1.
    public let probability: Float

    /// Mean-square power of the source samples before analysis resampling.
    public let sourcePower: Float

    /// Number of source-rate mono frames represented by this result.
    public let sourceFrameCount: Int

    /// Source-rate frames between the oldest covered input and availability.
    public let analysisLatencyFrameCount: Int

    public init(
        probability: Float,
        sourcePower: Float,
        sourceFrameCount: Int,
        analysisLatencyFrameCount: Int
    ) {
        self.probability = probability
        self.sourcePower = sourcePower
        self.sourceFrameCount = sourceFrameCount
        self.analysisLatencyFrameCount = analysisLatencyFrameCount
    }
}

/// A non-allocating result returned while feeding prepared analysis state.
public enum SpeechAnalysisEvent: Sendable, Equatable {
    case pending
    case result(SpeechAnalysisResult)
    case failed
}

/// Prepared, stateful, mono speech analysis suitable for deterministic injection.
///
/// Construction, latency inspection, and `reset()` are control-thread operations.
/// After construction, only `processMonoSample(_:)` is real-time safe. Callers
/// must serialize access to an instance.
public protocol SpeechAnalyzing: AnyObject {
    var sourceSampleRate: Double { get }
    var sourceBlockFrameCount: Int { get }
    var analysisLatencyFrameCount: Int { get }

    func processMonoSample(_ sample: Float) -> SpeechAnalysisEvent
    func reset()
}

