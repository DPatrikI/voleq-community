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

    func testAcceptedStartNeverPublishesPermissionCheckingOrVerifiedState() async throws {
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

        XCTAssertFalse(states.contains {
            $0.activity == .checkingAccess
                || $0.systemAudioAccessState == .checking
                || $0.systemAudioAccessState == .verified
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
