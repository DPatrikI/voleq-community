// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import VolEqCore

@MainActor
final class AudioCaptureProcessSession {
    private let catalog: any AudioProcessCatalog

    private(set) var processes: [AudioProcess] = []
    private(set) var selectedProcessID: AudioObjectID?
    private var requiresExplicitApplicationSelection = false

    init(catalog: any AudioProcessCatalog) {
        self.catalog = catalog
    }

    func refresh(
        currentSelection: AudioObjectID?,
        mode: CaptureMode,
        preservingRecoveryFailure: Bool,
        isCurrent: @MainActor () -> Bool
    ) async throws {
        let selectedIdentity = currentSelection.flatMap { selectedID in
            processes.first(where: { $0.id == selectedID })
        }.map(ApplicationCaptureIdentity.init(process:))
        let hadUnresolvedSelection = currentSelection != nil
            && selectedIdentity == nil
        let refreshed: [AudioProcess]
        do {
            refreshed = try await catalog.activeOutputProcesses()
        } catch {
            guard isCurrent(), !Task.isCancelled else {
                throw CancellationError()
            }
            throw error
        }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        processes = refreshed
        if let selectedIdentity {
            switch ApplicationCaptureTargetResolver.resolve(
                identity: selectedIdentity,
                processes: processes
            ) {
            case let .resolved(process):
                selectedProcessID = process.id
            case .missing, .ambiguous:
                selectedProcessID = nil
                if mode == .application {
                    requiresExplicitApplicationSelection = true
                }
            }
        } else if hadUnresolvedSelection {
            selectedProcessID = nil
            if mode == .application {
                requiresExplicitApplicationSelection = true
            }
        } else {
            selectedProcessID = nil
        }
        if selectedProcessID == nil,
           !preservingRecoveryFailure,
           !requiresExplicitApplicationSelection {
            selectedProcessID = processes.first?.id
        }
    }

    func resolveFresh(
        _ intent: CaptureIntent,
        isCurrent: @MainActor () -> Bool
    ) async throws -> ResolvedCaptureIntent {
        guard intent.mode == .application else {
            return ResolvedCaptureIntent(intent: intent, target: .deviceWide)
        }

        let refreshed: [AudioProcess]
        do {
            refreshed = try await catalog.activeOutputProcesses()
        } catch {
            guard isCurrent(), !Task.isCancelled else {
                throw CancellationError()
            }
            throw error
        }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        processes = refreshed
        guard let identity = intent.application else {
            requireExplicitApplicationSelection()
            throw VolEqError.noProcessSelected
        }

        let process: AudioProcess
        switch ApplicationCaptureTargetResolver.resolve(
            identity: identity,
            processes: processes
        ) {
        case let .resolved(value):
            process = value
        case .missing:
            requireExplicitApplicationSelection()
            throw RecoveryFailure.applicationMissing(identity.displayName)
        case .ambiguous:
            requireExplicitApplicationSelection()
            throw RecoveryFailure.applicationAmbiguous(identity.displayName)
        }

        let resolvedIntent = CaptureIntent(
            mode: intent.mode,
            speechAwarenessEnabled: intent.speechAwarenessEnabled,
            levelingSettings: intent.levelingSettings,
            application: ApplicationCaptureIdentity(
                processObjectID: process.id,
                pid: process.pid,
                bundleID: process.bundleID,
                displayName: process.name
            )
        )
        selectedProcessID = process.id
        return ResolvedCaptureIntent(
            intent: resolvedIntent,
            target: .application(process)
        )
    }

    func clearExplicitSelectionRequirement() {
        requiresExplicitApplicationSelection = false
    }

    func requireExplicitApplicationSelection() {
        selectedProcessID = nil
        requiresExplicitApplicationSelection = true
    }
}

private extension ApplicationCaptureIdentity {
    init(process: AudioProcess) {
        self.init(
            processObjectID: process.id,
            pid: process.pid,
            bundleID: process.bundleID,
            displayName: process.name
        )
    }
}
