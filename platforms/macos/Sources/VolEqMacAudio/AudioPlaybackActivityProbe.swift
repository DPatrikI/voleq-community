// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import CVolEqRealtime
import Foundation

enum AudioPlaybackActivityOutcome: Equatable, Sendable {
    case signalDetected(qualifyingCallbackCount: UInt32)
    case malformedInput
    case cancelled
    case coreAudioFailure(operation: String, status: OSStatus)
    case cleanupFailed([AudioCaptureTeardownStep])
}

struct AudioPlaybackActivityConfiguration: Equatable, Sendable {
    let captureTarget: AudioCaptureTarget
    let outputDeviceUID: String
}

protocol AudioPlaybackActivityProbing: AnyObject, Sendable {
    func observeUntilSignalOrCancelled() async -> AudioPlaybackActivityOutcome
    func cancel()
}

protocol AudioPlaybackActivityProbeBuilding: Sendable {
    func makeProbe(
        configuration: AudioPlaybackActivityConfiguration
    ) throws -> any AudioPlaybackActivityProbing
}

@available(macOS 14.2, *)
struct CoreAudioPlaybackActivityProbeBuilder:
    AudioPlaybackActivityProbeBuilding {
    func makeProbe(
        configuration: AudioPlaybackActivityConfiguration
    ) throws -> any AudioPlaybackActivityProbing {
        try CoreAudioPlaybackActivityProbe(configuration: configuration)
    }
}

final class AudioPlaybackSignalLatch: @unchecked Sendable {
    private(set) var state: OpaquePointer?

    init() throws {
        guard let state = voleq_realtime_signal_latch_create() else {
            throw VolEqError.missingValue(
                "VolEq could not allocate playback activity state."
            )
        }
        self.state = state
    }

    deinit { destroy() }

    var qualifyingCallbackCount: UInt32 {
        guard let state else { return 0 }
        return voleq_realtime_signal_latch_qualifying_callback_count(state)
    }

    var isMalformed: Bool {
        guard let state else { return true }
        return voleq_realtime_signal_latch_is_malformed(state)
    }

    func destroy() {
        guard let state else { return }
        voleq_realtime_signal_latch_destroy(state)
        self.state = nil
    }

#if DEBUG
    func _testOnlyObserve(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let state else { return }
        voleq_realtime_signal_latch_observe_callback(state, inputData)
    }
#endif
}

private final class AudioPlaybackActivityCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

private final class AudioPlaybackActivityStartStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OSStatus?

    func finish(_ status: OSStatus) { lock.withLock { value = status } }
    var current: OSStatus? { lock.withLock { value } }
}

@available(macOS 14.2, *)
final class CoreAudioPlaybackActivityProbe:
    AudioPlaybackActivityProbing,
    @unchecked Sendable {
    private let configuration: AudioPlaybackActivityConfiguration
    private let operations: CoreAudioCapturePipelineOperations
    private let pollNanoseconds: UInt64
    private let lifecycleQueue: DispatchQueue
    private let startQueue: DispatchQueue
    private let ioQueue: DispatchQueue
    private let cancellation = AudioPlaybackActivityCancellation()
    private let signalLatch: AudioPlaybackSignalLatch
    private let resources: CoreAudioCaptureResourceOwner
    private let prepareResourcesOverride: (() throws -> Void)?
    private var mustRetainSignalStateAfterCleanupFailure = false

    init(
        configuration: AudioPlaybackActivityConfiguration,
        operations: CoreAudioCapturePipelineOperations = .live,
        pollNanoseconds: UInt64 = 20_000_000,
        prepareResourcesOverride: (() throws -> Void)? = nil,
        lifecycleQueue: DispatchQueue = DispatchQueue(
            label: "com.patrikistvandoczy.voleq.playback-activity.lifecycle",
            qos: .userInitiated
        ),
        startQueue: DispatchQueue = DispatchQueue(
            label: "com.patrikistvandoczy.voleq.playback-activity.start",
            qos: .userInitiated
        ),
        ioQueue: DispatchQueue = DispatchQueue(
            label: "com.patrikistvandoczy.voleq.playback-activity.io",
            qos: .userInteractive
        ),
        startShutdownWaitNanoseconds: UInt64 = 500_000_000
    ) throws {
        self.configuration = configuration
        self.operations = operations
        self.pollNanoseconds = pollNanoseconds
        self.prepareResourcesOverride = prepareResourcesOverride
        self.lifecycleQueue = lifecycleQueue
        self.startQueue = startQueue
        self.ioQueue = ioQueue
        signalLatch = try AudioPlaybackSignalLatch()
        resources = CoreAudioCaptureResourceOwner(
            operations: operations,
            routeQueue: lifecycleQueue,
            startShutdownWaitNanoseconds: startShutdownWaitNanoseconds
        )
    }

    func observeUntilSignalOrCancelled() async -> AudioPlaybackActivityOutcome {
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .cancelled
        }

        do {
            try await performOnLifecycleQueue { [self] in
                if let prepareResourcesOverride {
                    try prepareResourcesOverride()
                } else {
                    try prepareResources()
                }
            }
        } catch let VolEqError.coreAudio(operation, status) {
            return await finish(
                outcome: .coreAudioFailure(operation: operation, status: status)
            )
        } catch {
            return await finish(outcome: .coreAudioFailure(
                operation: "Prepare playback activity watcher",
                status: kAudioHardwareUnspecifiedError
            ))
        }

        let startStatus = AudioPlaybackActivityStartStatus()
        let startTask = Task { [startQueue, resources] in
            await withCheckedContinuation { continuation in
                startQueue.async {
                    let status = resources.startIOProc()
                    startStatus.finish(status)
                    continuation.resume(returning: status)
                }
            }
        }
        var outcome: AudioPlaybackActivityOutcome = .cancelled
        while !cancellation.isCancelled, !Task.isCancelled {
            if let status = startStatus.current, status != noErr {
                outcome = .coreAudioFailure(
                    operation: "Start playback activity watcher",
                    status: status
                )
                break
            }
            if signalLatch.isMalformed {
                outcome = .malformedInput
                break
            }
            let count = signalLatch.qualifyingCallbackCount
            if count >= 2 {
                outcome = .signalDetected(qualifyingCallbackCount: count)
                break
            }
            do {
                try await Task.sleep(nanoseconds: pollNanoseconds)
            } catch {
                outcome = .cancelled
                break
            }
        }
        if cancellation.isCancelled || Task.isCancelled {
            outcome = .cancelled
        }
        let finished = await finish(outcome: outcome)
        if case .cleanupFailed = finished {
            // A blocked HAL Start remains owned by its task and resource owner.
            // Teardown has already bounded its wait and reported the retained
            // graph, so do not turn that safe failure into an unbounded wait.
            return finished
        }
        _ = await startTask.value
        return finished
    }

    func cancel() { cancellation.cancel() }

    deinit {
        if mustRetainSignalStateAfterCleanupFailure {
            _ = Unmanaged.passRetained(signalLatch)
        }
    }

    private func prepareResources() throws {
        guard let signalState = signalLatch.state else {
            throw VolEqError.missingValue(
                "Playback activity observation was cancelled before it started."
            )
        }

        let description = CATapDescription()
        description.name = "VolEq Playback Activity"
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        description.muteBehavior = .unmuted
        description.deviceUID = configuration.outputDeviceUID
        switch configuration.captureTarget {
        case let .application(processID):
            description.processes = [processID]
            description.isExclusive = false
        case .deviceWide:
            description.processes = [try resolveDeviceWideSelfExclusion(
                using: operations.ownProcessObject
            )]
            description.isExclusive = true
        }

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try requireNoErr(
            AudioHardwareCreateProcessTap(description, &tapID),
            "Create unmuted playback activity tap"
        )
        resources.didCreateTap(tapID)

        let tapUID = try readString(objectID: tapID, selector: kAudioTapPropertyUID)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolEq Private Playback Activity",
            kAudioAggregateDeviceUIDKey:
                "com.patrikistvandoczy.voleq.community.playback-activity.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try requireNoErr(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateID
            ),
            "Create private playback activity device"
        )
        resources.didCreateAggregate(aggregateID)

        let inputFormat: AudioStreamBasicDescription = try readValue(
            objectID: aggregateID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeInput
        )
        try validateCaptureAudioFormat(
            inputFormat,
            label: "Playback activity"
        )

        var ioProcID: AudioDeviceIOProcID?
        try requireNoErr(
            AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateID,
                ioQueue
            ) { _, inputData, _, _, _ in
                voleq_realtime_signal_latch_observe_callback(
                    signalState,
                    inputData
                )
            },
            "Create playback activity callback"
        )
        guard let ioProcID else {
            throw VolEqError.missingValue(
                "Core Audio created no playback activity callback."
            )
        }
        resources.didCreateIOProc(ioProcID)
    }

    private func finish(
        outcome: AudioPlaybackActivityOutcome
    ) async -> AudioPlaybackActivityOutcome {
        let report = await withCheckedContinuation { continuation in
            lifecycleQueue.async { [resources] in
                continuation.resume(returning: resources.teardown())
            }
        }
        guard report.isComplete else {
            // The probe and its preallocated callback state remain owned by this
            // object. Callers retain the probe when cleanup fails.
            mustRetainSignalStateAfterCleanupFailure = true
            return .cleanupFailed(report.unresolvedSteps)
        }
        signalLatch.destroy()
        return outcome
    }

    private func performOnLifecycleQueue(
        _ operation: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lifecycleQueue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }


#if DEBUG
    func _testOnlyAdoptResources(
        tapID: AudioObjectID,
        aggregateDeviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID
    ) {
        resources.didCreateTap(tapID)
        resources.didCreateAggregate(aggregateDeviceID)
        resources.didCreateIOProc(ioProcID)
    }

    func _testOnlyObserve(_ inputData: UnsafePointer<AudioBufferList>) {
        signalLatch._testOnlyObserve(inputData)
    }
#endif
}
