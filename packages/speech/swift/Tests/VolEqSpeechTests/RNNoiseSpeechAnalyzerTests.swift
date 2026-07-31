// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VolEqSpeech

final class RNNoiseSpeechAnalyzerTests: XCTestCase {
    private static let sharedModel = try! RNNoiseModelResource.bundled()

    func testBundledModelLoadsAndRejectsCorruption() throws {
        _ = Self.sharedModel

        XCTAssertThrowsError(try RNNoiseModelResource.bundled(bundle: Bundle(for: EmptyBundleMarker.self))) { error in
            XCTAssertEqual(error as? RNNoiseModelError, .resourceMissing)
        }

        let corrupt = Data([0, 1, 2, 3])
        XCTAssertThrowsError(
            try RNNoiseModelResource(data: corrupt, expectedSHA256: RNNoiseModelResource.bundledSHA256)
        ) { error in
            guard case RNNoiseModelError.checksumMismatch = error else {
                return XCTFail("Expected checksum mismatch, got \(error)")
            }
        }
    }

    func testSHA256ImplementationUsesStandardDigest() {
        let digest = SHA256.hexDigest(of: Data("abc".utf8))
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testProbabilityBoundsAndFinitePower() throws {
        let analyzer = try RNNoiseSpeechAnalyzer(sampleRate: 48_000, model: Self.sharedModel)
        let results = feed(
            analyzer,
            sampleCount: analyzer.sourceBlockFrameCount * 8,
            generator: { index in Float(sin(Double(index) * 0.071)) * 0.05 }
        )

        XCTAssertEqual(results.count, 8)
        for result in results {
            XCTAssertTrue((0...1).contains(result.probability))
            XCTAssertTrue(result.sourcePower.isFinite)
            XCTAssertGreaterThanOrEqual(result.sourcePower, 0)
            XCTAssertEqual(result.sourceFrameCount, 480)
        }
    }

    func testFrameAccountingAndLongStreamDriftAtSupportedRates() throws {
        for sampleRate in [16_000.0, 44_100.0, 48_000.0] {
            let analyzer = try RNNoiseSpeechAnalyzer(sampleRate: sampleRate, model: Self.sharedModel)
            var covered = 0
            var resultCount = 0
            for checkpoint in 1...10 {
                let chunk = feed(
                    analyzer,
                    sampleCount: analyzer.sourceBlockFrameCount * 100
                ) { index in
                    Float(sin(Double(index + checkpoint * 997) * 0.017)) * 0.01
                }
                covered += chunk.reduce(0) { $0 + $1.sourceFrameCount }
                resultCount += chunk.count
                let expectedBlocks = checkpoint * 100
                let expectedSourceCount = analyzer.sourceBlockFrameCount * expectedBlocks
                XCTAssertLessThanOrEqual(
                    abs(covered - expectedSourceCount),
                    analyzer.sourceBlockFrameCount
                )
                XCTAssertLessThanOrEqual(abs(resultCount - expectedBlocks), 1)
                XCTAssertTrue(chunk.allSatisfy {
                    $0.sourceFrameCount == analyzer.sourceBlockFrameCount
                })
            }
            XCTAssertGreaterThanOrEqual(analyzer.analysisLatencyFrameCount, analyzer.sourceBlockFrameCount)
            XCTAssertLessThanOrEqual(
                analyzer.analysisLatencyFrameCount,
                Int((sampleRate * 0.020).rounded()),
                "The prepared analysis must fit inside the accepted 20 ms lookahead"
            )
        }
    }

    func testResampledSourcePowerUsesTheReportedDelayedCoverageWindow() throws {
        for sampleRate in [16_000.0, 44_100.0] {
            let analyzer = try RNNoiseSpeechAnalyzer(sampleRate: sampleRate, model: Self.sharedModel)
            var samples: [Float] = []
            let sampleCount = analyzer.sourceBlockFrameCount * 8
            samples.reserveCapacity(sampleCount)

            for index in 0..<sampleCount {
                let sample = Float((index % 97) + 1) / 500
                samples.append(sample)
                guard case let .result(result) = analyzer.processMonoSample(sample) else { continue }

                let coverageStart = index + 1 - result.analysisLatencyFrameCount
                var expectedPower: Double = 0
                for offset in 0..<result.sourceFrameCount {
                    let sourceIndex = coverageStart + offset
                    guard samples.indices.contains(sourceIndex) else { continue }
                    let coveredSample = Double(samples[sourceIndex])
                    expectedPower += coveredSample * coveredSample
                }
                expectedPower /= Double(result.sourceFrameCount)
                XCTAssertEqual(
                    result.sourcePower,
                    Float(expectedPower),
                    accuracy: 0.000_000_1,
                    "Power metadata must cover the same delayed source interval as VAD at \(sampleRate) Hz"
                )
            }
        }
    }

    func testResetRestoresBlockBoundary() throws {
        let analyzer = try RNNoiseSpeechAnalyzer(sampleRate: 44_100, model: Self.sharedModel)
        let count = analyzer.sourceBlockFrameCount * 3
        let initialBoundaries = resultBoundaries(analyzer, sampleCount: count)
        _ = feed(analyzer, sampleCount: 137) { _ in 0.01 }
        analyzer.reset()
        let resetBoundaries = resultBoundaries(analyzer, sampleCount: count)

        XCTAssertEqual(resetBoundaries, initialBoundaries)
    }

    func testResetMatchesFreshAnalyzerStateIncludingResamplerHistory() throws {
        let resetAnalyzer = try RNNoiseSpeechAnalyzer(sampleRate: 44_100, model: Self.sharedModel)
        let freshAnalyzer = try RNNoiseSpeechAnalyzer(sampleRate: 44_100, model: Self.sharedModel)
        _ = feed(
            resetAnalyzer,
            sampleCount: resetAnalyzer.sourceBlockFrameCount * 12
        ) { index in
            Float(sin(Double(index) * 0.029)) * 0.15
        }
        resetAnalyzer.reset()

        let sampleCount = resetAnalyzer.sourceBlockFrameCount * 20
        let afterReset = feed(resetAnalyzer, sampleCount: sampleCount) { index in
            Float(sin(Double(index) * 0.013) + 0.3 * sin(Double(index) * 0.071)) * 0.05
        }
        let fresh = feed(freshAnalyzer, sampleCount: sampleCount) { index in
            Float(sin(Double(index) * 0.013) + 0.3 * sin(Double(index) * 0.071)) * 0.05
        }

        XCTAssertEqual(afterReset.count, fresh.count)
        for (resetResult, freshResult) in zip(afterReset, fresh) {
            XCTAssertEqual(resetResult.probability, freshResult.probability, accuracy: 0.000_001)
            XCTAssertEqual(resetResult.sourcePower, freshResult.sourcePower, accuracy: 0.000_000_1)
            XCTAssertEqual(resetResult.sourceFrameCount, freshResult.sourceFrameCount)
            XCTAssertEqual(
                resetResult.analysisLatencyFrameCount,
                freshResult.analysisLatencyFrameCount
            )
        }
    }

    func testNonFiniteInputFailsAndResetRecovers() throws {
        let analyzer = try RNNoiseSpeechAnalyzer(sampleRate: 48_000, model: Self.sharedModel)

        XCTAssertEqual(analyzer.processMonoSample(.nan), .failed)
        XCTAssertEqual(analyzer.processMonoSample(0), .failed)
        analyzer.reset()
        XCTAssertEqual(analyzer.processMonoSample(0), .pending)
    }

    private func feed(
        _ analyzer: any SpeechAnalyzing,
        sampleCount: Int,
        generator: (Int) -> Float
    ) -> [SpeechAnalysisResult] {
        var results: [SpeechAnalysisResult] = []
        for index in 0..<sampleCount {
            if case let .result(result) = analyzer.processMonoSample(generator(index)) {
                results.append(result)
            }
        }
        return results
    }

    private func resultBoundaries(_ analyzer: any SpeechAnalyzing, sampleCount: Int) -> [Int] {
        var boundaries: [Int] = []
        for index in 0..<sampleCount {
            if case .result = analyzer.processMonoSample(0.01) {
                boundaries.append(index)
            }
        }
        return boundaries
    }
}

private final class EmptyBundleMarker {}
