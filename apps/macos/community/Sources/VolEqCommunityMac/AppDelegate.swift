// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import SwiftUI
import VolEqMacAudio

@MainActor
@available(macOS 14.2, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presentationSubscription: AnyCancellable?
    private var consentSubscription: AnyCancellable?
    private var manualUpdateSubscription: AnyCancellable?
    private var releaseOpenFailureSubscription: AnyCancellable?
    private var wakeSubscription: AnyCancellable?
    private var utilityWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var isRestoringPresentation = false
    private var didFinishLaunching = false
    private var isPresentingConsent = false
    private var isPresentingUpdateResult = false

    private var applicationModel: VolEqApplicationModel {
        .shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentationSubscription = applicationModel.presentation.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.apply(mode)
            }

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

        wakeSubscription = NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didWakeNotification
        )
        .sink { [weak self] _ in
            self?.applicationModel.updates.applicationActivatedOrWoke()
        }

        didFinishLaunching = true
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.applicationModel.updates.applicationDidBecomeReady()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didFinishLaunching else { return }
        applicationModel.updates.applicationActivatedOrWoke()
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

    func applicationWillTerminate(_ notification: Notification) {
        applicationModel.updates.applicationWillTerminate()
        if applicationModel.audio.isRunning {
            applicationModel.audio.stop()
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
            guard NSApp.setActivationPolicy(.regular) else {
                recoverFromPresentationFailure(requested: .window, fallback: .menuBar)
                return
            }
            showUtilityWindow()
        case .menuBar:
            guard NSApp.setActivationPolicy(.accessory) else {
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
            updates: applicationModel.updates,
            openSettings: { [weak self] in self?.showSettings() }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "VolEq"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 548, height: 620))
        window.contentMinSize = NSSize(width: 548, height: 560)
        window.tabbingMode = .disallowed
        window.center()
        return NSWindowController(window: window)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let rootView = PresentationSettingsView(
            presentation: applicationModel.presentation,
            updates: applicationModel.updates
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "VolEq Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 480))
        window.contentMinSize = NSSize(width: 560, height: 460)
        window.tabbingMode = .disallowed
        window.center()
        return NSWindowController(window: window)
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
