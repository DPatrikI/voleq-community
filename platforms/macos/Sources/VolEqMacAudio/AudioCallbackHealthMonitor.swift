// SPDX-License-Identifier: MPL-2.0

import CVolEqRealtime
import Foundation

final class AudioCallbackHeartbeat: @unchecked Sendable {
    private let state: OpaquePointer

    init() throws {
        guard let state = voleq_realtime_heartbeat_create() else {
            throw VolEqError.missingValue(
                "VolEq could not allocate its audio callback heartbeat."
            )
        }
        self.state = state
    }

    deinit {
        voleq_realtime_heartbeat_destroy(state)
    }

    @inline(__always)
    func recordCallback() {
        voleq_realtime_heartbeat_record_callback(state)
    }

    var callbackCount: UInt64 {
        voleq_realtime_heartbeat_callback_count(state)
    }
}

protocol AudioCallbackHealthMonitoring: AnyObject {
    @MainActor func waitForInitialProgress(
        heartbeat: AudioCallbackHeartbeat,
        initialCount: UInt64,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool
    @MainActor func startWatchdog(
        heartbeat: AudioCallbackHeartbeat,
        isCurrent: @escaping @MainActor () -> Bool,
        onStall: @escaping @MainActor () -> Void
    )
    @MainActor func stop()
}

@MainActor
final class AudioCallbackHealthMonitor: AudioCallbackHealthMonitoring {
    private let clock: any AudioLifecycleClock
    private let scheduler: any AudioLifecycleScheduling
    private let pollNanoseconds: UInt64
    private let startupTimeoutNanoseconds: UInt64
    private let stallNanoseconds: UInt64
    private var watchdogTask: Task<Void, Never>?

    init(
        clock: any AudioLifecycleClock,
        scheduler: any AudioLifecycleScheduling,
        pollNanoseconds: UInt64 = 250_000_000,
        startupTimeoutNanoseconds: UInt64 = 2_000_000_000,
        stallNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.pollNanoseconds = pollNanoseconds
        self.startupTimeoutNanoseconds = startupTimeoutNanoseconds
        self.stallNanoseconds = stallNanoseconds
    }

    func waitForInitialProgress(
        heartbeat: AudioCallbackHeartbeat,
        initialCount: UInt64,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let startedAt = clock.nowNanoseconds()
        while isCurrent(), !Task.isCancelled {
            if heartbeat.callbackCount != initialCount { return true }
            let now = clock.nowNanoseconds()
            if now >= startedAt,
               now - startedAt >= startupTimeoutNanoseconds {
                return false
            }
            do {
                try await scheduler.sleep(nanoseconds: pollNanoseconds)
            } catch {
                return false
            }
        }
        return false
    }

    func startWatchdog(
        heartbeat: AudioCallbackHeartbeat,
        isCurrent: @escaping @MainActor () -> Bool,
        onStall: @escaping @MainActor () -> Void
    ) {
        stop()
        let initialCount = heartbeat.callbackCount
        let initialTime = clock.nowNanoseconds()
        watchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastCount = initialCount
            var lastProgressTime = initialTime

            while isCurrent(), !Task.isCancelled {
                do {
                    try await scheduler.sleep(nanoseconds: pollNanoseconds)
                } catch {
                    return
                }
                guard isCurrent(), !Task.isCancelled else { return }
                let count = heartbeat.callbackCount
                let now = clock.nowNanoseconds()
                if count != lastCount {
                    lastCount = count
                    lastProgressTime = now
                    continue
                }
                if now >= lastProgressTime,
                   now - lastProgressTime >= stallNanoseconds {
                    watchdogTask = nil
                    onStall()
                    return
                }
            }
        }
    }

    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }
}
