// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import VolEqDSP
import XCTest
@testable import VolEqMacAudio

final class BufferedSampleRateConverterBehaviorTests: AudioPipelineTestCase {
    func testConvertsSustained48KInputTo441KOutput() throws {
        try assertSustainedConversion(
            inputRate: 48_000,
            inputFramesPerPeriod: 480,
            outputRate: 44_100,
            outputFramesPerPeriod: 441
        )
    }

    func testConvertsSustained441KInputTo48KOutput() throws {
        try assertSustainedConversion(
            inputRate: 44_100,
            inputFramesPerPeriod: 441,
            outputRate: 48_000,
            outputFramesPerPeriod: 480
        )
    }

    func testConverts48KInputTo16KMonoHeadsetOutput() throws {
        try assertSustainedConversion(
            inputRate: 48_000,
            inputFramesPerPeriod: 480,
            outputRate: 16_000,
            outputFramesPerPeriod: 160,
            outputChannelCount: 1
        )
    }

    func testJittered48KInputNeverEmitsPartial441KOutputPeriods() throws {
        try assertSustainedConversion(
            inputRate: 48_000,
            inputFramesPerPeriod: 480,
            outputRate: 44_100,
            outputFramesPerPeriod: 441,
            inputFrameCountForPeriod: { period in
                period.isMultiple(of: 2) ? 478 : 482
            }
        )
    }

    func testInputOverflowDropsOldestFramesAndRecoversAtLiveEdge() throws {
        let format = floatFormat(sampleRate: 44_100, channelCount: 2)
        let converter = try BufferedSampleRateConverter(
            inputSampleRate: 48_000,
            outputFormat: format,
            bufferCapacityFrames: 64
        )
        var settings = neutralSettings()
        settings.lookaheadSeconds = 0
        let processor = DynamicsProcessor(sampleRate: 48_000, settings: settings)
        var input = (1...128).flatMap { frame -> [Float] in
            let sample = Float(frame) * 0.001
            return [sample, -sample]
        }
        var output = Array(repeating: Float.zero, count: 16 * 2)

        XCTAssertTrue(
            withInterleavedStereoBuffer(samples: &input) {
                converter.appendProcessedInput($0, processor: processor)
            }
        )
        let result = withMutableInterleavedBuffer(samples: &output, channelCount: 2) {
            converter.fillOutput($0)
        }

        XCTAssertEqual(result.droppedFrameCount, 64)
        XCTAssertEqual(result.producedFrameCount, 16)
        XCTAssertNil(result.errorStatus)
        XCTAssertGreaterThan(output[0], 0.05)
        XCTAssertLessThan(output[1], -0.05)
        XCTAssertGreaterThanOrEqual(output[2], output[0])
        XCTAssertLessThanOrEqual(output[3], output[1])
    }

    func testThreeConsecutiveOutputUnderrunsReturnFatalStatus() throws {
        let expectedStatus = OSStatus(bitPattern: 0x564F_5552) // 'VOUR'
        let converter = try BufferedSampleRateConverter(
            inputSampleRate: 48_000,
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            bufferCapacityFrames: 960
        )
        var settings = neutralSettings()
        settings.lookaheadSeconds = 0
        let processor = DynamicsProcessor(sampleRate: 48_000, settings: settings)
        var input = Array(repeating: Float(0.1), count: 960 * 2)
        var output = Array(repeating: Float.zero, count: 441 * 2)

        XCTAssertTrue(
            withInterleavedStereoBuffer(samples: &input) {
                converter.appendProcessedInput($0, processor: processor)
            }
        )
        var result = withMutableInterleavedBuffer(samples: &output, channelCount: 2) {
            converter.fillOutput($0)
        }
        XCTAssertEqual(result.producedFrameCount, 441)

        while result.producedFrameCount > 0 {
            output = Array(repeating: Float(0.75), count: 441 * 2)
            result = withMutableInterleavedBuffer(samples: &output, channelCount: 2) {
                converter.fillOutput($0)
            }
        }
        XCTAssertTrue(result.needsMoreInput)
        XCTAssertNil(result.errorStatus)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })

        output = Array(repeating: Float(0.75), count: 441 * 2)
        let secondUnderrun = withMutableInterleavedBuffer(
            samples: &output,
            channelCount: 2
        ) { converter.fillOutput($0) }
        XCTAssertTrue(secondUnderrun.needsMoreInput)
        XCTAssertNil(secondUnderrun.errorStatus)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })

        output = Array(repeating: Float(0.75), count: 441 * 2)
        let thirdUnderrun = withMutableInterleavedBuffer(
            samples: &output,
            channelCount: 2
        ) { converter.fillOutput($0) }
        XCTAssertTrue(thirdUnderrun.needsMoreInput)
        XCTAssertEqual(thirdUnderrun.errorStatus, expectedStatus)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }

    func testOversizedOutputPeriodIsRejectedAndCleared() throws {
        let expectedStatus = OSStatus(bitPattern: 0x564F_5552) // 'VOUR'
        let converter = try BufferedSampleRateConverter(
            inputSampleRate: 48_000,
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            bufferCapacityFrames: 8
        )
        var output = Array(repeating: Float(0.75), count: 4_097 * 2)

        let result = withMutableInterleavedBuffer(samples: &output, channelCount: 2) {
            converter.fillOutput($0)
        }

        XCTAssertEqual(result.producedFrameCount, 0)
        XCTAssertFalse(result.needsMoreInput)
        XCTAssertEqual(result.errorStatus, expectedStatus)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }

    private func assertSustainedConversion(
        inputRate: Double,
        inputFramesPerPeriod: Int,
        outputRate: Double,
        outputFramesPerPeriod: Int,
        outputChannelCount: UInt32 = 2,
        inputFrameCountForPeriod: ((Int) -> Int)? = nil
    ) throws {
        let converter = try BufferedSampleRateConverter(
            inputSampleRate: inputRate,
            outputFormat: floatFormat(
                sampleRate: outputRate,
                channelCount: outputChannelCount
            ),
            bufferCapacityFrames: inputFramesPerPeriod * 8
        )
        let processor = DynamicsProcessor(
            sampleRate: inputRate,
            settings: neutralSettings()
        )
        var phase = 0.0
        var totalProducedFrames = 0
        var foundAudibleOutput = false
        var startedOutput = false
        var warmupPeriodCount = 0
        let periodCount = 500

        for period in 0..<periodCount {
            let inputFrameCount = inputFrameCountForPeriod?(period) ?? inputFramesPerPeriod
            var input = (0..<inputFrameCount).flatMap { _ -> [Float] in
                defer { phase += 2 * .pi * 440 / inputRate }
                let sample = Float(sin(phase) * 0.1)
                return [sample, sample]
            }
            var output = Array(
                repeating: Float.zero,
                count: outputFramesPerPeriod * Int(outputChannelCount)
            )

            _ = withInterleavedStereoBuffer(samples: &input) { inputList in
                converter.appendProcessedInput(inputList, processor: processor)
            }
            let result = withMutableInterleavedBuffer(
                samples: &output,
                channelCount: outputChannelCount
            ) { outputList in
                converter.fillOutput(outputList)
            }
            totalProducedFrames += result.producedFrameCount
            foundAudibleOutput = foundAudibleOutput || output.contains { abs($0) > 0.000_001 }
            XCTAssertTrue(output.allSatisfy(\.isFinite))
            XCTAssertEqual(result.droppedFrameCount, 0)
            XCTAssertNil(result.errorStatus)

            if result.producedFrameCount == 0 {
                XCTAssertFalse(
                    startedOutput,
                    "The converter underrun after playback had started."
                )
                warmupPeriodCount += 1
                XCTAssertTrue(result.needsMoreInput)
                XCTAssertTrue(output.allSatisfy { $0 == 0 })
            } else {
                startedOutput = true
                XCTAssertEqual(result.producedFrameCount, outputFramesPerPeriod)
                XCTAssertFalse(result.needsMoreInput)
            }
        }

        XCTAssertLessThanOrEqual(warmupPeriodCount, 2)
        XCTAssertEqual(
            totalProducedFrames,
            outputFramesPerPeriod * (periodCount - warmupPeriodCount)
        )
        XCTAssertTrue(foundAudibleOutput)
    }
}
