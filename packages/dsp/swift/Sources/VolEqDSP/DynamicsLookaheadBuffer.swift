// SPDX-License-Identifier: MPL-2.0

import Foundation
import VolEqSpeech

struct DelayedDynamicsFrame {
    let left: Float
    let right: Float
    let maximumGain: Float
    let upwardEligibility: Float
    let wetLeft: Float
    let wetRight: Float
    let wetValid: Bool
    let suppressionTarget: Float
    let sourceFrameIndex: Int64
}

final class DynamicsLookaheadBuffer {
    private let delayedLeft: UnsafeMutableBufferPointer<Float>
    private let delayedRight: UnsafeMutableBufferPointer<Float>
    private let delayedMaximumGain: UnsafeMutableBufferPointer<Float>
    private let delayedUpwardEligibility: UnsafeMutableBufferPointer<Float>
    private let delayedWetLeft: UnsafeMutableBufferPointer<Float>
    private let delayedWetRight: UnsafeMutableBufferPointer<Float>
    private let delayedWetValid: UnsafeMutableBufferPointer<Bool>
    private let delayedSuppressionTarget: UnsafeMutableBufferPointer<Float>
    private let delayedSourceFrameIndex: UnsafeMutableBufferPointer<Int64>
    private let initialUpwardEligibility: Float

    private var delayWriteIndex = 0
    private var delayedFrameCount = 0
    private(set) var activeLookaheadFrameCount: Int

    init(maximumFrameCount: Int, initialUpwardEligibility: Float) {
        activeLookaheadFrameCount = maximumFrameCount
        self.initialUpwardEligibility = initialUpwardEligibility
        delayedLeft = Self.allocateBuffer(repeating: 0, count: maximumFrameCount)
        delayedRight = Self.allocateBuffer(repeating: 0, count: maximumFrameCount)
        delayedMaximumGain = Self.allocateBuffer(
            repeating: Float.greatestFiniteMagnitude,
            count: maximumFrameCount
        )
        delayedUpwardEligibility = Self.allocateBuffer(
            repeating: initialUpwardEligibility,
            count: maximumFrameCount
        )
        delayedWetLeft = Self.allocateBuffer(repeating: 0, count: maximumFrameCount)
        delayedWetRight = Self.allocateBuffer(repeating: 0, count: maximumFrameCount)
        delayedWetValid = Self.allocateBuffer(repeating: false, count: maximumFrameCount)
        delayedSuppressionTarget = Self.allocateBuffer(repeating: 0, count: maximumFrameCount)
        delayedSourceFrameIndex = Self.allocateBuffer(repeating: -1, count: maximumFrameCount)
    }

    deinit {
        Self.deallocateBuffer(delayedLeft)
        Self.deallocateBuffer(delayedRight)
        Self.deallocateBuffer(delayedMaximumGain)
        Self.deallocateBuffer(delayedUpwardEligibility)
        Self.deallocateBuffer(delayedWetLeft)
        Self.deallocateBuffer(delayedWetRight)
        Self.deallocateBuffer(delayedWetValid)
        Self.deallocateBuffer(delayedSuppressionTarget)
        Self.deallocateBuffer(delayedSourceFrameIndex)
    }

    var delayedFrameCountForBackfill: Int { delayedFrameCount }

    func delay(
        left: Float,
        right: Float,
        maximumGain: Float,
        upwardEligibility: Float,
        sourceFrameIndex: Int64
    ) -> DelayedDynamicsFrame {
        let lookaheadFrameCount = activeLookaheadFrameCount
        guard lookaheadFrameCount > 0 else {
            return DelayedDynamicsFrame(
                left: left,
                right: right,
                maximumGain: maximumGain,
                upwardEligibility: upwardEligibility,
                wetLeft: 0,
                wetRight: 0,
                wetValid: false,
                suppressionTarget: 0,
                sourceFrameIndex: sourceFrameIndex
            )
        }

        if delayedFrameCount < lookaheadFrameCount {
            store(
                left: left,
                right: right,
                maximumGain: maximumGain,
                upwardEligibility: upwardEligibility,
                sourceFrameIndex: sourceFrameIndex
            )
            delayedFrameCount += 1
            return DelayedDynamicsFrame(
                left: 0,
                right: 0,
                maximumGain: .greatestFiniteMagnitude,
                upwardEligibility: 0,
                wetLeft: 0,
                wetRight: 0,
                wetValid: false,
                suppressionTarget: 0,
                sourceFrameIndex: -1
            )
        }

        let output = DelayedDynamicsFrame(
            left: delayedLeft[delayWriteIndex],
            right: delayedRight[delayWriteIndex],
            maximumGain: delayedMaximumGain[delayWriteIndex],
            upwardEligibility: delayedUpwardEligibility[delayWriteIndex],
            wetLeft: delayedWetLeft[delayWriteIndex],
            wetRight: delayedWetRight[delayWriteIndex],
            wetValid: delayedWetValid[delayWriteIndex],
            suppressionTarget: delayedSuppressionTarget[delayWriteIndex],
            sourceFrameIndex: delayedSourceFrameIndex[delayWriteIndex]
        )
        store(
            left: left,
            right: right,
            maximumGain: maximumGain,
            upwardEligibility: upwardEligibility,
            sourceFrameIndex: sourceFrameIndex
        )
        return output
    }

    func backfillDenoisedFrame(
        sourceFrameIndex: Int64,
        currentSourceFrameIndex: Int64,
        wetLeft: Float,
        wetRight: Float,
        suppressionTarget: Float
    ) -> Bool {
        guard wetLeft.isFinite, wetRight.isFinite else { return false }
        let age = currentSourceFrameIndex - sourceFrameIndex
        guard age > 0,
              age <= Int64(delayedFrameCount),
              activeLookaheadFrameCount > 0 else {
            return false
        }
        let slot = (
            delayWriteIndex - Int(age) + activeLookaheadFrameCount
        ) % activeLookaheadFrameCount
        guard delayedSourceFrameIndex[slot] == sourceFrameIndex else { return false }
        delayedWetLeft[slot] = wetLeft
        delayedWetRight[slot] = wetRight
        delayedWetValid[slot] = true
        delayedSuppressionTarget[slot] = suppressionTarget
        return true
    }

    func backfillEligibility(_ eligibility: Float, analysisLatencyFrameCount: Int) {
        let oldestCoveredFrameAge = analysisLatencyFrameCount - 1
        guard oldestCoveredFrameAge > 0,
              delayedFrameCount > 0,
              activeLookaheadFrameCount > 0 else { return }
        let firstAge = 1
        let lastAge = min(oldestCoveredFrameAge, delayedFrameCount)
        guard firstAge <= lastAge else { return }
        for age in firstAge...lastAge {
            let index = (delayWriteIndex - age + activeLookaheadFrameCount)
                % activeLookaheadFrameCount
            delayedUpwardEligibility[index] = eligibility
        }
    }

    func reset(activeLookaheadFrameCount: Int) {
        delayWriteIndex = 0
        delayedFrameCount = 0
        self.activeLookaheadFrameCount = activeLookaheadFrameCount
        for index in delayedLeft.indices {
            delayedLeft[index] = 0
            delayedRight[index] = 0
            delayedMaximumGain[index] = .greatestFiniteMagnitude
            delayedUpwardEligibility[index] = initialUpwardEligibility
            delayedWetLeft[index] = 0
            delayedWetRight[index] = 0
            delayedWetValid[index] = false
            delayedSuppressionTarget[index] = 0
            delayedSourceFrameIndex[index] = -1
        }
    }

    private func store(
        left: Float,
        right: Float,
        maximumGain: Float,
        upwardEligibility: Float,
        sourceFrameIndex: Int64
    ) {
        delayedLeft[delayWriteIndex] = left
        delayedRight[delayWriteIndex] = right
        delayedMaximumGain[delayWriteIndex] = maximumGain
        delayedUpwardEligibility[delayWriteIndex] = upwardEligibility
        delayedWetValid[delayWriteIndex] = false
        delayedSuppressionTarget[delayWriteIndex] = 0
        delayedSourceFrameIndex[delayWriteIndex] = sourceFrameIndex
        delayWriteIndex += 1
        if delayWriteIndex == activeLookaheadFrameCount {
            delayWriteIndex = 0
        }
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
