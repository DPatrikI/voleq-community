// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import XCTest
@testable import VolEqCommunityMac
@testable import VolEqMacAudio

@available(macOS 14.2, *)
@MainActor
final class ApplicationTerminationAudioSafetyTests: XCTestCase {
    func testApplicationTerminationCancelsAndTearsDownActiveProbe() async throws {
        let probe = TerminationSuspendedPermissionProbe()
        let audio = AudioCaptureController(
            installSystemObservers: false,
            startPipelineOverride: { _ in },
            permissionProbeFactory: { _ in probe }
        )
        let suite = "VolEqTerminationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = VolEqApplicationModel(
            defaults: defaults,
            installedVersion: .zero,
            audioController: audio
        )
        let delegate = AppDelegate(applicationModel: model)

        audio.start()
        for _ in 0..<2_000 {
            if audio.runtimeState == .checkingAccess { break }
            await Task.yield()
        }
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertEqual(probe.cancelCount, 1)
        XCTAssertTrue(probe.isTornDown)
        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(audio.runtimeState, .stopped)
    }
}

@MainActor
private final class TerminationSuspendedPermissionProbe:
    SystemAudioPermissionProbing {
    private var continuation: CheckedContinuation<
        SystemAudioPermissionProbeOutcome,
        Never
    >?
    private(set) var cancelCount = 0
    private(set) var isTornDown = false

    func verify() async -> SystemAudioPermissionProbeOutcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        isTornDown = true
        continuation?.resume(returning: .cancelled)
        continuation = nil
    }
}
