// SPDX-License-Identifier: MPL-2.0

import Foundation

struct AudioCaptureLivenessPolicy: Equatable, Sendable {
    let pollIntervalNanoseconds: UInt64
    let verificationDelayNanoseconds: UInt64
    let confirmationDelayNanoseconds: UInt64
    let healthyResetDelayNanoseconds: UInt64

    static let production = AudioCaptureLivenessPolicy(
        pollIntervalNanoseconds: 100_000_000,
        verificationDelayNanoseconds: 2_000_000_000,
        confirmationDelayNanoseconds: 300_000_000,
        healthyResetDelayNanoseconds: 5_000_000_000
    )
}

@MainActor
final class AudioCaptureLivenessMonitor {
    private enum WatcherOwnership {
        case idle
        case active(
            id: UInt64,
            task: Task<Void, Never>,
            probe: (any AudioPlaybackActivityProbing)?,
            cancellationRequested: Bool
        )
        case retainedAfterCleanupFailure(
            probe: any AudioPlaybackActivityProbing,
            steps: [AudioCaptureTeardownStep]
        )
    }

    private var monitorTask: Task<Void, Never>?
    private var watcherOwnership = WatcherOwnership.idle
    private var nextWatcherID: UInt64 = 0
    private var activePipeline: (any AudioCapturePipeline)?
    private var latestObservation: AudioCaptureLivenessObservation?
    private let playbackActivityProbeBuilder:
        (any AudioPlaybackActivityProbeBuilding)?
    private let pollIntervalNanoseconds: UInt64
    private let automaticVerificationDelayNanoseconds: UInt64
    private let automaticConfirmationDelayNanoseconds: UInt64
    private let healthyRecoveryResetDelayNanoseconds: UInt64
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private var automaticRecoveryEnabled = false
    private var watcherAttemptedForZeroRun = false
    private var automaticRecoveryBlockedUntilHealthy = false
    private var exactZeroDeliveryBeganAt: UInt64?
    private var healthyNonzeroDeliveryBeganAt: UInt64?
    private var confirmedStaleCaptureAction: (@MainActor () -> Void)?

    init(
        playbackActivityProbeBuilder:
            (any AudioPlaybackActivityProbeBuilding)? = nil,
        pollIntervalNanoseconds: UInt64 = 100_000_000,
        automaticVerificationDelayNanoseconds: UInt64 = 2_000_000_000,
        automaticConfirmationDelayNanoseconds: UInt64 = 300_000_000,
        healthyRecoveryResetDelayNanoseconds: UInt64 = 5_000_000_000,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.playbackActivityProbeBuilder = playbackActivityProbeBuilder
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.automaticVerificationDelayNanoseconds =
            automaticVerificationDelayNanoseconds
        self.automaticConfirmationDelayNanoseconds =
            automaticConfirmationDelayNanoseconds
        self.healthyRecoveryResetDelayNanoseconds =
            healthyRecoveryResetDelayNanoseconds
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    convenience init(
        playbackActivityProbeBuilder:
            (any AudioPlaybackActivityProbeBuilding)? = nil,
        policy: AudioCaptureLivenessPolicy,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.init(
            playbackActivityProbeBuilder: playbackActivityProbeBuilder,
            pollIntervalNanoseconds: policy.pollIntervalNanoseconds,
            automaticVerificationDelayNanoseconds:
                policy.verificationDelayNanoseconds,
            automaticConfirmationDelayNanoseconds:
                policy.confirmationDelayNanoseconds,
            healthyRecoveryResetDelayNanoseconds:
                policy.healthyResetDelayNanoseconds,
            uptimeNanoseconds: uptimeNanoseconds
        )
    }

    func start(
        pipeline: any AudioCapturePipeline,
        automaticRecoveryEnabled: Bool = false,
        resetAutomaticRecoveryCircuitBreaker: Bool = false,
        isCurrent: @escaping @MainActor (any AudioCapturePipeline) -> Bool,
        onConfirmedStaleCapture: @escaping @MainActor () -> Void
    ) {
        activePipeline = pipeline
        self.automaticRecoveryEnabled = automaticRecoveryEnabled
        watcherAttemptedForZeroRun = false
        exactZeroDeliveryBeganAt = nil
        healthyNonzeroDeliveryBeganAt = nil
        confirmedStaleCaptureAction = onConfirmedStaleCapture
        if resetAutomaticRecoveryCircuitBreaker {
            automaticRecoveryBlockedUntilHealthy = false
        }
        monitorTask = Task { @MainActor [weak pipeline] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                guard let pipeline,
                      isCurrent(pipeline),
                      !Task.isCancelled
                else { return }
                for observation in pipeline.drainLivenessObservations() {
                    latestObservation = observation
                    considerCircuitBreakerReset(for: observation)
                    considerWatcherStart(for: observation)
                }
            }
        }
    }

    func stopAndWait() async -> AudioCaptureTeardownReport {
        monitorTask?.cancel()
        monitorTask = nil

        let pendingWatcher = requestActiveWatcherCancellation()
        if let pendingWatcher { await pendingWatcher.value }

        activePipeline = nil
        latestObservation = nil
        automaticRecoveryEnabled = false
        watcherAttemptedForZeroRun = false
        exactZeroDeliveryBeganAt = nil
        healthyNonzeroDeliveryBeganAt = nil
        confirmedStaleCaptureAction = nil

        switch watcherOwnership {
        case .idle:
            return .complete
        case let .retainedAfterCleanupFailure(_, steps):
            return AudioCaptureTeardownReport(unresolvedSteps: steps)
        case .active:
            return AudioCaptureTeardownReport(
                unresolvedSteps: [.finishPlaybackActivityWatcher]
            )
        }
    }

    private func considerWatcherStart(
        for observation: AudioCaptureLivenessObservation
    ) {
        guard automaticRecoveryEnabled else { return }
        guard observation.isExactFullFrameZeroDelivery else {
            exactZeroDeliveryBeganAt = nil
            watcherAttemptedForZeroRun = false
            cancelActiveWatcher()
            return
        }
        guard !automaticRecoveryBlockedUntilHealthy,
              !watcherAttemptedForZeroRun
        else { return }
        let now = uptimeNanoseconds()
        guard let beganAt = exactZeroDeliveryBeganAt else {
            exactZeroDeliveryBeganAt = now
            return
        }
        guard now &- beganAt >= automaticVerificationDelayNanoseconds else {
            return
        }
        if installPlaybackActivityWatcher() {
            watcherAttemptedForZeroRun = true
        }
    }

    private func installPlaybackActivityWatcher() -> Bool {
        guard case .idle = watcherOwnership,
              let pipeline = activePipeline,
              let configuration = pipeline.playbackActivityConfiguration,
              let playbackActivityProbeBuilder
        else { return false }

        nextWatcherID &+= 1
        let watcherID = nextWatcherID
        let task = Task { @MainActor [weak self, weak pipeline] in
            guard let self, let pipeline else { return }
            await runWatcher(
                id: watcherID,
                pipeline: pipeline,
                configuration: configuration,
                builder: playbackActivityProbeBuilder
            )
        }
        watcherOwnership = .active(
            id: watcherID,
            task: task,
            probe: nil,
            cancellationRequested: false
        )
        return true
    }

    private func runWatcher(
        id: UInt64,
        pipeline: any AudioCapturePipeline,
        configuration: AudioPlaybackActivityConfiguration,
        builder: any AudioPlaybackActivityProbeBuilding
    ) async {
        guard !Task.isCancelled else {
            releaseWatcher(
                id: id,
                pipeline: pipeline,
                rearmCurrentZeroRun: shouldRearmCurrentZeroRun(for: pipeline)
            )
            return
        }
        let probe: any AudioPlaybackActivityProbing
        do {
            probe = try builder.makeProbe(configuration: configuration)
        } catch {
            releaseWatcher(id: id, pipeline: pipeline, rearmCurrentZeroRun: true)
            return
        }
        guard attach(probe: probe, toWatcher: id) else {
            probe.cancel()
            return
        }

        let outcome = await probe.observeUntilSignalOrCancelled()
        if case let .cleanupFailed(steps) = outcome {
            retainFailedWatcher(id: id, probe: probe, steps: steps)
            return
        }
        guard activePipeline === pipeline, !Task.isCancelled else {
            releaseWatcher(
                id: id,
                pipeline: pipeline,
                rearmCurrentZeroRun: shouldRearmCurrentZeroRun(for: pipeline)
            )
            return
        }
        switch outcome {
        case let .signalDetected(count):
            await confirmIndependentSignal(
                watcherID: id,
                pipeline: pipeline,
                qualifyingCallbackCount: count
            )
        case .malformedInput, .cancelled, .coreAudioFailure, .cleanupFailed:
            releaseWatcher(id: id, pipeline: pipeline, rearmCurrentZeroRun: true)
        }
    }

    private func attach(
        probe: any AudioPlaybackActivityProbing,
        toWatcher id: UInt64
    ) -> Bool {
        guard case let .active(
            activeID,
            task,
            nil,
            cancellationRequested
        ) = watcherOwnership,
              activeID == id
        else { return false }
        watcherOwnership = .active(
            id: id,
            task: task,
            probe: probe,
            cancellationRequested: cancellationRequested
        )
        if cancellationRequested {
            probe.cancel()
        }
        return true
    }

    private func cancelActiveWatcher() {
        _ = requestActiveWatcherCancellation()
    }

    private func requestActiveWatcherCancellation() -> Task<Void, Never>? {
        guard case let .active(
            id,
            task,
            probe,
            cancellationRequested
        ) = watcherOwnership else { return nil }
        guard !cancellationRequested else { return task }
        watcherOwnership = .active(
            id: id,
            task: task,
            probe: probe,
            cancellationRequested: true
        )
        task.cancel()
        probe?.cancel()
        return task
    }

    private func retainFailedWatcher(
        id: UInt64,
        probe: any AudioPlaybackActivityProbing,
        steps: [AudioCaptureTeardownStep]
    ) {
        guard case let .active(activeID, _, _, _) = watcherOwnership,
              activeID == id
        else { return }
        watcherOwnership = .retainedAfterCleanupFailure(
            probe: probe,
            steps: steps
        )
    }

    private func releaseWatcher(
        id: UInt64,
        pipeline: any AudioCapturePipeline,
        rearmCurrentZeroRun: Bool
    ) {
        guard case let .active(activeID, _, _, _) = watcherOwnership,
              activeID == id
        else { return }
        watcherOwnership = .idle
        guard rearmCurrentZeroRun,
              monitorTask != nil,
              activePipeline === pipeline,
              let latestObservation
        else { return }
        let retriesSameZeroRun = watcherAttemptedForZeroRun
        watcherAttemptedForZeroRun = false
        if retriesSameZeroRun {
            exactZeroDeliveryBeganAt = nil
        }
        considerWatcherStart(for: latestObservation)
    }

    private func confirmIndependentSignal(
        watcherID: UInt64,
        pipeline: any AudioCapturePipeline,
        qualifyingCallbackCount: UInt32
    ) async {
        guard qualifyingCallbackCount >= 2,
              let sequenceAtSignal = latestObservation?.callbackSequence
        else {
            releaseWatcher(
                id: watcherID,
                pipeline: pipeline,
                rearmCurrentZeroRun: false
            )
            return
        }
        do {
            try await Task.sleep(
                nanoseconds: automaticConfirmationDelayNanoseconds
            )
        } catch {
            releaseWatcher(
                id: watcherID,
                pipeline: pipeline,
                rearmCurrentZeroRun: shouldRearmCurrentZeroRun(for: pipeline)
            )
            return
        }
        guard activePipeline === pipeline, !Task.isCancelled else {
            releaseWatcher(
                id: watcherID,
                pipeline: pipeline,
                rearmCurrentZeroRun: shouldRearmCurrentZeroRun(for: pipeline)
            )
            return
        }
        for observation in pipeline.drainLivenessObservations() {
            latestObservation = observation
        }
        guard let observation = latestObservation,
              observation.callbackSequence > sequenceAtSignal,
              observation.isExactFullFrameZeroDelivery
        else {
            releaseWatcher(
                id: watcherID,
                pipeline: pipeline,
                rearmCurrentZeroRun: false
            )
            return
        }
        automaticRecoveryBlockedUntilHealthy = true
        healthyNonzeroDeliveryBeganAt = nil
        releaseWatcher(
            id: watcherID,
            pipeline: pipeline,
            rearmCurrentZeroRun: false
        )
        confirmedStaleCaptureAction?()
    }

    private func shouldRearmCurrentZeroRun(
        for pipeline: any AudioCapturePipeline
    ) -> Bool {
        monitorTask != nil && activePipeline === pipeline
    }

    private func considerCircuitBreakerReset(
        for observation: AudioCaptureLivenessObservation
    ) {
        guard automaticRecoveryBlockedUntilHealthy else { return }
        guard observation.isHealthyNonzeroDelivery else {
            healthyNonzeroDeliveryBeganAt = nil
            return
        }
        let now = uptimeNanoseconds()
        guard let beganAt = healthyNonzeroDeliveryBeganAt else {
            healthyNonzeroDeliveryBeganAt = now
            return
        }
        guard now &- beganAt >= healthyRecoveryResetDelayNanoseconds else {
            return
        }
        automaticRecoveryBlockedUntilHealthy = false
        healthyNonzeroDeliveryBeganAt = nil
    }
}
