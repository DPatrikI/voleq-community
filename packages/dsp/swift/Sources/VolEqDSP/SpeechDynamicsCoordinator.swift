// SPDX-License-Identifier: MPL-2.0

import Foundation
import VolEqCore
import VolEqSpeech

final class SpeechDynamicsCoordinator {
    private let sampleRate: Float
    private let speechAnalyzer: (any SpeechAnalyzing)?
    private let stereoSpeechProcessor: (any StereoSpeechProcessing)?
    private let upwardGainAuthorizer: (any UpwardGainAuthorizing)?
    private let appliesSpeechLeveling: Bool

    private var analysisLeftBlock: [Float]
    private var analysisRightBlock: [Float]
    private var analysisBlockFrameCount = 0
    private var speechGate: SpeechLevelingGate
    private var suppressionGate = NoiseSuppressionActivityGate()
    private var lastSuppressionBlockStart: Int64 = -1
    private var lastSuppressionTarget: Float = 0

    private(set) var currentUpwardEligibility: Float
    var hasLearnedNoiseFloor: Bool { speechGate.learnedNoiseFloorDB != nil }

    init(
        sampleRate: Float,
        speechAnalyzer: (any SpeechAnalyzing)?,
        stereoSpeechProcessor: (any StereoSpeechProcessing)?,
        upwardGainAuthorizer: (any UpwardGainAuthorizing)?,
        appliesSpeechLeveling: Bool,
        analysisBlockCapacity: Int
    ) {
        self.sampleRate = sampleRate
        self.speechAnalyzer = speechAnalyzer
        self.stereoSpeechProcessor = stereoSpeechProcessor
        self.upwardGainAuthorizer = upwardGainAuthorizer
        self.appliesSpeechLeveling = appliesSpeechLeveling
        currentUpwardEligibility = appliesSpeechLeveling ? 0 : 1
        analysisLeftBlock = Array(repeating: 0, count: max(analysisBlockCapacity, 1))
        analysisRightBlock = Array(repeating: 0, count: max(analysisBlockCapacity, 1))
        speechGate = SpeechLevelingGate(sampleRate: sampleRate)
    }

    func analyze(
        left: Float,
        right: Float,
        sourceFrameIndex: Int64,
        parameters: DynamicsRuntimeParameters,
        lookaheadBuffer: DynamicsLookaheadBuffer
    ) -> Bool {
        if let stereoSpeechProcessor {
            let event = stereoSpeechProcessor.processStereoFrame(left: left, right: right)
            let block = stereoSpeechProcessor.pendingDenoisedBlock
            if let block {
                guard isValidDenoisedBlock(
                    block,
                    processor: stereoSpeechProcessor,
                    currentSourceFrameIndex: sourceFrameIndex
                ) else { return false }
            }
            guard handleSpeechEvent(
                event,
                parameters: parameters,
                lookaheadBuffer: lookaheadBuffer
            ) else { return false }
            guard let block else { return true }
            let target = suppressionTarget(
                for: block,
                processor: stereoSpeechProcessor,
                parameters: parameters
            )
            guard backfillDenoisedBlock(
                block,
                processor: stereoSpeechProcessor,
                currentSourceFrameIndex: sourceFrameIndex,
                lookaheadBuffer: lookaheadBuffer,
                suppressionTarget: target
            ) else { return false }
            stereoSpeechProcessor.consumeDenoisedBlock()
            return true
        }

        guard let speechAnalyzer else { return true }
        analysisLeftBlock[analysisBlockFrameCount] = left
        analysisRightBlock[analysisBlockFrameCount] = right
        analysisBlockFrameCount += 1
        guard analysisBlockFrameCount == analysisLeftBlock.count else { return true }
        analysisBlockFrameCount = 0

        var leftPower: Float = 0
        var rightPower: Float = 0
        var midPower: Float = 0
        for index in analysisLeftBlock.indices {
            let blockLeft = analysisLeftBlock[index]
            let blockRight = analysisRightBlock[index]
            let mid = (blockLeft + blockRight) * 0.5
            leftPower += blockLeft * blockLeft
            rightPower += blockRight * blockRight
            midPower += mid * mid
        }
        let dominantPower = max(leftPower, rightPower)
        let useCoherentDownmix = midPower >= dominantPower * 0.1
        let useLeftChannel = leftPower >= rightPower

        for index in analysisLeftBlock.indices {
            let mono: Float
            if useCoherentDownmix {
                mono = (analysisLeftBlock[index] + analysisRightBlock[index]) * 0.5
            } else {
                mono = useLeftChannel ? analysisLeftBlock[index] : analysisRightBlock[index]
            }
            guard handleSpeechEvent(
                speechAnalyzer.processMonoSample(mono),
                parameters: parameters,
                lookaheadBuffer: lookaheadBuffer
            ) else { return false }
        }
        return true
    }

    func effectiveNoiseGateDB(settings: LevelingSettings) -> Float {
        guard appliesSpeechLeveling else { return settings.noiseGateDB }
        return speechGate.effectiveNoiseGateDB(
            fixedNoiseGateDB: settings.noiseGateDB,
            compressionThresholdDB: settings.thresholdDB
        )
    }

    func reset() {
        resetRealtimeState()
        resetAnalyzers()
    }

    func resetRealtimeState() {
        currentUpwardEligibility = appliesSpeechLeveling ? 0 : 1
        speechGate.reset()
        suppressionGate.reset()
        lastSuppressionBlockStart = -1
        lastSuppressionTarget = 0
        analysisBlockFrameCount = 0
    }

    func resetAnalyzers() {
        speechAnalyzer?.reset()
        stereoSpeechProcessor?.reset()
    }

    private func handleSpeechEvent(
        _ event: SpeechAnalysisEvent,
        parameters: DynamicsRuntimeParameters,
        lookaheadBuffer: DynamicsLookaheadBuffer
    ) -> Bool {
        switch event {
        case .pending:
            return true
        case .failed:
            return false
        case let .result(result):
            guard result.probability.isFinite,
                  (0...1).contains(result.probability),
                  result.sourcePower.isFinite,
                  result.sourcePower >= 0,
                  result.sourceFrameCount > 0,
                  result.analysisLatencyFrameCount >= result.sourceFrameCount,
                  result.analysisLatencyFrameCount <= lookaheadBuffer.activeLookaheadFrameCount else {
                return false
            }
            guard appliesSpeechLeveling else { return true }
            let eligibility = speechGate.observe(
                result,
                fixedNoiseGateDB: parameters.settings.noiseGateDB,
                compressionThresholdDB: parameters.settings.thresholdDB
            )
            let authorizedEligibility = upwardGainAuthorizer?.allowsUpwardGain == false
                ? 0
                : eligibility
            currentUpwardEligibility = authorizedEligibility
            let confirmedOpeningCoverage = result.analysisLatencyFrameCount
                + max(
                    speechGate.openingBackfillSourceFrameCount
                        - result.sourceFrameCount,
                    0
                )
            lookaheadBuffer.backfillEligibility(
                authorizedEligibility,
                analysisLatencyFrameCount: min(
                    confirmedOpeningCoverage,
                    lookaheadBuffer.activeLookaheadFrameCount
                )
            )
            return true
        }
    }

    private func suppressionTarget(
        for block: DenoisedSpeechBlock,
        processor: any StereoSpeechProcessing,
        parameters: DynamicsRuntimeParameters
    ) -> Float {
        let nominalBlockSize = Int64(processor.sourceBlockFrameCount)
        let suppressionBlockStart = (
            block.sourceStartFrameIndex / nominalBlockSize
        ) * nominalBlockSize
        if suppressionBlockStart == lastSuppressionBlockStart {
            return lastSuppressionTarget
        }

        let result = SpeechAnalysisResult(
            probability: block.speechProbability,
            sourcePower: block.sourcePower,
            sourceFrameCount: processor.sourceBlockFrameCount,
            analysisLatencyFrameCount: processor.decisionLatencyFrameCount
        )
        let speechIsActive = suppressionGate.observe(
            result,
            sampleRate: sampleRate,
            fixedNoiseGateDB: parameters.settings.noiseGateDB,
            compressionThresholdDB: parameters.settings.thresholdDB,
            learnedNoiseFloorDB: speechGate.learnedNoiseFloorDB
        )
        let target = speechIsActive && upwardGainAuthorizer?.allowsUpwardGain == true
            ? suppressionTarget(snrDB: block.estimatedSNRDB)
            : 0
        lastSuppressionBlockStart = suppressionBlockStart
        lastSuppressionTarget = target
        return target
    }

    private func backfillDenoisedBlock(
        _ block: DenoisedSpeechBlock,
        processor: any StereoSpeechProcessing,
        currentSourceFrameIndex: Int64,
        lookaheadBuffer: DynamicsLookaheadBuffer,
        suppressionTarget: Float
    ) -> Bool {
        guard isValidDenoisedBlock(
            block,
            processor: processor,
            currentSourceFrameIndex: currentSourceFrameIndex
        ) else { return false }
        for frame in 0..<block.sourceFrameCount {
            let sourceFrameIndex = block.sourceStartFrameIndex + Int64(frame)
            guard lookaheadBuffer.backfillDenoisedFrame(
                sourceFrameIndex: sourceFrameIndex,
                currentSourceFrameIndex: currentSourceFrameIndex,
                wetLeft: processor.denoisedSample(frame: frame, channel: 0),
                wetRight: processor.denoisedSample(frame: frame, channel: 1),
                suppressionTarget: suppressionTarget
            ) else { return false }
        }
        return true
    }

    private func isValidDenoisedBlock(
        _ block: DenoisedSpeechBlock,
        processor: any StereoSpeechProcessing,
        currentSourceFrameIndex: Int64
    ) -> Bool {
        guard block.sourceStartFrameIndex >= 0,
              block.sourceFrameCount > 0,
              block.sourceFrameCount <= processor.sourceBlockFrameCount,
              block.speechProbability.isFinite,
              (0...1).contains(block.speechProbability),
              block.sourcePower.isFinite,
              block.sourcePower >= 0,
              block.estimatedSNRDB?.isFinite ?? true else {
            return false
        }
        let (lastSourceFrameIndex, sourceRangeOverflowed) = block.sourceStartFrameIndex
            .addingReportingOverflow(Int64(block.sourceFrameCount - 1))
        return !sourceRangeOverflowed && lastSourceFrameIndex <= currentSourceFrameIndex
    }

    private func suppressionTarget(snrDB: Float?) -> Float {
        guard let snrDB, snrDB.isFinite, snrDB < 24 else { return 0 }
        guard snrDB > 18 else { return 0.5 }
        let position = min(max((24 - snrDB) / 6, 0), 1)
        return 0.5 * smoothstep(position)
    }

    private func smoothstep(_ value: Float) -> Float {
        value * value * (3 - 2 * value)
    }
}
