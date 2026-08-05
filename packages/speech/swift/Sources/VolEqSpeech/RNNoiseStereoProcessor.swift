// SPDX-License-Identifier: MPL-2.0

import CRNNoise
import Foundation

/// Two-channel RNNoise processing with source-time-aligned, allocation-free output.
public final class RNNoiseStereoProcessor: StereoSpeechProcessing, @unchecked Sendable {
    public let sourceSampleRate: Double
    public let sourceBlockFrameCount: Int
    public let decisionLatencyFrameCount: Int
    public let processingLatencyFrameCount: Int
    public let inputResamplerLatencyFrameCount: Int
    public let outputResamplerLatencyFrameCount: Int

    private let inferenceEngine: RNNoiseInferenceEngine
    private let resampler: RNNoiseResampler
    private let dryHistory: RNNoiseTaggedStereoHistory
    private let decisionHistory = RNNoiseDecisionHistory()
    private let wetFIFO: RNNoiseWetOutputFIFO

    private var pendingLeft: [Float]
    private var pendingRight: [Float]
    private var pendingMetadata: DenoisedSpeechBlock?

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
        let blockFrameCount = try RNNoiseFixedBlockSampleRate.sourceBlockFrameCount(
            for: sampleRate
        )
        let rnnoiseFrameCount = Int(rnnoise_get_frame_size())
        guard rnnoiseFrameCount == RNNoiseInferenceEngine.analysisFrameCount else {
            throw SpeechAnalyzerError.unexpectedFrameSize(rnnoiseFrameCount)
        }

        let preparedResampler = try RNNoiseResampler(
            sampleRate: sampleRate,
            sourceBlockFrameCount: blockFrameCount
        )
        let preparedInference = try RNNoiseInferenceEngine(
            model: model,
            usesOptimizedPairedInference: usesOptimizedPairedInference
        )

        sourceSampleRate = sampleRate
        sourceBlockFrameCount = blockFrameCount
        inputResamplerLatencyFrameCount = preparedResampler.inputResamplerLatencyFrameCount
        outputResamplerLatencyFrameCount = preparedResampler.outputResamplerLatencyFrameCount
        decisionLatencyFrameCount = blockFrameCount + inputResamplerLatencyFrameCount
        processingLatencyFrameCount = blockFrameCount * 3
            + inputResamplerLatencyFrameCount
            + outputResamplerLatencyFrameCount
        resampler = preparedResampler
        inferenceEngine = preparedInference

        let historyCapacity = max(processingLatencyFrameCount + blockFrameCount * 3, 1)
        dryHistory = RNNoiseTaggedStereoHistory(capacity: historyCapacity)
        let wetFIFOCapacity = max(blockFrameCount * 4, 2_048)
        wetFIFO = RNNoiseWetOutputFIFO(capacity: wetFIFOCapacity)
        pendingLeft = [Float](repeating: 0, count: blockFrameCount)
        pendingRight = [Float](repeating: 0, count: blockFrameCount)
    }

    public func processStereoFrame(left: Float, right: Float) -> SpeechAnalysisEvent {
        guard !failed, pendingMetadata == nil, left.isFinite, right.isFinite else {
            failed = true
            return .failed
        }
        if wetFIFO.count > 0, !drainWetFIFO() { return fail() }
        sourceFrameIndex += 1
        dryHistory.store(left: left, right: right, at: sourceFrameIndex)

        if resampler.hasInputResampler {
            guard let outputFrameCount = resampler.processInputFrame(left: left, right: right),
                  outputFrameCount >= 0 else {
                return fail()
            }
            var event: SpeechAnalysisEvent = .pending
            for frame in 0..<outputFrameCount {
                event = appendAnalysisFrame(
                    left: resampler.inputFrame(at: frame).left,
                    right: resampler.inputFrame(at: frame).right
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

    package var completedOptimizedInferencePairCount: Int {
        inferenceEngine.optimizedInferencePairCount
    }

    public func denoisedSample(frame: Int, channel: Int) -> Float {
        guard pendingMetadata != nil, pendingLeft.indices.contains(frame) else { return 0 }
        return channel == 0 ? pendingLeft[frame] : pendingRight[frame]
    }

    public func consumeDenoisedBlock() {
        pendingMetadata = nil
    }

    public func reset() {
        let statesReset = inferenceEngine.reset()
        let rebuiltResamplers = resampler.reset()
        sourceFrameIndex = -1
        wetOutputFrameIndex = -1
        pendingMetadata = nil
        failed = !statesReset || !rebuiltResamplers
        dryHistory.reset()
        decisionHistory.reset()
        wetFIFO.reset()
    }

    private func appendAnalysisFrame(left: Float, right: Float) -> SpeechAnalysisEvent {
        guard left.isFinite, right.isFinite else { return fail() }
        switch inferenceEngine.appendSample(left: left, right: right) {
        case .pending:
            return .pending
        case .failed:
            return fail()
        case let .completed(inference):
            let approximateDecisionStart = sourceFrameIndex + 1
                - Int64(decisionLatencyFrameCount)
            let blockSize = Int64(sourceBlockFrameCount)
            let decisionStart = max(
                ((approximateDecisionStart + blockSize / 2) / blockSize) * blockSize,
                0
            )
            let decisionEnd = decisionStart + Int64(sourceBlockFrameCount - 1)
            guard decisionStart >= 0,
                  dryHistory.frame(at: decisionStart) != nil,
                  dryHistory.frame(at: decisionEnd) != nil else {
                // Input-resampler pre-roll may complete an analysis frame before a full
                // source-time decision window exists. Its denoised output is warm-up only.
                return appendDenoisedOutputWithoutDecision()
            }
            guard let (leftPower, rightPower) = dryHistory.sourcePowers(
                start: decisionStart,
                frameCount: sourceBlockFrameCount
            ) else {
                return fail()
            }
            let useLeft = inference.leftProbability >= inference.rightProbability
            let probability = min(max(
                useLeft ? inference.leftProbability : inference.rightProbability,
                0
            ), 1)
            let power = max(useLeft ? leftPower : rightPower, 0)
            let result = SpeechAnalysisResult(
                probability: probability,
                sourcePower: power,
                sourceFrameCount: sourceBlockFrameCount,
                analysisLatencyFrameCount: decisionLatencyFrameCount
            )
            decisionHistory.store(
                probability: result.probability,
                power: result.sourcePower,
                start: decisionStart,
                blockFrameCount: sourceBlockFrameCount
            )
            if inferenceEngine.completedAnalysisBlockCount >= 2 {
                decisionHistory.storeEstimatedSNR(
                    for: decisionStart - Int64(sourceBlockFrameCount * 2),
                    blockFrameCount: sourceBlockFrameCount,
                    estimatedSNRDB: inferenceEngine.estimatedSNRDB()
                )
            }
            guard appendDenoisedOutput() else { return fail() }
            inferenceEngine.advanceAnalysisHistory()
            return .result(result)
        }
    }

    private func appendDenoisedOutputWithoutDecision() -> SpeechAnalysisEvent {
        guard appendDenoisedOutput() else { return fail() }
        inferenceEngine.advanceAnalysisHistory()
        return .pending
    }

    private func appendDenoisedOutput() -> Bool {
        if let outputFrameCount = resampler.processOutputBlock(
            from: inferenceEngine
        ) {
            guard outputFrameCount >= 0 else { return false }
            for frame in 0..<outputFrameCount {
                let output = resampler.outputFrame(at: frame)
                guard enqueueWetOutput(left: output.left, right: output.right) else {
                    return false
                }
            }
        } else {
            return prepareDenoisedOutput48KBlock()
        }
        return drainWetFIFO()
    }

    private func prepareDenoisedOutput48KBlock() -> Bool {
        let outputStart = wetOutputFrameIndex + 1
        wetOutputFrameIndex += Int64(RNNoiseInferenceEngine.analysisFrameCount)
        let sourceOffset = Int64(sourceBlockFrameCount * 2)
        let sourceStart = outputStart - sourceOffset
        guard sourceStart >= 0 else {
            for frame in 0..<RNNoiseInferenceEngine.analysisFrameCount {
                guard inferenceEngine.denoisedSample(at: frame, channel: 0).isFinite,
                      inferenceEngine.denoisedSample(at: frame, channel: 1).isFinite else {
                    return false
                }
            }
            return true
        }
        let blockSize = Int64(sourceBlockFrameCount)
        guard sourceStart % blockSize == 0,
              pendingMetadata == nil,
              let decision = decisionHistory.decision(
                  at: sourceStart,
                  blockFrameCount: sourceBlockFrameCount
              ) else { return false }
        let succeeded = pendingLeft.withUnsafeMutableBufferPointer { outputLeft in
            pendingRight.withUnsafeMutableBufferPointer { outputRight in
                for frame in 0..<sourceBlockFrameCount {
                    let sourceIndex = sourceStart + Int64(frame)
                    guard dryHistory.frame(at: sourceIndex) != nil else { return false }
                    let scaledLeft = inferenceEngine.denoisedSample(at: frame, channel: 0) / 32_768
                    let scaledRight = inferenceEngine.denoisedSample(at: frame, channel: 1) / 32_768
                    guard scaledLeft.isFinite, scaledRight.isFinite else {
                        return false
                    }
                    outputLeft[frame] = scaledLeft
                    outputRight[frame] = scaledRight
                }
                return true
            }
        }
        guard succeeded else { return false }
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
        return wetFIFO.enqueue(
            left: left,
            right: right,
            sourceFrameIndex: sourceIndex
        )
    }

    private func drainWetFIFO() -> Bool {
        guard wetFIFO.count > 0, pendingMetadata == nil else { return true }
        guard let firstFrame = wetFIFO.frame(atOffset: 0) else { return false }
        let firstSourceIndex = firstFrame.sourceFrameIndex
        let blockSize = Int64(sourceBlockFrameCount)
        let blockStart = (firstSourceIndex / blockSize) * blockSize
        guard let decision = decisionHistory.decision(
            at: blockStart,
            blockFrameCount: sourceBlockFrameCount
        ) else { return false }

        var offset = 0
        var writeCount = 0
        while offset < wetFIFO.count, writeCount < sourceBlockFrameCount {
            guard let frame = wetFIFO.frame(atOffset: offset) else { return false }
            let sourceIndex = frame.sourceFrameIndex
            guard (sourceIndex / blockSize) * blockSize == blockStart else { break }
            guard sourceIndex == firstSourceIndex + Int64(writeCount), sourceIndex >= 0 else {
                return false
            }
            guard dryHistory.frame(at: sourceIndex) != nil else { return false }
            pendingLeft[writeCount] = frame.left
            pendingRight[writeCount] = frame.right
            writeCount += 1
            offset += 1
        }
        wetFIFO.consume(writeCount)
        pendingMetadata = DenoisedSpeechBlock(
            sourceStartFrameIndex: firstSourceIndex,
            sourceFrameCount: writeCount,
            speechProbability: decision.probability,
            sourcePower: decision.power,
            estimatedSNRDB: decision.snrDB
        )
        return true
    }

    private func fail() -> SpeechAnalysisEvent {
        failed = true
        return .failed
    }
}
