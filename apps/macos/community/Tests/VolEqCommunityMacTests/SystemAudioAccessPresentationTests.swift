// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import VolEqCommunityMac
@testable import VolEqMacAudio

@MainActor
final class SystemAudioAccessPresentationTests: XCTestCase {
    func testContinuePersistsExplanationAcceptance() async throws {
        let defaults = try makeDefaults()
        defer { removeTestDefaults(defaults) }
        let controller = SystemAudioAccessPresentationController(defaults: defaults)

        let request = Task { await controller.requestExplanationAcceptance() }
        await waitUntil { controller.shouldPresentExplanation }
        controller.respondToExplanation(continued: true)

        let accepted = await request.value
        XCTAssertTrue(accepted)
        XCTAssertTrue(defaults.bool(
            forKey: SystemAudioAccessPresentationController.explanationAcceptedKey
        ))

        let restored = SystemAudioAccessPresentationController(defaults: defaults)
        let restoredAcceptance = await restored.requestExplanationAcceptance()
        XCTAssertTrue(restoredAcceptance)
        XCTAssertFalse(restored.shouldPresentExplanation)
    }

    func testNotNowDoesNotPersistAndExplanationReturnsLater() async throws {
        let defaults = try makeDefaults()
        defer { removeTestDefaults(defaults) }
        let controller = SystemAudioAccessPresentationController(defaults: defaults)

        let first = Task { await controller.requestExplanationAcceptance() }
        await waitUntil { controller.shouldPresentExplanation }
        controller.respondToExplanation(continued: false)
        let firstAcceptance = await first.value
        XCTAssertFalse(firstAcceptance)
        XCTAssertFalse(defaults.bool(
            forKey: SystemAudioAccessPresentationController.explanationAcceptedKey
        ))

        let second = Task { await controller.requestExplanationAcceptance() }
        await waitUntil { controller.shouldPresentExplanation }
        XCTAssertTrue(controller.shouldPresentExplanation)
        controller.respondToExplanation(continued: false)
        let secondAcceptance = await second.value
        XCTAssertFalse(secondAcceptance)
    }

    func testConcurrentExplanationRequestsShareTheVisibleDecision() async throws {
        let defaults = try makeDefaults()
        defer { removeTestDefaults(defaults) }
        let controller = SystemAudioAccessPresentationController(defaults: defaults)

        let requestBeforeSleep = Task {
            await controller.requestExplanationAcceptance()
        }
        await waitUntil { controller.shouldPresentExplanation }
        let replacementRequestAfterWake = Task {
            await controller.requestExplanationAcceptance()
        }
        await Task.yield()

        XCTAssertTrue(controller.shouldPresentExplanation)
        controller.respondToExplanation(continued: true)

        let firstAccepted = await requestBeforeSleep.value
        let replacementAccepted = await replacementRequestAfterWake.value
        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(replacementAccepted)
        XCTAssertFalse(controller.shouldPresentExplanation)
    }

    func testCancelledExplanationRequestIsRemovedBeforeLaterStart() async throws {
        let defaults = try makeDefaults()
        defer { removeTestDefaults(defaults) }
        let controller = SystemAudioAccessPresentationController(defaults: defaults)

        let cancelledRequest = Task {
            await controller.requestExplanationAcceptance()
        }
        await waitUntil { controller.shouldPresentExplanation }
        cancelledRequest.cancel()

        let cancelled = await cancelledRequest.value
        XCTAssertFalse(cancelled)
        await waitUntil { !controller.shouldPresentExplanation }

        let laterRequest = Task {
            await controller.requestExplanationAcceptance()
        }
        await waitUntil { controller.shouldPresentExplanation }
        controller.respondToExplanation(continued: true)

        let accepted = await laterRequest.value
        XCTAssertTrue(accepted)
        XCTAssertFalse(controller.shouldPresentExplanation)
    }

    func testNoSoundHelpIsAlwaysAvailableAndUsesPrivacyCopy() throws {
        let defaults = try makeDefaults()
        defer { removeTestDefaults(defaults) }
        let controller = SystemAudioAccessPresentationController(defaults: defaults)

        XCTAssertFalse(controller.shouldPresentNoSoundHelp)
        controller.presentNoSoundHelp()
        XCTAssertTrue(controller.shouldPresentNoSoundHelp)
        XCTAssertTrue(SystemAudioAccessPresentationController.noSoundCopy.contains(
            "does not record, save, upload"
        ))
        XCTAssertTrue(SystemAudioAccessPresentationController.noSoundCopy.contains(
            "System Audio Recording permission"
        ))
        XCTAssertTrue(SystemAudioAccessPresentationController.noSoundCopy.contains(
            "Privacy & Security → Screen & System Audio Recording"
        ))
        controller.dismissNoSoundHelp()
        XCTAssertFalse(controller.shouldPresentNoSoundHelp)
    }

    func testSettingsNavigationUsesDirectPaneWhenSupported() throws {
        let defaults = try makeDefaults()
        defer { removeTestDefaults(defaults) }
        let opener = RecordingSystemSettingsOpener(results: [true])
        let controller = SystemAudioAccessPresentationController(
            defaults: defaults,
            settingsOpener: opener
        )

        let outcome = controller.openSystemAudioRecordingSettings()

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(opener.openedURLs.count, 1)
        XCTAssertTrue(opener.openedURLs[0].absoluteString.contains("Privacy_ScreenCapture"))
    }

    func testDirectNavigationFailureFallsBackToPrivacySettings() throws {
        let defaults = try makeDefaults()
        defer { removeTestDefaults(defaults) }
        let opener = RecordingSystemSettingsOpener(results: [false, true])
        let controller = SystemAudioAccessPresentationController(
            defaults: defaults,
            settingsOpener: opener
        )

        let outcome = controller.openSystemAudioRecordingSettings()

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(opener.openedURLs.count, 2)
        XCTAssertTrue(opener.openedURLs[1].absoluteString.contains("preference.security"))
    }

    func testSettingsNavigationTotalFailureReturnsManualInstructions() throws {
        let defaults = try makeDefaults()
        defer { removeTestDefaults(defaults) }
        let opener = RecordingSystemSettingsOpener(results: [false, false])
        let controller = SystemAudioAccessPresentationController(
            defaults: defaults,
            settingsOpener: opener
        )

        let outcome = controller.openSystemAudioRecordingSettings()

        XCTAssertEqual(opener.openedURLs.count, 2)
        XCTAssertEqual(
            outcome,
            .failed(
                manualInstructions: SystemAudioAccessPresentationController
                    .manualSettingsPath
            )
        )
        guard case let .failed(manualInstructions) = outcome else {
            return XCTFail("Total navigation failure must surface manual instructions")
        }
        XCTAssertTrue(manualInstructions.contains("Screen & System Audio Recording"))
    }

    func testUsageDescriptionUsesRequiredPrivacyCopy() throws {
        let plistURL = repositoryRoot()
            .appendingPathComponent("apps/macos/community/Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(
            plist["NSAudioCaptureUsageDescription"] as? String,
            "VolEq uses System Audio Recording access to level the playback you choose in real time. Audio is processed on this Mac and is never saved or uploaded."
        )
    }

    @available(macOS 14.2, *)
    func testMenuBarSurfaceRendersFullViewport() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
            "AppKit pixel evidence requires a WindowServer-backed local session; behavioral surface coverage still runs in GitHub Actions."
        )
        let defaults = try makeDefaults()
        defer { removeTestDefaults(defaults) }
        let hostingView = makeMenuBarHostingView(defaults: defaults)

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        XCTAssertEqual(hostingView.bounds.width, 360, accuracy: 0.5)
        XCTAssertEqual(hostingView.bounds.height, 560, accuracy: 0.5)
        let background = try XCTUnwrap(bitmap.colorAt(x: 5, y: 5))
            .usingColorSpace(.deviceRGB)
        let pixelScaleX = CGFloat(bitmap.pixelsWide) / hostingView.bounds.width
        let pixelScaleY = CGFloat(bitmap.pixelsHigh) / hostingView.bounds.height
        let bitmapRowsFromTop: (Range<CGFloat>) -> Range<Int> = { points in
            // `cacheDisplay` preserves this flipped SwiftUI backing store's
            // top-origin row order in the bitmap representation.
            let lowerEdge = Int(points.lowerBound * pixelScaleY)
            let upperEdge = Int(points.upperBound * pixelScaleY)
            return max(0, lowerEdge)..<min(bitmap.pixelsHigh, upperEdge)
        }
        let visibleSampleCount: (CGRect) -> Int = { rect in
            let columns = Int(rect.minX * pixelScaleX)..<min(
                bitmap.pixelsWide,
                Int(rect.maxX * pixelScaleX)
            )
            let rows = bitmapRowsFromTop(rect.minY..<rect.maxY)
            var count = 0
            for x in stride(from: columns.lowerBound, to: columns.upperBound, by: 3) {
                for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 3) {
                    guard let color = bitmap.colorAt(x: x, y: y)?
                        .usingColorSpace(.deviceRGB),
                        let background
                    else { continue }
                    if abs(color.redComponent - background.redComponent) > 0.2
                        || abs(color.greenComponent - background.greenComponent) > 0.2
                        || abs(color.blueComponent - background.blueComponent) > 0.2
                    {
                        count += 1
                    }
                }
            }
            return count
        }

        let namedRegions: [(String, CGRect)] = [
            ("runtime status", CGRect(x: 40, y: 55, width: 190, height: 70)),
            ("primary action", CGRect(x: 255, y: 70, width: 70, height: 45)),
            ("capture mode", CGRect(x: 40, y: 180, width: 195, height: 30)),
            ("application picker", CGRect(x: 115, y: 215, width: 205, height: 35)),
            ("speech toggle", CGRect(x: 300, y: 260, width: 25, height: 25)),
            ("update action", CGRect(x: 40, y: 315, width: 155, height: 30)),
            ("window action", CGRect(x: 40, y: 350, width: 155, height: 30)),
            ("settings action", CGRect(x: 235, y: 350, width: 90, height: 30)),
            ("quit action", CGRect(x: 40, y: 385, width: 90, height: 30)),
        ]
        for (name, region) in namedRegions {
            XCTAssertGreaterThan(
                visibleSampleCount(region),
                8,
                "The menu-bar surface must render its \(name) in the expected viewport region"
            )
        }

        if let outputPath = ProcessInfo.processInfo.environment[
            "VOLEQ_MENU_RENDER_PATH"
        ] {
            let png = try XCTUnwrap(bitmap.representation(
                using: .png,
                properties: [:]
            ))
            try png.write(to: URL(fileURLWithPath: outputPath))
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "VolEqSystemAudioAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(suite, forKey: "testSuiteName")
        return defaults
    }

    @available(macOS 14.2, *)
    private func makeMenuBarHostingView(
        defaults: UserDefaults
    ) -> NSHostingView<AnyView> {
        let audio = AppAudioTestRig().makeController()
        let model = VolEqApplicationModel(
            defaults: defaults,
            installedVersion: .zero,
            audioController: audio
        )
        let surface = MenuBarControlSurface(
            model: audio,
            systemAudioAccess: model.systemAudioAccess,
            updates: model.updates,
            actions: ApplicationShellActions(
                updates: model.updates,
                openSettings: {},
                quit: {}
            ),
            switchToWindow: {}
        )
        .environment(\.colorScheme, .dark)
        .background(Color(nsColor: .windowBackgroundColor))
        let hostingView = NSHostingView(rootView: AnyView(surface))
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 560)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView
    }

    private func removeTestDefaults(_ defaults: UserDefaults) {
        guard let suite = defaults.string(forKey: "testSuiteName") else {
            return XCTFail("Test defaults lost their suite identity")
        }
        defaults.removePersistentDomain(forName: suite)
    }

    private func waitUntil(
        attempts: Int = 2_000,
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for presentation state")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

}

private final class RecordingSystemSettingsOpener: SystemSettingsOpening {
    private var results: [Bool]
    private(set) var openedURLs: [URL] = []

    init(results: [Bool]) {
        self.results = results
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return results.isEmpty ? false : results.removeFirst()
    }
}
