// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import Foundation
import VolEqCore
import VolEqDSP
import VolEqSpeech

private let converterNeedsMoreInput = OSStatus(bitPattern: 0x564E_4441) // 'VNDA'
private let converterOutputUnderrun = OSStatus(bitPattern: 0x564F_5552) // 'VOUR'
private let callbackTimingUnavailable = OSStatus(bitPattern: 0x5643_544D) // 'VCTM'
let speechAnalysisFailed = OSStatus(bitPattern: 0x5653_5048) // 'VSPH'

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

struct SampleRateConversionResult: Equatable {
    let producedFrameCount: Int
    let needsMoreInput: Bool
    let droppedFrameCount: Int
    let errorStatus: OSStatus?
}

enum AudioSampleRatePath: Equatable {
    case directAggregateClock
    case sampleRateConverter
}

enum AudioCadenceResolution: Equatable {
    case pending
    case resolved(AudioSampleRatePath)
    case failed
}

/// Resolves the effective input/output clock relationship from hardware time.
///
/// Buffer sizes alone are not authoritative: equal frame counts at different
/// rates can describe different durations. Host-time deltas are in one common
/// clock domain, so comparing delivered frames per host tick distinguishes an
/// aggregate tap already synchronized to the output from a route that still
/// needs sample-rate conversion.
struct AudioCallbackCadenceAnalyzer {
    private static let requiredIntervalCount = 3
    private static let maximumObservationCount = 8
    private static let maximumRelativeError = 0.02
    private static let minimumErrorSeparationFraction = 0.5

    private let inputSampleRate: Double
    private let outputSampleRate: Double
    private var previousInputHostTime: UInt64?
    private var previousOutputHostTime: UInt64?
    private var previousInputFrameCount = 0
    private var previousOutputFrameCount = 0
    private var accumulatedInputFrames = 0.0
    private var accumulatedOutputFrames = 0.0
    private var accumulatedInputHostTicks = 0.0
    private var accumulatedOutputHostTicks = 0.0
    private var intervalCount = 0
    private var observationCount = 0

    init(inputSampleRate: Double, outputSampleRate: Double) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
    }

    mutating func observe(
        inputFrameCount: Int,
        inputTime: AudioTimeStamp?,
        outputFrameCount: Int,
        outputTime: AudioTimeStamp?
    ) -> AudioCadenceResolution {
        observationCount += 1
        guard
            let inputHostTime = Self.validHostTime(inputTime),
            let outputHostTime = Self.validHostTime(outputTime)
        else {
            previousInputHostTime = nil
            previousOutputHostTime = nil
            previousInputFrameCount = 0
            previousOutputFrameCount = 0
            return observationCount >= Self.maximumObservationCount ? .failed : .pending
        }

        defer {
            previousInputHostTime = inputHostTime
            previousOutputHostTime = outputHostTime
            previousInputFrameCount = inputFrameCount
            previousOutputFrameCount = outputFrameCount
        }

        guard
            let previousInputHostTime,
            let previousOutputHostTime,
            inputHostTime > previousInputHostTime,
            outputHostTime > previousOutputHostTime,
            previousInputFrameCount > 0,
            previousOutputFrameCount > 0
        else {
            return observationCount >= Self.maximumObservationCount ? .failed : .pending
        }

        accumulatedInputFrames += Double(previousInputFrameCount)
        accumulatedOutputFrames += Double(previousOutputFrameCount)
        accumulatedInputHostTicks += Double(inputHostTime - previousInputHostTime)
        accumulatedOutputHostTicks += Double(outputHostTime - previousOutputHostTime)
        intervalCount += 1

        guard intervalCount >= Self.requiredIntervalCount else { return .pending }
        let observedRateRatio = accumulatedInputFrames * accumulatedOutputHostTicks
            / (accumulatedOutputFrames * accumulatedInputHostTicks)
        let nominalRateRatio = inputSampleRate / outputSampleRate
        let directError = Self.relativeError(observedRateRatio, expected: 1)
        let conversionError = Self.relativeError(
            observedRateRatio,
            expected: nominalRateRatio
        )
        let selectedError = min(directError, conversionError)
        let errorSeparation = abs(directError - conversionError)
        // The two valid answers converge as the nominal rates get closer. Use
        // their actual distance instead of a fixed threshold so a 1 Hz
        // difference remains classifiable without accepting the midpoint.
        let expectedPathSeparation = abs(nominalRateRatio - 1)
            / max(abs(nominalRateRatio), 1)
        let requiredErrorSeparation = expectedPathSeparation
            * Self.minimumErrorSeparationFraction

        guard
            selectedError <= Self.maximumRelativeError,
            errorSeparation >= requiredErrorSeparation
        else {
            return observationCount >= Self.maximumObservationCount ? .failed : .pending
        }
        return .resolved(
            directError < conversionError
                ? .directAggregateClock
                : .sampleRateConverter
        )
    }

    private static func validHostTime(_ timestamp: AudioTimeStamp?) -> UInt64? {
        guard let timestamp else { return nil }
        let hostTimeValid = timestamp.mFlags.contains(.hostTimeValid)
        return hostTimeValid ? timestamp.mHostTime : nil
    }

    private static func relativeError(_ observed: Double, expected: Double) -> Double {
        abs(observed - expected) / max(abs(expected), 0.000_001)
    }
}

struct AudioIOProcessingDiagnostics: Equatable {
    let path: AudioSampleRatePath
    let inputFrameCount: Int
    let outputFrameCount: Int
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

final class AudioIOProcessor {
    let usesSampleRateConversion: Bool
    let inputSampleRate: Double
    let outputSampleRate: Double
    let directProcessingLatencyFrameCount: Int
    let conversionProcessingLatencyFrameCount: Int

    private let directDynamics: DynamicsProcessor
    private let conversionDynamics: DynamicsProcessor
    private let sampleRateConverter: BufferedSampleRateConverter?
    private let diagnosticsLock = NSLock()
    private let failureLock = NSLock()
    private var sharedDiagnostics: AudioIOProcessingDiagnostics?
    private var pendingFailureStatus: OSStatus?
    private var cadenceAnalyzer: AudioCallbackCadenceAnalyzer?
    private var selectedPath: AudioSampleRatePath?
    /// Written only by the serial audio callback; avoids a lock attempt per period.
    private var diagnosticsRecorded = false
    private var publishedFailure = false

    private static let sharedSpeechModel = Result<RNNoiseModelResource, Error> {
        try RNNoiseModelResource.bundled()
    }

    static func loadSpeechModel() throws -> RNNoiseModelResource {
        try sharedSpeechModel.get()
    }

    init(
        inputFormat: AudioStreamBasicDescription,
        outputFormat: AudioStreamBasicDescription,
        settings: LevelingSettings,
        speechModel: RNNoiseModelResource? = nil,
        speechAnalyzerFactory: ((Double) throws -> any SpeechAnalyzing)? = nil
    ) throws {
        inputSampleRate = inputFormat.mSampleRate
        outputSampleRate = outputFormat.mSampleRate
        let directAnalyzer: any SpeechAnalyzing
        let conversionAnalyzer: any SpeechAnalyzing
        if let speechAnalyzerFactory {
            directAnalyzer = try speechAnalyzerFactory(outputFormat.mSampleRate)
            conversionAnalyzer = try speechAnalyzerFactory(inputFormat.mSampleRate)
        } else {
            let model = try speechModel ?? Self.loadSpeechModel()
            directAnalyzer = try RNNoiseSpeechAnalyzer(
                sampleRate: outputFormat.mSampleRate,
                model: model
            )
            conversionAnalyzer = try RNNoiseSpeechAnalyzer(
                sampleRate: inputFormat.mSampleRate,
                model: model
            )
        }
        directDynamics = try DynamicsProcessor(
            sampleRate: outputFormat.mSampleRate,
            settings: settings,
            speechAnalyzer: directAnalyzer
        )
        conversionDynamics = try DynamicsProcessor(
            sampleRate: inputFormat.mSampleRate,
            settings: settings,
            speechAnalyzer: conversionAnalyzer
        )
        directProcessingLatencyFrameCount = directDynamics.latencyFrameCount
        conversionProcessingLatencyFrameCount = conversionDynamics.latencyFrameCount
        if abs(inputFormat.mSampleRate - outputFormat.mSampleRate) >= 1 {
            sampleRateConverter = try BufferedSampleRateConverter(
                inputSampleRate: inputFormat.mSampleRate,
                outputFormat: outputFormat
            )
            cadenceAnalyzer = AudioCallbackCadenceAnalyzer(
                inputSampleRate: inputFormat.mSampleRate,
                outputSampleRate: outputFormat.mSampleRate
            )
            usesSampleRateConversion = true
        } else {
            sampleRateConverter = nil
            cadenceAnalyzer = nil
            usesSampleRateConversion = false
            selectedPath = .directAggregateClock
        }
    }

    func updateSettings(_ settings: LevelingSettings) {
        directDynamics.updateSettings(settings)
        conversionDynamics.updateSettings(settings)
    }

    func currentDiagnostics() -> AudioIOProcessingDiagnostics? {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return sharedDiagnostics
    }

    /// Called by a control-thread monitor. Never call this from the audio callback.
    func takePendingFailure() -> OSStatus? {
        failureLock.lock()
        defer { failureLock.unlock() }
        let failure = pendingFailureStatus
        pendingFailureStatus = nil
        return failure
    }

    func process(
        input: UnsafePointer<AudioBufferList>,
        inputTime: AudioTimeStamp? = nil,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputTime: AudioTimeStamp? = nil
    ) {
        let inputFrameCount = Self.minimumAvailableFrameCount(in: input)
        let outputFrameCount = Self.minimumAvailableFrameCount(in: output)
        guard outputFrameCount > 0 else { return }
        guard inputFrameCount > 0 else {
            Self.clear(output: output)
            return
        }

        guard let sampleRateConverter else {
            recordDiagnosticsIfNeeded(
                path: .directAggregateClock,
                inputFrameCount: inputFrameCount,
                outputFrameCount: outputFrameCount
            )
            guard directDynamics.process(input: input, output: output) else {
                Self.clear(output: output)
                reportConversionFailureIfNeeded(speechAnalysisFailed)
                return
            }
            return
        }

        let path: AudioSampleRatePath
        if let selectedPath {
            path = selectedPath
        } else {
            guard var cadenceAnalyzer else {
                Self.clear(output: output)
                reportConversionFailureIfNeeded(callbackTimingUnavailable)
                return
            }
            let resolution = cadenceAnalyzer.observe(
                inputFrameCount: inputFrameCount,
                inputTime: inputTime,
                outputFrameCount: outputFrameCount,
                outputTime: outputTime
            )
            self.cadenceAnalyzer = cadenceAnalyzer
            switch resolution {
            case .pending:
                Self.clear(output: output)
                return
            case let .resolved(resolvedPath):
                selectedPath = resolvedPath
                path = resolvedPath
            case .failed:
                Self.clear(output: output)
                reportConversionFailureIfNeeded(callbackTimingUnavailable)
                return
            }
        }
        recordDiagnosticsIfNeeded(
            path: path,
            inputFrameCount: inputFrameCount,
            outputFrameCount: outputFrameCount
        )

        guard path == .sampleRateConverter else {
            guard directDynamics.process(input: input, output: output) else {
                Self.clear(output: output)
                reportConversionFailureIfNeeded(speechAnalysisFailed)
                return
            }
            return
        }

        guard sampleRateConverter.appendProcessedInput(input, processor: conversionDynamics) else {
            Self.clear(output: output)
            reportConversionFailureIfNeeded(speechAnalysisFailed)
            return
        }
        let result = sampleRateConverter.fillOutput(output)
        if let errorStatus = result.errorStatus {
            reportConversionFailureIfNeeded(errorStatus)
        }
    }

    private func reportConversionFailureIfNeeded(_ status: OSStatus) {
        guard !publishedFailure, failureLock.try() else { return }
        defer { failureLock.unlock() }
        guard pendingFailureStatus == nil else { return }
        pendingFailureStatus = status
        publishedFailure = true
    }

    private func recordDiagnosticsIfNeeded(
        path: AudioSampleRatePath,
        inputFrameCount: Int,
        outputFrameCount: Int
    ) {
        guard !diagnosticsRecorded, diagnosticsLock.try() else { return }
        defer { diagnosticsLock.unlock() }
        guard sharedDiagnostics == nil else { return }
        sharedDiagnostics = AudioIOProcessingDiagnostics(
            path: path,
            inputFrameCount: inputFrameCount,
            outputFrameCount: outputFrameCount
        )
        diagnosticsRecorded = true
    }

    private static func minimumAvailableFrameCount(
        in list: UnsafePointer<AudioBufferList>
    ) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list)
        )
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

    private static func minimumAvailableFrameCount(
        in list: UnsafeMutablePointer<AudioBufferList>
    ) -> Int {
        minimumAvailableFrameCount(in: UnsafePointer(list))
    }

    private static func clear(output list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }
}
