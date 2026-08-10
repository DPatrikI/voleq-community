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

enum SystemAudioSettingsNavigationOutcome: Equatable {
    case opened
    case failed(manualInstructions: String)
}

@MainActor
final class SystemAudioAccessPresentationController: ObservableObject {
    static let explanationAcceptedKey = "systemAudioAccessExplanationAccepted"
    static let explanationTitle = "System Audio Access Is Required"
    static let explanationCopy = "macOS calls this System Audio Recording permission. VolEq uses it only to process the playback you choose in real time. Audio stays in memory and is never saved, uploaded, or used for telemetry."
    static let noSoundTitle = "No sound?"
    static let noSoundCopy = "This usually means System Audio Recording permission was not granted or is disabled. VolEq processes the playback you choose only in memory. It does not record, save, upload, or use your audio for telemetry. In System Settings, open Privacy & Security → Screen & System Audio Recording."
    static let manualSettingsPath = "In System Settings, open Privacy & Security → Screen & System Audio Recording. If macOS asks you to quit and reopen VolEq after changing access, do that before starting again."

    @Published private(set) var shouldPresentExplanation = false
    @Published private(set) var shouldPresentNoSoundHelp = false

    private let defaults: UserDefaults
    private let settingsOpener: any SystemSettingsOpening
    private var explanationContinuations: [
        UUID: CheckedContinuation<Bool, Never>
    ] = [:]

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
        let requestID = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                explanationContinuations[requestID] = continuation
                shouldPresentExplanation = true
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelExplanationRequest(requestID)
            }
        }
    }

    func respondToExplanation(continued: Bool) {
        guard !explanationContinuations.isEmpty else { return }
        let continuations = Array(explanationContinuations.values)
        explanationContinuations.removeAll(keepingCapacity: true)
        shouldPresentExplanation = false
        if continued {
            defaults.set(true, forKey: Self.explanationAcceptedKey)
        }
        for continuation in continuations {
            continuation.resume(returning: continued)
        }
    }

    func presentNoSoundHelp() {
        shouldPresentNoSoundHelp = true
    }

    func dismissNoSoundHelp() {
        shouldPresentNoSoundHelp = false
    }

    private func cancelExplanationRequest(_ requestID: UUID) {
        guard let continuation = explanationContinuations.removeValue(
            forKey: requestID
        ) else { return }
        shouldPresentExplanation = !explanationContinuations.isEmpty
        continuation.resume(returning: false)
    }

    func openSystemAudioRecordingSettings() -> SystemAudioSettingsNavigationOutcome {
        if let directURL = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ), settingsOpener.open(directURL) {
            return .opened
        }

        if let privacyURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security"
        ), settingsOpener.open(privacyURL) {
            return .opened
        }

        return .failed(manualInstructions: Self.manualSettingsPath)
    }
}
