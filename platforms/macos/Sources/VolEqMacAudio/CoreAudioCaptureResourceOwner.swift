// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation

private final class CapturePipelineStartResult: @unchecked Sendable {
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
final class CoreAudioCaptureResourceOwner: @unchecked Sendable {
    private enum CallbackState {
        case prepared
        case startPending(CapturePipelineStartResult)
        case running
        case stopped
    }

    private enum GraphStage {
        case empty
        case tap(AudioObjectID)
        case aggregate(tap: AudioObjectID, device: AudioObjectID)
        case callback(
            tap: AudioObjectID,
            device: AudioObjectID,
            ioProc: AudioDeviceIOProcID,
            state: CallbackState
        )
    }

    private let operations: CoreAudioCapturePipelineOperations
    private let routeQueue: DispatchQueue
    private let startShutdownWaitNanoseconds: UInt64
    private let lock = NSLock()
    private var graphStage: GraphStage = .empty
    private var teardownRequested = false
    private var activeOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var activeOutputListener: AudioObjectPropertyListenerBlock?
    private var activeOutputListenerAddresses: [AudioObjectPropertyAddress] = []
    private var unresolvedTeardownSteps: [AudioCaptureTeardownStep] = []

    init(
        operations: CoreAudioCapturePipelineOperations,
        routeQueue: DispatchQueue,
        startShutdownWaitNanoseconds: UInt64 = 500_000_000
    ) {
        self.operations = operations
        self.routeQueue = routeQueue
        self.startShutdownWaitNanoseconds = startShutdownWaitNanoseconds
    }

    var tapID: AudioObjectID {
        lock.withLock {
            switch graphStage {
            case .empty: kAudioObjectUnknown
            case let .tap(tap), let .aggregate(tap, _),
                 let .callback(tap, _, _, _): tap
            }
        }
    }

    var aggregateDeviceID: AudioObjectID {
        lock.withLock {
            switch graphStage {
            case .empty, .tap: kAudioObjectUnknown
            case let .aggregate(_, device), let .callback(_, device, _, _):
                device
            }
        }
    }

    var ioProcID: AudioDeviceIOProcID? {
        lock.withLock {
            guard case let .callback(_, _, ioProc, _) = graphStage else {
                return nil
            }
            return ioProc
        }
    }

    func didInstallOutputListener(
        deviceID: AudioObjectID,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        lock.withLock {
            precondition(activeOutputListener == nil)
            activeOutputDeviceID = deviceID
            activeOutputListener = listener
        }
    }

    func didInstallOutputListenerAddress(_ address: AudioObjectPropertyAddress) {
        lock.withLock {
            precondition(activeOutputListener != nil)
            activeOutputListenerAddresses.append(address)
        }
    }

    func didCreateTap(_ id: AudioObjectID) {
        lock.withLock {
            guard case .empty = graphStage else { preconditionFailure() }
            graphStage = .tap(id)
        }
    }

    func didCreateAggregate(_ id: AudioObjectID) {
        lock.withLock {
            guard case let .tap(tap) = graphStage else { preconditionFailure() }
            graphStage = .aggregate(tap: tap, device: id)
        }
    }

    func didCreateIOProc(_ id: AudioDeviceIOProcID) {
        lock.withLock {
            guard case let .aggregate(tap, device) = graphStage else {
                preconditionFailure()
            }
            graphStage = .callback(
                tap: tap,
                device: device,
                ioProc: id,
                state: .prepared
            )
        }
    }

    func startIOProc() -> OSStatus {
        let request: CapturePipelineStartRequest? = lock.withLock {
            guard case let .callback(tap, device, ioProc, .prepared) = graphStage
            else { return nil }
            let result = CapturePipelineStartResult()
            graphStage = .callback(
                tap: tap,
                device: device,
                ioProc: ioProc,
                state: .startPending(result)
            )
            return CapturePipelineStartRequest(
                deviceID: device,
                ioProcID: ioProc,
                operations: operations,
                result: result
            )
        }
        guard let request else {
            // Teardown may have won after the outer executor admitted Start.
            // A late call must fail without touching an already-destroyed graph.
            return kAudio_ParamError
        }

        let status = request.operations.start(request.deviceID, request.ioProcID)
        request.result.finish(with: status)
        let shouldFinishTeardown = lock.withLock { () -> Bool in
            guard case let .callback(tap, device, ioProc, .startPending(result)) = graphStage,
                  result === request.result
            else { return false }
            graphStage = .callback(
                tap: tap,
                device: device,
                ioProc: ioProc,
                state: status == noErr ? .running : .stopped
            )
            return teardownRequested
        }
        if shouldFinishTeardown { _ = teardown() }
        return status
    }

    func teardown() -> AudioCaptureTeardownReport {
        lock.withLock {
            teardownRequested = true
            return teardownLocked()
        }
    }

    private func teardownLocked() -> AudioCaptureTeardownReport {
        var unresolved = unresolvedTeardownSteps
        if !removeOutputListeners() {
            unresolved.addUnique(.activeOutputListeners)
        } else {
            unresolved.removeAll { $0 == .activeOutputListeners }
        }

        if case let .callback(tap, device, ioProc, state) = graphStage {
            let stoppedState: CallbackState
            switch state {
            case .prepared:
                stoppedState = .stopped
            case .running:
                if operations.stop(device, ioProc) == noErr {
                    unresolved.removeAll { $0 == .stopIOProc }
                    stoppedState = .stopped
                } else {
                    unresolved.addUnique(.stopIOProc)
                    stoppedState = .running
                }
            case let .startPending(result):
                let completed: OSStatus?
                if let startStatus = result.read() {
                    completed = startStatus
                } else {
                    // This may unblock a pending HAL Start. It is not proof
                    // that a subsequently successful Start is stopped.
                    _ = operations.stop(device, ioProc)
                    completed = result.waitUntilFinished(
                        timeoutNanoseconds: startShutdownWaitNanoseconds
                    )
                }
                guard let completed else {
                    unresolved.addUnique(.finishIOProcStart)
                    unresolved.addUnique(.destroyIOProc)
                    unresolved.addUnique(.destroyAggregate)
                    unresolved.addUnique(.destroyTap)
                    unresolvedTeardownSteps = unresolved
                    return AudioCaptureTeardownReport(unresolvedSteps: unresolved)
                }
                unresolved.removeAll { $0 == .finishIOProcStart }
                if completed == noErr {
                    if operations.stop(device, ioProc) == noErr {
                        unresolved.removeAll { $0 == .stopIOProc }
                        stoppedState = .stopped
                    } else {
                        unresolved.addUnique(.stopIOProc)
                        stoppedState = .running
                    }
                } else {
                    stoppedState = .stopped
                }
            case .stopped:
                stoppedState = .stopped
            }

            graphStage = .callback(
                tap: tap,
                device: device,
                ioProc: ioProc,
                state: stoppedState
            )
            if operations.destroyIOProc(device, ioProc) == noErr {
                graphStage = .aggregate(tap: tap, device: device)
                unresolved.removeAll {
                    $0 == .finishIOProcStart
                        || $0 == .stopIOProc
                        || $0 == .destroyIOProc
                }
            } else {
                unresolved.addUnique(.destroyIOProc)
                unresolved.addUnique(.destroyAggregate)
                unresolved.addUnique(.destroyTap)
                unresolvedTeardownSteps = unresolved
                return AudioCaptureTeardownReport(unresolvedSteps: unresolved)
            }
        }

        if case let .aggregate(tap, device) = graphStage {
            if operations.destroyAggregate(device) == noErr {
                graphStage = .tap(tap)
                unresolved.removeAll { $0 == .destroyAggregate }
            } else {
                unresolved.addUnique(.destroyAggregate)
                unresolved.addUnique(.destroyTap)
                unresolvedTeardownSteps = unresolved
                return AudioCaptureTeardownReport(unresolvedSteps: unresolved)
            }
        }
        if case let .tap(tap) = graphStage {
            if operations.destroyTap(tap) == noErr {
                graphStage = .empty
                unresolved.removeAll { $0 == .destroyTap }
            } else {
                unresolved.addUnique(.destroyTap)
            }
        }
        unresolvedTeardownSteps = unresolved
        return AudioCaptureTeardownReport(unresolvedSteps: unresolved)
    }

    private func removeOutputListeners() -> Bool {
        guard activeOutputDeviceID != kAudioObjectUnknown,
              let activeOutputListener
        else { return activeOutputListenerAddresses.isEmpty }
        var unresolvedAddresses: [AudioObjectPropertyAddress] = []
        for address in activeOutputListenerAddresses {
            let injectedStatus = operations.removePropertyListenerStatus(
                activeOutputDeviceID,
                address
            )
            var mutableAddress = address
            let status = injectedStatus == noErr
                ? AudioObjectRemovePropertyListenerBlock(
                    activeOutputDeviceID,
                    &mutableAddress,
                    routeQueue,
                    activeOutputListener
                )
                : injectedStatus
            if status != noErr {
                unresolvedAddresses.append(address)
            }
        }
        activeOutputListenerAddresses = unresolvedAddresses
        guard unresolvedAddresses.isEmpty else { return false }
        activeOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
        self.activeOutputListener = nil
        return true
    }
}

@available(macOS 14.2, *)
private struct CapturePipelineStartRequest: @unchecked Sendable {
    let deviceID: AudioObjectID
    let ioProcID: AudioDeviceIOProcID?
    let operations: CoreAudioCapturePipelineOperations
    let result: CapturePipelineStartResult
}

private extension Array where Element == AudioCaptureTeardownStep {
    mutating func addUnique(_ step: AudioCaptureTeardownStep) {
        if !contains(step) { append(step) }
    }
}
