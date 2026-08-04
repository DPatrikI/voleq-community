// SPDX-License-Identifier: MPL-2.0

import CSpeexResampler
import Foundation

final class RNNoiseResampler {
    static let analysisSampleRate: UInt32 = 48_000
    static let resamplerQuality: Int32 = 3
    static let channelCount: UInt32 = 2

    let sourceSampleRate: Double
    let sourceBlockFrameCount: Int
    let inputResamplerLatencyFrameCount: Int
    let outputResamplerLatencyFrameCount: Int
    private var inputResampler: OpaquePointer?
    private var outputResampler: OpaquePointer?
    private var singleInputFrame = [Float](repeating: 0, count: 2)
    private var inputResamplerOutput = [Float](repeating: 0, count: 32)
    private var interleavedDenoised48K: [Float]
    private var outputResamplerScratch: [Float]

    var hasInputResampler: Bool { inputResampler != nil }

    init(sampleRate: Double, sourceBlockFrameCount: Int) throws {
        sourceSampleRate = sampleRate
        self.sourceBlockFrameCount = sourceBlockFrameCount
        let prepared = try Self.makeResamplers(sourceRate: UInt32(sampleRate))
        inputResampler = prepared.input
        outputResampler = prepared.output
        inputResamplerLatencyFrameCount = prepared.inputLatency
        outputResamplerLatencyFrameCount = prepared.outputLatency
        outputResamplerScratch = [Float](
            repeating: 0,
            count: max(sourceBlockFrameCount * 4, RNNoiseInferenceEngine.analysisFrameCount * 2)
        )
        interleavedDenoised48K = [Float](
            repeating: 0,
            count: RNNoiseInferenceEngine.analysisFrameCount * 2
        )
    }

    deinit {
        destroyResamplers()
    }

    func processInputFrame(left: Float, right: Float) -> Int? {
        guard let inputResampler else { return nil }
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
        guard status == 0, inputLength == 1 else { return -1 }
        return Int(outputLength)
    }

    func inputFrame(at index: Int) -> (left: Float, right: Float) {
        let offset = index * 2
        return (inputResamplerOutput[offset], inputResamplerOutput[offset + 1])
    }

    func processOutputBlock(
        from inferenceEngine: RNNoiseInferenceEngine
    ) -> Int? {
        guard let outputResampler else { return nil }
        let frameCount = RNNoiseInferenceEngine.analysisFrameCount
        for frame in 0..<frameCount {
            let scaledLeft = inferenceEngine.denoisedSample(at: frame, channel: 0) / 32_768
            let scaledRight = inferenceEngine.denoisedSample(at: frame, channel: 1) / 32_768
            guard scaledLeft.isFinite, scaledRight.isFinite else { return -1 }
            interleavedDenoised48K[frame * 2] = scaledLeft
            interleavedDenoised48K[frame * 2 + 1] = scaledRight
        }
        var inputLength = UInt32(frameCount)
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
        guard status == 0, inputLength == UInt32(frameCount) else { return -1 }
        return Int(outputLength)
    }

    func outputFrame(at index: Int) -> (left: Float, right: Float) {
        let offset = index * 2
        return (outputResamplerScratch[offset], outputResamplerScratch[offset + 1])
    }

    func reset() -> Bool {
        destroyResamplers()
        clear(&singleInputFrame)
        clear(&inputResamplerOutput)
        clear(&interleavedDenoised48K)
        clear(&outputResamplerScratch)
        do {
            let prepared = try Self.makeResamplers(sourceRate: UInt32(sourceSampleRate))
            inputResampler = prepared.input
            outputResampler = prepared.output
            return true
        } catch {
            return false
        }
    }

    private static func makeResamplers(
        sourceRate: UInt32
    ) throws -> (
        input: OpaquePointer?,
        output: OpaquePointer?,
        inputLatency: Int,
        outputLatency: Int
    ) {
        guard sourceRate != Self.analysisSampleRate else {
            return (nil, nil, 0, 0)
        }
        var inputError: Int32 = 0
        let input = voleq_speex_resampler_init(
            Self.channelCount,
            sourceRate,
            Self.analysisSampleRate,
            Self.resamplerQuality,
            &inputError
        )
        guard let input, inputError == 0 else {
            throw SpeechAnalyzerError.resamplerCreationFailed(inputError)
        }
        var outputError: Int32 = 0
        let output = voleq_speex_resampler_init(
            Self.channelCount,
            Self.analysisSampleRate,
            sourceRate,
            Self.resamplerQuality,
            &outputError
        )
        guard let output, outputError == 0 else {
            voleq_speex_resampler_destroy(input)
            throw SpeechAnalyzerError.resamplerCreationFailed(outputError)
        }
        return (
            input,
            output,
            Int(voleq_speex_resampler_get_input_latency(input)),
            Int(voleq_speex_resampler_get_output_latency(output))
        )
    }

    private func clear(_ values: inout [Float]) {
        for index in values.indices { values[index] = 0 }
    }

    private func destroyResamplers() {
        if let inputResampler { voleq_speex_resampler_destroy(inputResampler) }
        if let outputResampler { voleq_speex_resampler_destroy(outputResampler) }
        inputResampler = nil
        outputResampler = nil
    }
}
