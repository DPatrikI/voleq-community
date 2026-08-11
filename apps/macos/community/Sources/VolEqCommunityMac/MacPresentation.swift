// SPDX-License-Identifier: MPL-2.0

import Foundation
import Darwin
import VolEqMacAudio

enum MacPresentationMode: String, CaseIterable, Identifiable, Sendable {
    case window
    case menuBar

    var id: Self { self }

    var title: String {
        switch self {
        case .window:
            "Window"
        case .menuBar:
            "Menu Bar"
        }
    }

    var systemImage: String {
        switch self {
        case .window:
            "macwindow"
        case .menuBar:
            "menubar.rectangle"
        }
    }

    var detail: String {
        switch self {
        case .window:
            "Show VolEq in the Dock and use the utility window."
        case .menuBar:
            "Keep VolEq in the menu bar and open controls in a popover."
        }
    }
}

@MainActor
final class MacPresentationController: ObservableObject {
    static let preferenceKey = "macPresentationMode"

    @Published var mode: MacPresentationMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.preferenceKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.preferenceKey)
            .flatMap(MacPresentationMode.init(rawValue:))
            ?? .window
    }
}

@MainActor
@available(macOS 14.2, *)
final class VolEqApplicationModel {
    static let shared = VolEqApplicationModel(defaults: makeDefaults())

    let audio: AudioCaptureController
    let systemAudioAccess: SystemAudioAccessPresentationController
    let presentation: MacPresentationController
    let updates: UpdateController
    let diagnostics: AudioLivenessDiagnostics?

    init(
        defaults: UserDefaults,
        installedVersion: ApplicationVersion? = nil,
        systemSettingsOpener: any SystemSettingsOpening = WorkspaceSystemSettingsOpener(),
        audioController: AudioCaptureController? = nil
    ) {
        let systemAudioAccess = SystemAudioAccessPresentationController(
            defaults: defaults,
            settingsOpener: systemSettingsOpener
        )
        self.systemAudioAccess = systemAudioAccess
#if VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC
        diagnostics = Self.makeAudioLivenessDiagnostics()
#else
        diagnostics = nil
#endif
        audio = audioController ?? AudioCaptureController(
            permissionExplanationRequest: { [weak systemAudioAccess] in
                guard let systemAudioAccess else { return false }
                return await systemAudioAccess.requestExplanationAcceptance()
            },
            audioLivenessDiagnostics: diagnostics
        )
        presentation = MacPresentationController(defaults: defaults)
        let resolvedVersion: ApplicationVersion
        let checker: any UpdateChecking
        if let installedVersion {
            resolvedVersion = installedVersion
            checker = GitHubReleaseChecker(
                httpClient: EphemeralUpdateHTTPClient()
            )
        } else if let bundledVersion = try? ApplicationVersion(bundle: .main) {
            resolvedVersion = bundledVersion
            checker = GitHubReleaseChecker(
                httpClient: EphemeralUpdateHTTPClient()
            )
        } else {
            // A malformed package must not let optional update work prevent the
            // audio application from starting. Packaging validation catches
            // this condition; manual checks fail safely in such a build.
            resolvedVersion = .zero
            checker = UnavailableUpdateChecker()
        }
        updates = UpdateController(
            installedVersion: resolvedVersion,
            checker: checker,
            defaults: defaults,
            clock: SystemUpdateClock(),
            scheduler: FoundationUpdateScheduler(),
            workspaceOpener: SystemUpdateWorkspaceOpener()
        )
    }

    private static func makeDefaults() -> UserDefaults {
        if let suiteName = ProcessInfo.processInfo.environment["VOLEQ_DEFAULTS_SUITE"],
           !suiteName.isEmpty,
           let defaults = UserDefaults(suiteName: suiteName) {
            return defaults
        }
        return .standard
    }

#if VOLEQ_AUDIO_LIVENESS_DIAGNOSTIC
    private static func makeAudioLivenessDiagnostics() -> AudioLivenessDiagnostics? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let storage = applicationSupport
            .appendingPathComponent(
                "VolEq Audio Liveness Diagnostic",
                isDirectory: true
            )
            .appendingPathComponent(
                AudioLivenessDiagnostics.storageDirectoryName,
                isDirectory: true
            )
        let info = Bundle.main.infoDictionary ?? [:]
        let environment = AudioLivenessDiagnosticEnvironment(
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: hardwareModel(),
            applicationVersion: info["CFBundleShortVersionString"] as? String
                ?? "unknown",
            applicationBuild: info["CFBundleVersion"] as? String ?? "unknown",
            diagnosticVariant: info["VolEqDiagnosticVariant"] as? String
                ?? "audio-liveness",
            sourceCommit: info["VolEqDiagnosticSourceCommit"] as? String
                ?? "unknown"
        )
        return try? AudioLivenessDiagnostics(
            storageDirectoryURL: storage,
            environment: environment
        )
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: bytes)
    }
#endif
}
