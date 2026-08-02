// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VolEqSpeech

final class RNNoiseStereoProcessorTests: XCTestCase {
    private static let model = try! RNNoiseModelResource.bundled()

    private func mixSnapshot(_ value: UInt64, into hash: inout UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            hash ^= (value >> UInt64(shift)) & 0xff
            hash &*= 1_099_511_628_211
        }
    }

    func testMeasuredLatencyAtSupportedRates() throws {
        let expected = [
            (16_000.0, 24, 24, 528),
            (44_100.0, 24, 26, 1_373),
            (48_000.0, 0, 0, 1_440)
        ]
        for (rate, inputLatency, outputLatency, processingLatency) in expected {
            let processor = try RNNoiseStereoProcessor(sampleRate: rate, model: Self.model)
            XCTAssertEqual(processor.inputResamplerLatencyFrameCount, inputLatency)
            XCTAssertEqual(processor.outputResamplerLatencyFrameCount, outputLatency)
            XCTAssertEqual(processor.processingLatencyFrameCount, processingLatency)
        }
    }

    func testLongStereoStreamProducesFiniteAlignedBlocksAndResets() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let processor = try RNNoiseStereoProcessor(sampleRate: rate, model: Self.model)
            let blockCount = 1_000
            let frameCount = processor.sourceBlockFrameCount * blockCount
            var nextExpectedFrame: Int64 = 0
            var coveredFrameCount = 0
            for frame in 0..<frameCount {
                let left = Float(sin(Double(frame) * 0.031)) * 0.04
                let right = Float(sin(Double(frame) * 0.047)) * 0.02
                let event = processor.processStereoFrame(left: left, right: right)
                XCTAssertNotEqual(event, .failed, "failed at rate \(rate), frame \(frame)")
                if let block = processor.pendingDenoisedBlock {
                    XCTAssertEqual(block.sourceStartFrameIndex, nextExpectedFrame)
                    for sample in 0..<block.sourceFrameCount {
                        XCTAssertTrue(processor.denoisedSample(frame: sample, channel: 0).isFinite)
                        XCTAssertTrue(processor.denoisedSample(frame: sample, channel: 1).isFinite)
                    }
                    nextExpectedFrame += Int64(block.sourceFrameCount)
                    coveredFrameCount += block.sourceFrameCount
                    processor.consumeDenoisedBlock()
                }
            }
            XCTAssertGreaterThan(
                coveredFrameCount,
                processor.sourceBlockFrameCount * (blockCount - 4)
            )

            processor.reset()
            XCTAssertEqual(processor.processStereoFrame(left: 0.01, right: 0.02), .pending)
        }
    }

    func testNonFiniteInputFailsAndResetRecovers() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let processor = try RNNoiseStereoProcessor(sampleRate: rate, model: Self.model)
            XCTAssertEqual(processor.processStereoFrame(left: .nan, right: 0), .failed)
            XCTAssertEqual(processor.processStereoFrame(left: 0, right: 0), .failed)
            processor.reset()
            XCTAssertEqual(processor.processStereoFrame(left: 0, right: 0), .pending)
        }
    }

    func testOptimizedFloatInferenceIsBitExactAcrossRecurrentDriftHorizon() throws {
        let accepted = try RNNoiseStereoProcessor(
            sampleRate: 48_000,
            model: Self.model,
            usesOptimizedPairedInference: false
        )
        let optimized = try RNNoiseStereoProcessor(sampleRate: 48_000, model: Self.model)
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
            let phase = 2 * Double.pi * 180 * Double(frame) / 48_000
            let harmonic = 2 * Double.pi * 360 * Double(frame) / 48_000
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
            XCTAssertEqual(acceptedEvent, optimizedEvent, "event differed at frame \(frame)")
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
                            "wet sample differed at block \(denoisedBlockCount), frame \(sample), channel \(channel)"
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
        XCTAssertLessThanOrEqual(
            minimumActivityBoundaryDistance,
            0.001,
            "fixture no longer exercises a close speech-activity decision boundary"
        )
        XCTAssertEqual(accepted.completedOptimizedInferencePairCount, 0)
        XCTAssertEqual(optimized.completedOptimizedInferencePairCount, comparisonBlockCount)
    }

    func testExtremeFiniteInputFailsConservativelyAndResetRecovers() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let processor = try RNNoiseStereoProcessor(sampleRate: rate, model: Self.model)
            var didFail = false
            for frame in 0..<(processor.sourceBlockFrameCount * 8) {
                let event = processor.processStereoFrame(
                    left: frame.isMultiple(of: 2) ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude,
                    right: frame.isMultiple(of: 2) ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude
                )
                if event == .failed {
                    didFail = true
                    break
                }
            }
            XCTAssertTrue(didFail, "extreme stream remained active at \(rate) Hz")
            XCTAssertEqual(processor.processStereoFrame(left: 0, right: 0), .failed)
            processor.reset()
            XCTAssertEqual(processor.processStereoFrame(left: 0, right: 0), .pending)
        }
    }

    func testHighestChannelProbabilityAndItsPowerDriveLinkedDecision() throws {
        let stereo = try RNNoiseStereoProcessor(sampleRate: 48_000, model: Self.model)
        let leftAnalyzer = try RNNoiseSpeechAnalyzer(sampleRate: 48_000, model: Self.model)
        let rightAnalyzer = try RNNoiseSpeechAnalyzer(sampleRate: 48_000, model: Self.model)
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
            if rightResult.probability > leftResult.probability {
                rightWinCount += 1
            }
            let expected = leftResult.probability >= rightResult.probability
                ? leftResult
                : rightResult
            XCTAssertEqual(stereoResult.probability, expected.probability, accuracy: 0.000_001)
            XCTAssertEqual(stereoResult.sourcePower, expected.sourcePower, accuracy: 0.000_001)
        }
        XCTAssertGreaterThan(resultCount, 0)
        XCTAssertEqual(rightWinCount, resultCount)
    }

    func testAntiPhaseInputCannotCancelLinkedSpeechDecision() throws {
        let stereo = try RNNoiseStereoProcessor(sampleRate: 48_000, model: Self.model)
        let positiveAnalyzer = try RNNoiseSpeechAnalyzer(sampleRate: 48_000, model: Self.model)
        let negativeAnalyzer = try RNNoiseSpeechAnalyzer(sampleRate: 48_000, model: Self.model)
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

    func testResetMatchesFreshStereoState() throws {
        let resetProcessor = try RNNoiseStereoProcessor(sampleRate: 44_100, model: Self.model)
        let freshProcessor = try RNNoiseStereoProcessor(sampleRate: 44_100, model: Self.model)
        for frame in 0..<(resetProcessor.sourceBlockFrameCount * 7) {
            _ = resetProcessor.processStereoFrame(
                left: Float(sin(Double(frame) * 0.029)) * 0.08,
                right: Float(cos(Double(frame) * 0.037)) * 0.05
            )
            if resetProcessor.pendingDenoisedBlock != nil {
                resetProcessor.consumeDenoisedBlock()
            }
        }
        resetProcessor.reset()

        for frame in 0..<(resetProcessor.sourceBlockFrameCount * 12) {
            let left = Float(sin(Double(frame) * 0.041)) * 0.04
            let right = Float(cos(Double(frame) * 0.053)) * 0.03
            XCTAssertEqual(
                resetProcessor.processStereoFrame(left: left, right: right),
                freshProcessor.processStereoFrame(left: left, right: right)
            )
            XCTAssertEqual(resetProcessor.pendingDenoisedBlock, freshProcessor.pendingDenoisedBlock)
            if let block = resetProcessor.pendingDenoisedBlock {
                for sample in 0..<block.sourceFrameCount {
                    XCTAssertEqual(
                        resetProcessor.denoisedSample(frame: sample, channel: 0),
                        freshProcessor.denoisedSample(frame: sample, channel: 0),
                        accuracy: 0.000_001
                    )
                    XCTAssertEqual(
                        resetProcessor.denoisedSample(frame: sample, channel: 1),
                        freshProcessor.denoisedSample(frame: sample, channel: 1),
                        accuracy: 0.000_001
                    )
                }
                resetProcessor.consumeDenoisedBlock()
                freshProcessor.consumeDenoisedBlock()
            }
        }
    }

    func testDeterministicStereoOutputMatchesAcceptedSnapshot() throws {
        let processor = try RNNoiseStereoProcessor(
            sampleRate: 48_000,
            model: Self.model,
            usesOptimizedPairedInference: false
        )
        var randomState: UInt32 = 0x6A09_E667
        var snapshot: UInt64 = 14_695_981_039_346_656_037

        for _ in 0..<(processor.sourceBlockFrameCount * 16) {
            randomState = randomState &* 1_664_525 &+ 1_013_904_223
            let left = Float(Int32(bitPattern: randomState)) / Float(Int32.max) * 0.08
            randomState = randomState &* 1_664_525 &+ 1_013_904_223
            let right = Float(Int32(bitPattern: randomState)) / Float(Int32.max) * 0.06
            let event = processor.processStereoFrame(left: left, right: right)
            switch event {
            case .pending:
                mixSnapshot(0, into: &snapshot)
            case .failed:
                XCTFail("accepted deterministic stream must remain finite")
            case let .result(result):
                mixSnapshot(1, into: &snapshot)
                mixSnapshot(UInt64(result.probability.bitPattern), into: &snapshot)
                mixSnapshot(UInt64(result.sourcePower.bitPattern), into: &snapshot)
            }

            if let block = processor.pendingDenoisedBlock {
                mixSnapshot(UInt64(bitPattern: block.sourceStartFrameIndex), into: &snapshot)
                mixSnapshot(UInt64(block.sourceFrameCount), into: &snapshot)
                mixSnapshot(UInt64(block.speechProbability.bitPattern), into: &snapshot)
                mixSnapshot(UInt64(block.sourcePower.bitPattern), into: &snapshot)
                mixSnapshot(
                    UInt64(block.estimatedSNRDB?.bitPattern ?? Float.nan.bitPattern),
                    into: &snapshot
                )
                for frame in 0..<block.sourceFrameCount {
                    mixSnapshot(
                        UInt64(processor.denoisedSample(frame: frame, channel: 0).bitPattern),
                        into: &snapshot
                    )
                    mixSnapshot(
                        UInt64(processor.denoisedSample(frame: frame, channel: 1).bitPattern),
                        into: &snapshot
                    )
                }
                processor.consumeDenoisedBlock()
            }
        }

        XCTAssertEqual(
            snapshot,
            16_221_509_679_134_290_260,
            "accepted RNNoise snapshot changed: \(String(snapshot, radix: 16))"
        )
    }

    func testDenoisedMarkerEnergyIsTaggedToExactSourceBlockAtSupportedRates() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let processor = try RNNoiseStereoProcessor(sampleRate: rate, model: Self.model)
            let markerBlock = 8
            let totalBlockCount = 24
            let totalFrameCount = processor.sourceBlockFrameCount * totalBlockCount
            var wet = [Float](repeating: 0, count: totalFrameCount)
            var hasWet = [Bool](repeating: false, count: totalFrameCount)

            for frame in 0..<totalFrameCount {
                let sourceBlock = frame / processor.sourceBlockFrameCount
                let offset = frame % processor.sourceBlockFrameCount
                let sample = sourceBlock == markerBlock
                    ? Float(sin(2 * Double.pi * 220 * Double(offset) / rate)) * 0.08
                    : 0
                XCTAssertNotEqual(
                    processor.processStereoFrame(left: sample, right: sample * 0.91),
                    .failed
                )
                if let block = processor.pendingDenoisedBlock {
                    for offset in 0..<block.sourceFrameCount {
                        let source = Int(block.sourceStartFrameIndex) + offset
                        if wet.indices.contains(source) {
                            wet[source] = processor.denoisedSample(frame: offset, channel: 0)
                            hasWet[source] = true
                        }
                    }
                    processor.consumeDenoisedBlock()
                }
            }

            var wetBlockPower = [Double](repeating: 0, count: totalBlockCount)
            for block in 0..<totalBlockCount {
                var wetPower: Double = 0
                let start = block * processor.sourceBlockFrameCount
                let end = start + processor.sourceBlockFrameCount
                for source in start..<end {
                    if hasWet[source] {
                        wetPower += Double(wet[source] * wet[source])
                    }
                }
                wetBlockPower[block] = wetPower
            }
            let peakBlock = wetBlockPower.indices.max {
                wetBlockPower[$0] < wetBlockPower[$1]
            }
            XCTAssertEqual(peakBlock, markerBlock, "rate \(rate), powers \(wetBlockPower)")
            XCTAssertGreaterThan(wetBlockPower[markerBlock], 0, "rate \(rate)")
        }
    }

    func testDenoisedBroadbandMarkerHasZeroTaggedSampleLagAtSupportedRates() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let processor = try RNNoiseStereoProcessor(sampleRate: rate, model: Self.model)
            let totalBlockCount = 40
            let totalFrameCount = processor.sourceBlockFrameCount * totalBlockCount
            var source = [Float](repeating: 0, count: totalFrameCount)
            var wet = [Float](repeating: 0, count: totalFrameCount)
            var hasWet = [Bool](repeating: false, count: totalFrameCount)
            var randomState: UInt32 = 0x53A9_27C1

            for frame in source.indices {
                randomState = randomState &* 1_664_525 &+ 1_013_904_223
                let noise = Float(Int32(bitPattern: randomState)) / Float(Int32.max)
                source[frame] = noise * 0.08
                XCTAssertNotEqual(
                    processor.processStereoFrame(
                        left: source[frame],
                        right: source[frame] * 0.83
                    ),
                    .failed
                )
                if let block = processor.pendingDenoisedBlock {
                    for offset in 0..<block.sourceFrameCount {
                        let taggedFrame = Int(block.sourceStartFrameIndex) + offset
                        if wet.indices.contains(taggedFrame) {
                            wet[taggedFrame] = processor.denoisedSample(
                                frame: offset,
                                channel: 0
                            )
                            hasWet[taggedFrame] = true
                        }
                    }
                    processor.consumeDenoisedBlock()
                }
            }

            let evaluationStart = processor.sourceBlockFrameCount * 10
            let evaluationEnd = processor.sourceBlockFrameCount * 30
            XCTAssertTrue(hasWet[evaluationStart..<evaluationEnd].allSatisfy { $0 })
            let maximumLag = min(64, processor.sourceBlockFrameCount / 3)
            var bestLag = Int.min
            var bestCorrelation = -Double.infinity
            for lag in (-maximumLag)...maximumLag {
                var correlation: Double = 0
                for taggedFrame in evaluationStart..<evaluationEnd {
                    correlation += Double(wet[taggedFrame])
                        * Double(source[taggedFrame + lag])
                }
                let magnitude = abs(correlation)
                if magnitude > bestCorrelation {
                    bestCorrelation = magnitude
                    bestLag = lag
                }
            }
            XCTAssertEqual(bestLag, 0, "rate \(rate), peak correlation lag \(bestLag)")
        }
    }
}
