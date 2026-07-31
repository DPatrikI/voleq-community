// SPDX-License-Identifier: MPL-2.0

import CRNNoise
import CSpeexResampler
import Foundation

public enum SpeechAnalyzerError: Error, Equatable, LocalizedError {
    case unsupportedSampleRate(Double)
    case unexpectedFrameSize(Int)
    case stateCreationFailed
    case resamplerCreationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSampleRate(sampleRate):
            return "Unsupported speech-analysis sample rate: \(sampleRate) Hz."
        case let .unexpectedFrameSize(frameCount):
            return "RNNoise reported an unexpected frame size: \(frameCount)."
        case .stateCreationFailed:
            return "RNNoise could not create an analyzer state."
        case let .resamplerCreationFailed(code):
            return "SpeexDSP could not create an analysis resampler (error \(code))."
        }
    }
}

/// Offline RNNoise speech probability analysis. Denoised samples are discarded.
public final class RNNoiseSpeechAnalyzer: SpeechAnalyzing, @unchecked Sendable {
    public let sourceSampleRate: Double
    public let sourceBlockFrameCount: Int
    public let analysisLatencyFrameCount: Int

    private static let analysisSampleRate: UInt32 = 48_000
    private static let analysisFrameCount = 480
    private static let resamplerQuality: Int32 = 3

    private let modelResource: RNNoiseModelResource
    private let rnnoiseState: OpaquePointer
    private let resamplerState: OpaquePointer?
    private var sourceBlock: [Float]
    private var resamplerOutput: [Float]
    private var analysisFIFO: [Float]
    private var rnnoiseOutput: [Float]
    private var sourcePowerHistory: [Float]
    private var sourceBlockWriteCount = 0
    private var analysisFIFOCount = 0
    private var sourcePowerHistoryWriteIndex = 0
    private var failed = false

    public init(sampleRate: Double, model: RNNoiseModelResource) throws {
        guard sampleRate.isFinite,
              sampleRate >= 8_000,
              sampleRate <= 192_000,
              sampleRate.rounded() == sampleRate else {
            throw SpeechAnalyzerError.unsupportedSampleRate(sampleRate)
        }
        let sourceRate = UInt32(sampleRate)
        let blockFrameCount = Int((sampleRate * 0.010).rounded())
        guard blockFrameCount > 0 else {
            throw SpeechAnalyzerError.unsupportedSampleRate(sampleRate)
        }
        let rnnoiseFrameCount = Int(rnnoise_get_frame_size())
        guard rnnoiseFrameCount == Self.analysisFrameCount else {
            throw SpeechAnalyzerError.unexpectedFrameSize(rnnoiseFrameCount)
        }
        guard let state = rnnoise_create(model.model) else {
            throw SpeechAnalyzerError.stateCreationFailed
        }

        var initializedResampler: OpaquePointer?
        var inputLatency = 0
        if sourceRate != Self.analysisSampleRate {
            var error: Int32 = 0
            initializedResampler = voleq_speex_resampler_init(
                1,
                sourceRate,
                Self.analysisSampleRate,
                Self.resamplerQuality,
                &error
            )
            guard initializedResampler != nil, error == 0 else {
                rnnoise_destroy(state)
                throw SpeechAnalyzerError.resamplerCreationFailed(error)
            }
            inputLatency = Int(voleq_speex_resampler_get_input_latency(initializedResampler))
        }

        sourceSampleRate = sampleRate
        sourceBlockFrameCount = blockFrameCount
        analysisLatencyFrameCount = blockFrameCount + inputLatency
        modelResource = model
        rnnoiseState = state
        resamplerState = initializedResampler
        sourceBlock = [Float](repeating: 0, count: blockFrameCount)
        resamplerOutput = [Float](repeating: 0, count: Self.analysisFrameCount * 2)
        analysisFIFO = [Float](repeating: 0, count: Self.analysisFrameCount * 3)
        rnnoiseOutput = [Float](repeating: 0, count: Self.analysisFrameCount)
        sourcePowerHistory = [Float](
            repeating: 0,
            count: blockFrameCount + inputLatency + 1
        )
    }

    deinit {
        if let resamplerState {
            voleq_speex_resampler_destroy(resamplerState)
        }
        rnnoise_destroy(rnnoiseState)
    }

    public func processMonoSample(_ sample: Float) -> SpeechAnalysisEvent {
        guard !failed, sample.isFinite else {
            failed = true
            return .failed
        }

        sourceBlock[sourceBlockWriteCount] = sample
        sourceBlockWriteCount += 1
        sourcePowerHistory[sourcePowerHistoryWriteIndex] = sample * sample
        sourcePowerHistoryWriteIndex += 1
        if sourcePowerHistoryWriteIndex == sourcePowerHistory.count {
            sourcePowerHistoryWriteIndex = 0
        }

        guard sourceBlockWriteCount == sourceBlockFrameCount else {
            return .pending
        }
        sourceBlockWriteCount = 0

        if resamplerState == nil {
            for index in 0..<Self.analysisFrameCount {
                analysisFIFO[analysisFIFOCount + index] = sourceBlock[index] * 32_768
            }
            analysisFIFOCount += Self.analysisFrameCount
        } else if !appendResampledBlock() {
            failed = true
            return .failed
        }

        guard analysisFIFOCount >= Self.analysisFrameCount else {
            return .pending
        }

        let probability = analysisFIFO.withUnsafeMutableBufferPointer { input in
            rnnoiseOutput.withUnsafeMutableBufferPointer { output in
                rnnoise_process_frame(rnnoiseState, output.baseAddress, input.baseAddress)
            }
        }
        guard probability.isFinite, rnnoiseOutput.allSatisfy(\.isFinite) else {
            failed = true
            return .failed
        }

        let remainingCount = analysisFIFOCount - Self.analysisFrameCount
        if remainingCount > 0 {
            for index in 0..<remainingCount {
                analysisFIFO[index] = analysisFIFO[Self.analysisFrameCount + index]
            }
        }
        analysisFIFOCount = remainingCount

        var sourcePowerSum: Double = 0
        let resamplerLatency = analysisLatencyFrameCount - sourceBlockFrameCount
        for frame in 0..<sourceBlockFrameCount {
            let age = resamplerLatency + frame
            let index = (
                sourcePowerHistoryWriteIndex - 1 - age + sourcePowerHistory.count * 2
            ) % sourcePowerHistory.count
            sourcePowerSum += Double(sourcePowerHistory[index])
        }
        let sourcePower = Float(sourcePowerSum / Double(sourceBlockFrameCount))

        let result = SpeechAnalysisResult(
            probability: min(max(probability, 0), 1),
            sourcePower: max(sourcePower, 0),
            sourceFrameCount: sourceBlockFrameCount,
            analysisLatencyFrameCount: analysisLatencyFrameCount
        )
        return .result(result)
    }

    public func reset() {
        _ = rnnoise_init(rnnoiseState, modelResource.model)
        if let resamplerState {
            _ = voleq_speex_resampler_reset_mem(resamplerState)
        }
        sourceBlockWriteCount = 0
        analysisFIFOCount = 0
        sourcePowerHistoryWriteIndex = 0
        failed = false
        for index in sourceBlock.indices { sourceBlock[index] = 0 }
        for index in resamplerOutput.indices { resamplerOutput[index] = 0 }
        for index in analysisFIFO.indices { analysisFIFO[index] = 0 }
        for index in rnnoiseOutput.indices { rnnoiseOutput[index] = 0 }
        for index in sourcePowerHistory.indices { sourcePowerHistory[index] = 0 }
    }

    private func appendResampledBlock() -> Bool {
        guard let resamplerState else { return false }
        var inputLength = UInt32(sourceBlockFrameCount)
        var outputLength = UInt32(resamplerOutput.count)
        let error = sourceBlock.withUnsafeBufferPointer { input in
            resamplerOutput.withUnsafeMutableBufferPointer { output in
                voleq_speex_resampler_process_float(
                    resamplerState,
                    0,
                    input.baseAddress,
                    &inputLength,
                    output.baseAddress,
                    &outputLength
                )
            }
        }
        guard error == 0,
              inputLength == sourceBlockFrameCount,
              analysisFIFOCount + Int(outputLength) <= analysisFIFO.count else {
            return false
        }
        for index in 0..<Int(outputLength) {
            analysisFIFO[analysisFIFOCount + index] = resamplerOutput[index] * 32_768
        }
        analysisFIFOCount += Int(outputLength)
        return true
    }
}
