// SPDX-License-Identifier: MPL-2.0

import Foundation

struct ApplicationVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    static let bundleVersionKey = "CFBundleShortVersionString"
    static let zero = Self(major: 0, minor: 0, patch: 0)

    let major: UInt64
    let minor: UInt64
    let patch: UInt64

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    var releaseTag: String {
        "v\(description)"
    }

    init(installedVersionString: String) throws {
        self = try Self.parse(installedVersionString, requiresLeadingV: false)
    }

    init(releaseTag: String) throws {
        self = try Self.parse(releaseTag, requiresLeadingV: true)
    }

    init(bundle: Bundle) throws {
        guard let value = bundle.object(
            forInfoDictionaryKey: Self.bundleVersionKey
        ) as? String else {
            throw ApplicationVersionError.missingBundleVersion
        }
        try self.init(installedVersionString: value)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private init(major: UInt64, minor: UInt64, patch: UInt64) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    private static func parse(
        _ value: String,
        requiresLeadingV: Bool
    ) throws -> Self {
        let versionString: Substring
        if requiresLeadingV {
            guard value.first == "v" else {
                throw ApplicationVersionError.invalidFormat
            }
            versionString = value.dropFirst()
        } else {
            guard value.first != "v" else {
                throw ApplicationVersionError.invalidFormat
            }
            versionString = value[...]
        }

        let components = versionString.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else {
            throw ApplicationVersionError.invalidFormat
        }

        let numbers = try components.map { component -> UInt64 in
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  component == "0" || component.first != "0"
            else {
                throw ApplicationVersionError.invalidFormat
            }
            guard let number = UInt64(component) else {
                throw ApplicationVersionError.overflow
            }
            return number
        }

        return Self(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }
}

enum ApplicationVersionError: Error, Equatable, Sendable {
    case missingBundleVersion
    case invalidFormat
    case overflow
}

struct ValidatedGitHubReleaseURL: Equatable, Sendable {
    let url: URL

    init(url: URL, version: ApplicationVersion) throws {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
            components.scheme == "https",
            components.host?.lowercased() == "github.com",
            components.port == nil,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.percentEncodedPath
                == "/DPatrikI/voleq-community/releases/tag/\(version.releaseTag)"
        else {
            throw AvailableReleaseError.invalidReleaseURL
        }
        self.url = url
    }

    static func canonical(for version: ApplicationVersion) -> Self {
        // The version parser permits only ASCII decimal components, so this
        // fixed-origin URL cannot contain credentials, escapes, or traversal.
        let url = URL(
            string: "https://github.com/DPatrikI/voleq-community/releases/tag/\(version.releaseTag)"
        )!
        return try! Self(url: url, version: version)
    }
}

struct AvailableRelease: Equatable, Sendable {
    let version: ApplicationVersion
    let releaseURL: URL
    let publicationDate: Date

    init(
        version: ApplicationVersion,
        validatedReleaseURL: ValidatedGitHubReleaseURL,
        publicationDate: Date
    ) {
        self.version = version
        releaseURL = validatedReleaseURL.url
        self.publicationDate = publicationDate
    }
}

enum AvailableReleaseError: Error, Equatable, Sendable {
    case invalidReleaseURL
}

enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(latestVersion: ApplicationVersion)
    case updateAvailable(AvailableRelease)
}

protocol UpdateChecking: Sendable {
    func check(for installedVersion: ApplicationVersion) async throws -> UpdateCheckResult
}

struct UnavailableUpdateChecker: UpdateChecking, Sendable {
    func check(for installedVersion: ApplicationVersion) async throws -> UpdateCheckResult {
        throw UpdateCheckError.invalidResponse
    }
}

enum UpdateCheckError: LocalizedError, Equatable, Sendable {
    case cancelled
    case offline
    case timedOut
    case rateLimited
    case notFound
    case serverFailure(statusCode: Int)
    case unexpectedRedirect
    case responseTooLarge
    case invalidResponse
    case invalidRelease

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "The update check was cancelled."
        case .offline:
            "VolEq couldn’t reach GitHub. Check your internet connection and try again."
        case .timedOut:
            "GitHub didn’t respond in time. Try again."
        case .rateLimited:
            "GitHub temporarily limited update checks. Please try again later."
        case .notFound:
            "GitHub’s latest VolEq release could not be found. Try again later."
        case let .serverFailure(statusCode):
            "GitHub returned a server error (\(statusCode)). Try again later."
        case .unexpectedRedirect:
            "GitHub returned an unexpected redirect, so VolEq stopped the check."
        case .responseTooLarge:
            "GitHub returned more update information than VolEq accepts."
        case .invalidResponse, .invalidRelease:
            "GitHub returned update information VolEq couldn’t verify."
        }
    }
}
