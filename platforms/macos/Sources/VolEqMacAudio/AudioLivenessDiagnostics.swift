// SPDX-License-Identifier: MPL-2.0

import CVolEqRealtime
import AudioToolbox
import Foundation

public struct AudioLivenessDiagnosticEnvironment: Codable, Equatable, Sendable {
    public let macOSVersion: String
    public let hardwareModel: String
    public let applicationVersion: String
    public let applicationBuild: String
    public let diagnosticVariant: String
    public let sourceCommit: String

    public init(
        macOSVersion: String,
        hardwareModel: String,
        applicationVersion: String,
        applicationBuild: String,
        diagnosticVariant: String,
        sourceCommit: String
    ) {
        self.macOSVersion = macOSVersion
        self.hardwareModel = hardwareModel
        self.applicationVersion = applicationVersion
        self.applicationBuild = applicationBuild
        self.diagnosticVariant = diagnosticVariant
        self.sourceCommit = sourceCommit
    }
}

public enum AudioLivenessDiagnosticError: LocalizedError {
    case invalidStorageDirectory
    case oversizedRecord

    public var errorDescription: String? {
        switch self {
        case .invalidStorageDirectory:
            "VolEq could not prepare its bounded diagnostic storage."
        case .oversizedRecord:
            "VolEq refused an unexpectedly large diagnostic metadata record."
        }
    }
}

private struct DiagnosticJournalManifest: Codable {
    var currentSegment: Int
    var nextSequence: UInt64
}

private struct DiagnosticCallbackWindow: Codable, Equatable {
    let callbackCount: UInt64
    let firstCallbackSequence: UInt64
    let lastCallbackSequence: UInt64
    let firstHostTime: UInt64?
    let lastHostTime: UInt64?
    let minimumCallbackIntervalNanoseconds: UInt64?
    let maximumCallbackIntervalNanoseconds: UInt64?
    let capturedFrameCountMinimum: UInt32
    let capturedFrameCountMaximum: UInt32
    let capturedFrameCountTotal: UInt64
    let requestedOutputFrameCountMinimum: UInt32
    let requestedOutputFrameCountMaximum: UInt32
    let requestedOutputFrameCountTotal: UInt64
    let allZeroCallbackCount: UInt64
    let noCapturedFrameCallbackCount: UInt64
    let partialDeliveryCallbackCount: UInt64
    let nonfiniteInputCallbackCount: UInt64
    let outputActiveWhileInputUnusableCallbackCount: UInt64
    let maximumConsecutiveAllZeroCallbacks: UInt32
    let maximumConsecutivePartialCallbacks: UInt32
    let maximumCapturedPeak: Float
    let processingPaths: [String: UInt64]
    let processingOutcomes: [String: UInt64]
    let processingFailureStatuses: [Int32]
    let droppedCallbackRecordCount: UInt64
}

private struct DiagnosticJournalEntry: Codable, Equatable {
    let schemaVersion: Int
    let sequence: UInt64
    let sessionIdentifier: String
    let wallClock: String
    let uptimeNanoseconds: UInt64
    let kind: String
    let captureMode: String?
    let lifecycleActivity: String?
    let routeUID: String?
    let sampleRate: Double?
    let channelCount: UInt32?
    let bufferFrameSize: UInt32?
    let volumeScalar: Float?
    let muted: Bool?
    let statusCode: Int32?
    let cleanupComplete: Bool?
    let reason: String?
    let callbackWindow: DiagnosticCallbackWindow?
    let environment: AudioLivenessDiagnosticEnvironment?
}

private struct AudioLivenessDiagnosticReport: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let diagnosticSessionIdentifier: String
    let environment: AudioLivenessDiagnosticEnvironment
    let privacy: String
    let transitionSummary: [String]
    let timeline: [DiagnosticJournalEntry]
}

struct DiagnosticClock: Sendable {
    let wallClock: @Sendable () -> Date
    let uptimeNanoseconds: @Sendable () -> UInt64

    static let live = DiagnosticClock(
        wallClock: { Date() },
        uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds }
    )
}

struct AudioLivenessObservation: Equatable, Sendable {
    let callbackSequence: UInt64
    let capturedFrameCount: UInt32
    let requestedOutputFrameCount: UInt32
    let capturedPeak: Float
    let allZero: Bool
    let noCapturedFrames: Bool
    let partialDelivery: Bool
    let nonfiniteInput: Bool
    let outputRequestActive: Bool
    let consecutiveAllZeroCallbacks: UInt32

    init(
        callbackSequence: UInt64,
        capturedFrameCount: UInt32,
        requestedOutputFrameCount: UInt32,
        capturedPeak: Float,
        allZero: Bool,
        noCapturedFrames: Bool,
        partialDelivery: Bool,
        nonfiniteInput: Bool,
        outputRequestActive: Bool,
        consecutiveAllZeroCallbacks: UInt32
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
        self.consecutiveAllZeroCallbacks = consecutiveAllZeroCallbacks
    }

    init(_ record: VolEqRealtimeDiagnosticRecord) {
        callbackSequence = record.sequence
        capturedFrameCount = record.captured_frame_count
        requestedOutputFrameCount = record.requested_output_frame_count
        capturedPeak = record.captured_peak
        allZero = record.flags & UInt32(VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO) != 0
        noCapturedFrames = record.flags
            & UInt32(VOLEQ_DIAGNOSTIC_FLAG_NO_CAPTURED_FRAMES) != 0
        partialDelivery = record.flags
            & UInt32(VOLEQ_DIAGNOSTIC_FLAG_PARTIAL_DELIVERY) != 0
        nonfiniteInput = record.flags
            & UInt32(VOLEQ_DIAGNOSTIC_FLAG_NONFINITE_INPUT) != 0
        outputRequestActive = record.flags
            & UInt32(VOLEQ_DIAGNOSTIC_FLAG_OUTPUT_REQUEST_ACTIVE) != 0
        consecutiveAllZeroCallbacks = record.zero_run_length
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
}

protocol AudioLivenessDiagnosticsRecording: AnyObject, Sendable {
    func recordLifecycle(activity: String, captureMode: String)
    func recordRoute(
        uid: String,
        sampleRate: Double,
        channelCount: UInt32,
        bufferFrameSize: UInt32?
    )
    func recordVolumeChange(volumeScalar: Float?, muted: Bool?)
    func recordBufferSizeChange(_ bufferFrameSize: UInt32?)
    func recordRouteChangeDetected()
    func recordProcessingFailure(_ statusCode: Int32)
    func recordDiagnosticListenerState(
        reason: String,
        cleanupComplete: Bool?
    )
    func recordRecoveryExperimentEvent(kind: String, reason: String?)
    func ingest(
        _ records: [VolEqRealtimeDiagnosticRecord],
        droppedRecordCount: UInt64
    )
    func finalizeCaptureRun(reason: String, cleanupComplete: Bool)
}

private final class BoundedDiagnosticJournal: @unchecked Sendable {
    static let segmentCount = 4
    static let segmentByteLimit = 4 * 1_024 * 1_024
    static let recordByteLimit = 8 * 1_024

    private let directoryURL: URL
    private let manifestURL: URL
    private let configuredSegmentCount: Int
    private let configuredSegmentByteLimit: Int
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var manifest: DiagnosticJournalManifest

    init(
        directoryURL: URL,
        segmentCount: Int = BoundedDiagnosticJournal.segmentCount,
        segmentByteLimit: Int = BoundedDiagnosticJournal.segmentByteLimit
    ) throws {
        guard directoryURL.isFileURL else {
            throw AudioLivenessDiagnosticError.invalidStorageDirectory
        }
        precondition(segmentCount > 0)
        precondition(segmentByteLimit >= Self.recordByteLimit)
        self.directoryURL = directoryURL
        configuredSegmentCount = segmentCount
        configuredSegmentByteLimit = segmentByteLimit
        manifestURL = directoryURL.appendingPathComponent("manifest.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let scanned = Self.latestEntry(
            in: directoryURL,
            decoder: decoder,
            segmentCount: segmentCount
        )
        let nextScannedSequence = scanned.sequence == UInt64.max
            ? UInt64.max
            : scanned.sequence + 1
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? decoder.decode(
               DiagnosticJournalManifest.self,
               from: data
           ),
           (0..<segmentCount).contains(decoded.currentSegment) {
            manifest = DiagnosticJournalManifest(
                currentSegment: scanned.sequence >= decoded.nextSequence
                    ? (scanned.segment ?? decoded.currentSegment)
                    : decoded.currentSegment,
                nextSequence: max(decoded.nextSequence, nextScannedSequence)
            )
        } else {
            manifest = DiagnosticJournalManifest(
                currentSegment: scanned.segment ?? 0,
                nextSequence: nextScannedSequence
            )
        }
    }

    func append(_ makeEntry: (UInt64) -> DiagnosticJournalEntry) throws {
        let entry = makeEntry(manifest.nextSequence)
        var data = try encoder.encode(entry)
        data.append(0x0A)
        guard data.count <= Self.recordByteLimit else {
            throw AudioLivenessDiagnosticError.oversizedRecord
        }

        var segmentURL = url(for: manifest.currentSegment)
        let currentSize = (try? segmentURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
        if currentSize + data.count > configuredSegmentByteLimit {
            manifest.currentSegment = (manifest.currentSegment + 1)
                % configuredSegmentCount
            segmentURL = url(for: manifest.currentSegment)
            try Data().write(to: segmentURL, options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: segmentURL.path) {
            FileManager.default.createFile(
                atPath: segmentURL.path,
                contents: nil
            )
        }
        let handle = try FileHandle(forWritingTo: segmentURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()

        manifest.nextSequence &+= 1
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
    }

    func readAll() -> [DiagnosticJournalEntry] {
        var entries: [DiagnosticJournalEntry] = []
        for index in 0..<configuredSegmentCount {
            guard let data = try? Data(contentsOf: url(for: index)),
                  !data.isEmpty
            else { continue }
            for line in data.split(separator: 0x0A) {
                if let entry = try? decoder.decode(
                    DiagnosticJournalEntry.self,
                    from: Data(line)
                ) {
                    entries.append(entry)
                }
            }
        }
        return entries.sorted { $0.sequence < $1.sequence }
    }

    func clear() throws {
        for index in 0..<configuredSegmentCount {
            let segmentURL = url(for: index)
            if FileManager.default.fileExists(atPath: segmentURL.path) {
                try FileManager.default.removeItem(at: segmentURL)
            }
        }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            try FileManager.default.removeItem(at: manifestURL)
        }
        manifest = DiagnosticJournalManifest(currentSegment: 0, nextSequence: 1)
    }

    var storedByteCount: Int {
        (0..<configuredSegmentCount).reduce(0) { total, index in
            total + ((try? url(for: index).resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize) ?? 0)
        }
    }

    private func url(for index: Int) -> URL {
        directoryURL.appendingPathComponent("segment-\(index).ndjson")
    }

    private static func latestEntry(
        in directoryURL: URL,
        decoder: JSONDecoder,
        segmentCount: Int
    ) -> (sequence: UInt64, segment: Int?) {
        var highest: UInt64 = 0
        var highestSegment: Int?
        for index in 0..<segmentCount {
            let url = directoryURL.appendingPathComponent(
                "segment-\(index).ndjson"
            )
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) {
                if let entry = try? decoder.decode(
                    DiagnosticJournalEntry.self,
                    from: Data(line)
                ) {
                    if highestSegment == nil || entry.sequence > highest {
                        highest = entry.sequence
                        highestSegment = index
                    }
                }
            }
        }
        return (highest, highestSegment)
    }
}

private struct CallbackWindowAccumulator {
    private(set) var callbackCount: UInt64 = 0
    private var firstSequence: UInt64 = 0
    private var lastSequence: UInt64 = 0
    private var firstHostTime: UInt64?
    private var lastHostTime: UInt64?
    private var minimumHostDelta: UInt64?
    private var maximumHostDelta: UInt64?
    private var capturedMinimum = UInt32.max
    private var capturedMaximum: UInt32 = 0
    private var capturedTotal: UInt64 = 0
    private var outputMinimum = UInt32.max
    private var outputMaximum: UInt32 = 0
    private var outputTotal: UInt64 = 0
    private var allZeroCount: UInt64 = 0
    private var noCapturedFramesCount: UInt64 = 0
    private var partialCount: UInt64 = 0
    private var nonfiniteCount: UInt64 = 0
    private var outputActiveWhileUnusableCount: UInt64 = 0
    private var maximumZeroRun: UInt32 = 0
    private var maximumPartialRun: UInt32 = 0
    private var maximumPeak: Float = 0
    private var paths: [String: UInt64] = [:]
    private var outcomes: [String: UInt64] = [:]
    private var failureStatuses: [Int32] = []
    private var droppedCount: UInt64 = 0

    mutating func include(
        _ record: VolEqRealtimeDiagnosticRecord,
        droppedRecordCount: UInt64
    ) {
        if callbackCount == 0 {
            firstSequence = record.sequence
            firstHostTime = record.callback_host_time == 0
                ? nil
                : record.callback_host_time
        }
        callbackCount &+= 1
        lastSequence = record.sequence
        if record.callback_host_time != 0 {
            if let previous = lastHostTime,
               record.callback_host_time > previous {
                let delta = AudioConvertHostTimeToNanos(
                    record.callback_host_time - previous
                )
                minimumHostDelta = min(minimumHostDelta ?? delta, delta)
                maximumHostDelta = max(maximumHostDelta ?? delta, delta)
            }
            lastHostTime = record.callback_host_time
        }
        capturedMinimum = min(capturedMinimum, record.captured_frame_count)
        capturedMaximum = max(capturedMaximum, record.captured_frame_count)
        capturedTotal &+= UInt64(record.captured_frame_count)
        outputMinimum = min(outputMinimum, record.requested_output_frame_count)
        outputMaximum = max(outputMaximum, record.requested_output_frame_count)
        outputTotal &+= UInt64(record.requested_output_frame_count)
        let allZero = record.flags & UInt32(VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO) != 0
        let noFrames = record.flags
            & UInt32(VOLEQ_DIAGNOSTIC_FLAG_NO_CAPTURED_FRAMES) != 0
        let partial = record.flags
            & UInt32(VOLEQ_DIAGNOSTIC_FLAG_PARTIAL_DELIVERY) != 0
        let nonfinite = record.flags
            & UInt32(VOLEQ_DIAGNOSTIC_FLAG_NONFINITE_INPUT) != 0
        let outputActive = record.flags
            & UInt32(VOLEQ_DIAGNOSTIC_FLAG_OUTPUT_REQUEST_ACTIVE) != 0
        if allZero { allZeroCount &+= 1 }
        if noFrames { noCapturedFramesCount &+= 1 }
        if partial { partialCount &+= 1 }
        if nonfinite { nonfiniteCount &+= 1 }
        if outputActive && (allZero || noFrames) {
            outputActiveWhileUnusableCount &+= 1
        }
        maximumZeroRun = max(maximumZeroRun, record.zero_run_length)
        maximumPartialRun = max(maximumPartialRun, record.partial_run_length)
        if record.captured_peak.isFinite {
            maximumPeak = max(maximumPeak, record.captured_peak)
        }
        paths[Self.pathName(record.processing_path), default: 0] &+= 1
        outcomes[Self.outcomeName(record.processing_outcome), default: 0] &+= 1
        if record.processing_status != 0,
           !failureStatuses.contains(record.processing_status),
           failureStatuses.count < 16 {
            failureStatuses.append(record.processing_status)
        }
        droppedCount = droppedRecordCount
    }

    func snapshot() -> DiagnosticCallbackWindow? {
        guard callbackCount > 0 else { return nil }
        return DiagnosticCallbackWindow(
            callbackCount: callbackCount,
            firstCallbackSequence: firstSequence,
            lastCallbackSequence: lastSequence,
            firstHostTime: firstHostTime,
            lastHostTime: lastHostTime,
            minimumCallbackIntervalNanoseconds: minimumHostDelta,
            maximumCallbackIntervalNanoseconds: maximumHostDelta,
            capturedFrameCountMinimum: capturedMinimum,
            capturedFrameCountMaximum: capturedMaximum,
            capturedFrameCountTotal: capturedTotal,
            requestedOutputFrameCountMinimum: outputMinimum,
            requestedOutputFrameCountMaximum: outputMaximum,
            requestedOutputFrameCountTotal: outputTotal,
            allZeroCallbackCount: allZeroCount,
            noCapturedFrameCallbackCount: noCapturedFramesCount,
            partialDeliveryCallbackCount: partialCount,
            nonfiniteInputCallbackCount: nonfiniteCount,
            outputActiveWhileInputUnusableCallbackCount: outputActiveWhileUnusableCount,
            maximumConsecutiveAllZeroCallbacks: maximumZeroRun,
            maximumConsecutivePartialCallbacks: maximumPartialRun,
            maximumCapturedPeak: maximumPeak,
            processingPaths: paths,
            processingOutcomes: outcomes,
            processingFailureStatuses: failureStatuses,
            droppedCallbackRecordCount: droppedCount
        )
    }

    private static func pathName(_ value: UInt32) -> String {
        switch value {
        case 1: "directAggregateClock"
        case 2: "sampleRateConverter"
        default: "unresolved"
        }
    }

    private static func outcomeName(_ value: UInt32) -> String {
        switch value {
        case 1: "noOutputRequested"
        case 2: "clearedNoCapturedFrames"
        case 3: "clearedWhileResolvingTiming"
        case 4: "processed"
        case 5: "processingFailure"
        default: "unknown"
        }
    }
}

public final class AudioLivenessDiagnostics: @unchecked Sendable {
    public static let storageDirectoryName = "Audio Liveness Diagnostics"

    public let sessionIdentifier: String
    public let environment: AudioLivenessDiagnosticEnvironment

    private let queue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.diagnostics.audio-liveness",
        qos: .utility
    )
    private let clock: DiagnosticClock
    private let journal: BoundedDiagnosticJournal
    private var accumulator = CallbackWindowAccumulator()
    private var windowStartedAt: UInt64
    private var previousAllZero = false
    private var previousPartial = false
    private var lastDroppedRecordCount: UInt64 = 0
    private let encoder: JSONEncoder
    private let dateFormatter: ISO8601DateFormatter

    public convenience init(
        storageDirectoryURL: URL,
        environment: AudioLivenessDiagnosticEnvironment
    ) throws {
        try self.init(
            storageDirectoryURL: storageDirectoryURL,
            environment: environment,
            sessionIdentifier: UUID().uuidString,
            clock: .live
        )
    }

    init(
        storageDirectoryURL: URL,
        environment: AudioLivenessDiagnosticEnvironment,
        sessionIdentifier: String,
        clock: DiagnosticClock,
        journalSegmentCount: Int = BoundedDiagnosticJournal.segmentCount,
        journalSegmentByteLimit: Int = BoundedDiagnosticJournal.segmentByteLimit
    ) throws {
        self.environment = environment
        self.sessionIdentifier = sessionIdentifier
        self.clock = clock
        journal = try BoundedDiagnosticJournal(
            directoryURL: storageDirectoryURL,
            segmentCount: journalSegmentCount,
            segmentByteLimit: journalSegmentByteLimit
        )
        windowStartedAt = clock.uptimeNanoseconds()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        append(kind: "diagnosticSessionStarted", environment: environment)
    }

    public func recordLifecycle(activity: String, captureMode: String) {
        queue.async { [self] in
            append(
                kind: "lifecycleTransition",
                captureMode: captureMode,
                lifecycleActivity: activity
            )
        }
    }

    public func recordRoute(
        uid: String,
        sampleRate: Double,
        channelCount: UInt32,
        bufferFrameSize: UInt32?
    ) {
        queue.async { [self] in
            append(
                kind: "outputRoute",
                routeUID: uid,
                sampleRate: sampleRate,
                channelCount: channelCount,
                bufferFrameSize: bufferFrameSize
            )
        }
    }

    public func recordVolumeChange(volumeScalar: Float?, muted: Bool?) {
        queue.async { [self] in
            append(
                kind: "systemVolumeChange",
                volumeScalar: volumeScalar,
                muted: muted
            )
        }
    }

    public func recordBufferSizeChange(_ bufferFrameSize: UInt32?) {
        queue.async { [self] in
            append(
                kind: "outputBufferSizeChange",
                bufferFrameSize: bufferFrameSize
            )
        }
    }

    public func recordRouteChangeDetected() {
        queue.async { [self] in
            append(kind: "outputRouteChangeDetected")
        }
    }

    public func recordProcessingFailure(_ statusCode: Int32) {
        queue.async { [self] in
            append(kind: "processingFailure", statusCode: statusCode)
        }
    }

    public func recordDiagnosticListenerState(
        reason: String,
        cleanupComplete: Bool? = nil
    ) {
        queue.async { [self] in
            append(
                kind: "diagnosticListenerState",
                cleanupComplete: cleanupComplete,
                reason: reason
            )
        }
    }

    public func recordRecoveryExperimentEvent(
        kind: String,
        reason: String? = nil
    ) {
        queue.async { [self] in
            append(kind: kind, reason: reason)
        }
    }

    func ingest(
        _ records: [VolEqRealtimeDiagnosticRecord],
        droppedRecordCount: UInt64
    ) {
        queue.async { [self] in
            guard !records.isEmpty
                    || droppedRecordCount != lastDroppedRecordCount
            else { return }
            for record in records {
                let isAllZero = record.flags
                    & UInt32(VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO) != 0
                let isPartial = record.flags
                    & UInt32(VOLEQ_DIAGNOSTIC_FLAG_PARTIAL_DELIVERY) != 0
                if isAllZero != previousAllZero {
                    append(kind: isAllZero
                        ? "capturedInputBecameAllZero"
                        : "capturedInputResumedNonzero")
                    previousAllZero = isAllZero
                }
                if isPartial != previousPartial {
                    append(kind: isPartial
                        ? "partialInputDeliveryBegan"
                        : "partialInputDeliveryEnded")
                    previousPartial = isPartial
                }
                accumulator.include(
                    record,
                    droppedRecordCount: droppedRecordCount
                )
            }
            lastDroppedRecordCount = droppedRecordCount
            let now = clock.uptimeNanoseconds()
            if now >= windowStartedAt,
               now - windowStartedAt >= 1_000_000_000 {
                flushCallbackWindow()
                windowStartedAt = now
            }
        }
    }

    public func finalize(reason: String, cleanupComplete: Bool) {
        finalize(
            kind: "diagnosticSessionFinalized",
            reason: reason,
            cleanupComplete: cleanupComplete
        )
    }

    public func finalizeAndWait(
        reason: String,
        cleanupComplete: Bool
    ) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                flushCallbackWindow()
                append(
                    kind: "diagnosticSessionFinalized",
                    cleanupComplete: cleanupComplete,
                    reason: reason
                )
                continuation.resume()
            }
        }
    }

    public func finalizeCaptureRun(reason: String, cleanupComplete: Bool) {
        queue.async { [self] in
            flushCallbackWindow()
            append(
                kind: "captureRunFinalized",
                cleanupComplete: cleanupComplete,
                reason: reason
            )
            previousAllZero = false
            previousPartial = false
            lastDroppedRecordCount = 0
            windowStartedAt = clock.uptimeNanoseconds()
        }
    }

    private func finalize(
        kind: String,
        reason: String,
        cleanupComplete: Bool
    ) {
        queue.async { [self] in
            flushCallbackWindow()
            append(
                kind: kind,
                cleanupComplete: cleanupComplete,
                reason: reason
            )
        }
    }

    public func exportReportData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    flushCallbackWindow()
                    let timeline = journal.readAll()
                    let report = AudioLivenessDiagnosticReport(
                        schemaVersion: 1,
                        generatedAt: timestamp(),
                        diagnosticSessionIdentifier: sessionIdentifier,
                        environment: environment,
                        privacy: "Metadata only. No captured audio samples are recorded, retained, uploaded, or reconstructable from this report.",
                        transitionSummary: transitionSummary(for: timeline),
                        timeline: timeline
                    )
                    continuation.resume(returning: try encoder.encode(report))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func clearStoredData() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try journal.clear()
                    accumulator = CallbackWindowAccumulator()
                    previousAllZero = false
                    previousPartial = false
                    lastDroppedRecordCount = 0
                    windowStartedAt = clock.uptimeNanoseconds()
                    append(kind: "diagnosticHistoryCleared", environment: environment)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func storedByteCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [journal] in
                continuation.resume(returning: journal.storedByteCount)
            }
        }
    }

    private func flushCallbackWindow() {
        guard let snapshot = accumulator.snapshot() else { return }
        append(kind: "callbackWindow", callbackWindow: snapshot)
        accumulator = CallbackWindowAccumulator()
    }

    private func transitionSummary(
        for timeline: [DiagnosticJournalEntry]
    ) -> [String] {
        var summary: [String] = []
        let zeroStarts = timeline.filter {
            $0.kind == "capturedInputBecameAllZero"
        }
        let resumptions = timeline.filter {
            $0.kind == "capturedInputResumedNonzero"
        }
        let volumeChanges = timeline.filter {
            $0.kind == "systemVolumeChange"
        }
        let callbackWindows = timeline.compactMap(\.callbackWindow)
        let activeUnusable = callbackWindows.reduce(UInt64(0)) {
            $0 &+ $1.outputActiveWhileInputUnusableCallbackCount
        }
        if let first = zeroStarts.first {
            summary.append(
                "Captured input first became all zero at \(first.wallClock) while callback telemetry continued."
            )
        } else {
            summary.append("No all-zero captured-input transition was retained.")
        }
        summary.append(
            "Retained \(zeroStarts.count) all-zero transition(s), \(resumptions.count) nonzero resumption(s), and \(volumeChanges.count) system volume event(s)."
        )
        summary.append(
            "Output requests remained active during \(activeUnusable) retained callback(s) with all-zero or missing captured input. This is diagnostic metadata, not an automatic failure decision."
        )
        return summary
    }

    private func append(
        kind: String,
        captureMode: String? = nil,
        lifecycleActivity: String? = nil,
        routeUID: String? = nil,
        sampleRate: Double? = nil,
        channelCount: UInt32? = nil,
        bufferFrameSize: UInt32? = nil,
        volumeScalar: Float? = nil,
        muted: Bool? = nil,
        statusCode: Int32? = nil,
        cleanupComplete: Bool? = nil,
        reason: String? = nil,
        callbackWindow: DiagnosticCallbackWindow? = nil,
        environment: AudioLivenessDiagnosticEnvironment? = nil
    ) {
        try? journal.append { sequence in
            DiagnosticJournalEntry(
                schemaVersion: 1,
                sequence: sequence,
                sessionIdentifier: sessionIdentifier,
                wallClock: timestamp(),
                uptimeNanoseconds: clock.uptimeNanoseconds(),
                kind: kind,
                captureMode: captureMode,
                lifecycleActivity: lifecycleActivity,
                routeUID: routeUID,
                sampleRate: sampleRate,
                channelCount: channelCount,
                bufferFrameSize: bufferFrameSize,
                volumeScalar: volumeScalar,
                muted: muted,
                statusCode: statusCode,
                cleanupComplete: cleanupComplete,
                reason: reason,
                callbackWindow: callbackWindow,
                environment: environment
            )
        }
    }

    private func timestamp() -> String {
        dateFormatter.string(from: clock.wallClock())
    }
}

extension AudioLivenessDiagnostics: AudioLivenessDiagnosticsRecording {}

final class AudioCallbackTelemetry: @unchecked Sendable {
    private let state: OpaquePointer
    private let drainCapacity: Int
    private let drainBuffer: UnsafeMutablePointer<VolEqRealtimeDiagnosticRecord>

    init(capacity: Int = 4_096) throws {
        guard capacity >= 2,
              let state = voleq_realtime_diagnostic_state_create(capacity)
        else {
            throw VolEqError.missingValue(
                "VolEq could not allocate its bounded audio diagnostic state."
            )
        }
        self.state = state
        drainCapacity = capacity
        drainBuffer = .allocate(capacity: capacity)
    }

    deinit {
        voleq_realtime_diagnostic_state_destroy(state)
        drainBuffer.deallocate()
    }

    @inline(__always)
    func record(
        hostTime: UInt64,
        metadata: AudioIOCallbackMetadata
    ) {
        voleq_realtime_diagnostic_state_record(
            state,
            hostTime,
            UInt32(clamping: metadata.inputFrameCount),
            UInt32(clamping: metadata.outputFrameCount),
            metadata.capturedPeak,
            metadata.flags,
            metadata.path,
            metadata.outcome,
            metadata.status
        )
    }

    func drain() -> (
        records: [VolEqRealtimeDiagnosticRecord],
        droppedRecordCount: UInt64
    ) {
        let count = voleq_realtime_diagnostic_state_read(
            state,
            drainBuffer,
            drainCapacity
        )
        let records = Array(UnsafeBufferPointer(
            start: drainBuffer,
            count: Int(count)
        ))
        return (
            records,
            voleq_realtime_diagnostic_state_dropped_record_count(state)
        )
    }

    var isFaultInjectionEnabled: Bool {
        voleq_realtime_diagnostic_state_fault_injection_enabled(state)
    }

    func setFaultInjectionEnabled(_ enabled: Bool) {
        voleq_realtime_diagnostic_state_set_fault_injection_enabled(
            state,
            enabled
        )
    }
}
