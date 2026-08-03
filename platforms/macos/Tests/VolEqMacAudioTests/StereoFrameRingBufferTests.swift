// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VolEqMacAudio

final class StereoFrameRingBufferTests: AudioPipelineTestCase {
    func testRingBufferDropsOldestFrameAndPreservesLiveOrder() {
        let buffer = StereoFrameRingBuffer(capacity: 3)
        buffer.append(left: 1, right: -1)
        buffer.append(left: 2, right: -2)
        buffer.append(left: 3, right: -3)
        buffer.append(left: 4, right: -4)

        XCTAssertEqual(buffer.availableFrameCount, 3)
        XCTAssertEqual(buffer.droppedFrameCount, 1)

        let firstRead = buffer.contiguousReadPointer(maximumFrameCount: 3)
        XCTAssertEqual(firstRead?.frameCount, 2)
        XCTAssertEqual(firstRead?.pointer[0], 2)
        XCTAssertEqual(firstRead?.pointer[1], -2)
        XCTAssertEqual(firstRead?.pointer[2], 3)
        XCTAssertEqual(firstRead?.pointer[3], -3)

        buffer.consume(frameCount: 2)
        let secondRead = buffer.contiguousReadPointer(maximumFrameCount: 3)
        XCTAssertEqual(secondRead?.frameCount, 1)
        XCTAssertEqual(secondRead?.pointer[0], 4)
        XCTAssertEqual(secondRead?.pointer[1], -4)
    }

    func testCopyExactSelectsLeftChannelForMonoWithoutPartialConsumption() {
        let buffer = StereoFrameRingBuffer(capacity: 4)
        buffer.append(left: 0.25, right: -0.25)
        buffer.append(left: 0.5, right: -0.5)
        var output = Array(repeating: Float.zero, count: 2)

        let copied = withMutableInterleavedBuffer(
            samples: &output,
            channelCount: 1
        ) { outputList in
            buffer.copyExact(frameCount: 2, to: outputList)
        }

        XCTAssertTrue(copied)
        XCTAssertEqual(output, [0.25, 0.5])
        XCTAssertEqual(buffer.availableFrameCount, 0)
        XCTAssertFalse(
            withMutableInterleavedBuffer(samples: &output, channelCount: 1) {
                buffer.copyExact(frameCount: 1, to: $0)
            }
        )
        XCTAssertEqual(buffer.availableFrameCount, 0)
    }
}
