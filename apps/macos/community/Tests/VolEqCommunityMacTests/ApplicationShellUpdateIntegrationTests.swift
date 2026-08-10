// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VolEqCommunityMac

@MainActor
final class ApplicationShellUpdateIntegrationTests: XCTestCase {
    func testUpdateActionsDelegateToTheControllableUpdateModel() async throws {
        let updates = RecordingApplicationUpdateCommands()
        let actions = ApplicationShellActions(
            updates: updates,
            openSettings: {},
            quit: {}
        )
        let releaseURL = try XCTUnwrap(URL(
            string: "https://github.com/patrikistvandoczy/voleq/releases/tag/v0.2.0"
        ))
        let release = KnownAvailableUpdate(
            version: try ApplicationVersion(installedVersionString: "0.2.0"),
            releaseURL: releaseURL
        )

        await actions.checkForUpdates()
        let opened = actions.viewRelease(release)

        XCTAssertEqual(updates.manualCheckCount, 1)
        XCTAssertEqual(updates.openedReleases, [release])
        XCTAssertTrue(opened)
    }

    func testSettingsAndQuitActionsRemainBehaviorallyReachable() {
        let updates = RecordingApplicationUpdateCommands()
        var settingsCount = 0
        var quitCount = 0
        let actions = ApplicationShellActions(
            updates: updates,
            openSettings: { settingsCount += 1 },
            quit: { quitCount += 1 }
        )

        actions.openSettings()
        actions.quit()

        XCTAssertEqual(settingsCount, 1)
        XCTAssertEqual(quitCount, 1)
    }

}

@MainActor
private final class RecordingApplicationUpdateCommands:
    ApplicationUpdateCommandHandling {
    private(set) var manualCheckCount = 0
    private(set) var openedReleases: [KnownAvailableUpdate] = []

    func checkManually() async {
        manualCheckCount += 1
    }

    func openRelease(_ update: KnownAvailableUpdate) -> Bool {
        openedReleases.append(update)
        return true
    }
}
