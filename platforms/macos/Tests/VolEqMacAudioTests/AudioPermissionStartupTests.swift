// SPDX-License-Identifier: MPL-2.0

import Combine
import XCTest
@testable import VolEqMacAudio

@available(macOS 14.2, *)
@MainActor
final class AudioPermissionStartupTests: XCTestCase {
    func testExplanationIsAcceptedBeforeRealPipelineIsBuilt() async throws {
        let rig = AudioCaptureTestRig()
        var events: [String] = []
        rig.permissionExplanation = {
            events.append("explanation accepted")
            return true
        }
        rig.pipelines.make = {
            events.append("pipeline built")
            return try TestCapturePipeline()
        }
        let controller = rig.makeController()
        controller.mode = .system

        controller.start()
        try await waitForAudioCondition("active pipeline") {
            controller.runtimeState == .active
        }

        XCTAssertEqual(events, ["explanation accepted", "pipeline built"])
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }

    func testDecliningExplanationCreatesNoPipeline() async throws {
        let rig = AudioCaptureTestRig()
        rig.permissionExplanation = { false }
        let controller = rig.makeController()
        controller.mode = .system

        controller.start()
        try await waitForAudioCondition("declined explanation") {
            controller.systemAudioAccessState == .explanationRequired
                && controller.runtimeState == .stopped
        }

        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
    }

    func testAcceptedStartPublishesOnlyRealPipelineStartupStates() async throws {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        var states: [AudioCaptureStateSnapshot] = []
        let subscription = controller.$captureState.sink { states.append($0) }
        defer { subscription.cancel() }
        controller.mode = .system

        controller.start()
        try await waitForAudioCondition("active pipeline") {
            controller.runtimeState == .active
        }

        XCTAssertTrue(states.contains { $0.activity == .preparing })
        XCTAssertEqual(states.last?.activity, .active)
        XCTAssertTrue(states.allSatisfy {
            switch $0.activity {
            case .stopped, .ready, .preparing, .active:
                true
            case .suspended, .recovering, .recoveryFailed, .failed:
                false
            }
        })
        XCTAssertTrue(states.allSatisfy {
            $0.systemAudioAccessState == .notRequested
                || $0.systemAudioAccessState == .explanationRequired
        })
        XCTAssertTrue(states.contains {
            $0.status == "Preparing output-route safety monitoring before Leveling starts."
        })
        XCTAssertFalse(states.contains {
            $0.status.localizedCaseInsensitiveContains("access is checked")
                || $0.status.localizedCaseInsensitiveContains("checking audio access")
        })
    }

    func testEveryRestartBuildsTheRealPipelineDirectly() async throws {
        let rig = AudioCaptureTestRig()
        let controller = rig.makeController()
        controller.mode = .system

        for expectedCount in 1...2 {
            controller.start()
            try await waitForAudioCondition("active pipeline \(expectedCount)") {
                controller.runtimeState == .active
            }
            XCTAssertEqual(rig.pipelines.pipelines.count, expectedCount)
            controller.stop()
            try await waitForAudioCondition("stopped pipeline \(expectedCount)") {
                controller.runtimeState == .stopped
                    && controller.captureState.acceptsPrimaryAction
            }
        }
    }
}
