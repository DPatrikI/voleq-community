// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import XCTest
@testable import VolEqCommunityMac
@testable import VolEqMacAudio

@available(macOS 14.2, *)
@MainActor
final class ApplicationTerminationAudioSafetyTests: XCTestCase {
    func testApplicationTerminationDuringWakeRecoveryPreventsRestart() async throws {
        let rig = AppAudioTestRig()
        rig.blocksRouteRecovery = true
        let audio = rig.makeController()
        let suite = "VolEqTerminationRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = VolEqApplicationModel(
            defaults: defaults,
            installedVersion: .zero,
            audioController: audio
        )
        let delegate = AppDelegate(applicationModel: model)
        audio.mode = .system
        audio.start()
        await waitForAudio(audio, state: .active)
        audio.prepareForSystemSleep()
        audio.resumeAfterSystemWake()
        await waitForAudio(audio, state: .recovering)

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        XCTAssertEqual(audio.runtimeState, .stopped)
        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(rig.pipelines.count, 1)
    }

    func testWillTerminateDoesNotRepeatCompletedTerminateLaterTeardown() async throws {
        let rig = AppAudioTestRig()
        let audio = rig.makeController()
        let suite = "VolEqCompletedTerminationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = VolEqApplicationModel(
            defaults: defaults,
            installedVersion: .zero,
            audioController: audio
        )
        var terminationReply: Bool?
        let delegate = AppDelegate(
            applicationModel: model,
            terminationReply: { _, shouldTerminate in
                terminationReply = shouldTerminate
            }
        )
        audio.mode = .system
        audio.start()
        await waitForAudio(audio, state: .active)

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        for _ in 0..<2_000 where terminationReply == nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(terminationReply, true)
        XCTAssertEqual(rig.pipelines.first?.stopCount, 1)

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        XCTAssertEqual(rig.pipelines.first?.stopCount, 1)
    }

    private func waitForAudio(
        _ audio: AudioCaptureController,
        state: CaptureRuntimeState
    ) async {
        for _ in 0..<2_000 {
            if audio.runtimeState == state { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for application audio state \(state)")
    }
}
