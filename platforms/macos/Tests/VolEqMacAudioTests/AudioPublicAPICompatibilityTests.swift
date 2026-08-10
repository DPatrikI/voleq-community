// SPDX-License-Identifier: MPL-2.0

import Combine
import VolEqMacAudio
import XCTest

final class AudioPublicAPICompatibilityTests: XCTestCase {
    func testV010RuntimeStateRemainsExhaustivelySwitchable() {
        XCTAssertEqual(v010Title(for: .active), "active")
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

    private func v010Title(for state: CaptureRuntimeState) -> String {
        switch state {
        case .stopped: "stopped"
        case .ready: "ready"
        case .preparing: "preparing"
        case .active: "active"
        case .recovering: "recovering"
        case .failed: "failed"
        }
    }
}
