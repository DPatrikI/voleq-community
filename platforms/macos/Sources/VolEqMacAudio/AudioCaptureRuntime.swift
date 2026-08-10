// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation
import VolEqCore

enum AudioCaptureRuntimeStartResult {
    case active(runningStatusSuffix: String)
    case callbacksDidNotStart
    case failed(Error)
    case cancelled
}

private enum AudioCapturePipelineBuildResult: @unchecked Sendable {
    case built(any AudioCapturePipeline)
    case failed(Error, retainedPipeline: (any AudioCapturePipeline)?)
}

private enum AudioCapturePipelineStartResult: Sendable {
    case started(initialHeartbeatCount: UInt64, runningStatusSuffix: String)
    case failed(Error)
    case cancelled
}

private final class AudioCaptureStartupLease: @unchecked Sendable {
    private enum State {
        case available
        case scheduled
        case executing
        case cancelled
    }

    private let lock = NSLock()
    private var state = State.available

    func scheduleStart() -> Bool {
        lock.withLock {
            guard case .available = state else { return false }
            state = .scheduled
            return true
        }
    }

    func beginStartExecution() -> Bool {
        lock.withLock {
            guard case .scheduled = state else { return false }
            state = .executing
            return true
        }
    }

    func cancel() {
        lock.withLock {
            switch state {
            case .available, .scheduled:
                state = .cancelled
            case .executing, .cancelled:
                break
            }
        }
    }
}

final class AudioCapturePipelineExecutor: @unchecked Sendable {
    private let lifecycleQueue: DispatchQueue
    private let startQueue: DispatchQueue

    init(
        lifecycleQueue: DispatchQueue = DispatchQueue(
            label: "com.patrikistvandoczy.voleq.community.pipeline-lifecycle",
            qos: .userInitiated
        ),
        startQueue: DispatchQueue = DispatchQueue(
            label: "com.patrikistvandoczy.voleq.community.pipeline-start",
            qos: .userInitiated
        )
    ) {
        self.lifecycleQueue = lifecycleQueue
        self.startQueue = startQueue
    }

    fileprivate func build(
        builder: any AudioCapturePipelineBuilding,
        request: PreparedCaptureRequest,
        onRouteChange: @escaping @MainActor @Sendable () -> Void
    ) async -> AudioCapturePipelineBuildResult {
        await withCheckedContinuation { continuation in
            lifecycleQueue.async {
                do {
                    continuation.resume(returning: .built(try builder.build(
                        request: request,
                        onRouteChange: onRouteChange
                    )))
                } catch let failure as AudioCapturePipelineConstructionFailure {
                    continuation.resume(returning: .failed(
                        failure.underlyingError,
                        retainedPipeline: failure.retainedPipeline
                    ))
                } catch {
                    continuation.resume(returning: .failed(
                        error,
                        retainedPipeline: nil
                    ))
                }
            }
        }
    }

    fileprivate func start(
        _ pipeline: any AudioCapturePipeline,
        lease: AudioCaptureStartupLease
    ) async -> AudioCapturePipelineStartResult {
        await withCheckedContinuation { continuation in
            startQueue.async {
                guard lease.beginStartExecution() else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                do {
                    let initialCount = try pipeline.start()
                    continuation.resume(returning: .started(
                        initialHeartbeatCount: initialCount,
                        runningStatusSuffix: pipeline.runningStatusSuffix
                    ))
                } catch {
                    continuation.resume(returning: .failed(error))
                }
            }
        }
    }

    func teardown(
        _ pipeline: any AudioCapturePipeline
    ) async -> AudioCaptureTeardownReport {
        await withCheckedContinuation { continuation in
            lifecycleQueue.async {
                continuation.resume(returning: pipeline.stop())
            }
        }
    }
}

@MainActor
final class AudioCaptureRuntime {
    private let pipelineBuilder: any AudioCapturePipelineBuilding
    private let healthMonitorBuilder: any AudioCallbackHealthMonitorBuilding
    private let diagnosticsMonitor = AudioCaptureDiagnosticsMonitor()
    private let pipelineExecutor: AudioCapturePipelineExecutor

    private var pipeline: (any AudioCapturePipeline)?
    private var healthMonitor: (any AudioCallbackHealthMonitoring)?
    private var buildOperation: (
        id: UInt64,
        lease: AudioCaptureStartupLease,
        task: Task<AudioCapturePipelineBuildResult, Never>
    )?
    private var startOperation: (
        id: UInt64,
        pipeline: any AudioCapturePipeline,
        lease: AudioCaptureStartupLease,
        task: Task<AudioCapturePipelineStartResult, Never>
    )?
    private var startupID: UInt64 = 0

    init(
        pipelineBuilder: any AudioCapturePipelineBuilding,
        healthMonitorBuilder: any AudioCallbackHealthMonitorBuilding,
        pipelineExecutor: AudioCapturePipelineExecutor = AudioCapturePipelineExecutor()
    ) {
        self.pipelineBuilder = pipelineBuilder
        self.healthMonitorBuilder = healthMonitorBuilder
        self.pipelineExecutor = pipelineExecutor
    }

    var isIdle: Bool {
        pipeline == nil && buildOperation == nil && startOperation == nil
    }

    func cancelStartup() {
        buildOperation?.lease.cancel()
    }

    func updateSettings(_ settings: LevelingSettings) {
        pipeline?.updateSettings(settings)
    }

    func start(
        request: PreparedCaptureRequest,
        currentSettings: @escaping @MainActor () -> LevelingSettings,
        isCurrent: @escaping @MainActor () -> Bool,
        onRouteChange: @escaping @MainActor @Sendable () -> Void,
        onStall: @escaping @MainActor () -> Void,
        onStatus: @escaping @MainActor (String) -> Void,
        onProcessingFailure: @escaping @MainActor (OSStatus) -> Void,
        runningStatus: String
    ) async -> AudioCaptureRuntimeStartResult {
        guard pipeline == nil, buildOperation == nil, startOperation == nil else {
            return .failed(VolEqError.missingValue(
                "An audio pipeline operation is already in progress."
            ))
        }

        startupID &+= 1
        let operationID = startupID
        let pipelineBuilder = pipelineBuilder
        let pipelineExecutor = pipelineExecutor
        let startupLease = AudioCaptureStartupLease()
        let buildTask = Task {
            await pipelineExecutor.build(
                builder: pipelineBuilder,
                request: request,
                onRouteChange: onRouteChange
            )
        }
        buildOperation = (operationID, startupLease, buildTask)
        let buildResult = await buildTask.value
        adoptBuildResult(buildResult, operationID: operationID)

        switch buildResult {
        case let .failed(error, _):
            return isCurrent() ? .failed(error) : .cancelled
        case let .built(builtPipeline):
            guard isCurrent(), pipeline === builtPipeline,
                  startupLease.scheduleStart()
            else { return .cancelled }
            builtPipeline.updateSettings(currentSettings())

            let startTask = Task {
                await pipelineExecutor.start(builtPipeline, lease: startupLease)
            }
            startOperation = (
                operationID,
                builtPipeline,
                startupLease,
                startTask
            )
            let startResult = await startTask.value
            finishStartOperation(operationID: operationID, pipeline: builtPipeline)

            switch startResult {
            case .cancelled:
                return .cancelled
            case let .failed(error):
                return isCurrent() ? .failed(error) : .cancelled
            case let .started(initialCount, runningStatusSuffix):
                guard isCurrent(), self.pipeline === builtPipeline else {
                    return .cancelled
                }
                let healthMonitor = healthMonitorBuilder.makeMonitor()
                self.healthMonitor = healthMonitor
                let progressed = await healthMonitor.waitForInitialProgress(
                    heartbeat: builtPipeline.heartbeat,
                    initialCount: initialCount,
                    isCurrent: { [weak self, weak builtPipeline] in
                        guard let self, let builtPipeline else { return false }
                        return isCurrent() && self.pipeline === builtPipeline
                    }
                )
                guard isCurrent(), self.pipeline === builtPipeline else {
                    return .cancelled
                }
                guard progressed else { return .callbacksDidNotStart }

                healthMonitor.startWatchdog(
                    heartbeat: builtPipeline.heartbeat,
                    isCurrent: { [weak self, weak builtPipeline] in
                        guard let self, let builtPipeline else { return false }
                        return isCurrent() && self.pipeline === builtPipeline
                    },
                    onStall: onStall
                )
                diagnosticsMonitor.start(
                    pipeline: builtPipeline,
                    runningStatus: runningStatus,
                    isCurrent: { [weak self] candidate in
                        self?.pipeline === candidate
                    },
                    onStatus: onStatus,
                    onFailure: onProcessingFailure
                )
                return .active(runningStatusSuffix: runningStatusSuffix)
            }
        }
    }

    func teardown() async -> AudioCaptureTeardownReport {
        healthMonitor?.stop()
        healthMonitor = nil
        diagnosticsMonitor.stop()

        if let buildOperation {
            cancelStartup()
            let buildResult = await buildOperation.task.value
            adoptBuildResult(buildResult, operationID: buildOperation.id)
        }

        guard let currentPipeline = pipeline else { return .complete }
        startOperation?.lease.cancel()
        let report = await pipelineExecutor.teardown(currentPipeline)

        if report.isComplete,
           let startOperation,
           startOperation.pipeline === currentPipeline {
            _ = await startOperation.task.value
            finishStartOperation(
                operationID: startOperation.id,
                pipeline: currentPipeline
            )
        }
        if pipeline === currentPipeline, report.isComplete { pipeline = nil }
        return report
    }

    private func adoptBuildResult(
        _ result: AudioCapturePipelineBuildResult,
        operationID: UInt64
    ) {
        guard buildOperation?.id == operationID else { return }
        buildOperation = nil
        switch result {
        case let .built(pipeline):
            self.pipeline = pipeline
        case let .failed(_, retainedPipeline):
            pipeline = retainedPipeline
        }
    }

    private func finishStartOperation(
        operationID: UInt64,
        pipeline: any AudioCapturePipeline
    ) {
        guard startOperation?.id == operationID,
              startOperation?.pipeline === pipeline
        else { return }
        startOperation = nil
    }
}
