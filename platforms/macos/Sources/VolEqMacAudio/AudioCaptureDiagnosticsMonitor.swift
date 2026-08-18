// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation

@MainActor
final class AudioCaptureDiagnosticsMonitor {
    private enum VerificationTrigger {
        case userRequested(String)
        case controlledFaultInjection
        case automaticAfterOutputRouteRecovery

        var diagnosticReason: String {
            switch self {
            case let .userRequested(reason): reason
            case .controlledFaultInjection: "controlledFaultInjection"
            case .automaticAfterOutputRouteRecovery:
                "automaticAfterOutputRouteRecovery"
            }
        }

        var restoresRunningStatusWhenUnconfirmed: Bool {
            if case .automaticAfterOutputRouteRecovery = self { return true }
            return false
        }
    }

    private var task: Task<Void, Never>?
    private var verificationTask: Task<Void, Never>?
    private var activePipeline: (any AudioCapturePipeline)?
    private var activeProbe: (any AudioLivenessVerificationProbing)?
    private var retainedProbeAfterCleanupFailure:
        (any AudioLivenessVerificationProbing)?
    private var latestObservation: AudioLivenessObservation?
    private let verificationProbeBuilder:
        (any AudioLivenessVerificationProbeBuilding)?
    private let diagnostics: (any AudioLivenessDiagnosticsRecording)?
    private let pollIntervalNanoseconds: UInt64
    private let automaticVerificationDelayNanoseconds: UInt64
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private var runningStatus = ""
    private var automaticVerificationArmed = false
    private var automaticVerificationAttempted = false
    private var exactZeroDeliveryBeganAt: UInt64?

    init(
        verificationProbeBuilder:
            (any AudioLivenessVerificationProbeBuilding)? = nil,
        diagnostics: (any AudioLivenessDiagnosticsRecording)? = nil,
        pollIntervalNanoseconds: UInt64 = 100_000_000,
        automaticVerificationDelayNanoseconds: UInt64 = 2_000_000_000,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.verificationProbeBuilder = verificationProbeBuilder
        self.diagnostics = diagnostics
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.automaticVerificationDelayNanoseconds =
            automaticVerificationDelayNanoseconds
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    func start(
        pipeline: any AudioCapturePipeline,
        runningStatus: String,
        automaticVerificationAfterRouteRecovery: Bool = false,
        isCurrent: @escaping @MainActor (any AudioCapturePipeline) -> Bool,
        onStatus: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (OSStatus) -> Void,
        onConfirmedStaleCapture: @escaping @MainActor () -> Void
    ) {
        stop()
        let processor = pipeline.processor
        activePipeline = pipeline
        self.runningStatus = runningStatus
        automaticVerificationArmed =
            automaticVerificationAfterRouteRecovery
        automaticVerificationAttempted = false
        exactZeroDeliveryBeganAt = nil
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

    func stop() {
        task?.cancel()
        task = nil
        verificationTask?.cancel()
        verificationTask = nil
        activeProbe?.cancel()
        activeProbe = nil
        _ = activePipeline?.setDiagnosticFaultInjectionEnabled(false)
        activePipeline = nil
        latestObservation = nil
        runningStatus = ""
        automaticVerificationArmed = false
        automaticVerificationAttempted = false
        exactZeroDeliveryBeganAt = nil
        confirmedStaleCaptureAction = nil
        statusAction = nil
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
        statusAction?(
            "Verifying the captured-audio path without recording audio…"
        )
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
                kind: "livenessProbeStarted",
                reason: trigger.diagnosticReason
            )
            let outcome = await probe.verify()
            if case .cleanupFailed = outcome {
                retainedProbeAfterCleanupFailure = probe
            }
            guard activePipeline === pipeline, !Task.isCancelled else { return }
            activeProbe = nil
            verificationTask = nil

            switch outcome {
            case let .signalDetected(count):
                guard latestObservation?.isExactFullFrameZeroDelivery == true else {
                    finishUnconfirmed(
                        pipeline: pipeline,
                        kind: "livenessProbeMainCaptureResumed",
                        reason: "The main capture path resumed before recovery was needed.",
                        trigger: trigger
                    )
                    return
                }
                diagnostics?.recordRecoveryExperimentEvent(
                    kind: "confirmedStaleCapture",
                    reason: "The main path remained exact-zero while an independent unmuted probe received \(count) qualifying callback(s)."
                )
                statusAction?(
                    "A stale captured-audio path was confirmed. Reconnecting Leveling once…"
                )
                if pipeline.isDiagnosticFaultInjectionEnabled {
                    _ = pipeline.setDiagnosticFaultInjectionEnabled(false)
                }
                confirmedStaleCaptureAction?()
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
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: "livenessProbeCancelled",
                    reason: "Audio verification was cancelled.",
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
              pipeline.setDiagnosticFaultInjectionEnabled(true)
        else { return false }
        statusAction?(
            "Controlled test: simulating a live callback path with unusable captured input…"
        )
        verificationTask = Task { @MainActor [weak self, weak pipeline] in
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
            } catch { return }
            guard let self, let pipeline,
                  activePipeline === pipeline,
                  !Task.isCancelled
            else { return }
            verificationTask = nil
            if !requestVerification(trigger: .controlledFaultInjection) {
                _ = pipeline.setDiagnosticFaultInjectionEnabled(false)
            }
        }
        return true
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
        diagnostics?.recordRecoveryExperimentEvent(kind: kind, reason: reason)
        statusAction?(trigger.restoresRunningStatusWhenUnconfirmed
            ? runningStatus
            : "The independent probe could not confirm stale capture. No automatic restart occurred; use Reconnect Audio if sound should be playing.")
    }

    private func considerAutomaticVerification(
        for observation: AudioLivenessObservation
    ) {
        guard automaticVerificationArmed,
              !automaticVerificationAttempted
        else { return }
        guard observation.isExactFullFrameZeroDelivery else {
            exactZeroDeliveryBeganAt = nil
            return
        }
        let now = uptimeNanoseconds()
        guard let beganAt = exactZeroDeliveryBeganAt else {
            exactZeroDeliveryBeganAt = now
            return
        }
        guard now &- beganAt >= automaticVerificationDelayNanoseconds else {
            return
        }
        automaticVerificationAttempted = true
        _ = requestVerification(trigger: .automaticAfterOutputRouteRecovery)
    }
}
