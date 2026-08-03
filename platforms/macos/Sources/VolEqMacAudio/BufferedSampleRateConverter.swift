// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import Foundation
import VolEqCore
import VolEqDSP

private let converterNeedsMoreInput = OSStatus(bitPattern: 0x564E_4441) // 'VNDA'
private let converterOutputUnderrun = OSStatus(bitPattern: 0x564F_5552) // 'VOUR'

struct SampleRateConversionResult: Equatable {
    let producedFrameCount: Int
    let needsMoreInput: Bool
    let droppedFrameCount: Int
    let errorStatus: OSStatus?
}

/// Converts processed stereo Float32 frames to the active output-device format.
///
/// Construction and converter configuration happen off the real-time callback.
/// The callback itself only processes samples, moves ring-buffer indices, and
/// asks Audio Converter Services to perform PCM sample-rate/channel conversion.
final class BufferedSampleRateConverter {
    private let converter: AudioConverterRef
    private let inputRingBuffer: StereoFrameRingBuffer
    private let outputRingBuffer: StereoFrameRingBuffer
    private let outputChannelCount: Int
    private let scratchOutput: UnsafeMutablePointer<Float>
    private let scratchOutputFrameCapacity: Int
    private var hasStartedOutput = false
    private var consecutiveOutputUnderrunCount = 0

    init(
        inputSampleRate: Double,
        outputFormat: AudioStreamBasicDescription,
        bufferCapacityFrames: Int = 32_768
    ) throws {
        let outputChannelCount = Int(outputFormat.mChannelsPerFrame)
        guard (1...2).contains(outputChannelCount) else {
            throw VolEqError.unsupportedFormat(
                "Sample-rate conversion currently supports mono or stereo output only."
            )
        }
        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: inputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 2 * UInt32(MemoryLayout<Float>.stride),
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * UInt32(MemoryLayout<Float>.stride),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let outputBytesPerFrame = UInt32(outputChannelCount * MemoryLayout<Float>.stride)
        var converterOutputFormat = AudioStreamBasicDescription(
            mSampleRate: outputFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: outputBytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: outputBytesPerFrame,
            mChannelsPerFrame: UInt32(outputChannelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var newConverter: AudioConverterRef?
        try requireNoErr(
            AudioConverterNew(&inputFormat, &converterOutputFormat, &newConverter),
            "Create sample-rate converter"
        )
        guard let newConverter else {
            throw VolEqError.missingValue("Core Audio did not create a sample-rate converter.")
        }
        var disposeConverterOnFailure = true
        defer {
            if disposeConverterOnFailure {
                AudioConverterDispose(newConverter)
            }
        }

        var complexity = kAudioConverterSampleRateConverterComplexity_Normal
        try requireNoErr(
            AudioConverterSetProperty(
                newConverter,
                kAudioConverterSampleRateConverterComplexity,
                UInt32(MemoryLayout.size(ofValue: complexity)),
                &complexity
            ),
            "Configure sample-rate converter complexity"
        )
        var quality = kAudioConverterQuality_Medium
        try requireNoErr(
            AudioConverterSetProperty(
                newConverter,
                kAudioConverterSampleRateConverterQuality,
                UInt32(MemoryLayout.size(ofValue: quality)),
                &quality
            ),
            "Configure sample-rate converter quality"
        )

        let outputBufferCapacityFrames = max(bufferCapacityFrames, 4_096)
        converter = newConverter
        inputRingBuffer = StereoFrameRingBuffer(capacity: bufferCapacityFrames)
        outputRingBuffer = StereoFrameRingBuffer(capacity: outputBufferCapacityFrames)
        self.outputChannelCount = outputChannelCount
        scratchOutputFrameCapacity = outputBufferCapacityFrames
        scratchOutput = .allocate(
            capacity: outputBufferCapacityFrames * outputChannelCount
        )
        scratchOutput.initialize(
            repeating: 0,
            count: outputBufferCapacityFrames * outputChannelCount
        )
        disposeConverterOnFailure = false
    }

    deinit {
        scratchOutput.deinitialize(count: scratchOutputFrameCapacity * outputChannelCount)
        scratchOutput.deallocate()
        AudioConverterDispose(converter)
    }

    func appendProcessedInput(
        _ inputList: UnsafePointer<AudioBufferList>,
        processor: DynamicsProcessor
    ) -> Bool {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let channelCount = totalChannelCount(in: inputs)
        let frameCount = minimumAvailableFrameCount(in: inputs)
        guard channelCount > 0, frameCount > 0 else { return true }

        processor.beginAudioBuffer()
        for frame in 0..<frameCount {
            let left = sample(from: inputs, channel: 0, frame: frame)
            let right = sample(
                from: inputs,
                channel: min(1, channelCount - 1),
                frame: frame
            )
            let processed = processor.processFrame(left: left, right: right)
            inputRingBuffer.append(left: processed.left, right: processed.right)
        }
        return !processor.consumeProcessingFailure()
    }

    func fillOutput(
        _ outputList: UnsafeMutablePointer<AudioBufferList>
    ) -> SampleRateConversionResult {
        let outputs = UnsafeMutableAudioBufferListPointer(outputList)
        let outputFrameCapacity = minimumAvailableFrameCount(in: outputs)
        guard outputFrameCapacity > 0 else {
            return SampleRateConversionResult(
                producedFrameCount: 0,
                needsMoreInput: false,
                droppedFrameCount: totalDroppedFrameCount,
                errorStatus: nil
            )
        }
        zero(buffers: outputs)
        guard outputFrameCapacity <= outputRingBuffer.capacity else {
            return SampleRateConversionResult(
                producedFrameCount: 0,
                needsMoreInput: false,
                droppedFrameCount: totalDroppedFrameCount,
                errorStatus: converterOutputUnderrun
            )
        }

        var scratchBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(outputChannelCount),
                mDataByteSize: UInt32(
                    scratchOutputFrameCapacity
                        * outputChannelCount
                        * MemoryLayout<Float>.stride
                ),
                mData: UnsafeMutableRawPointer(scratchOutput)
            )
        )
        var requestedOutputFrames = UInt32(scratchOutputFrameCapacity)
        let status = AudioConverterFillComplexBuffer(
            converter,
            Self.provideInput,
            Unmanaged.passUnretained(self).toOpaque(),
            &requestedOutputFrames,
            &scratchBufferList,
            nil
        )
        let converterExhaustedInput = status == converterNeedsMoreInput
        let conversionError: OSStatus? = status == noErr || converterExhaustedInput
            ? nil
            : status
        guard conversionError == nil else {
            return SampleRateConversionResult(
                producedFrameCount: 0,
                needsMoreInput: false,
                droppedFrameCount: totalDroppedFrameCount,
                errorStatus: conversionError
            )
        }

        outputRingBuffer.appendInterleaved(
            UnsafePointer(scratchOutput),
            channelCount: outputChannelCount,
            frameCount: Int(requestedOutputFrames)
        )

        if !hasStartedOutput {
            // One buffered period absorbs converter priming and ordinary callback
            // jitter. Startup is a complete silent period rather than a partially
            // filled device period with an audible zero tail.
            let preRollFrames = min(
                outputRingBuffer.capacity,
                outputFrameCapacity + max(outputFrameCapacity / 2, 1)
            )
            guard outputRingBuffer.availableFrameCount >= preRollFrames else {
                return SampleRateConversionResult(
                    producedFrameCount: 0,
                    needsMoreInput: true,
                    droppedFrameCount: totalDroppedFrameCount,
                    errorStatus: nil
                )
            }
            hasStartedOutput = true
        }

        guard outputRingBuffer.availableFrameCount >= outputFrameCapacity else {
            consecutiveOutputUnderrunCount += 1
            return SampleRateConversionResult(
                producedFrameCount: 0,
                needsMoreInput: true,
                droppedFrameCount: totalDroppedFrameCount,
                errorStatus: consecutiveOutputUnderrunCount >= 3
                    ? converterOutputUnderrun
                    : nil
            )
        }

        consecutiveOutputUnderrunCount = 0
        guard outputRingBuffer.copyExact(
            frameCount: outputFrameCapacity,
            to: outputList
        ) else {
            return SampleRateConversionResult(
                producedFrameCount: 0,
                needsMoreInput: false,
                droppedFrameCount: totalDroppedFrameCount,
                errorStatus: converterOutputUnderrun
            )
        }
        return SampleRateConversionResult(
            producedFrameCount: outputFrameCapacity,
            needsMoreInput: false,
            droppedFrameCount: totalDroppedFrameCount,
            errorStatus: nil
        )
    }

    private var totalDroppedFrameCount: Int {
        inputRingBuffer.droppedFrameCount + outputRingBuffer.droppedFrameCount
    }

    private static let provideInput: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, userData in
        guard let userData else {
            ioNumberDataPackets.pointee = 0
            return converterNeedsMoreInput
        }
        let owner = Unmanaged<BufferedSampleRateConverter>
            .fromOpaque(userData)
            .takeUnretainedValue()
        return owner.provideInput(
            requestedFrameCount: ioNumberDataPackets,
            data: ioData
        )
    }

    private func provideInput(
        requestedFrameCount: UnsafeMutablePointer<UInt32>,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard let readable = inputRingBuffer.contiguousReadPointer(
            maximumFrameCount: Int(requestedFrameCount.pointee)
        ) else {
            requestedFrameCount.pointee = 0
            return converterNeedsMoreInput
        }

        requestedFrameCount.pointee = UInt32(readable.frameCount)
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mNumberChannels = 2
        data.pointee.mBuffers.mDataByteSize = UInt32(
            readable.frameCount * 2 * MemoryLayout<Float>.stride
        )
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(readable.pointer)
        inputRingBuffer.consume(frameCount: readable.frameCount)
        return noErr
    }

    private func totalChannelCount(
        in buffers: UnsafeMutableAudioBufferListPointer
    ) -> Int {
        var total = 0
        for buffer in buffers {
            total += Int(buffer.mNumberChannels)
        }
        return total
    }

    private func minimumAvailableFrameCount(
        in buffers: UnsafeMutableAudioBufferListPointer
    ) -> Int {
        var accumulator = AudioBufferFrameCountAccumulator()
        for buffer in buffers {
            accumulator.include(
                channelCount: buffer.mNumberChannels,
                dataByteSize: buffer.mDataByteSize,
                hasData: buffer.mData != nil
            )
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

    private func zero(buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }
}
