// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import Foundation

/// A fixed-capacity, interleaved stereo FIFO used only by the audio callback.
///
/// The aggregate-device callback is serial, so this buffer deliberately avoids
/// locks and allocations. If Core Audio stalls long enough to fill the FIFO, the
/// oldest frame is discarded so playback recovers at the live edge instead of
/// accumulating unbounded latency.
final class StereoFrameRingBuffer {
    let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    private(set) var availableFrameCount = 0
    private(set) var droppedFrameCount = 0
    private var readIndex = 0
    private var writeIndex = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity * 2)
        storage.initialize(repeating: 0, count: capacity * 2)
    }

    deinit {
        storage.deinitialize(count: capacity * 2)
        storage.deallocate()
    }

    func append(left: Float, right: Float) {
        if availableFrameCount == capacity {
            readIndex = (readIndex + 1) % capacity
            availableFrameCount -= 1
            droppedFrameCount += 1
        }

        let sampleIndex = writeIndex * 2
        storage[sampleIndex] = left
        storage[sampleIndex + 1] = right
        writeIndex = (writeIndex + 1) % capacity
        availableFrameCount += 1
    }

    func contiguousReadPointer(maximumFrameCount: Int) -> (
        pointer: UnsafeMutablePointer<Float>,
        frameCount: Int
    )? {
        guard availableFrameCount > 0, maximumFrameCount > 0 else { return nil }
        let frameCount = min(
            maximumFrameCount,
            availableFrameCount,
            capacity - readIndex
        )
        return (storage.advanced(by: readIndex * 2), frameCount)
    }

    func consume(frameCount: Int) {
        let consumed = min(max(frameCount, 0), availableFrameCount)
        readIndex = (readIndex + consumed) % capacity
        availableFrameCount -= consumed
    }

    func appendInterleaved(
        _ samples: UnsafePointer<Float>,
        channelCount: Int,
        frameCount: Int
    ) {
        precondition((1...2).contains(channelCount))
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            let left = samples[frame * channelCount]
            let right = channelCount > 1
                ? samples[frame * channelCount + 1]
                : left
            append(left: left, right: right)
        }
    }

    func copyExact(
        frameCount: Int,
        to outputList: UnsafeMutablePointer<AudioBufferList>
    ) -> Bool {
        guard frameCount > 0, availableFrameCount >= frameCount else { return false }
        let outputs = UnsafeMutableAudioBufferListPointer(outputList)
        var outputChannelCount = 0
        for buffer in outputs {
            outputChannelCount += Int(buffer.mNumberChannels)
        }
        guard outputChannelCount > 0 else { return false }

        for frame in 0..<frameCount {
            let sampleIndex = readIndex * 2
            write(storage[sampleIndex], to: outputs, channel: 0, frame: frame)
            if outputChannelCount > 1 {
                write(storage[sampleIndex + 1], to: outputs, channel: 1, frame: frame)
            }
            readIndex = (readIndex + 1) % capacity
        }
        availableFrameCount -= frameCount
        return true
    }

    private func write(
        _ value: Float,
        to buffers: UnsafeMutableAudioBufferListPointer,
        channel wantedChannel: Int,
        frame: Int
    ) {
        var channelOffset = 0
        for buffer in buffers {
            let channelCount = Int(buffer.mNumberChannels)
            guard wantedChannel < channelOffset + channelCount else {
                channelOffset += channelCount
                continue
            }
            guard let data = buffer.mData else { return }
            let localChannel = wantedChannel - channelOffset
            data.assumingMemoryBound(to: Float.self)[frame * channelCount + localChannel] = value
            return
        }
    }
}
