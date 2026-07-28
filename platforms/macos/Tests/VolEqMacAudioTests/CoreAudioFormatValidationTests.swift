// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import XCTest
@testable import VolEqMacAudio

final class CoreAudioFormatValidationTests: XCTestCase {
    func testAcceptsMonoAndStereoLayouts() throws {
        try validateSupportedChannelLayout(format(channels: 1), label: "Captured audio")
        try validateSupportedChannelLayout(format(channels: 2), label: "Output device")
    }

    func testRejectsMissingChannelsBeforeProcessing() {
        XCTAssertThrowsError(
            try validateSupportedChannelLayout(format(channels: 0), label: "Captured audio")
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Captured audio exposes 0 channels. VolEq Community currently supports mono and stereo audio only, so processing was not started."
            )
        }
    }

    func testRejectsMultichannelOutputBeforeProcessing() {
        XCTAssertThrowsError(
            try validateSupportedChannelLayout(format(channels: 6), label: "Output device")
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Output device exposes 6 channels. VolEq Community currently supports mono and stereo audio only, so processing was not started."
            )
        }
    }

    private func format(channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: channels * UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
