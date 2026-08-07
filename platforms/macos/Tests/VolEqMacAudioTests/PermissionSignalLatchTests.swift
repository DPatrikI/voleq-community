// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import XCTest
@testable import VolEqMacAudio

final class PermissionSignalLatchTests: AudioPipelineTestCase {
    func testTwoQualifyingFiniteCallbacksAuthorizeVerification() throws {
        let latch = try PermissionSignalLatch()
        var first = [Float(2.0e-7), 0]
        var second = [Float(0), -3.0e-7]

        withInterleavedStereoBuffer(samples: &first) { input in
            latch._testOnlyObserve(input)
        }
        XCTAssertEqual(latch.qualifyingCallbackCount, 1)

        withInterleavedStereoBuffer(samples: &second) { input in
            latch._testOnlyObserve(input)
        }
        XCTAssertEqual(latch.qualifyingCallbackCount, 2)
        XCTAssertFalse(latch.isMalformed)
    }

    func testOneCallbackSilenceAndSubThresholdNoiseDoNotAuthorize() throws {
        let latch = try PermissionSignalLatch()
        var qualifying = [Float(2.0e-7), 0]
        var silence = [Float.zero, 0]
        var subThreshold = [Float(1.0e-7), -9.0e-8]

        withInterleavedStereoBuffer(samples: &qualifying) { input in
            latch._testOnlyObserve(input)
        }
        withInterleavedStereoBuffer(samples: &silence) { input in
            latch._testOnlyObserve(input)
        }
        withInterleavedStereoBuffer(samples: &subThreshold) { input in
            latch._testOnlyObserve(input)
        }

        XCTAssertEqual(latch.qualifyingCallbackCount, 1)
        XCTAssertFalse(latch.isMalformed)
    }

    func testNaNAndInfinityFailClosedAsMalformed() throws {
        for malformedSample in [Float.nan, Float.infinity, -Float.infinity] {
            let latch = try PermissionSignalLatch()
            var samples = [malformedSample, Float(0.5)]

            withInterleavedStereoBuffer(samples: &samples) { input in
                latch._testOnlyObserve(input)
            }

            XCTAssertTrue(latch.isMalformed)
            XCTAssertEqual(latch.qualifyingCallbackCount, 0)
        }
    }

    func testMalformedByteCountFailsClosed() throws {
        let latch = try PermissionSignalLatch()
        var sample = Float(0.5)

        withUnsafeMutablePointer(to: &sample) { pointer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(MemoryLayout<Float>.size - 1),
                    mData: pointer
                )
            )
            withUnsafePointer(to: &list) { input in
                latch._testOnlyObserve(input)
            }
        }

        XCTAssertTrue(latch.isMalformed)
        XCTAssertEqual(latch.qualifyingCallbackCount, 0)
    }

    func testProductionProbeIsUnmutedInputOnlyAndUsesPublicCoreAudio() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let probe = try String(contentsOf: root.appendingPathComponent(
            "platforms/macos/Sources/VolEqMacAudio/SystemAudioPermissionProbe.swift"
        ))
        let realtime = try String(contentsOf: root.appendingPathComponent(
            "platforms/macos/Sources/CVolEqRealtime/VolEqRealtime.c"
        ))

        XCTAssertTrue(probe.contains("description.muteBehavior = .unmuted"))
        XCTAssertTrue(probe.contains("kAudioAggregateDeviceTapListKey"))
        XCTAssertFalse(probe.contains("kAudioAggregateDeviceSubDeviceListKey"))
        XCTAssertFalse(probe.contains("CGPreflight"))
        XCTAssertFalse(probe.contains("CGRequest"))
        XCTAssertFalse(probe.contains("TCC"))
        XCTAssertTrue(realtime.contains("#include <stdatomic.h>"))
        XCTAssertTrue(realtime.contains("1.0e-7f"))
        XCTAssertFalse(realtime.contains("printf("))
        XCTAssertFalse(realtime.contains("pthread_mutex"))
    }
}
