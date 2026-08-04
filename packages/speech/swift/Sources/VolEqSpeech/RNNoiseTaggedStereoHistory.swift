// SPDX-License-Identifier: MPL-2.0

import Foundation

final class RNNoiseTaggedStereoHistory {
    private let left: UnsafeMutableBufferPointer<Float>
    private let right: UnsafeMutableBufferPointer<Float>
    private let tags: UnsafeMutableBufferPointer<Int64>

    init(capacity: Int) {
        left = Self.allocateBuffer(repeating: 0, count: capacity)
        right = Self.allocateBuffer(repeating: 0, count: capacity)
        tags = Self.allocateBuffer(repeating: -1, count: capacity)
    }

    deinit {
        Self.deallocateBuffer(left)
        Self.deallocateBuffer(right)
        Self.deallocateBuffer(tags)
    }

    func store(left: Float, right: Float, at index: Int64) {
        let slot = Int(index % Int64(tags.count))
        self.left[slot] = left
        self.right[slot] = right
        tags[slot] = index
    }

    func frame(at index: Int64) -> (left: Float, right: Float)? {
        guard index >= 0 else { return nil }
        let slot = Int(index % Int64(tags.count))
        guard tags[slot] == index else { return nil }
        return (left[slot], right[slot])
    }

    func sourcePowers(start: Int64, frameCount: Int) -> (left: Float, right: Float)? {
        var leftSum: Double = 0
        var rightSum: Double = 0
        for offset in 0..<frameCount {
            guard let dry = frame(at: start + Int64(offset)) else { return nil }
            let dryLeft = Double(dry.left)
            let dryRight = Double(dry.right)
            leftSum += dryLeft * dryLeft
            rightSum += dryRight * dryRight
        }
        let count = Double(frameCount)
        let leftPower = Float(leftSum / count)
        let rightPower = Float(rightSum / count)
        return leftPower.isFinite && rightPower.isFinite
            ? (leftPower, rightPower)
            : nil
    }

    func reset() {
        for index in left.indices { left[index] = 0 }
        for index in right.indices { right[index] = 0 }
        for index in tags.indices { tags[index] = -1 }
    }

    private static func allocateBuffer<Element>(
        repeating value: Element,
        count: Int
    ) -> UnsafeMutableBufferPointer<Element> {
        let storage = UnsafeMutablePointer<Element>.allocate(capacity: count)
        storage.initialize(repeating: value, count: count)
        return UnsafeMutableBufferPointer(start: storage, count: count)
    }

    private static func deallocateBuffer<Element>(
        _ buffer: UnsafeMutableBufferPointer<Element>
    ) {
        buffer.deinitialize()
        buffer.baseAddress?.deallocate()
    }
}
