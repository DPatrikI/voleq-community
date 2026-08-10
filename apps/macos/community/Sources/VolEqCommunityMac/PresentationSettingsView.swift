// SPDX-License-Identifier: MPL-2.0

import SwiftUI

@available(macOS 14.2, *)
struct PresentationSettingsView: View {
    @ObservedObject var presentation: MacPresentationController
    @ObservedObject var updates: UpdateController
    let actions: ApplicationShellActions

    var body: some View {
        Form {
            Section("Presentation") {
                Picker("Presentation", selection: $presentation.mode) {
                    ForEach(MacPresentationMode.allCases) { mode in
                        HStack(spacing: 6) {
                            Text(mode.title)
                            Image(systemName: mode.systemImage)
                                .accessibilityHidden(true)
                        }
                        .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                Text(presentation.mode.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Label(
                    "Changing presentation does not interrupt leveling.",
                    systemImage: "waveform"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    )
                )

                Text(updates.automaticCheckExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(updates.lastCheckSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let update = updates.knownAvailableUpdate {
                            Button("View VolEq \(update.version.description) Release…") {
                                actions.viewRelease(update)
                            }
                            .buttonStyle(.link)
                        }
                    }

                    Spacer(minLength: 12)

                    if updates.isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking for updates")
                    }

                    Button("Check Now") {
                        Task { await actions.checkForUpdates() }
                    }
                    .disabled(updates.isChecking)
                    .accessibilityHint("Contacts GitHub to check the latest published VolEq release")
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 560, height: 480)
    }
}
