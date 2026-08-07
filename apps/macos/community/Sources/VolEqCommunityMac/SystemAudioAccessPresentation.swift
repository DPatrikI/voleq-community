// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

protocol SystemSettingsOpening {
    func open(_ url: URL) -> Bool
}

struct WorkspaceSystemSettingsOpener: SystemSettingsOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class SystemAudioAccessPresentationController: ObservableObject {
    static let explanationAcceptedKey = "systemAudioAccessExplanationAccepted"
    static let explanationTitle = "System Audio Access Is Required"
    static let explanationCopy = "macOS calls this System Audio Recording permission. VolEq uses it only to process the playback you choose in real time. Audio stays in memory and is never saved, uploaded, or used for telemetry."
    static let manualSettingsPath = "In System Settings, open Privacy & Security → Screen & System Audio Recording. If macOS asks you to quit and reopen VolEq after changing access, do that before choosing Check Again."

    @Published private(set) var shouldPresentExplanation = false
    @Published private(set) var settingsFallbackMessage: String?

    private let defaults: UserDefaults
    private let settingsOpener: any SystemSettingsOpening
    private var explanationContinuation: CheckedContinuation<Bool, Never>?

    init(
        defaults: UserDefaults,
        settingsOpener: any SystemSettingsOpening = WorkspaceSystemSettingsOpener()
    ) {
        self.defaults = defaults
        self.settingsOpener = settingsOpener
    }

    func requestExplanationAcceptance() async -> Bool {
        if defaults.bool(forKey: Self.explanationAcceptedKey) {
            return true
        }
        guard explanationContinuation == nil else { return false }

        shouldPresentExplanation = true
        return await withCheckedContinuation { continuation in
            explanationContinuation = continuation
        }
    }

    func respondToExplanation(continued: Bool) {
        guard let explanationContinuation else { return }
        self.explanationContinuation = nil
        shouldPresentExplanation = false
        if continued {
            defaults.set(true, forKey: Self.explanationAcceptedKey)
        }
        explanationContinuation.resume(returning: continued)
    }

    func openSystemAudioRecordingSettings() {
        settingsFallbackMessage = nil

        if let directURL = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ), settingsOpener.open(directURL) {
            settingsFallbackMessage = "System Settings opened. " + Self.manualSettingsPath
            return
        }

        var openedPrivacy = false
        if let privacyURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security"
        ) {
            openedPrivacy = settingsOpener.open(privacyURL)
        }
        settingsFallbackMessage = openedPrivacy
            ? "System Settings opened, but VolEq could not navigate directly to the recording pane. "
                + Self.manualSettingsPath
            : "VolEq could not open System Settings automatically. "
                + Self.manualSettingsPath
    }
}
