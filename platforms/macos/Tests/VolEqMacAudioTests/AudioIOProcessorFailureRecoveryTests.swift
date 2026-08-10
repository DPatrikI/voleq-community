// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import VolEqSpeech
import XCTest
@testable import VolEqMacAudio

final class AudioIOProcessorFailureRecoveryTests: AudioPipelineTestCase {
    func testMissingCallbackTimingClearsOutputAndPublishesFailureOnce() throws {
        let processor = try AudioIOProcessor(
            inputFormat: floatFormat(sampleRate: 48_000, channelCount: 2),
            outputFormat: floatFormat(sampleRate: 44_100, channelCount: 2),
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        let expectedStatus = OSStatus(bitPattern: 0x5643_544D)

        for callback in 0..<9 {
            var input = Array(repeating: Float(0.25), count: 480 * 2)
            var output = Array(repeating: Float(0.75), count: 441 * 2)
            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                    processor.process(input: inputList, output: outputList)
                }
            }
            XCTAssertTrue(output.allSatisfy { $0 == 0 })
            if callback < 7 {
                XCTAssertNil(processor.takePendingFailure())
            } else if callback == 7 {
                XCTAssertEqual(processor.takePendingFailure(), expectedStatus)
                XCTAssertNil(processor.takePendingFailure())
            } else {
                XCTAssertNil(processor.takePendingFailure())
            }
        }
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

        for _ in 0..<3 {
            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(samples: &output, channelCount: 2) { outputList in
                    processor.process(input: inputList, output: outputList)
                }
            }
            XCTAssertTrue(output.allSatisfy { $0 == 0 })
            output = Array(repeating: Float(0.75), count: 480 * 2)
        }

        XCTAssertEqual(processor.takePendingFailure(), speechAnalysisFailed)
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
            if let pending = processor.takePendingFailure() {
                failure = pending
                XCTAssertTrue(output.allSatisfy { $0 == 0 })
                break
            }
        }

        XCTAssertEqual(processor.currentDiagnostics()?.path, .sampleRateConverter)
        XCTAssertEqual(failure, speechAnalysisFailed)
        XCTAssertNil(processor.takePendingFailure())
    }

    @available(macOS 14.2, *)
    @MainActor
    func testCoordinatorConsumesRuntimeProcessorFailureAndStopsPipeline() async throws {
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

        let rig = AudioCaptureTestRig()
        rig.pipelines.make = { try TestCapturePipeline(processor: processor) }
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .failed, attempts: 20_000)

        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(rig.pipelines.pipelines.first?.stopCount, 1)
        XCTAssertEqual(controller.systemAudioAccessState, .notRequested)
        XCTAssertTrue(controller.status.contains("Original audio was restored"))
    }

    @available(macOS 14.2, *)
    @MainActor
    func testUnsupportedSpeechRateFailsBeforePipeline() async throws {
        let rig = AudioCaptureTestRig()
        rig.preflight.error = SpeechAnalyzerError.unsupportedSampleRate(22_050)
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        try await waitForAudioCondition("unsupported preflight failure") {
            controller.runtimeState == .failed
        }

        XCTAssertEqual(controller.runtimeState, .failed)
        XCTAssertTrue(controller.status.contains("does not support"))
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)

        let failureStatus = controller.status
        controller.refreshProcesses()

        XCTAssertEqual(controller.runtimeState, .failed)
        XCTAssertEqual(controller.systemAudioAccessState, .notRequested)
        XCTAssertEqual(controller.status, failureStatus)
    }

    @available(macOS 14.2, *)
    @MainActor
    func testSuccessfulRefreshClearsOnlyEnumerationFailure() async throws {
        let rig = AudioCaptureTestRig()
        rig.processCatalog.result = .failure(AudioCaptureTestError.unavailable)
        let controller = rig.makeController()
        controller.refreshProcesses()
        try await waitForAudioCondition("process enumeration failure") {
            controller.runtimeState == .failed
        }
        XCTAssertEqual(controller.runtimeState, .failed)

        rig.processCatalog.result = .success([])
        controller.refreshProcesses()
        try await waitForAudioCondition("process enumeration recovery") {
            controller.runtimeState == .ready
        }
        XCTAssertEqual(controller.runtimeState, .ready)
        XCTAssertTrue(controller.status.contains("No app is producing audio"))
    }
}
