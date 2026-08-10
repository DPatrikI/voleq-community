// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import XCTest
@testable import VolEqMacAudio

final class CoreAudioFormatValidationTests: XCTestCase {
    func testDeviceWideSelfExclusionUsesFreshPipelineBoundaryIdentity() throws {
        var resolutionCount = 0
        let objectID = try resolveDeviceWideSelfExclusion {
            resolutionCount += 1
            return 91
        }

        XCTAssertEqual(objectID, 91)
        XCTAssertEqual(resolutionCount, 1)
    }

    func testDeviceWideSelfExclusionFailsClosedWhenIdentityDisappears() {
        XCTAssertThrowsError(try resolveDeviceWideSelfExclusion { nil })
    }

    func testPropertyArrayCountUsesReturnedByteCountAfterChurn() throws {
        XCTAssertEqual(
            try validatedCoreAudioArrayCount(
                byteCount: 2 * UInt32(MemoryLayout<AudioObjectID>.stride),
                elementStride: MemoryLayout<AudioObjectID>.stride,
                maximumByteCount: 5 * UInt32(MemoryLayout<AudioObjectID>.stride)
            ),
            2
        )
    }

    func testPropertyArrayCountRejectsGrowthAndPartialElements() {
        XCTAssertThrowsError(try validatedCoreAudioArrayCount(
            byteCount: 12,
            elementStride: 4,
            maximumByteCount: 8
        ))
        XCTAssertThrowsError(try validatedCoreAudioArrayCount(
            byteCount: 7,
            elementStride: 4,
            maximumByteCount: 8
        ))
    }

    func testPropertyArrayCountRejectsOversizedInitialAllocation() {
        XCTAssertThrowsError(try validatedCoreAudioArrayCount(
            byteCount: maximumCoreAudioPropertyArrayByteCount + 4,
            elementStride: MemoryLayout<AudioObjectID>.stride,
            maximumByteCount: maximumCoreAudioPropertyArrayByteCount
        ))
    }

    func testAcceptsMonoAndStereoLayouts() throws {
        try validateCaptureAudioFormat(format(channels: 1), label: "Captured audio")
        try validateCaptureAudioFormat(format(channels: 2), label: "Output device")
    }

    func testRejectsMissingChannelsBeforeProcessing() {
        XCTAssertThrowsError(
            try validateCaptureAudioFormat(format(channels: 0), label: "Captured audio")
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Captured audio exposes 0 channels. VolEq Community currently supports mono and stereo audio only, so processing was not started."
            )
        }
    }

    func testRejectsMultichannelOutputBeforeProcessing() {
        XCTAssertThrowsError(
            try validateCaptureAudioFormat(format(channels: 6), label: "Output device")
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Output device exposes 6 channels. VolEq Community currently supports mono and stereo audio only, so processing was not started."
            )
        }
    }

    func testRejectsInvalidRatesAndNonNativeOrUnpackedPCM() {
        for sampleRate in [0, .nan, .infinity, 384_000] {
            XCTAssertThrowsError(try validateCaptureAudioFormat(
                format(channels: 2, sampleRate: sampleRate),
                label: "Output device"
            ))
        }

        XCTAssertThrowsError(try validateCaptureAudioFormat(
            format(
                channels: 2,
                flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                    | kAudioFormatFlagIsBigEndian
            ),
            label: "Output device"
        ))
        XCTAssertThrowsError(try validateCaptureAudioFormat(
            format(channels: 2, flags: kAudioFormatFlagIsFloat),
            label: "Output device"
        ))
    }

    func testRejectsInconsistentPCMStrides() {
        var interleaved = format(channels: 2)
        interleaved.mBytesPerFrame = 4
        XCTAssertThrowsError(try validateCaptureAudioFormat(
            interleaved,
            label: "Captured audio"
        ))

        var nonInterleaved = format(
            channels: 2,
            flags: kAudioFormatFlagsNativeFloatPacked
                | kAudioFormatFlagIsNonInterleaved
        )
        nonInterleaved.mBytesPerFrame = 8
        nonInterleaved.mBytesPerPacket = 8
        XCTAssertThrowsError(try validateCaptureAudioFormat(
            nonInterleaved,
            label: "Captured audio"
        ))
    }

    func testRejectsContradictoryFlagsAndReservedMetadata() {
        var signedFloat = format(channels: 2)
        signedFloat.mFormatFlags |= kAudioFormatFlagIsSignedInteger

        var alignedFloat = format(channels: 2)
        alignedFloat.mFormatFlags |= kAudioFormatFlagIsAlignedHigh

        var fractionalFloat = format(channels: 2)
        fractionalFloat.mFormatFlags |= 1 << kLinearPCMFormatFlagsSampleFractionShift

        var reserved = format(channels: 2)
        reserved.mReserved = 1

        for format in [signedFloat, alignedFloat, fractionalFloat, reserved] {
            XCTAssertThrowsError(
                try validateCaptureAudioFormat(format, label: "Test")
            )
        }
    }

    private func format(
        channels: UInt32,
        sampleRate: Double = 48_000,
        flags: AudioFormatFlags = kAudioFormatFlagsNativeFloatPacked
    ) -> AudioStreamBasicDescription {
        let bytesPerFrame = (flags & kAudioFormatFlagIsNonInterleaved) != 0
            ? UInt32(MemoryLayout<Float>.size)
            : channels * UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
