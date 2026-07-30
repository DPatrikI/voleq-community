// SPDX-License-Identifier: MPL-2.0

import XCTest
import VolEqCore
import VolEqSpeech
@testable import VolEqDSP

final class SpeechAwareDynamicsProcessorTests: XCTestCase {
    func testGateOpensImmediatelyUsesHysteresisThenHoldsAndFades() {
        var gate = SpeechLevelingGate(sampleRate: 48_000)
        let open = gate.observe(result(probability: 0.65), fixedNoiseGateDB: -55, compressionThresholdDB: -24)
        XCTAssertEqual(open, 1)

        let hysteresis = gate.observe(result(probability: 0.50), fixedNoiseGateDB: -55, compressionThresholdDB: -24)
        XCTAssertEqual(hysteresis, 1)

        for _ in 0..<20 {
            XCTAssertEqual(
                gate.observe(result(probability: 0.35), fixedNoiseGateDB: -55, compressionThresholdDB: -24),
                1,
                accuracy: 0.0001
            )
        }
        let firstFadeBlock = gate.observe(
            result(probability: 0.35),
            fixedNoiseGateDB: -55,
            compressionThresholdDB: -24
        )
        XCTAssertEqual(firstFadeBlock, 14.0 / 15.0, accuracy: 0.001)

        var finalEligibility = firstFadeBlock
        for _ in 1..<15 {
            finalEligibility = gate.observe(
                result(probability: 0.35),
                fixedNoiseGateDB: -55,
                compressionThresholdDB: -24
            )
        }
        XCTAssertEqual(finalEligibility, 0, accuracy: 0.0001)
        XCTAssertFalse(gate.isOpen)
    }

    func testNoiseFloorLearnsOnlyFromStrongNonSpeechAndRaisesAudibilityGate() {
        var gate = SpeechLevelingGate(sampleRate: 48_000)
        let staticPower = powf(10, -45 / 10)
        for _ in 0..<200 {
            _ = gate.observe(
                result(probability: 0.20, power: staticPower),
                fixedNoiseGateDB: -55,
                compressionThresholdDB: -24
            )
        }
        XCTAssertEqual(gate.learnedNoiseFloorDB ?? 0, -45, accuracy: 0.01)
        XCTAssertEqual(
            gate.effectiveNoiseGateDB(fixedNoiseGateDB: -55, compressionThresholdDB: -24),
            -39,
            accuracy: 0.01
        )

        let learned = gate.learnedNoiseFloorDB
        _ = gate.observe(
            result(probability: 0.21, power: powf(10, -20 / 10)),
            fixedNoiseGateDB: -55,
            compressionThresholdDB: -24
        )
        XCTAssertEqual(gate.learnedNoiseFloorDB, learned)
    }

    func testFirstSpeechBlockIsBackfilledInsideLookahead() throws {
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            script: [
                .init(probability: 0.1, power: power(at: -60)),
                .init(probability: 0.9, power: power(at: -40)),
                .init(probability: 0.9, power: power(at: -40)),
                .init(probability: 0.9, power: power(at: -40))
            ]
        )
        let processor = try DynamicsProcessor(sampleRate: 48_000, speechAnalyzer: analyzer)
        let quiet = amplitude(at: -40)
        var output = [Float]()
        output.reserveCapacity(processor.latencyFrameCount + 6_000)

        for frame in 0..<(processor.latencyFrameCount + 6_000) {
            let input: Float = frame < 480 ? amplitude(at: -60) : quiet
            output.append(processor.processFrame(left: input, right: input).left)
        }

        let unrelatedOutput = output[processor.latencyFrameCount..<(processor.latencyFrameCount + 480)]
        let firstSpeechOutputFrame = processor.latencyFrameCount + 480
        let firstSpeechOutput = output[firstSpeechOutputFrame]
        XCTAssertGreaterThanOrEqual(firstSpeechOutput, quiet * 0.999)
        XCTAssertGreaterThan(output[firstSpeechOutputFrame + 4_800], quiet * 1.05)
        XCTAssertLessThanOrEqual(
            unrelatedOutput.map(abs).max() ?? 0,
            amplitude(at: -60) * 1.001
        )
    }

    func testResamplerLatencyGapUsesNewestKnownSpeechStateWithoutASecondOpening() throws {
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            analysisLatencyFrameCount: 520,
            script: [
                .init(probability: 0.1, power: power(at: -60)),
                .init(probability: 0.9, power: power(at: -40)),
                .init(probability: 0.9, power: power(at: -40))
            ]
        )
        let processor = try DynamicsProcessor(sampleRate: 48_000, speechAnalyzer: analyzer)
        let speech = amplitude(at: -40)
        let totalInputFrames = 1_440
        var output: [Float] = []
        output.reserveCapacity(totalInputFrames + processor.latencyFrameCount)

        for frame in 0..<(totalInputFrames + processor.latencyFrameCount) {
            let input = frame < 440 ? amplitude(at: -60) : speech
            output.append(processor.processFrame(left: input, right: input).left)
        }

        let firstSpeechOutputFrame = processor.latencyFrameCount + 440
        let transition = Array(output[firstSpeechOutputFrame..<(firstSpeechOutputFrame + 520)])
        XCTAssertTrue(transition.allSatisfy { $0 >= speech * 0.999 })
        XCTAssertGreaterThan(transition.last ?? 0, transition.first ?? 0)
        let largestGainStep = zip(transition, transition.dropFirst())
            .map { abs($1 - $0) / speech }
            .max() ?? 0
        XCTAssertLessThan(largestGainStep, 0.01)
        XCTAssertLessThanOrEqual(
            output[..<firstSpeechOutputFrame].map(abs).max() ?? 0,
            amplitude(at: -60) * 1.001
        )
    }

    func testStaticNoiseNeverReceivesUpwardGainAndBecomesAttenuated() throws {
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            repeating: .init(probability: 0.1, power: power(at: -45))
        )
        let processor = try DynamicsProcessor(sampleRate: 48_000, speechAnalyzer: analyzer)
        let input = amplitude(at: -45)
        var audibleOutput: [Float] = []
        for frame in 0..<(48_000 * 4 + processor.latencyFrameCount) {
            let output = processor.processFrame(left: input, right: input).left
            if frame >= processor.latencyFrameCount {
                audibleOutput.append(abs(output))
            }
        }

        XCTAssertLessThanOrEqual(audibleOutput.max() ?? 0, input * 1.001)
        XCTAssertLessThan(audibleOutput.suffix(4_800).max() ?? input, input * 0.8)
    }

    func testQuietSpeechRetainsUpwardLeveling() throws {
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            repeating: .init(probability: 0.9, power: power(at: -40))
        )
        let processor = try DynamicsProcessor(sampleRate: 48_000, speechAnalyzer: analyzer)
        let input = amplitude(at: -40)
        var output: Float = 0
        for _ in 0..<(48_000 + processor.latencyFrameCount) {
            output = processor.processFrame(left: input, right: input).left
        }
        XCTAssertGreaterThan(output, input * 1.5)
    }

    func testSpeechGainSlewCannotDefeatLookaheadOnALoudOnset() throws {
        let sampleRate = 48_000
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: Double(sampleRate),
            repeating: .init(probability: 0.9, power: power(at: -40))
        )
        let processor = try DynamicsProcessor(
            sampleRate: Double(sampleRate),
            speechAnalyzer: analyzer
        )
        let quiet = amplitude(at: -40)

        for _ in 0..<(sampleRate * 2) {
            _ = processor.processFrame(left: quiet, right: quiet)
        }

        var loudOutput: [Float] = []
        loudOutput.reserveCapacity(sampleRate + processor.latencyFrameCount)
        for _ in 0..<(sampleRate + processor.latencyFrameCount) {
            loudOutput.append(abs(processor.processFrame(left: 1, right: 1).left))
        }

        let latency = processor.latencyFrameCount
        let firstLookaheadPeriodPeak = loudOutput[latency..<(latency * 2)].max() ?? 0
        let settledPeak = loudOutput.suffix(latency).max() ?? 0
        XCTAssertGreaterThan(settledPeak, 0)
        XCTAssertLessThanOrEqual(
            decibels(firstLookaheadPeriodPeak),
            decibels(settledPeak) + 1
        )
    }

    func testSpeechToStaticCannotKeepAnExtraGainTail() throws {
        let sampleRate = 48_000
        let input = amplitude(at: -45)
        let speechBlockCount = 100
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: Double(sampleRate),
            script: Array(
                repeating: .init(probability: 0.9, power: power(at: -45)),
                count: speechBlockCount
            ),
            repeating: .init(probability: 0.1, power: power(at: -45))
        )
        let processor = try DynamicsProcessor(
            sampleRate: Double(sampleRate),
            speechAnalyzer: analyzer
        )
        let transitionInputFrame = speechBlockCount * analyzer.sourceBlockFrameCount
        let totalInputFrameCount = transitionInputFrame + sampleRate * 4
        var output: [Float] = []
        output.reserveCapacity(totalInputFrameCount + processor.latencyFrameCount)

        for _ in 0..<(totalInputFrameCount + processor.latencyFrameCount) {
            output.append(abs(processor.processFrame(left: input, right: input).left))
        }

        let transitionOutputFrame = transitionInputFrame + processor.latencyFrameCount
        let afterGateFade = transitionOutputFrame + Int(Double(sampleRate) * 0.36)
        XCTAssertLessThanOrEqual(
            output[afterGateFade..<(afterGateFade + 4_800)].max() ?? input,
            input * 1.001
        )
        XCTAssertLessThan(output.suffix(4_800).max() ?? input, input * 0.8)
    }

    func testAnalysisOnlyMatchesTheLegacyLevelerSampleForSample() throws {
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            repeating: .init(probability: 0.9, power: power(at: -40))
        )
        let analysisOnly = try DynamicsProcessor(
            sampleRate: 48_000,
            speechAnalyzer: analyzer,
            appliesSpeechLeveling: false
        )
        let legacy = DynamicsProcessor(sampleRate: 48_000)

        for frame in 0..<12_000 {
            let left = Float(sin(Double(frame) * 0.031)) * 0.02
            let right = Float(sin(Double(frame) * 0.047 + 0.4)) * 0.018
            let analyzed = analysisOnly.processFrame(left: left, right: right)
            let baseline = legacy.processFrame(left: left, right: right)
            XCTAssertEqual(analyzed.left, baseline.left, accuracy: 0.000_001)
            XCTAssertEqual(analyzed.right, baseline.right, accuracy: 0.000_001)
        }
    }

    func testDeterministicStereoMusicRemainsDryAfterLatencyAlignment() throws {
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            repeating: .init(probability: 0.4, power: power(at: -30))
        )
        let processor = try DynamicsProcessor(sampleRate: 48_000, speechAnalyzer: analyzer)
        let frameCount = 48_000
        var input: [(left: Float, right: Float)] = []
        input.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let left = Float(
                sin(Double(frame) * 0.031) * 0.018
                    + sin(Double(frame) * 0.079) * 0.006
            )
            let right = Float(
                sin(Double(frame) * 0.043 + 0.7) * 0.015
                    + sin(Double(frame) * 0.097) * 0.005
            )
            input.append((left, right))
        }

        var output: [(left: Float, right: Float)] = []
        output.reserveCapacity(frameCount)
        for frame in 0..<(frameCount + processor.latencyFrameCount) {
            let source: (left: Float, right: Float) = frame < frameCount
                ? input[frame]
                : (left: 0, right: 0)
            let processed = processor.processFrame(left: source.left, right: source.right)
            if frame >= processor.latencyFrameCount {
                output.append(processed)
            }
        }

        XCTAssertEqual(output.count, input.count)
        for frame in input.indices {
            XCTAssertEqual(output[frame].left, input[frame].left, accuracy: 0.000_001)
            XCTAssertEqual(output[frame].right, input[frame].right, accuracy: 0.000_001)
        }
    }

    func testLoudNonSpeechStillReceivesDownwardProtection() throws {
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            repeating: .init(probability: 0.4, power: 0.64)
        )
        let processor = try DynamicsProcessor(sampleRate: 48_000, speechAnalyzer: analyzer)
        var output: Float = 0
        for _ in 0..<(48_000 + processor.latencyFrameCount) {
            output = processor.processFrame(left: 0.8, right: -0.8).left
        }
        XCTAssertLessThan(abs(output), 0.4)
    }

    func testAnalysisLatencyCannotExceedPreallocatedCeiling() {
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            analysisLatencyFrameCount: 2_401,
            repeating: .init(probability: 0.9, power: 0.01)
        )
        XCTAssertThrowsError(try DynamicsProcessor(sampleRate: 48_000, speechAnalyzer: analyzer)) { error in
            XCTAssertEqual(
                error as? DynamicsProcessorError,
                .analysisLatencyExceedsCapacity(latencyFrames: 2_401, capacityFrames: 2_400)
            )
        }
    }

    func testAnalyzerLatencyIsTheMinimumWhenLookaheadIsDisabled() throws {
        var settings = LevelingSettings()
        settings.lookaheadSeconds = 0
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            analysisLatencyFrameCount: 480,
            repeating: .init(probability: 0.4, power: 0.01)
        )
        let processor = try DynamicsProcessor(
            sampleRate: 48_000,
            settings: settings,
            speechAnalyzer: analyzer
        )
        XCTAssertEqual(processor.latencyFrameCount, 480)
    }

    func testSpeechAwareLookaheadCannotChangeWithoutRebuildingAnalyzerTimeline() throws {
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            repeating: .init(probability: 0.4, power: 0.01)
        )
        let processor = try DynamicsProcessor(sampleRate: 48_000, speechAnalyzer: analyzer)
        var settings = processor.settings
        settings.lookaheadSeconds = 0.040
        processor.updateSettings(settings)

        XCTAssertEqual(processor.settings.lookaheadSeconds, 0.020)
        XCTAssertEqual(processor.latencyFrameCount, 960)
    }

    func testNonFiniteAnalysisFailsAndSilencesProcessing() throws {
        let analyzer = ScriptedSpeechAnalyzer(
            sampleRate: 48_000,
            repeating: .init(probability: .nan, power: 0.01)
        )
        let processor = try DynamicsProcessor(sampleRate: 48_000, speechAnalyzer: analyzer)
        for _ in 0..<479 {
            _ = processor.processFrame(left: 0.1, right: 0.1)
        }
        let failedOutput = processor.processFrame(left: 0.1, right: 0.1)
        XCTAssertEqual(failedOutput.left, 0)
        XCTAssertEqual(failedOutput.right, 0)
        XCTAssertTrue(processor.consumeProcessingFailure())
        XCTAssertTrue(processor.consumeProcessingFailure())
        processor.reset()
        XCTAssertFalse(processor.consumeProcessingFailure())
    }

    private func result(
        probability: Float,
        power: Float = 0.01,
        frameCount: Int = 480
    ) -> SpeechAnalysisResult {
        SpeechAnalysisResult(
            probability: probability,
            sourcePower: power,
            sourceFrameCount: frameCount,
            analysisLatencyFrameCount: frameCount
        )
    }

    private func amplitude(at decibels: Float) -> Float {
        powf(10, decibels / 20)
    }

    private func power(at decibels: Float) -> Float {
        powf(10, decibels / 10)
    }

    private func decibels(_ amplitude: Float) -> Float {
        20 * log10f(max(amplitude, 0.000_000_1))
    }
}

private final class ScriptedSpeechAnalyzer: SpeechAnalyzing {
    struct Entry {
        let probability: Float
        let power: Float
    }

    let sourceSampleRate: Double
    let sourceBlockFrameCount: Int
    let analysisLatencyFrameCount: Int
    private let script: [Entry]
    private let repeatingEntry: Entry?
    private var sampleIndex = 0
    private var resultIndex = 0

    init(
        sampleRate: Double,
        analysisLatencyFrameCount: Int? = nil,
        script: [Entry] = [],
        repeating: Entry? = nil
    ) {
        sourceSampleRate = sampleRate
        sourceBlockFrameCount = Int((sampleRate * 0.010).rounded())
        self.analysisLatencyFrameCount = analysisLatencyFrameCount ?? sourceBlockFrameCount
        self.script = script
        repeatingEntry = repeating
    }

    convenience init(sampleRate: Double, repeating: Entry) {
        self.init(sampleRate: sampleRate, script: [], repeating: repeating)
    }

    func processMonoSample(_: Float) -> SpeechAnalysisEvent {
        sampleIndex += 1
        guard sampleIndex == sourceBlockFrameCount else { return .pending }
        sampleIndex = 0

        let entry: Entry
        if resultIndex < script.count {
            entry = script[resultIndex]
        } else if let repeatingEntry {
            entry = repeatingEntry
        } else if let last = script.last {
            entry = last
        } else {
            return .pending
        }
        resultIndex += 1
        return .result(
            SpeechAnalysisResult(
                probability: entry.probability,
                sourcePower: entry.power,
                sourceFrameCount: sourceBlockFrameCount,
                analysisLatencyFrameCount: analysisLatencyFrameCount
            )
        )
    }

    func reset() {
        sampleIndex = 0
        resultIndex = 0
    }
}
