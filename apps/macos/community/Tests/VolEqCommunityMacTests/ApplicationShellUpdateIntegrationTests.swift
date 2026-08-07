// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest

final class ApplicationShellUpdateIntegrationTests: XCTestCase {
    func testEveryRequiredManualAndBackgroundUpdateAccessPointIsWired() throws {
        let sources = sourceDirectory
        let app = try String(
            contentsOf: sources.appendingPathComponent("VolEqCommunityMacApp.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: sources.appendingPathComponent("PresentationSettingsView.swift"),
            encoding: .utf8
        )
        let surfaces = try String(
            contentsOf: sources.appendingPathComponent("VolEqControlSurfaces.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(app.contains("CommandGroup(after: .appInfo)"))
        XCTAssertTrue(app.contains("\"Checking for Updates…\""))
        XCTAssertTrue(app.contains("\"Check for Updates…\""))
        XCTAssertTrue(settings.contains("Button(\"Check Now\")"))
        XCTAssertTrue(settings.contains("Automatically check for updates"))
        XCTAssertTrue(surfaces.contains("struct UtilityWindowView"))
        XCTAssertTrue(surfaces.contains("struct MenuBarControlSurface"))
        XCTAssertEqual(
            surfaces.components(separatedBy: "UpdateAvailableIndicator(updates: updates").count - 1,
            2
        )
        XCTAssertTrue(surfaces.contains("Button(\"Check for Updates…\")"))
    }

    func testConsentCopyExplicitQuitAndSafeReleaseActionsRemainReachable() throws {
        let appDelegate = try String(
            contentsOf: sourceDirectory.appendingPathComponent("AppDelegate.swift"),
            encoding: .utf8
        )
        let surfaces = try String(
            contentsOf: sourceDirectory.appendingPathComponent("VolEqControlSurfaces.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegate.contains("Enable Daily Checks"))
        XCTAssertTrue(appDelegate.contains("Don’t Check Automatically"))
        XCTAssertTrue(appDelegate.contains("No audio or usage data is sent"))
        XCTAssertTrue(appDelegate.contains("View Release"))
        XCTAssertTrue(appDelegate.contains("Retry"))
        XCTAssertTrue(appDelegate.contains("Couldn’t Open Release"))
        XCTAssertTrue(appDelegate.contains("keyEquivalent = \"\\u{1b}\""))
        XCTAssertTrue(surfaces.contains("Button(\"Quit VolEq\")"))
        XCTAssertTrue(surfaces.contains("NSApp.terminate(nil)"))
    }

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/VolEqCommunityMac")
    }
}
