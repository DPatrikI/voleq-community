// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import VolEqMacAudio

enum MacActivationPolicyTransition {
    static func apply(
        current: NSApplication.ActivationPolicy,
        desired: NSApplication.ActivationPolicy,
        setPolicy: (NSApplication.ActivationPolicy) -> Bool
    ) -> Bool {
        // NSApplication returns false when no policy change was necessary.
        // Being at the requested policy is already a successful outcome.
        current == desired || setPolicy(desired)
    }
}

@MainActor
@available(macOS 14.2, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presentationSubscription: AnyCancellable?
    private var audioAccessExplanationSubscription: AnyCancellable?
    private var noSoundHelpSubscription: AnyCancellable?
    private var audioRuntimeAnnouncementSubscription: AnyCancellable?
    private var consentSubscription: AnyCancellable?
    private var manualUpdateSubscription: AnyCancellable?
    private var releaseOpenFailureSubscription: AnyCancellable?
    private let workspaceLifecycle: WorkspaceLifecycleForwarder
    private let terminationReply: @MainActor (NSApplication, Bool) -> Void
    private let audioStatusAnnouncement: @MainActor (String) -> Void
    private var audioAnnouncementTracker = AudioStatusAnnouncementTracker()
    private var utilityWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var isRestoringPresentation = false
    private var didFinishLaunching = false
    private var isPresentingConsent = false
    private var isPresentingAudioAccessExplanation = false
    private var isPresentingNoSoundHelp = false
    private var isPresentingUpdateResult = false
    private var isAwaitingAudioTermination = false
    private var didCompleteAudioTermination = false
    private var diagnosticTestSource: Process?
    private var diagnosticControlledTestTask: Task<Void, Never>?

    private let applicationModel: VolEqApplicationModel

    override convenience init() {
        self.init(
            applicationModel: .shared,
            workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
            audioStatusAnnouncement: { status in
                AppDelegate.postAudioStatusAnnouncement(status)
            },
            terminationReply: { $0.reply(toApplicationShouldTerminate: $1) }
        )
    }

    init(
        applicationModel: VolEqApplicationModel,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        audioStatusAnnouncement: @escaping @MainActor (String) -> Void = {
            AppDelegate.postAudioStatusAnnouncement($0)
        },
        terminationReply: @escaping @MainActor (NSApplication, Bool) -> Void = {
            $0.reply(toApplicationShouldTerminate: $1)
        }
    ) {
        self.applicationModel = applicationModel
        self.audioStatusAnnouncement = audioStatusAnnouncement
        self.terminationReply = terminationReply
        workspaceLifecycle = WorkspaceLifecycleForwarder(
            notificationCenter: workspaceNotificationCenter,
            prepareAudioForSleep: {
                applicationModel.audio.prepareForSystemSleep()
            },
            resumeAudioAfterWake: {
                applicationModel.audio.resumeAfterSystemWake()
            },
            updateApplicationActivatedOrWoke: {
                applicationModel.updates.applicationActivatedOrWoke()
            }
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentationSubscription = applicationModel.presentation.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.apply(mode)
            }

        audioAccessExplanationSubscription = applicationModel.systemAudioAccess
            .$shouldPresentExplanation
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.presentSystemAudioAccessExplanation()
            }

        noSoundHelpSubscription = applicationModel.systemAudioAccess
            .$shouldPresentNoSoundHelp
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.presentNoSoundHelp()
            }

        startAudioRuntimeAnnouncements()

        consentSubscription = applicationModel.updates.$shouldPresentConsent
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.presentAutomaticCheckConsent()
            }

        manualUpdateSubscription = applicationModel.updates.$manualPresentation
            .compactMap { $0 }
            .sink { [weak self] presentation in
                self?.presentManualUpdateResult(presentation)
            }

        releaseOpenFailureSubscription = applicationModel.updates.$releaseOpenFailure
            .compactMap { $0 }
            .sink { [weak self] presentation in
                self?.presentReleaseOpenFailure(presentation)
            }

        workspaceLifecycle.start()

        didFinishLaunching = true
#if !VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.applicationModel.updates.applicationDidBecomeReady()
        }
#endif
    }

    func startAudioRuntimeAnnouncements() {
        guard audioRuntimeAnnouncementSubscription == nil else { return }
        audioRuntimeAnnouncementSubscription = applicationModel.audio
            .$captureState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.processAudioStateForAnnouncement(state)
            }
    }

    func processAudioStateForAnnouncement(_ state: AudioCaptureStateSnapshot) {
        guard let message = audioAnnouncementTracker.message(for: state) else {
            return
        }
        audioStatusAnnouncement(message)
    }

    private static func postAudioStatusAnnouncement(_ status: String) {
        let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
            .announcement: status,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ]
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: userInfo
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didFinishLaunching else { return }
        workspaceLifecycle.applicationActivated()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard applicationModel.presentation.mode == .window else { return false }
        showUtilityWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isAwaitingAudioTermination else { return .terminateLater }
        isAwaitingAudioTermination = true
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            await applicationModel.audio.prepareForApplicationTermination()
            let cleanupComplete: Bool
            if case .actionRequired(.cleanupFailed) =
                applicationModel.audio.systemAudioAccessState {
                cleanupComplete = false
            } else {
                cleanupComplete = true
            }
            await applicationModel.diagnostics?.finalizeAndWait(
                reason: cleanupComplete
                    ? "Diagnostic application terminated after audio cleanup."
                    : "Diagnostic application terminated with incomplete Core Audio cleanup.",
                cleanupComplete: cleanupComplete
            )
            didCompleteAudioTermination = true
            isAwaitingAudioTermination = false
            if let sender { terminationReply(sender, true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
#if VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC
        diagnosticControlledTestTask?.cancel()
        diagnosticControlledTestTask = nil
        diagnosticTestSource?.terminate()
        diagnosticTestSource = nil
#endif
        applicationModel.updates.applicationWillTerminate()
        if !didCompleteAudioTermination {
            applicationModel.audio.stop()
            applicationModel.diagnostics?.finalize(
                reason: "Diagnostic application terminated before asynchronous cleanup completed.",
                cleanupComplete: false
            )
        }
    }

    func showSettings() {
        let controller: NSWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            controller = makeSettingsWindowController()
            settingsWindowController = controller
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func apply(_ mode: MacPresentationMode) {
        guard !isRestoringPresentation else { return }

        switch mode {
        case .window:
            guard MacActivationPolicyTransition.apply(
                current: NSApp.activationPolicy(),
                desired: .regular,
                setPolicy: { NSApp.setActivationPolicy($0) }
            ) else {
                recoverFromPresentationFailure(requested: .window, fallback: .menuBar)
                return
            }
            showUtilityWindow()
        case .menuBar:
            guard MacActivationPolicyTransition.apply(
                current: NSApp.activationPolicy(),
                desired: .accessory,
                setPolicy: { NSApp.setActivationPolicy($0) }
            ) else {
                recoverFromPresentationFailure(requested: .menuBar, fallback: .window)
                return
            }
            utilityWindowController?.close()
        }
    }

    private func recoverFromPresentationFailure(
        requested: MacPresentationMode,
        fallback: MacPresentationMode
    ) {
        // Published values are delivered from willSet. Defer rollback until the
        // failed user assignment has completed so it cannot overwrite fallback.
        Task { @MainActor [weak self] in
            guard let self,
                  self.applicationModel.presentation.mode == requested
            else { return }
            self.isRestoringPresentation = true
            self.applicationModel.presentation.mode = fallback
            self.isRestoringPresentation = false
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Switch Presentation"
        alert.informativeText = "VolEq couldn’t switch to \(requested.title). \(fallback.title) remains active."
        alert.addButton(withTitle: "OK")

        let visibleParent = [
            settingsWindowController?.window,
            utilityWindowController?.window,
        ]
        .compactMap { $0 }
        .first(where: \.isVisible)

        if let visibleParent {
            alert.beginSheetModal(for: visibleParent)
        } else {
            showSettings()
            if let settingsWindow = settingsWindowController?.window {
                alert.beginSheetModal(for: settingsWindow)
            }
        }
    }

    private func showUtilityWindow() {
        let controller: NSWindowController
        if let utilityWindowController {
            controller = utilityWindowController
        } else {
            controller = makeUtilityWindowController()
            utilityWindowController = controller
        }

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeUtilityWindowController() -> NSWindowController {
        let rootView = UtilityWindowView(
            model: applicationModel.audio,
            systemAudioAccess: applicationModel.systemAudioAccess,
            updates: applicationModel.updates,
            actions: makeShellActions()
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
#if VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC
        window.title = "VolEq Audio Liveness Diagnostic"
        window.setContentSize(NSSize(width: 548, height: 700))
        window.contentMinSize = NSSize(width: 548, height: 640)
#else
        window.title = "VolEq"
        window.setContentSize(NSSize(width: 548, height: 620))
        window.contentMinSize = NSSize(width: 548, height: 560)
#endif
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        return NSWindowController(window: window)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let rootView = PresentationSettingsView(
            presentation: applicationModel.presentation,
            updates: applicationModel.updates,
            actions: makeShellActions()
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
#if VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC
        window.title = "VolEq Audio Liveness Diagnostic Settings"
#else
        window.title = "VolEq Settings"
#endif
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 480))
        window.contentMinSize = NSSize(width: 560, height: 460)
        window.tabbingMode = .disallowed
        window.center()
        return NSWindowController(window: window)
    }

    private func makeShellActions() -> ApplicationShellActions {
        ApplicationShellActions(
            updates: applicationModel.updates,
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) },
            exportDiagnostics: { [weak self] in
                self?.exportDiagnosticReport()
            },
            clearDiagnostics: { [weak self] in
                self?.confirmDiagnosticHistoryClear()
            },
            verifyAudio: { [weak self] in
                self?.verifyAudioLivenessAndReconnect()
            },
            reconnectAudio: { [weak self] in
                self?.reconnectDiagnosticAudio()
            },
            runControlledTest: { [weak self] in
                self?.confirmControlledLivenessRecoveryTest()
            }
        )
    }

    func verifyAudioLivenessAndReconnect() {
        guard applicationModel.audio.verifyAndReconnectIfNeeded() else {
            presentDiagnosticResult(
                title: "Verification Not Started",
                message: applicationModel.audio.isRunning
                    ? "Captured audio is currently available, or another verification is already running. If sound should be playing but remains absent, use Reconnect Audio."
                    : "Start Leveling before verifying the captured-audio path.",
                warning: true
            )
            return
        }
    }

    func reconnectDiagnosticAudio() {
        guard applicationModel.audio.reconnectAudio() else {
            presentDiagnosticResult(
                title: "Reconnect Unavailable",
                message: "Reconnect Audio is available while Leveling is Active.",
                warning: true
            )
            return
        }
    }

    func confirmControlledLivenessRecoveryTest() {
        guard applicationModel.audio.isRunning,
              applicationModel.audio.mode == .system
        else {
            presentDiagnosticResult(
                title: "Use Active Device-wide Leveling",
                message: "The controlled test source is intentionally separate from VolEq, so this test requires Device-wide mode with Leveling Active.",
                warning: true
            )
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run Controlled Recovery Test?"
        alert.informativeText = "The diagnostic will simulate zero-filled capture and keep an independent metadata-only watcher in genuine silence for six seconds. A quiet synthetic tone will then play from a separate local process. VolEq should confirm the stale main path and reconnect once. No audio samples are stored."
        alert.addButton(withTitle: "Run Test")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runControlledLivenessRecoveryTest()
        }
    }

    private func runControlledLivenessRecoveryTest() {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/VolEqLivenessTestSource")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            presentDiagnosticResult(
                title: "Test Source Missing",
                message: "Rebuild the private audio-liveness diagnostic app; its synthetic test-source helper is unavailable.",
                warning: true
            )
            return
        }
        diagnosticControlledTestTask?.cancel()
        diagnosticControlledTestTask = nil
        diagnosticTestSource?.terminate()
        diagnosticTestSource = nil
        applicationModel.audio.cancelControlledLivenessRecoveryTest()
        guard applicationModel.audio.runControlledLivenessRecoveryTest() else {
            presentDiagnosticResult(
                title: "Controlled Test Didn’t Start",
                message: "The device-wide audio pipeline was no longer Active or another verification was already running.",
                warning: true
            )
            return
        }
        applicationModel.diagnostics?.recordRecoveryExperimentEvent(
            kind: "controlledTestSilentSentinelPeriodBegan",
            reason: "The main path was fault-injected to exact zero before any independent test signal existed."
        )
        diagnosticControlledTestTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 6_000_000_000)
            } catch {
                return
            }
            guard let self, applicationModel.audio.isRunning,
                  applicationModel.audio.mode == .system
            else { return }
            diagnosticControlledTestTask = nil
            startControlledTestSource(at: helper)
        }
    }

    private func startControlledTestSource(at helper: URL) {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["15"]
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor in
                guard let self, self.diagnosticTestSource === process else { return }
                self.diagnosticTestSource = nil
                self.applicationModel.diagnostics?.recordRecoveryExperimentEvent(
                    kind: "controlledTestSourceEnded",
                    reason: "Synthetic metadata-safe test source exited."
                )
            }
        }
        do {
            try process.run()
        } catch {
            applicationModel.audio.cancelControlledLivenessRecoveryTest()
            presentDiagnosticResult(
                title: "Couldn’t Start Controlled Test Source",
                message: error.localizedDescription,
                warning: true
            )
            return
        }
        diagnosticTestSource = process
        applicationModel.diagnostics?.recordRecoveryExperimentEvent(
            kind: "controlledTestSourceStarted",
            reason: "A separate process started a deterministic low-volume synthetic tone after the independent watcher remained silent beyond the old timeout; no samples are retained."
        )
    }

    func exportDiagnosticReport() {
        guard let diagnostics = applicationModel.diagnostics else {
            presentDiagnosticResult(
                title: "Diagnostics Unavailable",
                message: "VolEq could not initialize its bounded diagnostic storage. Quit and relaunch the diagnostic app before testing.",
                warning: true
            )
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Audio-Liveness Diagnostic Report"
        panel.nameFieldStringValue = "VolEq-Audio-Liveness-\(diagnostics.sessionIdentifier).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let data = try await diagnostics.exportReportData()
                    try await Task.detached(priority: .utility) {
                        try data.write(to: destination, options: .atomic)
                    }.value
                    self.presentDiagnosticResult(
                        title: "Diagnostic Report Exported",
                        message: "Saved metadata-only report to \(destination.path)."
                    )
                } catch {
                    self.presentDiagnosticResult(
                        title: "Couldn’t Export Diagnostic Report",
                        message: error.localizedDescription,
                        warning: true
                    )
                }
            }
        }
        if let parent = visibleParentWindow {
            panel.beginSheetModal(for: parent, completionHandler: completion)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.begin(completionHandler: completion)
        }
    }

    func confirmDiagnosticHistoryClear() {
        guard let diagnostics = applicationModel.diagnostics else {
            presentDiagnosticResult(
                title: "Diagnostics Unavailable",
                message: "There is no local diagnostic journal to clear.",
                warning: true
            )
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear Diagnostic Data?"
        alert.informativeText = "This permanently removes VolEq’s bounded local metadata journal. It does not affect reports you already exported."
        alert.addButton(withTitle: "Clear Diagnostic Data")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                do {
                    try await diagnostics.clearStoredData()
                    self?.presentDiagnosticResult(
                        title: "Diagnostic Data Cleared",
                        message: "A new metadata-only diagnostic session is now recording."
                    )
                } catch {
                    self?.presentDiagnosticResult(
                        title: "Couldn’t Clear Diagnostic Data",
                        message: error.localizedDescription,
                        warning: true
                    )
                }
            }
        }
    }

    private func presentDiagnosticResult(
        title: String,
        message: String,
        warning: Bool = false
    ) {
        let alert = NSAlert()
        alert.alertStyle = warning ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }

    private func presentAutomaticCheckConsent() {
        guard !isPresentingConsent else { return }
        isPresentingConsent = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Automatically Check for VolEq Updates?"
        alert.informativeText = "Scheduled checks contact GitHub at most once every 24 hours while VolEq is running. Checks you start yourself can run at any time. No audio or usage data is sent. You can change this later in Settings."
        alert.addButton(withTitle: "Enable Daily Checks")
        let declineButton = alert.addButton(withTitle: "Don’t Check Automatically")
        declineButton.keyEquivalent = "\u{1b}"
        present(alert) { [weak self] response in
            guard let self else { return }
            self.isPresentingConsent = false
            self.applicationModel.updates.chooseAutomaticCheckConsent(
                enabled: response == .alertFirstButtonReturn
            )
        }
    }

    private func presentSystemAudioAccessExplanation() {
        guard !isPresentingAudioAccessExplanation else { return }
        isPresentingAudioAccessExplanation = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = SystemAudioAccessPresentationController.explanationTitle
        alert.informativeText = SystemAudioAccessPresentationController.explanationCopy
        alert.addButton(withTitle: "Continue")
        let notNowButton = alert.addButton(withTitle: "Not Now")
        notNowButton.keyEquivalent = "\u{1b}"
        present(alert) { [weak self] response in
            guard let self else { return }
            self.isPresentingAudioAccessExplanation = false
            self.applicationModel.systemAudioAccess.respondToExplanation(
                continued: response == .alertFirstButtonReturn
            )
        }
    }

    private func presentNoSoundHelp() {
        guard !isPresentingNoSoundHelp else { return }
        isPresentingNoSoundHelp = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = SystemAudioAccessPresentationController.noSoundTitle
        alert.informativeText = SystemAudioAccessPresentationController.noSoundCopy
        alert.addButton(withTitle: "Open System Settings…")
        let doneButton = alert.addButton(withTitle: "Done")
        doneButton.keyEquivalent = "\u{1b}"
        present(alert) { [weak self] response in
            guard let self else { return }
            self.isPresentingNoSoundHelp = false
            self.applicationModel.systemAudioAccess.dismissNoSoundHelp()
            if response == .alertFirstButtonReturn {
                let outcome = self.applicationModel.systemAudioAccess
                    .openSystemAudioRecordingSettings()
                if case let .failed(manualInstructions) = outcome {
                    self.presentSystemAudioSettingsOpenFailure(
                        manualInstructions: manualInstructions
                    )
                }
            }
        }
    }

    private func presentSystemAudioSettingsOpenFailure(
        manualInstructions: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Open System Settings"
        alert.informativeText = manualInstructions
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }

    private func presentManualUpdateResult(
        _ presentation: ManualUpdatePresentation
    ) {
        guard !isPresentingUpdateResult else { return }
        isPresentingUpdateResult = true

        let alert = NSAlert()
        switch presentation.kind {
        case let .updateAvailable(update):
            alert.alertStyle = .informational
            alert.messageText = "VolEq \(update.version) Is Available"
            alert.informativeText = "VolEq will open the verified GitHub release page. It will not download or install the update."
            alert.addButton(withTitle: "View Release")
            let laterButton = alert.addButton(withTitle: "Later")
            laterButton.keyEquivalent = "\u{1b}"
            present(alert) { [weak self] response in
                guard let self else { return }
                self.isPresentingUpdateResult = false
                self.applicationModel.updates.dismissManualPresentation()
                if response == .alertFirstButtonReturn {
                    _ = self.applicationModel.updates.openRelease(update)
                }
            }
        case let .upToDate(installedVersion):
            alert.alertStyle = .informational
            alert.messageText = "VolEq Is Up to Date"
            alert.informativeText = "No newer published version was found for VolEq \(installedVersion)."
            alert.addButton(withTitle: "OK")
            present(alert) { [weak self] _ in
                self?.isPresentingUpdateResult = false
                self?.applicationModel.updates.dismissManualPresentation()
            }
        case let .failure(message):
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Check for Updates"
            alert.informativeText = message
            alert.addButton(withTitle: "Retry")
            let cancelButton = alert.addButton(withTitle: "Cancel")
            cancelButton.keyEquivalent = "\u{1b}"
            present(alert) { [weak self] response in
                guard let self else { return }
                self.isPresentingUpdateResult = false
                if response == .alertFirstButtonReturn {
                    self.applicationModel.updates.retryManualCheck()
                } else {
                    self.applicationModel.updates.dismissManualPresentation()
                }
            }
        }
    }

    private func presentReleaseOpenFailure(
        _ presentation: ReleaseOpenFailurePresentation
    ) {
        guard !isPresentingUpdateResult else { return }
        isPresentingUpdateResult = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Open Release"
        alert.informativeText = presentation.message
        alert.addButton(withTitle: "OK")
        present(alert) { [weak self] _ in
            self?.isPresentingUpdateResult = false
            self?.applicationModel.updates.dismissReleaseOpenFailure()
        }
    }

    private func present(
        _ alert: NSAlert,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        if let parent = visibleParentWindow {
            alert.beginSheetModal(for: parent) { response in
                Task { @MainActor in completion(response) }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            completion(response)
        }
    }

    private var visibleParentWindow: NSWindow? {
        [settingsWindowController?.window, utilityWindowController?.window]
            .compactMap { $0 }
            .first(where: \.isVisible)
    }
}
