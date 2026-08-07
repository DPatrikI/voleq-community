// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VolEqCommunityMac

final class ApplicationVersionTests: XCTestCase {
    func testNumericOrderingUsesComponentsInsteadOfText() throws {
        let versions = try ["1.0.0", "0.1.10", "0.1.9", "0.2.0"].map {
            try ApplicationVersion(installedVersionString: $0)
        }

        XCTAssertEqual(
            versions.sorted().map(\.description),
            ["0.1.9", "0.1.10", "0.2.0", "1.0.0"]
        )
        XCTAssertEqual(
            try ApplicationVersion(installedVersionString: "12.34.56"),
            try ApplicationVersion(releaseTag: "v12.34.56")
        )
    }

    func testCanonicalLeadingVIsRequiredOnlyForReleaseTags() throws {
        XCTAssertEqual(
            try ApplicationVersion(releaseTag: "v0.1.1").description,
            "0.1.1"
        )
        XCTAssertThrowsError(
            try ApplicationVersion(releaseTag: "0.1.1")
        )
        XCTAssertThrowsError(
            try ApplicationVersion(installedVersionString: "v0.1.1")
        )
    }

    func testMalformedAndNonCanonicalVersionsAreRejected() {
        for value in [
            "", "1", "1.2", "1.2.3.4", "1..3", ".1.2", "1.2.",
            "01.2.3", "1.02.3", "1.2.03", "1.2.-3", "1.2.+3",
            "1.2.3-beta", "1.2.3 ", " 1.2.3", "١.٢.٣",
        ] {
            XCTAssertThrowsError(
                try ApplicationVersion(installedVersionString: value),
                "Expected \(value.debugDescription) to be rejected"
            )
        }
    }

    func testOverflowIsRejected() {
        XCTAssertThrowsError(
            try ApplicationVersion(
                releaseTag: "v18446744073709551616.0.0"
            )
        ) { error in
            XCTAssertEqual(error as? ApplicationVersionError, .overflow)
        }
    }

    func testReleaseURLValidationAcceptsOnlyExpectedGitHubTagPage() throws {
        let version = try ApplicationVersion(releaseTag: "v0.1.1")
        let expected = URL(
            string: "https://github.com/DPatrikI/voleq-community/releases/tag/v0.1.1"
        )!
        XCTAssertEqual(
            try ValidatedGitHubReleaseURL(url: expected, version: version).url,
            expected
        )

        for value in [
            "http://github.com/DPatrikI/voleq-community/releases/tag/v0.1.1",
            "https://example.com/DPatrikI/voleq-community/releases/tag/v0.1.1",
            "https://user@github.com/DPatrikI/voleq-community/releases/tag/v0.1.1",
            "https://github.com:443/DPatrikI/voleq-community/releases/tag/v0.1.1",
            "https://github.com/dpatriki/voleq-community/releases/tag/v0.1.1",
            "https://github.com/DPatrikI/voleq-community/releases/tag/v0.1.2",
            "https://github.com/DPatrikI/voleq-community/releases/tag/v0.1.1?download=1",
            "https://github.com/DPatrikI/voleq-community/releases/tag/v0.1.1#notes",
        ] {
            XCTAssertThrowsError(
                try ValidatedGitHubReleaseURL(
                    url: URL(string: value)!,
                    version: version
                ),
                "Expected \(value) to be rejected"
            )
        }
    }

    func testCommittedApplicationVersionSourceIsStrictAndUnchanged() throws {
        let communityDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = communityDirectory
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        let value = try XCTUnwrap(
            info[ApplicationVersion.bundleVersionKey] as? String
        )

        XCTAssertEqual(
            try ApplicationVersion(installedVersionString: value).description,
            "0.1.0"
        )
    }
}
