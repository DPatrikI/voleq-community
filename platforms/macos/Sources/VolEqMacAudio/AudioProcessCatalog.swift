// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreAudio
import Foundation

protocol AudioProcessCatalog: Sendable {
    func activeOutputProcesses() async throws -> [AudioProcess]
}

struct CoreAudioProcessCatalogOperations: @unchecked Sendable {
    let processIDs: () throws -> [AudioObjectID]
    let pid: (AudioObjectID) throws -> pid_t
    let isProducingOutput: (AudioObjectID) throws -> UInt32
    let bundleID: (AudioObjectID) throws -> String
    let displayName: @MainActor (pid_t, String) -> String

    static let live = Self(
        processIDs: {
            try readArray(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList
            )
        },
        pid: {
            try readValue(objectID: $0, selector: kAudioProcessPropertyPID)
        },
        isProducingOutput: {
            try readValue(
                objectID: $0,
                selector: kAudioProcessPropertyIsRunningOutput
            )
        },
        bundleID: {
            try readString(objectID: $0, selector: kAudioProcessPropertyBundleID)
        },
        displayName: { pid, bundleID in
            NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? bundleID.split(separator: ".").last.map(String.init)
                ?? "Process \(pid)"
        }
    )
}

private struct DiscoveredAudioProcess: Sendable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
}

private final class CoreAudioProcessCatalogRequestLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCurrent: Bool { lock.withLock { !cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private final class CoreAudioProcessCatalogExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.process-catalog",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var operationInFlight = false

    func discover(
        operations: CoreAudioProcessCatalogOperations,
        lease: CoreAudioProcessCatalogRequestLease
    ) async throws -> [DiscoveredAudioProcess] {
        guard claimOperation() else {
            throw VolEqError.missingValue(
                "A previous application discovery is still finishing. Wait for it to stop, then try again."
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    defer { self.releaseOperation() }
                    guard lease.isCurrent else { throw CancellationError() }
                    let ids = try operations.processIDs()
                    guard lease.isCurrent else { throw CancellationError() }
                    let ownPID = getpid()
                    return ids.compactMap { id in
                        guard let pid = try? operations.pid(id), pid != ownPID,
                              ((try? operations.isProducingOutput(id)) ?? 0) != 0,
                              let bundleID = try? operations.bundleID(id),
                              !bundleID.isEmpty
                        else { return nil }
                        return DiscoveredAudioProcess(
                            id: id,
                            pid: pid,
                            bundleID: bundleID
                        )
                    }
                })
            }
        }
    }

    private func claimOperation() -> Bool {
        stateLock.withLock {
            guard !operationInFlight else { return false }
            operationInFlight = true
            return true
        }
    }

    private func releaseOperation() {
        stateLock.withLock { operationInFlight = false }
    }
}

struct CoreAudioProcessCatalog: AudioProcessCatalog {
    let operations: CoreAudioProcessCatalogOperations
    private let executor = CoreAudioProcessCatalogExecutor()

    init(operations: CoreAudioProcessCatalogOperations = .live) {
        self.operations = operations
    }

    func activeOutputProcesses() async throws -> [AudioProcess] {
        let lease = CoreAudioProcessCatalogRequestLease()
        let discovered = try await withTaskCancellationHandler {
            try await executor.discover(
                operations: operations,
                lease: lease
            )
        } onCancel: {
            lease.cancel()
        }
        try Task.checkCancellation()
        return await MainActor.run {
            discovered.map { process in
                AudioProcess(
                    id: process.id,
                    pid: process.pid,
                    name: operations.displayName(process.pid, process.bundleID),
                    bundleID: process.bundleID
                )
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
        }
    }
}
