// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import XCTest
@testable import VolEqCommunityMac
@testable import VolEqMacAudio

@MainActor
final class AudioLifecyclePresentationTests: XCTestCase {
    func testEveryRuntimeStateHasCompleteSharedActionAndAccessibilitySemantics() {
        let model = PresentationTestModel()
        let expectations: [PresentationExpectation] = [
            .init(.stopped, "Stopped", "Start Leveling", "Start", .neutral, false, true, "Conference"),
            .init(.ready, "Ready", "Start Leveling", "Start", .neutral, false, true, "Conference"),
            .init(.preparing, "Starting", "Stop Leveling", "Stop", .progressing, true, true, "Conference"),
            .init(.checkingAccess, "Starting", "Stop Leveling", "Stop", .progressing, true, true, "Conference"),
            .init(.active, "Active", "Stop Leveling", "Stop", .active, true, true, "Leveling Conference"),
            .init(.suspended, "Paused for System Sleep", "Stop Leveling", "Stop", .progressing, true, true, "Conference"),
            .init(.recovering, "Restoring Leveling", "Stop Leveling", "Stop", .progressing, true, true, "Conference"),
            .init(.recoveryFailed, "Leveling Did Not Resume", "Try Again", "Try Again", .attention, false, true, "Conference"),
            .init(.permissionRequired, "Stopped", "Start Leveling", "Start", .attention, false, true, "Conference"),
            .init(.failed, "Needs attention", "Start Leveling", "Start", .attention, false, true, "Conference"),
        ]

        for expectation in expectations {
            model.setState(expectation.state)
            let presentation = model.capturePresentation
            XCTAssertEqual(presentation.runtimeTitle, expectation.title)
            XCTAssertEqual(presentation.primaryActionTitle, expectation.fullAction)
            XCTAssertEqual(presentation.compactPrimaryActionTitle, expectation.compactAction)
            XCTAssertEqual(presentation.statusTone, expectation.tone)
            XCTAssertEqual(presentation.controlsLocked, expectation.controlsLocked)
            XCTAssertEqual(presentation.canPerformPrimaryAction, expectation.actionEnabled)
            XCTAssertEqual(
                presentation.accessibilityText,
                "\(expectation.title). \(expectation.targetSummary). Test status"
            )
        }
    }

    func testRecoveryFailureRequiresTargetButKeepsTryAgainSemantics() {
        let model = PresentationTestModel()
        model.setState(.recoveryFailed)
        model.selectedProcessID = nil

        XCTAssertEqual(model.capturePresentation.primaryActionTitle, "Try Again")
        XCTAssertFalse(model.capturePresentation.canPerformPrimaryAction)

        model.selectedProcessID = 42
        XCTAssertTrue(model.capturePresentation.canPerformPrimaryAction)
    }

    func testCleanupFailureLocksControlsAndPrimaryAction() {
        let model = PresentationTestModel()
        model.setState(.failed, access: .actionRequired(.cleanupFailed))

        XCTAssertTrue(model.capturePresentation.controlsLocked)
        XCTAssertFalse(model.capturePresentation.canPerformPrimaryAction)
    }

    func testStoppingSnapshotDoesNotOfferAStartThatLifecycleWillReject() {
        let model = PresentationTestModel()
        model.captureState = AudioCaptureStateSnapshot(
            activity: .stopped,
            systemAudioAccessState: .notRequested,
            status: "Stopping Leveling — original audio is being restored.",
            acceptsPrimaryAction: false
        )

        XCTAssertEqual(model.capturePresentation.runtimeTitle, "Stopping")
        XCTAssertEqual(
            model.capturePresentation.primaryActionTitle,
            "Restoring Audio…"
        )
        XCTAssertEqual(model.capturePresentation.statusTone, .progressing)
        XCTAssertTrue(model.capturePresentation.controlsLocked)
        XCTAssertFalse(model.capturePresentation.canPerformPrimaryAction)
        XCTAssertTrue(model.capturePresentation.accessibilityText
            .hasPrefix("Stopping."))
    }

    func testStaleApplicationSelectionDoesNotEnableStart() {
        let model = PresentationTestModel()
        model.selectedProcessID = 999

        XCTAssertEqual(
            model.capturePresentation.targetSummary,
            "Choose an audio-producing application"
        )
        XCTAssertFalse(model.capturePresentation.canPerformPrimaryAction)
    }

    func testApplicationAndDeviceWideSummariesUseSamePresentationValue() {
        let model = PresentationTestModel()
        model.processes = [AudioProcess(
            id: 42,
            pid: 7,
            name: "Conference",
            bundleID: "com.example.conference"
        )]
        model.selectedProcessID = 42
        XCTAssertEqual(model.capturePresentation.targetSummary, "Conference")

        model.setState(.active)
        XCTAssertEqual(model.capturePresentation.targetSummary, "Leveling Conference")

        model.mode = .system
        XCTAssertEqual(model.capturePresentation.targetSummary, "Leveling device-wide audio")
        XCTAssertTrue(model.capturePresentation.accessibilityText.contains("Active"))
        XCTAssertTrue(model.capturePresentation.accessibilityText
            .localizedCaseInsensitiveContains("device-wide"))
    }
}

@MainActor
private final class PresentationTestModel: VolEqControlSurfaceModel {
    var processes: [AudioProcess] = [AudioProcess(
        id: 42,
        pid: 7,
        name: "Conference",
        bundleID: "com.example.conference"
    )]
    var selectedProcessID: AudioObjectID? = 42
    var mode: CaptureMode = .application
    var speechAwarenessEnabled = true
    var captureState = AudioCaptureStateSnapshot(
        activity: .ready,
        systemAudioAccessState: .notRequested,
        status: "Test status"
    )

    func refreshProcesses() { }
    func toggle() { }
    func checkAudioAccessAgain() { }
    func cancelAudioAccessCheck() { }

    func setState(
        _ activity: AudioCaptureActivity,
        access: SystemAudioAccessState? = nil
    ) {
        captureState = AudioCaptureStateSnapshot(
            activity: activity,
            systemAudioAccessState: access ?? Self.accessState(for: activity),
            status: "Test status"
        )
    }

    private static func accessState(
        for activity: AudioCaptureActivity
    ) -> SystemAudioAccessState {
        switch activity {
        case .checkingAccess: .checking
        case .preparing, .active: .notRequested
        case .permissionRequired: .actionRequired(.permissionNotGranted)
        case .stopped, .ready, .suspended, .recovering, .recoveryFailed,
             .failed: .notRequested
        }
    }
}

private struct PresentationExpectation {
    let state: AudioCaptureActivity
    let title: String
    let fullAction: String
    let compactAction: String
    let tone: CaptureStatusTone
    let controlsLocked: Bool
    let actionEnabled: Bool
    let targetSummary: String

    init(
        _ state: AudioCaptureActivity,
        _ title: String,
        _ fullAction: String,
        _ compactAction: String,
        _ tone: CaptureStatusTone,
        _ controlsLocked: Bool,
        _ actionEnabled: Bool,
        _ targetSummary: String
    ) {
        self.state = state
        self.title = title
        self.fullAction = fullAction
        self.compactAction = compactAction
        self.tone = tone
        self.controlsLocked = controlsLocked
        self.actionEnabled = actionEnabled
        self.targetSummary = targetSummary
    }
}
