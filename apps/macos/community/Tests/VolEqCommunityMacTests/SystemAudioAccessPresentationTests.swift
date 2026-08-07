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
        defer { defaults.removePersistentDomain(forName: try! XCTUnwrap(defaultsSuiteName(defaults))) }
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
        defer { defaults.removePersistentDomain(forName: try! XCTUnwrap(defaultsSuiteName(defaults))) }
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

    func testSettingsNavigationUsesDirectPaneWhenSupported() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: try! XCTUnwrap(defaultsSuiteName(defaults))) }
        let opener = RecordingSystemSettingsOpener(results: [true])
        let controller = SystemAudioAccessPresentationController(
            defaults: defaults,
            settingsOpener: opener
        )

        controller.openSystemAudioRecordingSettings()

        XCTAssertEqual(opener.openedURLs.count, 1)
        XCTAssertTrue(opener.openedURLs[0].absoluteString.contains("Privacy_ScreenCapture"))
        XCTAssertTrue(controller.settingsFallbackMessage?.contains(
            "Screen & System Audio Recording"
        ) == true)
    }

    func testSettingsNavigationFailureOpensPrivacyAndShowsManualPath() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: try! XCTUnwrap(defaultsSuiteName(defaults))) }
        let opener = RecordingSystemSettingsOpener(results: [false, true])
        let controller = SystemAudioAccessPresentationController(
            defaults: defaults,
            settingsOpener: opener
        )

        controller.openSystemAudioRecordingSettings()

        XCTAssertEqual(opener.openedURLs.count, 2)
        XCTAssertTrue(opener.openedURLs[1].absoluteString.contains("preference.security"))
        XCTAssertTrue(controller.settingsFallbackMessage?.contains(
            "could not navigate directly"
        ) == true)
        XCTAssertTrue(controller.settingsFallbackMessage?.contains(
            "Screen & System Audio Recording"
        ) == true)
        XCTAssertTrue(controller.settingsFallbackMessage?.contains("quit and reopen") == true)
    }

    func testSettingsNavigationTotalFailureIsExplicit() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: try! XCTUnwrap(defaultsSuiteName(defaults))) }
        let opener = RecordingSystemSettingsOpener(results: [false, false])
        let controller = SystemAudioAccessPresentationController(
            defaults: defaults,
            settingsOpener: opener
        )

        controller.openSystemAudioRecordingSettings()

        XCTAssertEqual(opener.openedURLs.count, 2)
        XCTAssertTrue(controller.settingsFallbackMessage?.contains(
            "could not open System Settings automatically"
        ) == true)
        XCTAssertTrue(controller.settingsFallbackMessage?.contains(
            "Screen & System Audio Recording"
        ) == true)
    }

    func testNativeCopyAndBothControlSurfacesExposeRecoveryActions() throws {
        let sources = repositoryRoot()
            .appendingPathComponent("apps/macos/community/Sources/VolEqCommunityMac")
        let appDelegate = try String(
            contentsOf: sources.appendingPathComponent("AppDelegate.swift")
        )
        let surfaces = try String(
            contentsOf: sources.appendingPathComponent("VolEqControlSurfaces.swift")
        )
        let presentation = try String(
            contentsOf: sources.appendingPathComponent("SystemAudioAccessPresentation.swift")
        )

        XCTAssertTrue(presentation.contains("System Audio Access Is Required"))
        XCTAssertTrue(presentation.contains("Audio stays in memory and is never saved, uploaded, or used for telemetry."))
        XCTAssertTrue(appDelegate.contains("withTitle: \"Continue\""))
        XCTAssertTrue(appDelegate.contains("withTitle: \"Not Now\""))
        XCTAssertGreaterThanOrEqual(
            surfaces.components(separatedBy: "AudioAccessActions(").count - 1,
            2
        )
        XCTAssertTrue(surfaces.contains("Button(\"Open System Settings…\")"))
        XCTAssertTrue(surfaces.contains("Button(\"Check Again\")"))
        XCTAssertTrue(surfaces.contains("Button(\"Cancel\")"))
        XCTAssertTrue(surfaces.contains("Button(\"Switch to Window\")"))
        XCTAssertTrue(surfaces.contains(".frame(width: 360, height: 560)"))
        XCTAssertTrue(surfaces.contains("Check for Updates…"))
        XCTAssertTrue(surfaces.contains("Settings…"))
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
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: try! XCTUnwrap(defaultsSuiteName(defaults))) }
        let audio = AudioCaptureController(installSystemObservers: false)
        let model = VolEqApplicationModel(
            defaults: defaults,
            installedVersion: .zero,
            audioController: audio
        )
        let surface = MenuBarControlSurface(
            model: audio,
            systemAudioAccess: model.systemAudioAccess,
            updates: model.updates,
            openSettings: {},
            switchToWindow: {}
        )
        .environment(\.colorScheme, .dark)
        .background(Color(nsColor: .windowBackgroundColor))
        let hostingView = NSHostingView(rootView: surface)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 560)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        XCTAssertEqual(hostingView.bounds.width, 360, accuracy: 0.5)
        XCTAssertEqual(hostingView.bounds.height, 560, accuracy: 0.5)
        let background = try XCTUnwrap(bitmap.colorAt(x: 5, y: 5))
            .usingColorSpace(.deviceRGB)
        let hasVisibleContent = stride(from: 8, to: bitmap.pixelsHigh, by: 8)
            .contains { y in
                stride(from: 8, to: bitmap.pixelsWide, by: 8).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?
                        .usingColorSpace(.deviceRGB),
                        let background
                    else { return false }
                    return abs(color.redComponent - background.redComponent) > 0.2
                        || abs(color.greenComponent - background.greenComponent) > 0.2
                        || abs(color.blueComponent - background.blueComponent) > 0.2
                }
            }
        XCTAssertTrue(hasVisibleContent, "The menu-bar surface must render visible controls")

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

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String? {
        defaults.string(forKey: "testSuiteName")
    }

    private func waitUntil(
        attempts: Int = 2_000,
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
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
