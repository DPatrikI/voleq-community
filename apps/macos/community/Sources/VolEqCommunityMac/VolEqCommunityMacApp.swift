// SPDX-License-Identifier: MPL-2.0

import AppKit
import Darwin
import SwiftUI
import VolEqSpeech

@main
@available(macOS 14.2, *)
struct VolEqCommunityMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var presentation: MacPresentationController
    @StateObject private var updates: UpdateController
    private let applicationModel: VolEqApplicationModel

    init() {
        if ProcessInfo.processInfo.arguments.contains("--verify-speech-resources") {
            Self.verifySpeechResourcesAndExit()
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-app-resources") {
            Self.verifyAppResourcesAndExit()
        }

        let applicationModel = VolEqApplicationModel.shared
        self.applicationModel = applicationModel
        _presentation = StateObject(wrappedValue: applicationModel.presentation)
        _updates = StateObject(wrappedValue: applicationModel.updates)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarInsertion) {
            MenuBarControlSurface(
                model: applicationModel.audio,
                updates: updates,
                openSettings: { appDelegate.showSettings() }
            )
        } label: {
            MenuBarStatusLabel(
                model: applicationModel.audio,
                updates: updates
            )
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(
                    updates.isChecking
                        ? "Checking for Updates…"
                        : "Check for Updates…"
                ) {
                    Task {
                        await updates.checkManually()
                    }
                }
                .disabled(updates.isChecking)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",")
            }
        }
    }

    private var menuBarInsertion: Binding<Bool> {
        Binding(
            get: { presentation.mode == .menuBar },
            set: { isInserted in
                guard !isInserted, presentation.mode == .menuBar else { return }
                // If the user removes the menu-bar item with Command-drag,
                // return to the discoverable Window presentation instead of
                // leaving a running application without an entry point.
                presentation.mode = .window
            }
        )
    }

    private static func verifySpeechResourcesAndExit() -> Never {
        do {
            _ = try RNNoiseModelResource.bundled()
            print("[ok] packaged RNNoise model loaded")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func verifyAppResourcesAndExit() -> Never {
        do {
            try VolEqBrand.verifyPackagedResources()
            print("[ok] packaged VolEq branding loaded")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
