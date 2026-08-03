// SPDX-License-Identifier: MPL-2.0

import SwiftUI

@available(macOS 14.2, *)
struct PresentationSettingsView: View {
    @ObservedObject var presentation: MacPresentationController

    var body: some View {
        Form {
            Section("Presentation") {
                Picker("Presentation", selection: $presentation.mode) {
                    ForEach(MacPresentationMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
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
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 520, height: 260)
    }
}
