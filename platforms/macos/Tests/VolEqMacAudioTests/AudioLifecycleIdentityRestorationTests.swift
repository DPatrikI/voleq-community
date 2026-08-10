// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import XCTest
@testable import VolEqMacAudio

@available(macOS 14.2, *)
@MainActor
final class AudioLifecycleIdentityRestorationTests: XCTestCase {
    private let identity = ApplicationCaptureIdentity(
        processObjectID: 10,
        pid: 100,
        bundleID: "com.example.call",
        displayName: "Call"
    )

    func testReusedProcessObjectDuringExplanationFailsBeforePipeline() async {
        let rig = AudioCaptureTestRig()
        let explanation = SuspendedPermissionExplanation()
        rig.permissionExplanation = { await explanation.request() }
        rig.processCatalog.result = .success([audioProcess(
            id: 10, pid: 100, name: "Call", bundleID: "com.example.call"
        )])
        let controller = rig.makeController()
        await waitForSelection(controller, id: 10)

        controller.start()
        await waitForExplanation(explanation)
        rig.processCatalog.result = .success([audioProcess(
            id: 10, pid: 999, name: "Unrelated", bundleID: "com.example.other"
        )])
        explanation.respond(continued: true)
        await waitForRuntimeState(controller, .failed)

        XCTAssertNil(controller.selectedProcessID)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
    }

    func testUniqueRelaunchDuringExplanationUsesNewTargetForPipeline() async {
        let rig = AudioCaptureTestRig()
        let explanation = SuspendedPermissionExplanation()
        rig.permissionExplanation = { await explanation.request() }
        rig.processCatalog.result = .success([audioProcess(
            id: 10, pid: 100, name: "Call", bundleID: "com.example.call"
        )])
        let controller = rig.makeController()
        await waitForSelection(controller, id: 10)

        controller.start()
        await waitForExplanation(explanation)
        rig.processCatalog.result = .success([audioProcess(
            id: 11, pid: 101, name: "Call", bundleID: "com.example.call"
        )])
        explanation.respond(continued: true)
        await waitForRuntimeState(controller, .active)

        XCTAssertEqual(
            rig.pipelines.requests.map(\.captureTarget),
            [.application(11)]
        )
        XCTAssertEqual(controller.selectedProcessID, 11)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }

    func testAmbiguousRelaunchDuringExplanationFailsBeforePipeline() async {
        let rig = AudioCaptureTestRig()
        let explanation = SuspendedPermissionExplanation()
        rig.permissionExplanation = { await explanation.request() }
        rig.processCatalog.result = .success([audioProcess(
            id: 10, pid: 100, name: "Call", bundleID: "com.example.call"
        )])
        let controller = rig.makeController()
        await waitForSelection(controller, id: 10)

        controller.start()
        await waitForExplanation(explanation)
        rig.processCatalog.result = .success([
            audioProcess(id: 11, pid: 101, name: "Call", bundleID: "com.example.call"),
            audioProcess(id: 12, pid: 102, name: "Call", bundleID: "com.example.call"),
        ])
        explanation.respond(continued: true)
        await waitForRuntimeState(controller, .failed)

        XCTAssertNil(controller.selectedProcessID)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
    }

    func testOrdinaryStartRejectsReusedProcessObjectID() async throws {
        let rig = AudioCaptureTestRig()
        let selected = audioProcess(
            id: 10, pid: 100, name: "Call", bundleID: "com.example.call"
        )
        rig.processCatalog.result = .success([selected])
        let controller = rig.makeController()
        try await waitForAudioCondition("selected application identity") {
            controller.selectedProcessID == selected.id
        }
        rig.processCatalog.result = .success([audioProcess(
            id: 10, pid: 999, name: "Unrelated", bundleID: "com.example.other"
        )])

        controller.start()
        await waitForRuntimeState(controller, .failed)

        XCTAssertNil(controller.selectedProcessID)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
    }

    func testRefreshRejectsReusedProcessObjectIDBeforeStart() async throws {
        let rig = AudioCaptureTestRig()
        rig.processCatalog.result = .success([audioProcess(
            id: 10, pid: 100, name: "Call", bundleID: "com.example.call"
        )])
        let controller = rig.makeController()
        await waitForSelection(controller, id: 10)

        rig.processCatalog.result = .success([audioProcess(
            id: 10, pid: 999, name: "Unrelated", bundleID: "com.example.other"
        )])
        controller.refreshProcesses()
        try await waitForAudioCondition("reused selection cleared") {
            controller.processes.first?.pid == 999
                && controller.selectedProcessID == nil
        }
        controller.start()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(controller.selectedProcessID)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
    }

    func testRefreshDoesNotAutoSelectUnrelatedProcessAfterDisappearance() async throws {
        let rig = AudioCaptureTestRig()
        rig.processCatalog.result = .success([audioProcess(
            id: 10, pid: 100, name: "Call", bundleID: "com.example.call"
        )])
        let controller = rig.makeController()
        await waitForSelection(controller, id: 10)

        rig.processCatalog.result = .success([audioProcess(
            id: 20, pid: 200, name: "Unrelated", bundleID: "com.example.other"
        )])
        controller.refreshProcesses()
        try await waitForAudioCondition("missing selection cleared") {
            controller.processes.first?.id == 20
                && controller.selectedProcessID == nil
        }
        controller.start()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(controller.selectedProcessID)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
        XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
    }

    func testTargetDisappearanceAndBundlelessIdentityFailBeforePipeline() async {
        for process in [
            audioProcess(
                id: 10, pid: 100, name: "Call", bundleID: "com.example.call"
            ),
            audioProcess(id: 20, pid: 200, name: "Bundleless", bundleID: ""),
        ] {
            let rig = AudioCaptureTestRig()
            rig.processCatalog.result = .success([process])
            let controller = rig.makeController()
            await waitForSelection(controller, id: process.id)
            if !process.bundleID.isEmpty {
                rig.processCatalog.result = .success([])
            }

            controller.start()
            await waitForRuntimeState(controller, .failed)

            XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
            XCTAssertTrue(rig.pipelines.pipelines.isEmpty)
        }
    }

    func testExactPIDAndBundleMatchWins() {
        let exact = audioProcess(
            id: 11, pid: 100, name: "Call", bundleID: "com.example.call"
        )
        let relaunch = audioProcess(
            id: 12, pid: 101, name: "Call", bundleID: "com.example.call"
        )
        XCTAssertEqual(
            ApplicationCaptureTargetResolver.resolve(
                identity: identity,
                processes: [relaunch, exact]
            ),
            .resolved(exact)
        )
    }

    func testUniqueBundleRelaunchIsRestored() {
        let relaunch = audioProcess(
            id: 12, pid: 101, name: "Call", bundleID: "com.example.call"
        )
        XCTAssertEqual(
            ApplicationCaptureTargetResolver.resolve(
                identity: identity,
                processes: [relaunch]
            ),
            .resolved(relaunch)
        )
    }

    func testDisplayNameChangeDoesNotCountAsIdentityMovement() {
        let renamed = audioProcess(
            id: 10,
            pid: 100,
            name: "Call (New Window Title)",
            bundleID: "com.example.call"
        )

        XCTAssertEqual(
            ApplicationCaptureTargetResolver.resolve(
                identity: identity,
                processes: [renamed]
            ),
            .resolved(renamed)
        )
        XCTAssertEqual(
            ResolvedCaptureTarget.application(renamed).captureIdentity,
            .application(
                objectID: 10,
                pid: 100,
                bundleID: "com.example.call"
            )
        )
    }

    func testAmbiguousMissingAndBundlelessTargetsFailSafely() {
        let first = audioProcess(
            id: 12, pid: 101, name: "Call", bundleID: "com.example.call"
        )
        let second = audioProcess(
            id: 13, pid: 102, name: "Call", bundleID: "com.example.call"
        )
        XCTAssertEqual(
            ApplicationCaptureTargetResolver.resolve(
                identity: identity,
                processes: [first, second]
            ),
            .ambiguous
        )
        XCTAssertEqual(
            ApplicationCaptureTargetResolver.resolve(identity: identity, processes: []),
            .missing
        )
        XCTAssertEqual(
            ApplicationCaptureTargetResolver.resolve(
                identity: .init(
                    processObjectID: 10,
                    pid: 100,
                    bundleID: "",
                    displayName: "Bundleless"
                ),
                processes: [audioProcess(
                    id: 10,
                    pid: 100,
                    name: "Unrelated",
                    bundleID: ""
                )]
            ),
            .missing
        )
    }

    func testMissingWakeTargetRequiresExplicitSelection() async {
        let rig = AudioCaptureTestRig()
        let original = audioProcess(id: 10, pid: 100, name: "Call")
        let unrelated = audioProcess(
            id: 22,
            pid: 200,
            name: "Music",
            bundleID: "com.example.music"
        )
        rig.processCatalog.result = .success([original])
        let controller = rig.makeController()
        await waitForSelection(controller, id: original.id)
        controller.start()
        await waitForRuntimeState(controller, .active)
        controller.prepareForSystemSleep()
        rig.processCatalog.result = .success([unrelated])

        controller.resumeAfterSystemWake()
        await waitForRuntimeState(controller, .failed)

        XCTAssertNil(controller.selectedProcessID)
        controller.refreshProcesses()
        XCTAssertNil(controller.selectedProcessID)
        XCTAssertFalse(controller.canRetryRecovery)
        XCTAssertEqual(rig.pipelines.pipelines.count, 1)
    }

    func testExplicitSelectionSurvivesRefreshFailureThenSuccess() async {
        let rig = AudioCaptureTestRig()
        let original = audioProcess(id: 10, pid: 100, name: "Call")
        let replacement = audioProcess(id: 20, pid: 200, name: "Other")
        rig.processCatalog.result = .success([original])
        let controller = rig.makeController()
        await waitForSelection(controller, id: original.id)
        controller.start()
        await waitForRuntimeState(controller, .active)
        controller.prepareForSystemSleep()
        rig.processCatalog.result = .success([])
        controller.resumeAfterSystemWake()
        await waitForRuntimeState(controller, .failed)

        rig.processCatalog.result = .failure(AudioCaptureTestError.unavailable)
        controller.refreshProcesses()
        rig.processCatalog.result = .success([replacement])
        controller.refreshProcesses()

        XCTAssertEqual(controller.captureState.activity, .recoveryFailed)
        XCTAssertNil(controller.selectedProcessID)
    }

    private func waitForExplanation(
        _ explanation: SuspendedPermissionExplanation
    ) async {
        for _ in 0..<2_000 {
            if explanation.requestCount == 1 { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for permission explanation")
    }

    private func waitForSelection(
        _ controller: AudioCaptureController,
        id: AudioObjectID
    ) async {
        for _ in 0..<2_000 {
            if controller.selectedProcessID == id { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for application selection \(id)")
    }
}
