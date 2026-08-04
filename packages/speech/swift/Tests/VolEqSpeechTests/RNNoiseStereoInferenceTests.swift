// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VolEqSpeech

final class RNNoiseStereoInferenceTests: XCTestCase {
    func testOptimizedFloatInferenceIsBitExactAcrossRecurrentDriftHorizon() throws {
        for sampleRate in [16_000.0, 44_100.0, 48_000.0] {
            try assertOptimizedFloatInferenceIsBitExact(sampleRate: sampleRate)
        }
    }

    private func assertOptimizedFloatInferenceIsBitExact(sampleRate: Double) throws {
        let accepted = try RNNoiseStereoProcessor(
            sampleRate: sampleRate,
            model: RNNoiseStereoTestSupport.model,
            usesOptimizedPairedInference: false
        )
        let optimized = try RNNoiseStereoProcessor(
            sampleRate: sampleRate,
            model: RNNoiseStereoTestSupport.model
        )
        var randomState: UInt32 = 0xBB67_AE85
        var minimumActivityBoundaryDistance: Float = 1
        let comparisonBlockCount = 1_000
        var resultCount = 0
        var denoisedBlockCount = 0

        for frame in 0..<(accepted.sourceBlockFrameCount * comparisonBlockCount) {
            randomState = randomState &* 1_664_525 &+ 1_013_904_223
            let noiseLeft = Float(Int32(bitPattern: randomState)) / Float(Int32.max) * 0.012
            randomState = randomState &* 1_664_525 &+ 1_013_904_223
            let noiseRight = Float(Int32(bitPattern: randomState)) / Float(Int32.max) * 0.009
            let phase = 2 * Double.pi * 180 * Double(frame) / sampleRate
            let harmonic = 2 * Double.pi * 360 * Double(frame) / sampleRate
            let block = frame / accepted.sourceBlockFrameCount
            let modeBlock = block % 64
            let voicedLeft = Float(sin(phase) * 0.055 + sin(harmonic) * 0.018)
            let voicedRight = Float(sin(phase + 0.31) * 0.048 - sin(harmonic) * 0.014)
            let left: Float
            let right: Float
            if modeBlock < 32 {
                left = voicedLeft + noiseLeft
                right = voicedRight + noiseRight
            } else if modeBlock < 48 {
                left = noiseLeft
                right = voicedRight + noiseRight
            } else {
                left = voicedLeft + noiseLeft
                right = -voicedLeft + noiseRight
            }

            let acceptedEvent = accepted.processStereoFrame(left: left, right: right)
            let optimizedEvent = optimized.processStereoFrame(left: left, right: right)
            XCTAssertEqual(
                acceptedEvent,
                optimizedEvent,
                "event differed at \(sampleRate) Hz, frame \(frame)"
            )
            if case let .result(acceptedResult) = acceptedEvent {
                resultCount += 1
                for threshold: Float in [0.20, 0.35, 0.65, 0.90] {
                    minimumActivityBoundaryDistance = min(
                        minimumActivityBoundaryDistance,
                        abs(acceptedResult.probability - threshold)
                    )
                }
            }

            if let acceptedBlock = accepted.pendingDenoisedBlock,
               let optimizedBlock = optimized.pendingDenoisedBlock {
                denoisedBlockCount += 1
                XCTAssertEqual(acceptedBlock, optimizedBlock)
                for sample in 0..<acceptedBlock.sourceFrameCount {
                    for channel in 0..<2 {
                        XCTAssertEqual(
                            accepted.denoisedSample(frame: sample, channel: channel),
                            optimized.denoisedSample(frame: sample, channel: channel),
                            "wet sample differed at \(sampleRate) Hz, block \(denoisedBlockCount), frame \(sample), channel \(channel)"
                        )
                    }
                }
                accepted.consumeDenoisedBlock()
                optimized.consumeDenoisedBlock()
            } else {
                XCTAssertEqual(accepted.pendingDenoisedBlock == nil, optimized.pendingDenoisedBlock == nil)
            }
        }

        XCTAssertGreaterThan(resultCount, comparisonBlockCount - 2)
        XCTAssertGreaterThan(denoisedBlockCount, comparisonBlockCount - 4)
        if sampleRate == 48_000 {
            XCTAssertLessThanOrEqual(
                minimumActivityBoundaryDistance,
                0.001,
                "fixture no longer exercises a close speech-activity decision boundary"
            )
        }
        XCTAssertEqual(accepted.completedOptimizedInferencePairCount, 0)
        XCTAssertEqual(optimized.completedOptimizedInferencePairCount, comparisonBlockCount)
    }

    func testHighestChannelProbabilityAndItsPowerDriveLinkedDecision() throws {
        let stereo = try RNNoiseStereoProcessor(sampleRate: 48_000, model: RNNoiseStereoTestSupport.model)
        let leftAnalyzer = try RNNoiseSpeechAnalyzer(sampleRate: 48_000, model: RNNoiseStereoTestSupport.model)
        let rightAnalyzer = try RNNoiseSpeechAnalyzer(sampleRate: 48_000, model: RNNoiseStereoTestSupport.model)
        var resultCount = 0
        var rightWinCount = 0

        for frame in 0..<(480 * 12) {
            let left: Float = 0
            let right = Float(
                sin(Double(frame) * 0.071)
                    + 0.45 * sin(Double(frame) * 0.143)
                    + 0.2 * sin(Double(frame) * 0.281)
            ) * 0.06
            let stereoEvent = stereo.processStereoFrame(left: left, right: right)
            let leftEvent = leftAnalyzer.processMonoSample(left)
            let rightEvent = rightAnalyzer.processMonoSample(right)

            guard case let .result(stereoResult) = stereoEvent,
                  case let .result(leftResult) = leftEvent,
                  case let .result(rightResult) = rightEvent else {
                continue
            }
            resultCount += 1
            if rightResult.probability > leftResult.probability { rightWinCount += 1 }
            let expected = leftResult.probability >= rightResult.probability ? leftResult : rightResult
            XCTAssertEqual(stereoResult.probability, expected.probability, accuracy: 0.000_001)
            XCTAssertEqual(stereoResult.sourcePower, expected.sourcePower, accuracy: 0.000_001)
        }
        XCTAssertGreaterThan(resultCount, 0)
        XCTAssertEqual(rightWinCount, resultCount)
    }

    func testAntiPhaseInputCannotCancelLinkedSpeechDecision() throws {
        let stereo = try RNNoiseStereoProcessor(sampleRate: 48_000, model: RNNoiseStereoTestSupport.model)
        let positiveAnalyzer = try RNNoiseSpeechAnalyzer(sampleRate: 48_000, model: RNNoiseStereoTestSupport.model)
        let negativeAnalyzer = try RNNoiseSpeechAnalyzer(sampleRate: 48_000, model: RNNoiseStereoTestSupport.model)
        var resultCount = 0

        for frame in 0..<(480 * 12) {
            let sample = Float(
                sin(Double(frame) * 0.071)
                    + 0.45 * sin(Double(frame) * 0.143)
                    + 0.2 * sin(Double(frame) * 0.281)
            ) * 0.06
            let stereoEvent = stereo.processStereoFrame(left: sample, right: -sample)
            let positiveEvent = positiveAnalyzer.processMonoSample(sample)
            let negativeEvent = negativeAnalyzer.processMonoSample(-sample)

            guard case let .result(stereoResult) = stereoEvent,
                  case let .result(positiveResult) = positiveEvent,
                  case let .result(negativeResult) = negativeEvent else {
                continue
            }
            resultCount += 1
            XCTAssertEqual(
                stereoResult.probability,
                max(positiveResult.probability, negativeResult.probability),
                accuracy: 0.000_001
            )
            XCTAssertGreaterThan(stereoResult.sourcePower, 0)
        }
        XCTAssertGreaterThan(resultCount, 0)
    }
}
