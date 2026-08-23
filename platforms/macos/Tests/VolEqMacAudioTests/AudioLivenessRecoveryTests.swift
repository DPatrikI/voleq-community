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
    AudioLivenessVerificationProbing,
    @unchecked Sendable {
    let outcome: AudioLivenessVerificationOutcome
    private let lock = NSLock()
    private var storedVerifyCount = 0
    private var storedCancelCount = 0
    private var storedModes: [AudioLivenessVerificationMode] = []

    init(outcome: AudioLivenessVerificationOutcome) {
        self.outcome = outcome
    }

    var verifyCount: Int { lock.withLock { storedVerifyCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    var modes: [AudioLivenessVerificationMode] {
        lock.withLock { storedModes }
    }

    func verify(
        mode: AudioLivenessVerificationMode
    ) async -> AudioLivenessVerificationOutcome {
        lock.withLock {
            storedVerifyCount += 1
            storedModes.append(mode)
        }
        return outcome
    }

    func cancel() { lock.withLock { storedCancelCount += 1 } }
}

private final class TestLivenessProbeBuilder:
    AudioLivenessVerificationProbeBuilding,
    @unchecked Sendable {
    let probe: ImmediateLivenessProbe
    private let lock = NSLock()
    private var storedConfigurations: [AudioLivenessVerificationConfiguration] = []

    init(outcome: AudioLivenessVerificationOutcome) {
        probe = ImmediateLivenessProbe(outcome: outcome)
    }

    var configurations: [AudioLivenessVerificationConfiguration] {
        lock.withLock { storedConfigurations }
    }

    func makeProbe(
        configuration: AudioLivenessVerificationConfiguration
    ) throws -> any AudioLivenessVerificationProbing {
        lock.withLock { storedConfigurations.append(configuration) }
        return probe
    }
}

private final class ControllableLivenessProbe:
    AudioLivenessVerificationProbing,
    @unchecked Sendable {
    private let lock = NSLock()
    private let completesWhenCancelled: Bool
    private var continuation:
        CheckedContinuation<AudioLivenessVerificationOutcome, Never>?
    private var pendingOutcome: AudioLivenessVerificationOutcome?
    private var storedVerifyCount = 0
    private var storedCancelCount = 0
    private var storedModes: [AudioLivenessVerificationMode] = []

    init(completesWhenCancelled: Bool = true) {
        self.completesWhenCancelled = completesWhenCancelled
    }

    var verifyCount: Int { lock.withLock { storedVerifyCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    var modes: [AudioLivenessVerificationMode] {
        lock.withLock { storedModes }
    }

    func verify(
        mode: AudioLivenessVerificationMode
    ) async -> AudioLivenessVerificationOutcome {
        await withCheckedContinuation { continuation in
            let immediateOutcome: AudioLivenessVerificationOutcome? =
                lock.withLock {
                storedVerifyCount += 1
                storedModes.append(mode)
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
        if completesWhenCancelled {
            complete(with: .cancelled)
        }
    }

    func complete(with outcome: AudioLivenessVerificationOutcome) {
        let storedContinuation: CheckedContinuation<
            AudioLivenessVerificationOutcome,
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
    AudioLivenessVerificationProbeBuilding,
    @unchecked Sendable {
    let probe: ControllableLivenessProbe

    init(probe: ControllableLivenessProbe = ControllableLivenessProbe()) {
        self.probe = probe
    }

    func makeProbe(
        configuration: AudioLivenessVerificationConfiguration
    ) throws -> any AudioLivenessVerificationProbing {
        probe
    }
}

private final class LivenessTestPipeline:
    AudioCapturePipeline,
    @unchecked Sendable {
    let heartbeat: AudioCallbackHeartbeat
    let processor: AudioIOProcessor?
    let runningStatusSuffix = ""
    let livenessVerificationConfiguration:
        AudioLivenessVerificationConfiguration? = .init(
            captureTarget: .deviceWide,
            outputDeviceUID: "test-output"
        )
    private let lock = NSLock()
    private var storedObservation: AudioLivenessObservation?
    private var storedDrainCount = 0
    private var faultInjected = false

    init(observation: AudioLivenessObservation?) throws {
        heartbeat = try AudioCallbackHeartbeat()
        processor = nil
        storedObservation = observation
    }

    func start() throws -> UInt64 { heartbeat.callbackCount }
    func stop() -> AudioCaptureTeardownReport { .complete }
    func updateSettings(_ settings: LevelingSettings) {}
    func drainDiagnosticTelemetry() -> AudioLivenessObservation? {
        lock.withLock {
            storedDrainCount += 1
            guard let observation = storedObservation else { return nil }
            return AudioLivenessObservation(
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
                outputRequestActive: observation.outputRequestActive,
                consecutiveAllZeroCallbacks:
                    observation.consecutiveAllZeroCallbacks
            )
        }
    }
    var drainCount: Int { lock.withLock { storedDrainCount } }
    func setObservation(_ observation: AudioLivenessObservation?) {
        lock.withLock { storedObservation = observation }
    }
    func setDiagnosticFaultInjectionEnabled(_ enabled: Bool) -> Bool {
        lock.withLock { faultInjected = enabled }
        return true
    }
    var isDiagnosticFaultInjectionEnabled: Bool {
        lock.withLock { faultInjected }
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
    func testRouteRecoveryAutomaticallyVerifiesSustainedExactZerosOnce() async throws {
        let clock = ManualLivenessClock()
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        var confirmations = 0
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
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
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        var confirmations = 0
        var statuses: [String] = []
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling normally",
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onStatus: { statuses.append($0) },
            onFailure: { _ in },
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
        XCTAssertEqual(
            builder.probe.modes,
            [.untilSignalOrCancelled]
        )
        XCTAssertEqual(confirmations, 0)
        XCTAssertTrue(statuses.isEmpty)
        let report = await monitor.stopAndWait()
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(builder.probe.cancelCount, 1)
    }

    func testFreshMainObservationPreventsReconnectWhenPlaybackResumesNormally() async throws {
        let clock = ManualLivenessClock()
        let builder = ControllableLivenessProbeBuilder()
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            automaticConfirmationDelayNanoseconds: 1_000_000,
            uptimeNanoseconds: { clock.now }
        )
        var confirmations = 0
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling normally",
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
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

    func testAutomaticRecoveryStaysBlockedUntilFiveSecondsOfHealthyAudio() async throws {
        let clock = ManualLivenessClock()
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            automaticConfirmationDelayNanoseconds: 1_000_000,
            healthyRecoveryResetDelayNanoseconds: 5_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        var confirmations = 0
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
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
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
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

    func testStopWaitsForActiveWatcherCleanup() async throws {
        let clock = ManualLivenessClock()
        let probe = ControllableLivenessProbe(completesWhenCancelled: false)
        let builder = ControllableLivenessProbeBuilder(probe: probe)
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
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
        let builder = TestLivenessProbeBuilder(
            outcome: .cleanupFailed([.destroyTap])
        )
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder
        )
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
            onConfirmedStaleCapture: {}
        )
        try await waitForAudioCondition("manual verification readiness") {
            monitor.requestVerification(reason: "cleanup-test")
        }
        try await waitForAudioCondition("cleanup failure outcome") {
            builder.probe.verifyCount == 1
        }

        let report = await monitor.stopAndWait()
        XCTAssertEqual(report.unresolvedSteps, [.destroyTap])
        XCTAssertFalse(report.permitsReplacementPipeline)
    }

    func testInitialPipelineNeverAutomaticallyProbesOrdinarySilence() async throws {
        let clock = ManualLivenessClock()
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
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
        let builder = TestLivenessProbeBuilder(outcome: .noSignal)
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 2_000_000_000,
            uptimeNanoseconds: { clock.now }
        )
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
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

    func testIndependentSignalConfirmsStaleMainCaptureOnce() async throws {
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder
        )
        var confirmations = 0
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
            onConfirmedStaleCapture: { confirmations += 1 }
        )
        try await waitForAudioCondition("initial liveness observation") {
            monitor.requestVerification(reason: "test")
        }
        try await waitForAudioCondition("stale capture confirmation") {
            confirmations == 1
        }

        XCTAssertEqual(builder.probe.verifyCount, 1)
        XCTAssertEqual(
            builder.probe.modes,
            [.bounded(timeoutNanoseconds: 3_000_000_000)]
        )
        XCTAssertEqual(builder.configurations.count, 1)
        XCTAssertEqual(confirmations, 1)
        _ = await monitor.stopAndWait()
    }

    func testIndependentSilenceDoesNotRecoverOrLeaveInjectedFailureEnabled() async throws {
        let builder = TestLivenessProbeBuilder(outcome: .noSignal)
        let pipeline = try LivenessTestPipeline(observation: exactZeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder
        )
        var confirmations = 0
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
            onConfirmedStaleCapture: { confirmations += 1 }
        )
        try await waitForAudioCondition("initial liveness observation") {
            monitor.requestVerification(reason: "test")
        }
        try await waitForAudioCondition("silent probe completion") {
            builder.probe.verifyCount == 1
                && !pipeline.isDiagnosticFaultInjectionEnabled
        }

        XCTAssertEqual(confirmations, 0)
        _ = await monitor.stopAndWait()
    }

    func testNonzeroMainCaptureSkipsProbe() async throws {
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let pipeline = try LivenessTestPipeline(observation: nonzeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder
        )
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
            onConfirmedStaleCapture: {}
        )
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(monitor.requestVerification(reason: "test"))
        XCTAssertEqual(builder.probe.verifyCount, 0)
        _ = await monitor.stopAndWait()
    }

    func testControlledFailureRunsOneProbeThenStopsInjectionDuringRecoveryTeardown() async throws {
        let builder = TestLivenessProbeBuilder(
            outcome: .signalDetected(qualifyingCallbackCount: 2)
        )
        let pipeline = try LivenessTestPipeline(observation: nonzeroObservation)
        let monitor = AudioCaptureDiagnosticsMonitor(
            verificationProbeBuilder: builder,
            pollIntervalNanoseconds: 1_000_000,
            automaticVerificationDelayNanoseconds: 1_000_000,
            automaticConfirmationDelayNanoseconds: 1_000_000
        )
        var confirmations = 0
        monitor.start(
            pipeline: pipeline,
            runningStatus: "Leveling",
            automaticRecoveryEnabled: true,
            isCurrent: { $0 === pipeline },
            onStatus: { _ in },
            onFailure: { _ in },
            onConfirmedStaleCapture: {
                confirmations += 1
            }
        )
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(monitor.beginControlledFailureTest())
        pipeline.setObservation(exactZeroObservation)
        try await waitForAudioCondition(
            "controlled liveness recovery",
            timeoutNanoseconds: 2_000_000_000
        ) {
            confirmations == 1
        }

        XCTAssertEqual(builder.probe.verifyCount, 1)
        XCTAssertFalse(pipeline.isDiagnosticFaultInjectionEnabled)
        _ = await monitor.stopAndWait()
    }

    func testSimulatedUnusableCaptureClearsOutputAndReportsFullFrameZeros() throws {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let processor = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        var input = [Float](repeating: 0.25, count: 128 * 2)
        var output = [Float](repeating: 0.75, count: 128 * 2)
        var metadata: AudioIOCallbackMetadata?
        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(
                samples: &output,
                channelCount: 2
            ) { outputList in
                metadata = processor.processSimulatedUnusableCapture(
                    input: inputList,
                    output: outputList
                )
            }
        }

        XCTAssertEqual(output, [Float](repeating: 0, count: output.count))
        let resolved = try XCTUnwrap(metadata)
        XCTAssertEqual(resolved.inputFrameCount, 128)
        XCTAssertEqual(resolved.outputFrameCount, 128)
        XCTAssertEqual(resolved.capturedPeak, 0)
        XCTAssertNotEqual(
            resolved.flags & UInt32(VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO),
            0
        )
    }

    func testSignalLatchRequiresTwoFiniteAboveThresholdCallbacks() throws {
        let latch = try AudioSignalLatch()
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
        let latch = try AudioSignalLatch()
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
    func testVerificationProbeUsesUnmutedInputOnlyGraphAndCleansUp() async throws {
        let recorder = LockedLivenessEventRecorder()
        let operations = CoreAudioCapturePipelineOperations(
            start: { _, _ in recorder.append("start"); return noErr },
            stop: { _, _ in recorder.append("stop"); return noErr },
            destroyIOProc: { _, _ in recorder.append("destroyIOProc"); return noErr },
            destroyAggregate: { _ in recorder.append("destroyAggregate"); return noErr },
            destroyTap: { _ in recorder.append("destroyTap"); return noErr },
            ownProcessObject: { 99 }
        )
        let probe = try CoreAudioLivenessVerificationProbe(
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
            await probe.verify(
                mode: .bounded(timeoutNanoseconds: 3_000_000_000)
            )
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
    func testPersistentVerificationProbeCancelsAndCleansUp() async throws {
        let recorder = LockedLivenessEventRecorder()
        let operations = CoreAudioCapturePipelineOperations(
            start: { _, _ in recorder.append("start"); return noErr },
            stop: { _, _ in recorder.append("stop"); return noErr },
            destroyIOProc: { _, _ in recorder.append("destroyIOProc"); return noErr },
            destroyAggregate: { _ in recorder.append("destroyAggregate"); return noErr },
            destroyTap: { _ in recorder.append("destroyTap"); return noErr },
            ownProcessObject: { 99 }
        )
        let probe = try CoreAudioLivenessVerificationProbe(
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
            await probe.verify(mode: .untilSignalOrCancelled)
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
    func testManualReconnectUsesNormalTeardownAndRebuild() async throws {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system
        controller.start()
        await waitForRuntimeState(controller, .active)

        XCTAssertTrue(controller.reconnectAudio())
        try await waitForAudioCondition("manual reconnect") {
            rig.pipelines.pipelines.count == 2
                && controller.runtimeState == .active
        }

        XCTAssertEqual(rig.pipelines.pipelines.first?.stopCount, 1)
        XCTAssertEqual(rig.pipelines.pipelines.last?.startCount, 1)
    }

    private var exactZeroObservation: AudioLivenessObservation {
        AudioLivenessObservation(
            callbackSequence: 100,
            capturedFrameCount: 512,
            requestedOutputFrameCount: 512,
            capturedPeak: 0,
            allZero: true,
            noCapturedFrames: false,
            partialDelivery: false,
            nonfiniteInput: false,
            outputRequestActive: true,
            consecutiveAllZeroCallbacks: 100
        )
    }

    private var nonzeroObservation: AudioLivenessObservation {
        AudioLivenessObservation(
            callbackSequence: 100,
            capturedFrameCount: 512,
            requestedOutputFrameCount: 512,
            capturedPeak: 0.25,
            allZero: false,
            noCapturedFrames: false,
            partialDelivery: false,
            nonfiniteInput: false,
            outputRequestActive: true,
            consecutiveAllZeroCallbacks: 0
        )
    }

    private var partialObservation: AudioLivenessObservation {
        AudioLivenessObservation(
            callbackSequence: 100,
            capturedFrameCount: 256,
            requestedOutputFrameCount: 512,
            capturedPeak: 0,
            allZero: true,
            noCapturedFrames: false,
            partialDelivery: true,
            nonfiniteInput: false,
            outputRequestActive: true,
            consecutiveAllZeroCallbacks: 100
        )
    }

    private var missingFrameObservation: AudioLivenessObservation {
        AudioLivenessObservation(
            callbackSequence: 100,
            capturedFrameCount: 0,
            requestedOutputFrameCount: 512,
            capturedPeak: 0,
            allZero: false,
            noCapturedFrames: true,
            partialDelivery: false,
            nonfiniteInput: false,
            outputRequestActive: true,
            consecutiveAllZeroCallbacks: 0
        )
    }

    private var nonfiniteObservation: AudioLivenessObservation {
        AudioLivenessObservation(
            callbackSequence: 100,
            capturedFrameCount: 512,
            requestedOutputFrameCount: 512,
            capturedPeak: 0,
            allZero: false,
            noCapturedFrames: false,
            partialDelivery: false,
            nonfiniteInput: true,
            outputRequestActive: true,
            consecutiveAllZeroCallbacks: 0
        )
    }
}

private final class LockedLivenessEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var events: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
