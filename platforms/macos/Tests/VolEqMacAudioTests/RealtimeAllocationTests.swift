// SPDX-License-Identifier: MPL-2.0

import CVolEqRealtimeTestSupport
import CVolEqRealtime
import AudioToolbox
import XCTest
import VolEqCore
import VolEqDSP
import VolEqSpeech
@testable import VolEqMacAudio

final class RealtimeAllocationTests: XCTestCase {
    func testCallbackHeartbeatIncrementIsAllocationFree() throws {
        let heartbeat = try AudioCallbackHeartbeat()

        voleq_test_allocation_tracking_begin()
        heartbeat.recordCallback()
        let allocationCount = voleq_test_allocation_tracking_end()

        XCTAssertEqual(allocationCount, 0)
        XCTAssertEqual(heartbeat.callbackCount, 1)
    }

    func testDiagnosticRecordPublicationIsAllocationFree() throws {
        let telemetry = try AudioCallbackTelemetry(capacity: 8)
        let metadata = AudioIOCallbackMetadata(
            inputFrameCount: 512,
            outputFrameCount: 512,
            capturedPeak: 0,
            flags: UInt32(VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO)
                | UInt32(VOLEQ_DIAGNOSTIC_FLAG_OUTPUT_REQUEST_ACTIVE),
            path: 1,
            outcome: 4,
            status: noErr
        )

        voleq_test_allocation_tracking_begin()
        telemetry.record(hostTime: 100, metadata: metadata)
        let allocationCount = voleq_test_allocation_tracking_end()

        XCTAssertEqual(allocationCount, 0)
        XCTAssertEqual(telemetry.drain().records.count, 1)
    }

    func testDiagnosticDirectCallbackIsAllocationFree() throws {
        let format = floatFormat(sampleRate: 48_000)
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        let frameCount = 512
        var input = [Float](repeating: 0, count: frameCount * 2)
        var output = [Float](repeating: 0, count: frameCount * 2)
        let allocationCount = input.withUnsafeMutableBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                var inputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(inputBytes.count),
                        mData: inputBytes.baseAddress
                    )
                )
                var outputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(outputBytes.count),
                        mData: outputBytes.baseAddress
                    )
                )
                voleq_test_allocation_tracking_begin()
                _ = processor.processWithDiagnostics(
                    input: &inputList,
                    output: &outputList
                )
                return voleq_test_allocation_tracking_end()
            }
        }

        XCTAssertEqual(allocationCount, 0)
    }

    func testLivenessProbeObservationAndFaultInjectionAreAllocationFree() throws {
        let latch = try AudioSignalLatch()
        let format = floatFormat(sampleRate: 48_000)
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        let frameCount = 512
        var input = [Float](repeating: 0.125, count: frameCount * 2)
        var output = [Float](repeating: 0.75, count: frameCount * 2)
        let allocationCount = input.withUnsafeMutableBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                var inputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(inputBytes.count),
                        mData: inputBytes.baseAddress
                    )
                )
                var outputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(outputBytes.count),
                        mData: outputBytes.baseAddress
                    )
                )
                voleq_test_allocation_tracking_begin()
                latch._testOnlyObserve(&inputList)
                _ = processor.processSimulatedUnusableCapture(
                    input: &inputList,
                    output: &outputList
                )
                return voleq_test_allocation_tracking_end()
            }
        }

        XCTAssertEqual(allocationCount, 0)
        XCTAssertEqual(latch.qualifyingCallbackCount, 1)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }

    func testFirstAndWarmedStereoProcessingAreAllocationFree() throws {
        for sampleRate in [16_000.0, 44_100.0, 48_000.0] {
            try assertAllocationFree(
                sampleRate: sampleRate,
                warmupFrameCount: 0
            )
            try assertAllocationFree(
                sampleRate: sampleRate,
                warmupFrameCount: Int(sampleRate / 10)
            )
        }
    }

    func testDirectAudioCallbacksAreAllocationFree() throws {
        for sampleRate in [16_000.0, 44_100.0, 48_000.0] {
            let format = floatFormat(sampleRate: sampleRate)
            let processor = try AudioIOProcessor(
                inputFormat: format,
                outputFormat: format,
                settings: neutralSettings(),
                systemContentAnalysisEnabled: true
            )
            XCTAssertEqual(
                processAllocationCount(
                    processor: processor,
                    inputSampleRate: sampleRate,
                    outputSampleRate: sampleRate
                ),
                0
            )
            for callback in 1..<9 {
                _ = processAllocationCount(
                    processor: processor,
                    callback: callback,
                    inputSampleRate: sampleRate,
                    outputSampleRate: sampleRate,
                    tracks: false
                )
            }
            XCTAssertEqual(
                processAllocationCount(
                    processor: processor,
                    callback: 9,
                    inputSampleRate: sampleRate,
                    outputSampleRate: sampleRate
                ),
                0
            )
        }
    }

    func testFirstResolvedAndWarmedConvertedCallbacksAreAllocationFree() throws {
        for (inputSampleRate, outputSampleRate) in [
            (48_000.0, 44_100.0),
            (44_100.0, 48_000.0),
        ] {
            let processor = try AudioIOProcessor(
                inputFormat: floatFormat(sampleRate: inputSampleRate),
                outputFormat: floatFormat(sampleRate: outputSampleRate),
                settings: neutralSettings(),
                systemContentAnalysisEnabled: true
            )
            for callback in 0..<4 {
                XCTAssertEqual(
                    processAllocationCount(
                        processor: processor,
                        callback: callback,
                        inputSampleRate: inputSampleRate,
                        outputSampleRate: outputSampleRate
                    ),
                    0
                )
            }
            for callback in 4..<12 {
                _ = processAllocationCount(
                    processor: processor,
                    callback: callback,
                    inputSampleRate: inputSampleRate,
                    outputSampleRate: outputSampleRate,
                    tracks: false
                )
            }
            XCTAssertEqual(
                processAllocationCount(
                    processor: processor,
                    callback: 12,
                    inputSampleRate: inputSampleRate,
                    outputSampleRate: outputSampleRate
                ),
                0
            )
        }
    }

    func testSpeechAwareLevelingAlwaysPreparesStereoSuppression() throws {
        let model = try RNNoiseModelResource.bundled()
        let recorder = StereoFactoryRecorder()
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000),
            outputFormat: floatFormat(sampleRate: 44_100),
            settings: neutralSettings(),
            speechModel: model,
            stereoSpeechProcessorFactory: { sampleRate in
                recorder.record(sampleRate)
                return try RNNoiseStereoProcessor(sampleRate: sampleRate, model: model)
            }
        )

        XCTAssertEqual(recorder.sampleRates, [44_100, 48_000])
        XCTAssertEqual(processor.directProcessingLatencyFrameCount, 1_373)
        XCTAssertEqual(processor.conversionProcessingLatencyFrameCount, 1_440)
    }

    func testContendedSettingsSnapshotDoesNotBlockOrConstructProcessors() throws {
        let model = try RNNoiseModelResource.bundled()
        let recorder = StereoFactoryRecorder()
        let format = floatFormat(sampleRate: 48_000)
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechModel: model,
            stereoSpeechProcessorFactory: { sampleRate in
                recorder.record(sampleRate)
                return try RNNoiseStereoProcessor(sampleRate: sampleRate, model: model)
            }
        )
        XCTAssertEqual(recorder.sampleRates, [48_000, 48_000])

        let allocationCount = processor._testOnlyWithParameterLocksHeld {
            processAllocationCount(processor: processor)
        }

        XCTAssertEqual(allocationCount, 0)
        XCTAssertEqual(recorder.sampleRates, [48_000, 48_000])
        XCTAssertNil(processor.takePendingFailure())
    }

    func testFailurePublicationIsAllocationFreeAndReportedOnce() throws {
        let recorder = StereoFactoryRecorder()
        let format = floatFormat(sampleRate: 48_000)
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            stereoSpeechProcessorFactory: { sampleRate in
                recorder.record(sampleRate)
                return ImmediateFailingStereoSpeechProcessor(sampleRate: sampleRate)
            }
        )
        XCTAssertEqual(recorder.sampleRates, [48_000, 48_000])

        let allocationCount = processAllocationCount(processor: processor)

        XCTAssertEqual(allocationCount, 0)
        XCTAssertEqual(processor.takePendingFailure(), speechAnalysisFailed)
        XCTAssertNil(processor.takePendingFailure())
        XCTAssertEqual(processAllocationCount(processor: processor), 0)
        XCTAssertNil(processor.takePendingFailure())
        XCTAssertEqual(recorder.sampleRates, [48_000, 48_000])
    }

    private func assertAllocationFree(
        sampleRate: Double,
        warmupFrameCount: Int
    ) throws {
        let model = try RNNoiseModelResource.bundled()
        let speech = try RNNoiseStereoProcessor(sampleRate: sampleRate, model: model)
        let processor = try DynamicsProcessor(
            sampleRate: sampleRate,
            stereoSpeechProcessor: speech
        )
        for frame in 0..<warmupFrameCount {
            let sample = Float(frame % 97) / 970
            _ = processor.processFrame(left: sample, right: -sample)
        }

        voleq_test_allocation_tracking_begin()
        for frame in 0..<960 {
            let sample = Float(frame % 89) / 890
            _ = processor.processFrame(left: sample, right: -sample)
        }
        let allocationCount = voleq_test_allocation_tracking_end()

        XCTAssertEqual(allocationCount, 0)
        XCTAssertFalse(processor.consumeProcessingFailure())
    }

    private func processAllocationCount(
        processor: AudioIOProcessor,
        callback: Int = 0,
        inputSampleRate: Double = 48_000,
        outputSampleRate: Double = 44_100,
        tracks: Bool = true
    ) -> Int {
        let frameCount = 512
        var input = (0..<frameCount).flatMap { frame -> [Float] in
            let sample = Float(
                sin(Double(frame + callback * frameCount) * 0.043)
            ) * 0.05
            return [sample, sample]
        }
        var output = [Float](repeating: 0, count: frameCount * 2)
        var allocationCount = 0
        input.withUnsafeMutableBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                var inputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(inputBytes.count),
                        mData: inputBytes.baseAddress
                    )
                )
                var outputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(outputBytes.count),
                        mData: outputBytes.baseAddress
                    )
                )
                var inputTime = AudioTimeStamp()
                inputTime.mHostTime = UInt64(callback) * hostTimeIncrement(
                    frameCount: frameCount,
                    sampleRate: inputSampleRate
                )
                inputTime.mFlags = .hostTimeValid
                var outputTime = AudioTimeStamp()
                outputTime.mHostTime = UInt64(callback) * hostTimeIncrement(
                    frameCount: frameCount,
                    sampleRate: outputSampleRate
                )
                outputTime.mFlags = .hostTimeValid
                if tracks { voleq_test_allocation_tracking_begin() }
                processor.process(
                    input: &inputList,
                    inputTime: inputTime,
                    output: &outputList,
                    outputTime: outputTime
                )
                if tracks {
                    allocationCount = Int(voleq_test_allocation_tracking_end())
                }
            }
        }
        return allocationCount
    }

    private func hostTimeIncrement(frameCount: Int, sampleRate: Double) -> UInt64 {
        UInt64((Double(frameCount) * 1_000_000 / sampleRate).rounded())
    }

    private func floatFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
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

private final class StereoFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var sampleRates: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ sampleRate: Double) {
        lock.lock()
        storage.append(sampleRate)
        lock.unlock()
    }
}

private final class ImmediateFailingStereoSpeechProcessor: StereoSpeechProcessing {
    let sourceSampleRate: Double
    let sourceBlockFrameCount: Int
    let decisionLatencyFrameCount: Int
    let processingLatencyFrameCount: Int
    let inputResamplerLatencyFrameCount = 0
    let outputResamplerLatencyFrameCount = 0

    init(sampleRate: Double) {
        sourceSampleRate = sampleRate
        sourceBlockFrameCount = try! RNNoiseFixedBlockSampleRate.sourceBlockFrameCount(
            for: sampleRate
        )
        decisionLatencyFrameCount = sourceBlockFrameCount
        processingLatencyFrameCount = sourceBlockFrameCount * 3
    }

    func processStereoFrame(left _: Float, right _: Float) -> SpeechAnalysisEvent { .failed }
    var pendingDenoisedBlock: DenoisedSpeechBlock? { nil }
    func denoisedSample(frame _: Int, channel _: Int) -> Float { 0 }
    func consumeDenoisedBlock() {}
    func reset() {}
}
