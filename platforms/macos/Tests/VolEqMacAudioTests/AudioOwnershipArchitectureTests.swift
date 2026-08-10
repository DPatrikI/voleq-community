// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest

final class AudioOwnershipArchitectureTests: XCTestCase {
    func testProductionOwnersExposeNoResourceAdoptionBypasses() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourcesDirectory = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/VolEqMacAudio")
        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: sourcesDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let productionSource = try sourceFiles
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0) }
            .joined(separator: "\n")

        XCTAssertFalse(productionSource.contains("init(adopting:"))
        XCTAssertFalse(productionSource.contains("CoreAudioCaptureOwnedResources"))
        XCTAssertFalse(productionSource.contains("resourceStage:"))
        XCTAssertFalse(productionSource.contains("CoreAudioPermissionProbeOwnedResources"))
    }
}
