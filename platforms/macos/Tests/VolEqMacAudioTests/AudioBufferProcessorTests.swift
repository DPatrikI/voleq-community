// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VolEqMacAudio

final class AudioBufferProcessorTests: XCTestCase {
    func testFrameCountUsesSmallestUsableBuffer() {
        var accumulator = AudioBufferFrameCountAccumulator()

        accumulator.include(
            channelCount: 2,
            dataByteSize: byteSize(frames: 480, channels: 2),
            hasData: true
        )
        accumulator.include(
            channelCount: 1,
            dataByteSize: byteSize(frames: 256, channels: 1),
            hasData: true
        )

        XCTAssertEqual(accumulator.value, 256)
    }

    func testFrameCountIgnoresBuffersWithoutChannelsOrStorage() {
        var accumulator = AudioBufferFrameCountAccumulator()

        accumulator.include(channelCount: 0, dataByteSize: 4_096, hasData: true)
        accumulator.include(channelCount: 2, dataByteSize: 4_096, hasData: false)
        accumulator.include(
            channelCount: 2,
            dataByteSize: byteSize(frames: 128, channels: 2),
            hasData: true
        )

        XCTAssertEqual(accumulator.value, 128)
    }

    func testFrameCountIsZeroWhenNoBufferIsUsable() {
        var accumulator = AudioBufferFrameCountAccumulator()

        accumulator.include(channelCount: 0, dataByteSize: 0, hasData: false)

        XCTAssertEqual(accumulator.value, 0)
    }

    func testFrameCountIgnoresIncompleteTrailingByte() {
        var accumulator = AudioBufferFrameCountAccumulator()
        let completeFrames = byteSize(frames: 64, channels: 2)

        accumulator.include(
            channelCount: 2,
            dataByteSize: completeFrames + 1,
            hasData: true
        )

        XCTAssertEqual(accumulator.value, 64)
    }

    private func byteSize(frames: UInt32, channels: UInt32) -> UInt32 {
        frames * channels * UInt32(MemoryLayout<Float>.stride)
    }
}
