// SPDX-License-Identifier: MPL-2.0

import Foundation
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
    let presentation: MacPresentationController

    init(defaults: UserDefaults) {
        audio = AudioCaptureController()
        presentation = MacPresentationController(defaults: defaults)
    }

    private static func makeDefaults() -> UserDefaults {
        if let suiteName = ProcessInfo.processInfo.environment["VOLEQ_DEFAULTS_SUITE"],
           !suiteName.isEmpty,
           let defaults = UserDefaults(suiteName: suiteName) {
            return defaults
        }
        return .standard
    }
}
