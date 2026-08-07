// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import CVolEqRealtime
import Foundation

public enum SystemAudioAccessIssue: Equatable, Sendable {
    case permissionNotGranted
    case couldNotVerify
    case malformedAudio
    case coreAudioFailure
    case cleanupFailed
}

public enum SystemAudioAccessState: Equatable, Sendable {
    case notRequested
    case explanationRequired
    case checking
    case verified
    case actionRequired(SystemAudioAccessIssue)
}

enum SystemAudioPermissionProbeOutcome: Equatable {
    case verified
    case denied
    case timedOut
    case cancelled
    case malformed
    case coreAudioFailure(operation: String, status: OSStatus)
}

struct SystemAudioPermissionProbeConfiguration: Equatable {
    enum Target: Equatable {
        case application(AudioObjectID)
        case deviceWide(excluding: AudioObjectID)
    }

    let target: Target
    let outputDeviceUID: String
}

@MainActor
protocol SystemAudioPermissionProbing: AnyObject {
    var isTornDown: Bool { get }

    func verify() async -> SystemAudioPermissionProbeOutcome
    func cancel()
}

protocol PermissionProbeTiming: Sendable {
    func nowNanoseconds() -> UInt64
    func sleep(nanoseconds: UInt64) async throws
}

struct ContinuousPermissionProbeTiming: PermissionProbeTiming {
    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

final class PermissionSignalLatch: @unchecked Sendable {
    private(set) var state: OpaquePointer?

    init() throws {
        guard let state = voleq_realtime_signal_latch_create() else {
            throw VolEqError.missingValue(
                "VolEq could not allocate the audio-access verification state."
            )
        }
        self.state = state
    }

    deinit {
        destroy()
    }

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

@available(macOS 14.2, *)
struct CoreAudioPermissionProbeOperations: @unchecked Sendable {
    let start: (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus
    let stop: (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus
    let destroyIOProc: (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus
    let destroyAggregate: (AudioObjectID) -> OSStatus
    let destroyTap: (AudioObjectID) -> OSStatus

    static let live = CoreAudioPermissionProbeOperations(
        start: AudioDeviceStart,
        stop: AudioDeviceStop,
        destroyIOProc: { deviceID, ioProcID in
            guard let ioProcID else { return kAudio_ParamError }
            return AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        },
        destroyAggregate: AudioHardwareDestroyAggregateDevice,
        destroyTap: AudioHardwareDestroyProcessTap
    )
}

private final class PermissionProbeStartResult: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: OSStatus?

    func finish(with status: OSStatus) {
        condition.lock()
        value = status
        condition.broadcast()
        condition.unlock()
    }

    func read() -> OSStatus? {
        condition.withLock { value }
    }

    func waitUntilFinished(timeoutNanoseconds: UInt64) -> OSStatus? {
        condition.lock()
        defer { condition.unlock() }
        guard value == nil else { return value }
        let deadline = Date(
            timeIntervalSinceNow: Double(timeoutNanoseconds) / 1_000_000_000
        )
        while value == nil, condition.wait(until: deadline) {}
        return value
    }
}

@available(macOS 14.2, *)
private struct PermissionProbeStartRequest: @unchecked Sendable {
    let deviceID: AudioObjectID
    let ioProcID: AudioDeviceIOProcID?
    let operations: CoreAudioPermissionProbeOperations
    let result: PermissionProbeStartResult
}

@MainActor
@available(macOS 14.2, *)
final class CoreAudioSystemPermissionProbe: SystemAudioPermissionProbing {
    private let configuration: SystemAudioPermissionProbeConfiguration
    private let timing: any PermissionProbeTiming
    private let timeoutNanoseconds: UInt64
    private let pollNanoseconds: UInt64
    private let operations: CoreAudioPermissionProbeOperations
    private let prepareResourcesOverride: (() throws -> Void)?
    private let startShutdownWaitNanoseconds: UInt64
    private let ioQueue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.permission-probe",
        qos: .userInitiated
    )

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var signalLatch: PermissionSignalLatch?
    private var startResult: PermissionProbeStartResult?
    private var startAttempted = false
    private var cancelled = false

    init(
        configuration: SystemAudioPermissionProbeConfiguration,
        timing: any PermissionProbeTiming = ContinuousPermissionProbeTiming(),
        timeoutNanoseconds: UInt64 = 30_000_000_000,
        pollNanoseconds: UInt64 = 20_000_000,
        operations: CoreAudioPermissionProbeOperations = .live,
        prepareResourcesOverride: (() throws -> Void)? = nil,
        startShutdownWaitNanoseconds: UInt64 = 500_000_000
    ) throws {
        self.configuration = configuration
        self.timing = timing
        self.timeoutNanoseconds = timeoutNanoseconds
        self.pollNanoseconds = pollNanoseconds
        self.operations = operations
        self.prepareResourcesOverride = prepareResourcesOverride
        self.startShutdownWaitNanoseconds = startShutdownWaitNanoseconds
        signalLatch = try PermissionSignalLatch()
    }

    deinit {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            let attempted = startAttempted
            let status = startResult?.read()
            var safeToDestroy = !attempted || status != nil && status != noErr
            if attempted, status == nil || status == noErr {
                let stopStatus = operations.stop(aggregateDeviceID, ioProcID)
                var completedStatus = status
                if completedStatus == nil {
                    completedStatus = startResult?.waitUntilFinished(
                        timeoutNanoseconds: startShutdownWaitNanoseconds
                    )
                }
                safeToDestroy = completedStatus != nil
                    && (stopStatus == noErr || completedStatus != noErr)
            }
            if safeToDestroy,
               operations.destroyIOProc(aggregateDeviceID, ioProcID) == noErr {
                self.ioProcID = nil
            }
        }
        if ioProcID == nil, aggregateDeviceID != kAudioObjectUnknown,
           operations.destroyAggregate(aggregateDeviceID) == noErr {
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if aggregateDeviceID == kAudioObjectUnknown,
           tapID != kAudioObjectUnknown,
           operations.destroyTap(tapID) == noErr {
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // If Core Audio refused to remove a live callback, deliberately keep
        // its latch alive until process exit. Leaking a tiny latch is safer
        // than freeing memory that an OS-owned realtime callback may still use.
        if ioProcID != nil, let signalLatch {
            _ = Unmanaged.passRetained(signalLatch)
            self.signalLatch = nil
        }
    }

    var isTornDown: Bool {
        tapID == kAudioObjectUnknown
            && aggregateDeviceID == kAudioObjectUnknown
            && ioProcID == nil
            && signalLatch == nil
    }

    func verify() async -> SystemAudioPermissionProbeOutcome {
        guard !cancelled else {
            teardown()
            return .cancelled
        }

        let start = timing.nowNanoseconds()
        let deadline = start.addingReportingOverflow(timeoutNanoseconds)
        do {
            if let prepareResourcesOverride {
                try prepareResourcesOverride()
            } else {
                try prepareResources()
            }
            beginDeviceStart()
        } catch let VolEqError.coreAudio(operation, status) {
            if let cleanupFailure = teardown() {
                return cleanupFailure
            }
            if status == kAudioDevicePermissionsError {
                return .denied
            }
            return .coreAudioFailure(operation: operation, status: status)
        } catch {
            if let cleanupFailure = teardown() {
                return cleanupFailure
            }
            return .coreAudioFailure(
                operation: "Prepare audio-access verification",
                status: kAudioHardwareUnspecifiedError
            )
        }

        var outcome: SystemAudioPermissionProbeOutcome = .cancelled
        while !cancelled && !Task.isCancelled {
            guard let signalLatch else { return .cancelled }
            if let startStatus = startResult?.read(), startStatus != noErr {
                outcome = startStatus == kAudioDevicePermissionsError
                    ? .denied
                    : .coreAudioFailure(
                        operation: "Start audio-access verification",
                        status: startStatus
                    )
                break
            }
            if signalLatch.isMalformed {
                outcome = .malformed
                break
            }
            if startResult?.read() == noErr,
               signalLatch.qualifyingCallbackCount >= 2 {
                outcome = .verified
                break
            }

            let now = timing.nowNanoseconds()
            if deadline.overflow || now >= deadline.partialValue {
                outcome = .timedOut
                break
            }

            do {
                try await timing.sleep(nanoseconds: pollNanoseconds)
            } catch {
                outcome = .cancelled
                break
            }
        }
        if let cleanupFailure = teardown() {
            return cleanupFailure
        }
        return outcome
    }

    func cancel() {
        cancelled = true
        _ = teardown()
    }

    private func prepareResources() throws {
        guard let signalState = signalLatch?.state else {
            throw VolEqError.missingValue(
                "Audio-access verification was cancelled before it started."
            )
        }

        let description = CATapDescription()
        description.name = "VolEq Audio Access Verification"
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        description.muteBehavior = .unmuted
        description.deviceUID = configuration.outputDeviceUID

        switch configuration.target {
        case let .application(processID):
            description.processes = [processID]
            description.isExclusive = false
        case let .deviceWide(ownProcessID):
            description.processes = [ownProcessID]
            description.isExclusive = true
        }

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try requireNoErr(
            AudioHardwareCreateProcessTap(description, &newTapID),
            "Create unmuted audio-access verification tap"
        )
        tapID = newTapID

        let tapUID = try readString(objectID: tapID, selector: kAudioTapPropertyUID)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolEq Private Permission Probe",
            kAudioAggregateDeviceUIDKey:
                "com.patrikistvandoczy.voleq.community.permission-probe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            // Starting this input-only probe must not wait synchronously for
            // tapped audio. The explicit 30-second verifier owns that wait.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try requireNoErr(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &newAggregateID
            ),
            "Create private audio-access verification device"
        )
        aggregateDeviceID = newAggregateID

        let inputFormat: AudioStreamBasicDescription = try readValue(
            objectID: aggregateDeviceID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeInput
        )
        try validateFloat32(inputFormat, label: "Audio-access verification")
        try validateSupportedChannelLayout(
            inputFormat,
            label: "Audio-access verification"
        )

        var newIOProcID: AudioDeviceIOProcID?
        try requireNoErr(
            AudioDeviceCreateIOProcIDWithBlock(
                &newIOProcID,
                aggregateDeviceID,
                ioQueue
            ) { _, inputData, _, _, _ in
                voleq_realtime_signal_latch_observe_callback(
                    signalState,
                    inputData
                )
            },
            "Create audio-access verification callback"
        )
        ioProcID = newIOProcID
    }

    private func beginDeviceStart() {
        let result = PermissionProbeStartResult()
        startResult = result
        startAttempted = true
        let request = PermissionProbeStartRequest(
            deviceID: aggregateDeviceID,
            ioProcID: ioProcID,
            operations: operations,
            result: result
        )
        DispatchQueue.global(qos: .userInitiated).async {
            request.result.finish(with: request.operations.start(
                request.deviceID,
                request.ioProcID
            ))
        }
    }

    @discardableResult
    private func teardown() -> SystemAudioPermissionProbeOutcome? {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            let startStatus = startResult?.read()
            let shouldStop = startAttempted
                && (startStatus == nil || startStatus == noErr)
            if shouldStop {
                let stopStatus = operations.stop(aggregateDeviceID, ioProcID)
                let completedStatus = startStatus ?? startResult?.waitUntilFinished(
                    timeoutNanoseconds: startShutdownWaitNanoseconds
                )
                guard let completedStatus else {
                    return .coreAudioFailure(
                        operation: "Finish stopping audio-access verification",
                        status: kAudioHardwareUnspecifiedError
                    )
                }
                guard stopStatus == noErr || completedStatus != noErr else {
                    return .coreAudioFailure(
                        operation: "Stop audio-access verification",
                        status: stopStatus
                    )
                }
            }
            let destroyStatus = operations.destroyIOProc(
                aggregateDeviceID,
                ioProcID
            )
            guard destroyStatus == noErr else {
                return .coreAudioFailure(
                    operation: "Destroy audio-access verification callback",
                    status: destroyStatus
                )
            }
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            let status = operations.destroyAggregate(aggregateDeviceID)
            guard status == noErr else {
                return .coreAudioFailure(
                    operation: "Destroy audio-access verification device",
                    status: status
                )
            }
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            let status = operations.destroyTap(tapID)
            guard status == noErr else {
                return .coreAudioFailure(
                    operation: "Destroy audio-access verification tap",
                    status: status
                )
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        signalLatch?.destroy()
        signalLatch = nil
        startResult = nil
        startAttempted = false
        return nil
    }

#if DEBUG
    func _testOnlyAdoptResources(
        tapID: AudioObjectID,
        aggregateDeviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID?,
        startAttempted: Bool = true
    ) {
        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
        self.ioProcID = ioProcID
        self.startAttempted = startAttempted
    }
#endif
}
