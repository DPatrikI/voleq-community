// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import SwiftUI
import VolEqMacAudio

@MainActor
@available(macOS 14.2, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presentationSubscription: AnyCancellable?
    private var utilityWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var isRestoringPresentation = false

    private var applicationModel: VolEqApplicationModel {
        .shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentationSubscription = applicationModel.presentation.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.apply(mode)
            }
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
            presentation: applicationModel.presentation
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "VolEq Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 260))
        window.tabbingMode = .disallowed
        window.center()
        return NSWindowController(window: window)
    }
}
