// SPDX-License-Identifier: MPL-2.0

import CVolEqRealtime
import Foundation

struct AudioCaptureLivenessObservation: Equatable, Sendable {
    let callbackSequence: UInt64
    let capturedFrameCount: UInt32
    let requestedOutputFrameCount: UInt32
    let capturedPeak: Float
    let allZero: Bool
    let noCapturedFrames: Bool
    let partialDelivery: Bool
    let nonfiniteInput: Bool
    let outputRequestActive: Bool

    init(
        callbackSequence: UInt64,
        capturedFrameCount: UInt32,
        requestedOutputFrameCount: UInt32,
        capturedPeak: Float,
        allZero: Bool,
        noCapturedFrames: Bool,
        partialDelivery: Bool,
        nonfiniteInput: Bool,
        outputRequestActive: Bool
    ) {
        self.callbackSequence = callbackSequence
        self.capturedFrameCount = capturedFrameCount
        self.requestedOutputFrameCount = requestedOutputFrameCount
        self.capturedPeak = capturedPeak
        self.allZero = allZero
        self.noCapturedFrames = noCapturedFrames
        self.partialDelivery = partialDelivery
        self.nonfiniteInput = nonfiniteInput
        self.outputRequestActive = outputRequestActive
    }

    init(_ record: VolEqRealtimeLivenessRecord) {
        callbackSequence = record.sequence
        capturedFrameCount = record.captured_frame_count
        requestedOutputFrameCount = record.requested_output_frame_count
        capturedPeak = record.captured_peak
        allZero = record.flags & UInt32(VOLEQ_LIVENESS_FLAG_ALL_ZERO) != 0
        noCapturedFrames = record.flags
            & UInt32(VOLEQ_LIVENESS_FLAG_NO_CAPTURED_FRAMES) != 0
        partialDelivery = record.flags
            & UInt32(VOLEQ_LIVENESS_FLAG_PARTIAL_DELIVERY) != 0
        nonfiniteInput = record.flags
            & UInt32(VOLEQ_LIVENESS_FLAG_NONFINITE_INPUT) != 0
        outputRequestActive = record.flags
            & UInt32(VOLEQ_LIVENESS_FLAG_OUTPUT_REQUEST_ACTIVE) != 0
    }

    var isExactFullFrameZeroDelivery: Bool {
        allZero
            && !noCapturedFrames
            && !partialDelivery
            && !nonfiniteInput
            && outputRequestActive
            && capturedFrameCount > 0
            && requestedOutputFrameCount > 0
            && capturedPeak == 0
    }

    var isHealthyNonzeroDelivery: Bool {
        !allZero
            && !noCapturedFrames
            && !partialDelivery
            && !nonfiniteInput
            && outputRequestActive
            && capturedFrameCount > 0
            && requestedOutputFrameCount > 0
            && capturedPeak > 0
    }
}

/// Preallocated single-producer state used to distinguish progressing callbacks
/// from useful captured-audio delivery. Audio samples never enter this state,
/// and all allocation is completed before AudioDeviceStart.
final class AudioCaptureLivenessState: @unchecked Sendable {
    private let state: OpaquePointer
    private let drainCapacity: Int
    private let drainBuffer: UnsafeMutablePointer<VolEqRealtimeLivenessRecord>

    init(capacity: Int = 4_096) throws {
        guard capacity >= 2,
              let state = voleq_realtime_liveness_state_create(capacity)
        else {
            throw VolEqError.missingValue(
                "VolEq could not allocate audio liveness state."
            )
        }
        self.state = state
        drainCapacity = capacity
        drainBuffer = .allocate(capacity: capacity)
    }

    deinit {
        voleq_realtime_liveness_state_destroy(state)
        drainBuffer.deallocate()
    }

    @inline(__always)
    func record(_ metadata: AudioCaptureLivenessMetadata) {
        voleq_realtime_liveness_state_record(
            state,
            UInt32(clamping: metadata.inputFrameCount),
            UInt32(clamping: metadata.outputFrameCount),
            metadata.capturedPeak,
            metadata.flags
        )
    }

    func drain() -> [AudioCaptureLivenessObservation] {
        let count = voleq_realtime_liveness_state_read(
            state,
            drainBuffer,
            drainCapacity
        )
        return UnsafeBufferPointer(start: drainBuffer, count: Int(count))
            .map(AudioCaptureLivenessObservation.init)
    }
}
