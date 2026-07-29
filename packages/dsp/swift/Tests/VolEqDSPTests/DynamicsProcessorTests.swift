// SPDX-License-Identifier: MPL-2.0

import XCTest
import VolEqCore
@testable import VolEqDSP

final class DynamicsProcessorTests: XCTestCase {
    func testLoudSignalReceivesLessGainThanConversationalSignal() {
        let processor = DynamicsProcessor(sampleRate: 48_000)

        var quietGain: Float = 0
        for _ in 0..<48_000 {
            quietGain = processor.gain(left: 0.03, right: 0.03)
        }

        var loudGain: Float = 0
        for _ in 0..<48_000 {
            loudGain = processor.gain(left: 0.8, right: 0.8)
        }

        XCTAssertGreaterThan(quietGain, loudGain)
    }

    func testStereoChannelsShareTheSameGain() {
        let processor = DynamicsProcessor(sampleRate: 48_000)
        let gain = processor.gain(left: 0.8, right: 0.1)
        XCTAssertGreaterThan(gain, 0)
        XCTAssertEqual(0.8 * gain / (0.1 * gain), 8, accuracy: 0.0001)
    }

    func testQuietPriorityCanMakeQuietOriginSpeechSlightlyLouder() {
        var settings = LevelingSettings()
        settings.compressorRatio = 6
        settings.quietCompressionRatio = 8
        settings.quietPriorityDB = 6
        settings.makeupGainDB = 0
        settings.noiseGateDB = -55

        let quietAmplitude = powf(10, -40 / 20)
        let loudAmplitude = powf(10, -18 / 20)
        let quietOutputDB = settledOutputDB(amplitude: quietAmplitude, settings: settings)
        let loudOutputDB = settledOutputDB(amplitude: loudAmplitude, settings: settings)

        XCTAssertGreaterThan(quietOutputDB, loudOutputDB)
        XCTAssertLessThan(quietOutputDB - loudOutputDB, 6)
    }

    func testDisablingQuietLevelingPreservesQuietLevelBelowThreshold() {
        var settings = LevelingSettings()
        settings.quietCompressionRatio = 1
        settings.quietPriorityDB = 0
        settings.makeupGainDB = 0
        settings.noiseGateDB = -55

        let inputDB: Float = -40
        let amplitude = powf(10, inputDB / 20)
        let outputDB = settledOutputDB(amplitude: amplitude, settings: settings)

        XCTAssertEqual(outputDB, inputDB, accuracy: 0.05)
    }

    func testNoiseGateAttenuatesSilenceAfterRelease() {
        let processor = DynamicsProcessor(sampleRate: 48_000)
        var gain: Float = 1
        for _ in 0..<96_000 {
            gain = processor.gain(left: 0.000_01, right: 0.000_01)
        }
        XCTAssertLessThan(gain, 1)
    }

    func testSettingsCanBeUpdatedWhileProcessorExists() {
        let processor = DynamicsProcessor(sampleRate: 48_000)
        var settings = processor.settings
        settings.thresholdDB = -18
        settings.compressorRatio = 12
        settings.makeupGainDB = 18

        processor.updateSettings(settings)

        XCTAssertEqual(processor.settings, settings)
    }

    func testInvalidSettingsAreNormalizedAtInitialization() {
        let unsafeSettings = LevelingSettings(
            thresholdDB: .nan,
            compressorRatio: 0,
            quietCompressionRatio: -.infinity,
            quietPriorityDB: .infinity,
            noiseGateDB: .nan,
            expanderRatio: -2,
            makeupGainDB: .infinity,
            limiterDB: 12,
            attackSeconds: 0,
            releaseSeconds: -1,
            detectorAttackSeconds: .nan,
            detectorReleaseSeconds: .infinity,
            lookaheadSeconds: -.infinity,
            loudReductionDB: .nan
        )

        let processor = DynamicsProcessor(sampleRate: 48_000, settings: unsafeSettings)
        let normalized = processor.settings
        let defaults = LevelingSettings()

        XCTAssertEqual(normalized.thresholdDB, defaults.thresholdDB)
        XCTAssertEqual(normalized.compressorRatio, 1)
        XCTAssertEqual(normalized.quietCompressionRatio, defaults.quietCompressionRatio)
        XCTAssertEqual(normalized.quietPriorityDB, defaults.quietPriorityDB)
        XCTAssertEqual(normalized.noiseGateDB, defaults.noiseGateDB)
        XCTAssertEqual(normalized.expanderRatio, 1)
        XCTAssertEqual(normalized.makeupGainDB, defaults.makeupGainDB)
        XCTAssertEqual(normalized.limiterDB, 0)
        XCTAssertEqual(normalized.attackSeconds, defaults.attackSeconds)
        XCTAssertEqual(normalized.releaseSeconds, defaults.releaseSeconds)
        XCTAssertEqual(normalized.detectorAttackSeconds, defaults.detectorAttackSeconds)
        XCTAssertEqual(normalized.detectorReleaseSeconds, defaults.detectorReleaseSeconds)
        XCTAssertEqual(normalized.lookaheadSeconds, defaults.lookaheadSeconds)
        XCTAssertEqual(normalized.loudReductionDB, defaults.loudReductionDB)
    }

    func testSettingsNormalizationClampsFiniteValuesAndPreservesValidValues() {
        let settings = LevelingSettings(
            thresholdDB: -200,
            compressorRatio: 120,
            quietCompressionRatio: 4,
            quietPriorityDB: -12,
            noiseGateDB: -10,
            expanderRatio: 3,
            makeupGainDB: -80,
            limiterDB: -200,
            attackSeconds: 0.000_000_1,
            releaseSeconds: 90,
            detectorAttackSeconds: 0.025,
            detectorReleaseSeconds: 0.750,
            lookaheadSeconds: 0.075,
            loudReductionDB: 30
        )

        let normalized = settings.normalized()

        XCTAssertEqual(normalized.thresholdDB, -160)
        XCTAssertEqual(normalized.compressorRatio, 100)
        XCTAssertEqual(normalized.quietCompressionRatio, 4)
        XCTAssertEqual(normalized.quietPriorityDB, -12)
        XCTAssertEqual(normalized.noiseGateDB, -160)
        XCTAssertEqual(normalized.expanderRatio, 3)
        XCTAssertEqual(normalized.makeupGainDB, -60)
        XCTAssertEqual(normalized.limiterDB, -160)
        XCTAssertEqual(normalized.attackSeconds, 0.000_001)
        XCTAssertEqual(normalized.releaseSeconds, 60)
        XCTAssertEqual(normalized.detectorAttackSeconds, 0.025)
        XCTAssertEqual(normalized.detectorReleaseSeconds, 0.750)
        XCTAssertEqual(normalized.lookaheadSeconds, 0.050)
        XCTAssertEqual(normalized.loudReductionDB, 24)
        XCTAssertEqual(normalized.normalized(), normalized)
        XCTAssertEqual(LevelingSettings(lookaheadSeconds: -1).normalized().lookaheadSeconds, 0)
        XCTAssertEqual(LevelingSettings(loudReductionDB: -3).normalized().loudReductionDB, 0)
    }

    func testLookaheadHasExactTenMillisecondLatencyAtSupportedRates() {
        for (sampleRate, expectedFrames) in [(16_000.0, 160), (44_100.0, 441), (48_000.0, 480)] {
            let processor = DynamicsProcessor(sampleRate: sampleRate)
            XCTAssertEqual(processor.latencyFrameCount, expectedFrames)

            for _ in 0..<expectedFrames {
                let output = processor.processFrame(left: 0.25, right: -0.125)
                XCTAssertEqual(output.left, 0)
                XCTAssertEqual(output.right, 0)
            }

            let firstDelayedOutput = processor.processFrame(left: 0.25, right: -0.125)
            XCTAssertNotEqual(firstDelayedOutput.left, 0)
            XCTAssertNotEqual(firstDelayedOutput.right, 0)
        }
    }

    func testZeroLookaheadDisablesDelay() {
        var settings = LevelingSettings()
        settings.lookaheadSeconds = 0
        let processor = DynamicsProcessor(sampleRate: 48_000, settings: settings)

        XCTAssertEqual(processor.latencyFrameCount, 0)
        let output = processor.processFrame(left: 0.25, right: 0.25)
        XCTAssertNotEqual(output.left, 0)
    }

    func testResetRestoresInitialLookaheadSilence() {
        let processor = DynamicsProcessor(sampleRate: 48_000)
        let latency = processor.latencyFrameCount

        for _ in 0...latency {
            _ = processor.processFrame(left: 0.25, right: 0.25)
        }
        processor.reset()

        for _ in 0..<latency {
            let output = processor.processFrame(left: 0.25, right: 0.25)
            XCTAssertEqual(output.left, 0)
            XCTAssertEqual(output.right, 0)
        }
        XCTAssertNotEqual(processor.processFrame(left: 0.25, right: 0.25).left, 0)
    }

    func testLookaheadPreventsQuietToLoudOpeningBlast() {
        let sampleRate = 48_000
        let processor = DynamicsProcessor(sampleRate: Double(sampleRate))
        let quietAmplitude = powf(10, -40 / 20)

        for _ in 0..<(sampleRate * 2) {
            _ = processor.processFrame(left: quietAmplitude, right: quietAmplitude)
        }

        var loudOutput: [Float] = []
        loudOutput.reserveCapacity(sampleRate + processor.latencyFrameCount)
        for _ in 0..<(sampleRate + processor.latencyFrameCount) {
            let output = processor.processFrame(left: 1, right: 1)
            loudOutput.append(abs(output.left))
        }

        let latency = processor.latencyFrameCount
        let firstLookaheadPeriodPeak = loudOutput[latency..<(latency * 2)].max() ?? 0
        let settledPeak = loudOutput.suffix(latency).max() ?? 0
        XCTAssertGreaterThan(settledPeak, 0)
        XCTAssertLessThanOrEqual(
            decibels(firstLookaheadPeriodPeak),
            decibels(settledPeak) + 1
        )
    }

    func testLookaheadCatchesAnIsolatedFullScaleImpulse() {
        let processor = DynamicsProcessor(sampleRate: 48_000)
        let quietAmplitude = powf(10, -40 / 20)

        for _ in 0..<96_000 {
            _ = processor.processFrame(left: quietAmplitude, right: quietAmplitude)
        }
        _ = processor.processFrame(left: 1, right: 1)

        var peak: Float = 0
        for _ in 0...processor.latencyFrameCount {
            let output = processor.processFrame(left: 0, right: 0)
            peak = max(peak, max(abs(output.left), abs(output.right)))
        }

        XCTAssertGreaterThan(peak, quietAmplitude)
        XCTAssertLessThan(peak, 0.25)
    }

    func testLoudOriginSpeechSettlesAtLeastFiveDecibelsBelowQuietOriginSpeech() {
        let quietOutputDB = settledProcessedOutputDB(inputDB: -40)
        let loudOutputDB = settledProcessedOutputDB(inputDB: -6)

        XCTAssertGreaterThanOrEqual(quietOutputDB - loudOutputDB, 5)
        XCTAssertLessThanOrEqual(quietOutputDB - loudOutputDB, 9)
    }

    func testInvalidSettingsUpdateCannotProduceNonFiniteSamples() {
        let processor = DynamicsProcessor(sampleRate: 48_000)
        processor.updateSettings(
            LevelingSettings(
                thresholdDB: .infinity,
                compressorRatio: .nan,
                quietCompressionRatio: 0,
                quietPriorityDB: -.infinity,
                noiseGateDB: .nan,
                expanderRatio: -1,
                makeupGainDB: .infinity,
                limiterDB: .nan,
                attackSeconds: -.infinity,
                releaseSeconds: 0,
                detectorAttackSeconds: -1,
                detectorReleaseSeconds: .nan
            )
        )
        processor.beginAudioBuffer()

        for _ in 0..<1_000 {
            let output = processor.processFrame(left: 0.25, right: -0.5)
            XCTAssertTrue(output.left.isFinite)
            XCTAssertTrue(output.right.isFinite)
        }
    }

    func testInvalidSampleRatesUseDeterministicSafeFallback() {
        for sampleRate in [Double.nan, .infinity, -.infinity, 0, -48_000, 1_000_000] {
            let fallbackProcessor = DynamicsProcessor(sampleRate: sampleRate)
            let referenceProcessor = DynamicsProcessor(sampleRate: 48_000)

            for _ in 0..<100 {
                let fallback = fallbackProcessor.processFrame(left: 0.2, right: -0.1)
                let reference = referenceProcessor.processFrame(left: 0.2, right: -0.1)
                XCTAssertEqual(fallback.left, reference.left)
                XCTAssertEqual(fallback.right, reference.right)
            }
        }
    }

    private func settledOutputDB(
        amplitude: Float,
        settings: LevelingSettings
    ) -> Float {
        let processor = DynamicsProcessor(sampleRate: 48_000, settings: settings)
        var gain: Float = 1
        for _ in 0..<96_000 {
            gain = processor.gain(left: amplitude, right: amplitude)
        }
        return 20 * log10f(max(amplitude * gain, 0.000_001))
    }

    private func settledProcessedOutputDB(inputDB: Float) -> Float {
        let sampleRate = 48_000
        let processor = DynamicsProcessor(sampleRate: Double(sampleRate))
        let amplitude = powf(10, inputDB / 20)
        var output: Float = 0
        for _ in 0..<(sampleRate * 2 + processor.latencyFrameCount) {
            output = processor.processFrame(left: amplitude, right: amplitude).left
        }
        return decibels(abs(output))
    }

    private func decibels(_ amplitude: Float) -> Float {
        20 * log10f(max(amplitude, 0.000_001))
    }
}
