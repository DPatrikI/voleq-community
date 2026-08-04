// SPDX-License-Identifier: MPL-2.0

import CRNNoise
import Foundation

struct RNNoiseInferenceResult {
    let leftProbability: Float
    let rightProbability: Float
}

enum RNNoiseInferenceAppendResult {
    case pending
    case completed(RNNoiseInferenceResult)
    case failed
}

final class RNNoiseInferenceEngine {
    static let analysisFrameCount = 480
    private static let insignificantPower: Double = 1e-12

    private let modelResource: RNNoiseModelResource
    private let usesOptimizedPairedInference: Bool
    private let leftState: OpaquePointer
    private let rightState: OpaquePointer
    private var analysisWriteCount = 0

    private var analysisLeft: UnsafeMutableBufferPointer<Float>
    private var analysisRight: UnsafeMutableBufferPointer<Float>
    private let denoisedLeft48K: UnsafeMutableBufferPointer<Float>
    private let denoisedRight48K: UnsafeMutableBufferPointer<Float>
    private var previousAnalysisLeft: UnsafeMutableBufferPointer<Float>
    private var previousAnalysisRight: UnsafeMutableBufferPointer<Float>
    private var olderAnalysisLeft: UnsafeMutableBufferPointer<Float>
    private var olderAnalysisRight: UnsafeMutableBufferPointer<Float>
    private(set) var completedAnalysisBlockCount = 0
    private(set) var optimizedInferencePairCount = 0

    init(model: RNNoiseModelResource, usesOptimizedPairedInference: Bool) throws {
        guard let leftState = rnnoise_create(model.model) else {
            throw SpeechAnalyzerError.stateCreationFailed
        }
        guard let rightState = rnnoise_create(model.model) else {
            rnnoise_destroy(leftState)
            throw SpeechAnalyzerError.stateCreationFailed
        }
        modelResource = model
        self.usesOptimizedPairedInference = usesOptimizedPairedInference
        self.leftState = leftState
        self.rightState = rightState
        analysisLeft = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        analysisRight = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        denoisedLeft48K = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        denoisedRight48K = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        previousAnalysisLeft = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        previousAnalysisRight = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        olderAnalysisLeft = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
        olderAnalysisRight = Self.allocateBuffer(repeating: 0, count: Self.analysisFrameCount)
    }

    deinit {
        rnnoise_destroy(rightState)
        rnnoise_destroy(leftState)
        Self.deallocateBuffer(analysisLeft)
        Self.deallocateBuffer(analysisRight)
        Self.deallocateBuffer(denoisedLeft48K)
        Self.deallocateBuffer(denoisedRight48K)
        Self.deallocateBuffer(previousAnalysisLeft)
        Self.deallocateBuffer(previousAnalysisRight)
        Self.deallocateBuffer(olderAnalysisLeft)
        Self.deallocateBuffer(olderAnalysisRight)
    }

    func appendSample(left: Float, right: Float) -> RNNoiseInferenceAppendResult {
        guard left.isFinite, right.isFinite else { return .failed }
        analysisLeft[analysisWriteCount] = left * 32_768
        analysisRight[analysisWriteCount] = right * 32_768
        analysisWriteCount += 1
        guard analysisWriteCount == Self.analysisFrameCount else { return .pending }
        analysisWriteCount = 0

        let leftProbability: Float
        var rightProbability: Float
        if usesOptimizedPairedInference {
            rightProbability = 0
            leftProbability = rnnoise_process_frame_pair(
                leftState,
                denoisedLeft48K.baseAddress,
                analysisLeft.baseAddress,
                rightState,
                denoisedRight48K.baseAddress,
                analysisRight.baseAddress,
                &rightProbability
            )
            optimizedInferencePairCount += 1
        } else {
            leftProbability = rnnoise_process_frame(
                leftState,
                denoisedLeft48K.baseAddress,
                analysisLeft.baseAddress
            )
            rightProbability = rnnoise_process_frame(
                rightState,
                denoisedRight48K.baseAddress,
                analysisRight.baseAddress
            )
        }
        guard leftProbability.isFinite, rightProbability.isFinite else { return .failed }
        return .completed(RNNoiseInferenceResult(
            leftProbability: leftProbability,
            rightProbability: rightProbability
        ))
    }

    func denoisedSample(at index: Int, channel: Int) -> Float {
        channel == 0 ? denoisedLeft48K[index] : denoisedRight48K[index]
    }

    func estimatedSNRDB() -> Float? {
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
            return nil
        }
        let snr = Float(10 * log10(wetPower / removedPower))
        return snr.isFinite ? snr : nil
    }

    func advanceAnalysisHistory() {
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

    func reset() -> Bool {
        let leftStateReset = rnnoise_init(leftState, modelResource.model) == 0
        let rightStateReset = rnnoise_init(rightState, modelResource.model) == 0
        analysisWriteCount = 0
        completedAnalysisBlockCount = 0
        optimizedInferencePairCount = 0
        clear(analysisLeft)
        clear(analysisRight)
        clear(denoisedLeft48K)
        clear(denoisedRight48K)
        clear(previousAnalysisLeft)
        clear(previousAnalysisRight)
        clear(olderAnalysisLeft)
        clear(olderAnalysisRight)
        return leftStateReset && rightStateReset
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
