// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import XCTest
@testable import VolEqCommunityMac

final class MacPresentationControllerTests: XCTestCase {
    @MainActor
    func testNewInstallationDefaultsToWindow() {
        withDefaults { defaults in
            let controller = MacPresentationController(defaults: defaults)
            XCTAssertEqual(controller.mode, .window)
        }
    }

    @MainActor
    func testSelectionPersistsAcrossControllerInstances() {
        withDefaults { defaults in
            let controller = MacPresentationController(defaults: defaults)
            controller.mode = .menuBar

            let restored = MacPresentationController(defaults: defaults)
            XCTAssertEqual(restored.mode, .menuBar)
        }
    }

    @MainActor
    func testUnknownPersistedValueFallsBackToWindow() {
        withDefaults { defaults in
            defaults.set("future-mode", forKey: MacPresentationController.preferenceKey)
            let controller = MacPresentationController(defaults: defaults)
            XCTAssertEqual(controller.mode, .window)
        }
    }

    func testAlreadyRequestedActivationPolicyIsSuccessfulWithoutSettingAgain() {
        var requestedPolicies: [NSApplication.ActivationPolicy] = []

        let succeeded = MacActivationPolicyTransition.apply(
            current: .regular,
            desired: .regular,
            setPolicy: { policy in
                requestedPolicies.append(policy)
                return false
            }
        )

        XCTAssertTrue(succeeded)
        XCTAssertTrue(requestedPolicies.isEmpty)
    }

    func testActivationPolicyChangeReportsSetterResult() {
        var requestedPolicies: [NSApplication.ActivationPolicy] = []

        let failed = MacActivationPolicyTransition.apply(
            current: .accessory,
            desired: .regular,
            setPolicy: { policy in
                requestedPolicies.append(policy)
                return false
            }
        )

        XCTAssertFalse(failed)
        XCTAssertEqual(requestedPolicies, [.regular])

        let succeeded = MacActivationPolicyTransition.apply(
            current: .accessory,
            desired: .regular,
            setPolicy: { _ in true }
        )
        XCTAssertTrue(succeeded)
    }

    @MainActor
    func testMenuBarTransitionDismissesBeforeActivatingWindow() async {
        var events: [String] = []
        let activated = expectation(description: "Window presentation activated")

        MenuBarPresentationTransition.switchToWindow(
            dismiss: { events.append("dismiss") },
            activateWindow: {
                events.append("window")
                activated.fulfill()
            }
        )

        XCTAssertEqual(events, ["dismiss"])
        await fulfillment(of: [activated], timeout: 1)
        XCTAssertEqual(events, ["dismiss", "window"])
    }

    func testPresentationMetadataIsCompleteAndDistinct() {
        XCTAssertEqual(MacPresentationMode.allCases, [.window, .menuBar])
        XCTAssertEqual(Set(MacPresentationMode.allCases.map(\.title)).count, 2)
        XCTAssertTrue(MacPresentationMode.allCases.allSatisfy { !$0.detail.isEmpty })
        XCTAssertTrue(MacPresentationMode.allCases.allSatisfy { !$0.systemImage.isEmpty })
    }

    @MainActor
    func testMenuBarIconUsesNativeTemplateMetrics() throws {
        let (resources, resourceDirectoryURL) = try loadBrandResources()
        let icon = try VolEqBrand.loadMenuBarIcon(
            resources: resources,
            resourceDirectoryURL: resourceDirectoryURL
        )

        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size.width, 18, accuracy: 0.001)
        XCTAssertEqual(icon.size.height, 18, accuracy: 0.001)
    }

    func testBrandManifestResolvesCommittedResources() throws {
        let (resources, resourceDirectoryURL) = try loadBrandResources()
        let applicationIconURL = resourceDirectoryURL
            .appendingPathComponent(resources.applicationIconFileName)
        let menuBarTemplateURL = resourceDirectoryURL
            .appendingPathComponent(resources.menuBarTemplate.fileName)

        XCTAssertTrue(FileManager.default.fileExists(atPath: applicationIconURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: menuBarTemplateURL.path))
    }

    func testBrandManifestRejectsUnsafeResourceNames() throws {
        let validManifest: [String: Any] = [
            VolEqBrandResources.applicationIconKey: "Application.icns",
            VolEqBrandResources.menuBarTemplateKey: "MenuTemplate.png",
        ]
        XCTAssertNoThrow(try VolEqBrandResources(infoDictionary: validManifest))

        for invalidIconName in [
            "../Application.icns",
            "Folder/Application.icns",
            "Folder\\Application.icns",
            "Application:Alternate.icns",
            " Application.icns",
            "Application.icns ",
            "Application.png",
            ".",
            "..",
        ] {
            var manifest = validManifest
            manifest[VolEqBrandResources.applicationIconKey] = invalidIconName
            XCTAssertThrowsError(try VolEqBrandResources(infoDictionary: manifest))
        }

        var wrongTemplateExtension = validManifest
        wrongTemplateExtension[VolEqBrandResources.menuBarTemplateKey] = "MenuTemplate.icns"
        XCTAssertThrowsError(
            try VolEqBrandResources(infoDictionary: wrongTemplateExtension)
        )
    }

    private func loadBrandResources() throws -> (VolEqBrandResources, URL) {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let communityDirectory = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceDirectoryURL = communityDirectory
            .appendingPathComponent("Resources", isDirectory: true)
        let infoPlistURL = resourceDirectoryURL
            .appendingPathComponent(VolEqBrandResources.configurationFileName)
        let infoPlistData = try Data(contentsOf: infoPlistURL)
        guard let infoDictionary = try PropertyListSerialization.propertyList(
            from: infoPlistData,
            format: nil
        ) as? [String: Any] else {
            XCTFail("Could not read branding configuration from Info.plist")
            throw CocoaError(.propertyListReadCorrupt)
        }

        return (
            try VolEqBrandResources(infoDictionary: infoDictionary),
            resourceDirectoryURL
        )
    }

    @MainActor
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "VolEqCommunityMacTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated user defaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
