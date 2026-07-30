// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import VolEqCore
import VolEqDSP
import VolEqSpeech
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
        XCTAssertEqual(processor.directProcessingLatencyFrameCount, 882)
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
                if resolvedOutput.count > 882 { break }
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
        XCTAssertEqual(firstAudibleFrame, 882)
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

    func testRuntimeSpeechFailureClearsOutputAndReportsOnce() throws {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAnalyzerFactory: {
                FailingSpeechAnalyzer(sampleRate: $0, failAfterSampleCount: 1_060)
            }
        )
        var input = Array(repeating: Float(0.25), count: 480 * 2)
        var output = Array(repeating: Float(0.75), count: 480 * 2)

        for _ in 0..<2 {
            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                    processor.process(input: inputList, output: outputList)
                }
            }
            XCTAssertTrue(output.allSatisfy { $0 == 0 })
            output = Array(repeating: Float(0.75), count: 480 * 2)
        }

        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                processor.process(input: inputList, output: outputList)
            }
        }
        XCTAssertTrue(output.allSatisfy { $0 == 0 }, "A partial callback must be cleared in full.")
        XCTAssertEqual(processor.takePendingFailure(), speechAnalysisFailed)
        XCTAssertNil(processor.takePendingFailure())

        output = Array(repeating: Float(0.75), count: 480 * 2)
        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                processor.process(input: inputList, output: outputList)
            }
        }
        XCTAssertTrue(output.allSatisfy { $0 == 0 }, "Fatal analysis state must remain latched.")
        XCTAssertNil(processor.takePendingFailure())
    }

    func testRuntimeSpeechFailureClearsConvertedPathAndReportsOnce() throws {
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            settings: neutralSettings(),
            speechAnalyzerFactory: { sampleRate in
                if sampleRate == 48_000 {
                    return FailingSpeechAnalyzer(
                        sampleRate: sampleRate,
                        failAfterSampleCount: 700
                    )
                }
                return PendingSpeechAnalyzer(sampleRate: sampleRate)
            }
        )
        var failure: OSStatus?

        for callback in 0..<12 {
            var input = Array(repeating: Float(0.25), count: 480 * 2)
            var output = Array(repeating: Float(0.75), count: 441 * 2)
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

            if let pendingFailure = processor.takePendingFailure() {
                failure = pendingFailure
                XCTAssertTrue(output.allSatisfy { $0 == 0 })
                break
            }
        }

        XCTAssertEqual(processor.currentDiagnostics()?.path, .sampleRateConverter)
        XCTAssertEqual(failure, speechAnalysisFailed)

        var input = Array(repeating: Float(0.25), count: 480 * 2)
        var output = Array(repeating: Float(0.75), count: 441 * 2)
        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                processor.process(input: inputList, output: outputList)
            }
        }
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
        XCTAssertNil(processor.takePendingFailure())
    }

    @available(macOS 14.2, *)
    @MainActor
    func testControllerConsumesRuntimeFailureOnceAndTransitionsToStoppedState() throws {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAnalyzerFactory: {
                FailingSpeechAnalyzer(sampleRate: $0, failAfterSampleCount: 1)
            }
        )
        var input = Array(repeating: Float(0.25), count: 480 * 2)
        var output = Array(repeating: Float(0.75), count: 480 * 2)
        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                processor.process(input: inputList, output: outputList)
            }
        }

        var resourceStopCount = 0
        let controller = AudioCaptureController(
            installSystemObservers: false,
            initiallyRunning: true,
            stopResourcesDidRun: { resourceStopCount += 1 }
        )
        XCTAssertTrue(controller.isRunning)
        XCTAssertTrue(controller.recoverPendingProcessingFailure(from: processor))
        XCTAssertEqual(resourceStopCount, 1)
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller.status.contains("Original audio was restored"))

        XCTAssertFalse(controller.recoverPendingProcessingFailure(from: processor))
        XCTAssertEqual(resourceStopCount, 1)
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

    private func hostTimestamp(_ hostTime: UInt64) -> AudioTimeStamp {
        var timestamp = AudioTimeStamp()
        timestamp.mHostTime = hostTime
        timestamp.mFlags = .hostTimeValid
        return timestamp
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

private enum TestSpeechFailure: Error {
    case startup
}

private final class PendingSpeechAnalyzer: SpeechAnalyzing {
    let sourceSampleRate: Double
    let sourceBlockFrameCount: Int
    let analysisLatencyFrameCount = 0

    init(sampleRate: Double) {
        sourceSampleRate = sampleRate
        sourceBlockFrameCount = max(Int((sampleRate * 0.010).rounded()), 1)
    }

    func processMonoSample(_: Float) -> SpeechAnalysisEvent { .pending }
    func reset() {}
}

private final class FailingSpeechAnalyzer: SpeechAnalyzing {
    let sourceSampleRate: Double
    let sourceBlockFrameCount = 1
    let analysisLatencyFrameCount = 1
    private let failAfterSampleCount: Int
    private var processedSampleCount = 0

    init(sampleRate: Double, failAfterSampleCount: Int) {
        sourceSampleRate = sampleRate
        self.failAfterSampleCount = failAfterSampleCount
    }

    func processMonoSample(_: Float) -> SpeechAnalysisEvent {
        processedSampleCount += 1
        return processedSampleCount >= failAfterSampleCount ? .failed : .pending
    }

    func reset() {
        processedSampleCount = 0
    }
}

private final class AnalyzerCreationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
