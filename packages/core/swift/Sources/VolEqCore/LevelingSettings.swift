// SPDX-License-Identifier: MPL-2.0

/// Platform-neutral settings for VolEq's linked-stereo speech leveler.
///
/// The properties remain mutable so clients can build settings incrementally. Before
/// using values for signal processing, call ``normalized()``. VolEq's processors do
/// this at their public boundaries, keeping invalid external input out of the
/// real-time audio path.
public struct LevelingSettings: Equatable, Sendable {
    public var thresholdDB: Float
    public var compressorRatio: Float
    public var quietCompressionRatio: Float
    public var quietPriorityDB: Float
    public var noiseGateDB: Float
    public var expanderRatio: Float
    public var makeupGainDB: Float
    public var limiterDB: Float
    public var attackSeconds: Float
    public var releaseSeconds: Float
    public var detectorAttackSeconds: Float
    public var detectorReleaseSeconds: Float
    public var lookaheadSeconds: Float
    public var loudReductionDB: Float

    public init(
        thresholdDB: Float = -24,
        compressorRatio: Float = 6,
        quietCompressionRatio: Float = 8,
        quietPriorityDB: Float = 6,
        noiseGateDB: Float = -55,
        expanderRatio: Float = 2,
        makeupGainDB: Float = 6,
        limiterDB: Float = -1,
        attackSeconds: Float = 0.001,
        releaseSeconds: Float = 0.200,
        detectorAttackSeconds: Float = 0.010,
        detectorReleaseSeconds: Float = 0.500,
        lookaheadSeconds: Float = 0.020,
        loudReductionDB: Float = 6
    ) {
        self.thresholdDB = thresholdDB
        self.compressorRatio = compressorRatio
        self.quietCompressionRatio = quietCompressionRatio
        self.quietPriorityDB = quietPriorityDB
        self.noiseGateDB = noiseGateDB
        self.expanderRatio = expanderRatio
        self.makeupGainDB = makeupGainDB
        self.limiterDB = limiterDB
        self.attackSeconds = attackSeconds
        self.releaseSeconds = releaseSeconds
        self.detectorAttackSeconds = detectorAttackSeconds
        self.detectorReleaseSeconds = detectorReleaseSeconds
        self.lookaheadSeconds = lookaheadSeconds
        self.loudReductionDB = loudReductionDB
    }

    /// Returns settings constrained to finite, processing-safe values.
    ///
    /// Finite values outside the supported range are clamped. Non-finite values and
    /// non-positive time constants fall back to the corresponding default. The noise
    /// gate is also kept at or below the compression threshold so each processing
    /// region remains reachable.
    public func normalized() -> LevelingSettings {
        let defaults = LevelingSettings()

        let normalizedThreshold = Self.clampedFinite(
            thresholdDB,
            default: defaults.thresholdDB,
            range: -160...0
        )
        let normalizedNoiseGate = min(
            Self.clampedFinite(
                noiseGateDB,
                default: defaults.noiseGateDB,
                range: -160...0
            ),
            normalizedThreshold
        )

        return LevelingSettings(
            thresholdDB: normalizedThreshold,
            compressorRatio: Self.clampedFinite(
                compressorRatio,
                default: defaults.compressorRatio,
                range: 1...100
            ),
            quietCompressionRatio: Self.clampedFinite(
                quietCompressionRatio,
                default: defaults.quietCompressionRatio,
                range: 1...100
            ),
            quietPriorityDB: Self.clampedFinite(
                quietPriorityDB,
                default: defaults.quietPriorityDB,
                range: -60...60
            ),
            noiseGateDB: normalizedNoiseGate,
            expanderRatio: Self.clampedFinite(
                expanderRatio,
                default: defaults.expanderRatio,
                range: 1...100
            ),
            makeupGainDB: Self.clampedFinite(
                makeupGainDB,
                default: defaults.makeupGainDB,
                range: -60...60
            ),
            limiterDB: Self.clampedFinite(
                limiterDB,
                default: defaults.limiterDB,
                range: -160...0
            ),
            attackSeconds: Self.normalizedTime(
                attackSeconds,
                default: defaults.attackSeconds
            ),
            releaseSeconds: Self.normalizedTime(
                releaseSeconds,
                default: defaults.releaseSeconds
            ),
            detectorAttackSeconds: Self.normalizedTime(
                detectorAttackSeconds,
                default: defaults.detectorAttackSeconds
            ),
            detectorReleaseSeconds: Self.normalizedTime(
                detectorReleaseSeconds,
                default: defaults.detectorReleaseSeconds
            ),
            lookaheadSeconds: Self.normalizedLookahead(
                lookaheadSeconds,
                default: defaults.lookaheadSeconds
            ),
            loudReductionDB: Self.clampedFinite(
                loudReductionDB,
                default: defaults.loudReductionDB,
                range: 0...24
            )
        )
    }

    private static func clampedFinite(
        _ value: Float,
        default defaultValue: Float,
        range: ClosedRange<Float>
    ) -> Float {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func normalizedTime(_ value: Float, default defaultValue: Float) -> Float {
        guard value.isFinite, value > 0 else { return defaultValue }
        return min(max(value, 0.000_001), 60)
    }

    private static func normalizedLookahead(_ value: Float, default defaultValue: Float) -> Float {
        guard value.isFinite else { return defaultValue }
        return min(max(value, 0), 0.050)
    }
}
