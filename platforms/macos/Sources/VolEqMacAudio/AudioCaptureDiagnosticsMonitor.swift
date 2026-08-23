// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation

@MainActor
final class AudioCaptureDiagnosticsMonitor {
    private enum VerificationTrigger {
        case userRequested(String)
        case automaticDuringExactZero

        var diagnosticReason: String {
            switch self {
            case let .userRequested(reason): reason
            case .automaticDuringExactZero: "automaticDuringExactZero"
            }
        }

        var isAutomatic: Bool {
            if case .automaticDuringExactZero = self { return true }
            return false
        }

        var mode: AudioLivenessVerificationMode {
            switch self {
            case .userRequested:
                .bounded(timeoutNanoseconds: 3_000_000_000)
            case .automaticDuringExactZero:
                .untilSignalOrCancelled
            }
        }
    }

    private var task: Task<Void, Never>?
    private var verificationTask: Task<Void, Never>?
    private var activePipeline: (any AudioCapturePipeline)?
    private var activeProbe: (any AudioLivenessVerificationProbing)?
    private var retainedProbeAfterCleanupFailure:
        (any AudioLivenessVerificationProbing)?
    private var retainedProbeCleanupSteps: [AudioCaptureTeardownStep] = []
    private var latestObservation: AudioLivenessObservation?
    private let verificationProbeBuilder:
        (any AudioLivenessVerificationProbeBuilding)?
    private let diagnostics: (any AudioLivenessDiagnosticsRecording)?
    private let pollIntervalNanoseconds: UInt64
    private let automaticVerificationDelayNanoseconds: UInt64
    private let automaticConfirmationDelayNanoseconds: UInt64
    private let healthyRecoveryResetDelayNanoseconds: UInt64
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private var runningStatus = ""
    private var automaticRecoveryEnabled = false
    private var automaticVerificationAttemptedForZeroRun = false
    private var automaticRecoveryBlockedUntilHealthy = false
    private var exactZeroDeliveryBeganAt: UInt64?
    private var healthyNonzeroDeliveryBeganAt: UInt64?
    private var activeVerificationTrigger: VerificationTrigger?

    init(
        verificationProbeBuilder:
            (any AudioLivenessVerificationProbeBuilding)? = nil,
        diagnostics: (any AudioLivenessDiagnosticsRecording)? = nil,
        pollIntervalNanoseconds: UInt64 = 100_000_000,
        automaticVerificationDelayNanoseconds: UInt64 = 2_000_000_000,
        automaticConfirmationDelayNanoseconds: UInt64 = 300_000_000,
        healthyRecoveryResetDelayNanoseconds: UInt64 = 5_000_000_000,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.verificationProbeBuilder = verificationProbeBuilder
        self.diagnostics = diagnostics
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.automaticVerificationDelayNanoseconds =
            automaticVerificationDelayNanoseconds
        self.automaticConfirmationDelayNanoseconds =
            automaticConfirmationDelayNanoseconds
        self.healthyRecoveryResetDelayNanoseconds =
            healthyRecoveryResetDelayNanoseconds
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    func start(
        pipeline: any AudioCapturePipeline,
        runningStatus: String,
        automaticRecoveryEnabled: Bool = false,
        resetAutomaticRecoveryCircuitBreaker: Bool = false,
        isCurrent: @escaping @MainActor (any AudioCapturePipeline) -> Bool,
        onStatus: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (OSStatus) -> Void,
        onConfirmedStaleCapture: @escaping @MainActor () -> Void
    ) {
        let processor = pipeline.processor
        activePipeline = pipeline
        self.runningStatus = runningStatus
        self.automaticRecoveryEnabled = automaticRecoveryEnabled
        automaticVerificationAttemptedForZeroRun = false
        exactZeroDeliveryBeganAt = nil
        healthyNonzeroDeliveryBeganAt = nil
        activeVerificationTrigger = nil
        if resetAutomaticRecoveryCircuitBreaker {
            automaticRecoveryBlockedUntilHealthy = false
        }
        task = Task { @MainActor [weak pipeline] in
            var diagnosticsRecorded = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                guard let pipeline,
                      isCurrent(pipeline),
                      !Task.isCancelled
                else { return }
                if let observation = pipeline.drainDiagnosticTelemetry() {
                    latestObservation = observation
                    considerAutomaticRecoveryCircuitBreakerReset(
                        for: observation
                    )
                    considerAutomaticVerification(for: observation)
                }
                if let failure = processor?.takePendingFailure() {
                    pipeline.recordDiagnosticProcessingFailure(failure)
                    onFailure(failure)
                    return
                }
                guard !diagnosticsRecorded,
                      let processor,
                      let diagnostics = processor.currentDiagnostics()
                else { continue }

                switch diagnostics.path {
                case .directAggregateClock:
                    onStatus(processor.usesSampleRateConversion
                        ? runningStatus + " Core Audio synchronized this route (\(diagnostics.inputFrameCount)→\(diagnostics.outputFrameCount) frames); duplicate conversion is bypassed."
                        : runningStatus)
                case .sampleRateConverter:
                    onStatus(
                        runningStatus + " Output conversion is active (\(diagnostics.inputFrameCount)→\(diagnostics.outputFrameCount) callback frames; \(Int(processor.inputSampleRate))→\(Int(processor.outputSampleRate)) Hz)."
                    )
                }
                diagnosticsRecorded = true
            }
        }
        confirmedStaleCaptureAction = onConfirmedStaleCapture
        statusAction = onStatus
    }

    func stopAndWait() async -> AudioCaptureTeardownReport {
        task?.cancel()
        task = nil
        verificationTask?.cancel()
        activeProbe?.cancel()
        let pendingVerification = verificationTask
        if let pendingVerification {
            await pendingVerification.value
        }
        verificationTask = nil
        activeProbe = nil
        _ = activePipeline?.setDiagnosticFaultInjectionEnabled(false)
        activePipeline = nil
        latestObservation = nil
        runningStatus = ""
        automaticRecoveryEnabled = false
        automaticVerificationAttemptedForZeroRun = false
        exactZeroDeliveryBeganAt = nil
        healthyNonzeroDeliveryBeganAt = nil
        activeVerificationTrigger = nil
        confirmedStaleCaptureAction = nil
        statusAction = nil
        guard retainedProbeAfterCleanupFailure != nil else {
            return .complete
        }
        return AudioCaptureTeardownReport(
            unresolvedSteps: retainedProbeCleanupSteps
        )
    }

    private var confirmedStaleCaptureAction: (@MainActor () -> Void)?
    private var statusAction: (@MainActor (String) -> Void)?

    @discardableResult
    func requestVerification(reason: String) -> Bool {
        requestVerification(trigger: .userRequested(reason))
    }

    @discardableResult
    private func requestVerification(trigger: VerificationTrigger) -> Bool {
        guard verificationTask == nil,
              retainedProbeAfterCleanupFailure == nil,
              let pipeline = activePipeline,
              let configuration = pipeline.livenessVerificationConfiguration,
              let verificationProbeBuilder
        else { return false }
        guard latestObservation?.isExactFullFrameZeroDelivery == true else {
            diagnostics?.recordRecoveryExperimentEvent(
                kind: "livenessVerificationSkipped",
                reason: "The main capture path was not currently delivering exact full-frame zeros."
            )
            statusAction?(
                "Audio verification was not needed because captured audio is currently available."
            )
            return false
        }

        diagnostics?.recordRecoveryExperimentEvent(
            kind: "livenessVerificationRequested",
            reason: trigger.diagnosticReason
        )
        if !trigger.isAutomatic {
            statusAction?(
                "Verifying the captured-audio path without recording audio…"
            )
        }
        activeVerificationTrigger = trigger
        verificationTask = Task { @MainActor [weak self, weak pipeline] in
            guard let self, let pipeline else { return }
            let probe: any AudioLivenessVerificationProbing
            do {
                probe = try verificationProbeBuilder.makeProbe(
                    configuration: configuration
                )
            } catch {
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: "livenessProbePreparationFailed",
                    reason: error.localizedDescription,
                    trigger: trigger
                )
                return
            }
            activeProbe = probe
            diagnostics?.recordRecoveryExperimentEvent(
                kind: trigger.isAutomatic
                    ? "livenessSentinelStarted"
                    : "livenessProbeStarted",
                reason: trigger.diagnosticReason
            )
            let outcome = await probe.verify(mode: trigger.mode)
            if case let .cleanupFailed(steps) = outcome {
                retainedProbeAfterCleanupFailure = probe
                retainedProbeCleanupSteps = steps
            }
            guard activePipeline === pipeline, !Task.isCancelled else { return }
            activeProbe = nil

            switch outcome {
            case let .signalDetected(count):
                if trigger.isAutomatic {
                    await confirmAutomaticSignal(
                        pipeline: pipeline,
                        qualifyingCallbackCount: count,
                        trigger: trigger
                    )
                } else {
                    confirmStaleCaptureIfStillNeeded(
                        pipeline: pipeline,
                        qualifyingCallbackCount: count,
                        trigger: trigger
                    )
                }
            case .noSignal:
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: "livenessProbeNoSignal",
                    reason: "The independent probe also received no useful audio; silence remained ambiguous.",
                    trigger: trigger
                )
            case .malformedInput:
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: "livenessProbeMalformedInput",
                    reason: "The independent probe rejected malformed input metadata.",
                    trigger: trigger
                )
            case .cancelled:
                let mainCaptureResumed = trigger.isAutomatic
                    && latestObservation?.isExactFullFrameZeroDelivery != true
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: mainCaptureResumed
                        ? "livenessSentinelMainCaptureResumed"
                        : "livenessProbeCancelled",
                    reason: mainCaptureResumed
                        ? "The main capture path resumed normally, so the independent watcher was cancelled."
                        : "Audio verification was cancelled.",
                    trigger: trigger
                )
            case let .coreAudioFailure(operation, status):
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: "livenessProbeCoreAudioFailure",
                    reason: "\(operation) failed with Core Audio status \(status).",
                    trigger: trigger
                )
            case let .cleanupFailed(steps):
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: "livenessProbeCleanupFailed",
                    reason: "Probe cleanup retained \(steps.count) unresolved Core Audio step(s); Quit is required.",
                    trigger: trigger
                )
            }
        }
        return true
    }

    @discardableResult
    func beginControlledFailureTest() -> Bool {
        guard verificationTask == nil,
              retainedProbeAfterCleanupFailure == nil,
              let pipeline = activePipeline,
              automaticRecoveryEnabled,
              pipeline.setDiagnosticFaultInjectionEnabled(true)
        else { return false }
        statusAction?(
            "Controlled test: holding the main captured-audio path at exact zero while the independent watcher remains armed…"
        )
        return true
    }

    func cancelControlledFailureTest() {
        _ = activePipeline?.setDiagnosticFaultInjectionEnabled(false)
    }

    private func finishUnconfirmed(
        pipeline: any AudioCapturePipeline,
        kind: String,
        reason: String,
        trigger: VerificationTrigger
    ) {
        if pipeline.isDiagnosticFaultInjectionEnabled {
            _ = pipeline.setDiagnosticFaultInjectionEnabled(false)
        }
        verificationTask = nil
        activeProbe = nil
        activeVerificationTrigger = nil
        diagnostics?.recordRecoveryExperimentEvent(kind: kind, reason: reason)
        statusAction?(trigger.isAutomatic
            ? runningStatus
            : "The independent probe could not confirm stale capture. No automatic restart occurred; use Reconnect Audio if sound should be playing.")
    }

    private func considerAutomaticVerification(
        for observation: AudioLivenessObservation
    ) {
        guard automaticRecoveryEnabled
        else { return }
        guard observation.isExactFullFrameZeroDelivery else {
            exactZeroDeliveryBeganAt = nil
            automaticVerificationAttemptedForZeroRun = false
            if activeVerificationTrigger?.isAutomatic == true {
                activeProbe?.cancel()
            }
            return
        }
        guard !automaticRecoveryBlockedUntilHealthy,
              !automaticVerificationAttemptedForZeroRun
        else { return }
        let now = uptimeNanoseconds()
        guard let beganAt = exactZeroDeliveryBeganAt else {
            exactZeroDeliveryBeganAt = now
            return
        }
        guard now &- beganAt >= automaticVerificationDelayNanoseconds else {
            return
        }
        automaticVerificationAttemptedForZeroRun = true
        _ = requestVerification(trigger: .automaticDuringExactZero)
    }

    private func confirmAutomaticSignal(
        pipeline: any AudioCapturePipeline,
        qualifyingCallbackCount: UInt32,
        trigger: VerificationTrigger
    ) async {
        guard let sequenceAtSignal = latestObservation?.callbackSequence else {
            finishUnconfirmed(
                pipeline: pipeline,
                kind: "livenessSentinelMainProgressUnconfirmed",
                reason: "The main path had no callback sequence available when independent signal was detected.",
                trigger: trigger
            )
            return
        }
        do {
            try await Task.sleep(
                nanoseconds: automaticConfirmationDelayNanoseconds
            )
        } catch {
            finishUnconfirmed(
                pipeline: pipeline,
                kind: "livenessSentinelCancelled",
                reason: "Automatic verification was cancelled before fresh main-path confirmation.",
                trigger: trigger
            )
            return
        }
        guard activePipeline === pipeline, !Task.isCancelled else { return }
        if let freshObservation = pipeline.drainDiagnosticTelemetry() {
            latestObservation = freshObservation
        }
        guard let observation = latestObservation,
              observation.callbackSequence > sequenceAtSignal
        else {
            finishUnconfirmed(
                pipeline: pipeline,
                kind: "livenessSentinelMainProgressUnconfirmed",
                reason: "The main path did not publish a fresh callback observation after independent signal was detected.",
                trigger: trigger
            )
            return
        }
        confirmStaleCaptureIfStillNeeded(
            pipeline: pipeline,
            qualifyingCallbackCount: qualifyingCallbackCount,
            trigger: trigger
        )
    }

    private func confirmStaleCaptureIfStillNeeded(
        pipeline: any AudioCapturePipeline,
        qualifyingCallbackCount: UInt32,
        trigger: VerificationTrigger
    ) {
        guard latestObservation?.isExactFullFrameZeroDelivery == true else {
            finishUnconfirmed(
                pipeline: pipeline,
                kind: trigger.isAutomatic
                    ? "livenessSentinelMainCaptureResumed"
                    : "livenessProbeMainCaptureResumed",
                reason: "The main capture path resumed before recovery was needed.",
                trigger: trigger
            )
            return
        }
        if trigger.isAutomatic {
            automaticRecoveryBlockedUntilHealthy = true
            healthyNonzeroDeliveryBeganAt = nil
        }
        verificationTask = nil
        activeProbe = nil
        activeVerificationTrigger = nil
        diagnostics?.recordRecoveryExperimentEvent(
            kind: "confirmedStaleCapture",
            reason: "The main path remained exact-zero while an independent unmuted probe received \(qualifyingCallbackCount) qualifying callback(s)."
        )
        statusAction?(
            "A stale captured-audio path was confirmed. Reconnecting Leveling once…"
        )
        if pipeline.isDiagnosticFaultInjectionEnabled {
            _ = pipeline.setDiagnosticFaultInjectionEnabled(false)
        }
        confirmedStaleCaptureAction?()
    }

    private func considerAutomaticRecoveryCircuitBreakerReset(
        for observation: AudioLivenessObservation
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
        diagnostics?.recordRecoveryExperimentEvent(
            kind: "automaticRecoveryCircuitBreakerReset",
            reason: "The rebuilt main capture path delivered five continuous seconds of healthy nonzero audio."
        )
    }
}
