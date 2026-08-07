// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

enum UpdateConsentDecision: String, Equatable, Sendable {
    case undecided
    case enabled
    case disabled
}

enum LastUpdateCheckStatus: String, Equatable, Sendable {
    case never
    case upToDate
    case updateAvailable
    case failed
}

struct KnownAvailableUpdate: Equatable, Sendable {
    let version: ApplicationVersion
    let releaseURL: URL
}

struct ManualUpdatePresentation: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case updateAvailable(KnownAvailableUpdate)
        case upToDate(installedVersion: ApplicationVersion)
        case failure(message: String)
    }

    let id = UUID()
    let kind: Kind
}

struct ReleaseOpenFailurePresentation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
}

@MainActor
protocol UpdateClock: AnyObject {
    var now: Date { get }
}

@MainActor
final class SystemUpdateClock: UpdateClock {
    var now: Date { Date() }
}

@MainActor
protocol UpdateScheduling: AnyObject {
    func schedule(
        after interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    )
    func cancel()
}

@MainActor
final class FoundationUpdateScheduler: UpdateScheduling {
    private var timer: Timer?

    func schedule(
        after interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel()
        let timer = Timer(timeInterval: max(0, interval), repeats: false) { _ in
            Task { @MainActor in action() }
        }
        timer.tolerance = min(max(0, tolerance), max(0, interval))
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
protocol UpdateWorkspaceOpening: AnyObject {
    @discardableResult
    func open(_ url: URL) -> Bool
}

@MainActor
final class SystemUpdateWorkspaceOpener: UpdateWorkspaceOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class UpdateController: ObservableObject {
    static let automaticInterval: TimeInterval = 24 * 60 * 60
    static let timerTolerance: TimeInterval = 5 * 60

    enum PreferenceKey {
        static let consentDecision = "updateChecksConsentDecision"
        static let automaticallyChecks = "automaticallyChecksForUpdates"
        static let ordinaryLaunchCount = "ordinaryApplicationLaunchCount"
        static let lastAutomaticAttempt = "lastAutomaticUpdateAttempt"
        static let lastCompletedStatus = "lastCompletedUpdateCheckStatus"
        static let knownAvailableVersion = "lastKnownAvailableVersion"
    }

    @Published private(set) var consentDecision: UpdateConsentDecision
    @Published private(set) var automaticallyChecksForUpdates: Bool
    @Published private(set) var shouldPresentConsent = false
    @Published private(set) var isChecking = false
    @Published private(set) var lastCompletedStatus: LastUpdateCheckStatus
    @Published private(set) var knownAvailableUpdate: KnownAvailableUpdate?
    @Published private(set) var manualPresentation: ManualUpdatePresentation?
    @Published private(set) var releaseOpenFailure: ReleaseOpenFailurePresentation?

    let installedVersion: ApplicationVersion

    private enum Trigger: Equatable {
        case manual
        case automatic
        case enable
    }

    private struct ActiveRequest {
        let id: UUID
        let trigger: Trigger
        let task: Task<UpdateCheckResult, Error>
    }

    private let checker: any UpdateChecking
    private let defaults: UserDefaults
    private let clock: any UpdateClock
    private let scheduler: any UpdateScheduling
    private let workspaceOpener: any UpdateWorkspaceOpening
    private var activeRequest: ActiveRequest?
    private var manualFeedbackRequested = false

    init(
        installedVersion: ApplicationVersion,
        checker: any UpdateChecking,
        defaults: UserDefaults,
        clock: any UpdateClock,
        scheduler: any UpdateScheduling,
        workspaceOpener: any UpdateWorkspaceOpening
    ) {
        self.installedVersion = installedVersion
        self.checker = checker
        self.defaults = defaults
        self.clock = clock
        self.scheduler = scheduler
        self.workspaceOpener = workspaceOpener

        consentDecision = defaults.string(forKey: PreferenceKey.consentDecision)
            .flatMap(UpdateConsentDecision.init(rawValue:))
            ?? .undecided
        automaticallyChecksForUpdates = defaults.bool(
            forKey: PreferenceKey.automaticallyChecks
        )
        lastCompletedStatus = defaults.string(forKey: PreferenceKey.lastCompletedStatus)
            .flatMap(LastUpdateCheckStatus.init(rawValue:))
            ?? .never

        if consentDecision != .enabled {
            automaticallyChecksForUpdates = false
        }

        if let persistedVersion = defaults.string(
            forKey: PreferenceKey.knownAvailableVersion
        ) {
            if let version = try? ApplicationVersion(
                installedVersionString: persistedVersion
            ) {
                if version > installedVersion {
                    knownAvailableUpdate = KnownAvailableUpdate(
                        version: version,
                        releaseURL: ValidatedGitHubReleaseURL.canonical(for: version).url
                    )
                } else {
                    knownAvailableUpdate = nil
                    defaults.removeObject(forKey: PreferenceKey.knownAvailableVersion)
                    if lastCompletedStatus == .updateAvailable {
                        persistCompletedStatus(.never)
                    }
                }
            } else {
                knownAvailableUpdate = nil
                defaults.removeObject(forKey: PreferenceKey.knownAvailableVersion)
                if lastCompletedStatus == .updateAvailable {
                    persistCompletedStatus(.failed)
                }
            }
        } else {
            knownAvailableUpdate = nil
            if lastCompletedStatus == .updateAvailable {
                persistCompletedStatus(.never)
            }
        }
    }

    var lastCheckSummary: String {
        switch lastCompletedStatus {
        case .never:
            "This installation has not been checked for updates yet."
        case .upToDate:
            "Last check found no newer published VolEq release."
        case .updateAvailable:
            if let knownAvailableUpdate {
                "Last check: VolEq \(knownAvailableUpdate.version) is available."
            } else {
                "Last check found an available update."
            }
        case .failed:
            "Last check failed. No conclusion was made about available updates."
        }
    }

    var automaticCheckExplanation: String {
        "Scheduled checks contact GitHub at most once every 24 hours while the app is running. Checks you start yourself can run at any time. No audio or usage data is sent."
    }

    func applicationDidBecomeReady() {
        let persistedLaunchCount = defaults.integer(
            forKey: PreferenceKey.ordinaryLaunchCount
        )
        // Only first launch versus second-or-later matters. Saturating the
        // persisted value also makes corrupted negative/extreme preferences
        // safe to consume without overflow during application startup.
        let launchCount = persistedLaunchCount >= 1 ? 2 : 1
        defaults.set(launchCount, forKey: PreferenceKey.ordinaryLaunchCount)

        if consentDecision == .undecided, launchCount >= 2 {
            shouldPresentConsent = true
        }

        guard automaticallyChecksForUpdates else { return }
        checkIfAutomaticallyDueOrSchedule()
    }

    func applicationActivatedOrWoke() {
        guard automaticallyChecksForUpdates else { return }
        checkIfAutomaticallyDueOrSchedule()
    }

    func applicationWillTerminate() {
        scheduler.cancel()
        activeRequest?.task.cancel()
        activeRequest = nil
        isChecking = false
    }

    func chooseAutomaticCheckConsent(enabled: Bool) {
        shouldPresentConsent = false
        if enabled {
            setAutomaticallyChecksForUpdates(true)
        } else {
            consentDecision = .disabled
            automaticallyChecksForUpdates = false
            persistConsentAndEnabledState()
            scheduler.cancel()
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard enabled != automaticallyChecksForUpdates
                || (enabled && consentDecision != .enabled)
        else { return }

        if enabled {
            consentDecision = .enabled
            automaticallyChecksForUpdates = true
            shouldPresentConsent = false
            persistConsentAndEnabledState()

            Task { [weak self] in
                await self?.performCheck(trigger: .enable)
            }
        } else {
            automaticallyChecksForUpdates = false
            persistConsentAndEnabledState()
            scheduler.cancel()
            cancelAutomaticRequestIfPossible()
        }
    }

    func checkManually() async {
        await performCheck(trigger: .manual)
    }

    func dismissManualPresentation() {
        manualPresentation = nil
    }

    func dismissReleaseOpenFailure() {
        releaseOpenFailure = nil
    }

    func retryManualCheck() {
        manualPresentation = nil
        Task { [weak self] in
            await self?.checkManually()
        }
    }

    @discardableResult
    func openRelease(_ update: KnownAvailableUpdate) -> Bool {
        guard let validatedURL = try? ValidatedGitHubReleaseURL(
            url: update.releaseURL,
            version: update.version
        ) else {
            releaseOpenFailure = ReleaseOpenFailurePresentation(
                message: "VolEq refused to open a release link it could not verify."
            )
            return false
        }
        guard workspaceOpener.open(validatedURL.url) else {
            releaseOpenFailure = ReleaseOpenFailurePresentation(
                message: "macOS couldn’t open the verified GitHub release page. You can try again."
            )
            return false
        }
        return true
    }

    private var normalizedLastAutomaticAttempt: Date? {
        guard let attempt = defaults.object(
            forKey: PreferenceKey.lastAutomaticAttempt
        ) as? Date else {
            return nil
        }

        let now = clock.now
        guard attempt <= now else {
            // Wall-clock rollback or a corrupted future preference must not
            // postpone update discovery indefinitely. Treat now as the start
            // of a fresh rolling interval rather than checking immediately.
            defaults.set(now, forKey: PreferenceKey.lastAutomaticAttempt)
            return now
        }
        return attempt
    }

    private var isAutomaticCheckDue: Bool {
        guard let normalizedLastAutomaticAttempt else { return true }
        return clock.now.timeIntervalSince(normalizedLastAutomaticAttempt)
            >= Self.automaticInterval
    }

    private func checkIfAutomaticallyDueOrSchedule() {
        if isAutomaticCheckDue {
            Task { [weak self] in
                await self?.performCheck(trigger: .automatic)
            }
        } else {
            scheduleNextAutomaticCheck()
        }
    }

    private func scheduleNextAutomaticCheck() {
        guard automaticallyChecksForUpdates,
              let normalizedLastAutomaticAttempt
        else {
            scheduler.cancel()
            return
        }

        let dueDate = normalizedLastAutomaticAttempt.addingTimeInterval(
            Self.automaticInterval
        )
        scheduler.schedule(
            after: max(0, dueDate.timeIntervalSince(clock.now)),
            tolerance: Self.timerTolerance
        ) { [weak self] in
            self?.applicationActivatedOrWoke()
        }
    }

    private func performCheck(trigger: Trigger) async {
        if trigger == .manual {
            manualFeedbackRequested = true
        }

        if trigger == .enable {
            guard automaticallyChecksForUpdates else { return }
            defaults.set(clock.now, forKey: PreferenceKey.lastAutomaticAttempt)
            scheduler.cancel()
        }

        if let activeRequest {
            if trigger == .manual {
                manualFeedbackRequested = true
            }
            if trigger == .automatic,
               automaticallyChecksForUpdates,
               isAutomaticCheckDue
            {
                defaults.set(clock.now, forKey: PreferenceKey.lastAutomaticAttempt)
                scheduler.cancel()
            }
            let result = await activeRequest.task.result
            completeRequestIfCurrent(id: activeRequest.id, result: result)
            return
        }

        if trigger == .automatic {
            guard automaticallyChecksForUpdates, isAutomaticCheckDue else {
                scheduleNextAutomaticCheck()
                return
            }
            let attemptDate = clock.now
            defaults.set(attemptDate, forKey: PreferenceKey.lastAutomaticAttempt)
            scheduler.cancel()
        }

        isChecking = true
        let checker = checker
        let installedVersion = installedVersion
        let request = ActiveRequest(
            id: UUID(),
            trigger: trigger,
            task: Task.detached(priority: .utility) {
                try await checker.check(for: installedVersion)
            }
        )
        activeRequest = request

        let result = await request.task.result
        completeRequestIfCurrent(id: request.id, result: result)
    }

    private func completeRequestIfCurrent(
        id: UUID,
        result: Result<UpdateCheckResult, Error>
    ) {
        guard let request = activeRequest, request.id == id else { return }

        let manualFeedbackRequested = manualFeedbackRequested
        activeRequest = nil
        self.manualFeedbackRequested = false
        isChecking = false

        switch result {
        case let .success(result):
            apply(result, presentsManualFeedback: manualFeedbackRequested)
        case let .failure(error):
            apply(error, presentsManualFeedback: manualFeedbackRequested)
        }

        if automaticallyChecksForUpdates {
            if normalizedLastAutomaticAttempt == nil {
                checkIfAutomaticallyDueOrSchedule()
            } else {
                scheduleNextAutomaticCheck()
            }
        }
    }

    private func apply(
        _ result: UpdateCheckResult,
        presentsManualFeedback: Bool
    ) {
        switch result {
        case .upToDate:
            if let knownAvailableUpdate,
               knownAvailableUpdate.version > installedVersion
            {
                persistCompletedStatus(.updateAvailable)
                if presentsManualFeedback {
                    manualPresentation = ManualUpdatePresentation(
                        kind: .updateAvailable(knownAvailableUpdate)
                    )
                }
                return
            }
            knownAvailableUpdate = nil
            defaults.removeObject(forKey: PreferenceKey.knownAvailableVersion)
            persistCompletedStatus(.upToDate)
            if presentsManualFeedback {
                manualPresentation = ManualUpdatePresentation(
                    kind: .upToDate(installedVersion: installedVersion)
                )
            }
        case let .updateAvailable(release):
            let update: KnownAvailableUpdate
            if let knownAvailableUpdate,
               knownAvailableUpdate.version >= release.version
            {
                update = knownAvailableUpdate
            } else {
                update = KnownAvailableUpdate(
                    version: release.version,
                    releaseURL: release.releaseURL
                )
            }
            knownAvailableUpdate = update
            defaults.set(
                update.version.description,
                forKey: PreferenceKey.knownAvailableVersion
            )
            persistCompletedStatus(.updateAvailable)
            if presentsManualFeedback {
                manualPresentation = ManualUpdatePresentation(
                    kind: .updateAvailable(update)
                )
            }
        }
    }

    private func apply(
        _ error: Error,
        presentsManualFeedback: Bool
    ) {
        let updateError: UpdateCheckError
        if let error = error as? UpdateCheckError {
            updateError = error
        } else if error is CancellationError {
            updateError = .cancelled
        } else {
            updateError = .invalidResponse
        }

        if updateError != .cancelled {
            persistCompletedStatus(.failed)
        }
        if presentsManualFeedback {
            manualPresentation = ManualUpdatePresentation(
                kind: .failure(
                    message: updateError.errorDescription
                        ?? "VolEq couldn’t check for updates. Try again."
                )
            )
        }
    }

    private func cancelAutomaticRequestIfPossible() {
        guard let request = activeRequest,
              request.trigger != .manual,
              !manualFeedbackRequested
        else { return }

        activeRequest = nil
        isChecking = false
        request.task.cancel()
    }

    private func persistConsentAndEnabledState() {
        defaults.set(
            consentDecision.rawValue,
            forKey: PreferenceKey.consentDecision
        )
        defaults.set(
            automaticallyChecksForUpdates,
            forKey: PreferenceKey.automaticallyChecks
        )
    }

    private func persistCompletedStatus(_ status: LastUpdateCheckStatus) {
        lastCompletedStatus = status
        defaults.set(status.rawValue, forKey: PreferenceKey.lastCompletedStatus)
    }
}
