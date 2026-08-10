// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import XCTest
@testable import VolEqMacAudio

private enum ProcessCatalogTestError: Error { case unavailable }

private final class ControlledProcessCatalog: AudioProcessCatalog, @unchecked Sendable {
    private let lock = NSLock()
    private var nextRequest = 0
    private var continuations: [
        Int: CheckedContinuation<[AudioProcess], Error>
    ] = [:]

    var requestCount: Int { lock.withLock { nextRequest } }

    func activeOutputProcesses() async throws -> [AudioProcess] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                nextRequest += 1
                continuations[nextRequest] = continuation
            }
        }
    }

    func complete(
        request: Int,
        with result: Result<[AudioProcess], Error>
    ) {
        let continuation = lock.withLock {
            continuations.removeValue(forKey: request)
        }
        continuation?.resume(with: result)
    }
}

private final class BlockingCoreAudioProcessList: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var storedRequestCount = 0
    private var entered = false

    var requestCount: Int { lock.withLock { storedRequestCount } }
    var hasEntered: Bool { lock.withLock { entered } }

    func read() -> [AudioObjectID] {
        let request = lock.withLock { () -> Int in
            storedRequestCount += 1
            if storedRequestCount == 1 { entered = true }
            return storedRequestCount
        }
        if request == 1 { releaseSemaphore.wait() }
        return [10]
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class AudioTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }
    func increment() { lock.withLock { storedValue += 1 } }
}

@MainActor
final class AudioProcessCatalogTests: XCTestCase {
    func testVanishedEntryIsSkippedWhileValidProcessesRemain() async throws {
        let catalog = CoreAudioProcessCatalog(operations: .init(
            processIDs: { [10, 11] },
            pid: { id in
                if id == 10 { throw ProcessCatalogTestError.unavailable }
                return 111
            },
            isProducingOutput: { _ in 1 },
            bundleID: { _ in "com.example.valid" },
            displayName: { _, _ in "Valid" }
        ))

        let processes = try await catalog.activeOutputProcesses()
        XCTAssertEqual(processes, [AudioProcess(
            id: 11,
            pid: 111,
            name: "Valid",
            bundleID: "com.example.valid"
        )])
    }

    func testUnreadableOrEmptyBundleIdentityIsSkipped() async throws {
        let catalog = CoreAudioProcessCatalog(operations: .init(
            processIDs: { [10, 11, 12] },
            pid: { id in pid_t(id + 100) },
            isProducingOutput: { _ in 1 },
            bundleID: { id in
                if id == 10 { throw ProcessCatalogTestError.unavailable }
                return id == 11 ? "" : "com.example.valid"
            },
            displayName: { _, _ in "Valid" }
        ))

        let processes = try await catalog.activeOutputProcesses()
        XCTAssertEqual(processes, [
            AudioProcess(
                id: 12,
                pid: 112,
                name: "Valid",
                bundleID: "com.example.valid"
            )
        ])
    }

    func testTopLevelProcessListFailureIsNotHiddenAsChurn() async {
        let catalog = CoreAudioProcessCatalog(operations: .init(
            processIDs: { throw ProcessCatalogTestError.unavailable },
            pid: { _ in 1 },
            isProducingOutput: { _ in 1 },
            bundleID: { _ in "com.example" },
            displayName: { _, _ in "Example" }
        ))

        do {
            _ = try await catalog.activeOutputProcesses()
            XCTFail("Expected top-level discovery failure")
        } catch {
            XCTAssertTrue(error is ProcessCatalogTestError)
        }
    }

    func testBlockedProcessEnumerationDoesNotBlockMainActor() async throws {
        let release = DispatchSemaphore(value: 0)
        let entered = AudioTestFlag()
        let catalog = CoreAudioProcessCatalog(operations: .init(
            processIDs: {
                entered.set()
                release.wait()
                return []
            },
            pid: { _ in 1 },
            isProducingOutput: { _ in 1 },
            bundleID: { _ in "com.example" },
            displayName: { _, _ in "Example" }
        ))

        let discovery = Task { try await catalog.activeOutputProcesses() }
        try await waitForAudioCondition("background process enumeration") {
            entered.value
        }
        let mainActorProgressed = await MainActor.run { true }
        XCTAssertTrue(mainActorProgressed)

        release.signal()
        let processes = try await discovery.value
        XCTAssertEqual(processes, [])
    }

    func testCancelledDiscoveriesCannotQueueBehindBlockedHALEnumeration() async throws {
        let processList = BlockingCoreAudioProcessList()
        let catalog = CoreAudioProcessCatalog(operations: .init(
            processIDs: { processList.read() },
            pid: { _ in 100 },
            isProducingOutput: { _ in 1 },
            bundleID: { _ in "com.example.call" },
            displayName: { _, _ in "Call" }
        ))
        let first = Task { try await catalog.activeOutputProcesses() }
        defer { processList.release() }
        try await waitForAudioCondition("blocked catalog request") {
            processList.hasEntered
        }
        first.cancel()

        let rejected = AudioTestCounter()
        let followers = (0..<100).map { _ in
            Task {
                do {
                    _ = try await catalog.activeOutputProcesses()
                } catch {
                    rejected.increment()
                }
            }
        }
        try await waitForAudioCondition("bounded catalog rejections") {
            rejected.value == followers.count
        }

        XCTAssertEqual(processList.requestCount, 1)
        processList.release()
        _ = try? await first.value
        for follower in followers { await follower.value }
    }

    func testStaleCatalogFailureIsCancelledBeforeItCanReplaceNewerResults() async throws {
        let catalog = ControlledProcessCatalog()
        let session = AudioCaptureProcessSession(catalog: catalog)
        var currentRequest = 1
        let first = Task {
            try await session.refresh(
                currentSelection: nil,
                mode: .application,
                preservingRecoveryFailure: false,
                isCurrent: { currentRequest == 1 }
            )
        }
        try await waitForAudioCondition("first process request") {
            catalog.requestCount == 1
        }

        currentRequest = 2
        let second = Task {
            try await session.refresh(
                currentSelection: nil,
                mode: .application,
                preservingRecoveryFailure: false,
                isCurrent: { currentRequest == 2 }
            )
        }
        try await waitForAudioCondition("second process request") {
            catalog.requestCount == 2
        }
        catalog.complete(request: 2, with: .success([]))
        try await second.value

        catalog.complete(
            request: 1,
            with: .failure(ProcessCatalogTestError.unavailable)
        )
        do {
            try await first.value
            XCTFail("Expected stale process failure to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(session.processes.isEmpty)
    }

    @available(macOS 14.2, *)
    func testRefreshStormKeepsCatalogWorkBoundedBeforeApplicationStart() async throws {
        let processList = BlockingCoreAudioProcessList()
        let catalog = CoreAudioProcessCatalog(operations: .init(
            processIDs: { processList.read() },
            pid: { _ in 100 },
            isProducingOutput: { _ in 1 },
            bundleID: { _ in "com.example.call" },
            displayName: { _, _ in "Call" }
        ))
        let rig = AudioCaptureTestRig()
        let base = rig.makeDependencies()
        let coordinator = AudioCaptureLifecycleCoordinator(dependencies: .init(
            processCatalog: catalog,
            preflight: base.preflight,
            pipelineBuilder: base.pipelineBuilder,
            routeMonitor: base.routeMonitor,
            routeStabilityGate: base.routeStabilityGate,
            callbackHealthMonitorBuilder: base.callbackHealthMonitorBuilder,
            permissionExplanationRequest: base.permissionExplanationRequest,
            routeRecoveryDelayNanoseconds: base.routeRecoveryDelayNanoseconds,
            wakeRecoveryDelayNanoseconds: base.wakeRecoveryDelayNanoseconds
        ))
        let observer = TestLifecycleObserver()
        coordinator.observer = observer
        coordinator.publishCurrentState()
        try await waitForAudioCondition("blocked initial catalog read") {
            processList.hasEntered
        }

        for _ in 0..<100 {
            coordinator.refreshProcesses(
                currentSelection: nil,
                mode: .application
            )
        }
        XCTAssertEqual(processList.requestCount, 1)

        coordinator.start(intent: CaptureIntent(
            mode: .application,
            speechAwarenessEnabled: false,
            levelingSettings: .init(),
            application: .init(
                processObjectID: 10,
                pid: 100,
                bundleID: "com.example.call",
                displayName: "Call"
            )
        ))
        processList.release()
        try await waitForAudioCondition("application start after refresh storm") {
            observer.snapshots.last?.runtimeState == .active
        }
        for _ in 0..<20 { await Task.yield() }

        // One blocked refresh plus at most one coalesced refresh may precede
        // the bounded identity checks performed by application startup.
        XCTAssertLessThanOrEqual(processList.requestCount, 6)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }
}
