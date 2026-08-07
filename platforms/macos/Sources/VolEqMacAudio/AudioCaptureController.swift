// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreAudio
import Foundation
import VolEqCore
import VolEqSpeech

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

public enum CaptureRuntimeState: Equatable, Sendable {
    case stopped
    case ready
    case preparing
    case checkingAccess
    case active
    case recovering
    case permissionRequired
    case failed
}

enum AudioCaptureTeardownStep: Equatable {
    case activeOutputListeners
    case stopIOProc
    case destroyIOProc
    case destroyAggregate
    case destroyTap
}

@available(macOS 14.2, *)
struct AudioCaptureResourceOperations: @unchecked Sendable {
    let stop: (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus
    let destroyIOProc: (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus
    let destroyAggregate: (AudioObjectID) -> OSStatus
    let destroyTap: (AudioObjectID) -> OSStatus

    static let live = AudioCaptureResourceOperations(
        stop: AudioDeviceStop,
        destroyIOProc: { deviceID, ioProcID in
            guard let ioProcID else { return kAudio_ParamError }
            return AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        },
        destroyAggregate: AudioHardwareDestroyAggregateDevice,
        destroyTap: AudioHardwareDestroyProcessTap
    )
}

private struct PreparedCaptureStart {
    let speechModel: RNNoiseModelResource?
    let outputDeviceID: AudioObjectID
    let outputDeviceUID: String
    let outputFormat: AudioStreamBasicDescription
    let probeTarget: SystemAudioPermissionProbeConfiguration.Target
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
    @Published public private(set) var runtimeState: CaptureRuntimeState = .stopped
    @Published public private(set) var systemAudioAccessState: SystemAudioAccessState = .notRequested
    @Published public private(set) var status = "Choose an audio-producing app, then start."

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioProcessor: AudioIOProcessor?
    private var activeOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
    nonisolated(unsafe) private var activeOutputListener: AudioObjectPropertyListenerBlock?
    private var activeOutputListenerAddresses: [AudioObjectPropertyAddress] = []
    // Swift deinitializers are nonisolated. All mutation still occurs on the
    // main actor; this annotation only lets deinit unregister the retained
    // Core Audio block after actor-isolated use has ended.
    nonisolated(unsafe) private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var routeRecoveryTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var processingDiagnosticsTask: Task<Void, Never>?
    private var permissionProbe: (any SystemAudioPermissionProbing)?
    private let stopResourcesDidRun: (() -> Void)?
    private let startPipelineOverride: (@MainActor (AudioCaptureController) throws -> Void)?
    private let teardownStepRecorder: ((AudioCaptureTeardownStep) -> Void)?
    private let loadProcessesOverride: (@MainActor () throws -> [AudioProcess])?
    private let permissionExplanationRequest: @MainActor () async -> Bool
    private let permissionProbeFactory: @MainActor (
        SystemAudioPermissionProbeConfiguration
    ) throws -> any SystemAudioPermissionProbing
    private let routeRecoveryDelayNanoseconds: UInt64
    private let resourceOperations: AudioCaptureResourceOperations
    private var processRefreshFailed = false
    private var ioCallbackStarted = false
    private var testOnlyHasSimulatedIOProc = false
    private var startupGeneration: UInt64 = 0
    private let ioQueue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.audio",
        qos: .userInteractive
    )
    private let routeQueue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.audio-route",
        qos: .userInitiated
    )

    public convenience init(
        permissionExplanationRequest: @escaping @MainActor () async -> Bool = { true }
    ) {
        self.init(
            installSystemObservers: true,
            permissionExplanationRequest: permissionExplanationRequest
        )
    }

    init(
        installSystemObservers: Bool,
        initiallyRunning: Bool = false,
        stopResourcesDidRun: (() -> Void)? = nil,
        startPipelineOverride: (@MainActor (AudioCaptureController) throws -> Void)? = nil,
        teardownStepRecorder: ((AudioCaptureTeardownStep) -> Void)? = nil,
        loadProcessesOverride: (@MainActor () throws -> [AudioProcess])? = nil,
        permissionExplanationRequest: @escaping @MainActor () async -> Bool = { true },
        permissionProbeFactory: (@MainActor (
            SystemAudioPermissionProbeConfiguration
        ) throws -> any SystemAudioPermissionProbing)? = nil,
        routeRecoveryDelayNanoseconds: UInt64 = 350_000_000,
        resourceOperations: AudioCaptureResourceOperations = .live
    ) {
        isRunning = initiallyRunning
        runtimeState = initiallyRunning ? .active : .stopped
        self.stopResourcesDidRun = stopResourcesDidRun
        self.startPipelineOverride = startPipelineOverride
        self.teardownStepRecorder = teardownStepRecorder
        self.loadProcessesOverride = loadProcessesOverride
        self.permissionExplanationRequest = permissionExplanationRequest
        self.permissionProbeFactory = permissionProbeFactory ?? { configuration in
            try CoreAudioSystemPermissionProbe(configuration: configuration)
        }
        self.routeRecoveryDelayNanoseconds = routeRecoveryDelayNanoseconds
        self.resourceOperations = resourceOperations
        if installSystemObservers {
            refreshProcesses()
            do {
                try installDefaultOutputListener()
            } catch {
                processRefreshFailed = false
                runtimeState = .failed
                status = error.localizedDescription
            }
        }
    }

    deinit {
        routeRecoveryTask?.cancel()
        startupTask?.cancel()
        processingDiagnosticsTask?.cancel()

        if activeOutputDeviceID != kAudioObjectUnknown,
           let activeOutputListener {
            for var address in activeOutputListenerAddresses {
                AudioObjectRemovePropertyListenerBlock(
                    activeOutputDeviceID,
                    &address,
                    routeQueue,
                    activeOutputListener
                )
            }
        }

        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID,
           resourceOperations.stop(aggregateDeviceID, ioProcID) == noErr,
           resourceOperations.destroyIOProc(aggregateDeviceID, ioProcID) == noErr {
            self.ioProcID = nil
        }
        if ioProcID == nil, aggregateDeviceID != kAudioObjectUnknown,
           resourceOperations.destroyAggregate(aggregateDeviceID) == noErr {
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if aggregateDeviceID == kAudioObjectUnknown,
           tapID != kAudioObjectUnknown,
           resourceOperations.destroyTap(tapID) == noErr {
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

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
            let found = try loadProcessesOverride?() ?? readActiveProcesses()

            processes = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if let selectedProcessID, !processes.contains(where: { $0.id == selectedProcessID }) {
                self.selectedProcessID = nil
            }
            if selectedProcessID == nil {
                selectedProcessID = processes.first?.id
            }
            let canReplaceDiagnostic = runtimeState != .failed || processRefreshFailed
            processRefreshFailed = false
            if !isRunning,
               startupTask == nil,
               permissionProbe == nil,
               systemAudioAccessState != .explanationRequired,
               !isPermissionActionRequired,
               canReplaceDiagnostic {
                runtimeState = .ready
                status = processes.isEmpty
                    ? "No app is producing audio yet. Start meeting audio, then refresh."
                    : "Ready. Audio will stay on your current default output device."
            }
        } catch {
            processRefreshFailed = true
            runtimeState = .failed
            status = error.localizedDescription
        }
    }

    private func readActiveProcesses() throws -> [AudioProcess] {
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
        return found
    }

    public func toggle() {
        isRunning ? stop() : start()
    }

    public func start() {
        guard !isRunning, startupTask == nil, permissionProbe == nil else { return }
        processRefreshFailed = false
        routeRecoveryTask?.cancel()
        routeRecoveryTask = nil
        beginSafeStart(isRecovery: false)
    }

    public func checkAudioAccessAgain() {
        guard !isRunning, startupTask == nil, permissionProbe == nil else { return }
        beginSafeStart(isRecovery: false)
    }

    public func cancelAudioAccessCheck() {
        guard runtimeState == .checkingAccess || permissionProbe != nil else { return }
        startupGeneration &+= 1
        permissionProbe?.cancel()
        let probeCleanupSucceeded = permissionProbe?.isTornDown ?? true
        if probeCleanupSucceeded {
            permissionProbe = nil
        }
        startupTask?.cancel()
        startupTask = nil
        let pipelineCleanupSucceeded = stopResources()
        isRunning = false
        if probeCleanupSucceeded && pipelineCleanupSucceeded {
            systemAudioAccessState = .notRequested
            runtimeState = .stopped
            status = "Audio access check cancelled. Processing did not start, and original audio remains unchanged."
        } else {
            systemAudioAccessState = .actionRequired(.cleanupFailed)
            runtimeState = .failed
            status = incompleteTeardownStatus
        }
    }

    private func beginSafeStart(isRecovery: Bool) {
        guard !isRunning, startupTask == nil, permissionProbe == nil else { return }
        runtimeState = .preparing

        let prepared: PreparedCaptureStart
        do {
            guard stopResources() else {
                isRunning = true
                runtimeState = .failed
                systemAudioAccessState = .actionRequired(.cleanupFailed)
                status = incompleteTeardownStatus
                return
            }
            prepared = try prepareCaptureStart()
        } catch {
            isRunning = false
            runtimeState = .failed
            systemAudioAccessState = .notRequested
            status = startupFailureStatus(for: error)
            return
        }

        startupGeneration &+= 1
        let generation = startupGeneration
        systemAudioAccessState = .explanationRequired
        status = isRecovery
            ? "The output route changed. Original audio is restored while VolEq prepares a safe access check."
            : "System Audio Recording access must be explained before VolEq can check it safely."

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let accepted = await self.permissionExplanationRequest()
            guard generation == self.startupGeneration, !Task.isCancelled else { return }

            guard accepted else {
                self.startupTask = nil
                self.systemAudioAccessState = .explanationRequired
                self.runtimeState = .stopped
                self.status = "Processing did not start. Original audio remains unchanged. Choose Start when you are ready to review System Audio Recording access."
                return
            }

            self.systemAudioAccessState = .checking
            self.runtimeState = .checkingAccess
            self.status = "Original audio remains unchanged while VolEq checks access. Keep the selected audio playing. This can take up to 30 seconds."

            let probe: any SystemAudioPermissionProbing
            do {
                probe = try self.permissionProbeFactory(
                    SystemAudioPermissionProbeConfiguration(
                        target: prepared.probeTarget,
                        outputDeviceUID: prepared.outputDeviceUID
                    )
                )
            } catch {
                self.startupTask = nil
                self.applyPermissionProbeOutcome(.coreAudioFailure(
                    operation: "Prepare audio-access verification",
                    status: kAudioHardwareUnspecifiedError
                ))
                return
            }

            self.permissionProbe = probe
            let outcome = await probe.verify()
            guard generation == self.startupGeneration, !Task.isCancelled else { return }
            self.startupTask = nil

            guard probe.isTornDown else {
                probe.cancel()
                self.permissionProbe = probe
                self.isRunning = false
                self.systemAudioAccessState = .actionRequired(.cleanupFailed)
                self.runtimeState = .failed
                self.status = self.incompleteTeardownStatus
                return
            }
            self.permissionProbe = nil

            guard outcome == .verified else {
                self.applyPermissionProbeOutcome(outcome)
                return
            }

            self.systemAudioAccessState = .verified
            self.startVerifiedPipeline(prepared)
        }
    }

    private func prepareCaptureStart() throws -> PreparedCaptureStart {
        if startPipelineOverride != nil {
            let target: SystemAudioPermissionProbeConfiguration.Target
            switch mode {
            case .application:
                target = .application(selectedProcessID ?? 1)
            case .system:
                target = .deviceWide(excluding: 1)
            }
            return PreparedCaptureStart(
                speechModel: nil,
                outputDeviceID: 1,
                outputDeviceUID: "test-output",
                outputFormat: AudioStreamBasicDescription(),
                probeTarget: target
            )
        }

        let probeTarget = try Self.resolvePermissionProbeTarget(
            mode: mode,
            selectedProcessID: selectedProcessID,
            processes: processes,
            ownProcessObject: { try processObject(for: getpid()) }
        )

        // All non-permission work that can be validated without a tap is done
        // before the explanatory alert or the system permission prompt.
        let speechModel = speechAwarenessEnabled
            ? try AudioIOProcessor.loadSpeechModel()
            : nil
        let outputDeviceID = try defaultOutputDevice()
        let outputDeviceUID = try readString(
            objectID: outputDeviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
        let outputFormat: AudioStreamBasicDescription = try readValue(
            objectID: outputDeviceID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeOutput
        )
        try validateFloat32(outputFormat, label: "Output device")
        try validateSupportedChannelLayout(outputFormat, label: "Output device")
        if speechAwarenessEnabled {
            _ = try RNNoiseFixedBlockSampleRate.sourceBlockFrameCount(
                for: outputFormat.mSampleRate
            )
        }

        return PreparedCaptureStart(
            speechModel: speechModel,
            outputDeviceID: outputDeviceID,
            outputDeviceUID: outputDeviceUID,
            outputFormat: outputFormat,
            probeTarget: probeTarget
        )
    }

    static func resolvePermissionProbeTarget(
        mode: CaptureMode,
        selectedProcessID: AudioObjectID?,
        processes: [AudioProcess],
        ownProcessObject: () throws -> AudioObjectID?
    ) throws -> SystemAudioPermissionProbeConfiguration.Target {
        switch mode {
        case .application:
            guard let selectedProcessID else { throw VolEqError.noProcessSelected }
            guard processes.contains(where: { $0.id == selectedProcessID }) else {
                throw VolEqError.missingValue(
                    "The selected application is no longer producing audio. Refresh and choose it again."
                )
            }
            return .application(selectedProcessID)
        case .system:
            guard let ownProcess = try ownProcessObject() else {
                throw VolEqError.missingValue(
                    "VolEq could not exclude itself from device-wide capture, so it stopped to prevent feedback. Try again."
                )
            }
            return .deviceWide(excluding: ownProcess)
        }
    }

    private func startVerifiedPipeline(_ prepared: PreparedCaptureStart) {
        runtimeState = .preparing
        do {
            if let startPipelineOverride {
                try startPipelineOverride(self)
                isRunning = true
                runtimeState = .active
                status = "Leveling is active after audio access was verified."
                return
            }

            let currentOutputDeviceID = try defaultOutputDevice()
            let currentOutputUID = try readString(
                objectID: currentOutputDeviceID,
                selector: kAudioDevicePropertyDeviceUID
            )
            let currentOutputFormat: AudioStreamBasicDescription = try readValue(
                objectID: currentOutputDeviceID,
                selector: kAudioDevicePropertyStreamFormat,
                scope: kAudioDevicePropertyScopeOutput
            )
            try validateFloat32(currentOutputFormat, label: "Output device")
            try validateSupportedChannelLayout(
                currentOutputFormat,
                label: "Output device"
            )
            if speechAwarenessEnabled {
                _ = try RNNoiseFixedBlockSampleRate.sourceBlockFrameCount(
                    for: currentOutputFormat.mSampleRate
                )
            }
            guard currentOutputDeviceID == prepared.outputDeviceID,
                  currentOutputUID == prepared.outputDeviceUID,
                  currentOutputFormat.mSampleRate == prepared.outputFormat.mSampleRate,
                  currentOutputFormat.mChannelsPerFrame == prepared.outputFormat.mChannelsPerFrame
            else {
                throw VolEqError.missingValue(
                    "The output route changed during audio-access verification. Processing did not start, and original audio remains unchanged. Check again on the current output."
                )
            }
            try installActiveOutputListeners(for: currentOutputDeviceID)

            let description = CATapDescription()
            description.name = "VolEq Capture"
            description.isPrivate = true
            description.isMixdown = true
            description.isMono = false
            description.muteBehavior = .mutedWhenTapped
            description.deviceUID = prepared.outputDeviceUID

            switch prepared.probeTarget {
            case let .application(processID):
                description.processes = [processID]
                description.isExclusive = false
            case let .deviceWide(ownProcess):
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
                kAudioAggregateDeviceMainSubDeviceKey: prepared.outputDeviceUID,
                kAudioAggregateDeviceSubDeviceListKey: [[
                    kAudioSubDeviceUIDKey: prepared.outputDeviceUID,
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
                speechModel: prepared.speechModel,
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
            ioCallbackStarted = true

            isRunning = true
            runtimeState = .active
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
            let restored = stopResources()
            isRunning = !restored
            runtimeState = .failed
            if !restored {
                systemAudioAccessState = .actionRequired(.cleanupFailed)
            }
            status = restored
                ? startupFailureStatus(for: error)
                : incompleteTeardownStatus
        }
    }

    private func applyPermissionProbeOutcome(
        _ outcome: SystemAudioPermissionProbeOutcome
    ) {
        isRunning = false
        _ = stopResources()

        switch outcome {
        case .verified:
            return
        case .cancelled:
            systemAudioAccessState = .notRequested
            runtimeState = .stopped
            status = "Audio access check cancelled. Processing did not start, and original audio remains unchanged."
        case .denied:
            systemAudioAccessState = .actionRequired(.permissionNotGranted)
            runtimeState = .permissionRequired
            status = "Processing did not start, and original audio remains unchanged. System Audio Recording access is required, but VolEq never saves or uploads audio."
        case .timedOut:
            systemAudioAccessState = .actionRequired(.couldNotVerify)
            runtimeState = .permissionRequired
            status = "Audio access could not be verified. Processing did not start, and original audio remains unchanged. Keep the selected audio playing, then check again."
        case .malformed:
            systemAudioAccessState = .actionRequired(.malformedAudio)
            runtimeState = .permissionRequired
            status = "Audio access could not be verified because the captured data was unusable. Processing did not start, and original audio remains unchanged."
        case let .coreAudioFailure(operation, statusCode):
            systemAudioAccessState = .actionRequired(.coreAudioFailure)
            runtimeState = .permissionRequired
            let error = VolEqError.coreAudio(
                operation: operation,
                status: statusCode
            )
            status = "\(error.localizedDescription) Processing did not start, and original audio remains unchanged."
        }
    }

    public func stop() {
        startupGeneration &+= 1
        routeRecoveryTask?.cancel()
        routeRecoveryTask = nil
        permissionProbe?.cancel()
        let probeCleanupSucceeded = permissionProbe?.isTornDown ?? true
        if probeCleanupSucceeded {
            permissionProbe = nil
        }
        startupTask?.cancel()
        startupTask = nil
        let pipelineCleanupSucceeded = stopResources()
        guard probeCleanupSucceeded && pipelineCleanupSucceeded else {
            isRunning = !pipelineCleanupSucceeded
            systemAudioAccessState = .actionRequired(.cleanupFailed)
            runtimeState = .failed
            status = incompleteTeardownStatus
            return
        }
        isRunning = false
        systemAudioAccessState = .notRequested
        runtimeState = .stopped
        status = "Stopped. Original application audio is restored."
    }

    @discardableResult
    private func stopResources() -> Bool {
        processingDiagnosticsTask?.cancel()
        processingDiagnosticsTask = nil
        removeActiveOutputListeners()
        if aggregateDeviceID != kAudioObjectUnknown,
           let ioProcID {
            if let teardownStepRecorder {
                teardownStepRecorder(.stopIOProc)
                teardownStepRecorder(.destroyIOProc)
            } else {
                if ioCallbackStarted {
                    guard resourceOperations.stop(aggregateDeviceID, ioProcID) == noErr else {
                        stopResourcesDidRun?()
                        return false
                    }
                }
                guard resourceOperations.destroyIOProc(
                    aggregateDeviceID,
                    ioProcID
                ) == noErr else {
                    stopResourcesDidRun?()
                    return false
                }
            }
        } else if aggregateDeviceID != kAudioObjectUnknown,
                  testOnlyHasSimulatedIOProc,
                  let teardownStepRecorder {
            teardownStepRecorder(.stopIOProc)
            teardownStepRecorder(.destroyIOProc)
        }
        ioProcID = nil
        testOnlyHasSimulatedIOProc = false
        ioCallbackStarted = false

        if aggregateDeviceID != kAudioObjectUnknown {
            if let teardownStepRecorder {
                teardownStepRecorder(.destroyAggregate)
            } else {
                guard resourceOperations.destroyAggregate(aggregateDeviceID) == noErr else {
                    stopResourcesDidRun?()
                    return false
                }
            }
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if let teardownStepRecorder {
                teardownStepRecorder(.destroyTap)
            } else {
                guard resourceOperations.destroyTap(tapID) == noErr else {
                    stopResourcesDidRun?()
                    return false
                }
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        audioProcessor = nil
        stopResourcesDidRun?()
        return true
    }

    private var incompleteTeardownStatus: String {
        "VolEq could not fully stop its Core Audio resources. It will not start another pipeline. Quit VolEq to guarantee the original audio path is restored."
    }

    private func startupFailureStatus(for error: Error) -> String {
        guard case SpeechAnalyzerError.unsupportedSampleRate = error else {
            return error.localizedDescription
        }
        return "Speech-aware processing does not support the current audio sample rate. Original audio remains available. Turn off Speech-aware leveling to use base leveling."
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
        if let teardownStepRecorder {
            teardownStepRecorder(.activeOutputListeners)
        } else {
            for var address in activeOutputListenerAddresses {
                AudioObjectRemovePropertyListenerBlock(
                    activeOutputDeviceID,
                    &address,
                    routeQueue,
                    activeOutputListener
                )
            }
        }
        activeOutputListenerAddresses.removeAll(keepingCapacity: true)
        activeOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
        self.activeOutputListener = nil
    }

    private func handleOutputRouteChange() {
        let wasRunning = isRunning
        let wasCheckingAccess = runtimeState == .checkingAccess

        guard wasRunning || wasCheckingAccess else {
            guard runtimeState != .failed else { return }
            guard !isPermissionActionRequired,
                  systemAudioAccessState != .explanationRequired
            else { return }
            runtimeState = .ready
            status = processes.isEmpty
                ? "No app is producing audio yet. Start meeting audio, then refresh."
                : "Ready. Audio will use the current default output device."
            return
        }

        startupGeneration &+= 1
        routeRecoveryTask?.cancel()
        permissionProbe?.cancel()
        let probeCleanupSucceeded = permissionProbe?.isTornDown ?? true
        if probeCleanupSucceeded {
            permissionProbe = nil
        }
        startupTask?.cancel()
        startupTask = nil
        let pipelineCleanupSucceeded = stopResources()
        guard probeCleanupSucceeded && pipelineCleanupSucceeded else {
            isRunning = !pipelineCleanupSucceeded
            systemAudioAccessState = .actionRequired(.cleanupFailed)
            runtimeState = .failed
            status = incompleteTeardownStatus
            return
        }
        isRunning = false
        systemAudioAccessState = .notRequested
        runtimeState = .recovering
        status = "The output device changed. Original audio is restored while VolEq rechecks access on the new route."
        let recoveryDelayNanoseconds = routeRecoveryDelayNanoseconds
        routeRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: recoveryDelayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.routeRecoveryTask = nil
            self.beginSafeStart(isRecovery: true)
        }
    }

    private var isPermissionActionRequired: Bool {
        if case .actionRequired = systemAudioAccessState {
            return true
        }
        return false
    }

#if DEBUG
    func _testOnlyAdoptCaptureResources(
        tapID: AudioObjectID,
        aggregateDeviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        started: Bool = true
    ) {
        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
        self.ioProcID = ioProcID
        self.ioCallbackStarted = started
    }

    func _testOnlySimulatePartiallyPreparedCaptureResources() {
        activeOutputDeviceID = 101
        activeOutputListener = { _, _ in }
        activeOutputListenerAddresses = [
            propertyAddress(kAudioDevicePropertyNominalSampleRate)
        ]
        aggregateDeviceID = 102
        tapID = 103
        testOnlyHasSimulatedIOProc = true
        ioCallbackStarted = true
    }

    func _testOnlyCaptureResourcesAreInactive() -> Bool {
        tapID == kAudioObjectUnknown
            && aggregateDeviceID == kAudioObjectUnknown
            && ioProcID == nil
            && activeOutputDeviceID == kAudioObjectUnknown
            && activeOutputListener == nil
            && activeOutputListenerAddresses.isEmpty
            && routeRecoveryTask == nil
            && startupTask == nil
            && permissionProbe == nil
            && !ioCallbackStarted
    }

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
        let restored = stopResources()
        isRunning = !restored
        processRefreshFailed = false
        runtimeState = .failed
        if !restored {
            systemAudioAccessState = .actionRequired(.cleanupFailed)
        }
        let operation = conversionStatus == speechAnalysisFailed
            ? "Analyze speech locally"
            : "Convert audio for the output device"
        let error = VolEqError.coreAudio(
            operation: operation,
            status: conversionStatus
        )
        status = restored
            ? "\(error.localizedDescription) Original audio was restored. Try starting again."
            : incompleteTeardownStatus
    }

}
