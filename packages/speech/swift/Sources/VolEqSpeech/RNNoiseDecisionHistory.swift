// SPDX-License-Identifier: MPL-2.0

import Foundation

final class RNNoiseDecisionHistory {
    private var starts = [Int64](repeating: -1, count: 8)
    private var probabilities = [Float](repeating: 0, count: 8)
    private var powers = [Float](repeating: 0, count: 8)
    private var snr = [Float](repeating: .nan, count: 8)

    func store(probability: Float, power: Float, start: Int64, blockFrameCount: Int) {
        let block = start / Int64(blockFrameCount)
        let slot = Int(block % Int64(starts.count))
        starts[slot] = start
        probabilities[slot] = probability
        powers[slot] = power
        snr[slot] = .nan
    }

    func decision(
        at start: Int64,
        blockFrameCount: Int
    ) -> (probability: Float, power: Float, snrDB: Float?)? {
        let block = start / Int64(blockFrameCount)
        let slot = Int(block % Int64(starts.count))
        guard starts[slot] == start else { return nil }
        return (
            probabilities[slot],
            powers[slot],
            snr[slot].isFinite ? snr[slot] : nil
        )
    }

    func storeEstimatedSNR(
        for sourceStart: Int64,
        blockFrameCount: Int,
        estimatedSNRDB: Float?
    ) {
        guard sourceStart >= 0 else { return }
        let block = sourceStart / Int64(blockFrameCount)
        let slot = Int(block % Int64(starts.count))
        guard starts[slot] == sourceStart else { return }
        if let estimatedSNRDB, estimatedSNRDB.isFinite {
            snr[slot] = estimatedSNRDB
        } else {
            snr[slot] = .nan
        }
    }

    func reset() {
        for index in starts.indices { starts[index] = -1 }
        for index in probabilities.indices { probabilities[index] = 0 }
        for index in powers.indices { powers[index] = 0 }
        for index in snr.indices { snr[index] = .nan }
    }
}
