// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation

let maximumCoreAudioPropertyArrayByteCount: UInt32 = 1_048_576

enum VolEqError: LocalizedError {
    case coreAudio(operation: String, status: OSStatus)
    case missingValue(String)
    case unsupportedFormat(String)
    case noProcessSelected

    var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            let code = Self.fourCC(status)
            return "\(operation) failed (\(code), \(status))."
        case let .missingValue(message), let .unsupportedFormat(message):
            return message
        case .noProcessSelected:
            return "Choose an application that is currently producing audio."
        }
    }

    private static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else { return "OSStatus" }
        return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
    }
}

@inline(__always)
func requireNoErr(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw VolEqError.coreAudio(operation: operation, status: status)
    }
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )
}

func readValue<T>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    as type: T.Type = T.self
) throws -> T {
    var address = propertyAddress(selector, scope: scope)
    var size = UInt32(MemoryLayout<T>.size)
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    try requireNoErr(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, value),
        "Read Core Audio property \(selector)"
    )
    guard size == UInt32(MemoryLayout<T>.size) else {
        throw VolEqError.missingValue(
            "Core Audio returned an invalid size for property \(selector)."
        )
    }
    return value.pointee
}

func readArray<T>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    as type: T.Type = T.self
) throws -> [T] {
    var address = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    try requireNoErr(
        AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
        "Size Core Audio property \(selector)"
    )

    let allocatedCount = try validatedCoreAudioArrayCount(
        byteCount: size,
        elementStride: MemoryLayout<T>.stride,
        maximumByteCount: maximumCoreAudioPropertyArrayByteCount
    )
    guard allocatedCount > 0 else { return [] }
    let allocatedByteCount = size
    let values = UnsafeMutablePointer<T>.allocate(capacity: allocatedCount)
    defer { values.deallocate() }
    try requireNoErr(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, values),
        "Read Core Audio property array \(selector)"
    )
    let returnedCount = try validatedCoreAudioArrayCount(
        byteCount: size,
        elementStride: MemoryLayout<T>.stride,
        maximumByteCount: allocatedByteCount
    )
    return Array(UnsafeBufferPointer(start: values, count: returnedCount))
}

func validatedCoreAudioArrayCount(
    byteCount: UInt32,
    elementStride: Int,
    maximumByteCount: UInt32
) throws -> Int {
    guard elementStride > 0,
          byteCount <= maximumByteCount,
          Int(byteCount).isMultiple(of: elementStride)
    else {
        throw VolEqError.missingValue(
            "Core Audio returned an invalid property-array size."
        )
    }
    return Int(byteCount) / elementStride
}

func readString(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> String {
    var address = propertyAddress(selector, scope: scope)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutableBytes(of: &value) { bytes in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, bytes.baseAddress!)
    }
    try requireNoErr(status, "Read Core Audio string property \(selector)")
    guard size == UInt32(MemoryLayout<Unmanaged<CFString>?>.size) else {
        throw VolEqError.missingValue(
            "Core Audio returned an invalid string-property size."
        )
    }
    guard let value else { throw VolEqError.missingValue("Core Audio returned an empty string property.") }
    return value.takeRetainedValue() as String
}

func defaultOutputDevice() throws -> AudioObjectID {
    let id: AudioObjectID = try readValue(
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDefaultOutputDevice
    )
    guard id != kAudioObjectUnknown else {
        throw VolEqError.missingValue("No default audio output device is available.")
    }
    return id
}

func processObject(for pid: pid_t) throws -> AudioObjectID? {
    var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var processID = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let qualifierSize = UInt32(MemoryLayout<pid_t>.size)
    try requireNoErr(
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            qualifierSize,
            &processID,
            &size,
            &objectID
        ),
        "Find this app's Core Audio process"
    )
    guard size == UInt32(MemoryLayout<AudioObjectID>.size) else {
        throw VolEqError.missingValue(
            "Core Audio returned an invalid process-object size."
        )
    }
    return objectID == kAudioObjectUnknown ? nil : objectID
}

func validateApplicationCaptureIdentity(
    objectID: AudioObjectID,
    expected: ApplicationCaptureIdentity
) throws {
    let actualPID: pid_t = try readValue(
        objectID: objectID,
        selector: kAudioProcessPropertyPID
    )
    let actualBundleID = try readString(
        objectID: objectID,
        selector: kAudioProcessPropertyBundleID
    )
    guard actualPID == expected.pid,
          !expected.bundleID.isEmpty,
          actualBundleID == expected.bundleID
    else {
        throw RecoveryFailure.applicationMissing(expected.displayName)
    }
}

func validateCaptureAudioFormat(
    _ format: AudioStreamBasicDescription,
    label: String
) throws {
    let isPCM = format.mFormatID == kAudioFormatLinearPCM
    let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isPacked = (format.mFormatFlags & kAudioFormatFlagIsPacked) != 0
    let isNativeEndian = (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0
    let isNonInterleaved =
        (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let allowedFlags = kAudioFormatFlagIsFloat
        | kAudioFormatFlagIsPacked
        | kAudioFormatFlagIsNonInterleaved
    let hasOnlySupportedFlags = (format.mFormatFlags & ~allowedFlags) == 0
    let channels = format.mChannelsPerFrame
    let channelCount = Int(channels)
    guard (1...2).contains(channelCount) else {
        let description = channelCount == 1 ? "channel" : "channels"
        throw VolEqError.unsupportedFormat(
            "\(label) exposes \(channelCount) \(description). "
                + "VolEq currently supports mono and stereo audio only, "
                + "so processing was not started."
        )
    }
    let expectedBytesPerFrame = isNonInterleaved
        ? UInt32(MemoryLayout<Float>.size)
        : channels * UInt32(MemoryLayout<Float>.size)
    let expectedPacketBytes = expectedBytesPerFrame.multipliedReportingOverflow(
        by: format.mFramesPerPacket
    )

    guard format.mSampleRate.isFinite,
          (8_000...192_000).contains(format.mSampleRate),
          isPCM,
          isFloat,
          isPacked,
          isNativeEndian,
          hasOnlySupportedFlags,
          format.mBitsPerChannel == 32,
          format.mFramesPerPacket == 1,
          format.mReserved == 0,
          !expectedPacketBytes.overflow,
          format.mBytesPerFrame == expectedBytesPerFrame,
          format.mBytesPerPacket == expectedPacketBytes.partialValue
    else {
        throw VolEqError.unsupportedFormat(
            "\(label) uses an unsupported audio format. VolEq currently expects native packed 32-bit floating-point PCM between 8 and 192 kHz with no contradictory layout flags."
        )
    }

}
