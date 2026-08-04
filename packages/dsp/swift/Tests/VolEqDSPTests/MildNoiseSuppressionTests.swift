// SPDX-License-Identifier: MPL-2.0

import XCTest
import VolEqCore
import VolEqSpeech
@testable import VolEqDSP

final class MildNoiseSuppressionTests: XCTestCase {
    func testAutomaticSNRTaperEndpointsAndMidpoint() throws {
        let expected: [(Float?, Float)] = [
            (18, 0.5),
            (21, 0.25),
            (24, 0),
            (nil, 0)
        ]
        for (snr, wantedMix) in expected {
            let output = try settledConstantOutput(snrDB: snr)
            XCTAssertEqual(output, 1 - wantedMix, accuracy: 0.002)
        }
    }

    func testThirtyMillisecondAttackAndHundredMillisecondReleaseAreClickFree() throws {
        let rate = 48_000.0
        let speech = ScriptedStereoSpeechProcessor(
            sampleRate: rate,
            probability: 0.99,
            sourcePower: 0.01,
            snrDB: 18,
            wetGenerator: { _, _ in 0 }
        )
        let authority = MutableSuppressionAuthority(allowsUpwardGain: true)
        let processor = try DynamicsProcessor(
            sampleRate: rate,
            settings: neutralSettings(),
            stereoSpeechProcessor: speech,
            upwardGainAuthorizer: authority
        )
        var output: [Float] = []
        let totalFrames = processor.latencyFrameCount + 12_000
        output.reserveCapacity(totalFrames)
        for frame in 0..<totalFrames {
            if frame == 5_760 { authority.allowsUpwardGain = false }
            output.append(processor.processFrame(left: 1, right: 1).left)
        }
        let audible = Array(output.dropFirst(processor.latencyFrameCount))
        let largestStep = zip(audible, audible.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThanOrEqual(largestStep, 0.5 / Float(0.030 * rate) + 0.000_001)

        let settledWet = audible[4_300]
        XCTAssertEqual(settledWet, 0.5, accuracy: 0.002)
        guard let releaseStart = (4_000..<(audible.count - 1)).first(where: {
            audible[$0 + 1] > audible[$0]
        }) else {
            return XCTFail("release did not begin")
        }
        XCTAssertEqual(audible[releaseStart + 4_799], 1, accuracy: 0.002)
    }

    func testStationaryNoiseDropsByAtLeastThreeDBWithoutChangingSpeechByOneDB() throws {
        let rate = 48_000.0
        let block = 480
        let speech = ScriptedStereoSpeechProcessor(
            sampleRate: rate,
            probability: 0.99,
            sourcePower: 0.01,
            snrDB: 18,
            wetGenerator: { index, _ in
                Float(sin(2 * Double.pi * 220 * Double(index) / rate)) * 0.08
            }
        )
        let processor = try DynamicsProcessor(
            sampleRate: rate,
            settings: neutralSettings(),
            stereoSpeechProcessor: speech,
            upwardGainAuthorizer: MutableSuppressionAuthority(allowsUpwardGain: true)
        )
        let totalInput = 48_000
        var output = [Float]()
        output.reserveCapacity(totalInput + processor.latencyFrameCount)
        for frame in 0..<(totalInput + processor.latencyFrameCount) {
            let clean = Float(sin(2 * Double.pi * 220 * Double(frame) / rate)) * 0.08
            let noise = Float((frame * 17) % 101 - 50) / 50 * 0.025
            let input = frame < totalInput ? clean + noise : 0
            output.append(processor.processFrame(left: input, right: input).left)
        }

        let start = processor.latencyFrameCount + block * 8
        let end = processor.latencyFrameCount + totalInput - block
        var inputNoisePower: Double = 0
        var outputNoisePower: Double = 0
        var cleanPower: Double = 0
        var outputProjection: Double = 0
        for outputIndex in start..<end {
            let sourceIndex = outputIndex - processor.latencyFrameCount
            let clean = Float(sin(2 * Double.pi * 220 * Double(sourceIndex) / rate)) * 0.08
            let noise = Float((sourceIndex * 17) % 101 - 50) / 50 * 0.025
            let processed = output[outputIndex]
            inputNoisePower += Double(noise * noise)
            outputNoisePower += Double((processed - clean) * (processed - clean))
            cleanPower += Double(clean * clean)
            outputProjection += Double(processed * clean)
        }
        let noiseReductionDB = 10 * log10(inputNoisePower / outputNoisePower)
        let speechLevelChangeDB = 20 * log10(abs(outputProjection / cleanPower))
        XCTAssertGreaterThanOrEqual(noiseReductionDB, 3)
        XCTAssertLessThanOrEqual(abs(speechLevelChangeDB), 1)
    }

    func testBundledRNNoiseReducesStationaryNoiseWithoutMovingProjectedSpeech() throws {
        let rate = 48_000.0
        let model = try RNNoiseModelResource.bundled()
        let speech = try RNNoiseStereoProcessor(sampleRate: rate, model: model)
        let processor = try DynamicsProcessor(
            sampleRate: rate,
            settings: neutralSettings(),
            stereoSpeechProcessor: speech,
            upwardGainAuthorizer: MutableSuppressionAuthority(allowsUpwardGain: true)
        )
        let sourceFrameCount = 48_000
        var cleanSource = [Float](repeating: 0, count: sourceFrameCount)
        var noiseSource = [Float](repeating: 0, count: sourceFrameCount)
        var randomState: UInt32 = 0x7A31_C49D
        for frame in 0..<sourceFrameCount {
            cleanSource[frame] = Float(
                sin(2 * Double.pi * 180 * Double(frame) / rate)
                    + 0.5 * sin(2 * Double.pi * 360 * Double(frame) / rate)
                    + 0.24 * sin(2 * Double.pi * 540 * Double(frame) / rate)
            ) * 0.06
            randomState = randomState &* 1_664_525 &+ 1_013_904_223
            noiseSource[frame] = Float(Int32(bitPattern: randomState))
                / Float(Int32.max) * 0.025
        }
        var output = [Float]()
        var outputRight = [Float]()
        output.reserveCapacity(sourceFrameCount + processor.latencyFrameCount)
        outputRight.reserveCapacity(sourceFrameCount + processor.latencyFrameCount)
        for frame in 0..<(sourceFrameCount + processor.latencyFrameCount) {
            let input = frame < sourceFrameCount
                ? cleanSource[frame] + noiseSource[frame]
                : 0
            let processed = processor.processFrame(left: input, right: input * 0.7)
            output.append(processed.left)
            outputRight.append(processed.right)
        }
        XCTAssertFalse(processor.consumeProcessingFailure())

        let evaluationRange = 14_400..<(sourceFrameCount - 4_800)
        var cleanPower: Double = 0
        var inputNoisePower: Double = 0
        var outputProjection: Double = 0
        var outputLeftPower: Double = 0
        var outputRightPower: Double = 0
        for source in evaluationRange {
            let clean = cleanSource[source]
            let noise = noiseSource[source]
            cleanPower += Double(clean * clean)
            inputNoisePower += Double(noise * noise)
            let outputIndex = source + processor.latencyFrameCount
            outputProjection += Double(output[outputIndex] * clean)
            outputLeftPower += Double(output[outputIndex] * output[outputIndex])
            outputRightPower += Double(outputRight[outputIndex] * outputRight[outputIndex])
        }
        let projection = outputProjection / cleanPower
        var outputResidualPower: Double = 0
        for source in evaluationRange {
            let clean = cleanSource[source]
            let residual = Double(output[source + processor.latencyFrameCount])
                - projection * Double(clean)
            outputResidualPower += residual * residual
        }
        let noiseReductionDB = 10 * log10(inputNoisePower / outputResidualPower)
        let speechLevelChangeDB = 20 * log10(abs(projection))
        let outputBalanceDB = 10 * log10(outputLeftPower / outputRightPower)
        let inputBalanceDB = 20 * log10(1 / 0.7)
        XCTAssertGreaterThanOrEqual(noiseReductionDB, 3, "measured \(noiseReductionDB) dB")
        XCTAssertLessThanOrEqual(
            abs(speechLevelChangeDB),
            1,
            "measured \(speechLevelChangeDB) dB"
        )
        XCTAssertLessThanOrEqual(
            abs(outputBalanceDB - inputBalanceDB),
            0.5,
            "balance changed by \(outputBalanceDB - inputBalanceDB) dB"
        )
    }

    func testBundledRNNoiseCleanSpeechRemainsNearTransparent() throws {
        let rate = 48_000.0
        let model = try RNNoiseModelResource.bundled()
        let speech = try RNNoiseStereoProcessor(sampleRate: rate, model: model)
        let processor = try DynamicsProcessor(
            sampleRate: rate,
            settings: neutralSettings(),
            stereoSpeechProcessor: speech,
            upwardGainAuthorizer: MutableSuppressionAuthority(allowsUpwardGain: true)
        )
        let sourceFrameCount = 38_400
        var clean = [Float](repeating: 0, count: sourceFrameCount)
        var output = [Float]()
        output.reserveCapacity(sourceFrameCount + processor.latencyFrameCount)
        for frame in 0..<(sourceFrameCount + processor.latencyFrameCount) {
            if frame < sourceFrameCount {
                clean[frame] = Float(
                    sin(2 * Double.pi * 190 * Double(frame) / rate)
                        + 0.42 * sin(2 * Double.pi * 380 * Double(frame) / rate)
                        + 0.18 * sin(2 * Double.pi * 570 * Double(frame) / rate)
                ) * 0.06
            }
            let input = frame < sourceFrameCount ? clean[frame] : 0
            output.append(processor.processFrame(left: input, right: input).left)
        }
        XCTAssertFalse(processor.consumeProcessingFailure())

        var referencePower: Double = 0
        var errorPower: Double = 0
        var projection: Double = 0
        let evaluationRange = 14_400..<(sourceFrameCount - 4_800)
        for source in evaluationRange {
            let reference = Double(clean[source])
            let processed = Double(output[source + processor.latencyFrameCount])
            referencePower += reference * reference
            errorPower += (processed - reference) * (processed - reference)
            projection += processed * reference
        }
        let levelChangeDB = 20 * log10(abs(projection / referencePower))
        let errorRelativeDB = 10 * log10(errorPower / referencePower)
        XCTAssertLessThanOrEqual(abs(levelChangeDB), 0.1, "level \(levelChangeDB) dB")
        XCTAssertLessThanOrEqual(errorRelativeDB, -28, "error \(errorRelativeDB) dB")
    }

    func testUnauthorizedMusicAndNonSpeechRemainDry() throws {
        for (probability, authorized) in [(Float(0.99), false), (Float(0.1), true)] {
            let speech = ScriptedStereoSpeechProcessor(
                sampleRate: 48_000,
                probability: probability,
                sourcePower: 0.01,
                snrDB: 10,
                wetGenerator: { _, _ in 0 }
            )
            let processor = try DynamicsProcessor(
                sampleRate: 48_000,
                settings: neutralSettings(),
                stereoSpeechProcessor: speech,
                upwardGainAuthorizer: MutableSuppressionAuthority(
                    allowsUpwardGain: authorized
                )
            )
            let input = (0..<8_000).map { Float(sin(Double($0) * 0.071)) * 0.1 }
            var output: [Float] = []
            for sample in input {
                output.append(processor.processFrame(left: sample, right: sample).left)
            }
            for frame in processor.latencyFrameCount..<output.count {
                XCTAssertEqual(
                    output[frame],
                    input[frame - processor.latencyFrameCount],
                    accuracy: 0.000_001
                )
            }
        }
    }

    func testMissingPlatformAuthorityRemainsDry() throws {
        let speech = ScriptedStereoSpeechProcessor(
            sampleRate: 48_000,
            probability: 0.99,
            sourcePower: 0.01,
            snrDB: 10,
            wetGenerator: { _, _ in 0 }
        )
        let processor = try DynamicsProcessor(
            sampleRate: 48_000,
            settings: neutralSettings(),
            stereoSpeechProcessor: speech
        )
        let input = (0..<8_000).map { Float(sin(Double($0) * 0.071)) * 0.1 }
        var output: [Float] = []
        for sample in input {
            output.append(processor.processFrame(left: sample, right: sample).left)
        }
        for frame in processor.latencyFrameCount..<output.count {
            XCTAssertEqual(
                output[frame],
                input[frame - processor.latencyFrameCount],
                accuracy: 0.000_001
            )
        }
    }

    func testImpossibleWetSourceRangeFailsWithoutOverflowing() throws {
        let processor = try DynamicsProcessor(
            sampleRate: 48_000,
            settings: neutralSettings(),
            stereoSpeechProcessor: ImpossibleRangeStereoSpeechProcessor(),
            upwardGainAuthorizer: MutableSuppressionAuthority(allowsUpwardGain: true)
        )
        for _ in 0..<960 {
            let output = processor.processFrame(left: 0.1, right: 0.1)
            XCTAssertTrue(output.left.isFinite)
            XCTAssertTrue(output.right.isFinite)
        }
        XCTAssertTrue(processor.consumeProcessingFailure())
    }

    func testNonFiniteWetMetadataFailsClosedAndResetRecovers() throws {
        let speech = ScriptedStereoSpeechProcessor(
            sampleRate: 48_000,
            probability: 0.99,
            sourcePower: 0.01,
            snrDB: .infinity,
            wetGenerator: { _, _ in 0 }
        )
        let processor = try DynamicsProcessor(
            sampleRate: 48_000,
            settings: neutralSettings(),
            stereoSpeechProcessor: speech,
            upwardGainAuthorizer: MutableSuppressionAuthority(allowsUpwardGain: true)
        )

        for _ in 0..<960 {
            _ = processor.processFrame(left: 0.1, right: 0.1)
        }
        XCTAssertTrue(processor.consumeProcessingFailure())
        XCTAssertEqual(processor.processFrame(left: 0.1, right: 0.1).left, 0)
        XCTAssertEqual(processor.processFrame(left: 0.1, right: 0.1).right, 0)

        speech.snrDB = 10
        processor.reset()
        for _ in 0..<960 {
            _ = processor.processFrame(left: 0.1, right: 0.1)
        }
        XCTAssertFalse(processor.consumeProcessingFailure())
    }

    func testNonFiniteWetSamplesFailBeforeBlending() throws {
        let speech = ScriptedStereoSpeechProcessor(
            sampleRate: 48_000,
            probability: 0.99,
            sourcePower: 0.01,
            snrDB: 10,
            wetGenerator: { _, _ in .nan }
        )
        let processor = try DynamicsProcessor(
            sampleRate: 48_000,
            settings: neutralSettings(),
            stereoSpeechProcessor: speech,
            upwardGainAuthorizer: MutableSuppressionAuthority(allowsUpwardGain: true)
        )
        var observedFailureOutput = false
        for _ in 0..<1_440 {
            let output = processor.processFrame(left: 0.1, right: -0.1)
            XCTAssertTrue(output.left.isFinite)
            XCTAssertTrue(output.right.isFinite)
            if processor.consumeProcessingFailure() {
                observedFailureOutput = output.left == 0 && output.right == 0
                break
            }
        }
        XCTAssertTrue(observedFailureOutput)
    }

    func testExtremeFiniteInputFailsWithoutEmittingCorruptAudio() throws {
        let processor = try DynamicsProcessor(
            sampleRate: 48_000,
            settings: neutralSettings(),
            stereoSpeechProcessor: ScriptedStereoSpeechProcessor(
                sampleRate: 48_000,
                probability: 0.99,
                sourcePower: 0.01,
                snrDB: 10,
                wetGenerator: { _, _ in 0 }
            ),
            upwardGainAuthorizer: MutableSuppressionAuthority(allowsUpwardGain: true)
        )
        let output = processor.processFrame(
            left: .greatestFiniteMagnitude,
            right: -.greatestFiniteMagnitude
        )
        XCTAssertEqual(output.left, 0)
        XCTAssertEqual(output.right, 0)
        XCTAssertTrue(processor.consumeProcessingFailure())
    }

    func testLinkedMixPreservesStereoBalanceWithinHalfDB() throws {
        let speech = ScriptedStereoSpeechProcessor(
            sampleRate: 48_000,
            probability: 0.99,
            sourcePower: 0.01,
            snrDB: 18,
            wetGenerator: { index, channel in
                let base = Float(sin(Double(index) * 0.051)) * 0.08
                return channel == 0 ? base : base * 0.5
            }
        )
        let processor = try DynamicsProcessor(
            sampleRate: 48_000,
            settings: neutralSettings(),
            stereoSpeechProcessor: speech,
            upwardGainAuthorizer: MutableSuppressionAuthority(allowsUpwardGain: true)
        )
        var leftPower: Double = 0
        var rightPower: Double = 0
        for frame in 0..<(processor.latencyFrameCount + 12_000) {
            let base = Float(sin(Double(frame) * 0.051)) * 0.08
            let output = processor.processFrame(left: base, right: base * 0.5)
            if frame > processor.latencyFrameCount + 4_000 {
                leftPower += Double(output.left * output.left)
                rightPower += Double(output.right * output.right)
            }
        }
        let balanceDB = 10 * log10(leftPower / rightPower)
        XCTAssertEqual(balanceDB, 20 * log10(2), accuracy: 0.5)
    }

    private func settledConstantOutput(snrDB: Float?) throws -> Float {
        let speech = ScriptedStereoSpeechProcessor(
            sampleRate: 48_000,
            probability: 0.99,
            sourcePower: 0.01,
            snrDB: snrDB,
            wetGenerator: { _, _ in 0 }
        )
        let processor = try DynamicsProcessor(
            sampleRate: 48_000,
            settings: neutralSettings(),
            stereoSpeechProcessor: speech,
            upwardGainAuthorizer: MutableSuppressionAuthority(allowsUpwardGain: true)
        )
        var last: Float = 0
        for _ in 0..<(processor.latencyFrameCount + 12_000) {
            last = processor.processFrame(left: 1, right: 1).left
        }
        return last
    }

    private func neutralSettings() -> LevelingSettings {
        LevelingSettings(
            thresholdDB: 0,
            compressorRatio: 1,
            quietCompressionRatio: 1,
            quietPriorityDB: 0,
            noiseGateDB: -160,
            expanderRatio: 1,
            makeupGainDB: 0,
            limiterDB: 0
        )
    }
}

private final class ImpossibleRangeStereoSpeechProcessor: StereoSpeechProcessing {
    let sourceSampleRate = 48_000.0
    let sourceBlockFrameCount = 480
    let decisionLatencyFrameCount = 480
    let processingLatencyFrameCount = 960
    let inputResamplerLatencyFrameCount = 0
    let outputResamplerLatencyFrameCount = 0
    private var frameCount = 0
    private var metadata: DenoisedSpeechBlock?

    func processStereoFrame(left _: Float, right _: Float) -> SpeechAnalysisEvent {
        frameCount += 1
        if frameCount == processingLatencyFrameCount {
            metadata = DenoisedSpeechBlock(
                sourceStartFrameIndex: Int64.max,
                sourceFrameCount: sourceBlockFrameCount,
                speechProbability: 0.99,
                sourcePower: 0.01,
                estimatedSNRDB: 10
            )
        }
        return frameCount.isMultiple(of: sourceBlockFrameCount)
            ? .result(
                SpeechAnalysisResult(
                    probability: 0.99,
                    sourcePower: 0.01,
                    sourceFrameCount: sourceBlockFrameCount,
                    analysisLatencyFrameCount: decisionLatencyFrameCount
                )
            )
            : .pending
    }

    var pendingDenoisedBlock: DenoisedSpeechBlock? { metadata }
    func denoisedSample(frame _: Int, channel _: Int) -> Float { 0 }
    func consumeDenoisedBlock() { metadata = nil }
    func reset() {
        frameCount = 0
        metadata = nil
    }
}

private final class MutableSuppressionAuthority: UpwardGainAuthorizing, @unchecked Sendable {
    var allowsUpwardGain: Bool

    init(allowsUpwardGain: Bool) {
        self.allowsUpwardGain = allowsUpwardGain
    }
}

private final class ScriptedStereoSpeechProcessor: StereoSpeechProcessing {
    let sourceSampleRate: Double
    let sourceBlockFrameCount: Int
    let decisionLatencyFrameCount: Int
    let processingLatencyFrameCount: Int
    let inputResamplerLatencyFrameCount = 0
    let outputResamplerLatencyFrameCount = 0

    var probability: Float
    var sourcePower: Float
    var snrDB: Float?

    private let wetGenerator: (Int64, Int) -> Float
    private var sourceFrameIndex: Int64 = -1
    private var pendingMetadata: DenoisedSpeechBlock?
    private var pendingLeft: [Float]
    private var pendingRight: [Float]

    init(
        sampleRate: Double,
        probability: Float,
        sourcePower: Float,
        snrDB: Float?,
        wetGenerator: @escaping (Int64, Int) -> Float
    ) {
        sourceSampleRate = sampleRate
        sourceBlockFrameCount = Int((sampleRate * 0.010).rounded())
        decisionLatencyFrameCount = sourceBlockFrameCount
        processingLatencyFrameCount = sourceBlockFrameCount * 2
        self.probability = probability
        self.sourcePower = sourcePower
        self.snrDB = snrDB
        self.wetGenerator = wetGenerator
        pendingLeft = [Float](repeating: 0, count: sourceBlockFrameCount)
        pendingRight = [Float](repeating: 0, count: sourceBlockFrameCount)
    }

    func processStereoFrame(left _: Float, right _: Float) -> SpeechAnalysisEvent {
        guard pendingMetadata == nil else { return .failed }
        sourceFrameIndex += 1
        let completedFrameCount = sourceFrameIndex + 1
        guard completedFrameCount % Int64(sourceBlockFrameCount) == 0 else {
            return .pending
        }
        if completedFrameCount >= Int64(processingLatencyFrameCount) {
            let start = completedFrameCount - Int64(processingLatencyFrameCount)
            for frame in 0..<sourceBlockFrameCount {
                let source = start + Int64(frame)
                pendingLeft[frame] = wetGenerator(source, 0)
                pendingRight[frame] = wetGenerator(source, 1)
            }
            pendingMetadata = DenoisedSpeechBlock(
                sourceStartFrameIndex: start,
                sourceFrameCount: sourceBlockFrameCount,
                speechProbability: probability,
                sourcePower: sourcePower,
                estimatedSNRDB: snrDB
            )
        }
        return .result(
            SpeechAnalysisResult(
                probability: probability,
                sourcePower: sourcePower,
                sourceFrameCount: sourceBlockFrameCount,
                analysisLatencyFrameCount: decisionLatencyFrameCount
            )
        )
    }

    var pendingDenoisedBlock: DenoisedSpeechBlock? { pendingMetadata }

    func denoisedSample(frame: Int, channel: Int) -> Float {
        channel == 0 ? pendingLeft[frame] : pendingRight[frame]
    }

    func consumeDenoisedBlock() {
        pendingMetadata = nil
    }

    func reset() {
        sourceFrameIndex = -1
        pendingMetadata = nil
    }
}
