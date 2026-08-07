// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VolEqCommunityMac

final class GitHubReleaseCheckerTests: XCTestCase {
    func testValidNewerReleaseIsReturnedAndRequestIsConstrained() async throws {
        let client = StubUpdateHTTPClient(
            behavior: .response(
                response(
                    payload: payload(tag: "v0.1.10")
                )
            )
        )
        let checker = GitHubReleaseChecker(httpClient: client)
        let installed = try ApplicationVersion(installedVersionString: "0.1.9")

        let result = try await checker.check(for: installed)

        guard case let .updateAvailable(release) = result else {
            return XCTFail("Expected an available release")
        }
        XCTAssertEqual(release.version.description, "0.1.10")
        XCTAssertEqual(
            release.releaseURL.absoluteString,
            "https://github.com/DPatrikI/voleq-community/releases/tag/v0.1.10"
        )
        XCTAssertEqual(
            release.publicationDate,
            ISO8601DateFormatter().date(from: "2026-08-06T09:10:11Z")
        )

        let request = await client.lastRequest
        XCTAssertEqual(request?.url, GitHubReleaseChecker.endpoint)
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Accept"),
            "application/vnd.github+json"
        )
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "X-GitHub-Api-Version"),
            GitHubReleaseChecker.apiVersion
        )
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "User-Agent"),
            "VolEq-Community/0.1.9 (+https://github.com/DPatrikI/voleq-community)"
        )
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        let maximumResponseBytes = await client.lastMaximumResponseBytes
        XCTAssertEqual(
            maximumResponseBytes,
            GitHubReleaseChecker.maximumResponseBytes
        )
    }

    func testEqualAndOlderLatestReleasesAreUpToDate() async throws {
        for tag in ["v0.1.1", "v0.1.0"] {
            let client = StubUpdateHTTPClient(
                behavior: .response(response(payload: payload(tag: tag)))
            )
            let checker = GitHubReleaseChecker(httpClient: client)
            let installed = try ApplicationVersion(
                installedVersionString: "0.1.1"
            )

            let result = try await checker.check(for: installed)
            guard case .upToDate = result else {
                return XCTFail("Expected \(tag) not to be exposed as an update")
            }
        }
    }

    func testDraftPrereleaseAndMalformedPayloadsAreRejected() async throws {
        let cases: [Data] = [
            payload(tag: "v0.1.1", draft: true),
            payload(tag: "v0.1.1", prerelease: true),
            payload(tag: "0.1.1"),
            payload(tag: "v0.1.1-beta"),
            payload(tag: "v0.1.1", publishedAt: "not-a-date"),
            Data("{not json".utf8),
        ]

        for payload in cases {
            try await assertError(.invalidRelease, payload: payload)
        }
    }

    func testInvalidReleaseURLsAreRejected() async throws {
        for url in [
            "http://github.com/DPatrikI/voleq-community/releases/tag/v0.1.1",
            "https://example.com/DPatrikI/voleq-community/releases/tag/v0.1.1",
            "https://github.com/DPatrikI/other/releases/tag/v0.1.1",
            "https://github.com/DPatrikI/voleq-community/releases/tag/v0.1.2",
        ] {
            try await assertError(
                .invalidRelease,
                payload: payload(tag: "v0.1.1", htmlURL: url)
            )
        }
    }

    func testRedirectAndHTTPFailuresAreClassified() async throws {
        let cases: [(UpdateHTTPResponse, UpdateCheckError)] = [
            (
                response(
                    statusCode: 200,
                    url: URL(string: "https://api.github.com/redirected")!
                ),
                .unexpectedRedirect
            ),
            (response(statusCode: 302), .unexpectedRedirect),
            (response(statusCode: 404), .notFound),
            (response(statusCode: 403), .rateLimited),
            (response(statusCode: 429), .rateLimited),
            (response(statusCode: 500), .serverFailure(statusCode: 500)),
            (response(statusCode: 503), .serverFailure(statusCode: 503)),
        ]

        for (response, expectedError) in cases {
            let checker = GitHubReleaseChecker(
                httpClient: StubUpdateHTTPClient(
                    behavior: .response(response)
                )
            )
            do {
                _ = try await checker.check(
                    for: ApplicationVersion(installedVersionString: "0.1.0")
                )
                XCTFail("Expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? UpdateCheckError, expectedError)
            }
        }
    }

    func testHTTPFailureClassificationDoesNotDependOnJSONContentType() async throws {
        let cases: [(Int, UpdateCheckError)] = [
            (403, .rateLimited),
            (404, .notFound),
            (503, .serverFailure(statusCode: 503)),
        ]

        for (statusCode, expectedError) in cases {
            let checker = GitHubReleaseChecker(
                httpClient: StubUpdateHTTPClient(
                    behavior: .response(
                        response(
                            statusCode: statusCode,
                            mimeType: "text/html"
                        )
                    )
                )
            )
            do {
                _ = try await checker.check(
                    for: ApplicationVersion(installedVersionString: "0.1.0")
                )
                XCTFail("Expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? UpdateCheckError, expectedError)
            }
        }
    }

    func testTimeoutCancellationAndOfflineFailuresAreClassified() async throws {
        let cases: [(StubUpdateHTTPClient.Behavior, UpdateCheckError)] = [
            (.error(URLError(.timedOut)), .timedOut),
            (.error(URLError(.notConnectedToInternet)), .offline),
            (.error(URLError(.networkConnectionLost)), .offline),
            (.cancelled, .cancelled),
        ]

        for (behavior, expectedError) in cases {
            let checker = GitHubReleaseChecker(
                httpClient: StubUpdateHTTPClient(behavior: behavior)
            )
            do {
                _ = try await checker.check(
                    for: ApplicationVersion(installedVersionString: "0.1.0")
                )
                XCTFail("Expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? UpdateCheckError, expectedError)
            }
        }
    }

    func testOversizedResponsesAreRejectedEvenForInjectedClients() async throws {
        let oversized = Data(
            repeating: 0,
            count: GitHubReleaseChecker.maximumResponseBytes + 1
        )
        let checker = GitHubReleaseChecker(
            httpClient: StubUpdateHTTPClient(
                behavior: .response(response(payload: oversized))
            )
        )

        do {
            _ = try await checker.check(
                for: ApplicationVersion(installedVersionString: "0.1.0")
            )
            XCTFail("Expected oversized response failure")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .responseTooLarge)
        }
    }

    func testNonJSONContentTypeIsRejected() async throws {
        let checker = GitHubReleaseChecker(
            httpClient: StubUpdateHTTPClient(
                behavior: .response(
                    response(mimeType: "text/html")
                )
            )
        )

        do {
            _ = try await checker.check(
                for: ApplicationVersion(installedVersionString: "0.1.0")
            )
            XCTFail("Expected a non-JSON response failure")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .invalidResponse)
        }
    }

    func testEphemeralConfigurationDisablesPersistentNetworkStores() {
        let configuration = EphemeralUpdateHTTPClient.makeConfiguration()

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 8)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 10)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 1)
    }

    func testProductionDelegateRejectsRedirectBeforeFollowingIt() async {
        let delegate = BoundedSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: GitHubReleaseChecker.endpoint)
        let redirectResponse = HTTPURLResponse(
            url: GitHubReleaseChecker.endpoint,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://example.com/update"]
        )!
        let redirectedRequest = URLRequest(
            url: URL(string: "https://example.com/update")!
        )

        do {
            _ = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UpdateHTTPResponse, Error>) in
                delegate.register(
                    task: task,
                    maximumResponseBytes: 64,
                    continuation: continuation
                )
                delegate.urlSession(
                    session,
                    task: task,
                    willPerformHTTPRedirection: redirectResponse,
                    newRequest: redirectedRequest
                ) { followedRequest in
                    XCTAssertNil(followedRequest)
                }
                delegate.urlSession(session, task: task, didCompleteWithError: nil)
            }
            XCTFail("Expected redirect rejection")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .unexpectedRedirect)
        }
        session.invalidateAndCancel()
    }

    func testProductionDelegateRejectsDeclaredAndStreamedOversizedBodies() async {
        await assertProductionDelegateSizeFailure(
            expectedContentLength: 65,
            chunks: []
        )
        await assertProductionDelegateSizeFailure(
            expectedContentLength: -1,
            chunks: [Data(repeating: 1, count: 40), Data(repeating: 2, count: 25)]
        )
    }

    private func assertError(
        _ expectedError: UpdateCheckError,
        payload: Data
    ) async throws {
        let checker = GitHubReleaseChecker(
            httpClient: StubUpdateHTTPClient(
                behavior: .response(response(payload: payload))
            )
        )
        do {
            _ = try await checker.check(
                for: ApplicationVersion(installedVersionString: "0.1.0")
            )
            XCTFail("Expected \(expectedError)")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, expectedError)
        }
    }

    private func assertProductionDelegateSizeFailure(
        expectedContentLength: Int64,
        chunks: [Data]
    ) async {
        let delegate = BoundedSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: GitHubReleaseChecker.endpoint)
        let response = HTTPURLResponse(
            url: GitHubReleaseChecker.endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": "\(expectedContentLength)",
            ]
        )!

        do {
            _ = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UpdateHTTPResponse, Error>) in
                delegate.register(
                    task: task,
                    maximumResponseBytes: 64,
                    continuation: continuation
                )
                delegate.urlSession(
                    session,
                    dataTask: task,
                    didReceive: response
                ) { disposition in
                    let expected: URLSession.ResponseDisposition = expectedContentLength > 64
                        ? .cancel
                        : .allow
                    XCTAssertEqual(disposition, expected)
                }
                for chunk in chunks {
                    delegate.urlSession(session, dataTask: task, didReceive: chunk)
                }
                delegate.urlSession(session, task: task, didCompleteWithError: nil)
            }
            XCTFail("Expected bounded response rejection")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .responseTooLarge)
        }
        session.invalidateAndCancel()
    }

    private func response(
        statusCode: Int = 200,
        url: URL? = GitHubReleaseChecker.endpoint,
        mimeType: String? = "application/json",
        payload: Data? = nil
    ) -> UpdateHTTPResponse {
        UpdateHTTPResponse(
            data: payload ?? self.payload(tag: "v0.1.1"),
            statusCode: statusCode,
            url: url,
            mimeType: mimeType
        )
    }

    private func payload(
        tag: String,
        htmlURL: String? = nil,
        publishedAt: String = "2026-08-06T09:10:11Z",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> Data {
        let releaseURL = htmlURL
            ?? "https://github.com/DPatrikI/voleq-community/releases/tag/\(tag)"
        return try! JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "html_url": releaseURL,
            "published_at": publishedAt,
            "draft": draft,
            "prerelease": prerelease,
        ])
    }
}

private actor StubUpdateHTTPClient: UpdateHTTPClient {
    enum Behavior: @unchecked Sendable {
        case response(UpdateHTTPResponse)
        case error(Error)
        case cancelled
    }

    let behavior: Behavior
    private(set) var lastRequest: URLRequest?
    private(set) var lastMaximumResponseBytes: Int?

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> UpdateHTTPResponse {
        lastRequest = request
        lastMaximumResponseBytes = maximumResponseBytes
        switch behavior {
        case let .response(response):
            return response
        case let .error(error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }
}
