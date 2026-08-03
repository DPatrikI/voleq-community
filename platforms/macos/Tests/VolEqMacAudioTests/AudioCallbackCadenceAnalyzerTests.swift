// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VolEqMacAudio

final class AudioCallbackCadenceAnalyzerTests: AudioPipelineTestCase {
    func testCloseNominalRatesResolveSynchronizedCallbacks() {
        var analyzer = AudioCallbackCadenceAnalyzer(
            inputSampleRate: 48_000,
            outputSampleRate: 47_999
        )
        var resolution = AudioCadenceResolution.pending

        for callback in 0..<4 {
            resolution = analyzer.observe(
                inputFrameCount: 480,
                inputTime: hostTimestamp(UInt64(callback * 10_000_000)),
                outputFrameCount: 480,
                outputTime: hostTimestamp(UInt64(callback * 10_000_000))
            )
        }

        XCTAssertEqual(resolution, .resolved(.directAggregateClock))
    }

    func testCloseNominalRatesResolveDistinctClocks() {
        var analyzer = AudioCallbackCadenceAnalyzer(
            inputSampleRate: 48_000,
            outputSampleRate: 47_999
        )
        var resolution = AudioCadenceResolution.pending

        for callback in 0..<4 {
            resolution = analyzer.observe(
                inputFrameCount: 480,
                inputTime: hostTimestamp(UInt64(callback * 10_000_000)),
                outputFrameCount: 480,
                outputTime: hostTimestamp(UInt64(callback * 10_000_208))
            )
        }

        XCTAssertEqual(resolution, .resolved(.sampleRateConverter))
    }

    func testCloseNominalRatesKeepAmbiguousCadencePending() {
        var analyzer = AudioCallbackCadenceAnalyzer(
            inputSampleRate: 48_000,
            outputSampleRate: 47_999
        )
        var resolution = AudioCadenceResolution.pending

        for callback in 0..<4 {
            resolution = analyzer.observe(
                inputFrameCount: 480,
                inputTime: hostTimestamp(UInt64(callback * 10_000_000)),
                outputFrameCount: 480,
                outputTime: hostTimestamp(UInt64(callback * 10_000_104))
            )
        }

        XCTAssertEqual(resolution, .pending)
    }

    func testMissingTimestampsExhaustObservationBudgetAndFail() {
        var analyzer = AudioCallbackCadenceAnalyzer(
            inputSampleRate: 48_000,
            outputSampleRate: 44_100
        )

        for _ in 0..<7 {
            XCTAssertEqual(
                analyzer.observe(
                    inputFrameCount: 480,
                    inputTime: nil,
                    outputFrameCount: 441,
                    outputTime: nil
                ),
                .pending
            )
        }
        XCTAssertEqual(
            analyzer.observe(
                inputFrameCount: 480,
                inputTime: nil,
                outputFrameCount: 441,
                outputTime: nil
            ),
            .failed
        )
    }
}
