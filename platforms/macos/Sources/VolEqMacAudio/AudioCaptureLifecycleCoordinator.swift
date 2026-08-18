// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation
import VolEqCore

@MainActor
protocol AudioCaptureLifecycleObserving: AnyObject {
    func lifecycleDidPublish(_ snapshot: AudioCaptureLifecycleSnapshot)
    func lifecycleDidCompleteTeardown(_ report: AudioCaptureTeardownReport)
    func lifecycleDidRefreshProcesses(
        _ processes: [AudioProcess],
        selectedProcessID: AudioObjectID?
    )
    func lifecycleDidRestoreIntent(_ intent: CaptureIntent)
}

extension AudioCaptureLifecycleObserving {
    func lifecycleDidCompleteTeardown(_ report: AudioCaptureTeardownReport) {}
}

@MainActor
final class AudioCaptureLifecycleCoordinator {
    weak var observer: (any AudioCaptureLifecycleObserving)?

    private let dependencies: AudioCaptureDependencies
    private let processSession: AudioCaptureProcessSession
    private let processRefreshCoordinator: AudioProcessRefreshCoordinator
    private let captureRuntime: AudioCaptureRuntime
    private let preflightExecutor = AudioCapturePreflightExecutor()
    private var stateMachine = CaptureLifecycleStateMachine()
    private var generation: UInt64 = 0
    private var transitionTask: Task<Void, Never>?
    private let routeChangeCoordinator = AudioRouteChangeCoordinator()
    private let routeMonitorBootstrap = AudioRouteMonitorBootstrapCoordinator()
    private var wakePendingAfterCleanup = false
    private var activeRouteObservation: AudioOutputRouteObservation?

    private var phase: CaptureLifecyclePhase { stateMachine.phase }
    private var snapshot: AudioCaptureLifecycleSnapshot { stateMachine.snapshot }

    init(dependencies: AudioCaptureDependencies) {
        self.dependencies = dependencies
        processSession = AudioCaptureProcessSession(
            catalog: dependencies.processCatalog
        )
        processRefreshCoordinator = AudioProcessRefreshCoordinator(
            processSession: processSession
        )
        captureRuntime = AudioCaptureRuntime(
            pipelineBuilder: dependencies.pipelineBuilder,
            healthMonitorBuilder: dependencies.callbackHealthMonitorBuilder,
            verificationProbeBuilder:
                dependencies.livenessVerificationProbeBuilder,
            diagnostics: dependencies.livenessDiagnostics
        )
        routeMonitorBootstrap.start { [weak self] in
            guard let self else { throw CancellationError() }
            try await installRouteMonitoring()
        } onSuccess: { [weak self] in
            self?.refreshProcesses(currentSelection: nil, mode: .application)
        } onFailure: { [weak self] error in
            guard let self else { return }
                _ = apply(
                    event: .routeMonitoringFailed(nil),
                    status: error.localizedDescription
                )
        }
    }

    func publishCurrentState() {
        observer?.lifecycleDidPublish(snapshot)
        publishProcessSelection()
    }

    private func publishProcessSelection() {
        observer?.lifecycleDidRefreshProcesses(
            processSession.processes,
            selectedProcessID: processSession.selectedProcessID
        )
    }

    func refreshProcesses(
        currentSelection: AudioObjectID?,
        mode: CaptureMode
    ) {
        let preservesRecoveryFailure: Bool
        if case .recoveryFailed = phase {
            preservesRecoveryFailure = true
        } else {
            preservesRecoveryFailure = false
        }
        let refreshOwnsLifecyclePhase: Bool
        switch phase {
        case .stopped, .ready, .processDiscoveryFailed:
            refreshOwnsLifecyclePhase = true
        case .explanationDeclined, .installingRouteMonitor, .explaining,
             .preparing, .active, .stopping,
             .suspending, .suspended,
             .recovering, .recoveryFailed, .failed,
             .verifiedFailure, .cleanupFailed, .routeMonitoringFailed:
            refreshOwnsLifecyclePhase = false
        }

        let context = AudioProcessRefreshCoordinator.Context(
            lifecycleGeneration: generation,
            currentSelection: currentSelection,
            mode: mode,
            preservesRecoveryFailure: preservesRecoveryFailure,
            ownsLifecyclePhase: refreshOwnsLifecyclePhase
        )
        processRefreshCoordinator.schedule(
            context: context,
            isLifecycleCurrent: { [weak self] in
                self?.generation == context.lifecycleGeneration
            },
            onSelectionChanged: { [weak self] in
                self?.publishProcessSelection()
            },
            onSucceeded: { [weak self] ownsLifecyclePhase in
                guard let self,
                      generation == context.lifecycleGeneration,
                      !context.preservesRecoveryFailure,
                      ownsLifecyclePhase
                else { return }
                _ = apply(
                    event: .processRefreshSucceeded,
                    status: processSession.processes.isEmpty
                        ? "No app is producing audio yet. Start meeting audio, then refresh."
                        : "Ready. Audio will stay on your current default output device."
                )
            },
            onFailed: { [weak self] error, ownsLifecyclePhase in
                guard let self,
                      generation == context.lifecycleGeneration,
                      !context.preservesRecoveryFailure,
                      ownsLifecyclePhase
                else { return }
                _ = apply(
                    event: .processRefreshFailed(resumableIntent),
                    status: error.localizedDescription
                )
            }
        )
    }

    func start(intent: CaptureIntent) {
        routeMonitorBootstrap.cancel()
        guard canBeginOperation,
              case let .beginStart(reducedIntent) = CaptureLifecycleReducer.reduce(
                  phase: phase,
                  event: .start(intent)
              )
        else { return }
        guard reducedIntent.mode == .system || reducedIntent.application != nil else {
            processSession.requireExplicitApplicationSelection()
            publishProcessSelection()
            publishStatus(
                "Select the application you want VolEq to level, then choose Start."
            )
            return
        }
        processSession.clearExplicitSelectionRequirement()
        beginRouteMonitoringAndStart(reducedIntent)
    }

    func retry(intent: CaptureIntent) {
        guard canBeginOperation,
              case let .beginRetry(reducedIntent) = CaptureLifecycleReducer.reduce(
                  phase: phase,
                  event: .retry(intent)
              )
        else { return }
        guard reducedIntent.mode == .system || reducedIntent.application != nil else {
            publishStatus(
                "Select the application you want VolEq to level, then choose Try Again."
            )
            return
        }
        processSession.clearExplicitSelectionRequirement()
        _ = apply(
            event: .retry(reducedIntent),
            status: "Restoring Leveling — original audio is restored while VolEq reconnects."
        )
        scheduleRecovery(intent: reducedIntent, reason: .userRetry)
    }

    func requestLivenessVerification() -> Bool {
        guard case .active = phase else { return false }
        return captureRuntime.requestLivenessVerification(reason: "userRequested")
    }

    func beginControlledLivenessFailureTest() -> Bool {
        guard case .active = phase else { return false }
        return captureRuntime.beginControlledLivenessFailureTest()
    }

    func reconnect() -> Bool {
        guard case let .recover(intent, reason) = CaptureLifecycleReducer.reduce(
            phase: phase,
            event: .userReconnectRequested
        ) else { return false }
        _ = apply(
            event: .userReconnectRequested,
            status: "Reconnecting Leveling — original audio is restored while VolEq rebuilds the captured-audio path."
        )
        beginAutomaticRecovery(intent: intent, reason: reason)
        return true
    }

    func stop() {
        requestStop(event: .stop)
    }

    private func requestStop(event: CaptureLifecycleEvent) {
        routeMonitorBootstrap.cancel()
        guard case .stop = CaptureLifecycleReducer.reduce(
            phase: phase,
            event: event
        ) else { return }
        invalidateTransition()
        processSession.clearExplicitSelectionRequirement()
        wakePendingAfterCleanup = false
        _ = apply(
            event: event,
            status: "Stopping Leveling — original audio is being restored."
        )
        beginTeardown(
            completion: .stopped,
            completionStatus: "Stopped. Original application audio is restored."
        )
    }

    func stopAndWait() async {
        stop()
        let task = transitionTask
        await task?.value
    }

    func prepareForApplicationTermination() async {
        requestStop(event: .terminationRequested)
        let task = transitionTask
        await task?.value
        let firstReport = await dependencies.routeMonitor.stop()
        if !firstReport.isComplete {
            await Task.yield()
            _ = await dependencies.routeMonitor.stop()
        }
    }

    func prepareForSystemSleep(fallbackIntent: CaptureIntent?) {
        let directive = CaptureLifecycleReducer.reduce(
            phase: phase,
            event: .sleep(fallbackIntent)
        )
        if case .cancelQueuedWake = directive {
            wakePendingAfterCleanup = false
            return
        }
        guard case let .sleep(intent) = directive else { return }

        _ = apply(
            event: .sleep(fallbackIntent),
            status: "Paused for System Sleep — restoring the original audio path."
        )
        invalidateTransition()
        beginTeardown(
            completion: .suspended(intent),
            completionStatus: "Paused for System Sleep — original audio has been restored."
        )
    }

    func resumeAfterSystemWake() {
        let directive = CaptureLifecycleReducer.reduce(
            phase: phase,
            event: .wake
        )
        if case .queueWake = directive {
            wakePendingAfterCleanup = true
            return
        }
        guard case let .recover(intent, .systemWake) = directive,
              transitionTask == nil,
              resourcesAllowReplacement
        else { return }
        _ = apply(
            event: .wake,
            status: "Restoring Leveling — original audio is restored while VolEq reconnects."
        )
        scheduleRecovery(intent: intent, reason: .systemWake)
    }

    func updateSettings(_ settings: LevelingSettings) {
        captureRuntime.updateSettings(settings)
        _ = apply(
            event: .settingsChanged(settings),
            status: snapshot.status
        )
    }

    private var canBeginOperation: Bool {
        transitionTask == nil && resourcesAllowReplacement
    }

    private var resourcesAllowReplacement: Bool {
        captureRuntime.isIdle
    }

    private var resumableIntent: CaptureIntent? {
        phase.resumableIntent
    }

    private func applyingLatestSettings(
        to intent: CaptureIntent
    ) -> CaptureIntent {
        guard let settings = resumableIntent?.levelingSettings else {
            return intent
        }
        return intent.replacingLevelingSettings(settings)
    }

    private func beginSafeStart(
        intent: CaptureIntent,
        isRecovery: Bool,
        recoverySourceIntent: CaptureIntent?,
        recoveryReason: AudioRecoveryReason?
    ) {
        guard canBeginOperation else { return }
        cancelProcessRefreshWork()
        generation &+= 1
        let operationGeneration = generation
        let startEvent: CaptureLifecycleEvent = recoverySourceIntent.map {
            .recoveryStartFlowBegan(previous: $0, restored: intent)
        } ?? .startFlowBegan(intent)
        guard case .transition = apply(
            event: startEvent,
            status: isRecovery
                ? "Restoring Leveling — preparing the audio path."
                : "Review how VolEq uses System Audio Recording before continuing."
        ) else { return }
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let accepted = await dependencies.permissionExplanationRequest()
            guard isCurrent(operationGeneration) else { return }
            guard accepted else {
                transitionTask = nil
                _ = apply(
                    event: .explanationDeclined(intent),
                    status: "Processing did not start. Choose Start when you are ready to review System Audio Recording access."
                )
                return
            }
            guard case .transition = apply(
                event: .explanationAccepted(intent),
                status: isRecovery
                    ? "Restoring Leveling — preparing the audio path."
                    : "Starting Leveling…"
            ) else {
                transitionTask = nil
                return
            }

            let resolved: ResolvedCaptureIntent
            do {
                resolved = try await resolveFreshIntent(
                    intent,
                    generation: operationGeneration
                )
                guard isCurrent(operationGeneration) else { return }
                observer?.lifecycleDidRestoreIntent(
                    applyingLatestSettings(to: resolved.intent)
                )
            } catch {
                guard isCurrent(operationGeneration) else { return }
                transitionTask = nil
                applyStartFailure(AudioCaptureFailurePresentation.startFailure(
                    error,
                    intent: intent,
                    isRecovery: isRecovery
                ))
                return
            }

            let prepared: PreparedCaptureRequest
            do {
                prepared = try await preflightExecutor.prepare(
                    using: dependencies.preflight,
                    resolvedIntent: resolved
                )
            } catch {
                guard isCurrent(operationGeneration) else { return }
                transitionTask = nil
                applyStartFailure(AudioCaptureFailurePresentation.startFailure(
                    error,
                    intent: intent,
                    isRecovery: isRecovery
                ))
                return
            }
            guard isCurrent(operationGeneration) else { return }
            activeRouteObservation = routeObservation(for: prepared)
            await startPipeline(
                prepared,
                generation: operationGeneration,
                isRecovery: isRecovery,
                recoveryReason: recoveryReason
            )
            if isCurrent(operationGeneration) { transitionTask = nil }
        }
    }

    private func startPipeline(
        _ preparedRequest: PreparedCaptureRequest,
        generation operationGeneration: UInt64,
        isRecovery: Bool,
        recoveryReason: AudioRecoveryReason?
    ) async {
        let request = resumableIntent.map {
            preparedRequest.replacingIntent($0)
        } ?? preparedRequest
        let status: String
        switch request.intent.mode {
        case .application:
            let name = request.intent.application?.displayName
                ?? "the selected application"
            status = "Leveling \(name) on the current output device."
        case .system:
            status = "Leveling the device-wide mix. VolEq excludes itself to avoid feedback."
        }

        let result = await captureRuntime.start(
            request: request,
            currentSettings: { [weak self] in
                self?.resumableIntent?.levelingSettings
                    ?? request.intent.levelingSettings
            },
            isCurrent: { [weak self] in
                self?.isCurrent(operationGeneration) == true
            },
            onRouteChange: { [weak self] in
                self?.handleOutputRouteChange(
                    expectedGeneration: operationGeneration
                )
            },
            onStall: { [weak self] in
                self?.handleCallbackStall()
            },
            onStatus: { [weak self] status in
                self?.publishStatus(status)
            },
            onProcessingFailure: { [weak self] statusCode in
                self?.handleProcessingFailure(statusCode)
            },
            onConfirmedStaleCapture: { [weak self] in
                self?.handleConfirmedStaleCapture()
            },
            automaticLivenessVerificationAfterRouteRecovery:
                recoveryReason == .outputRouteChanged,
            runningStatus: status
        )
        guard isCurrent(operationGeneration) else { return }

        switch result {
        case let .active(runningStatusSuffix):
            activeRouteObservation = routeObservation(for: request)
            _ = apply(
                event: .pipelineStarted(request.intent),
                status: status + runningStatusSuffix
            )
            processSession.clearExplicitSelectionRequirement()
        case .callbacksDidNotStart:
            await handleCallbackStartupFailure(
                intent: request.intent,
                isRecovery: isRecovery
            )
        case let .failed(error):
            _ = apply(
                event: .pipelineStartFailed(request.intent),
                status: "Stopping Leveling — original audio is being restored."
            )
            let report = await teardownOwnedResources()
            if report.isComplete {
                let failure = AudioCaptureFailurePresentation.startFailure(
                    error,
                    intent: request.intent,
                    isRecovery: isRecovery
                )
                applyTeardownCompletion(
                    .failed(failure.phase),
                    status: failure.status
                )
            } else {
                applyTeardownFailure()
            }
        case .cancelled:
            return
        }
    }

    private func handleCallbackStartupFailure(
        intent: CaptureIntent,
        isRecovery: Bool
    ) async {
        _ = apply(
            event: .pipelineStartFailed(intent),
            status: "Stopping Leveling — original audio is being restored."
        )
        let report = await teardownOwnedResources()
        guard report.isComplete else {
            applyTeardownFailure()
            return
        }
        let failure = AudioCaptureFailurePresentation.callbackStartupFailure(
            intent: intent,
            isRecovery: isRecovery
        )
        applyTeardownCompletion(.failed(failure.phase), status: failure.status)
    }

    private func beginAutomaticRecovery(
        intent: CaptureIntent,
        reason: AudioRecoveryReason
    ) {
        invalidateTransition()
        beginTeardown(
            completion: .recoveryReady(intent, reason),
            completionStatus: "Restoring Leveling — original audio is restored while VolEq reconnects."
        )
    }

    private func scheduleRecovery(
        intent: CaptureIntent,
        reason: AudioRecoveryReason
    ) {
        guard transitionTask == nil, resourcesAllowReplacement else { return }
        cancelProcessRefreshWork()
        generation &+= 1
        let operationGeneration = generation
        publishStatus(
            "Restoring Leveling — original audio is restored while VolEq reconnects."
        )
        let delay = reason == .systemWake
            ? dependencies.wakeRecoveryDelayNanoseconds
            : dependencies.routeRecoveryDelayNanoseconds

        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await dependencies.routeStabilityGate.waitUntilStable(
                    initialDelayNanoseconds: delay,
                    isCurrent: { [weak self] in
                        self?.isCurrent(operationGeneration) == true
                    }
                )
                guard isCurrent(operationGeneration) else { return }
                guard case let .recovering(currentIntent, currentReason) = phase,
                      currentReason == reason,
                      currentIntent.matchesOperationIdentity(of: intent)
                else { return }
                let restoredIntent = try await restoreApplicationTarget(
                    currentIntent,
                    generation: operationGeneration
                )
                guard isCurrent(operationGeneration) else { return }
                transitionTask = nil
                beginSafeStart(
                    intent: restoredIntent,
                    isRecovery: true,
                    recoverySourceIntent: currentIntent,
                    recoveryReason: currentReason
                )
            } catch is CancellationError {
                return
            } catch let failure as RecoveryFailure {
                guard isCurrent(operationGeneration) else { return }
                transitionTask = nil
                let presentation = AudioCaptureFailurePresentation.recoveryFailure(
                    failure,
                    intent: intent
                )
                _ = apply(
                    event: .recoveryFailed(intent, failure),
                    status: presentation.status
                )
            } catch {
                guard isCurrent(operationGeneration) else { return }
                transitionTask = nil
                let failure = RecoveryFailure.pipeline(error.localizedDescription)
                let presentation = AudioCaptureFailurePresentation.recoveryFailure(
                    failure,
                    intent: intent
                )
                _ = apply(
                    event: .recoveryFailed(intent, failure),
                    status: presentation.status
                )
            }
        }
    }

    private func restoreApplicationTarget(
        _ intent: CaptureIntent,
        generation operationGeneration: UInt64
    ) async throws -> CaptureIntent {
        guard intent.mode == .application else {
            observer?.lifecycleDidRestoreIntent(intent)
            return intent
        }
        guard intent.application != nil else {
            processSession.requireExplicitApplicationSelection()
            publishProcessSelection()
            throw RecoveryFailure.applicationMissing("The selected application")
        }
        let restored = try await resolveFreshIntent(
            intent,
            generation: operationGeneration
        ).intent
        observer?.lifecycleDidRestoreIntent(restored)
        return restored
    }

    private func beginRouteMonitoringAndStart(_ intent: CaptureIntent) {
        guard canBeginOperation,
              case .transition = apply(
                event: .routeMonitoringStarted(intent),
                status: "Preparing output-route safety monitoring before Leveling starts."
              )
        else { return }
        cancelProcessRefreshWork()
        generation &+= 1
        let operationGeneration = generation
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await installRouteMonitoring()
                guard isCurrent(operationGeneration) else { return }
                transitionTask = nil
                beginSafeStart(
                    intent: intent,
                    isRecovery: false,
                    recoverySourceIntent: nil,
                    recoveryReason: nil
                )
            } catch {
                guard isCurrent(operationGeneration) else { return }
                transitionTask = nil
                _ = apply(
                    event: .routeMonitoringFailed(intent),
                    status: error.localizedDescription
                )
            }
        }
    }

    private func installRouteMonitoring() async throws {
        guard !dependencies.routeMonitor.isMonitoring else { return }
        try await dependencies.routeMonitor.start { [weak self] in
            self?.handleOutputRouteChange()
        }
        guard dependencies.routeMonitor.isMonitoring else {
            throw VolEqError.missingValue(
                "VolEq could not confirm output-route monitoring. Processing did not start."
            )
        }
    }

    private func resolveFreshIntent(
        _ intent: CaptureIntent,
        generation operationGeneration: UInt64
    ) async throws -> ResolvedCaptureIntent {
        guard intent.mode == .application else {
            return try await processSession.resolveFresh(
                intent,
                isCurrent: { [weak self] in
                    self?.isCurrent(operationGeneration) == true
                }
            )
        }
        defer { publishProcessSelection() }
        return try await processSession.resolveFresh(
            intent,
            isCurrent: { [weak self] in
                self?.isCurrent(operationGeneration) == true
            }
        )
    }

    private func handleOutputRouteChange(expectedGeneration: UInt64? = nil) {
        if let expectedGeneration, expectedGeneration != generation { return }
        let notificationGeneration = generation
        switch CaptureLifecycleReducer.reduce(
            phase: phase,
            event: .routeChanged
        ) {
        case .recover:
            routeChangeCoordinator.signal { [weak self] in
                guard let self,
                      generation == notificationGeneration
                else { return false }
                return await routeChangeRequiresRecovery()
            } onRecoveryRequired: { [weak self] in
                self?.beginRouteRecoveryIfStillCurrent(notificationGeneration)
            }
        case .refreshReadyStatus:
            _ = apply(
                event: .routeChanged,
                status: processSession.processes.isEmpty
                    ? "No app is producing audio yet. Start meeting audio, then refresh."
                    : "Ready. Audio will use the current default output device."
            )
        default:
            break
        }
    }

    private func beginRouteRecoveryIfStillCurrent(
        _ notificationGeneration: UInt64
    ) {
        guard generation == notificationGeneration,
              case let .recover(intent, reason) = CaptureLifecycleReducer.reduce(
                phase: phase,
                event: .routeChanged
              )
        else { return }
        _ = apply(
            event: .routeChanged,
            status: "Restoring Leveling — VolEq is restoring the original audio path before reconnecting."
        )
        beginAutomaticRecovery(intent: intent, reason: reason)
    }

    private func handleCallbackStall() {
        guard case let .recover(intent, reason) = CaptureLifecycleReducer.reduce(
            phase: phase,
            event: .callbacksStalled
        ) else { return }
        _ = apply(
            event: .callbacksStalled,
            status: "Restoring Leveling — VolEq is restoring the original audio path before reconnecting."
        )
        beginAutomaticRecovery(intent: intent, reason: reason)
    }

    private func handleConfirmedStaleCapture() {
        guard case let .recover(intent, reason) = CaptureLifecycleReducer.reduce(
            phase: phase,
            event: .staleCaptureConfirmed
        ) else { return }
        _ = apply(
            event: .staleCaptureConfirmed,
            status: "A stale captured-audio path was confirmed. Restoring original audio before reconnecting once."
        )
        beginAutomaticRecovery(intent: intent, reason: reason)
    }

    private func routeChangeRequiresRecovery() async -> Bool {
        guard let activeRouteObservation else { return true }
        do {
            return try await dependencies.routeStabilityGate.hasRouteChanged(
                since: activeRouteObservation
            )
        } catch {
            return true
        }
    }

    private func routeObservation(
        for request: PreparedCaptureRequest
    ) -> AudioOutputRouteObservation {
        AudioOutputRouteObservation(
            deviceID: request.outputDeviceID,
            uid: request.outputDeviceUID,
            sampleRate: request.outputFormat.mSampleRate,
            channelCount: request.outputFormat.mChannelsPerFrame
        )
    }

    private func handleProcessingFailure(_ statusCode: OSStatus) {
        let intent = resumableIntent
        let failure = AudioCaptureFailurePresentation.processingFailure(
            statusCode,
            intent: intent
        )
        guard case .stop = CaptureLifecycleReducer.reduce(
            phase: phase,
            event: .processingFailed(intent)
        ) else { return }
        _ = apply(
            event: .processingFailed(intent),
            status: "Audio processing stopped after an internal conversion failure. Restoring original audio."
        )
        invalidateTransition()
        beginTeardown(
            completion: .failed(failure.phase),
            completionStatus: failure.status
        )
    }

    private func beginTeardown(
        completion: CaptureTeardownCompletion,
        completionStatus: String
    ) {
        captureRuntime.cancelStartup()
        let operationGeneration = generation
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await teardownOwnedResources()
            guard operationGeneration == generation else { return }
            observer?.lifecycleDidCompleteTeardown(report)
            transitionTask = nil
            guard report.permitsReplacementPipeline else {
                applyTeardownFailure()
                return
            }
            applyTeardownCompletion(completion, status: completionStatus)
        }
    }

    private func teardownOwnedResources() async -> AudioCaptureTeardownReport {
        await captureRuntime.teardown()
    }

    private func invalidateTransition() {
        generation &+= 1
        transitionTask?.cancel()
        transitionTask = nil
        routeChangeCoordinator.cancel()
        cancelProcessRefreshWork()
    }

    private func cancelProcessRefreshWork() {
        processRefreshCoordinator.cancel()
    }

    private func isCurrent(_ operationGeneration: UInt64) -> Bool {
        operationGeneration == generation && !Task.isCancelled
    }

    @discardableResult
    private func apply(
        event: CaptureLifecycleEvent,
        status: String
    ) -> CaptureLifecycleDirective {
        let result = stateMachine.apply(event: event, status: status)
        if let published = result.published {
            observer?.lifecycleDidPublish(published)
        }
        return result.directive
    }

    private func applyStartFailure(
        _ failure: AudioCaptureLifecycleSnapshot
    ) {
        _ = apply(
            event: .startupFailed(failure.phase),
            status: failure.status
        )
    }

    private func applyTeardownCompletion(
        _ completion: CaptureTeardownCompletion,
        status: String
    ) {
        let directive = apply(
            event: .teardownCompleted(completion),
            status: status
        )
        switch directive {
        case let .recover(intent, reason):
            scheduleRecovery(intent: intent, reason: reason)
        case let .transition(.suspended(intent)):
            if wakePendingAfterCleanup {
                wakePendingAfterCleanup = false
                _ = apply(
                    event: .wake,
                    status: "Restoring Leveling — original audio is restored while VolEq reconnects."
                )
                scheduleRecovery(intent: intent, reason: .systemWake)
            }
        default:
            break
        }
    }

    private func applyTeardownFailure() {
        _ = apply(
            event: .teardownFailed,
            status: AudioCaptureFailurePresentation.cleanupFailure.status
        )
    }

    private func publishStatus(_ status: String) {
        let published = stateMachine.updateStatus(status)
        observer?.lifecycleDidPublish(published)
    }

}
