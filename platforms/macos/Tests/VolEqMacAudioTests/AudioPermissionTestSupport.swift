// SPDX-License-Identifier: MPL-2.0

import Foundation
@testable import VolEqMacAudio

@MainActor
final class PermissionProbeEventRecorder {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

@MainActor
final class ImmediateSystemAudioPermissionProbe: SystemAudioPermissionProbing {
    private let outcome: SystemAudioPermissionProbeOutcome
    private let recorder: PermissionProbeEventRecorder?
    private let tearsDownBeforeReturning: Bool
    private(set) var cancelCount = 0
    private(set) var isTornDown = false

    init(
        outcome: SystemAudioPermissionProbeOutcome = .verified,
        recorder: PermissionProbeEventRecorder? = nil,
        tearsDownBeforeReturning: Bool = true
    ) {
        self.outcome = outcome
        self.recorder = recorder
        self.tearsDownBeforeReturning = tearsDownBeforeReturning
    }

    func verify() async -> SystemAudioPermissionProbeOutcome {
        recorder?.append("probe verify")
        if tearsDownBeforeReturning {
            isTornDown = true
            recorder?.append("probe teardown")
        }
        return outcome
    }

    func cancel() {
        cancelCount += 1
        isTornDown = true
        recorder?.append("probe cancel")
    }
}

@MainActor
final class SuspendedSystemAudioPermissionProbe: SystemAudioPermissionProbing {
    private let recorder: PermissionProbeEventRecorder?
    private var continuation: CheckedContinuation<SystemAudioPermissionProbeOutcome, Never>?
    private(set) var cancelCount = 0
    private(set) var isTornDown = false

    init(recorder: PermissionProbeEventRecorder? = nil) {
        self.recorder = recorder
    }

    func verify() async -> SystemAudioPermissionProbeOutcome {
        recorder?.append("probe verify")
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(with outcome: SystemAudioPermissionProbeOutcome) {
        guard let continuation else { return }
        self.continuation = nil
        isTornDown = true
        recorder?.append("probe teardown")
        continuation.resume(returning: outcome)
    }

    func cancel() {
        cancelCount += 1
        isTornDown = true
        recorder?.append("probe cancel")
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: .cancelled)
    }
}

@MainActor
@available(macOS 14.2, *)
func waitForPermissionState(
    _ controller: AudioCaptureController,
    _ state: SystemAudioAccessState,
    attempts: Int = 2_000
) async {
    for _ in 0..<attempts {
        if controller.systemAudioAccessState == state { return }
        await Task.yield()
    }
}

@MainActor
@available(macOS 14.2, *)
func waitForRuntimeState(
    _ controller: AudioCaptureController,
    _ state: CaptureRuntimeState,
    attempts: Int = 2_000
) async {
    for _ in 0..<attempts {
        if controller.runtimeState == state { return }
        await Task.yield()
    }
}
