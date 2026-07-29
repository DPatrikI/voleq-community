// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import VolEqCore
import VolEqDSP
import XCTest
@testable import VolEqMacAudio

final class BufferedSampleRateConverterTests: XCTestCase {
    func testRingBufferDropsOldestFrameAndPreservesLiveOrder() {
        let buffer = StereoFrameRingBuffer(capacity: 3)
        buffer.append(left: 1, right: -1)
        buffer.append(left: 2, right: -2)
        buffer.append(left: 3, right: -3)
        buffer.append(left: 4, right: -4)

        XCTAssertEqual(buffer.availableFrameCount, 3)
        XCTAssertEqual(buffer.droppedFrameCount, 1)

        let firstRead = buffer.contiguousReadPointer(maximumFrameCount: 3)
        XCTAssertEqual(firstRead?.frameCount, 2)
        XCTAssertEqual(firstRead?.pointer[0], 2)
        XCTAssertEqual(firstRead?.pointer[1], -2)
        XCTAssertEqual(firstRead?.pointer[2], 3)
        XCTAssertEqual(firstRead?.pointer[3], -3)

        buffer.consume(frameCount: 2)
        let secondRead = buffer.contiguousReadPointer(maximumFrameCount: 3)
        XCTAssertEqual(secondRead?.frameCount, 1)
        XCTAssertEqual(secondRead?.pointer[0], 4)
        XCTAssertEqual(secondRead?.pointer[1], -4)
    }

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
    }

    func testEqualCallbackPeriodsBypassDuplicateNominalRateConversion() throws {
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            settings: neutralSettings()
        )
        var input = Array(repeating: Float(0.125), count: 512 * 2)
        var output = Array(repeating: Float.zero, count: 512 * 2)

        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                processor.process(input: inputList, output: outputList)
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
        XCTAssertTrue(output.allSatisfy { abs($0) > 0.12 })
    }

    func testRateMatchedCallbackPeriodsKeepSampleRateConversion() throws {
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            settings: neutralSettings()
        )
        var input = Array(repeating: Float(0.125), count: 480 * 2)
        var output = Array(repeating: Float.zero, count: 441 * 2)

        for _ in 0..<2 {
            output = Array(repeating: Float.zero, count: 441 * 2)
            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                    processor.process(input: inputList, output: outputList)
                }
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
        XCTAssertTrue(output.contains { abs($0) > 0.01 })
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

            withInterleavedStereoBuffer(samples: &input) { inputList in
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

    private func withInterleavedStereoBuffer<Result>(
        samples: inout [Float],
        body: (UnsafePointer<AudioBufferList>) throws -> Result
    ) rethrows -> Result {
        try samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            return try withUnsafePointer(to: &list, body)
        }
    }

    private func withMutableInterleavedBuffer<Result>(
        samples: inout [Float],
        channelCount: UInt32,
        body: (UnsafeMutablePointer<AudioBufferList>) throws -> Result
    ) rethrows -> Result {
        try samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channelCount,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            return try withUnsafeMutablePointer(to: &list, body)
        }
    }

    private func floatFormat(
        sampleRate: Double,
        channelCount: UInt32
    ) -> AudioStreamBasicDescription {
        let bytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.stride)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func neutralSettings() -> LevelingSettings {
        LevelingSettings(
            thresholdDB: 0,
            compressorRatio: 1,
            quietCompressionRatio: 1,
            quietPriorityDB: 0,
            noiseGateDB: -160,
            expanderRatio: 1,
            makeupGainDB: 0,
            limiterDB: 0
        )
    }
}
