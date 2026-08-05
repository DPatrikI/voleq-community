// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Validates source rates that can use RNNoise's fixed 10 ms analysis cadence.
///
/// The source block is fixed for an analyzer or processor lifetime. Rates
/// requiring alternating block lengths are rejected before processing begins.
public enum RNNoiseFixedBlockSampleRate {
    public static let minimumSampleRate: Double = 8_000
    public static let maximumSampleRate: Double = 192_000
    public static let analysisBlockDurationSeconds: Double = 0.010

    /// Returns the exact whole-source-frame count in a fixed 10 ms block.
    public static func sourceBlockFrameCount(for sampleRate: Double) throws -> Int {
        guard sampleRate.isFinite,
              sampleRate >= minimumSampleRate,
              sampleRate <= maximumSampleRate,
              sampleRate.rounded() == sampleRate else {
            throw SpeechAnalyzerError.unsupportedSampleRate(sampleRate)
        }

        let integerSampleRate = Int(sampleRate)
        guard integerSampleRate.isMultiple(of: 100) else {
            throw SpeechAnalyzerError.unsupportedSampleRate(sampleRate)
        }
        return integerSampleRate / 100
    }
}
