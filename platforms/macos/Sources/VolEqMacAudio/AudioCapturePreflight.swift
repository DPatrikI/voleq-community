// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation
import VolEqCore
import VolEqSpeech

enum AudioCaptureTarget: Equatable, Sendable {
    case application(AudioObjectID)
    case deviceWide
}

enum AudioCaptureTargetResolver {
    static func resolve(
        resolvedIntent: ResolvedCaptureIntent,
        ownProcessObject: () throws -> AudioObjectID?
    ) throws -> AudioCaptureTarget {
        switch resolvedIntent.target {
        case let .application(process):
            return .application(process.id)
        case .deviceWide:
            guard try ownProcessObject() != nil else {
                throw VolEqError.missingValue(
                    "VolEq could not exclude itself from device-wide capture, so it stopped to prevent feedback. Try again."
                )
            }
            return .deviceWide
        }
    }
}

protocol AudioCapturePreflighting: Sendable {
    func prepare(
        resolvedIntent: ResolvedCaptureIntent
    ) throws -> PreparedCaptureRequest
}

final class AudioCapturePreflightExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.patrikistvandoczy.voleq.community.capture-preflight",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var operationInFlight = false

    func prepare(
        using preflight: any AudioCapturePreflighting,
        resolvedIntent: ResolvedCaptureIntent
    ) async throws -> PreparedCaptureRequest {
        let lease = AudioCapturePreflightLease()
        return try await withTaskCancellationHandler {
            guard claimOperation() else {
                throw VolEqError.missingValue(
                    "A previous audio preparation is still finishing. Wait for it to stop, then try again."
                )
            }
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(with: Result {
                        defer { releaseOperation() }
                        guard lease.isCurrent else { throw CancellationError() }
                        return try preflight.prepare(
                            resolvedIntent: resolvedIntent
                        )
                    })
                }
            }
        } onCancel: {
            lease.cancel()
        }
    }

    private func claimOperation() -> Bool {
        stateLock.withLock {
            guard !operationInFlight else { return false }
            operationInFlight = true
            return true
        }
    }

    private func releaseOperation() {
        stateLock.withLock { operationInFlight = false }
    }
}

private final class AudioCapturePreflightLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCurrent: Bool { lock.withLock { !cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

struct CoreAudioCapturePreflight: AudioCapturePreflighting {
    func prepare(
        resolvedIntent: ResolvedCaptureIntent
    ) throws -> PreparedCaptureRequest {
        let captureTarget = try AudioCaptureTargetResolver.resolve(
            resolvedIntent: resolvedIntent,
            ownProcessObject: { try processObject(for: getpid()) }
        )
        let intent = resolvedIntent.intent
        let speechModel = intent.speechAwarenessEnabled
            ? try AudioIOProcessor.loadSpeechModel()
            : nil
        let outputDeviceID = try defaultOutputDevice()
        let outputDeviceUID = try readString(
            objectID: outputDeviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
        let outputFormat: AudioStreamBasicDescription = try readValue(
            objectID: outputDeviceID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeOutput
        )
        try validateCaptureAudioFormat(outputFormat, label: "Output device")
        if intent.speechAwarenessEnabled {
            _ = try RNNoiseFixedBlockSampleRate.sourceBlockFrameCount(
                for: outputFormat.mSampleRate
            )
        }

        return PreparedCaptureRequest(
            speechModel: speechModel,
            outputDeviceID: outputDeviceID,
            outputDeviceUID: outputDeviceUID,
            outputFormat: outputFormat,
            captureTarget: captureTarget,
            intent: intent
        )
    }
}
