// SPDX-License-Identifier: MPL-2.0

import Foundation

struct RNNoiseWetFIFOFrame {
    let left: Float
    let right: Float
    let sourceFrameIndex: Int64
}

final class RNNoiseWetOutputFIFO {
    private var left: [Float]
    private var right: [Float]
    private var tags: [Int64]
    private var readIndex = 0
    private var writeIndex = 0
    private(set) var count = 0

    init(capacity: Int) {
        left = [Float](repeating: 0, count: capacity)
        right = [Float](repeating: 0, count: capacity)
        tags = [Int64](repeating: -1, count: capacity)
    }

    var capacity: Int { left.count }

    func enqueue(left: Float, right: Float, sourceFrameIndex: Int64) -> Bool {
        guard count < capacity else { return false }
        self.left[writeIndex] = left
        self.right[writeIndex] = right
        tags[writeIndex] = sourceFrameIndex
        writeIndex = (writeIndex + 1) % capacity
        count += 1
        return true
    }

    func frame(atOffset offset: Int) -> RNNoiseWetFIFOFrame? {
        guard offset >= 0, offset < count else { return nil }
        let index = (readIndex + offset) % capacity
        return RNNoiseWetFIFOFrame(
            left: left[index],
            right: right[index],
            sourceFrameIndex: tags[index]
        )
    }

    func consume(_ frameCount: Int) {
        guard frameCount >= 0, frameCount <= count else { return }
        readIndex = (readIndex + frameCount) % capacity
        count -= frameCount
    }

    func reset() {
        readIndex = 0
        writeIndex = 0
        count = 0
        for index in left.indices { left[index] = 0 }
        for index in right.indices { right[index] = 0 }
        for index in tags.indices { tags[index] = -1 }
    }
}
