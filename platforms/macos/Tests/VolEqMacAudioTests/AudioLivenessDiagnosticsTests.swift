// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import CVolEqRealtime
import Foundation
import XCTest
@testable import VolEqMacAudio

final class AudioLivenessDiagnosticsTests: AudioPipelineTestCase {
    func testCallbacksProgressWhileCapturedInputRemainsAllZero() throws {
        let heartbeat = try AudioCallbackHeartbeat()
        let telemetry = try AudioCallbackTelemetry(capacity: 8)
        let metadata = AudioIOCallbackMetadata(
            inputFrameCount: 256,
            outputFrameCount: 256,
            capturedPeak: 0,
            flags: UInt32(VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO)
                | UInt32(VOLEQ_DIAGNOSTIC_FLAG_OUTPUT_REQUEST_ACTIVE),
            path: 1,
            outcome: 4,
            status: noErr
        )

        for hostTime in [UInt64(100), 200, 300] {
            heartbeat.recordCallback()
            telemetry.record(hostTime: hostTime, metadata: metadata)
        }
        let drained = telemetry.drain()

        XCTAssertEqual(heartbeat.callbackCount, 3)
        XCTAssertEqual(drained.records.count, 3)
        XCTAssertEqual(drained.records.map(\.zero_run_length), [1, 2, 3])
        XCTAssertEqual(drained.droppedRecordCount, 0)
    }

    func testAudioProcessorReportsAllZeroAndPartialInputWithoutChangingOutput() throws {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let regular = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        let diagnostic = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        var input = [Float](repeating: 0, count: 256 * 2)
        var regularOutput = [Float](repeating: 0.75, count: 512 * 2)
        var diagnosticOutput = regularOutput
        var metadata: AudioIOCallbackMetadata?

        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(
                samples: &regularOutput,
                channelCount: 2
            ) { outputList in
                regular.process(input: inputList, output: outputList)
            }
            withMutableInterleavedBuffer(
                samples: &diagnosticOutput,
                channelCount: 2
            ) { outputList in
                metadata = diagnostic.processWithDiagnostics(
                    input: inputList,
                    output: outputList
                )
            }
        }

        XCTAssertEqual(diagnosticOutput, regularOutput)
        let resolved = try XCTUnwrap(metadata)
        XCTAssertNotEqual(
            resolved.flags & UInt32(VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO),
            0
        )
        XCTAssertNotEqual(
            resolved.flags & UInt32(VOLEQ_DIAGNOSTIC_FLAG_PARTIAL_DELIVERY),
            0
        )
        XCTAssertEqual(resolved.capturedPeak, 0)
        XCTAssertEqual(resolved.inputFrameCount, 256)
        XCTAssertEqual(resolved.outputFrameCount, 512)

        let telemetry = try AudioCallbackTelemetry(capacity: 4)
        telemetry.record(hostTime: 1, metadata: resolved)
        telemetry.record(hostTime: 2, metadata: resolved)
        XCTAssertEqual(
            telemetry.drain().records.map(\.partial_run_length),
            [1, 2]
        )
    }

    func testDiagnosticScanIsOutputEquivalentForNonzeroAudio() throws {
        let format = floatFormat(sampleRate: 48_000, channelCount: 2)
        let regular = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        let diagnostic = try AudioIOProcessor(
            inputFormat: format,
            outputFormat: format,
            settings: neutralSettings(),
            speechAwarenessEnabled: false
        )
        var input = (0..<(512 * 2)).map {
            Float(($0 % 19) - 9) * 0.002
        }
        var regularOutput = [Float](repeating: 0.75, count: 512 * 2)
        var diagnosticOutput = regularOutput

        withInterleavedStereoBuffer(samples: &input) { inputList in
            withMutableInterleavedBuffer(
                samples: &regularOutput,
                channelCount: 2
            ) { outputList in
                regular.process(input: inputList, output: outputList)
            }
            withMutableInterleavedBuffer(
                samples: &diagnosticOutput,
                channelCount: 2
            ) { outputList in
                _ = diagnostic.processWithDiagnostics(
                    input: inputList,
                    output: outputList
                )
            }
        }

        XCTAssertEqual(diagnosticOutput, regularOutput)
    }

    func testOrdinarySilenceDoesNotBecomeCallbackStallOrFailure() throws {
        let heartbeat = try AudioCallbackHeartbeat()
        let telemetry = try AudioCallbackTelemetry(capacity: 4)
        heartbeat.recordCallback()
        telemetry.record(
            hostTime: 1,
            metadata: AudioIOCallbackMetadata(
                inputFrameCount: 128,
                outputFrameCount: 128,
                capturedPeak: 0,
                flags: UInt32(VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO)
                    | UInt32(VOLEQ_DIAGNOSTIC_FLAG_OUTPUT_REQUEST_ACTIVE),
                path: 1,
                outcome: 4,
                status: noErr
            )
        )

        let record = try XCTUnwrap(telemetry.drain().records.first)
        XCTAssertEqual(heartbeat.callbackCount, 1)
        XCTAssertEqual(record.processing_outcome, 4)
        XCTAssertEqual(record.processing_status, noErr)
    }

    func testRealtimeRingDropsNewRecordsWhenBoundedCapacityIsFull() throws {
        let telemetry = try AudioCallbackTelemetry(capacity: 2)
        let metadata = AudioIOCallbackMetadata(
            inputFrameCount: 1,
            outputFrameCount: 1,
            capturedPeak: 0.1,
            flags: UInt32(VOLEQ_DIAGNOSTIC_FLAG_OUTPUT_REQUEST_ACTIVE),
            path: 1,
            outcome: 4,
            status: noErr
        )
        for hostTime in UInt64(1)...5 {
            telemetry.record(hostTime: hostTime, metadata: metadata)
        }

        let drained = telemetry.drain()
        XCTAssertEqual(drained.records.map(\.callback_host_time), [1, 2])
        XCTAssertEqual(drained.droppedRecordCount, 3)
        telemetry.record(hostTime: 6, metadata: metadata)
        XCTAssertEqual(telemetry.drain().records.first?.sequence, 6)
    }

    func testReportIsMetadataOnlyAndFinalizesNormalLifecycle() async throws {
        let fixture = try DiagnosticFixture()
        defer { fixture.remove() }
        let diagnostics = try fixture.makeDiagnostics()
        diagnostics.recordLifecycle(activity: "active", captureMode: "Device-wide")
        diagnostics.recordRoute(
            uid: "BuiltInSpeakerDevice",
            sampleRate: 48_000,
            channelCount: 2,
            bufferFrameSize: 512
        )
        diagnostics.recordProcessingFailure(-50)
        diagnostics.recordRecoveryExperimentEvent(
            kind: "confirmedStaleCapture",
            reason: "Metadata-only test evidence."
        )
        diagnostics.ingest(
            [diagnosticRecord(sequence: 1, peak: 0, allZero: true)],
            droppedRecordCount: 0
        )
        diagnostics.finalizeCaptureRun(
            reason: "Audio capture stopped normally.",
            cleanupComplete: true
        )

        let data = try await diagnostics.exportReportData()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        XCTAssertEqual(
            root["diagnosticSessionIdentifier"] as? String,
            "TEST-SESSION"
        )
        XCTAssertFalse(containsForbiddenAudioPayloadKey(root))
        let timeline = try XCTUnwrap(root["timeline"] as? [[String: Any]])
        XCTAssertTrue(timeline.contains {
            $0["kind"] as? String == "captureRunFinalized"
                && $0["cleanupComplete"] as? Bool == true
        })
        XCTAssertTrue(timeline.contains {
            $0["kind"] as? String == "callbackWindow"
        })
        XCTAssertTrue(timeline.contains {
            $0["kind"] as? String == "processingFailure"
                && $0["statusCode"] as? Int == -50
        })
        XCTAssertTrue(timeline.contains {
            $0["kind"] as? String == "confirmedStaleCapture"
        })
    }

    func testTeardownFailureReportContainsExactMetadataButNoAudioPayload() async throws {
        let fixture = try DiagnosticFixture()
        defer { fixture.remove() }
        let diagnostics = try fixture.makeDiagnostics()
        diagnostics.recordTeardownFailure(AudioCaptureTeardownFailure(
            step: .activeOutputListeners,
            statusCode: -5,
            objectID: 42,
            propertySelector: 1_234,
            propertyScope: 5_678,
            propertyElement: 9
        ))

        let data = try await diagnostics.exportReportData()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let timeline = try XCTUnwrap(root["timeline"] as? [[String: Any]])
        let event = try XCTUnwrap(timeline.first {
            $0["kind"] as? String == "audioTeardownFailure"
        })

        XCTAssertEqual(event["statusCode"] as? Int, -5)
        let reason = try XCTUnwrap(event["reason"] as? String)
        XCTAssertTrue(reason.contains("step=activeOutputListeners"))
        XCTAssertTrue(reason.contains("objectID=42"))
        XCTAssertTrue(reason.contains("propertySelector=1234"))
        XCTAssertTrue(reason.contains("propertyScope=5678"))
        XCTAssertTrue(reason.contains("propertyElement=9"))
        XCTAssertFalse(containsForbiddenAudioPayloadKey(root))
    }

    func testCaptureRunFinalizationResetsAllZeroTransitionState() async throws {
        let fixture = try DiagnosticFixture()
        defer { fixture.remove() }
        let diagnostics = try fixture.makeDiagnostics()
        diagnostics.ingest(
            [diagnosticRecord(sequence: 1, peak: 0, allZero: true)],
            droppedRecordCount: 0
        )
        diagnostics.finalizeCaptureRun(
            reason: "First run ended.",
            cleanupComplete: true
        )
        diagnostics.ingest(
            [diagnosticRecord(sequence: 2, peak: 0, allZero: true)],
            droppedRecordCount: 0
        )

        let timeline = try await reportTimeline(from: diagnostics)
        XCTAssertEqual(
            timeline.filter {
                $0["kind"] as? String == "capturedInputBecameAllZero"
            }.count,
            2
        )
    }

    func testJournalStorageRotatesWithinConfiguredBoundAndIgnoresTruncatedTail() async throws {
        let fixture = try DiagnosticFixture()
        defer { fixture.remove() }
        let diagnostics = try fixture.makeDiagnostics(
            segmentCount: 2,
            segmentByteLimit: 8 * 1_024
        )
        for index in 0..<180 {
            diagnostics.recordDiagnosticListenerState(
                reason: "bounded-metadata-event-\(index)"
            )
        }
        _ = try await diagnostics.exportReportData()
        let storedBytes = await diagnostics.storedByteCount()
        XCTAssertLessThanOrEqual(storedBytes, 16 * 1_024)

        let segment = fixture.directory.appendingPathComponent("segment-0.ndjson")
        if FileManager.default.fileExists(atPath: segment.path) {
            let handle = try FileHandle(forWritingTo: segment)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{truncated".utf8))
            try handle.close()
        }
        let report = try await diagnostics.exportReportData()
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: report))
    }

    func testInterruptedPreviousSessionIsRetainedForNextExport() async throws {
        let fixture = try DiagnosticFixture()
        defer { fixture.remove() }
        let interrupted = try fixture.makeDiagnostics(
            sessionIdentifier: "INTERRUPTED-SESSION"
        )
        interrupted.recordLifecycle(
            activity: "active",
            captureMode: "Device-wide"
        )
        _ = try await interrupted.exportReportData()

        let current = try fixture.makeDiagnostics(
            sessionIdentifier: "CURRENT-SESSION"
        )
        let timeline = try await reportTimeline(from: current)
        let sessionIdentifiers = Set(timeline.compactMap {
            $0["sessionIdentifier"] as? String
        })

        XCTAssertTrue(sessionIdentifiers.contains("INTERRUPTED-SESSION"))
        XCTAssertTrue(sessionIdentifiers.contains("CURRENT-SESSION"))
        XCTAssertFalse(timeline.contains {
            $0["sessionIdentifier"] as? String == "INTERRUPTED-SESSION"
                && $0["kind"] as? String == "diagnosticSessionFinalized"
        })
    }

    @available(macOS 14.2, *)
    func testVolumeListenersAreOptionalIndependentAndCleanedUp() async throws {
        let fixture = try DiagnosticFixture()
        defer { fixture.remove() }
        let diagnostics = try fixture.makeDiagnostics()
        let removals = LockedCounter()
        let operations = AudioOutputControlDiagnosticsOperations(
            hasProperty: { _, _ in true },
            addListener: { _, _, _, _ in noErr },
            removeListener: { _, _, _, _ in
                removals.increment()
                return noErr
            },
            readFloat: { _, _ in 0.5 },
            readUInt32: { _, address in
                address.mSelector == kAudioDevicePropertyBufferFrameSize
                    ? 512
                    : 0
            }
        )
        let observer = AudioOutputControlDiagnosticsObserver(
            deviceID: 42,
            diagnostics: diagnostics,
            operations: operations
        )

        observer.start()
        observer.stop()
        let report = try await diagnostics.exportReportData()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: report) as? [String: Any]
        )
        let timeline = try XCTUnwrap(root["timeline"] as? [[String: Any]])

        XCTAssertEqual(removals.value, 3)
        XCTAssertTrue(timeline.contains {
            $0["kind"] as? String == "systemVolumeChange"
        })
        XCTAssertTrue(timeline.contains {
            $0["kind"] as? String == "outputBufferSizeChange"
        })
        XCTAssertFalse(timeline.contains {
            $0["kind"] as? String == "outputRouteChangeDetected"
        })
    }

    @available(macOS 14.2, *)
    func testVolumeListenerRemovalFailureReportsExactPropertyAndNeverSignalsRouteRecovery() async throws {
        let fixture = try DiagnosticFixture()
        defer { fixture.remove() }
        let diagnostics = try fixture.makeDiagnostics()
        let operations = AudioOutputControlDiagnosticsOperations(
            hasProperty: { _, _ in true },
            addListener: { _, _, _, _ in noErr },
            removeListener: { _, address, _, _ in
                address.mSelector == kAudioDevicePropertyMute ? -77 : noErr
            },
            readFloat: { _, _ in 0.5 },
            readUInt32: { _, _ in 0 }
        )
        let observer = AudioOutputControlDiagnosticsObserver(
            deviceID: 42,
            diagnostics: diagnostics,
            operations: operations
        )

        observer.start()
        observer.stop()
        let timeline = try await reportTimeline(from: diagnostics)
        let failure = try XCTUnwrap(timeline.first {
            ($0["reason"] as? String)?.contains("OSStatus=-77") == true
        })

        XCTAssertEqual(failure["kind"] as? String, "diagnosticListenerState")
        XCTAssertTrue(
            (failure["reason"] as? String)?.contains("deviceID=42") == true
        )
        XCTAssertTrue(
            (failure["reason"] as? String)?.contains(
                "propertySelector=\(kAudioDevicePropertyMute)"
            ) == true
        )
        XCTAssertFalse(timeline.contains {
            $0["kind"] as? String == "outputRouteChangeDetected"
        })
    }

    @MainActor
    @available(macOS 14.2, *)
    func testControllerStartStopFinalizesCaptureRunAfterCleanup() async throws {
        let fixture = try DiagnosticFixture()
        defer { fixture.remove() }
        let diagnostics = try fixture.makeDiagnostics()
        let rig = AudioCaptureTestRig()
        let controller = AudioCaptureController(
            dependencies: rig.makeDependencies(),
            diagnostics: diagnostics
        )
        controller.mode = .system

        controller.start()
        await waitForRuntimeState(controller, .active)
        await controller.stopAndWait()

        let timeline = try await reportTimeline(from: diagnostics)
        XCTAssertTrue(timeline.contains {
            $0["kind"] as? String == "captureRunFinalized"
                && $0["cleanupComplete"] as? Bool == true
        })
    }

    @MainActor
    @available(macOS 14.2, *)
    func testCleanupFailureFinalizesCaptureRunAsIncomplete() async throws {
        let fixture = try DiagnosticFixture()
        defer { fixture.remove() }
        let diagnostics = try fixture.makeDiagnostics()
        let rig = AudioCaptureTestRig()
        rig.pipelines.make = {
            let pipeline = try TestCapturePipeline()
            pipeline.teardownReport = AudioCaptureTeardownReport(
                unresolvedSteps: [.destroyTap]
            )
            return pipeline
        }
        let controller = AudioCaptureController(
            dependencies: rig.makeDependencies(),
            diagnostics: diagnostics
        )
        controller.mode = .system

        controller.start()
        await waitForRuntimeState(controller, .active)
        await controller.stopAndWait()

        let timeline = try await reportTimeline(from: diagnostics)
        XCTAssertTrue(timeline.contains {
            $0["kind"] as? String == "captureRunFinalized"
                && $0["cleanupComplete"] as? Bool == false
        })
    }

    @MainActor
    @available(macOS 14.2, *)
    func testListenerOnlyCleanupFinalizesAsIncompleteWithoutBlockingStop() async throws {
        let fixture = try DiagnosticFixture()
        defer { fixture.remove() }
        let diagnostics = try fixture.makeDiagnostics()
        let rig = AudioCaptureTestRig()
        rig.pipelines.make = {
            let pipeline = try TestCapturePipeline()
            pipeline.teardownReport = AudioCaptureTeardownReport(
                unresolvedSteps: [.activeOutputListeners]
            )
            return pipeline
        }
        let controller = AudioCaptureController(
            dependencies: rig.makeDependencies(),
            diagnostics: diagnostics
        )
        controller.mode = .system

        controller.start()
        await waitForRuntimeState(controller, .active)
        await controller.stopAndWait()

        XCTAssertEqual(controller.runtimeState, .stopped)
        let timeline = try await reportTimeline(from: diagnostics)
        XCTAssertTrue(timeline.contains {
            $0["kind"] as? String == "captureRunFinalized"
                && $0["cleanupComplete"] as? Bool == false
                && ($0["reason"] as? String)?.contains("quarantined") == true
        })
    }

    private func diagnosticRecord(
        sequence: UInt64,
        peak: Float,
        allZero: Bool
    ) -> VolEqRealtimeDiagnosticRecord {
        var record = VolEqRealtimeDiagnosticRecord()
        record.sequence = sequence
        record.callback_host_time = sequence * 100
        record.captured_frame_count = 512
        record.requested_output_frame_count = 512
        record.captured_peak = peak
        record.flags = UInt32(VOLEQ_DIAGNOSTIC_FLAG_OUTPUT_REQUEST_ACTIVE)
        if allZero {
            record.flags |= UInt32(VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO)
            record.zero_run_length = 1
        }
        record.processing_path = 1
        record.processing_outcome = 4
        return record
    }

    private func containsForbiddenAudioPayloadKey(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            let forbidden = Set([
                "samples", "audioSamples", "pcm", "bufferData",
                "processName", "processNames", "url", "urls",
                "mediaTitle", "mediaTitles",
            ])
            if !forbidden.isDisjoint(with: dictionary.keys) { return true }
            return dictionary.values.contains(where: containsForbiddenAudioPayloadKey)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsForbiddenAudioPayloadKey)
        }
        return false
    }

    private func reportTimeline(
        from diagnostics: AudioLivenessDiagnostics
    ) async throws -> [[String: Any]] {
        let report = try await diagnostics.exportReportData()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: report) as? [String: Any]
        )
        return try XCTUnwrap(root["timeline"] as? [[String: Any]])
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.withLock { storage += 1 }
    }

    var value: Int { lock.withLock { storage } }
}

private final class MutableDiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var uptime: UInt64 = 10_000

    var diagnosticClock: DiagnosticClock {
        DiagnosticClock(
            wallClock: { [self] in lock.withLock { date } },
            uptimeNanoseconds: { [self] in
                lock.withLock {
                    uptime &+= 1_000_000_000
                    return uptime
                }
            }
        )
    }
}

private struct DiagnosticFixture {
    let directory: URL
    let clock = MutableDiagnosticClock()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func makeDiagnostics(
        sessionIdentifier: String = "TEST-SESSION",
        segmentCount: Int = 4,
        segmentByteLimit: Int = 4 * 1_024 * 1_024
    ) throws -> AudioLivenessDiagnostics {
        try AudioLivenessDiagnostics(
            storageDirectoryURL: directory,
            environment: AudioLivenessDiagnosticEnvironment(
                macOSVersion: "macOS Test",
                hardwareModel: "TestMac1,1",
                applicationVersion: "0.1.1",
                applicationBuild: "2",
                diagnosticVariant: "audio-liveness",
                sourceCommit: "ee6cde5"
            ),
            sessionIdentifier: sessionIdentifier,
            clock: clock.diagnosticClock,
            journalSegmentCount: segmentCount,
            journalSegmentByteLimit: segmentByteLimit
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
