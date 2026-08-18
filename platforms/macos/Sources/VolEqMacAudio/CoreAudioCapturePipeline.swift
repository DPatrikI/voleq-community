// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation
import VolEqCore

protocol AudioCapturePipeline: AnyObject, Sendable {
    var heartbeat: AudioCallbackHeartbeat { get }
    var processor: AudioIOProcessor? { get }
    var runningStatusSuffix: String { get }
    func start() throws -> UInt64
    func stop() -> AudioCaptureTeardownReport
    func updateSettings(_ settings: LevelingSettings)
    var livenessVerificationConfiguration: AudioLivenessVerificationConfiguration? { get }
    func drainDiagnosticTelemetry() -> AudioLivenessObservation?
    func recordDiagnosticProcessingFailure(_ statusCode: OSStatus)
    func setDiagnosticFaultInjectionEnabled(_ enabled: Bool) -> Bool
    var isDiagnosticFaultInjectionEnabled: Bool { get }
}

extension AudioCapturePipeline {
    var livenessVerificationConfiguration: AudioLivenessVerificationConfiguration? { nil }
    func drainDiagnosticTelemetry() -> AudioLivenessObservation? { nil }
    func recordDiagnosticProcessingFailure(_ statusCode: OSStatus) {}
    func setDiagnosticFaultInjectionEnabled(_ enabled: Bool) -> Bool { false }
    var isDiagnosticFaultInjectionEnabled: Bool { false }
}

protocol AudioCapturePipelineBuilding: Sendable {
    func build(
        request: PreparedCaptureRequest,
        onRouteChange: @escaping @MainActor @Sendable () -> Void
    ) throws -> any AudioCapturePipeline
}

struct AudioCapturePipelineConstructionFailure: Error {
    let underlyingError: Error
    let retainedPipeline: any AudioCapturePipeline
}

func resolveDeviceWideSelfExclusion(
    using resolver: () throws -> AudioObjectID?
) throws -> AudioObjectID {
    guard let ownProcess = try resolver() else {
        throw VolEqError.missingValue(
            "VolEq could not revalidate its device-wide feedback exclusion, so it stopped before processing began. Try again."
        )
    }
    return ownProcess
}

@available(macOS 14.2, *)
struct CoreAudioCapturePipelineOperations: @unchecked Sendable {
    let start: (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus
    let stop: (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus
    let destroyIOProc: (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus
    let destroyAggregate: (AudioObjectID) -> OSStatus
    let destroyTap: (AudioObjectID) -> OSStatus
    let removePropertyListenerStatus: (
        AudioObjectID,
        AudioObjectPropertyAddress
    ) -> OSStatus
    let ownProcessObject: () throws -> AudioObjectID?

    init(
        start: @escaping (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus,
        stop: @escaping (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus,
        destroyIOProc: @escaping (AudioObjectID, AudioDeviceIOProcID?) -> OSStatus,
        destroyAggregate: @escaping (AudioObjectID) -> OSStatus,
        destroyTap: @escaping (AudioObjectID) -> OSStatus,
        removePropertyListenerStatus: @escaping (
            AudioObjectID,
            AudioObjectPropertyAddress
        ) -> OSStatus = { _, _ in noErr },
        ownProcessObject: @escaping () throws -> AudioObjectID? = {
            try processObject(for: getpid())
        }
    ) {
        self.start = start
        self.stop = stop
        self.destroyIOProc = destroyIOProc
        self.destroyAggregate = destroyAggregate
        self.destroyTap = destroyTap
        self.removePropertyListenerStatus = removePropertyListenerStatus
        self.ownProcessObject = ownProcessObject
    }

    static let live = CoreAudioCapturePipelineOperations(
        start: AudioDeviceStart,
        stop: AudioDeviceStop,
        destroyIOProc: { deviceID, ioProcID in
            guard let ioProcID else { return kAudio_ParamError }
            return AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        },
        destroyAggregate: AudioHardwareDestroyAggregateDevice,
        destroyTap: AudioHardwareDestroyProcessTap
    )
}

@available(macOS 14.2, *)
struct CoreAudioCapturePipelineBuilder: AudioCapturePipelineBuilding {
    let operations: CoreAudioCapturePipelineOperations
    let diagnostics: (any AudioLivenessDiagnosticsRecording)?

    init(
        operations: CoreAudioCapturePipelineOperations = .live,
        diagnostics: (any AudioLivenessDiagnosticsRecording)? = nil
    ) {
        self.operations = operations
        self.diagnostics = diagnostics
    }

    func build(
        request: PreparedCaptureRequest,
        onRouteChange: @escaping @MainActor @Sendable () -> Void
    ) throws -> any AudioCapturePipeline {
        try CoreAudioCapturePipeline.build(
            request: request,
            operations: operations,
            diagnostics: diagnostics,
            onRouteChange: onRouteChange
        )
    }
}

@available(macOS 14.2, *)
final class CoreAudioCapturePipeline: AudioCapturePipeline, @unchecked Sendable {
    private static let abandonedCleanupQueue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.abandoned-pipeline-cleanup",
        qos: .userInitiated
    )
    private let operations: CoreAudioCapturePipelineOperations
    private let ioQueue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.audio",
        qos: .userInteractive
    )
    private let routeQueue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.active-output-route",
        qos: .userInitiated
    )
    private let lifecycleLock = NSLock()
    private let resources: CoreAudioCaptureResourceOwner
    private let diagnostics: (any AudioLivenessDiagnosticsRecording)?
    private let callbackTelemetry: AudioCallbackTelemetry?
    private var storedProcessor: AudioIOProcessor?
    private var outputControlDiagnostics: AudioOutputControlDiagnosticsObserver?
    private var storedVerificationConfiguration: AudioLivenessVerificationConfiguration?
    let heartbeat: AudioCallbackHeartbeat

    var processor: AudioIOProcessor? {
        lifecycleLock.withLock { storedProcessor }
    }

    var livenessVerificationConfiguration: AudioLivenessVerificationConfiguration? {
        lifecycleLock.withLock { storedVerificationConfiguration }
    }

    private init(
        operations: CoreAudioCapturePipelineOperations,
        heartbeat: AudioCallbackHeartbeat,
        diagnostics: (any AudioLivenessDiagnosticsRecording)?
    ) throws {
        self.operations = operations
        self.heartbeat = heartbeat
        self.diagnostics = diagnostics
        callbackTelemetry = try diagnostics.map { _ in
            try AudioCallbackTelemetry()
        }
        resources = CoreAudioCaptureResourceOwner(
            operations: operations,
            routeQueue: routeQueue
        )
    }

    static func build(
        request: PreparedCaptureRequest,
        operations: CoreAudioCapturePipelineOperations,
        diagnostics: (any AudioLivenessDiagnosticsRecording)? = nil,
        onRouteChange: @escaping @MainActor @Sendable () -> Void
    ) throws -> CoreAudioCapturePipeline {
        let pipeline = try CoreAudioCapturePipeline(
            operations: operations,
            heartbeat: try AudioCallbackHeartbeat(),
            diagnostics: diagnostics
        )
        do {
            try pipeline.prepare(request: request, onRouteChange: onRouteChange)
            return pipeline
        } catch {
            // The retained owner is handed to the lifecycle runtime so even a
            // partially constructed graph is dismantled on its teardown
            // executor instead of blocking the main actor here.
            throw AudioCapturePipelineConstructionFailure(
                underlyingError: error,
                retainedPipeline: pipeline
            )
        }
    }

    private func prepare(
        request: PreparedCaptureRequest,
        onRouteChange: @escaping @MainActor @Sendable () -> Void
    ) throws {
        let outputDeviceID = try defaultOutputDevice()
        let outputUID = try readString(
            objectID: outputDeviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
        let outputFormat: AudioStreamBasicDescription = try readValue(
            objectID: outputDeviceID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeOutput
        )
        try validateCaptureAudioFormat(outputFormat, label: "Output device")
        guard outputDeviceID == request.outputDeviceID,
              outputUID == request.outputDeviceUID,
              outputFormat.mSampleRate == request.outputFormat.mSampleRate,
              outputFormat.mChannelsPerFrame == request.outputFormat.mChannelsPerFrame
        else {
            throw VolEqError.missingValue(
                "The output route changed during startup. Processing did not start, and original audio remains unchanged. Try again on the current output."
            )
        }
        lifecycleLock.withLock {
            storedVerificationConfiguration = AudioLivenessVerificationConfiguration(
                captureTarget: request.captureTarget,
                outputDeviceUID: request.outputDeviceUID
            )
        }

        try installOutputListeners(
            deviceID: outputDeviceID,
            onRouteChange: onRouteChange
        )
        let bufferFrameSize: UInt32? = try? readValue(
            objectID: outputDeviceID,
            selector: kAudioDevicePropertyBufferFrameSize
        )
        diagnostics?.recordRoute(
            uid: outputUID,
            sampleRate: outputFormat.mSampleRate,
            channelCount: outputFormat.mChannelsPerFrame,
            bufferFrameSize: bufferFrameSize
        )
        if let diagnostics {
            let observer = AudioOutputControlDiagnosticsObserver(
                deviceID: outputDeviceID,
                diagnostics: diagnostics
            )
            observer.start()
            outputControlDiagnostics = observer
        }

        let tapDescription = CATapDescription()
        tapDescription.name = "VolEq Capture"
        tapDescription.isPrivate = true
        tapDescription.isMixdown = true
        tapDescription.isMono = false
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.deviceUID = request.outputDeviceUID
        switch request.captureTarget {
        case let .application(processID):
            guard let expected = request.intent.application else {
                throw VolEqError.missingValue(
                    "Audio processing received no application identity."
                )
            }
            try validateApplicationCaptureIdentity(
                objectID: processID,
                expected: expected
            )
            tapDescription.processes = [processID]
            tapDescription.isExclusive = false
        case .deviceWide:
            let ownProcess = try resolveDeviceWideSelfExclusion(
                using: operations.ownProcessObject
            )
            tapDescription.processes = [ownProcess]
            tapDescription.isExclusive = true
        }

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try requireNoErr(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            "Create process tap"
        )
        resources.didCreateTap(tapID)
        let tapUID = try readString(
            objectID: tapID,
            selector: kAudioTapPropertyUID
        )
        let aggregateUID = "com.patrikistvandoczy.voleq.community.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolEq Private Audio Device",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: request.outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: request.outputDeviceUID,
                kAudioSubDeviceInputChannelsKey: 0,
            ]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        try requireNoErr(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateDeviceID
            ),
            "Create private aggregate device"
        )
        resources.didCreateAggregate(aggregateDeviceID)

        let callbackInputFormat: AudioStreamBasicDescription = try readValue(
            objectID: aggregateDeviceID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeInput
        )
        let aggregateOutputFormat: AudioStreamBasicDescription = try readValue(
            objectID: aggregateDeviceID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeOutput
        )
        try validateCaptureAudioFormat(
            callbackInputFormat,
            label: "Captured audio"
        )
        try validateCaptureAudioFormat(
            aggregateOutputFormat,
            label: "Output device"
        )

        let processor = try AudioIOProcessor(
            inputFormat: callbackInputFormat,
            outputFormat: aggregateOutputFormat,
            settings: request.intent.levelingSettings,
            speechAwarenessEnabled: request.intent.speechAwarenessEnabled,
            speechModel: request.speechModel,
            systemContentAnalysisEnabled: request.intent.speechAwarenessEnabled
        )
        lifecycleLock.withLock { storedProcessor = processor }

        var ioProcID: AudioDeviceIOProcID?
        try requireNoErr(
            AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateDeviceID,
                ioQueue
            ) { [heartbeat, callbackTelemetry] _, inputData, inputTime, outputData, outputTime in
                heartbeat.recordCallback()
                if let callbackTelemetry {
                    let metadata = callbackTelemetry.isFaultInjectionEnabled
                        ? processor.processSimulatedUnusableCapture(
                            input: inputData,
                            output: outputData
                        )
                        : processor.processWithDiagnostics(
                            input: inputData,
                            inputTime: inputTime.pointee,
                            output: outputData,
                            outputTime: outputTime.pointee
                        )
                    let outputTimestamp = outputTime.pointee
                    let inputTimestamp = inputTime.pointee
                    let hostTime: UInt64
                    if outputTimestamp.mFlags.contains(.hostTimeValid) {
                        hostTime = outputTimestamp.mHostTime
                    } else if inputTimestamp.mFlags.contains(.hostTimeValid) {
                        hostTime = inputTimestamp.mHostTime
                    } else {
                        hostTime = 0
                    }
                    callbackTelemetry.record(
                        hostTime: hostTime,
                        metadata: metadata
                    )
                } else {
                    processor.process(
                        input: inputData,
                        inputTime: inputTime.pointee,
                        output: outputData,
                        outputTime: outputTime.pointee
                    )
                }
            },
            "Create audio processing callback"
        )
        guard let ioProcID else {
            throw VolEqError.missingValue(
                "Core Audio created no audio processing callback."
            )
        }
        resources.didCreateIOProc(ioProcID)
    }

    func start() throws -> UInt64 {
        let initialCount = heartbeat.callbackCount
        try requireNoErr(resources.startIOProc(), "Start audio processing")
        return initialCount
    }

    func updateSettings(_ settings: LevelingSettings) {
        lifecycleLock.withLock {
            storedProcessor?.updateSettings(settings)
        }
    }

    func drainDiagnosticTelemetry() -> AudioLivenessObservation? {
        guard let callbackTelemetry, let diagnostics else { return nil }
        let drained = callbackTelemetry.drain()
        diagnostics.ingest(
            drained.records,
            droppedRecordCount: drained.droppedRecordCount
        )
        return drained.records.last.map(AudioLivenessObservation.init)
    }

    func recordDiagnosticProcessingFailure(_ statusCode: OSStatus) {
        diagnostics?.recordProcessingFailure(statusCode)
    }

    func setDiagnosticFaultInjectionEnabled(_ enabled: Bool) -> Bool {
        guard let callbackTelemetry else { return false }
        callbackTelemetry.setFaultInjectionEnabled(enabled)
        diagnostics?.recordRecoveryExperimentEvent(
            kind: enabled
                ? "controlledFaultInjectionBegan"
                : "controlledFaultInjectionEnded",
            reason: "Diagnostic-only atomic callback fault injection."
        )
        return true
    }

    var isDiagnosticFaultInjectionEnabled: Bool {
        callbackTelemetry?.isFaultInjectionEnabled ?? false
    }

    var runningStatusSuffix: String {
        lifecycleLock.withLock {
            guard let processor = storedProcessor,
                  processor.usesSampleRateConversion
            else { return "" }
            return " Resolving route timing (\(Int(processor.inputSampleRate))→\(Int(processor.outputSampleRate)) Hz labels)…"
        }
    }

    func stop() -> AudioCaptureTeardownReport {
        _ = drainDiagnosticTelemetry()
        outputControlDiagnostics?.stop()
        outputControlDiagnostics = nil
        let report = resources.teardown()
        report.failures.forEach { diagnostics?.recordTeardownFailure($0) }
        if report.permitsReplacementPipeline, !report.isComplete {
            diagnostics?.recordRecoveryExperimentEvent(
                kind: "outputRouteListenersQuarantined",
                reason: "The tap, aggregate device, and IO callback were destroyed. Unremovable route listeners remain generation-gated in a retained ownership ledger."
            )
        }
        return report
    }

    private func installOutputListeners(
        deviceID: AudioObjectID,
        onRouteChange: @escaping @MainActor @Sendable () -> Void
    ) throws {
        let ingress = AudioRouteChangeSignalCoalescer(deliver: onRouteChange)
        let diagnostics = diagnostics
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            diagnostics?.recordRouteChangeDetected()
            ingress.signal()
        }
        let addresses = [
            propertyAddress(kAudioDevicePropertyDeviceIsAlive),
            propertyAddress(kAudioDevicePropertyNominalSampleRate),
            propertyAddress(
                kAudioDevicePropertyStreamFormat,
                scope: kAudioDevicePropertyScopeOutput
            ),
        ]
        resources.didInstallOutputListener(deviceID: deviceID, listener: listener)
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
            resources.didInstallOutputListenerAddress(address)
        }
    }

    deinit {
        outputControlDiagnostics?.stop()
        let resources = resources
        Self.abandonedCleanupQueue.async {
            let report = resources.teardown()
            guard !report.isComplete else { return }
            // Core Audio may still own a callback or listener. Retain the
            // ledger rather than freeing callback ownership during process
            // lifetime after a final best-effort cleanup refusal.
            _ = Unmanaged.passRetained(resources)
        }
    }
}
