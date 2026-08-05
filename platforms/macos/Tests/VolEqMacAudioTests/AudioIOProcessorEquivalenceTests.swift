// SPDX-License-Identifier: MPL-2.0

import VolEqCore
import VolEqDSP
import VolEqSpeech
import XCTest
@testable import VolEqMacAudio

final class AudioIOProcessorEquivalenceTests: AudioPipelineTestCase {
    func testEmptyInputClearsOutput() throws {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings()
        )
        var input: [Float] = []
        var output = Array(repeating: Float(0.75), count: 512 * 2)

        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                processor.process(input: inputList, output: outputList)
            }
        }

        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }

    func testAnalyzerStartupFailureStopsAudioIOConstruction() {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        XCTAssertThrowsError(
            try AudioIOProcessor(
                inputFormat: format,
                outputFormat: format,
                settings: neutralSettings(),
                speechAnalyzerFactory: { _ in throw TestSpeechFailure.startup }
            )
        ) { error in
            XCTAssertEqual(error as? TestSpeechFailure, .startup)
        }
    }

    func testFractionalFixedBlockRateStopsAudioIOConstructionBeforeSpeechFactoriesRun() {
        let fractionalFormat = floatFormat(sampleRate: 22_050, channelCount: 2)
        var factoryCalls = 0

        XCTAssertThrowsError(
            try AudioIOProcessor(
                inputFormat: fractionalFormat,
                outputFormat: fractionalFormat,
                settings: neutralSettings(),
                speechAnalyzerFactory: { _ in
                    factoryCalls += 1
                    return PendingSpeechAnalyzer(sampleRate: 48_000)
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? SpeechAnalyzerError,
                .unsupportedSampleRate(22_050)
            )
        }
        XCTAssertEqual(factoryCalls, 0)
    }

    func testDisablingSpeechAwarenessRetainsBaseLevelingAtFractionalFixedBlockRate() throws {
        let fractionalFormat = floatFormat(sampleRate: 22_050, channelCount: 2)
        let processor = try AudioIOProcessor(
            inputFormat: fractionalFormat,
            outputFormat: fractionalFormat,
            settings: neutralSettings(),
            speechAwarenessEnabled: false,
            speechAnalyzerFactory: { _ in
                XCTFail("Speech analyzer must not be constructed when disabled")
                return PendingSpeechAnalyzer(sampleRate: 48_000)
            }
        )

        XCTAssertFalse(processor.usesSampleRateConversion)
        XCTAssertEqual(processor.inputSampleRate, 22_050)
        XCTAssertEqual(processor.outputSampleRate, 22_050)
    }

    func testDisablingSpeechAwarenessSkipsAllSpeechProcessorConstruction() throws {
        let creations = AnalyzerCreationRecorder()
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false,
            speechAnalyzerFactory: { sampleRate in
                creations.append(sampleRate)
                throw TestSpeechFailure.startup
            },
            stereoSpeechProcessorFactory: { sampleRate in
                creations.append(sampleRate)
                throw TestSpeechFailure.startup
            }
        )

        XCTAssertTrue(creations.values.isEmpty)
        XCTAssertEqual(processor.directProcessingLatencyFrameCount, 960)
    }

    func testDisabledSpeechAwarenessMatchesBaseDirectPathSampleForSample() throws {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let settings = LevelingSettings()
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: settings,
            speechAwarenessEnabled: false,
            speechAnalyzerFactory: { _ in throw TestSpeechFailure.startup }
        )
        let baseline = DynamicsProcessor(sampleRate: 48_000, settings: settings)

        for callback in 0..<8 {
            var input = (0..<512).flatMap { frame -> [Float] in
                let absoluteFrame = callback * 512 + frame
                return [
                    Float(sin(Double(absoluteFrame) * 0.031)) * 0.08,
                    Float(sin(Double(absoluteFrame) * 0.047 + 0.4)) * 0.06
                ]
            }
            var actual = Array(repeating: Float.zero, count: input.count)
            var expected = Array(repeating: Float.zero, count: input.count)

            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &actual, channelCount: 2) { outputList in
                    processor.process(input: inputList, output: outputList)
                }
                withMutableInterleavedBuffer(samples: &expected, channelCount: 2) { outputList in
                    XCTAssertTrue(baseline.process(input: inputList, output: outputList))
                }
            }
            assertSamplesBitExact(actual, expected)
        }

        XCTAssertEqual(processor.currentDiagnostics()?.path, .directAggregateClock)
        XCTAssertNil(processor.takePendingFailure())
    }

    func testDisabledSpeechAwarenessMatchesBaseConvertedPathSampleForSample() throws {
        let inputRate = 48_000.0
        let outputRate = 44_100.0
        let settings = LevelingSettings()
        let outputFormat = floatFormat(sampleRate: outputRate, channelCount: 2)
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: inputRate, channelCount: 2),
            outputFormat: outputFormat,
            settings: settings,
            speechAwarenessEnabled: false,
            speechAnalyzerFactory: { _ in throw TestSpeechFailure.startup }
        )
        let baselineDynamics = DynamicsProcessor(sampleRate: inputRate, settings: settings)
        let baselineConverter = try BufferedSampleRateConverter(
            inputSampleRate: inputRate,
            outputFormat: outputFormat
        )
        var phase = 0.0

        for callback in 0..<20 {
            var input = (0..<480).flatMap { _ -> [Float] in
                defer { phase += 2 * .pi * 330 / inputRate }
                let left = Float(sin(phase)) * 0.08
                let right = Float(sin(phase + 0.4)) * 0.06
                return [left, right]
            }
            var actual = Array(repeating: Float.zero, count: 441 * 2)
            var expected = Array(repeating: Float.zero, count: 441 * 2)

            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &actual, channelCount: 2) { outputList in
                    processor.process(
                        input: inputList,
                        inputTime: hostTimestamp(UInt64(callback * 10_000)),
                        output: outputList,
                        outputTime: hostTimestamp(UInt64(callback * 10_000))
                    )
                }
                if processor.currentDiagnostics()?.path == .sampleRateConverter {
                    XCTAssertTrue(
                        baselineConverter.appendProcessedInput(
                            inputList,
                            processor: baselineDynamics
                        )
                    )
                    withMutableInterleavedBuffer(samples: &expected, channelCount: 2) {
                        _ = baselineConverter.fillOutput($0)
                    }
                }
            }
            assertSamplesBitExact(actual, expected)
            XCTAssertNil(processor.takePendingFailure())
        }

        XCTAssertEqual(processor.currentDiagnostics()?.path, .sampleRateConverter)
    }

    func testDirectAndConvertedPathsReceiveSeparateAnalyzerState() throws {
        let creations = AnalyzerCreationRecorder()
        _ = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            settings: neutralSettings(),
            speechAnalyzerFactory: { sampleRate in
                creations.append(sampleRate)
                return PendingSpeechAnalyzer(sampleRate: sampleRate)
            }
        )
        XCTAssertEqual(creations.values, [44_100, 48_000])
    }
}
