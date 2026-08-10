// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation

protocol AudioLifecycleClock: Sendable {
    func nowNanoseconds() -> UInt64
}

protocol AudioLifecycleScheduling: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

struct ContinuousAudioLifecycleClock: AudioLifecycleClock {
    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

struct ContinuousAudioLifecycleScheduler: AudioLifecycleScheduling {
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

struct AudioOutputRouteObservation: Equatable, Sendable {
    let deviceID: AudioObjectID
    let uid: String
    let sampleRate: Double
    let channelCount: UInt32
}

protocol AudioOutputRouteObserving: Sendable {
    func observe() async throws -> AudioOutputRouteObservation
}

struct CoreAudioOutputRouteObserverOperations: @unchecked Sendable {
    let observe: () throws -> AudioOutputRouteObservation

    static let live = Self(observe: CoreAudioOutputRouteObserver.observeSynchronously)
}

private final class CoreAudioOutputRouteObservationExecutor: @unchecked Sendable {
    private let operations: CoreAudioOutputRouteObserverOperations
    private let queue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.route-observation",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var observationInFlight = false

    init(operations: CoreAudioOutputRouteObserverOperations) {
        self.operations = operations
    }

    func observe(
        lease: AudioOutputRouteObservationLease
    ) async throws -> AudioOutputRouteObservation {
        guard claimObservation() else {
            throw RecoveryFailure.routeUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self, operations] in
                continuation.resume(with: Result {
                    defer { releaseObservation() }
                    guard lease.isCurrent else { throw CancellationError() }
                    return try operations.observe()
                })
            }
        }
    }

    private func claimObservation() -> Bool {
        stateLock.withLock {
            guard !observationInFlight else { return false }
            observationInFlight = true
            return true
        }
    }

    private func releaseObservation() {
        stateLock.withLock { observationInFlight = false }
    }
}

private final class AudioOutputRouteObservationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCurrent: Bool { lock.withLock { !cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

struct CoreAudioOutputRouteObserver: AudioOutputRouteObserving {
    private let executor: CoreAudioOutputRouteObservationExecutor

    init(operations: CoreAudioOutputRouteObserverOperations = .live) {
        executor = CoreAudioOutputRouteObservationExecutor(
            operations: operations
        )
    }

    func observe() async throws -> AudioOutputRouteObservation {
        let lease = AudioOutputRouteObservationLease()
        let observation = try await withTaskCancellationHandler {
            try await executor.observe(lease: lease)
        } onCancel: {
            lease.cancel()
        }
        try Task.checkCancellation()
        return observation
    }

    fileprivate static func observeSynchronously() throws -> AudioOutputRouteObservation {
        let deviceID = try defaultOutputDevice()
        let alive: UInt32 = try readValue(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive
        )
        guard alive != 0 else {
            throw VolEqError.missingValue("The default audio output is not ready.")
        }
        let uid = try readString(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
        let format: AudioStreamBasicDescription = try readValue(
            objectID: deviceID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeOutput
        )
        try validateCaptureAudioFormat(format, label: "Output device")
        return AudioOutputRouteObservation(
            deviceID: deviceID,
            uid: uid,
            sampleRate: format.mSampleRate,
            channelCount: format.mChannelsPerFrame
        )
    }
}

protocol AudioOutputRouteStabilityChecking: Sendable {
    @MainActor func hasRouteChanged(
        since observation: AudioOutputRouteObservation
    ) async throws -> Bool
    @MainActor func waitUntilStable(
        initialDelayNanoseconds: UInt64,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> AudioOutputRouteObservation
}

struct AudioOutputRouteStabilityGate: AudioOutputRouteStabilityChecking {
    let observer: any AudioOutputRouteObserving
    let clock: any AudioLifecycleClock
    let scheduler: any AudioLifecycleScheduling
    let observationTimeoutScheduler: any AudioLifecycleScheduling
    let observationIntervalNanoseconds: UInt64
    let timeoutNanoseconds: UInt64
    let comparisonTimeoutNanoseconds: UInt64

    init(
        observer: any AudioOutputRouteObserving,
        clock: any AudioLifecycleClock,
        scheduler: any AudioLifecycleScheduling,
        observationTimeoutScheduler: (any AudioLifecycleScheduling)? = nil,
        observationIntervalNanoseconds: UInt64,
        timeoutNanoseconds: UInt64,
        comparisonTimeoutNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.observer = observer
        self.clock = clock
        self.scheduler = scheduler
        self.observationTimeoutScheduler =
            observationTimeoutScheduler ?? scheduler
        self.observationIntervalNanoseconds = observationIntervalNanoseconds
        self.timeoutNanoseconds = timeoutNanoseconds
        self.comparisonTimeoutNanoseconds = comparisonTimeoutNanoseconds
    }

    @MainActor
    func hasRouteChanged(
        since observation: AudioOutputRouteObservation
    ) async throws -> Bool {
        let now = clock.nowNanoseconds()
        let deadlineResult = now.addingReportingOverflow(
            comparisonTimeoutNanoseconds
        )
        let deadline = deadlineResult.overflow
            ? UInt64.max
            : deadlineResult.partialValue
        return try await observe(
            before: deadline,
            remainingNanoseconds: comparisonTimeoutNanoseconds
        ) != observation
    }

    @MainActor
    func waitUntilStable(
        initialDelayNanoseconds: UInt64,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> AudioOutputRouteObservation {
        try await scheduler.sleep(nanoseconds: initialDelayNanoseconds)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }

        let startedAt = clock.nowNanoseconds()
        let deadlineResult = startedAt.addingReportingOverflow(timeoutNanoseconds)
        let deadline = deadlineResult.overflow
            ? UInt64.max
            : deadlineResult.partialValue
        var previous: AudioOutputRouteObservation?

        while isCurrent(), !Task.isCancelled {
            let beforeObservation = clock.nowNanoseconds()
            guard beforeObservation < deadline else { break }

            do {
                let current = try await observe(
                    before: deadline,
                    remainingNanoseconds: deadline - beforeObservation
                )
                let afterObservation = clock.nowNanoseconds()
                guard afterObservation < deadline else { break }
                if current == previous { return current }
                previous = current
            } catch {
                previous = nil
            }

            let afterObservation = clock.nowNanoseconds()
            guard afterObservation < deadline else { break }
            let remaining = deadline - afterObservation
            try await scheduler.sleep(
                nanoseconds: min(observationIntervalNanoseconds, remaining)
            )
        }

        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        throw RecoveryFailure.routeUnavailable
    }

    private func observe(
        before deadline: UInt64,
        remainingNanoseconds: UInt64
    ) async throws -> AudioOutputRouteObservation {
        let race = AudioOutputRouteObservationDeadlineRace()
        return try await race.run(
            observer: observer,
            scheduler: observationTimeoutScheduler,
            timeoutNanoseconds: remainingNanoseconds,
            deadline: deadline,
            clock: clock
        )
    }
}

private final class AudioOutputRouteObservationDeadlineRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        AudioOutputRouteObservation,
        Error
    >?
    private var completedResult: Result<AudioOutputRouteObservation, Error>?
    private var tasks: [Task<Void, Never>] = []

    func run(
        observer: any AudioOutputRouteObserving,
        scheduler: any AudioLifecycleScheduling,
        timeoutNanoseconds: UInt64,
        deadline: UInt64,
        clock: any AudioLifecycleClock
    ) async throws -> AudioOutputRouteObservation {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard install(continuation) else { return }
                let observationTask = Task { [self] in
                    do {
                        let observation = try await observer.observe()
                        guard clock.nowNanoseconds() < deadline else {
                            resolve(.failure(RecoveryFailure.routeUnavailable))
                            return
                        }
                        resolve(.success(observation))
                    } catch {
                        resolve(.failure(error))
                    }
                }
                let timeoutTask = Task { [self] in
                    do {
                        await Task.yield()
                        try await scheduler.sleep(
                            nanoseconds: timeoutNanoseconds
                        )
                        resolve(.failure(RecoveryFailure.routeUnavailable))
                    } catch {
                        resolve(.failure(error))
                    }
                }
                installTasks([observationTask, timeoutTask])
            }
        } onCancel: {
            self.resolve(.failure(CancellationError()))
        }
    }

    private func install(
        _ continuation: CheckedContinuation<
            AudioOutputRouteObservation,
            Error
        >
    ) -> Bool {
        let completed = lock.withLock { () -> Result<
            AudioOutputRouteObservation,
            Error
        >? in
            if let completedResult { return completedResult }
            self.continuation = continuation
            return nil
        }
        guard let completed else { return true }
        continuation.resume(with: completed)
        return false
    }

    private func resolve(
        _ result: Result<AudioOutputRouteObservation, Error>
    ) {
        let resolution = lock.withLock { () -> (
            CheckedContinuation<AudioOutputRouteObservation, Error>?,
            [Task<Void, Never>]
        )? in
            guard completedResult == nil else { return nil }
            completedResult = result
            let continuation = self.continuation
            self.continuation = nil
            let tasks = self.tasks
            self.tasks = []
            return (continuation, tasks)
        }
        guard let resolution else { return }
        resolution.1.forEach { $0.cancel() }
        resolution.0?.resume(with: result)
    }

    private func installTasks(_ tasks: [Task<Void, Never>]) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard completedResult == nil else { return true }
            self.tasks = tasks
            return false
        }
        if shouldCancel { tasks.forEach { $0.cancel() } }
    }
}

@MainActor
protocol AudioOutputRouteMonitoring: AnyObject {
    var isMonitoring: Bool { get }
    func start(
        onChange: @escaping @MainActor @Sendable () -> Void
    ) async throws
    func stop() async -> AudioOutputRouteMonitorTeardownReport
}

struct AudioOutputRouteMonitorTeardownReport: Equatable, Sendable {
    let removalStatus: OSStatus?

    static let complete = AudioOutputRouteMonitorTeardownReport(removalStatus: nil)
    var isComplete: Bool { removalStatus == nil }
}

@available(macOS 14.2, *)
struct CoreAudioOutputRouteMonitorOperations: @unchecked Sendable {
    let add: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    let remove: (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus

    static let live = Self(
        add: AudioObjectAddPropertyListenerBlock,
        remove: AudioObjectRemovePropertyListenerBlock
    )
}

@MainActor
@available(macOS 14.2, *)
final class CoreAudioOutputRouteMonitor: AudioOutputRouteMonitoring {
    private let queue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.default-output-route",
        qos: .userInitiated
    )
    private var registration: CoreAudioOutputRouteListenerRegistration?
    private var installationTask: Task<OSStatus, Never>?
    private let operations: CoreAudioOutputRouteMonitorOperations
    private let executor = CoreAudioOutputRouteMonitorExecutor()

    init(operations: CoreAudioOutputRouteMonitorOperations = .live) {
        self.operations = operations
    }

    var isMonitoring: Bool { registration?.isInstalled == true }

    func start(
        onChange: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        if let installationTask {
            try requireNoErr(
                await installationTask.value,
                "Observe the default output device"
            )
            return
        }
        if let registration {
            if !registration.removalFailed, registration.isInstalled { return }
            throw VolEqError.missingValue(
                "The previous output-route listener is still owned by Core Audio. Quit VolEq before trying again."
            )
        }
        let ingress = AudioRouteChangeSignalCoalescer(deliver: onChange)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            ingress.signal()
        }
        let registration = CoreAudioOutputRouteListenerRegistration(
            queue: queue,
            listener: listener,
            addOperation: operations.add,
            removeOperation: operations.remove
        )
        self.registration = registration
        let task = Task { [executor, registration] in
            await executor.install(registration)
        }
        installationTask = task
        let status = await task.value
        installationTask = nil
        guard status == noErr else {
            if self.registration === registration {
                self.registration = nil
            }
            try requireNoErr(status, "Observe the default output device")
            return
        }
    }

    func stop() async -> AudioOutputRouteMonitorTeardownReport {
        if let installationTask { _ = await installationTask.value }
        guard let registration else { return .complete }
        let report = await executor.remove(registration)
        if report.isComplete { self.registration = nil }
        return report
    }

    deinit {
        guard let registration else { return }
        executor.abandon(registration)
    }
}

private final class CoreAudioOutputRouteMonitorExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.route-monitor-owner",
        qos: .userInitiated
    )

    func install(
        _ registration: CoreAudioOutputRouteListenerRegistration
    ) async -> OSStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: registration.install())
            }
        }
    }

    func remove(
        _ registration: CoreAudioOutputRouteListenerRegistration
    ) async -> AudioOutputRouteMonitorTeardownReport {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: registration.remove())
            }
        }
    }

    func abandon(_ registration: CoreAudioOutputRouteListenerRegistration) {
        queue.async {
            guard !registration.remove().isComplete else { return }
            // Core Audio may still call this block. Deliberately retain the
            // small registration until process exit rather than release
            // callback ownership after a refused removal.
            _ = Unmanaged.passRetained(registration)
        }
    }
}

private final class CoreAudioOutputRouteListenerRegistration: @unchecked Sendable {
    private let queue: DispatchQueue
    private let listener: AudioObjectPropertyListenerBlock
    private let addOperation: (
        AudioObjectID,
        UnsafePointer<AudioObjectPropertyAddress>,
        DispatchQueue,
        @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    private let removeOperation: (
        AudioObjectID,
        UnsafePointer<AudioObjectPropertyAddress>,
        DispatchQueue,
        @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    private let lock = NSLock()
    private var installed = false
    private var failedRemoval = false

    init(
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock,
        addOperation: @escaping (
            AudioObjectID,
            UnsafePointer<AudioObjectPropertyAddress>,
            DispatchQueue,
            @escaping AudioObjectPropertyListenerBlock
        ) -> OSStatus,
        removeOperation: @escaping (
            AudioObjectID,
            UnsafePointer<AudioObjectPropertyAddress>,
            DispatchQueue,
            @escaping AudioObjectPropertyListenerBlock
        ) -> OSStatus
    ) {
        self.queue = queue
        self.listener = listener
        self.addOperation = addOperation
        self.removeOperation = removeOperation
    }

    var isInstalled: Bool { lock.withLock { installed } }
    var removalFailed: Bool { lock.withLock { failedRemoval } }

    func install() -> OSStatus {
        guard !isInstalled else { return noErr }
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let status = addOperation(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        guard status == noErr else { return status }
        lock.withLock {
            installed = true
            failedRemoval = false
        }
        return noErr
    }

    func remove() -> AudioOutputRouteMonitorTeardownReport {
        guard isInstalled else { return .complete }
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let status = removeOperation(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        guard status == noErr else {
            lock.withLock { failedRemoval = true }
            return AudioOutputRouteMonitorTeardownReport(removalStatus: status)
        }
        lock.withLock {
            installed = false
            failedRemoval = false
        }
        return .complete
    }
}
