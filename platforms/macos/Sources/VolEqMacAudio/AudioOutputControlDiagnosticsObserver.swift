// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import CoreAudio
import Foundation

@available(macOS 14.2, *)
struct AudioOutputControlDiagnosticsOperations: @unchecked Sendable {
    let hasProperty: (AudioObjectID, AudioObjectPropertyAddress) -> Bool
    let addListener: (
        AudioObjectID,
        AudioObjectPropertyAddress,
        DispatchQueue,
        @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    let removeListener: (
        AudioObjectID,
        AudioObjectPropertyAddress,
        DispatchQueue,
        @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    let readFloat: (AudioObjectID, AudioObjectPropertyAddress) -> Float?
    let readUInt32: (AudioObjectID, AudioObjectPropertyAddress) -> UInt32?

    static let live = AudioOutputControlDiagnosticsOperations(
        hasProperty: { deviceID, address in
            var address = address
            return AudioObjectHasProperty(deviceID, &address)
        },
        addListener: { deviceID, address, queue, listener in
            var address = address
            return AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                queue,
                listener
            )
        },
        removeListener: { deviceID, address, queue, listener in
            var address = address
            return AudioObjectRemovePropertyListenerBlock(
                deviceID,
                &address,
                queue,
                listener
            )
        },
        readFloat: AudioOutputControlDiagnosticsObserver.readFloat,
        readUInt32: AudioOutputControlDiagnosticsObserver.readUInt32
    )
}

@available(macOS 14.2, *)
final class AudioOutputControlDiagnosticsObserver: @unchecked Sendable {
    private let deviceID: AudioObjectID
    private let diagnostics: any AudioLivenessDiagnosticsRecording
    private let operations: AudioOutputControlDiagnosticsOperations
    private let queue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.diagnostics.output-controls",
        qos: .utility
    )
    private var listener: AudioObjectPropertyListenerBlock?
    private var addresses: [AudioObjectPropertyAddress] = []

    init(
        deviceID: AudioObjectID,
        diagnostics: any AudioLivenessDiagnosticsRecording,
        operations: AudioOutputControlDiagnosticsOperations = .live
    ) {
        self.deviceID = deviceID
        self.diagnostics = diagnostics
        self.operations = operations
    }

    func start() {
        let virtualVolume = propertyAddress(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput
        )
        let mainVolume = propertyAddress(
            kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput
        )
        let mute = propertyAddress(
            kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput
        )
        let bufferSize = propertyAddress(
            kAudioDevicePropertyBufferFrameSize
        )
        let volumeAddress = operations.hasProperty(deviceID, virtualVolume)
            ? virtualVolume
            : (operations.hasProperty(deviceID, mainVolume)
                ? mainVolume
                : nil)
        let muteAddress = operations.hasProperty(deviceID, mute)
            ? mute
            : nil
        let bufferSizeAddress = operations.hasProperty(deviceID, bufferSize)
            ? bufferSize
            : nil
        addresses = [volumeAddress, muteAddress, bufferSizeAddress].compactMap { $0 }
        guard !addresses.isEmpty else {
            diagnostics.recordDiagnosticListenerState(
                reason: "Output volume and mute properties are unavailable on this route.",
                cleanupComplete: nil
            )
            return
        }

        let diagnostics = diagnostics
        let deviceID = deviceID
        let operations = operations
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Self.publishCurrentValues(
                deviceID: deviceID,
                volumeAddress: volumeAddress,
                muteAddress: muteAddress,
                bufferSizeAddress: bufferSizeAddress,
                operations: operations,
                diagnostics: diagnostics
            )
        }
        self.listener = listener
        var installed: [AudioObjectPropertyAddress] = []
        for address in addresses {
            let status = operations.addListener(
                deviceID,
                address,
                queue,
                listener
            )
            if status == noErr {
                installed.append(address)
            } else {
                diagnostics.recordDiagnosticListenerState(
                    reason: "A diagnostic output-control listener was unavailable (OSStatus \(status)).",
                    cleanupComplete: nil
                )
            }
        }
        addresses = installed
        Self.publishCurrentValues(
            deviceID: deviceID,
            volumeAddress: volumeAddress,
            muteAddress: muteAddress,
            bufferSizeAddress: bufferSizeAddress,
            operations: operations,
            diagnostics: diagnostics
        )
    }

    func stop() {
        guard let listener else { return }
        var complete = true
        for address in addresses {
            if operations.removeListener(
                deviceID,
                address,
                queue,
                listener
            ) != noErr {
                complete = false
            }
        }
        addresses.removeAll(keepingCapacity: false)
        self.listener = nil
        diagnostics.recordDiagnosticListenerState(
            reason: complete
                ? "Diagnostic output-control listeners stopped."
                : "One or more diagnostic output-control listeners could not be removed.",
            cleanupComplete: complete
        )
    }

    private static func publishCurrentValues(
        deviceID: AudioObjectID,
        volumeAddress: AudioObjectPropertyAddress?,
        muteAddress: AudioObjectPropertyAddress?,
        bufferSizeAddress: AudioObjectPropertyAddress?,
        operations: AudioOutputControlDiagnosticsOperations,
        diagnostics: any AudioLivenessDiagnosticsRecording
    ) {
        let volume = volumeAddress.flatMap {
            operations.readFloat(deviceID, $0)
        }
        let muted = muteAddress.flatMap {
            operations.readUInt32(deviceID, $0)
        }.map { $0 != 0 }
        diagnostics.recordVolumeChange(volumeScalar: volume, muted: muted)
        if let bufferSizeAddress {
            diagnostics.recordBufferSizeChange(
                operations.readUInt32(deviceID, bufferSizeAddress)
            )
        }
    }

    fileprivate static func readFloat(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> Float? {
        var mutableAddress = address
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &mutableAddress,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr && size == MemoryLayout<Float>.size
            ? value
            : nil
    }

    fileprivate static func readUInt32(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> UInt32? {
        var mutableAddress = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &mutableAddress,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr && size == MemoryLayout<UInt32>.size
            ? value
            : nil
    }
}
