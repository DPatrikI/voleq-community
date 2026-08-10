// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VolEqCommunityMac
@testable import VolEqMacAudio
import VolEqCore

@available(macOS 14.2, *)
@MainActor
final class AudioStatusAnnouncementTests: XCTestCase {
    func testOrdinaryStartupDoesNotAnnounceIntermediateStates() throws {
        var messages: [String] = []
        let fixture = try makeDelegate { messages.append($0) }
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
        }

        fixture.delegate.processAudioStateForAnnouncement(
            state(.ready, "Ready")
        )
        fixture.delegate.processAudioStateForAnnouncement(
            state(.preparing, "Starting")
        )
        fixture.delegate.processAudioStateForAnnouncement(
            state(.active, "Active")
        )

        XCTAssertTrue(messages.isEmpty)
    }

    func testPublishedRecoveryAndCancellationAreConsumedInOrderWithoutYielding() throws {
        var messages: [String] = []
        let suite = "VolEqAnnouncementPublisherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let audio = AppAudioTestRig().makeController()
        let model = VolEqApplicationModel(
            defaults: defaults,
            installedVersion: .zero,
            audioController: audio
        )
        let delegate = AppDelegate(
            applicationModel: model,
            audioStatusAnnouncement: { messages.append($0) }
        )
        delegate.startAudioRuntimeAnnouncements()

        let intent = CaptureIntent(
            mode: .system,
            speechAwarenessEnabled: true,
            levelingSettings: LevelingSettings(),
            application: nil
        )
        audio.lifecycleDidPublish(AudioCaptureLifecycleSnapshot(
            phase: .recovering(intent, .outputRouteChanged),
            status: "Restoring"
        ))
        audio.lifecycleDidPublish(AudioCaptureLifecycleSnapshot(
            phase: .stopping(intent),
            status: "Restoring original audio"
        ))
        audio.lifecycleDidPublish(AudioCaptureLifecycleSnapshot(
            phase: .stopped,
            status: "Stopped by user"
        ))

        XCTAssertEqual(messages, ["Restoring", "Stopped by user"])
    }

    func testRecoverySuccessAndCancellationAreAnnouncedWithoutLaunchNoise() throws {
        var messages: [String] = []
        let primary = try makeDelegate { messages.append($0) }
        defer {
            primary.defaults.removePersistentDomain(forName: primary.suite)
        }
        let delegate = primary.delegate

        delegate.processAudioStateForAnnouncement(state(.ready, "Ready"))
        XCTAssertTrue(messages.isEmpty)
        delegate.processAudioStateForAnnouncement(state(.recovering, "Restoring"))
        delegate.processAudioStateForAnnouncement(state(.preparing, "Preparing"))
        delegate.processAudioStateForAnnouncement(state(.active, "Restored"))

        XCTAssertEqual(messages, ["Restoring", "Restored"])

        var cancellationMessages: [String] = []
        let cancellation = try makeDelegate {
            cancellationMessages.append($0)
        }
        defer {
            cancellation.defaults.removePersistentDomain(
                forName: cancellation.suite
            )
        }
        let cancellationDelegate = cancellation.delegate
        cancellationDelegate.processAudioStateForAnnouncement(state(.ready, "Ready"))
        cancellationDelegate.processAudioStateForAnnouncement(
            state(.recovering, "Restoring")
        )
        cancellationDelegate.processAudioStateForAnnouncement(
            state(
                .stopped,
                "Stopping Leveling",
                acceptsPrimaryAction: false
            )
        )
        cancellationDelegate.processAudioStateForAnnouncement(
            state(.stopped, "Stopped by user")
        )

        XCTAssertEqual(
            cancellationMessages,
            ["Restoring", "Stopped by user"]
        )
    }

    private func makeDelegate(
        announce: @escaping @MainActor (String) -> Void
    ) throws -> (delegate: AppDelegate, defaults: UserDefaults, suite: String) {
        let suite = "VolEqAnnouncementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let model = VolEqApplicationModel(
            defaults: defaults,
            installedVersion: .zero,
            audioController: AppAudioTestRig().makeController()
        )
        return (
            AppDelegate(
                applicationModel: model,
                audioStatusAnnouncement: announce
            ),
            defaults,
            suite
        )
    }

    private func state(
        _ activity: AudioCaptureActivity,
        _ status: String,
        acceptsPrimaryAction: Bool = true
    ) -> AudioCaptureStateSnapshot {
        AudioCaptureStateSnapshot(
            activity: activity,
            systemAudioAccessState: .notRequested,
            status: status,
            acceptsPrimaryAction: acceptsPrimaryAction
        )
    }
}
