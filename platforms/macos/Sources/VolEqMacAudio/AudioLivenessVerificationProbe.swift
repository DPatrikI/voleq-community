// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import CVolEqRealtime
import Foundation

enum AudioLivenessVerificationOutcome: Equatable, Sendable {
    case signalDetected(qualifyingCallbackCount: UInt32)
    case noSignal
    case malformedInput
    case cancelled
    case coreAudioFailure(operation: String, status: OSStatus)
    case cleanupFailed([AudioCaptureTeardownStep])
}

struct AudioLivenessVerificationConfiguration: Equatable, Sendable {
    let captureTarget: AudioCaptureTarget
    let outputDeviceUID: String
}

protocol AudioLivenessVerificationProbing: AnyObject, Sendable {
    func verify() async -> AudioLivenessVerificationOutcome
    func cancel()
}

protocol AudioLivenessVerificationProbeBuilding: Sendable {
    func makeProbe(
        configuration: AudioLivenessVerificationConfiguration
    ) throws -> any AudioLivenessVerificationProbing
}

@available(macOS 14.2, *)
struct CoreAudioLivenessVerificationProbeBuilder:
    AudioLivenessVerificationProbeBuilding {
    func makeProbe(
        configuration: AudioLivenessVerificationConfiguration
    ) throws -> any AudioLivenessVerificationProbing {
        try CoreAudioLivenessVerificationProbe(configuration: configuration)
    }
}

final class AudioSignalLatch: @unchecked Sendable {
    private(set) var state: OpaquePointer?

    init() throws {
        guard let state = voleq_realtime_signal_latch_create() else {
            throw VolEqError.missingValue(
                "VolEq could not allocate its audio-liveness verification state."
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

private final class AudioLivenessProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

private final class AudioLivenessProbeStartStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OSStatus?

    func finish(_ status: OSStatus) { lock.withLock { value = status } }
    var current: OSStatus? { lock.withLock { value } }
}

@available(macOS 14.2, *)
final class CoreAudioLivenessVerificationProbe:
    AudioLivenessVerificationProbing,
    @unchecked Sendable {
    private let configuration: AudioLivenessVerificationConfiguration
    private let operations: CoreAudioCapturePipelineOperations
    private let timeoutNanoseconds: UInt64
    private let pollNanoseconds: UInt64
    private let lifecycleQueue: DispatchQueue
    private let startQueue: DispatchQueue
    private let ioQueue: DispatchQueue
    private let cancellation = AudioLivenessProbeCancellation()
    private let signalLatch: AudioSignalLatch
    private let resources: CoreAudioCaptureResourceOwner
    private let prepareResourcesOverride: (() throws -> Void)?
    private var mustRetainSignalStateAfterCleanupFailure = false

    init(
        configuration: AudioLivenessVerificationConfiguration,
        operations: CoreAudioCapturePipelineOperations = .live,
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        pollNanoseconds: UInt64 = 20_000_000,
        prepareResourcesOverride: (() throws -> Void)? = nil,
        lifecycleQueue: DispatchQueue = DispatchQueue(
            label: "com.patrikistvandoczy.voleq.diagnostics.liveness-probe-lifecycle",
            qos: .userInitiated
        ),
        startQueue: DispatchQueue = DispatchQueue(
            label: "com.patrikistvandoczy.voleq.diagnostics.liveness-probe-start",
            qos: .userInitiated
        ),
        ioQueue: DispatchQueue = DispatchQueue(
            label: "com.patrikistvandoczy.voleq.diagnostics.liveness-probe-io",
            qos: .userInteractive
        )
    ) throws {
        self.configuration = configuration
        self.operations = operations
        self.timeoutNanoseconds = timeoutNanoseconds
        self.pollNanoseconds = pollNanoseconds
        self.prepareResourcesOverride = prepareResourcesOverride
        self.lifecycleQueue = lifecycleQueue
        self.startQueue = startQueue
        self.ioQueue = ioQueue
        signalLatch = try AudioSignalLatch()
        resources = CoreAudioCaptureResourceOwner(
            operations: operations,
            routeQueue: lifecycleQueue
        )
    }

    func verify() async -> AudioLivenessVerificationOutcome {
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
                operation: "Prepare audio-liveness verification",
                status: kAudioHardwareUnspecifiedError
            ))
        }

        let startStatus = AudioLivenessProbeStartStatus()
        let startTask = Task { [startQueue, resources] in
            await withCheckedContinuation { continuation in
                startQueue.async {
                    let status = resources.startIOProc()
                    startStatus.finish(status)
                    continuation.resume(returning: status)
                }
            }
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var outcome: AudioLivenessVerificationOutcome = .noSignal
        while !cancellation.isCancelled, !Task.isCancelled {
            if let status = startStatus.current, status != noErr {
                outcome = .coreAudioFailure(
                    operation: "Start audio-liveness verification",
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
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= startedAt, now - startedAt >= timeoutNanoseconds {
                outcome = .noSignal
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
                "Audio-liveness verification was cancelled before it started."
            )
        }

        let description = CATapDescription()
        description.name = "VolEq Audio Liveness Verification"
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
            "Create unmuted audio-liveness verification tap"
        )
        resources.didCreateTap(tapID)

        let tapUID = try readString(objectID: tapID, selector: kAudioTapPropertyUID)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolEq Private Liveness Probe",
            kAudioAggregateDeviceUIDKey:
                "com.patrikistvandoczy.voleq.community.liveness-probe.\(UUID().uuidString)",
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
            "Create private audio-liveness verification device"
        )
        resources.didCreateAggregate(aggregateID)

        let inputFormat: AudioStreamBasicDescription = try readValue(
            objectID: aggregateID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeInput
        )
        try validateCaptureAudioFormat(
            inputFormat,
            label: "Audio-liveness verification"
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
            "Create audio-liveness verification callback"
        )
        guard let ioProcID else {
            throw VolEqError.missingValue(
                "Core Audio created no audio-liveness verification callback."
            )
        }
        resources.didCreateIOProc(ioProcID)
    }

    private func finish(
        outcome: AudioLivenessVerificationOutcome
    ) async -> AudioLivenessVerificationOutcome {
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
