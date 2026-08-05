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
        let expectedStatus = OSStatus(bitPattern: 0x5643_544D) // 'VCTM'

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
            stopResourcesDidRun: { resourceStopCount += 1 },
            loadProcessesOverride: { [] }
        )
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.runtimeState, .active)
        XCTAssertTrue(controller.recoverPendingProcessingFailure(from: processor))
        XCTAssertEqual(resourceStopCount, 1)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.runtimeState, .failed)
        XCTAssertTrue(controller.status.contains("Original audio was restored"))

        let failureStatus = controller.status
        controller._testOnlyHandleOutputRouteChange()
        XCTAssertEqual(controller.runtimeState, .failed)
        XCTAssertEqual(controller.status, failureStatus)

        controller.refreshProcesses()
        XCTAssertEqual(controller.runtimeState, .failed)
        XCTAssertEqual(controller.status, failureStatus)

        XCTAssertFalse(controller.recoverPendingProcessingFailure(from: processor))
        XCTAssertEqual(resourceStopCount, 1)
    }

    @available(macOS 14.2, *)
    @MainActor
    func testRejectedSpeechStartupCleansUpBeforeAnyCallbackCanStartAndIsSafeToStopOrRetry() {
        var cleanupCount = 0
        var startAttemptCount = 0
        var teardownSteps: [AudioCaptureTeardownStep] = []
        let controller = AudioCaptureController(
            installSystemObservers: false,
            stopResourcesDidRun: { cleanupCount += 1 },
            startPipelineOverride: { controller in
                startAttemptCount += 1
                controller._testOnlySimulatePartiallyPreparedCaptureResources()
                throw SpeechAnalyzerError.unsupportedSampleRate(22_050)
            },
            teardownStepRecorder: { teardownSteps.append($0) }
        )

        controller.start()
        XCTAssertEqual(startAttemptCount, 1)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(teardownSteps, [
            .activeOutputListeners,
            .stopIOProc,
            .destroyIOProc,
            .destroyAggregate,
            .destroyTap
        ])
        XCTAssertTrue(controller._testOnlyCaptureResourcesAreInactive())
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.runtimeState, .failed)
        XCTAssertTrue(controller.status.contains("Speech-aware processing does not support"))
        XCTAssertTrue(controller.status.contains("Original audio remains available"))

        controller.stop()
        controller.stop()
        XCTAssertEqual(cleanupCount, 3)
        XCTAssertEqual(teardownSteps.count, 5)
        XCTAssertTrue(controller._testOnlyCaptureResourcesAreInactive())
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.runtimeState, .stopped)

        controller.start()
        XCTAssertEqual(startAttemptCount, 2)
        XCTAssertEqual(cleanupCount, 4)
        XCTAssertEqual(teardownSteps.count, 10)
        XCTAssertEqual(Array(teardownSteps.suffix(5)), [
            .activeOutputListeners,
            .stopIOProc,
            .destroyIOProc,
            .destroyAggregate,
            .destroyTap
        ])
        XCTAssertTrue(controller._testOnlyCaptureResourcesAreInactive())
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.runtimeState, .failed)
    }

    @available(macOS 14.2, *)
    @MainActor
    func testSuccessfulRefreshClearsOnlyAProcessEnumerationFailure() {
        enum RefreshFailure: Error { case unavailable }
        var shouldFail = true
        let controller = AudioCaptureController(
            installSystemObservers: false,
            loadProcessesOverride: {
                if shouldFail { throw RefreshFailure.unavailable }
                return []
            }
        )

        controller.refreshProcesses()
        XCTAssertEqual(controller.runtimeState, .failed)

        shouldFail = false
        controller.refreshProcesses()
        XCTAssertEqual(controller.runtimeState, .ready)
        XCTAssertTrue(controller.status.contains("No app is producing audio"))
    }

    @available(macOS 14.2, *)
    @MainActor
    func testRouteChangeTearsDownAndReconstructsFreshStereoProcessorsAtNewRate() async throws {
        let model = try RNNoiseModelResource.bundled()
        let creations = AnalyzerCreationRecorder()
        let oldFormat = floatFormat(sampleRate: 48_000, channelCount: 2)
        let oldProcessor = try AudioIOProcessor(
            inputFormat: oldFormat,
            outputFormat: oldFormat,
            settings: neutralSettings(),
            speechModel: model,
            stereoSpeechProcessorFactory: { sampleRate in
                creations.append(sampleRate)
                return try RNNoiseStereoProcessor(sampleRate: sampleRate, model: model)
            }
        )
        var oldInput = Array(repeating: Float(0.08), count: 480 * 2)
        var oldOutput = Array(repeating: Float.zero, count: 480 * 2)
        for _ in 0..<5 {
            withInterleavedStereoBuffer(samples: &oldInput) { inputList in
                withMutableInterleavedBuffer(samples: &oldOutput, channelCount: 2) { outputList in
                    oldProcessor.process(input: inputList, output: outputList)
                }
            }
        }
        XCTAssertEqual(oldProcessor.directProcessingLatencyFrameCount, 1_440)
        XCTAssertEqual(creations.values, [48_000, 48_000])

        var stopCount = 0
        var restartError: Error?
        var resumedFiniteAudio = false
        let restarted = expectation(description: "route restarted")
        let controller = AudioCaptureController(
            installSystemObservers: false,
            initiallyRunning: true,
            stopResourcesDidRun: { stopCount += 1 },
            startPipelineOverride: { _ in
                do {
                    let newFormat = self.floatFormat(sampleRate: 16_000, channelCount: 2)
                    let newProcessor = try AudioIOProcessor(
                        inputFormat: newFormat,
                        outputFormat: newFormat,
                        settings: self.neutralSettings(),
                        speechModel: model,
                        stereoSpeechProcessorFactory: { sampleRate in
                            creations.append(sampleRate)
                            return try RNNoiseStereoProcessor(
                                sampleRate: sampleRate,
                                model: model
                            )
                        }
                    )
                    XCTAssertEqual(newProcessor.directProcessingLatencyFrameCount, 528)
                    var input = Array(repeating: Float(0.08), count: 160 * 2)
                    var output = Array(repeating: Float.zero, count: 160 * 2)
                    var accumulatedOutput: [Float] = []
                    for _ in 0..<6 {
                        self.withInterleavedStereoBuffer(samples: &input) { inputList in
                            self.withMutableInterleavedBuffer(
                                samples: &output,
                                channelCount: 2
                            ) { outputList in
                                newProcessor.process(input: inputList, output: outputList)
                            }
                        }
                        accumulatedOutput.append(contentsOf: output)
                    }
                    resumedFiniteAudio = accumulatedOutput.allSatisfy(\.isFinite)
                        && accumulatedOutput.contains { abs($0) > 0.000_001 }
                        && newProcessor.takePendingFailure() == nil
                } catch {
                    restartError = error
                }
                restarted.fulfill()
            },
            routeRecoveryDelayNanoseconds: 0
        )

        controller._testOnlyHandleOutputRouteChange()
        XCTAssertEqual(controller.runtimeState, .recovering)
        await fulfillment(of: [restarted], timeout: 2)

        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(restartError)
        XCTAssertTrue(resumedFiniteAudio)
        XCTAssertEqual(creations.values, [48_000, 48_000, 16_000, 16_000])
    }
}
