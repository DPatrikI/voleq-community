// SPDX-License-Identifier: MPL-2.0

import XCTest
import VolEqCore
import VolEqSpeech
@testable import VolEqDSP

final class DynamicsInternalComponentTests: XCTestCase {
    func testRuntimeParametersSnapshotNormalizesSettingsOnce() {
        let unsafe = LevelingSettings(
            thresholdDB: .nan,
            compressorRatio: 0,
            quietCompressionRatio: .infinity,
            lookaheadSeconds: 0.075
        )
        let snapshot = DynamicsRuntimeParameters.make(
            settings: unsafe,
            sampleRate: 48_000
        )

        XCTAssertEqual(snapshot.settings, unsafe.normalized())
        XCTAssertEqual(snapshot.lookaheadFrameCount, 2_400)
        XCTAssertTrue(snapshot.attackCoefficient.isFinite)
        XCTAssertTrue(snapshot.limiterAmplitude.isFinite)
    }

    func testDelayedDynamicsFrameKeepsSampleAndMetadataTogetherThroughRing() {
        let buffer = DynamicsLookaheadBuffer(
            maximumFrameCount: 8,
            initialUpwardEligibility: 0
        )
        buffer.reset(activeLookaheadFrameCount: 1)

        _ = buffer.delay(
            left: 0.25,
            right: -0.5,
            maximumGain: 0.75,
            upwardEligibility: 1,
            sourceFrameIndex: 42
        )
        let delayed = buffer.delay(
            left: 0,
            right: 0,
            maximumGain: 1,
            upwardEligibility: 0,
            sourceFrameIndex: 43
        )
        XCTAssertEqual(delayed.left, 0.25)
        XCTAssertEqual(delayed.right, -0.5)
        XCTAssertEqual(delayed.maximumGain, 0.75)
        XCTAssertEqual(delayed.upwardEligibility, 1)
        XCTAssertFalse(delayed.wetValid)
        XCTAssertEqual(delayed.sourceFrameIndex, 42)

        buffer.reset(activeLookaheadFrameCount: 1)
        let resetWarmup = buffer.delay(
            left: 0.75,
            right: 0.5,
            maximumGain: 0.5,
            upwardEligibility: 1,
            sourceFrameIndex: 99
        )
        XCTAssertEqual(resetWarmup.sourceFrameIndex, -1)
        let resetDelayed = buffer.delay(
            left: 0,
            right: 0,
            maximumGain: 1,
            upwardEligibility: 0,
            sourceFrameIndex: 100
        )
        XCTAssertEqual(resetDelayed.sourceFrameIndex, 99)
        XCTAssertEqual(resetDelayed.left, 0.75)
    }
}
