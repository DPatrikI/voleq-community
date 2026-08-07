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
    let openSettings: () -> Void

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

                AudioAccessActions(
                    model: model,
                    systemAudioAccess: systemAudioAccess,
                    compact: false
                )

                UpdateAvailableIndicator(updates: updates, compact: false)

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

                Button {
                    model.toggle()
                } label: {
                    Text(model.isRunning ? "Stop Leveling" : "Start Leveling")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.isRunning && !model.canStart)
                .keyboardShortcut(.defaultAction)

                HStack {
                    Spacer()
                    Button(action: openSettings) {
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
    let openSettings: () -> Void
    let switchToWindow: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("VolEq")
                    .font(.title2.weight(.semibold))

                HStack(alignment: .center, spacing: 12) {
                    RuntimeStatusView(model: model, compact: true)
                    Spacer(minLength: 12)
                    Button(model.isRunning ? "Stop" : "Start") {
                        model.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.isRunning && !model.canStart)
                }

                AudioAccessActions(
                    model: model,
                    systemAudioAccess: systemAudioAccess,
                    compact: true
                )

                Divider()

                CaptureControls(model: model, compact: true)

                UpdateAvailableIndicator(updates: updates, compact: true)

                Divider()

                HStack {
                    Button("Check for Updates…") {
                        Task { await updates.checkManually() }
                    }
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
                    Button("Switch to Window") {
                        MenuBarPresentationTransition.switchToWindow(
                            dismiss: { dismiss() },
                            activateWindow: switchToWindow
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: openSettings) {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }

                Button("Quit VolEq") {
                    NSApp.terminate(nil)
                }
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
        if let update = updates.knownAvailableUpdate {
            return "VolEq, \(model.runtimeTitle), version \(update.version) available"
        }
        return "VolEq, \(model.runtimeTitle)"
    }
}

@available(macOS 14.2, *)
private struct UpdateAvailableIndicator: View {
    @ObservedObject var updates: UpdateController
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
                    _ = updates.openRelease(update)
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(model.statusColor)
                .frame(width: compact ? 10 : 12, height: compact ? 10 : 12)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(model.runtimeTitle)
                    .font(compact ? .headline : .title2.weight(.semibold))
                Text(model.targetSummary)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !compact
                    || (model.runtimeState != .ready
                        && model.runtimeState != .active) {
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@available(macOS 14.2, *)
private struct AudioAccessActions<Model: VolEqControlSurfaceModel>: View {
    @ObservedObject var model: Model
    @ObservedObject var systemAudioAccess: SystemAudioAccessPresentationController
    let compact: Bool

    @ViewBuilder
    var body: some View {
        switch model.systemAudioAccessState {
        case .checking:
            VStack(alignment: .leading, spacing: 8) {
                Text("Keep the selected audio playing. VolEq is not changing the original output while access is checked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Cancel") {
                    model.cancelAudioAccessCheck()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
            .padding(compact ? 10 : 12)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case let .actionRequired(issue):
            VStack(alignment: .leading, spacing: 10) {
                Text(issue == .cleanupFailed
                    ? "VolEq could not fully stop Core Audio resources. Quit VolEq before trying again."
                    : "System Audio Recording permission is required to process playback. Audio is processed in memory and is never saved or uploaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if issue == .cleanupFailed {
                    Button("Quit VolEq") {
                        NSApp.terminate(nil)
                    }
                } else {
                    HStack {
                        Button("Open System Settings…") {
                            systemAudioAccess.openSystemAudioRecordingSettings()
                        }
                        Button("Check Again") {
                            model.checkAudioAccessAgain()
                        }
                        .disabled(model.isCheckingAudioAccess)
                    }
                    if let fallback = systemAudioAccess.settingsFallbackMessage {
                        Text(fallback)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("If macOS asks you to quit and reopen VolEq after changing access, do that before choosing Check Again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(compact ? 10 : 12)
            .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .notRequested, .explanationRequired, .verified:
            EmptyView()
        }
    }
}

@available(macOS 14.2, *)
private struct CaptureControls<Model: VolEqControlSurfaceModel>: View {
    @ObservedObject var model: Model
    let compact: Bool

    var body: some View {
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
            .disabled(model.controlsLocked)

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
                    .disabled(model.controlsLocked || model.processes.isEmpty)

                    Button {
                        model.refreshProcesses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh audio applications")
                    .disabled(model.controlsLocked)
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
                    .disabled(model.controlsLocked)
            }
        }
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
