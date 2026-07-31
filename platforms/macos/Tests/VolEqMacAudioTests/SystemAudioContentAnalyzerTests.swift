// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VolEqMacAudio

final class SystemAudioContentAnalyzerTests: XCTestCase {
    func testUnknownAndSpeechLikeNonMusicRemainUnauthorized() {
        XCTAssertFalse(
            SystemAudioContentDecision.classify(
                classifications: []
            ) == .speech
        )
        XCTAssertFalse(
            SystemAudioContentDecision.classify(
                classifications: [
                    (identifier: "speech", confidence: 0.21),
                    (identifier: "laughter", confidence: 0.79)
                ]
            ) == .speech
        )
    }

    func testConfidentSpeechWithoutMusicIsAuthorized() {
        XCTAssertEqual(
            SystemAudioContentDecision.classify(
                classifications: [
                    (identifier: "speech", confidence: 0.78),
                    (identifier: "typing", confidence: 0.08),
                    (identifier: "music", confidence: 0.02)
                ]
            ),
            .speech
        )
    }

    func testObservedQuietSpeechOutranksGenericMusicConfusion() {
        XCTAssertEqual(
            SystemAudioContentDecision.classify(
                classifications: [
                    (identifier: "speech", confidence: 0.26),
                    (identifier: "music", confidence: 0.39)
                ]
            ),
            .speech
        )
    }

    func testObservedChillMusicRemainsMusic() {
        XCTAssertEqual(
            SystemAudioContentDecision.classify(
                classifications: [
                    (identifier: "speech", confidence: 0.10),
                    (identifier: "music", confidence: 0.43)
                ]
            ),
            .music
        )
    }

    func testWeakSpeechAgainstMusicOrInstrumentEvidenceRemainsMusic() {
        for identifier in ["singing", "piano", "guitar"] {
            XCTAssertEqual(
                SystemAudioContentDecision.classify(
                    classifications: [
                        (identifier: "speech", confidence: 0.10),
                        (identifier: identifier, confidence: 0.43)
                    ]
                ),
                .music,
                "Expected \(identifier) to remain classified as music"
            )
        }
    }

    func testStrongSpeechOutranksSpuriousExplicitMusicEvidence() {
        XCTAssertEqual(
            SystemAudioContentDecision.classify(
                classifications: [
                    (identifier: "speech", confidence: 0.61),
                    (identifier: "singing", confidence: 0.29)
                ]
            ),
            .speech
        )
    }

    func testContentGateConfirmsSpeechHoldsUncertaintyAndImmediatelyVetoesMusic() {
        var gate = SystemAudioContentGate()
        XCTAssertFalse(gate.observe(.speech))
        XCTAssertTrue(gate.observe(.speech))

        for _ in 0..<SystemAudioContentGate.uncertainSpeechHoldResultCount {
            XCTAssertTrue(gate.observe(.unknown))
        }
        XCTAssertFalse(gate.observe(.unknown))

        XCTAssertFalse(gate.observe(.speech))
        XCTAssertTrue(gate.observe(.speech))
        XCTAssertFalse(gate.observe(.music))
        XCTAssertFalse(gate.observe(.speech))
        XCTAssertTrue(gate.observe(.speech))
        gate.reset()
        XCTAssertFalse(gate.allowsUpwardGain)
    }

    func testSystemClassifierStartsConservativelyAtHalfSecondResolution() throws {
        let analyzer = try SystemAudioContentAnalyzer(sampleRate: 48_000)
        XCTAssertFalse(analyzer.allowsUpwardGain)
        XCTAssertEqual(SystemAudioContentAnalyzer.analysisWindowSeconds, 0.5)
        XCTAssertEqual(SystemAudioContentAnalyzer.overlapFactor, 0.5)
        XCTAssertEqual(
            SystemAudioContentAnalyzer.drainIntervalMilliseconds
                * SystemAudioContentAnalyzer.inputGapResetDrainCount,
            500
        )
    }
}
