// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreAudio
import Foundation
import VolEqCore

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
    @Published public var speechAwarenessEnabled = true
    @Published public var levelingSettings = LevelingSettings() {
        didSet { audioProcessor?.updateSettings(levelingSettings) }
    }
    @Published public private(set) var isRunning = false
    @Published public private(set) var status = "Choose an audio-producing app, then start."

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioProcessor: AudioIOProcessor?
    private var activeOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var activeOutputListener: AudioObjectPropertyListenerBlock?
    private var activeOutputListenerAddresses: [AudioObjectPropertyAddress] = []
    // Swift deinitializers are nonisolated. All mutation still occurs on the
    // main actor; this annotation only lets deinit unregister the retained
    // Core Audio block after actor-isolated use has ended.
    nonisolated(unsafe) private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var routeRecoveryTask: Task<Void, Never>?
    private var processingDiagnosticsTask: Task<Void, Never>?
    private let stopResourcesDidRun: (() -> Void)?
    private let startPipelineOverride: (@MainActor () -> Void)?
    private let routeRecoveryDelayNanoseconds: UInt64
    private let ioQueue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.audio",
        qos: .userInteractive
    )
    private let routeQueue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.audio-route",
        qos: .userInitiated
    )

    public convenience init() {
        self.init(installSystemObservers: true)
    }

    init(
        installSystemObservers: Bool,
        initiallyRunning: Bool = false,
        stopResourcesDidRun: (() -> Void)? = nil,
        startPipelineOverride: (@MainActor () -> Void)? = nil,
        routeRecoveryDelayNanoseconds: UInt64 = 350_000_000
    ) {
        isRunning = initiallyRunning
        self.stopResourcesDidRun = stopResourcesDidRun
        self.startPipelineOverride = startPipelineOverride
        self.routeRecoveryDelayNanoseconds = routeRecoveryDelayNanoseconds
        if installSystemObservers {
            refreshProcesses()
            do {
                try installDefaultOutputListener()
            } catch {
                status = error.localizedDescription
            }
        }
    }

    deinit {
        guard let defaultOutputListener else { return }
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            routeQueue,
            defaultOutputListener
        )
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
        routeRecoveryTask?.cancel()
        routeRecoveryTask = nil
        startPipeline()
    }

    private func startPipeline() {
        if let startPipelineOverride {
            startPipelineOverride()
            return
        }
        stopResources()

        do {
            // Verify the local model before a muting process tap exists. Analyzer
            // and resampler states are then prepared before AudioDeviceStart.
            let speechModel = speechAwarenessEnabled
                ? try AudioIOProcessor.loadSpeechModel()
                : nil
            let outputDeviceID = try defaultOutputDevice()
            let outputUID = try readString(
                objectID: outputDeviceID,
                selector: kAudioDevicePropertyDeviceUID
            )
            try installActiveOutputListeners(for: outputDeviceID)

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
                // Per AudioHardware.h, this makes AudioDeviceStart wait for
                // tapped audio; it does not start the tap when the aggregate
                // is created. Prepared analyzers exist before AudioDeviceStart.
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

            // The I/O callback belongs to the aggregate device. Its input stream
            // can already be rate-adjusted by Core Audio's tap drift compensation,
            // so the tap's advertised format is not necessarily the format of
            // `inputData`. Configuring another converter from the tap format can
            // double-resample Bluetooth audio and produce metallic/robotic output.
            let callbackInputFormat: AudioStreamBasicDescription = try readValue(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyStreamFormat,
                scope: kAudioDevicePropertyScopeInput
            )
            let outputFormat: AudioStreamBasicDescription = try readValue(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyStreamFormat,
                scope: kAudioDevicePropertyScopeOutput
            )
            try validateFloat32(callbackInputFormat, label: "Captured audio")
            try validateFloat32(outputFormat, label: "Output device")
            try validateSupportedChannelLayout(callbackInputFormat, label: "Captured audio")
            try validateSupportedChannelLayout(outputFormat, label: "Output device")
            let processor = try AudioIOProcessor(
                inputFormat: callbackInputFormat,
                outputFormat: outputFormat,
                settings: levelingSettings,
                speechAwarenessEnabled: speechAwarenessEnabled,
                speechModel: speechModel,
                systemContentAnalysisEnabled: speechAwarenessEnabled
            )
            audioProcessor = processor
            var newIOProcID: AudioDeviceIOProcID?
            try requireNoErr(
                AudioDeviceCreateIOProcIDWithBlock(
                    &newIOProcID,
                    aggregateDeviceID,
                    ioQueue
                ) { _, inputData, inputTime, outputData, outputTime in
                    processor.process(
                        input: inputData,
                        inputTime: inputTime.pointee,
                        output: outputData,
                        outputTime: outputTime.pointee
                    )
                },
                "Create audio processing callback"
            )
            ioProcID = newIOProcID
            try requireNoErr(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                "Start audio processing"
            )

            isRunning = true
            let routeStatus = processor.usesSampleRateConversion
                ? " Resolving route timing (\(Int(processor.inputSampleRate))→\(Int(processor.outputSampleRate)) Hz labels)…"
                : ""
            let runningStatus: String
            if mode == .application,
               let process = processes.first(where: { $0.id == selectedProcessID }) {
                runningStatus = "Leveling \(process.name) on the current output device."
            } else {
                runningStatus = "Leveling the device-wide mix. VolEq excludes itself to avoid feedback."
            }
            status = runningStatus + routeStatus
            scheduleProcessingDiagnostics(for: processor, runningStatus: runningStatus)
        } catch {
            stopResources()
            isRunning = false
            status = error.localizedDescription
        }
    }

    public func stop() {
        routeRecoveryTask?.cancel()
        routeRecoveryTask = nil
        stopResources()
        isRunning = false
        status = "Stopped. Original application audio is restored."
    }

    private func stopResources() {
        processingDiagnosticsTask?.cancel()
        processingDiagnosticsTask = nil
        removeActiveOutputListeners()
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
        audioProcessor = nil
        stopResourcesDidRun?()
    }

    private func scheduleProcessingDiagnostics(
        for processor: AudioIOProcessor,
        runningStatus: String
    ) {
        processingDiagnosticsTask?.cancel()
        processingDiagnosticsTask = Task { @MainActor [weak self] in
            var diagnosticsRecorded = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled, self.audioProcessor === processor else {
                    return
                }
                if self.recoverPendingProcessingFailure(from: processor) {
                    return
                }
                guard !diagnosticsRecorded,
                      let diagnostics = processor.currentDiagnostics() else { continue }

                switch diagnostics.path {
                case .directAggregateClock:
                    if processor.usesSampleRateConversion {
                        self.status = runningStatus
                            + " Core Audio synchronized this route "
                            + "(\(diagnostics.inputFrameCount)→\(diagnostics.outputFrameCount) frames); "
                            + "duplicate conversion is bypassed."
                    } else {
                        self.status = runningStatus
                    }
                case .sampleRateConverter:
                    self.status = runningStatus
                        + " Output conversion is active "
                        + "(\(diagnostics.inputFrameCount)→\(diagnostics.outputFrameCount) callback frames; "
                        + "\(Int(processor.inputSampleRate))→\(Int(processor.outputSampleRate)) Hz)."
                }
                diagnosticsRecorded = true
            }
            self?.processingDiagnosticsTask = nil
        }
    }

    private func installDefaultOutputListener() throws {
        guard defaultOutputListener == nil else { return }
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleOutputRouteChange()
            }
        }
        try requireNoErr(
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                routeQueue,
                listener
            ),
            "Observe the default output device"
        )
        defaultOutputListener = listener
    }

    private func installActiveOutputListeners(for deviceID: AudioObjectID) throws {
        removeActiveOutputListeners()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleOutputRouteChange()
            }
        }
        let addresses = [
            propertyAddress(kAudioDevicePropertyDeviceIsAlive),
            propertyAddress(kAudioDevicePropertyNominalSampleRate),
            propertyAddress(
                kAudioDevicePropertyStreamFormat,
                scope: kAudioDevicePropertyScopeOutput
            )
        ]

        var installed: [AudioObjectPropertyAddress] = []
        do {
            for var address in addresses {
                try requireNoErr(
                    AudioObjectAddPropertyListenerBlock(
                        deviceID,
                        &address,
                        routeQueue,
                        listener
                    ),
                    "Observe output-device changes"
                )
                installed.append(address)
            }
        } catch {
            for var address in installed {
                AudioObjectRemovePropertyListenerBlock(
                    deviceID,
                    &address,
                    routeQueue,
                    listener
                )
            }
            throw error
        }

        activeOutputDeviceID = deviceID
        activeOutputListener = listener
        activeOutputListenerAddresses = installed
    }

    private func removeActiveOutputListeners() {
        guard
            activeOutputDeviceID != kAudioObjectUnknown,
            let activeOutputListener
        else {
            activeOutputListenerAddresses.removeAll(keepingCapacity: true)
            activeOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
            return
        }
        for var address in activeOutputListenerAddresses {
            AudioObjectRemovePropertyListenerBlock(
                activeOutputDeviceID,
                &address,
                routeQueue,
                activeOutputListener
            )
        }
        activeOutputListenerAddresses.removeAll(keepingCapacity: true)
        activeOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
        self.activeOutputListener = nil
    }

    private func handleOutputRouteChange() {
        guard isRunning else {
            status = processes.isEmpty
                ? "No app is producing audio yet. Start meeting audio, then refresh."
                : "Ready. Audio will use the current default output device."
            return
        }

        routeRecoveryTask?.cancel()
        stopResources()
        status = "The output device changed. Reconnecting safely…"
        let recoveryDelayNanoseconds = routeRecoveryDelayNanoseconds
        routeRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: recoveryDelayNanoseconds)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.routeRecoveryTask = nil
            self.startPipeline()
        }
    }

#if DEBUG
    func _testOnlyHandleOutputRouteChange() {
        handleOutputRouteChange()
    }
#endif

    @discardableResult
    func recoverPendingProcessingFailure(from processor: AudioIOProcessor) -> Bool {
        guard let failure = processor.takePendingFailure() else { return false }
        recoverFromProcessingFailure(failure)
        return true
    }

    private func recoverFromProcessingFailure(_ conversionStatus: OSStatus) {
        stopResources()
        isRunning = false
        let operation = conversionStatus == speechAnalysisFailed
            ? "Analyze speech locally"
            : "Convert audio for the output device"
        let error = VolEqError.coreAudio(
            operation: operation,
            status: conversionStatus
        )
        status = "\(error.localizedDescription) Original audio was restored. Try starting again."
    }

}
