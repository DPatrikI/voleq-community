// SPDX-License-Identifier: MPL-2.0

import Combine
import VolEqMacAudio
import XCTest

final class AudioPublicAPICompatibilityTests: XCTestCase {
    func testLegacyRuntimeStateRemainsExhaustivelySwitchable() {
        XCTAssertEqual(legacyTitle(for: .active), "active")
    }

    @available(macOS 14.2, *)
    @MainActor
    func testLegacyProjectedPublishersRemainAvailableToExternalClients() {
        func compileProjectedPublishers(_ controller: AudioCaptureController) {
            let _: Published<Bool>.Publisher = controller.$isRunning
            let _: Published<CaptureRuntimeState>.Publisher =
                controller.$runtimeState
            let _: Published<SystemAudioAccessState>.Publisher =
                controller.$systemAudioAccessState
            let _: Published<String>.Publisher = controller.$status
        }
        _ = compileProjectedPublishers
    }

    private func legacyTitle(for state: CaptureRuntimeState) -> String {
        switch state {
        case .stopped: "stopped"
        case .ready: "ready"
        case .preparing: "preparing"
        case .checkingAccess: "checking"
        case .active: "active"
        case .recovering: "recovering"
        case .permissionRequired: "permission"
        case .failed: "failed"
        }
    }
}
