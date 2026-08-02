// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreAudio
import Darwin
import SwiftUI
import VolEqMacAudio
import VolEqSpeech

@main
@available(macOS 14.2, *)
struct VolEqCommunityMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var audio: AudioCaptureController

    init() {
        if ProcessInfo.processInfo.arguments.contains("--verify-speech-resources") {
            do {
                _ = try RNNoiseModelResource.bundled()
                print("[ok] packaged RNNoise model loaded")
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        _audio = StateObject(wrappedValue: AudioCaptureController())
    }

    var body: some Scene {
        WindowGroup("VolEq Community") {
            ContentView(audio: audio)
                .frame(width: 520)
                .fixedSize(horizontal: false, vertical: true)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@available(macOS 14.2, *)
struct ContentView: View {
    @ObservedObject var audio: AudioCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VolEq — Volume Equilibrium")
                .font(.largeTitle.weight(.semibold))
            Text("Automatic voice-volume leveling for online meetings")
                .foregroundStyle(.secondary)

            Picker("Capture", selection: $audio.mode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(audio.isRunning)

            Toggle("Speech-aware leveling", isOn: $audio.speechAwarenessEnabled)
                .disabled(audio.isRunning)
            Text(
                audio.speechAwarenessEnabled
                    ? "On: quiet gain is limited to detected speech."
                    : "Off: uses the leveler without speech recognition."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("Mild noise suppression", isOn: $audio.noiseSuppressionEnabled)
                .disabled(audio.isRunning || !audio.speechAwarenessEnabled)
            Text(
                !audio.speechAwarenessEnabled
                    ? "Available when speech-aware leveling is on."
                    : audio.noiseSuppressionEnabled
                        ? "On: gently reduces stationary noise while speech is active."
                        : "Off: speech-aware leveling stays active without denoising."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if audio.mode == .application {
                HStack {
                    Picker("Application", selection: $audio.selectedProcessID) {
                        if audio.processes.isEmpty {
                            Text("No active audio applications").tag(nil as AudioObjectID?)
                        }
                        ForEach(audio.processes) { process in
                            Text(process.label).tag(process.id as AudioObjectID?)
                        }
                    }
                    .disabled(audio.isRunning || audio.processes.isEmpty)

                    Button("Refresh") {
                        audio.refreshProcesses()
                    }
                    .disabled(audio.isRunning)
                }
            } else {
                Text("Device-wide captures the current output mix. System alerts and every app except VolEq are included.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(audio.isRunning ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
                Text(audio.status)
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer()
            }

            Button(audio.isRunning ? "Stop Leveling" : "Start Leveling") {
                audio.toggle()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!audio.isRunning && audio.mode == .application && audio.selectedProcessID == nil)

            Text("VolEq uses carefully chosen speech-leveling and mild-suppression presets. Advanced controls and automation are planned for VolEq Premium.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
    }
}
