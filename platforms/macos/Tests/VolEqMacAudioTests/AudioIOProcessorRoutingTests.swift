// SPDX-License-Identifier: MPL-2.0

import VolEqSpeech
import XCTest
@testable import VolEqMacAudio

final class AudioIOProcessorRoutingTests: AudioPipelineTestCase {
    func testMatchingAggregateCallbackAndOutputRatesDoNotConvertAgain() throws {
        let callbackFormat = floatFormat(sampleRate: 44_100, channelCount: 2)
        let processor = try AudioIOProcessor(
            inputFormat: callbackFormat,
            outputFormat: callbackFormat,
            settings: neutralSettings()
        )

        XCTAssertFalse(processor.usesSampleRateConversion)
        XCTAssertEqual(processor.inputSampleRate, 44_100)
        XCTAssertEqual(processor.outputSampleRate, 44_100)
        XCTAssertEqual(processor.directProcessingLatencyFrameCount, 1_373)
    }

    func testEqualCallbackPeriodsBypassDuplicateNominalRateConversion() throws {
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            settings: neutralSettings()
        )
        var input = Array(repeating: Float(0.125), count: 512 * 2)
        var output = Array(repeating: Float.zero, count: 512 * 2)
        var resolvedOutput: [Float] = []

        for callback in 0..<20 {
            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                    processor.process(
                        input: inputList,
                        inputTime: hostTimestamp(UInt64(callback * 11_610)),
                        output: outputList,
                        outputTime: hostTimestamp(UInt64(callback * 11_610))
                    )
                }
            }
            if processor.currentDiagnostics()?.path == .directAggregateClock {
                resolvedOutput.append(contentsOf: stride(from: 0, to: output.count, by: 2).map {
                    output[$0]
                })
                if resolvedOutput.count > 1_373 { break }
            }
        }

        XCTAssertEqual(
            processor.currentDiagnostics(),
            AudioIOProcessingDiagnostics(
                path: .directAggregateClock,
                inputFrameCount: 512,
                outputFrameCount: 512
            )
        )
        let firstAudibleFrame = resolvedOutput.firstIndex { abs($0) > 0.12 }
        XCTAssertEqual(firstAudibleFrame, 1_373)
    }

    func testEqualFrameCountsOnDifferentClocksKeepSampleRateConversion() throws {
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            settings: neutralSettings()
        )
        var input = Array(repeating: Float(0.125), count: 512 * 2)
        var output = Array(repeating: Float.zero, count: 512 * 2)

        for callback in 0..<4 {
            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                    processor.process(
                        input: inputList,
                        inputTime: hostTimestamp(UInt64(callback * 10_667)),
                        output: outputList,
                        outputTime: hostTimestamp(UInt64(callback * 11_610))
                    )
                }
            }
        }

        XCTAssertEqual(
            processor.currentDiagnostics(),
            AudioIOProcessingDiagnostics(
                path: .sampleRateConverter,
                inputFrameCount: 512,
                outputFrameCount: 512
            )
        )
    }

    func testConvertedPathPreservesTwentyMillisecondLookahead() throws {
        let immediateOnset = try convertedStepOnsetFrame(lookaheadSeconds: 0)
        let lookaheadOnset = try convertedStepOnsetFrame(lookaheadSeconds: 0.020)

        XCTAssertEqual(lookaheadOnset - immediateOnset, 882)
    }

    func testSynchronizedDirectPathFeedsContentAnalysisAtOutputRate() throws {
        let contentAnalyzers = ContentAnalyzerRecorder()
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            settings: neutralSettings(),
            speechAnalyzerFactory: { PendingSpeechAnalyzer(sampleRate: $0) },
            contentAnalyzerFactory: { contentAnalyzers.make(sampleRate: $0) }
        )
        var input = Array(repeating: Float(0.125), count: 512 * 2)
        var output = Array(repeating: Float.zero, count: 512 * 2)

        for callback in 0..<4 {
            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                    processor.process(
                        input: inputList,
                        inputTime: hostTimestamp(UInt64(callback * 11_610)),
                        output: outputList,
                        outputTime: hostTimestamp(UInt64(callback * 11_610))
                    )
                }
            }
        }

        XCTAssertEqual(processor.currentDiagnostics()?.path, .directAggregateClock)
        XCTAssertGreaterThan(contentAnalyzers.appendedFrameCount(at: 44_100), 0)
        XCTAssertEqual(contentAnalyzers.appendedFrameCount(at: 48_000), 0)
    }

    func testConvertedPathFeedsContentAnalysisAtInputRate() throws {
        let contentAnalyzers = ContentAnalyzerRecorder()
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            settings: neutralSettings(),
            speechAnalyzerFactory: { PendingSpeechAnalyzer(sampleRate: $0) },
            contentAnalyzerFactory: { contentAnalyzers.make(sampleRate: $0) }
        )
        var input = Array(repeating: Float(0.125), count: 512 * 2)
        var output = Array(repeating: Float.zero, count: 512 * 2)

        for callback in 0..<4 {
            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                    processor.process(
                        input: inputList,
                        inputTime: hostTimestamp(UInt64(callback * 10_667)),
                        output: outputList,
                        outputTime: hostTimestamp(UInt64(callback * 11_610))
                    )
                }
            }
        }

        XCTAssertEqual(processor.currentDiagnostics()?.path, .sampleRateConverter)
        XCTAssertEqual(contentAnalyzers.appendedFrameCount(at: 44_100), 0)
        XCTAssertGreaterThan(contentAnalyzers.appendedFrameCount(at: 48_000), 0)
    }

    func testRealSpeechAnalysisRunsOnBothConvertedRateDirections() throws {
        for (inputRate, outputRate, inputHostStep, outputHostStep) in [
            (48_000.0, 44_100.0, 10_667, 11_610),
            (44_100.0, 48_000.0, 11_610, 10_667)
        ] {
            let processor = try AudioIOProcessor(
                inputFormat: floatFormat(sampleRate: inputRate, channelCount: 2),
                outputFormat: floatFormat(sampleRate: outputRate, channelCount: 2),
                settings: neutralSettings()
            )
            var phase = 0.0
            var foundAudibleOutput = false

            for callback in 0..<200 {
                var input = (0..<512).flatMap { _ -> [Float] in
                    defer { phase += 2 * .pi * 330 / inputRate }
                    let sample = Float(sin(phase) * 0.08)
                    return [sample, sample]
                }
                var output = Array(repeating: Float.zero, count: 512 * 2)
                withInterleavedStereoBuffer(samples: &input) { inputList in
                    withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                        processor.process(
                            input: inputList,
                            inputTime: hostTimestamp(UInt64(callback * inputHostStep)),
                            output: outputList,
                            outputTime: hostTimestamp(UInt64(callback * outputHostStep))
                        )
                    }
                }
                XCTAssertTrue(output.allSatisfy(\.isFinite))
                foundAudibleOutput = foundAudibleOutput || output.contains { abs($0) > 0.000_001 }
                XCTAssertNil(processor.takePendingFailure())
            }

            XCTAssertEqual(processor.currentDiagnostics()?.path, .sampleRateConverter)
            XCTAssertTrue(foundAudibleOutput)
        }
    }

    func testRealSpeechAnalysisSustainsComplete16KCallModePeriods() throws {
        let inputRate = 48_000.0
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: inputRate, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 16_000, channelCount: 1),
            settings: neutralSettings()
        )
        var phase = 0.0
        var startedOutput = false
        var warmupPeriodCount = 0
        var audiblePeriodCount = 0

        for callback in 0..<200 {
            var input = (0..<480).flatMap { _ -> [Float] in
                defer { phase += 2 * .pi * 330 / inputRate }
                let sample = Float(sin(phase) * 0.08)
                return [sample, sample]
            }
            var output = Array(repeating: Float.zero, count: 160)
            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &output, channelCount: 1) { outputList in
                    processor.process(
                        input: inputList,
                        inputTime: hostTimestamp(UInt64(callback * 10_000)),
                        output: outputList,
                        outputTime: hostTimestamp(UInt64(callback * 10_000))
                    )
                }
            }

            XCTAssertTrue(output.allSatisfy(\.isFinite))
            XCTAssertNil(processor.takePendingFailure())
            let isAudible = output.contains { abs($0) > 0.000_001 }
            if isAudible {
                startedOutput = true
                audiblePeriodCount += 1
            } else if !startedOutput {
                warmupPeriodCount += 1
            } else {
                XCTFail("The call-mode converter emitted an incomplete silent period after startup.")
            }
        }

        XCTAssertEqual(processor.currentDiagnostics()?.path, .sampleRateConverter)
        XCTAssertLessThanOrEqual(warmupPeriodCount, 10)
        XCTAssertEqual(audiblePeriodCount, 200 - warmupPeriodCount)
    }

    private func convertedStepOnsetFrame(lookaheadSeconds: Float) throws -> Int {
        var settings = neutralSettings()
        settings.lookaheadSeconds = lookaheadSeconds
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            settings: settings,
            speechAnalyzerFactory: { PendingSpeechAnalyzer(sampleRate: $0) }
        )
        var input = Array(repeating: Float(0.125), count: 480 * 2)
        var output = Array(repeating: Float.zero, count: 441 * 2)
        var resolvedOutput: [Float] = []

        for callback in 0..<20 {
            output = Array(repeating: Float.zero, count: 441 * 2)
            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                    processor.process(
                        input: inputList,
                        inputTime: hostTimestamp(UInt64(callback * 10_000)),
                        output: outputList,
                        outputTime: hostTimestamp(UInt64(callback * 10_000))
                    )
                }
            }
            if processor.currentDiagnostics()?.path == .sampleRateConverter {
                resolvedOutput.append(contentsOf: stride(from: 0, to: output.count, by: 2).map {
                    output[$0]
                })
            }
        }

        XCTAssertEqual(
            processor.currentDiagnostics(),
            AudioIOProcessingDiagnostics(
                path: .sampleRateConverter,
                inputFrameCount: 480,
                outputFrameCount: 441
            )
        )
        return try XCTUnwrap(resolvedOutput.firstIndex { abs($0) > 0.01 })
    }
}
