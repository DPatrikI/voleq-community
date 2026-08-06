// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VolEqCommunityMac

final class UpdateControllerTests: XCTestCase {
    @MainActor
    func testNoAutomaticRequestBeforeConsentButManualCheckAlwaysRuns() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let checker = ImmediateUpdateChecker(results: [.success(upToDate())])
        let controller = try makeController(defaults: defaults, checker: checker)

        controller.applicationDidBecomeReady()
        var callCount = await checker.callCount
        XCTAssertEqual(callCount, 0)

        await controller.checkManually()
        callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(controller.lastCompletedStatus, .upToDate)
        XCTAssertNotNil(controller.manualPresentation)
    }

    @MainActor
    func testConsentAppearsOnceOnSecondOrdinaryLaunchAndPersistsEitherChoice() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let checker = ImmediateUpdateChecker(results: [])

        let first = try makeController(defaults: defaults, checker: checker)
        first.applicationDidBecomeReady()
        XCTAssertFalse(first.shouldPresentConsent)

        let second = try makeController(defaults: defaults, checker: checker)
        second.applicationDidBecomeReady()
        XCTAssertTrue(second.shouldPresentConsent)
        second.chooseAutomaticCheckConsent(enabled: false)
        XCTAssertEqual(second.consentDecision, .disabled)

        let third = try makeController(defaults: defaults, checker: checker)
        third.applicationDidBecomeReady()
        XCTAssertFalse(third.shouldPresentConsent)
        XCTAssertEqual(third.consentDecision, .disabled)
        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 0)
    }

    @MainActor
    func testEnabledConsentAndSchedulePersistAcrossRelaunch() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let checker = ImmediateUpdateChecker(results: [.success(upToDate())])
        let first = try makeController(defaults: defaults, checker: checker)

        first.chooseAutomaticCheckConsent(enabled: true)
        await waitUntil { await checker.callCount >= 1 }
        await waitUntil { !first.isChecking }

        let relaunchedScheduler = TestUpdateScheduler()
        let relaunched = try makeController(
            defaults: defaults,
            checker: checker,
            scheduler: relaunchedScheduler
        )
        relaunched.applicationDidBecomeReady()

        XCTAssertEqual(relaunched.consentDecision, .enabled)
        XCTAssertTrue(relaunched.automaticallyChecksForUpdates)
        XCTAssertFalse(relaunched.shouldPresentConsent)
        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(
            relaunchedScheduler.scheduledInterval ?? -1,
            UpdateController.automaticInterval,
            accuracy: 0.001
        )
    }

    @MainActor
    func testEnablingPerformsImmediateCheckAndDisablingCancelsAutomaticWork() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set(
            Date(timeIntervalSince1970: 1_000_000 - 60),
            forKey: UpdateController.PreferenceKey.lastAutomaticAttempt
        )
        let checker = DeferredUpdateChecker()
        let scheduler = TestUpdateScheduler()
        let controller = try makeController(
            defaults: defaults,
            checker: checker,
            scheduler: scheduler
        )

        controller.setAutomaticallyChecksForUpdates(true)
        await waitForCalls(checker, count: 1)
        XCTAssertTrue(controller.isChecking)
        XCTAssertEqual(controller.consentDecision, .enabled)
        XCTAssertTrue(controller.automaticallyChecksForUpdates)
        XCTAssertEqual(
            defaults.object(forKey: UpdateController.PreferenceKey.lastAutomaticAttempt) as? Date,
            Date(timeIntervalSince1970: 1_000_000)
        )

        controller.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(controller.isChecking)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1)

        await checker.resume(with: .success(try updateAvailable("0.2.0")))
        await drainTasks()
        XCTAssertNil(controller.knownAvailableUpdate)
        XCTAssertEqual(controller.lastCompletedStatus, .never)
    }

    @MainActor
    func testEnableCheckResetsNextAutomaticDueDateToTwentyFourHours() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        defaults.set(
            now.addingTimeInterval(-UpdateController.automaticInterval + 60),
            forKey: UpdateController.PreferenceKey.lastAutomaticAttempt
        )
        let clock = TestUpdateClock(now: now)
        let scheduler = TestUpdateScheduler()
        let checker = ImmediateUpdateChecker(results: [.success(upToDate())])
        let controller = try makeController(
            defaults: defaults,
            checker: checker,
            clock: clock,
            scheduler: scheduler
        )

        controller.setAutomaticallyChecksForUpdates(true)
        await waitUntil { await checker.callCount >= 1 }
        await waitUntil { !controller.isChecking }

        XCTAssertEqual(
            defaults.object(forKey: UpdateController.PreferenceKey.lastAutomaticAttempt) as? Date,
            now
        )
        XCTAssertEqual(
            scheduler.scheduledInterval ?? -1,
            UpdateController.automaticInterval,
            accuracy: 0.001
        )
    }

    @MainActor
    func testImmediateDisableCancelsQueuedEnableBeforeItStarts() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let checker = ImmediateUpdateChecker(results: [.success(upToDate())])
        let controller = try makeController(defaults: defaults, checker: checker)

        controller.setAutomaticallyChecksForUpdates(true)
        controller.setAutomaticallyChecksForUpdates(false)
        await drainTasks()

        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(
            defaults.object(forKey: UpdateController.PreferenceKey.lastAutomaticAttempt)
        )
        XCTAssertFalse(controller.isChecking)
    }

    @MainActor
    func testAutomaticChecksUseRollingTwentyFourHourGateAcrossActivationAndTimer() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let start = Date(timeIntervalSince1970: 10_000)
        defaults.set(UpdateConsentDecision.enabled.rawValue, forKey: UpdateController.PreferenceKey.consentDecision)
        defaults.set(true, forKey: UpdateController.PreferenceKey.automaticallyChecks)
        defaults.set(start, forKey: UpdateController.PreferenceKey.lastAutomaticAttempt)
        let clock = TestUpdateClock(now: start.addingTimeInterval(60))
        let scheduler = TestUpdateScheduler()
        let checker = ImmediateUpdateChecker(results: [.success(upToDate())])
        let controller = try makeController(
            defaults: defaults,
            checker: checker,
            clock: clock,
            scheduler: scheduler
        )

        controller.applicationDidBecomeReady()
        var callCount = await checker.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(
            scheduler.scheduledInterval ?? -1,
            UpdateController.automaticInterval - 60,
            accuracy: 0.001
        )

        controller.applicationActivatedOrWoke()
        callCount = await checker.callCount
        XCTAssertEqual(callCount, 0)

        clock.now = start.addingTimeInterval(UpdateController.automaticInterval + 1)
        scheduler.fire()
        await waitUntil { await checker.callCount >= 1 }
        await waitUntil { !controller.isChecking }

        XCTAssertEqual(
            defaults.object(forKey: UpdateController.PreferenceKey.lastAutomaticAttempt) as? Date,
            clock.now
        )
        callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertNotNil(scheduler.scheduledInterval)
    }

    @MainActor
    func testOverdueCheckRunsAfterRelaunchAndWakeButNotTwice() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let start = Date(timeIntervalSince1970: 20_000)
        defaults.set(UpdateConsentDecision.enabled.rawValue, forKey: UpdateController.PreferenceKey.consentDecision)
        defaults.set(true, forKey: UpdateController.PreferenceKey.automaticallyChecks)
        defaults.set(
            start.addingTimeInterval(-UpdateController.automaticInterval - 1),
            forKey: UpdateController.PreferenceKey.lastAutomaticAttempt
        )
        let clock = TestUpdateClock(now: start)
        let checker = DeferredUpdateChecker()
        let controller = try makeController(
            defaults: defaults,
            checker: checker,
            clock: clock
        )

        controller.applicationDidBecomeReady()
        controller.applicationActivatedOrWoke()
        await waitForCalls(checker, count: 1)
        var callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)

        await checker.resume(with: .success(upToDate()))
        await waitUntil { !controller.isChecking }
        controller.applicationActivatedOrWoke()
        await drainTasks()
        callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testManualChecksBypassDailyLimitWithoutMovingAutomaticAttempt() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let attempt = Date(timeIntervalSince1970: 30_000)
        defaults.set(UpdateConsentDecision.enabled.rawValue, forKey: UpdateController.PreferenceKey.consentDecision)
        defaults.set(true, forKey: UpdateController.PreferenceKey.automaticallyChecks)
        defaults.set(attempt, forKey: UpdateController.PreferenceKey.lastAutomaticAttempt)
        let checker = ImmediateUpdateChecker(results: [.success(upToDate())])
        let controller = try makeController(
            defaults: defaults,
            checker: checker,
            clock: TestUpdateClock(now: attempt.addingTimeInterval(60))
        )

        await controller.checkManually()

        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(
            defaults.object(forKey: UpdateController.PreferenceKey.lastAutomaticAttempt) as? Date,
            attempt
        )
        XCTAssertNotNil(controller.manualPresentation)
    }

    @MainActor
    func testConcurrentManualRequestsAreDeduplicated() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let checker = DeferredUpdateChecker()
        let controller = try makeController(defaults: defaults, checker: checker)

        let first = Task { @MainActor in await controller.checkManually() }
        await waitForCalls(checker, count: 1)
        let second = Task { @MainActor in await controller.checkManually() }
        await drainTasks()
        var callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)

        await checker.resume(with: .success(try updateAvailable("0.2.0")))
        await first.value
        await second.value

        callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(controller.knownAvailableUpdate?.version.description, "0.2.0")
        guard case .updateAvailable? = controller.manualPresentation?.kind else {
            return XCTFail("Expected one manual update presentation")
        }
    }

    @MainActor
    func testCachedIndicatorRestoresAndResetsWhenInstalledVersionCatchesUp() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set("0.2.0", forKey: UpdateController.PreferenceKey.knownAvailableVersion)
        defaults.set(
            LastUpdateCheckStatus.updateAvailable.rawValue,
            forKey: UpdateController.PreferenceKey.lastCompletedStatus
        )
        let checker = ImmediateUpdateChecker(results: [])

        let oldInstall = try makeController(
            installedVersion: "0.1.0",
            defaults: defaults,
            checker: checker
        )
        XCTAssertEqual(oldInstall.knownAvailableUpdate?.version.description, "0.2.0")

        let caughtUp = try makeController(
            installedVersion: "0.2.0",
            defaults: defaults,
            checker: checker
        )
        XCTAssertNil(caughtUp.knownAvailableUpdate)
        XCTAssertNil(
            defaults.string(forKey: UpdateController.PreferenceKey.knownAvailableVersion)
        )
        XCTAssertEqual(caughtUp.lastCompletedStatus, .never)
        XCTAssertEqual(
            caughtUp.lastCheckSummary,
            "This installation has not been checked for updates yet."
        )
    }

    @MainActor
    func testRestoredUpToDateStatusDoesNotClaimNewInstalledVersionWasChecked() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set(
            LastUpdateCheckStatus.upToDate.rawValue,
            forKey: UpdateController.PreferenceKey.lastCompletedStatus
        )

        let upgraded = try makeController(
            installedVersion: "0.2.0",
            defaults: defaults,
            checker: ImmediateUpdateChecker(results: [])
        )

        XCTAssertEqual(upgraded.lastCompletedStatus, .upToDate)
        XCTAssertEqual(
            upgraded.lastCheckSummary,
            "Last check found no newer published VolEq release."
        )
        XCTAssertFalse(upgraded.lastCheckSummary.contains("0.2.0"))
    }

    @MainActor
    func testMalformedCachedVersionDoesNotCreateUpToDateConclusion() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set("not-a-version", forKey: UpdateController.PreferenceKey.knownAvailableVersion)
        defaults.set(
            LastUpdateCheckStatus.updateAvailable.rawValue,
            forKey: UpdateController.PreferenceKey.lastCompletedStatus
        )

        let controller = try makeController(
            defaults: defaults,
            checker: ImmediateUpdateChecker(results: [])
        )

        XCTAssertNil(controller.knownAvailableUpdate)
        XCTAssertEqual(controller.lastCompletedStatus, .failed)
        XCTAssertTrue(controller.lastCheckSummary.contains("No conclusion"))
    }

    @MainActor
    func testManualFeedbackCoversAvailableUpToDateAndFailureWhileAutomaticFailureIsSilent() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let checker = ImmediateUpdateChecker(results: [
            .success(upToDate()),
            .failure(.offline),
            .success(try updateAvailable("0.2.0")),
            .failure(.timedOut),
        ])
        let controller = try makeController(defaults: defaults, checker: checker)

        await controller.checkManually()
        guard case .upToDate? = controller.manualPresentation?.kind else {
            return XCTFail("Expected up-to-date presentation")
        }
        controller.dismissManualPresentation()

        await controller.checkManually()
        guard case let .failure(message)? = controller.manualPresentation?.kind else {
            return XCTFail("Expected failure presentation")
        }
        XCTAssertTrue(message.contains("internet connection"))
        controller.dismissManualPresentation()

        await controller.checkManually()
        guard case .updateAvailable? = controller.manualPresentation?.kind else {
            return XCTFail("Expected available presentation")
        }
        controller.dismissManualPresentation()

        controller.setAutomaticallyChecksForUpdates(true)
        await waitUntil { await checker.callCount >= 4 }
        await waitUntil { !controller.isChecking }
        XCTAssertNil(controller.manualPresentation)
        XCTAssertEqual(controller.lastCompletedStatus, .failed)
        XCTAssertTrue(controller.lastCheckSummary.contains("No conclusion"))
    }

    @MainActor
    func testKnownIndicatorSurvivesOlderResponseAndNewerReleaseSupersedesIt() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let checker = ImmediateUpdateChecker(results: [
            .success(try updateAvailable("0.2.0")),
            .success(upToDate()),
            .success(try updateAvailable("0.3.0")),
            .success(try updateAvailable("0.2.0")),
        ])
        let controller = try makeController(defaults: defaults, checker: checker)

        await controller.checkManually()
        XCTAssertEqual(controller.knownAvailableUpdate?.version.description, "0.2.0")
        controller.dismissManualPresentation()

        await controller.checkManually()
        XCTAssertEqual(controller.knownAvailableUpdate?.version.description, "0.2.0")
        guard case .updateAvailable? = controller.manualPresentation?.kind else {
            return XCTFail("Expected the cached update to remain visible")
        }
        controller.dismissManualPresentation()

        await controller.checkManually()
        XCTAssertEqual(controller.knownAvailableUpdate?.version.description, "0.3.0")
        controller.dismissManualPresentation()

        await controller.checkManually()
        XCTAssertEqual(controller.knownAvailableUpdate?.version.description, "0.3.0")
    }

    @MainActor
    func testReleaseOpeningRevalidatesURLBeforeUsingWorkspace() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let opener = TestUpdateWorkspaceOpener()
        let controller = try makeController(
            defaults: defaults,
            checker: ImmediateUpdateChecker(results: []),
            opener: opener
        )
        let version = try ApplicationVersion(installedVersionString: "0.2.0")
        let valid = KnownAvailableUpdate(
            version: version,
            releaseURL: ValidatedGitHubReleaseURL.canonical(for: version).url
        )
        let invalid = KnownAvailableUpdate(
            version: version,
            releaseURL: URL(string: "https://example.com/update")!
        )

        XCTAssertFalse(controller.openRelease(invalid))
        XCTAssertTrue(opener.openedURLs.isEmpty)
        XCTAssertNotNil(controller.releaseOpenFailure)
        controller.dismissReleaseOpenFailure()
        XCTAssertTrue(controller.openRelease(valid))
        XCTAssertEqual(opener.openedURLs, [valid.releaseURL])

        let failingOpener = TestUpdateWorkspaceOpener(result: false)
        let failingController = try makeController(
            defaults: defaults,
            checker: ImmediateUpdateChecker(results: []),
            opener: failingOpener
        )
        XCTAssertFalse(failingController.openRelease(valid))
        XCTAssertTrue(
            failingController.releaseOpenFailure?.message.contains("macOS") == true
        )
    }

    @MainActor
    private func makeController(
        installedVersion: String = "0.1.0",
        defaults: UserDefaults,
        checker: any UpdateChecking,
        clock: TestUpdateClock? = nil,
        scheduler: TestUpdateScheduler? = nil,
        opener: TestUpdateWorkspaceOpener? = nil
    ) throws -> UpdateController {
        UpdateController(
            installedVersion: try ApplicationVersion(
                installedVersionString: installedVersion
            ),
            checker: checker,
            defaults: defaults,
            clock: clock ?? TestUpdateClock(
                now: Date(timeIntervalSince1970: 1_000_000)
            ),
            scheduler: scheduler ?? TestUpdateScheduler(),
            workspaceOpener: opener ?? TestUpdateWorkspaceOpener()
        )
    }

    private func upToDate() -> UpdateCheckResult {
        .upToDate(
            latestVersion: try! ApplicationVersion(
                installedVersionString: "0.1.0"
            )
        )
    }

    private func updateAvailable(_ version: String) throws -> UpdateCheckResult {
        let version = try ApplicationVersion(installedVersionString: version)
        return .updateAvailable(
            AvailableRelease(
                version: version,
                validatedReleaseURL: .canonical(for: version),
                publicationDate: Date(timeIntervalSince1970: 1_000)
            )
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UpdateControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(suiteName, forKey: "UpdateControllerTests.suiteName")
        return defaults
    }

    private func clear(_ defaults: UserDefaults) {
        if let suiteName = defaults.string(
            forKey: "UpdateControllerTests.suiteName"
        ) {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @MainActor
    private func waitForCalls(
        _ checker: DeferredUpdateChecker,
        count: Int
    ) async {
        await waitUntil { await checker.callCount >= count }
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0 ..< 1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous update state")
    }

    private func drainTasks() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }
}

private actor ImmediateUpdateChecker: UpdateChecking {
    private var results: [Result<UpdateCheckResult, UpdateCheckError>]
    private(set) var callCount = 0

    init(results: [Result<UpdateCheckResult, UpdateCheckError>]) {
        self.results = results
    }

    func check(for installedVersion: ApplicationVersion) async throws -> UpdateCheckResult {
        callCount += 1
        guard !results.isEmpty else {
            throw UpdateCheckError.invalidResponse
        }
        return try results.removeFirst().get()
    }
}

private actor DeferredUpdateChecker: UpdateChecking {
    private var continuations: [CheckedContinuation<UpdateCheckResult, Error>] = []
    private(set) var callCount = 0

    func check(for installedVersion: ApplicationVersion) async throws -> UpdateCheckResult {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(with result: Result<UpdateCheckResult, UpdateCheckError>) {
        guard !continuations.isEmpty else { return }
        let continuation = continuations.removeFirst()
        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
private final class TestUpdateClock: UpdateClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

@MainActor
private final class TestUpdateScheduler: UpdateScheduling {
    private(set) var scheduledInterval: TimeInterval?
    private(set) var tolerance: TimeInterval?
    private(set) var cancelCount = 0
    private var action: (@MainActor @Sendable () -> Void)?

    func schedule(
        after interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        scheduledInterval = interval
        self.tolerance = tolerance
        self.action = action
    }

    func cancel() {
        cancelCount += 1
        scheduledInterval = nil
        tolerance = nil
        action = nil
    }

    func fire() {
        let action = action
        self.action = nil
        scheduledInterval = nil
        action?()
    }
}

@MainActor
private final class TestUpdateWorkspaceOpener: UpdateWorkspaceOpening {
    private(set) var openedURLs: [URL] = []
    private let result: Bool

    init(result: Bool = true) {
        self.result = result
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return result
    }
}
