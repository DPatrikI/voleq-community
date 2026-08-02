// SPDX-License-Identifier: MPL-2.0

import CRNNoise
import CSpeexResampler
import Foundation

/// Two-channel RNNoise processing with source-time-aligned, allocation-free output.
public final class RNNoiseStereoProcessor: StereoSpeechProcessing, @unchecked Sendable {
    public let sourceSampleRate: Double
    public let sourceBlockFrameCount: Int
    public let decisionLatencyFrameCount: Int
    public let processingLatencyFrameCount: Int
    public let inputResamplerLatencyFrameCount: Int
    public let outputResamplerLatencyFrameCount: Int

    private static let analysisSampleRate: UInt32 = 48_000
    private static let analysisFrameCount = 480
    private static let resamplerQuality: Int32 = 3
    private static let channelCount: UInt32 = 2
    private static let insignificantPower: Double = 1e-12

    private let modelResource: RNNoiseModelResource
    private let usesOptimizedPairedInference: Bool
    private let leftState: OpaquePointer
    private let rightState: OpaquePointer
    private var inputResampler: OpaquePointer?
    private var outputResampler: OpaquePointer?

    private var singleInputFrame = [Float](repeating: 0, count: 2)
    private var inputResamplerOutput = [Float](repeating: 0, count: 32)
    private var analysisLeft: UnsafeMutableBufferPointer<Float>
    private var analysisRight: UnsafeMutableBufferPointer<Float>
    private var denoisedLeft48K = [Float](repeating: 0, count: 480)
    private var denoisedRight48K = [Float](repeating: 0, count: 480)
    private var previousAnalysisLeft: UnsafeMutableBufferPointer<Float>
    private var previousAnalysisRight: UnsafeMutableBufferPointer<Float>
    private var olderAnalysisLeft: UnsafeMutableBufferPointer<Float>
    private var olderAnalysisRight: UnsafeMutableBufferPointer<Float>
    private var interleavedDenoised48K = [Float](repeating: 0, count: 960)
    private var outputResamplerScratch: [Float]

    private let dryLeftHistory: UnsafeMutableBufferPointer<Float>
    private let dryRightHistory: UnsafeMutableBufferPointer<Float>
    private let dryHistoryTags: UnsafeMutableBufferPointer<Int64>
    private var decisionHistoryStart: [Int64]
    private var decisionHistoryProbability: [Float]
    private var decisionHistoryPower: [Float]
    private var decisionHistorySNR: [Float]

    private var pendingLeft: [Float]
    private var pendingRight: [Float]
    private var pendingMetadata: DenoisedSpeechBlock?
    private var pendingWriteCount = 0
    private var pendingStartFrameIndex: Int64 = 0

    private var wetFIFOLeft: [Float]
    private var wetFIFORight: [Float]
    private var wetFIFOTag: [Int64]
    private var wetFIFOReadIndex = 0
    private var wetFIFOWriteIndex = 0
    private var wetFIFOCount = 0

    private var analysisWriteCount = 0
    private var completedAnalysisBlockCount = 0
    private var optimizedInferencePairCount = 0
    private var sourceFrameIndex: Int64 = -1
    private var wetOutputFrameIndex: Int64 = -1
    private var failed = false

    public convenience init(sampleRate: Double, model: RNNoiseModelResource) throws {
        try self.init(sampleRate: sampleRate, model: model, usesOptimizedPairedInference: true)
    }

    init(
        sampleRate: Double,
        model: RNNoiseModelResource,
        usesOptimizedPairedInference: Bool
    ) throws {
        guard sampleRate.isFinite,
              sampleRate >= 8_000,
              sampleRate <= 192_000,
              sampleRate.rounded() == sampleRate else {
            throw SpeechAnalyzerError.unsupportedSampleRate(sampleRate)
        }
        let rnnoiseFrameCount = Int(rnnoise_get_frame_size())
        guard rnnoiseFrameCount == Self.analysisFrameCount else {
            throw SpeechAnalyzerError.unexpectedFrameSize(rnnoiseFrameCount)
        }
        guard let leftState = rnnoise_create(model.model) else {
            throw SpeechAnalyzerError.stateCreationFailed
        }
        guard let rightState = rnnoise_create(model.model) else {
            rnnoise_destroy(leftState)
            throw SpeechAnalyzerError.stateCreationFailed
        }

        let sourceRate = UInt32(sampleRate)
        let blockFrameCount = Int((sampleRate * 0.010).rounded())
        var preparedInputResampler: OpaquePointer?
        var preparedOutputResampler: OpaquePointer?
        var inputLatency = 0
        var outputLatency = 0
        if sourceRate != Self.analysisSampleRate {
            var inputError: Int32 = 0
            preparedInputResampler = voleq_speex_resampler_init(
                Self.channelCount,
                sourceRate,
                Self.analysisSampleRate,
                Self.resamplerQuality,
                &inputError
            )
            guard preparedInputResampler != nil, inputError == 0 else {
                rnnoise_destroy(rightState)
                rnnoise_destroy(leftState)
                throw SpeechAnalyzerError.resamplerCreationFailed(inputError)
            }
            var outputError: Int32 = 0
            preparedOutputResampler = voleq_speex_resampler_init(
                Self.channelCount,
                Self.analysisSampleRate,
                sourceRate,
                Self.resamplerQuality,
                &outputError
            )
            guard preparedOutputResampler != nil, outputError == 0 else {
                if let preparedInputResampler {
                    voleq_speex_resampler_destroy(preparedInputResampler)
                }
                rnnoise_destroy(rightState)
                rnnoise_destroy(leftState)
                throw SpeechAnalyzerError.resamplerCreationFailed(outputError)
            }
            inputLatency = Int(voleq_speex_resampler_get_input_latency(preparedInputResampler))
            outputLatency = Int(voleq_speex_resampler_get_output_latency(preparedOutputResampler))
        }

        sourceSampleRate = sampleRate
        sourceBlockFrameCount = blockFrameCount
        inputResamplerLatencyFrameCount = inputLatency
        outputResamplerLatencyFrameCount = outputLatency
        decisionLatencyFrameCount = blockFrameCount + inputLatency
        processingLatencyFrameCount = blockFrameCount * 3 + inputLatency + outputLatency
        modelResource = model
        self.usesOptimizedPairedInference = usesOptimizedPairedInference
        self.leftState = leftState
        self.rightState = rightState
        inputResampler = preparedInputResampler
        outputResampler = preparedOutputResampler

        outputResamplerScratch = [Float](
            repeating: 0,
            count: max(blockFrameCount * 4, Self.analysisFrameCount * 2)
        )
        analysisLeft = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        analysisRight = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        previousAnalysisLeft = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        previousAnalysisRight = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        olderAnalysisLeft = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        olderAnalysisRight = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        let historyCapacity = max(processingLatencyFrameCount + blockFrameCount * 3, 1)
        dryLeftHistory = Self.allocateBuffer(repeating: 0, count: historyCapacity)
        dryRightHistory = Self.allocateBuffer(repeating: 0, count: historyCapacity)
        dryHistoryTags = Self.allocateBuffer(repeating: -1, count: historyCapacity)
        decisionHistoryStart = [Int64](repeating: -1, count: 8)
        decisionHistoryProbability = [Float](repeating: 0, count: 8)
        decisionHistoryPower = [Float](repeating: 0, count: 8)
        decisionHistorySNR = [Float](repeating: .nan, count: 8)
        pendingLeft = [Float](repeating: 0, count: blockFrameCount)
        pendingRight = [Float](repeating: 0, count: blockFrameCount)
        let wetFIFOCapacity = max(blockFrameCount * 4, 2_048)
        wetFIFOLeft = [Float](repeating: 0, count: wetFIFOCapacity)
        wetFIFORight = [Float](repeating: 0, count: wetFIFOCapacity)
        wetFIFOTag = [Int64](repeating: -1, count: wetFIFOCapacity)
    }

    deinit {
        if let inputResampler { voleq_speex_resampler_destroy(inputResampler) }
        if let outputResampler { voleq_speex_resampler_destroy(outputResampler) }
        rnnoise_destroy(rightState)
        rnnoise_destroy(leftState)
        dryLeftHistory.deinitialize()
        dryLeftHistory.baseAddress?.deallocate()
        dryRightHistory.deinitialize()
        dryRightHistory.baseAddress?.deallocate()
        dryHistoryTags.deinitialize()
        dryHistoryTags.baseAddress?.deallocate()
        Self.deallocateBuffer(analysisLeft)
        Self.deallocateBuffer(analysisRight)
        Self.deallocateBuffer(previousAnalysisLeft)
        Self.deallocateBuffer(previousAnalysisRight)
        Self.deallocateBuffer(olderAnalysisLeft)
        Self.deallocateBuffer(olderAnalysisRight)
    }

    public func processStereoFrame(left: Float, right: Float) -> SpeechAnalysisEvent {
        guard !failed, pendingMetadata == nil, left.isFinite, right.isFinite else {
            failed = true
            return .failed
        }
        if wetFIFOCount > 0, !drainWetFIFO() { return fail() }
        sourceFrameIndex += 1
        storeDry(left: left, right: right, at: sourceFrameIndex)

        if let inputResampler {
            singleInputFrame[0] = min(max(left, -1), 1)
            singleInputFrame[1] = min(max(right, -1), 1)
            var inputLength: UInt32 = 1
            var outputLength = UInt32(inputResamplerOutput.count / 2)
            let status = singleInputFrame.withUnsafeBufferPointer { input in
                inputResamplerOutput.withUnsafeMutableBufferPointer { output in
                    voleq_speex_resampler_process_interleaved_float(
                        inputResampler,
                        input.baseAddress,
                        &inputLength,
                        output.baseAddress,
                        &outputLength
                    )
                }
            }
            guard status == 0, inputLength == 1 else { return fail() }
            var event: SpeechAnalysisEvent = .pending
            for frame in 0..<Int(outputLength) {
                event = appendAnalysisFrame(
                    left: inputResamplerOutput[frame * 2],
                    right: inputResamplerOutput[frame * 2 + 1]
                )
                if failed { return .failed }
            }
            return event
        }
        return appendAnalysisFrame(
            left: min(max(left, -1), 1),
            right: min(max(right, -1), 1)
        )
    }

    public var pendingDenoisedBlock: DenoisedSpeechBlock? { pendingMetadata }

    package var completedOptimizedInferencePairCount: Int { optimizedInferencePairCount }

    public func denoisedSample(frame: Int, channel: Int) -> Float {
        guard pendingMetadata != nil, pendingLeft.indices.contains(frame) else { return 0 }
        return channel == 0 ? pendingLeft[frame] : pendingRight[frame]
    }

    public func consumeDenoisedBlock() {
        pendingMetadata = nil
    }

    public func reset() {
        let statesReset = rnnoise_init(leftState, modelResource.model) == 0
            && rnnoise_init(rightState, modelResource.model) == 0
        let rebuiltResamplers = rebuildResamplers()
        analysisWriteCount = 0
        sourceFrameIndex = -1
        wetOutputFrameIndex = -1
        wetFIFOReadIndex = 0
        wetFIFOWriteIndex = 0
        wetFIFOCount = 0
        pendingWriteCount = 0
        pendingStartFrameIndex = 0
        pendingMetadata = nil
        completedAnalysisBlockCount = 0
        optimizedInferencePairCount = 0
        failed = !statesReset || !rebuiltResamplers
        clear(analysisLeft)
        clear(analysisRight)
        clear(&denoisedLeft48K)
        clear(&denoisedRight48K)
        clear(previousAnalysisLeft)
        clear(previousAnalysisRight)
        clear(olderAnalysisLeft)
        clear(olderAnalysisRight)
        clear(&interleavedDenoised48K)
        clear(&outputResamplerScratch)
        for index in dryLeftHistory.indices { dryLeftHistory[index] = 0 }
        for index in dryRightHistory.indices { dryRightHistory[index] = 0 }
        for index in dryHistoryTags.indices { dryHistoryTags[index] = -1 }
        for index in decisionHistoryStart.indices { decisionHistoryStart[index] = -1 }
        for index in decisionHistorySNR.indices { decisionHistorySNR[index] = .nan }
    }

    /// Speex's memory reset does not clear all of its internal buffered storage.
    /// Reset is a control-thread operation, so reconstruct converters to guarantee
    /// the same state as a newly prepared route without touching the callback.
    private func rebuildResamplers() -> Bool {
        guard UInt32(sourceSampleRate) != Self.analysisSampleRate else {
            return inputResampler == nil && outputResampler == nil
        }
        if let inputResampler { voleq_speex_resampler_destroy(inputResampler) }
        if let outputResampler { voleq_speex_resampler_destroy(outputResampler) }
        inputResampler = nil
        outputResampler = nil

        let sourceRate = UInt32(sourceSampleRate)
        var inputError: Int32 = 0
        guard let replacementInput = voleq_speex_resampler_init(
            Self.channelCount,
            sourceRate,
            Self.analysisSampleRate,
            Self.resamplerQuality,
            &inputError
        ), inputError == 0 else {
            return false
        }
        var outputError: Int32 = 0
        guard let replacementOutput = voleq_speex_resampler_init(
            Self.channelCount,
            Self.analysisSampleRate,
            sourceRate,
            Self.resamplerQuality,
            &outputError
        ), outputError == 0 else {
            voleq_speex_resampler_destroy(replacementInput)
            return false
        }
        inputResampler = replacementInput
        outputResampler = replacementOutput
        return true
    }

    private func appendAnalysisFrame(left: Float, right: Float) -> SpeechAnalysisEvent {
        guard left.isFinite, right.isFinite else { return fail() }
        analysisLeft[analysisWriteCount] = left * 32_768
        analysisRight[analysisWriteCount] = right * 32_768
        analysisWriteCount += 1
        guard analysisWriteCount == Self.analysisFrameCount else { return .pending }
        analysisWriteCount = 0

        let leftProbability: Float
        var rightProbability: Float
        if usesOptimizedPairedInference {
            rightProbability = 0
            leftProbability = denoisedLeft48K.withUnsafeMutableBufferPointer { leftOutput in
                denoisedRight48K.withUnsafeMutableBufferPointer { rightOutput in
                    rnnoise_process_frame_pair(
                        leftState,
                        leftOutput.baseAddress,
                        analysisLeft.baseAddress,
                        rightState,
                        rightOutput.baseAddress,
                        analysisRight.baseAddress,
                        &rightProbability
                    )
                }
            }
        } else {
            leftProbability = denoisedLeft48K.withUnsafeMutableBufferPointer { output in
                rnnoise_process_frame(leftState, output.baseAddress, analysisLeft.baseAddress)
            }
            rightProbability = denoisedRight48K.withUnsafeMutableBufferPointer { output in
                rnnoise_process_frame(rightState, output.baseAddress, analysisRight.baseAddress)
            }
        }
        guard leftProbability.isFinite,
              rightProbability.isFinite else { return fail() }
        if usesOptimizedPairedInference { optimizedInferencePairCount += 1 }

        let approximateDecisionStart = sourceFrameIndex + 1
            - Int64(decisionLatencyFrameCount)
        let blockSize = Int64(sourceBlockFrameCount)
        let decisionStart = max(
            ((approximateDecisionStart + blockSize / 2) / blockSize) * blockSize,
            0
        )
        let decisionEnd = decisionStart + Int64(sourceBlockFrameCount - 1)
        guard decisionStart >= 0,
              dryFrame(at: decisionStart) != nil,
              dryFrame(at: decisionEnd) != nil else {
            // Input-resampler pre-roll may complete an analysis frame before a full
            // source-time decision window exists. Its denoised output is warm-up only.
            return appendDenoisedOutputWithoutDecision()
        }
        guard let (leftPower, rightPower) = sourcePowers(start: decisionStart) else {
            return fail()
        }
        let useLeft = leftProbability >= rightProbability
        let probability = min(max(useLeft ? leftProbability : rightProbability, 0), 1)
        let power = max(useLeft ? leftPower : rightPower, 0)
        let result = SpeechAnalysisResult(
            probability: probability,
            sourcePower: power,
            sourceFrameCount: sourceBlockFrameCount,
            analysisLatencyFrameCount: decisionLatencyFrameCount
        )
        storeDecision(result, start: decisionStart)
        if completedAnalysisBlockCount >= 2 {
            storeEstimatedSNR(for: decisionStart - Int64(sourceBlockFrameCount * 2))
        }
        guard appendDenoisedOutput() else { return fail() }
        advanceAnalysisHistory()
        return .result(result)
    }

    private func appendDenoisedOutputWithoutDecision() -> SpeechAnalysisEvent {
        guard appendDenoisedOutput() else { return fail() }
        advanceAnalysisHistory()
        return .pending
    }

    private func advanceAnalysisHistory() {
        let recycledLeft = olderAnalysisLeft
        olderAnalysisLeft = previousAnalysisLeft
        previousAnalysisLeft = analysisLeft
        analysisLeft = recycledLeft
        let recycledRight = olderAnalysisRight
        olderAnalysisRight = previousAnalysisRight
        previousAnalysisRight = analysisRight
        analysisRight = recycledRight
        completedAnalysisBlockCount += 1
    }

    private func appendDenoisedOutput() -> Bool {
        if let outputResampler {
            for frame in 0..<Self.analysisFrameCount {
                let left = denoisedLeft48K[frame] / 32_768
                let right = denoisedRight48K[frame] / 32_768
                guard left.isFinite, right.isFinite else { return false }
                interleavedDenoised48K[frame * 2] = left
                interleavedDenoised48K[frame * 2 + 1] = right
            }
            var inputLength = UInt32(Self.analysisFrameCount)
            var outputLength = UInt32(outputResamplerScratch.count / 2)
            let status = interleavedDenoised48K.withUnsafeBufferPointer { input in
                outputResamplerScratch.withUnsafeMutableBufferPointer { output in
                    voleq_speex_resampler_process_interleaved_float(
                        outputResampler,
                        input.baseAddress,
                        &inputLength,
                        output.baseAddress,
                        &outputLength
                    )
                }
            }
            guard status == 0, inputLength == Self.analysisFrameCount else { return false }
            for frame in 0..<Int(outputLength) {
                guard enqueueWetOutput(
                    left: outputResamplerScratch[frame * 2],
                    right: outputResamplerScratch[frame * 2 + 1]
                ) else { return false }
            }
        } else {
            return prepareDenoisedOutput48KBlock()
        }
        return drainWetFIFO()
    }

    private func prepareDenoisedOutput48KBlock() -> Bool {
        let outputStart = wetOutputFrameIndex + 1
        wetOutputFrameIndex += Int64(Self.analysisFrameCount)
        let sourceOffset = Int64(sourceBlockFrameCount * 2)
        let sourceStart = outputStart - sourceOffset
        guard sourceStart >= 0 else {
            for frame in 0..<Self.analysisFrameCount {
                guard denoisedLeft48K[frame].isFinite,
                      denoisedRight48K[frame].isFinite else { return false }
            }
            return true
        }
        let blockSize = Int64(sourceBlockFrameCount)
        guard sourceStart % blockSize == 0,
              pendingMetadata == nil,
              let decision = decision(at: sourceStart) else { return false }
        let dryCapacity = dryHistoryTags.count
        let succeeded = denoisedLeft48K.withUnsafeBufferPointer { left in
            denoisedRight48K.withUnsafeBufferPointer { right in
                pendingLeft.withUnsafeMutableBufferPointer { outputLeft in
                    pendingRight.withUnsafeMutableBufferPointer { outputRight in
                        for frame in 0..<sourceBlockFrameCount {
                            let sourceIndex = sourceStart + Int64(frame)
                            let drySlot = Int(sourceIndex % Int64(dryCapacity))
                            guard dryHistoryTags[drySlot] == sourceIndex else { return false }
                            let scaledLeft = left[frame] / 32_768
                            let scaledRight = right[frame] / 32_768
                            guard scaledLeft.isFinite, scaledRight.isFinite else {
                                return false
                            }
                            outputLeft[frame] = scaledLeft
                            outputRight[frame] = scaledRight
                        }
                        return true
                    }
                }
            }
        }
        guard succeeded else { return false }
        pendingStartFrameIndex = sourceStart
        pendingWriteCount = sourceBlockFrameCount
        pendingMetadata = DenoisedSpeechBlock(
            sourceStartFrameIndex: sourceStart,
            sourceFrameCount: sourceBlockFrameCount,
            speechProbability: decision.probability,
            sourcePower: decision.power,
            estimatedSNRDB: decision.snrDB
        )
        return true
    }

    private func enqueueWetOutput(left: Float, right: Float) -> Bool {
        guard left.isFinite, right.isFinite else { return false }
        wetOutputFrameIndex += 1
        let sourceIndex = wetOutputFrameIndex
            - Int64(sourceBlockFrameCount * 2)
            - Int64(inputResamplerLatencyFrameCount + outputResamplerLatencyFrameCount)
        guard sourceIndex >= 0 else { return true }
        guard wetFIFOCount < wetFIFOLeft.count else { return false }
        wetFIFOLeft[wetFIFOWriteIndex] = left
        wetFIFORight[wetFIFOWriteIndex] = right
        wetFIFOTag[wetFIFOWriteIndex] = sourceIndex
        wetFIFOWriteIndex = (wetFIFOWriteIndex + 1) % wetFIFOLeft.count
        wetFIFOCount += 1
        return true
    }

    private func drainWetFIFO() -> Bool {
        guard wetFIFOCount > 0, pendingMetadata == nil else { return true }
        let firstSourceIndex = wetFIFOTag[wetFIFOReadIndex]
        let blockSize = Int64(sourceBlockFrameCount)
        let blockStart = (firstSourceIndex / blockSize) * blockSize
        guard let decision = decision(at: blockStart) else { return false }
        var readIndex = wetFIFOReadIndex
        var fifoCount = wetFIFOCount
        var writeCount = 0
        let fifoCapacity = wetFIFOLeft.count
        let dryCapacity = dryHistoryTags.count
        let succeeded = wetFIFOLeft.withUnsafeBufferPointer { fifoLeft in
            wetFIFORight.withUnsafeBufferPointer { fifoRight in
                wetFIFOTag.withUnsafeBufferPointer { fifoTag in
                    pendingLeft.withUnsafeMutableBufferPointer { outputLeft in
                        pendingRight.withUnsafeMutableBufferPointer { outputRight in
                            while fifoCount > 0, writeCount < sourceBlockFrameCount {
                                let sourceIndex = fifoTag[readIndex]
                                guard (sourceIndex / blockSize) * blockSize == blockStart else {
                                    break
                                }
                                guard sourceIndex == firstSourceIndex + Int64(writeCount) else {
                                    return false
                                }
                                guard sourceIndex >= 0 else { return false }
                                let drySlot = Int(sourceIndex % Int64(dryCapacity))
                                guard dryHistoryTags[drySlot] == sourceIndex else {
                                    return false
                                }
                                outputLeft[writeCount] = fifoLeft[readIndex]
                                outputRight[writeCount] = fifoRight[readIndex]
                                writeCount += 1
                                readIndex += 1
                                if readIndex == fifoCapacity { readIndex = 0 }
                                fifoCount -= 1
                            }
                            return true
                        }
                    }
                }
            }
        }
        guard succeeded else { return false }
        pendingStartFrameIndex = firstSourceIndex
        pendingWriteCount = writeCount
        wetFIFOReadIndex = readIndex
        wetFIFOCount = fifoCount
        pendingMetadata = DenoisedSpeechBlock(
            sourceStartFrameIndex: pendingStartFrameIndex,
            sourceFrameCount: pendingWriteCount,
            speechProbability: decision.probability,
            sourcePower: decision.power,
            estimatedSNRDB: decision.snrDB
        )
        return true
    }

    private func storeDry(left: Float, right: Float, at index: Int64) {
        let slot = Int(index % Int64(dryHistoryTags.count))
        dryLeftHistory[slot] = left
        dryRightHistory[slot] = right
        dryHistoryTags[slot] = index
    }

    private func dryFrame(at index: Int64) -> (left: Float, right: Float)? {
        guard index >= 0 else { return nil }
        let slot = Int(index % Int64(dryHistoryTags.count))
        guard dryHistoryTags[slot] == index else { return nil }
        return (dryLeftHistory[slot], dryRightHistory[slot])
    }

    private func sourcePowers(start: Int64) -> (left: Float, right: Float)? {
        var leftSum: Double = 0
        var rightSum: Double = 0
        for offset in 0..<sourceBlockFrameCount {
            guard let dry = dryFrame(at: start + Int64(offset)) else { return nil }
            let left = Double(dry.left)
            let right = Double(dry.right)
            leftSum += left * left
            rightSum += right * right
        }
        let count = Double(sourceBlockFrameCount)
        let left = Float(leftSum / count)
        let right = Float(rightSum / count)
        return left.isFinite && right.isFinite ? (left, right) : nil
    }

    private func storeDecision(_ result: SpeechAnalysisResult, start: Int64) {
        let block = start / Int64(sourceBlockFrameCount)
        let slot = Int(block % Int64(decisionHistoryStart.count))
        decisionHistoryStart[slot] = start
        decisionHistoryProbability[slot] = result.probability
        decisionHistoryPower[slot] = result.sourcePower
        decisionHistorySNR[slot] = .nan
    }

    private func decision(
        at start: Int64
    ) -> (probability: Float, power: Float, snrDB: Float?)? {
        let block = start / Int64(sourceBlockFrameCount)
        let slot = Int(block % Int64(decisionHistoryStart.count))
        guard decisionHistoryStart[slot] == start else { return nil }
        let snr = decisionHistorySNR[slot]
        return (
            decisionHistoryProbability[slot],
            decisionHistoryPower[slot],
            snr.isFinite ? snr : nil
        )
    }

    private func storeEstimatedSNR(for sourceStart: Int64) {
        guard sourceStart >= 0 else { return }
        let block = sourceStart / Int64(sourceBlockFrameCount)
        let slot = Int(block % Int64(decisionHistoryStart.count))
        guard decisionHistoryStart[slot] == sourceStart else { return }
        var dryPower: Double = 0
        var wetPower: Double = 0
        for index in 0..<Self.analysisFrameCount {
            let dryLeft = Double(olderAnalysisLeft[index])
            let dryRight = Double(olderAnalysisRight[index])
            let wetLeft = Double(denoisedLeft48K[index])
            let wetRight = Double(denoisedRight48K[index])
            dryPower += dryLeft * dryLeft + dryRight * dryRight
            wetPower += wetLeft * wetLeft + wetRight * wetRight
        }
        let removedPower = max(dryPower - wetPower, 0)
        guard removedPower > Self.insignificantPower,
              wetPower > Self.insignificantPower else {
            decisionHistorySNR[slot] = .nan
            return
        }
        let snr = Float(10 * log10(wetPower / removedPower))
        decisionHistorySNR[slot] = snr.isFinite ? snr : .nan
    }

    private func fail() -> SpeechAnalysisEvent {
        failed = true
        return .failed
    }

    private func clear(_ values: inout [Float]) {
        for index in values.indices { values[index] = 0 }
    }

    private func clear(_ values: UnsafeMutableBufferPointer<Float>) {
        for index in values.indices { values[index] = 0 }
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
