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
    private let leftState: OpaquePointer
    private let rightState: OpaquePointer
    private var inputResampler: OpaquePointer?
    private var outputResampler: OpaquePointer?

    private var singleInputFrame = [Float](repeating: 0, count: 2)
    private var inputResamplerOutput = [Float](repeating: 0, count: 32)
    private var analysisLeft = [Float](repeating: 0, count: 480)
    private var analysisRight = [Float](repeating: 0, count: 480)
    private var denoisedLeft48K = [Float](repeating: 0, count: 480)
    private var denoisedRight48K = [Float](repeating: 0, count: 480)
    private var previousAnalysisLeft = [Float](repeating: 0, count: 480)
    private var previousAnalysisRight = [Float](repeating: 0, count: 480)
    private var olderAnalysisLeft = [Float](repeating: 0, count: 480)
    private var olderAnalysisRight = [Float](repeating: 0, count: 480)
    private var interleavedDenoised48K = [Float](repeating: 0, count: 960)
    private var outputResamplerScratch: [Float]

    private var dryLeftHistory: [Float]
    private var dryRightHistory: [Float]
    private var dryHistoryTags: [Int64]
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
    private var sourceFrameIndex: Int64 = -1
    private var wetOutputFrameIndex: Int64 = -1
    private var failed = false

    public init(sampleRate: Double, model: RNNoiseModelResource) throws {
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
        self.leftState = leftState
        self.rightState = rightState
        inputResampler = preparedInputResampler
        outputResampler = preparedOutputResampler

        outputResamplerScratch = [Float](
            repeating: 0,
            count: max(blockFrameCount * 4, Self.analysisFrameCount * 2)
        )
        let historyCapacity = max(processingLatencyFrameCount + blockFrameCount * 3, 1)
        dryLeftHistory = [Float](repeating: 0, count: historyCapacity)
        dryRightHistory = [Float](repeating: 0, count: historyCapacity)
        dryHistoryTags = [Int64](repeating: -1, count: historyCapacity)
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
    }

    public func processStereoFrame(left: Float, right: Float) -> SpeechAnalysisEvent {
        guard !failed, pendingMetadata == nil, left.isFinite, right.isFinite else {
            failed = true
            return .failed
        }
        guard drainWetFIFO() else { return fail() }
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
        failed = !statesReset || !rebuiltResamplers
        clear(&analysisLeft)
        clear(&analysisRight)
        clear(&denoisedLeft48K)
        clear(&denoisedRight48K)
        clear(&previousAnalysisLeft)
        clear(&previousAnalysisRight)
        clear(&olderAnalysisLeft)
        clear(&olderAnalysisRight)
        clear(&interleavedDenoised48K)
        clear(&outputResamplerScratch)
        clear(&dryLeftHistory)
        clear(&dryRightHistory)
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

        let leftProbability = analysisLeft.withUnsafeBufferPointer { input in
            denoisedLeft48K.withUnsafeMutableBufferPointer { output in
                rnnoise_process_frame(leftState, output.baseAddress, input.baseAddress)
            }
        }
        let rightProbability = analysisRight.withUnsafeBufferPointer { input in
            denoisedRight48K.withUnsafeMutableBufferPointer { output in
                rnnoise_process_frame(rightState, output.baseAddress, input.baseAddress)
            }
        }
        guard leftProbability.isFinite,
              rightProbability.isFinite,
              denoisedLeft48K.allSatisfy(\.isFinite),
              denoisedRight48K.allSatisfy(\.isFinite) else { return fail() }

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
        guard let leftPower = sourcePower(channel: 0, start: decisionStart),
              let rightPower = sourcePower(channel: 1, start: decisionStart) else {
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
        for index in 0..<Self.analysisFrameCount {
            olderAnalysisLeft[index] = previousAnalysisLeft[index]
            olderAnalysisRight[index] = previousAnalysisRight[index]
            previousAnalysisLeft[index] = analysisLeft[index]
            previousAnalysisRight[index] = analysisRight[index]
        }
        completedAnalysisBlockCount += 1
    }

    private func appendDenoisedOutput() -> Bool {
        for frame in 0..<Self.analysisFrameCount {
            interleavedDenoised48K[frame * 2] = denoisedLeft48K[frame] / 32_768
            interleavedDenoised48K[frame * 2 + 1] = denoisedRight48K[frame] / 32_768
        }
        if let outputResampler {
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
            for frame in 0..<Self.analysisFrameCount {
                guard enqueueWetOutput(
                    left: interleavedDenoised48K[frame * 2],
                    right: interleavedDenoised48K[frame * 2 + 1]
                ) else { return false }
            }
        }
        return drainWetFIFO()
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
        pendingStartFrameIndex = firstSourceIndex
        pendingWriteCount = 0
        while wetFIFOCount > 0, pendingWriteCount < sourceBlockFrameCount {
            let left = wetFIFOLeft[wetFIFOReadIndex]
            let right = wetFIFORight[wetFIFOReadIndex]
            let sourceIndex = wetFIFOTag[wetFIFOReadIndex]
            guard (sourceIndex / blockSize) * blockSize == blockStart else { break }
            wetFIFOReadIndex = (wetFIFOReadIndex + 1) % wetFIFOLeft.count
            wetFIFOCount -= 1
            guard sourceIndex == pendingStartFrameIndex + Int64(pendingWriteCount),
                  dryFrame(at: sourceIndex) != nil else { return false }
            pendingLeft[pendingWriteCount] = left
            pendingRight[pendingWriteCount] = right
            pendingWriteCount += 1
        }
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

    private func sourcePower(channel: Int, start: Int64) -> Float? {
        var sum: Double = 0
        for offset in 0..<sourceBlockFrameCount {
            guard let dry = dryFrame(at: start + Int64(offset)) else { return nil }
            let sample = channel == 0 ? dry.left : dry.right
            let doubleSample = Double(sample)
            sum += doubleSample * doubleSample
        }
        let average = Float(sum / Double(sourceBlockFrameCount))
        return average.isFinite ? average : nil
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
}
