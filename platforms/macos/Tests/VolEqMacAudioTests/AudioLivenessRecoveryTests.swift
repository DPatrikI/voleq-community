// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import CoreAudio
import CVolEqRealtime
import Foundation
import VolEqCore
import XCTest
@testable import VolEqMacAudio

private let livenessTestIOProc: AudioDeviceIOProcID = {
    _, _, _, _, _, _, _ in noErr
}

private final class ImmediateLivenessProbe:
    AudioPlaybackActivityProbing,
    @unchecked Sendable {
    let outcome: AudioPlaybackActivityOutcome
    private let lock = NSLock()
    private var storedVerifyCount = 0
    private var storedCancelCount = 0

    init(outcome: AudioPlaybackActivityOutcome) {
        self.outcome = outcome
    }

    var verifyCount: Int { lock.withLock { storedVerifyCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    func observeUntilSignalOrCancelled() async -> AudioPlaybackActivityOutcome {
        lock.withLock {
            storedVerifyCount += 1
        }
        return outcome
    }

    func cancel() { lock.withLock { storedCancelCount += 1 } }
}

private final class TestLivenessProbeBuilder:
    AudioPlaybackActivityProbeBuilding,
    @unchecked Sendable {
    let probe: ImmediateLivenessProbe
    private let lock = NSLock()
    private var storedConfigurations: [AudioPlaybackActivityConfiguration] = []

    init(outcome: AudioPlaybackActivityOutcome) {
        probe = ImmediateLivenessProbe(outcome: outcome)
    }

    var configurations: [AudioPlaybackActivityConfiguration] {
        lock.withLock { storedConfigurations }
    }

    func makeProbe(
        configuration: AudioPlaybackActivityConfiguration
    ) throws -> any AudioPlaybackActivityProbing {
        lock.withLock { storedConfigurations.append(configuration) }
        return probe
    }
}

private final class ControllableLivenessProbe:
    AudioPlaybackActivityProbing,
    @unchecked Sendable {
    private let lock = NSLock()
    private let completesWhenCancelled: Bool
    private let onCancel: () -> Void
    private var continuation:
        CheckedContinuation<AudioPlaybackActivityOutcome, Never>?
    private var pendingOutcome: AudioPlaybackActivityOutcome?
    private var storedVerifyCount = 0
    private var storedCancelCount = 0

    init(
        completesWhenCancelled: Bool = true,
        onCancel: @escaping () -> Void = {}
    ) {
        self.completesWhenCancelled = completesWhenCancelled
        self.onCancel = onCancel
    }

    var verifyCount: Int { lock.withLock { storedVerifyCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    func observeUntilSignalOrCancelled() async -> AudioPlaybackActivityOutcome {
        await withCheckedContinuation { continuation in
            let immediateOutcome: AudioPlaybackActivityOutcome? =
                lock.withLock {
                storedVerifyCount += 1
                if let pendingOutcome {
                    self.pendingOutcome = nil
                    return pendingOutcome
                }
                self.continuation = continuation
                return nil
            }
            if let immediateOutcome {
                continuation.resume(returning: immediateOutcome)
            }
        }
    }

    func cancel() {
        lock.withLock { storedCancelCount += 1 }
        onCancel()
        if completesWhenCancelled {
            complete(with: .cancelled)
        }
    }

    func complete(with outcome: AudioPlaybackActivityOutcome) {
        let storedContinuation: CheckedContinuation<
            AudioPlaybackActivityOutcome,
            Never
        >? = lock.withLock {
            guard let continuation else {
                pendingOutcome = outcome
                return nil
            }
            self.continuation = nil
            return continuation
        }
        storedContinuation?.resume(returning: outcome)
    }
}

private final class ControllableLivenessProbeBuilder:
    AudioPlaybackActivityProbeBuilding,
    @unchecked Sendable {
    let probe: ControllableLivenessProbe

    init(probe: ControllableLivenessProbe = ControllableLivenessProbe()) {
        self.probe = probe
    }

    func makeProbe(
        configuration: AudioPlaybackActivityConfiguration
    ) throws -> any AudioPlaybackActivityProbing {
        probe
    }
}

private final class QueuedLivenessProbeBuilder:
    AudioPlaybackActivityProbeBuilding,
    @unchecked Sendable {
    private let lock = NSLock()
    private let probes: [ControllableLivenessProbe]
    private var nextIndex = 0

    init(probes: [ControllableLivenessProbe]) {
        self.probes = probes
    }

    var makeCount: Int { lock.withLock { nextIndex } }

    func makeProbe(
        configuration: AudioPlaybackActivityConfiguration
    ) throws -> any AudioPlaybackActivityProbing {
        try lock.withLock {
            guard probes.indices.contains(nextIndex) else {
                throw AudioCaptureTestError.unavailable
            }
            defer { nextIndex += 1 }
            return probes[nextIndex]
        }
    }
}

private final class LivenessTestPipeline:
    AudioCapturePipeline,
    @unchecked Sendable {
    let heartbeat: AudioCallbackHeartbeat
    let processor: AudioIOProcessor?
    let runningStatusSuffix = ""
    let playbackActivityConfiguration:
        AudioPlaybackActivityConfiguration? = .init(
            captureTarget: .deviceWide,
            outputDeviceUID: "test-output"
        )
    private let lock = NSLock()
    private var storedObservation: AudioCaptureLivenessObservation?
    private var storedDrainCount = 0

    init(observation: AudioCaptureLivenessObservation?) throws {
        heartbeat = try AudioCallbackHeartbeat()
        processor = nil
        storedObservation = observation
    }

    func start() throws -> UInt64 { heartbeat.callbackCount }
    func stop() -> AudioCaptureTeardownReport { .complete }
    func updateSettings(_ settings: LevelingSettings) {}
    func drainLivenessObservations() -> [AudioCaptureLivenessObservation] {
        lock.withLock {
            storedDrainCount += 1
            guard let observation = storedObservation else { return [] }
            return [AudioCaptureLivenessObservation(
                callbackSequence: observation.callbackSequence
                    &+ UInt64(storedDrainCount),
                capturedFrameCount: observation.capturedFrameCount,
                requestedOutputFrameCount:
                    observation.requestedOutputFrameCount,
                capturedPeak: observation.capturedPeak,
                allZero: observation.allZero,
                noCapturedFrames: observation.noCapturedFrames,
                partialDelivery: observation.partialDelivery,
                nonfiniteInput: observation.nonfiniteInput,
                outputRequestActive: observation.outputRequestActive
            )]
        }
    }
    var drainCount: Int { lock.withLock { storedDrainCount } }
    func setObservation(_ observation: AudioCaptureLivenessObservation?) {
        lock.withLock { storedObservation = observation }
    }
}

private final class ManualLivenessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow: UInt64 = 0

    var now: UInt64 { lock.withLock { storedNow } }
    func advance(_ nanoseconds: UInt64) {
        lock.withLock { storedNow += nanoseconds }
    }
}

@MainActor
final class AudioLivenessRecoveryTests: AudioPipelineTestCase {
    @available(macOS 14.2, *)
    func testControllerRebuildsOnceAndPreservesCircuitBreakerAcrossRuntimeReplacement(
    ) async throws {
        let exactZero = exactZeroObservation
        let nonzero = nonzeroObservation
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let clock = ManualLivenessClock()
        let rig = AudioCaptureTestRig()
        rig.playbackActivityProbeBuilder = builder
        rig.livenessUptimeNanoseconds = { clock.now }
        rig.livenessPolicy = AudioCaptureLivenessPolicy(
            pollIntervalNanoseconds: 1_000_000,
            verificationDelayNanoseconds: 2_000_000_000,
            confirmationDelayNanoseconds: 1_000_000,
            healthyResetDelayNanoseconds: 5_000_000_000
        )
        rig.pipelines.make = {
            try TestCapturePipeline(
                playbackActivityConfiguration: .init(
                    captureTarget: .deviceWide,
                    outputDeviceUID: "test-output"
                ),
                livenessObservation: exactZero
            )
        }
        let controller = rig.makeController()
        controller.mode = .system

        controller.start()
        try await waitForAudioCondition("initial exact-zero observation") {
            (rig.pipelines.pipelines.first?.livenessDrainCount ?? 0) > 0
        }
        clock.advance(2_000_000_000)
        try await waitForAudioCondition("confirmed-stale pipeline replacement") {
            rig.pipelines.pipelines.count == 2
                && controller.runtimeState == .active
        }
        let firstPipeline = try XCTUnwrap(rig.pipelines.pipelines.first)
        let replacementPipeline = try XCTUnwrap(rig.pipelines.pipelines.last)

        let replacementZeroDrainCount = replacementPipeline.livenessDrainCount
        try await waitForAudioCondition("replacement exact-zero observation") {
            replacementPipeline.livenessDrainCount
                > replacementZeroDrainCount
        }
        clock.advance(2_000_000_000)
        let blockedThresholdDrainCount = replacementPipeline.livenessDrainCount
        try await waitForAudioCondition("blocked verification threshold") {
            replacementPipeline.livenessDrainCount
                >= blockedThresholdDrainCount + 3
        }
        XCTAssertEqual(rig.pipelines.pipelines.count, 2)
        XCTAssertEqual(builder.probe.verifyCount, 1)
        XCTAssertEqual(firstPipeline.stopCount, 1)
        XCTAssertEqual(replacementPipeline.startCount, 1)

        replacementPipeline.livenessObservation = nonzero
        let firstHealthyDrainCount = replacementPipeline.livenessDrainCount
        try await waitForAudioCondition("first healthy observation") {
            replacementPipeline.livenessDrainCount > firstHealthyDrainCount
        }
        clock.advance(5_000_000_000)
        let resetDrainCount = replacementPipeline.livenessDrainCount
        try await waitForAudioCondition("healthy circuit-breaker reset") {
            replacementPipeline.livenessDrainCount > resetDrainCount
        }

        replacementPipeline.livenessObservation = exactZero
        let newZeroDrainCount = replacementPipeline.livenessDrainCount
        try await waitForAudioCondition("post-health exact-zero observation") {
            replacementPipeline.livenessDrainCount > newZeroDrainCount
        }
        clock.advance(2_000_000_000)

        try await waitForAudioCondition("post-health circuit-breaker reset") {
            rig.pipelines.pipelines.count == 3
                && controller.runtimeState == .active
        }
        XCTAssertEqual(builder.probe.verifyCount, 2)
        XCTAssertEqual(replacementPipeline.stopCount, 1)

        await controller.stopAndWait()
        await waitForRuntimeState(controller, .stopped)
    }

    func testRouteRecoveryAutomaticallyVerifiesSustainedExactZerosOnce() async throws {
        let clock = ManualLivenessClock()
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureLivenessMonitor(
            playbackActivityProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        var confirmations = 0
        monitor.start(
            pipeline: pipeline,
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onConfirmedStaleCapture: { confirmations += 1 }
        )
        try await waitForAudioCondition("initial automatic zero observation") {
            pipeline.drainCount > 0
        }
        clock.advance(2_000_000_000)
        try await waitForAudioCondition("automatic stale capture confirmation") {
            confirmations == 1
        }
        clock.advance(10_000_000_000)
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(builder.probe.verifyCount, 1)
        XCTAssertEqual(confirmations, 1)
        _ = await monitor.stopAndWait()
    }

    func testAutomaticWatcherRemainsArmedThroughArbitrarilyLongSilence() async throws {
        let clock = ManualLivenessClock()
        let builder = ControllableLivenessProbeBuilder()
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureLivenessMonitor(
            playbackActivityProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        var confirmations = 0
        monitor.start(
            pipeline: pipeline,
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onConfirmedStaleCapture: { confirmations += 1 }
        )
        try await waitForAudioCondition("initial silent observation") {
            pipeline.drainCount > 0
        }
        clock.advance(2_000_000_000)
        try await waitForAudioCondition("persistent automatic watcher") {
            builder.probe.verifyCount == 1
        }
        clock.advance(3_600_000_000_000)
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(builder.probe.verifyCount, 1)
        XCTAssertEqual(confirmations, 0)
        let report = await monitor.stopAndWait()
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(builder.probe.cancelCount, 1)
    }

    func testFreshMainObservationPreventsReconnectWhenPlaybackResumesNormally() async throws {
        let clock = ManualLivenessClock()
        let builder = ControllableLivenessProbeBuilder()
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureLivenessMonitor(
            playbackActivityProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            automaticConfirmationDelayNanoseconds: 1_000_000,
            uptimeNanoseconds: { clock.now }
        )
        var confirmations = 0
        monitor.start(
            pipeline: pipeline,
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onConfirmedStaleCapture: { confirmations += 1 }
        )
        try await waitForAudioCondition("initial exact-zero observation") {
            pipeline.drainCount > 0
        }
        clock.advance(2_000_000_000)
        try await waitForAudioCondition("automatic watcher start") {
            builder.probe.verifyCount == 1
        }

        pipeline.setObservation(nonzeroObservation)
        builder.probe.complete(with: .signalDetected(qualifyingCallbackCount: 2))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(confirmations, 0)
        _ = await monitor.stopAndWait()
    }

    func testNewZeroRunStartsAfterPreviousWatcherFinishesSlowCancellation() async throws {
        let clock = ManualLivenessClock()
        let firstWatcherCancelled = expectation(
            description: "first watcher cancellation"
        )
        let firstProbe = ControllableLivenessProbe(
            completesWhenCancelled: false,
            onCancel: { firstWatcherCancelled.fulfill() }
        )
        let secondProbe = ControllableLivenessProbe()
        let builder = QueuedLivenessProbeBuilder(
            probes: [firstProbe, secondProbe]
        )
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureLivenessMonitor(
            playbackActivityProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        monitor.start(
            pipeline: pipeline,
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onConfirmedStaleCapture: {}
        )
        try await waitForAudioCondition("initial exact-zero observation") {
            pipeline.drainCount > 0
        }
        clock.advance(2_000_000_000)
        try await waitForAudioCondition("first watcher start") {
            firstProbe.verifyCount == 1
        }

        pipeline.setObservation(nonzeroObservation)
        await fulfillment(of: [firstWatcherCancelled], timeout: 2)
        XCTAssertEqual(firstProbe.cancelCount, 1)
        pipeline.setObservation(exactZeroObservation)
        let newZeroDrain = pipeline.drainCount
        try await waitForAudioCondition("new zero run") {
            pipeline.drainCount > newZeroDrain
        }
        clock.advance(2_000_000_000)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(builder.makeCount, 1)

        firstProbe.complete(with: .cancelled)
        try await waitForAudioCondition("second watcher start") {
            secondProbe.verifyCount == 1
        }

        let report = await monitor.stopAndWait()
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(builder.makeCount, 2)
    }

    func testAutomaticRecoveryStaysBlockedUntilFiveSecondsOfHealthyAudio() async throws {
        let clock = ManualLivenessClock()
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureLivenessMonitor(
            playbackActivityProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            automaticConfirmationDelayNanoseconds: 1_000_000,
            healthyRecoveryResetDelayNanoseconds: 5_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        var confirmations = 0
        monitor.start(
            pipeline: pipeline,
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onConfirmedStaleCapture: { confirmations += 1 }
        )
        try await waitForAudioCondition("first zero observation") {
            pipeline.drainCount > 0
        }
        clock.advance(2_000_000_000)
        try await waitForAudioCondition("first confirmed recovery") {
            confirmations == 1
        }

        clock.advance(3_600_000_000_000)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(builder.probe.verifyCount, 1)

        pipeline.setObservation(nonzeroObservation)
        var drain = pipeline.drainCount
        try await waitForAudioCondition("healthy reset begins") {
            pipeline.drainCount > drain
        }
        clock.advance(5_000_000_000)
        drain = pipeline.drainCount
        try await waitForAudioCondition("healthy reset completes") {
            pipeline.drainCount > drain
        }

        pipeline.setObservation(exactZeroObservation)
        drain = pipeline.drainCount
        try await waitForAudioCondition("second zero observation") {
            pipeline.drainCount > drain
        }
        clock.advance(2_000_000_000)
        try await waitForAudioCondition("second confirmed recovery") {
            confirmations == 2
        }

        XCTAssertEqual(builder.probe.verifyCount, 2)
        _ = await monitor.stopAndWait()
    }

    func testPartialMissingAndNonfiniteInputNeverTriggerExactZeroRecovery() async throws {
        let clock = ManualLivenessClock()
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let pipeline = try LivenessTestPipeline(observation: partialObservation)
        let monitor = AudioCaptureLivenessMonitor(
            playbackActivityProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        monitor.start(
            pipeline: pipeline,
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onConfirmedStaleCapture: {}
        )

        for observation in [
            partialObservation,
            missingFrameObservation,
            nonfiniteObservation,
        ] {
            pipeline.setObservation(observation)
            let drain = pipeline.drainCount
            try await waitForAudioCondition("non-qualifying observation") {
                pipeline.drainCount > drain
            }
            clock.advance(10_000_000_000)
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(builder.probe.verifyCount, 0)
        _ = await monitor.stopAndWait()
    }

    func testLivenessObservationDoesNotChangeProcessedOutput() throws {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let regular = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        let observed = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        var input = (0..<(512 * 2)).map {
            Float(($0 % 19) - 9) * 0.002
        }
        var regularOutput = [Float](repeating: 0.75, count: 512 * 2)
        var observedOutput = regularOutput

        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(
                samples: &regularOutput,
                channelCount: 2
            ) { outputList in
                regular.process(input: inputList, output: outputList)
            }
            withMutableInterleavedBuffer(
                samples: &observedOutput,
                channelCount: 2
            ) { outputList in
                _ = observed.processWithLivenessObservation(
                    input: inputList,
                    output: outputList
                )
            }
        }

        XCTAssertEqual(observedOutput, regularOutput)
    }

    func testProcessorClassifiesOneFrameShortExactZeroDeliveryAsPartial() throws {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let regular = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        let observed = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        var input = [Float](repeating: 0, count: 511 * 2)
        var regularOutput = [Float](repeating: 0.75, count: 512 * 2)
        var observedOutput = regularOutput
        var metadata: AudioCaptureLivenessMetadata?

        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(
                samples: &regularOutput,
                channelCount: 2
            ) { outputList in
                regular.process(input: inputList, output: outputList)
            }
            withMutableInterleavedBuffer(
                samples: &observedOutput,
                channelCount: 2
            ) { outputList in
                metadata = observed.processWithLivenessObservation(
                    input: inputList,
                    output: outputList
                )
            }
        }

        XCTAssertEqual(observedOutput, regularOutput)
        let resolved = try XCTUnwrap(metadata)
        XCTAssertNotEqual(
            resolved.flags & UInt32(VOLEQ_LIVENESS_FLAG_ALL_ZERO),
            0
        )
        XCTAssertNotEqual(
            resolved.flags & UInt32(VOLEQ_LIVENESS_FLAG_PARTIAL_DELIVERY),
            0
        )
        XCTAssertEqual(resolved.capturedPeak, 0)
        XCTAssertEqual(resolved.inputFrameCount, 511)
        XCTAssertEqual(resolved.outputFrameCount, 512)
    }

    func testProcessorUsesFractionalRateFloorForPartialDelivery() throws {
        let inputFormat = floatFormat(sampleRate: 44_100, channelCount: 2)
        let outputFormat = floatFormat(sampleRate: 48_000, channelCount: 2)

        for (inputFrameCount, expectsPartial) in [(470, false), (469, true)] {
            let processor = try AudioIOProcessor(
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                settings: neutralSettings(),
                speechAwarenessEnabled: false
            )
            var input = [Float](
                repeating: 0,
                count: inputFrameCount * 2
            )
            var output = [Float](repeating: 0.75, count: 512 * 2)
            var metadata: AudioCaptureLivenessMetadata?

            withInterleavedStereoBuffer(samples: &input) { inputList in
                withMutableInterleavedBuffer(
                    samples: &output,
                    channelCount: 2
                ) { outputList in
                    metadata = processor.processWithLivenessObservation(
                        input: inputList,
                        output: outputList
                    )
                }
            }

            let resolved = try XCTUnwrap(metadata)
            let isPartial = resolved.flags
                & UInt32(VOLEQ_LIVENESS_FLAG_PARTIAL_DELIVERY) != 0
            XCTAssertEqual(
                isPartial,
                expectsPartial,
                "Unexpected partial classification for \(inputFrameCount) input frames"
            )
        }
    }

    func testProcessorClassifiesMissingInputChannelAsPartial() throws {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        var presentChannel = [Float](repeating: 0, count: 512)
        var output = [Float](repeating: 0.75, count: 512 * 2)
        var metadata: AudioCaptureLivenessMetadata?
        let inputList = AudioBufferList.allocate(maximumBuffers: 2)
        defer { inputList.unsafeMutablePointer.deallocate() }

        presentChannel.withUnsafeMutableBytes { bytes in
            inputList.count = 2
            inputList[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bytes.count),
                mData: bytes.baseAddress
            )
            inputList[1] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bytes.count),
                mData: nil
            )
            withMutableInterleavedBuffer(
                samples: &output,
                channelCount: 2
            ) { outputList in
                metadata = processor.processWithLivenessObservation(
                    input: inputList.unsafePointer,
                    output: outputList
                )
            }
        }

        let resolved = try XCTUnwrap(metadata)
        XCTAssertNotEqual(
            resolved.flags & UInt32(VOLEQ_LIVENESS_FLAG_ALL_ZERO),
            0
        )
        XCTAssertNotEqual(
            resolved.flags & UInt32(VOLEQ_LIVENESS_FLAG_PARTIAL_DELIVERY),
            0
        )
        XCTAssertEqual(resolved.inputFrameCount, 512)
    }

    func testStopWaitsForActiveWatcherCleanup() async throws {
        let clock = ManualLivenessClock()
        let probe = ControllableLivenessProbe(completesWhenCancelled: false)
        let builder = ControllableLivenessProbeBuilder(probe: probe)
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureLivenessMonitor(
            playbackActivityProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        monitor.start(
            pipeline: pipeline,
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onConfirmedStaleCapture: {}
        )
        try await waitForAudioCondition("initial zero observation") {
            pipeline.drainCount > 0
        }
        clock.advance(2_000_000_000)
        try await waitForAudioCondition("watcher start") {
            probe.verifyCount == 1
        }

        var stopCompleted = false
        let stop = Task { @MainActor in
            let report = await monitor.stopAndWait()
            stopCompleted = true
            return report
        }
        try await waitForAudioCondition("watcher cancellation") {
            probe.cancelCount == 1
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertFalse(stopCompleted)

        probe.complete(with: .cancelled)
        let report = await stop.value
        XCTAssertTrue(stopCompleted)
        XCTAssertTrue(report.isComplete)
    }

    func testWatcherCleanupFailureBlocksReplacement() async throws {
        let clock = ManualLivenessClock()
        let builder = TestLivenessProbeBuilder(
            outcome: .cleanupFailed([.destroyTap])
        )
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureLivenessMonitor(
            playbackActivityProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        monitor.start(
            pipeline: pipeline,
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onConfirmedStaleCapture: {}
        )
        try await waitForAudioCondition("initial exact-zero observation") {
            pipeline.drainCount > 0
        }
        clock.advance(2_000_000_000)
        try await waitForAudioCondition("cleanup failure outcome") {
            builder.probe.verifyCount == 1
        }

        let report = await monitor.stopAndWait()
        XCTAssertEqual(report.unresolvedSteps, [.destroyTap])
        XCTAssertFalse(report.permitsReplacementPipeline)
    }

    func testDisabledMonitorDoesNotProbeOrdinarySilence() async throws {
        let clock = ManualLivenessClock()
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureLivenessMonitor(
            playbackActivityProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        monitor.start(
            pipeline: pipeline,
            isCurrent: { $0 === pipeline },
            onConfirmedStaleCapture: {}
        )
        try await waitForAudioCondition("unarmed silent observation") {
            pipeline.drainCount > 0
        }
        clock.advance(20_000_000_000)
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(builder.probe.verifyCount, 0)
        _ = await monitor.stopAndWait()
    }

    func testNonzeroDeliveryResetsAutomaticZeroDuration() async throws {
        let clock = ManualLivenessClock()
        let builder = TestLivenessProbeBuilder(outcome: .cancelled)
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureLivenessMonitor(
            playbackActivityProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        monitor.start(
            pipeline: pipeline,
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onConfirmedStaleCapture: {}
        )
        try await waitForAudioCondition("first exact-zero observation") {
            pipeline.drainCount > 0
        }
        pipeline.setObservation(nonzeroObservation)
        clock.advance(2_000_000_000)
        let nonzeroDrain = pipeline.drainCount
        try await waitForAudioCondition("nonzero reset observation") {
            pipeline.drainCount > nonzeroDrain
        }
        pipeline.setObservation(exactZeroObservation)
        let resumedZeroDrain = pipeline.drainCount
        try await waitForAudioCondition("resumed zero observation") {
            pipeline.drainCount > resumedZeroDrain
        }
        clock.advance(1_999_999_999)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(builder.probe.verifyCount, 0)
        clock.advance(1)
        try await waitForAudioCondition("reset zero-duration probe") {
            builder.probe.verifyCount == 1
        }
        _ = await monitor.stopAndWait()
    }

    func testSignalLatchRequiresTwoFiniteAboveThresholdCallbacks() throws {
        let latch = try AudioPlaybackSignalLatch()
        var first = [Float(2.0e-4), 0]
        var subThresholdNoise = [Float(5.0e-5), 0]
        var second = [Float(0), -3.0e-4]

        withInterleavedStereoBuffer(samples: &first) { latch._testOnlyObserve($0) }
        withInterleavedStereoBuffer(samples: &subThresholdNoise) {
            latch._testOnlyObserve($0)
        }
        XCTAssertEqual(latch.qualifyingCallbackCount, 1)
        withInterleavedStereoBuffer(samples: &second) { latch._testOnlyObserve($0) }

        XCTAssertEqual(latch.qualifyingCallbackCount, 2)
        XCTAssertFalse(latch.isMalformed)
    }

    func testSignalLatchRejectsUnboundedCallbackMetadataBeforeScanning() throws {
        let latch = try AudioPlaybackSignalLatch()
        var sample = Float(0.25)
        withUnsafeMutablePointer(to: &sample) { samplePointer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32((65_536 + 1) * MemoryLayout<Float>.size),
                    mData: samplePointer
                )
            )
            withUnsafePointer(to: &list) { latch._testOnlyObserve($0) }
        }

        XCTAssertTrue(latch.isMalformed)
        XCTAssertEqual(latch.qualifyingCallbackCount, 0)
    }

    @available(macOS 14.2, *)
    func testPlaybackActivityProbeUsesUnmutedInputOnlyGraphAndCleansUp() async throws {
        let recorder = LockedLivenessEventRecorder()
        let operations = CoreAudioCapturePipelineOperations(
            start: { _, _ in recorder.append("start"); return noErr },
            stop: { _, _ in recorder.append("stop"); return noErr },
            destroyIOProc: { _, _ in recorder.append("destroyIOProc"); return noErr },
            destroyAggregate: { _ in recorder.append("destroyAggregate"); return noErr },
            destroyTap: { _ in recorder.append("destroyTap"); return noErr },
            ownProcessObject: { 99 }
        )
        let probe = try CoreAudioPlaybackActivityProbe(
            configuration: .init(
                captureTarget: .deviceWide,
                outputDeviceUID: "test-output"
            ),
            operations: operations,
            prepareResourcesOverride: {}
        )
        probe._testOnlyAdoptResources(
            tapID: 11,
            aggregateDeviceID: 12,
            ioProcID: livenessTestIOProc
        )
        let verification = Task {
            await probe.observeUntilSignalOrCancelled()
        }
        try await waitForAudioCondition("verification probe start") {
            recorder.events.contains("start")
        }
        var first = [Float(0.1), 0]
        var second = [Float(0), -0.1]
        withInterleavedStereoBuffer(samples: &first) { probe._testOnlyObserve($0) }
        withInterleavedStereoBuffer(samples: &second) { probe._testOnlyObserve($0) }

        let outcome = await verification.value
        XCTAssertEqual(
            outcome,
            .signalDetected(qualifyingCallbackCount: 2)
        )
        XCTAssertEqual(
            recorder.events,
            ["start", "stop", "destroyIOProc", "destroyAggregate", "destroyTap"]
        )
    }

    @available(macOS 14.2, *)
    func testPersistentPlaybackActivityProbeCancelsAndCleansUp() async throws {
        let recorder = LockedLivenessEventRecorder()
        let operations = CoreAudioCapturePipelineOperations(
            start: { _, _ in recorder.append("start"); return noErr },
            stop: { _, _ in recorder.append("stop"); return noErr },
            destroyIOProc: { _, _ in recorder.append("destroyIOProc"); return noErr },
            destroyAggregate: { _ in recorder.append("destroyAggregate"); return noErr },
            destroyTap: { _ in recorder.append("destroyTap"); return noErr },
            ownProcessObject: { 99 }
        )
        let probe = try CoreAudioPlaybackActivityProbe(
            configuration: .init(
                captureTarget: .deviceWide,
                outputDeviceUID: "test-output"
            ),
            operations: operations,
            pollNanoseconds: 1_000_000,
            prepareResourcesOverride: {}
        )
        probe._testOnlyAdoptResources(
            tapID: 21,
            aggregateDeviceID: 22,
            ioProcID: livenessTestIOProc
        )
        let verification = Task {
            await probe.observeUntilSignalOrCancelled()
        }
        try await waitForAudioCondition("persistent probe start") {
            recorder.events.contains("start")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        probe.cancel()

        let outcome = await verification.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(
            recorder.events,
            ["start", "stop", "destroyIOProc", "destroyAggregate", "destroyTap"]
        )
    }

    @available(macOS 14.2, *)
    func testBlockedPlaybackActivityStartReturnsBoundedCleanupFailure() async throws {
        let recorder = LockedLivenessEventRecorder()
        let releaseStart = DispatchSemaphore(value: 0)
        let operations = CoreAudioCapturePipelineOperations(
            start: { _, _ in
                recorder.append("start")
                _ = releaseStart.wait(timeout: .now() + .milliseconds(200))
                return noErr
            },
            stop: { _, _ in recorder.append("stop"); return noErr },
            destroyIOProc: { _, _ in
                recorder.append("destroyIOProc"); return noErr
            },
            destroyAggregate: { _ in
                recorder.append("destroyAggregate"); return noErr
            },
            destroyTap: { _ in recorder.append("destroyTap"); return noErr },
            ownProcessObject: { 99 }
        )
        let probe = try CoreAudioPlaybackActivityProbe(
            configuration: .init(
                captureTarget: .deviceWide,
                outputDeviceUID: "test-output"
            ),
            operations: operations,
            pollNanoseconds: 1_000_000,
            prepareResourcesOverride: {},
            startShutdownWaitNanoseconds: 1_000_000
        )
        probe._testOnlyAdoptResources(
            tapID: 31,
            aggregateDeviceID: 32,
            ioProcID: livenessTestIOProc
        )
        let verification = Task {
            await probe.observeUntilSignalOrCancelled()
        }
        try await waitForAudioCondition("blocked watcher start") {
            recorder.events.contains("start")
        }
        let beganAt = DispatchTime.now().uptimeNanoseconds
        probe.cancel()

        let outcome = await verification.value
        let elapsed = DispatchTime.now().uptimeNanoseconds - beganAt
        releaseStart.signal()

        XCTAssertEqual(
            outcome,
            .cleanupFailed([
                .finishIOProcStart,
                .destroyIOProc,
                .destroyAggregate,
                .destroyTap,
            ])
        )
        XCTAssertLessThan(elapsed, 100_000_000)
    }

    private var exactZeroObservation: AudioCaptureLivenessObservation {
        AudioCaptureLivenessObservation(
            callbackSequence: 100,
            capturedFrameCount: 512,
            requestedOutputFrameCount: 512,
            capturedPeak: 0,
            allZero: true,
            noCapturedFrames: false,
            partialDelivery: false,
            nonfiniteInput: false,
            outputRequestActive: true
        )
    }

    private var nonzeroObservation: AudioCaptureLivenessObservation {
        AudioCaptureLivenessObservation(
            callbackSequence: 100,
            capturedFrameCount: 512,
            requestedOutputFrameCount: 512,
            capturedPeak: 0.25,
            allZero: false,
            noCapturedFrames: false,
            partialDelivery: false,
            nonfiniteInput: false,
            outputRequestActive: true
        )
    }

    private var partialObservation: AudioCaptureLivenessObservation {
        AudioCaptureLivenessObservation(
            callbackSequence: 100,
            capturedFrameCount: 256,
            requestedOutputFrameCount: 512,
            capturedPeak: 0,
            allZero: true,
            noCapturedFrames: false,
            partialDelivery: true,
            nonfiniteInput: false,
            outputRequestActive: true
        )
    }

    private var missingFrameObservation: AudioCaptureLivenessObservation {
        AudioCaptureLivenessObservation(
            callbackSequence: 100,
            capturedFrameCount: 0,
            requestedOutputFrameCount: 512,
            capturedPeak: 0,
            allZero: false,
            noCapturedFrames: true,
            partialDelivery: false,
            nonfiniteInput: false,
            outputRequestActive: true
        )
    }

    private var nonfiniteObservation: AudioCaptureLivenessObservation {
        AudioCaptureLivenessObservation(
            callbackSequence: 100,
            capturedFrameCount: 512,
            requestedOutputFrameCount: 512,
            capturedPeak: 0,
            allZero: false,
            noCapturedFrames: false,
            partialDelivery: false,
            nonfiniteInput: true,
            outputRequestActive: true
        )
    }
}

private final class LockedLivenessEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var events: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
