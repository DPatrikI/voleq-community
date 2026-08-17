// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation

@MainActor
final class AudioCaptureDiagnosticsMonitor {
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

    init(
        verificationProbeBuilder:
            (any AudioLivenessVerificationProbeBuilding)? = nil,
        diagnostics: (any AudioLivenessDiagnosticsRecording)? = nil
    ) {
        self.verificationProbeBuilder = verificationProbeBuilder
        self.diagnostics = diagnostics
    }

    func start(
        pipeline: any AudioCapturePipeline,
        runningStatus: String,
        isCurrent: @escaping @MainActor (any AudioCapturePipeline) -> Bool,
        onStatus: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (OSStatus) -> Void,
        onConfirmedStaleCapture: @escaping @MainActor () -> Void
    ) {
        stop()
        let processor = pipeline.processor
        activePipeline = pipeline
        task = Task { @MainActor [weak pipeline] in
            var diagnosticsRecorded = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let pipeline,
                      isCurrent(pipeline),
                      !Task.isCancelled
                else { return }
                if let observation = pipeline.drainDiagnosticTelemetry() {
                    latestObservation = observation
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
        confirmedStaleCaptureAction = nil
        statusAction = nil
    }

    private var confirmedStaleCaptureAction: (@MainActor () -> Void)?
    private var statusAction: (@MainActor (String) -> Void)?

    @discardableResult
    func requestVerification(reason: String) -> Bool {
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
            reason: reason
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
                    reason: error.localizedDescription
                )
                return
            }
            activeProbe = probe
            diagnostics?.recordRecoveryExperimentEvent(
                kind: "livenessProbeStarted",
                reason: reason
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
                        reason: "The main capture path resumed before recovery was needed."
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
                    reason: "The independent probe also received no useful audio; silence remained ambiguous."
                )
            case .malformedInput:
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: "livenessProbeMalformedInput",
                    reason: "The independent probe rejected malformed input metadata."
                )
            case .cancelled:
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: "livenessProbeCancelled",
                    reason: "Audio verification was cancelled."
                )
            case let .coreAudioFailure(operation, status):
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: "livenessProbeCoreAudioFailure",
                    reason: "\(operation) failed with Core Audio status \(status)."
                )
            case let .cleanupFailed(steps):
                finishUnconfirmed(
                    pipeline: pipeline,
                    kind: "livenessProbeCleanupFailed",
                    reason: "Probe cleanup retained \(steps.count) unresolved Core Audio step(s); Quit is required."
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
            if !requestVerification(reason: "controlledFaultInjection") {
                _ = pipeline.setDiagnosticFaultInjectionEnabled(false)
            }
        }
        return true
    }

    private func finishUnconfirmed(
        pipeline: any AudioCapturePipeline,
        kind: String,
        reason: String
    ) {
        if pipeline.isDiagnosticFaultInjectionEnabled {
            _ = pipeline.setDiagnosticFaultInjectionEnabled(false)
        }
        verificationTask = nil
        activeProbe = nil
        diagnostics?.recordRecoveryExperimentEvent(kind: kind, reason: reason)
        statusAction?(
            "The independent probe could not confirm stale capture. No automatic restart occurred; use Reconnect Audio if sound should be playing."
        )
    }
}
