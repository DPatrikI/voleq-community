// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VolEqSpeech

final class RNNoiseStereoProcessorTests: XCTestCase {
    private static let model = RNNoiseStereoTestSupport.model

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

    func testResetMatchesFreshStereoState() throws {
        for sampleRate in [16_000.0, 44_100.0, 48_000.0] {
            let resetProcessor = try RNNoiseStereoProcessor(sampleRate: sampleRate, model: Self.model)
            let freshProcessor = try RNNoiseStereoProcessor(sampleRate: sampleRate, model: Self.model)
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
                    freshProcessor.processStereoFrame(left: left, right: right),
                    "event differed at \(sampleRate) Hz, frame \(frame)"
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
    }

    func testUnconsumedPendingBlockLatchesFailureUntilReset() throws {
        let processor = try RNNoiseStereoProcessor(sampleRate: 48_000, model: Self.model)
        for _ in 0..<processor.sourceBlockFrameCount * 4 {
            _ = processor.processStereoFrame(left: 0.01, right: -0.01)
            if processor.pendingDenoisedBlock != nil { break }
        }
        XCTAssertNotNil(processor.pendingDenoisedBlock)
        XCTAssertEqual(processor.processStereoFrame(left: 0.01, right: -0.01), .failed)
        XCTAssertEqual(processor.processStereoFrame(left: 0.01, right: -0.01), .failed)
        processor.reset()
        XCTAssertEqual(processor.processStereoFrame(left: 0.01, right: -0.01), .pending)
    }
}
