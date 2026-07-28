// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import VolEqDSP

struct AudioBufferFrameCountAccumulator {
    private var minimumFrameCount = Int.max
    private var foundUsableBuffer = false

    mutating func include(
        channelCount: UInt32,
        dataByteSize: UInt32,
        hasData: Bool
    ) {
        guard channelCount > 0, hasData else { return }

        let bytesPerFrame = MemoryLayout<Float>.stride * Int(channelCount)
        let frameCount = Int(dataByteSize) / bytesPerFrame
        minimumFrameCount = min(minimumFrameCount, frameCount)
        foundUsableBuffer = true
    }

    var value: Int {
        foundUsableBuffer ? minimumFrameCount : 0
    }
}

extension DynamicsProcessor {
    func process(
        input inputList: UnsafePointer<AudioBufferList>,
        output outputList: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let outputs = UnsafeMutableAudioBufferListPointer(outputList)

        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }

        let inputChannels = totalChannelCount(in: inputs)
        let outputChannels = totalChannelCount(in: outputs)
        guard inputChannels > 0, outputChannels > 0 else { return }

        let inputFrames = minimumAvailableFrameCount(in: inputs)
        let outputFrames = minimumAvailableFrameCount(in: outputs)
        let frameCount = min(inputFrames, outputFrames)
        guard frameCount > 0 else { return }

        beginAudioBuffer()
        for frame in 0..<frameCount {
            let left = sample(from: inputs, channel: 0, frame: frame)
            let right = sample(from: inputs, channel: min(1, inputChannels - 1), frame: frame)
            let output = processFrame(left: left, right: right)

            write(output.left, to: outputs, channel: 0, frame: frame)
            if outputChannels > 1 {
                write(output.right, to: outputs, channel: 1, frame: frame)
            }
        }
    }

    @inline(__always)
    private func totalChannelCount(
        in buffers: UnsafeMutableAudioBufferListPointer
    ) -> Int {
        var total = 0
        var index = 0
        while index < buffers.count {
            total += Int(buffers[index].mNumberChannels)
            index += 1
        }
        return total
    }

    @inline(__always)
    private func minimumAvailableFrameCount(
        in buffers: UnsafeMutableAudioBufferListPointer
    ) -> Int {
        var accumulator = AudioBufferFrameCountAccumulator()
        var index = 0
        while index < buffers.count {
            let buffer = buffers[index]
            accumulator.include(
                channelCount: buffer.mNumberChannels,
                dataByteSize: buffer.mDataByteSize,
                hasData: buffer.mData != nil
            )
            index += 1
        }
        return accumulator.value
    }

    private func sample(
        from buffers: UnsafeMutableAudioBufferListPointer,
        channel wantedChannel: Int,
        frame: Int
    ) -> Float {
        var channelOffset = 0
        for buffer in buffers {
            let channelCount = Int(buffer.mNumberChannels)
            guard wantedChannel < channelOffset + channelCount else {
                channelOffset += channelCount
                continue
            }
            guard let data = buffer.mData else { return 0 }
            let localChannel = wantedChannel - channelOffset
            return data.assumingMemoryBound(to: Float.self)[frame * channelCount + localChannel]
        }
        return 0
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
