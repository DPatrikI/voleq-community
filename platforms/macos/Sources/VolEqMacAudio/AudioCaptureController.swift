// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreAudio
import Foundation
import VolEqCore
import VolEqDSP

public struct AudioProcess: Identifiable, Hashable {
    public let id: AudioObjectID
    public let pid: pid_t
    public let name: String
    public let bundleID: String

    public var label: String {
        bundleID.isEmpty ? name : "\(name) — \(bundleID)"
    }
}

public enum CaptureMode: String, CaseIterable, Identifiable {
    case application = "Application"
    case system = "Device-wide"

    public var id: Self { self }
}

@MainActor
@available(macOS 14.2, *)
public final class AudioCaptureController: ObservableObject {
    @Published public var processes: [AudioProcess] = []
    @Published public var selectedProcessID: AudioObjectID?
    @Published public var mode: CaptureMode = .application
    @Published public var levelingSettings = LevelingSettings() {
        didSet { processor?.updateSettings(levelingSettings) }
    }
    @Published public private(set) var isRunning = false
    @Published public private(set) var status = "Choose an audio-producing app, then start."

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var processor: DynamicsProcessor?
    private let ioQueue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.audio",
        qos: .userInteractive
    )

    public init() {
        refreshProcesses()
    }

    public func refreshProcesses() {
        do {
            let ids: [AudioObjectID] = try readArray(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList
            )
            let ownPID = getpid()
            var found: [AudioProcess] = []

            for id in ids {
                let pid: pid_t = try readValue(objectID: id, selector: kAudioProcessPropertyPID)
                guard pid != ownPID else { continue }
                let isProducingOutput: UInt32 = (try? readValue(
                    objectID: id,
                    selector: kAudioProcessPropertyIsRunningOutput
                )) ?? 0
                guard isProducingOutput != 0 else { continue }

                let bundleID = (try? readString(objectID: id, selector: kAudioProcessPropertyBundleID)) ?? ""
                let runningApp = NSRunningApplication(processIdentifier: pid)
                let name = runningApp?.localizedName
                    ?? bundleID.split(separator: ".").last.map(String.init)
                    ?? "Process \(pid)"
                found.append(AudioProcess(id: id, pid: pid, name: name, bundleID: bundleID))
            }

            processes = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if let selectedProcessID, !processes.contains(where: { $0.id == selectedProcessID }) {
                self.selectedProcessID = nil
            }
            if selectedProcessID == nil {
                selectedProcessID = processes.first?.id
            }
            if !isRunning {
                status = processes.isEmpty
                    ? "No app is producing audio yet. Start meeting audio, then refresh."
                    : "Ready. Audio will stay on your current default output device."
            }
        } catch {
            status = error.localizedDescription
        }
    }

    public func toggle() {
        isRunning ? stop() : start()
    }

    public func start() {
        guard !isRunning else { return }
        stopResources()

        do {
            let outputDeviceID = try defaultOutputDevice()
            let outputUID = try readString(
                objectID: outputDeviceID,
                selector: kAudioDevicePropertyDeviceUID
            )

            let description = CATapDescription()
            description.name = "VolEq Capture"
            description.isPrivate = true
            description.isMixdown = true
            description.isMono = false
            description.muteBehavior = .mutedWhenTapped
            description.deviceUID = outputUID

            switch mode {
            case .application:
                guard let selectedProcessID else { throw VolEqError.noProcessSelected }
                description.processes = [selectedProcessID]
                description.isExclusive = false
            case .system:
                guard let ownProcess = try processObject(for: getpid()) else {
                    throw VolEqError.missingValue(
                        "VolEq could not exclude itself from device-wide capture, so it stopped to prevent feedback. Try again."
                    )
                }
                description.processes = [ownProcess]
                description.isExclusive = true
            }

            var newTapID = AudioObjectID(kAudioObjectUnknown)
            try requireNoErr(
                AudioHardwareCreateProcessTap(description, &newTapID),
                "Create process tap"
            )
            tapID = newTapID

            let tapUID = try readString(objectID: tapID, selector: kAudioTapPropertyUID)
            let aggregateUID = "com.patrikistvandoczy.voleq.community.aggregate.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "VolEq Private Audio Device",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceInputChannelsKey: 0
                ]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]

            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            try requireNoErr(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
                "Create private aggregate device"
            )
            aggregateDeviceID = newAggregateID

            let tapFormat: AudioStreamBasicDescription = try readValue(
                objectID: tapID,
                selector: kAudioTapPropertyFormat
            )
            let outputFormat: AudioStreamBasicDescription = try readValue(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyStreamFormat,
                scope: kAudioDevicePropertyScopeOutput
            )
            try validateFloat32(tapFormat, label: "Captured audio")
            try validateFloat32(outputFormat, label: "Output device")
            try validateSupportedChannelLayout(tapFormat, label: "Captured audio")
            try validateSupportedChannelLayout(outputFormat, label: "Output device")
            guard abs(tapFormat.mSampleRate - outputFormat.mSampleRate) < 1 else {
                throw VolEqError.unsupportedFormat("The capture and output sample rates do not match.")
            }

            let processor = DynamicsProcessor(
                sampleRate: tapFormat.mSampleRate,
                settings: levelingSettings
            )
            self.processor = processor
            var newIOProcID: AudioDeviceIOProcID?
            try requireNoErr(
                AudioDeviceCreateIOProcIDWithBlock(
                    &newIOProcID,
                    aggregateDeviceID,
                    ioQueue
                ) { _, inputData, _, outputData, _ in
                    processor.process(input: inputData, output: outputData)
                },
                "Create audio processing callback"
            )
            ioProcID = newIOProcID
            try requireNoErr(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                "Start audio processing"
            )

            isRunning = true
            if mode == .application,
               let process = processes.first(where: { $0.id == selectedProcessID }) {
                status = "Leveling \(process.name) on the current output device."
            } else {
                status = "Leveling the device-wide mix. VolEq excludes itself to avoid feedback."
            }
        } catch {
            stopResources()
            isRunning = false
            status = error.localizedDescription
        }
    }

    public func stop() {
        stopResources()
        isRunning = false
        status = "Stopped. Original application audio is restored."
    }

    private func stopResources() {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        processor = nil
    }

}
