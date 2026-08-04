// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VolEqSpeech

final class RNNoiseStereoAlignmentTests: XCTestCase {
    func testDeterministicStereoOutputMatchesAcceptedSnapshot() throws {
        let processor = try RNNoiseStereoProcessor(
            sampleRate: 48_000,
            model: RNNoiseStereoTestSupport.model,
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
                RNNoiseStereoTestSupport.mixSnapshot(0, into: &snapshot)
            case .failed:
                XCTFail("accepted deterministic stream must remain finite")
            case let .result(result):
                RNNoiseStereoTestSupport.mixSnapshot(1, into: &snapshot)
                RNNoiseStereoTestSupport.mixSnapshot(UInt64(result.probability.bitPattern), into: &snapshot)
                RNNoiseStereoTestSupport.mixSnapshot(UInt64(result.sourcePower.bitPattern), into: &snapshot)
            }

            if let block = processor.pendingDenoisedBlock {
                RNNoiseStereoTestSupport.mixSnapshot(
                    UInt64(bitPattern: block.sourceStartFrameIndex), into: &snapshot
                )
                RNNoiseStereoTestSupport.mixSnapshot(UInt64(block.sourceFrameCount), into: &snapshot)
                RNNoiseStereoTestSupport.mixSnapshot(UInt64(block.speechProbability.bitPattern), into: &snapshot)
                RNNoiseStereoTestSupport.mixSnapshot(UInt64(block.sourcePower.bitPattern), into: &snapshot)
                RNNoiseStereoTestSupport.mixSnapshot(
                    UInt64(block.estimatedSNRDB?.bitPattern ?? Float.nan.bitPattern), into: &snapshot
                )
                for frame in 0..<block.sourceFrameCount {
                    RNNoiseStereoTestSupport.mixSnapshot(
                        UInt64(processor.denoisedSample(frame: frame, channel: 0).bitPattern),
                        into: &snapshot
                    )
                    RNNoiseStereoTestSupport.mixSnapshot(
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
            let processor = try RNNoiseStereoProcessor(sampleRate: rate, model: RNNoiseStereoTestSupport.model)
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
                for source in start..<end where hasWet[source] {
                    wetPower += Double(wet[source] * wet[source])
                }
                wetBlockPower[block] = wetPower
            }
            let peakBlock = wetBlockPower.indices.max { wetBlockPower[$0] < wetBlockPower[$1] }
            XCTAssertEqual(peakBlock, markerBlock, "rate \(rate), powers \(wetBlockPower)")
            XCTAssertGreaterThan(wetBlockPower[markerBlock], 0, "rate \(rate)")
        }
    }

    func testDenoisedBroadbandMarkerHasZeroTaggedSampleLagAtSupportedRates() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let processor = try RNNoiseStereoProcessor(sampleRate: rate, model: RNNoiseStereoTestSupport.model)
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
                    processor.processStereoFrame(left: source[frame], right: source[frame] * 0.83),
                    .failed
                )
                if let block = processor.pendingDenoisedBlock {
                    for offset in 0..<block.sourceFrameCount {
                        let taggedFrame = Int(block.sourceStartFrameIndex) + offset
                        if wet.indices.contains(taggedFrame) {
                            wet[taggedFrame] = processor.denoisedSample(frame: offset, channel: 0)
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
                    correlation += Double(wet[taggedFrame]) * Double(source[taggedFrame + lag])
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
