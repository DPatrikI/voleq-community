// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreAudio
import SwiftUI
import VolEqMacAudio

@available(macOS 14.2, *)
struct UtilityWindowView<Model: VolEqControlSurfaceModel>: View {
    @ObservedObject var model: Model
    @ObservedObject var updates: UpdateController
    let openSettings: () -> Void

    var body: some View {
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
}

@available(macOS 14.2, *)
struct MenuBarControlSurface<Model: VolEqControlSurfaceModel>: View {
    @ObservedObject var model: Model
    @ObservedObject var updates: UpdateController
    let openSettings: () -> Void

    var body: some View {
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
                Button(action: openSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                Spacer()

                Button("Quit VolEq") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 360)
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

                if !compact || model.runtimeState == .failed {
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
            .disabled(model.isRunning)

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
                    .disabled(model.isRunning || model.processes.isEmpty)

                    Button {
                        model.refreshProcesses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh audio applications")
                    .disabled(model.isRunning)
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
                    .disabled(model.isRunning)
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
