// SPDX-License-Identifier: MPL-2.0

import Foundation

@MainActor
protocol ApplicationUpdateCommandHandling: AnyObject {
    func checkManually() async
    @discardableResult
    func openRelease(_ update: KnownAvailableUpdate) -> Bool
}

extension UpdateController: ApplicationUpdateCommandHandling {}

@MainActor
struct ApplicationShellActions {
    private let updates: any ApplicationUpdateCommandHandling
    private let openSettingsAction: () -> Void
    private let quitAction: () -> Void
    private let exportDiagnosticsAction: () -> Void
    private let clearDiagnosticsAction: () -> Void
    private let verifyAudioAction: () -> Void
    private let reconnectAudioAction: () -> Void
    private let runControlledTestAction: () -> Void

    init(
        updates: any ApplicationUpdateCommandHandling,
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void,
        exportDiagnostics: @escaping () -> Void = {},
        clearDiagnostics: @escaping () -> Void = {},
        verifyAudio: @escaping () -> Void = {},
        reconnectAudio: @escaping () -> Void = {},
        runControlledTest: @escaping () -> Void = {}
    ) {
        self.updates = updates
        openSettingsAction = openSettings
        quitAction = quit
        exportDiagnosticsAction = exportDiagnostics
        clearDiagnosticsAction = clearDiagnostics
        verifyAudioAction = verifyAudio
        reconnectAudioAction = reconnectAudio
        runControlledTestAction = runControlledTest
    }

    func checkForUpdates() async {
        await updates.checkManually()
    }

    @discardableResult
    func viewRelease(_ update: KnownAvailableUpdate) -> Bool {
        updates.openRelease(update)
    }

    func openSettings() {
        openSettingsAction()
    }

    func quit() {
        quitAction()
    }

    func exportDiagnostics() {
        exportDiagnosticsAction()
    }

    func clearDiagnostics() {
        clearDiagnosticsAction()
    }

    func verifyAudio() { verifyAudioAction() }

    func reconnectAudio() { reconnectAudioAction() }

    func runControlledTest() { runControlledTestAction() }
}
