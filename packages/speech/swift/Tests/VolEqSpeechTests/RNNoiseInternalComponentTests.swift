// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VolEqSpeech

final class RNNoiseInternalComponentTests: XCTestCase {
    func testTaggedStereoHistoryRequiresExactSourceTagsAndComputesStereoPower() {
        let history = RNNoiseTaggedStereoHistory(capacity: 4)
        history.store(left: 0.5, right: -0.25, at: 12)
        history.store(left: 0.25, right: 0.5, at: 13)

        XCTAssertEqual(history.frame(at: 12)?.left, 0.5)
        XCTAssertEqual(history.frame(at: 12)?.right, -0.25)
        XCTAssertNil(history.frame(at: 8))
        let powers = try! XCTUnwrap(history.sourcePowers(start: 12, frameCount: 2))
        let expectedLeftPower = Float((0.5 * 0.5 + 0.25 * 0.25) / 2)
        let expectedRightPower = Float((0.25 * 0.25 + 0.5 * 0.5) / 2)
        XCTAssertEqual(powers.left, expectedLeftPower, accuracy: 0.000_001)
        XCTAssertEqual(powers.right, expectedRightPower, accuracy: 0.000_001)
    }

    func testWetFIFOPreservesSourceTagsAndOnlyCommitsValidatedConsumption() {
        let fifo = RNNoiseWetOutputFIFO(capacity: 4)
        XCTAssertTrue(fifo.enqueue(left: 0.1, right: 0.2, sourceFrameIndex: 40))
        XCTAssertTrue(fifo.enqueue(left: 0.3, right: 0.4, sourceFrameIndex: 41))
        XCTAssertEqual(fifo.count, 2)
        XCTAssertEqual(fifo.frame(atOffset: 0)?.sourceFrameIndex, 40)
        XCTAssertEqual(fifo.frame(atOffset: 1)?.sourceFrameIndex, 41)

        fifo.consume(1)
        XCTAssertEqual(fifo.count, 1)
        XCTAssertEqual(fifo.frame(atOffset: 0)?.sourceFrameIndex, 41)
        XCTAssertTrue(fifo.enqueue(left: 0.5, right: 0.6, sourceFrameIndex: 42))
        XCTAssertTrue(fifo.enqueue(left: 0.7, right: 0.8, sourceFrameIndex: 43))
        fifo.consume(2)
        XCTAssertEqual(fifo.count, 1)
        XCTAssertEqual(fifo.frame(atOffset: 0)?.sourceFrameIndex, 43)
        XCTAssertTrue(fifo.enqueue(left: 0.9, right: 1.0, sourceFrameIndex: 44))
        XCTAssertEqual(fifo.frame(atOffset: 1)?.sourceFrameIndex, 44)
        fifo.reset()
        XCTAssertEqual(fifo.count, 0)
        XCTAssertNil(fifo.frame(atOffset: 0))
    }

    func testWetFIFORejectsFullCapacityAndInvalidConsumptionWithoutMutation() {
        let fifo = RNNoiseWetOutputFIFO(capacity: 2)
        XCTAssertNil(fifo.frame(atOffset: -1))
        XCTAssertTrue(fifo.enqueue(left: 0.1, right: 0.2, sourceFrameIndex: 10))
        XCTAssertTrue(fifo.enqueue(left: 0.3, right: 0.4, sourceFrameIndex: 11))
        XCTAssertFalse(fifo.enqueue(left: 0.5, right: 0.6, sourceFrameIndex: 12))
        XCTAssertEqual(fifo.count, 2)

        fifo.consume(-1)
        XCTAssertEqual(fifo.count, 2)
        fifo.consume(3)
        XCTAssertEqual(fifo.count, 2)
        XCTAssertEqual(fifo.frame(atOffset: 0)?.sourceFrameIndex, 10)
        XCTAssertEqual(fifo.frame(atOffset: 1)?.sourceFrameIndex, 11)
    }

    func testDecisionHistoryKeepsProbabilityPowerAndDelayedSNRAssociated() {
        let history = RNNoiseDecisionHistory()
        history.store(probability: 0.8, power: 0.02, start: 480, blockFrameCount: 480)
        XCTAssertEqual(
            history.decision(at: 480, blockFrameCount: 480)?.probability,
            0.8
        )
        XCTAssertNil(history.decision(at: 0, blockFrameCount: 480))

        history.storeEstimatedSNR(
            for: 480,
            blockFrameCount: 480,
            estimatedSNRDB: -4.771_213
        )
        let decision = try! XCTUnwrap(history.decision(at: 480, blockFrameCount: 480))
        let estimatedSNR = try! XCTUnwrap(decision.snrDB)
        XCTAssertEqual(estimatedSNR, -4.771_213, accuracy: 0.000_001)
    }
}
