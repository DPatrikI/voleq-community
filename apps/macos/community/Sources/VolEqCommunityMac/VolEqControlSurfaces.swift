// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreAudio
import SwiftUI
import VolEqMacAudio

@available(macOS 14.2, *)
struct UtilityWindowView<Model: VolEqControlSurfaceModel>: View {
    @ObservedObject var model: Model
    @ObservedObject var systemAudioAccess: SystemAudioAccessPresentationController
    @ObservedObject var updates: UpdateController
    let actions: ApplicationShellActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    VolEqMark(size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("VolEq")
                            .font(.system(size: 34, weight: .semibold))
                        Text("Automatic voice-volume leveling")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                RuntimeStatusView(model: model, compact: false)

                AudioSafetyActions(
                    model: model,
                    actions: actions
                )

                UpdateAvailableIndicator(
                    updates: updates,
                    actions: actions,
                    compact: false
                )

                if updates.isChecking {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking for updates…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Checking for updates")
                }

                Divider()

                CaptureControls(model: model, compact: false)

                CapturePrimaryActionButton(
                    model: model,
                    compact: false,
                    fillsWidth: true,
                    isDefaultAction: true
                )

                HStack {
                    NoSoundButton(systemAudioAccess: systemAudioAccess)
                    Spacer()
                    Button(action: actions.openSettings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(width: 500)
        }
        .frame(minWidth: 548, minHeight: 560)
    }
}

@available(macOS 14.2, *)
struct MenuBarControlSurface<Model: VolEqControlSurfaceModel>: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: Model
    @ObservedObject var systemAudioAccess: SystemAudioAccessPresentationController
    @ObservedObject var updates: UpdateController
    let actions: ApplicationShellActions
    let switchToWindow: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("VolEq")
                    .font(.title2.weight(.semibold))

                HStack(alignment: .center, spacing: 12) {
                    RuntimeStatusView(model: model, compact: true)
                    Spacer(minLength: 12)
                    CapturePrimaryActionButton(
                        model: model,
                        compact: true,
                        fillsWidth: false,
                        isDefaultAction: false
                    )
                }

                AudioSafetyActions(
                    model: model,
                    actions: actions
                )

                Divider()

                CaptureControls(model: model, compact: true)

                UpdateAvailableIndicator(
                    updates: updates,
                    actions: actions,
                    compact: true
                )

                Divider()

                HStack {
                    Button("Check for Updates…") {
                        Task { await actions.checkForUpdates() }
                    }
                    .accessibilityIdentifier("voleq.check-for-updates")
                    .buttonStyle(.plain)
                    .disabled(updates.isChecking)

                    if updates.isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking for updates")
                    }

                    Spacer()
                }

                HStack {
                    NoSoundButton(systemAudioAccess: systemAudioAccess)

                    Spacer()

                    Button("Switch to Window") {
                        MenuBarPresentationTransition.switchToWindow(
                            dismiss: { dismiss() },
                            activateWindow: switchToWindow
                        )
                    }
                    .accessibilityIdentifier("voleq.switch-to-window")
                    .buttonStyle(.plain)

                    Button(action: actions.openSettings) {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("voleq.open-settings")
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }

                Button("Quit VolEq") {
                    actions.quit()
                }
                .accessibilityIdentifier("voleq.quit")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: 320)
        }
        // MenuBarExtra does not derive a useful intrinsic height from a
        // ScrollView. A fixed, bounded viewport keeps the popover visible;
        // overflow remains reachable through vertical scrolling.
        .frame(width: 360, height: 560)
    }
}

@available(macOS 14.2, *)
private struct CapturePrimaryActionButton<Model: VolEqControlSurfaceModel>: View {
    @ObservedObject var model: Model
    let compact: Bool
    let fillsWidth: Bool
    let isDefaultAction: Bool

    @ViewBuilder
    var body: some View {
        if isDefaultAction {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

    private var button: some View {
        let presentation = model.capturePresentation
        return Button {
            model.toggle()
        } label: {
            Text(compact
                ? presentation.compactPrimaryActionTitle
                : presentation.primaryActionTitle)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!presentation.canPerformPrimaryAction)
        .accessibilityLabel(presentation.primaryActionTitle)
        .accessibilityIdentifier("voleq.primary-action")
    }
}

@MainActor
enum MenuBarPresentationTransition {
    static func switchToWindow(
        dismiss: () -> Void,
        activateWindow: @escaping @MainActor () -> Void
    ) {
        // Removing a MenuBarExtra while its popover is still open can leave
        // the popover orphaned on screen. Close it first, then change the
        // presentation mode after SwiftUI processes the dismissal.
        dismiss()
        DispatchQueue.main.async {
            activateWindow()
        }
    }
}

@available(macOS 14.2, *)
struct MenuBarStatusLabel<Model: VolEqControlSurfaceModel>: View {
    @ObservedObject var model: Model
    @ObservedObject var updates: UpdateController

    var body: some View {
        Image(nsImage: VolEqBrand.menuBarIcon)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let presentation = model.capturePresentation
        if let update = updates.knownAvailableUpdate {
            return "VolEq, \(presentation.runtimeTitle), version \(update.version) available"
        }
        return "VolEq, \(presentation.runtimeTitle)"
    }
}

@available(macOS 14.2, *)
private struct UpdateAvailableIndicator: View {
    @ObservedObject var updates: UpdateController
    let actions: ApplicationShellActions
    let compact: Bool

    var body: some View {
        if let update = updates.knownAvailableUpdate {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("VolEq \(update.version.description) is available")
                        .font(compact ? .callout.weight(.medium) : .headline)
                    if !compact {
                        Text("VolEq will open GitHub; it never downloads or installs updates.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Button("View Release…") {
                    actions.viewRelease(update)
                }
            }
            .padding(compact ? 10 : 12)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
        }
    }
}

@available(macOS 14.2, *)
private struct RuntimeStatusView<Model: VolEqControlSurfaceModel>: View {
    @ObservedObject var model: Model
    let compact: Bool

    var body: some View {
        let presentation = model.capturePresentation
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(presentation.statusTone.color)
                .frame(width: compact ? 10 : 12, height: compact ? 10 : 12)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(presentation.runtimeTitle)
                    .font(compact ? .headline : .title2.weight(.semibold))
                Text(presentation.targetSummary)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !compact
                    || (model.captureState.runtimeState != .ready
                        && model.captureState.runtimeState != .active) {
                    Text(model.captureState.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityText)
        .accessibilityIdentifier("voleq.runtime-status")
    }
}

@available(macOS 14.2, *)
private struct AudioSafetyActions<Model: VolEqControlSurfaceModel>: View {
    @ObservedObject var model: Model
    let actions: ApplicationShellActions

    @ViewBuilder
    var body: some View {
        let accessState = model.captureState.systemAudioAccessState
        if case .actionRequired(.cleanupFailed) = accessState {
            VStack(alignment: .leading, spacing: 10) {
                Text("VolEq could not fully stop Core Audio resources. Quit VolEq before trying again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Quit VolEq") {
                    actions.quit()
                }
                .accessibilityIdentifier("voleq.cleanup-failure-quit")
            }
            .padding(12)
            .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct NoSoundButton: View {
    @ObservedObject var systemAudioAccess: SystemAudioAccessPresentationController

    var body: some View {
        Button("No sound?") {
            systemAudioAccess.presentNoSoundHelp()
        }
        .accessibilityIdentifier("voleq.no-sound-help")
        .buttonStyle(.plain)
        .help("Troubleshoot System Audio Recording permission")
    }
}

@available(macOS 14.2, *)
private struct CaptureControls<Model: VolEqControlSurfaceModel>: View {
    @ObservedObject var model: Model
    let compact: Bool

    var body: some View {
        let presentation = model.capturePresentation
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            Text("Capture")
                .font(compact ? .headline : .title3.weight(.semibold))

            Picker("Capture", selection: $model.mode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(presentation.controlsLocked)

            if model.mode == .application {
                HStack(spacing: 8) {
                    Picker("Application", selection: $model.selectedProcessID) {
                        if model.processes.isEmpty {
                            Text("No active audio applications").tag(nil as AudioObjectID?)
                        }
                        ForEach(model.processes) { process in
                            Text(process.label).tag(process.id as AudioObjectID?)
                        }
                    }
                    .disabled(presentation.controlsLocked || model.processes.isEmpty)

                    Button {
                        model.refreshProcesses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh audio applications")
                    .disabled(presentation.controlsLocked)
                }
            } else if !compact {
                Text("Includes the current output mix from every application except VolEq.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Speech-aware leveling")
                    if !compact {
                        Text("Quiet voices are lifted while loud voices stay controlled, with mild noise suppression.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Toggle("Speech-aware leveling", isOn: $model.speechAwarenessEnabled)
                    .labelsHidden()
                    .disabled(presentation.controlsLocked)
            }
        }
        .accessibilityIdentifier("voleq.capture-controls")
    }
}

private struct VolEqMark: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: VolEqBrand.applicationIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
