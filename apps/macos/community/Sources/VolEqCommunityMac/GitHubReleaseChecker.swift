// SPDX-License-Identifier: MPL-2.0

import Foundation

struct UpdateHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let url: URL?
    let mimeType: String?
}

protocol UpdateHTTPClient: Sendable {
    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> UpdateHTTPResponse
}

struct GitHubReleaseChecker: UpdateChecking, Sendable {
    static let endpoint = URL(
        string: "https://api.github.com/repos/DPatrikI/voleq-community/releases/latest"
    )!
    static let maximumResponseBytes = 128 * 1_024
    static let apiVersion = "2026-03-10"

    private let httpClient: any UpdateHTTPClient

    init(httpClient: any UpdateHTTPClient) {
        self.httpClient = httpClient
    }

    func check(for installedVersion: ApplicationVersion) async throws -> UpdateCheckResult {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(
            "VolEq-Community/\(installedVersion) (+https://github.com/DPatrikI/voleq-community)",
            forHTTPHeaderField: "User-Agent"
        )

        let response: UpdateHTTPResponse
        do {
            response = try await httpClient.send(
                request,
                maximumResponseBytes: Self.maximumResponseBytes
            )
        } catch is CancellationError {
            throw UpdateCheckError.cancelled
        } catch let error as UpdateCheckError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        } catch {
            throw UpdateCheckError.invalidResponse
        }

        guard response.url == Self.endpoint else {
            throw UpdateCheckError.unexpectedRedirect
        }
        guard response.data.count <= Self.maximumResponseBytes else {
            throw UpdateCheckError.responseTooLarge
        }

        switch response.statusCode {
        case 200:
            break
        case 403, 429:
            throw UpdateCheckError.rateLimited
        case 404:
            throw UpdateCheckError.notFound
        case 500 ... 599:
            throw UpdateCheckError.serverFailure(statusCode: response.statusCode)
        case 300 ... 399:
            throw UpdateCheckError.unexpectedRedirect
        default:
            throw UpdateCheckError.invalidResponse
        }

        guard response.mimeType?.lowercased() == "application/json" else {
            throw UpdateCheckError.invalidResponse
        }

        let payload: LatestReleasePayload
        do {
            payload = try JSONDecoder().decode(
                LatestReleasePayload.self,
                from: response.data
            )
        } catch {
            throw UpdateCheckError.invalidRelease
        }

        guard !payload.draft, !payload.prerelease,
              let publicationDate = ISO8601DateFormatter().date(
                  from: payload.publishedAt
              )
        else {
            throw UpdateCheckError.invalidRelease
        }

        let releaseVersion: ApplicationVersion
        let releaseURL: ValidatedGitHubReleaseURL
        do {
            releaseVersion = try ApplicationVersion(releaseTag: payload.tagName)
            guard let url = URL(string: payload.htmlURL) else {
                throw AvailableReleaseError.invalidReleaseURL
            }
            releaseURL = try ValidatedGitHubReleaseURL(
                url: url,
                version: releaseVersion
            )
        } catch {
            throw UpdateCheckError.invalidRelease
        }

        guard releaseVersion > installedVersion else {
            return .upToDate(latestVersion: releaseVersion)
        }
        return .updateAvailable(
            AvailableRelease(
                version: releaseVersion,
                validatedReleaseURL: releaseURL,
                publicationDate: publicationDate
            )
        )
    }

    private static func map(_ error: URLError) -> UpdateCheckError {
        switch error.code {
        case .cancelled:
            .cancelled
        case .timedOut:
            .timedOut
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .dataNotAllowed:
            .offline
        default:
            .invalidResponse
        }
    }
}

private struct LatestReleasePayload: Decodable {
    let tagName: String
    let htmlURL: String
    let publishedAt: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case draft
        case prerelease
    }
}

final class EphemeralUpdateHTTPClient: UpdateHTTPClient, @unchecked Sendable {
    private let delegate: BoundedSessionDelegate
    private let session: URLSession

    init(configuration: URLSessionConfiguration = makeConfiguration()) {
        delegate = BoundedSessionDelegate()
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> UpdateHTTPResponse {
        let taskBox = UpdateDataTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                taskBox.store(task)
                delegate.register(
                    task: task,
                    maximumResponseBytes: maximumResponseBytes,
                    continuation: continuation
                )
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }
}

private final class UpdateDataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?

    func store(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

final class BoundedSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class RequestState {
        let maximumResponseBytes: Int
        let continuation: CheckedContinuation<UpdateHTTPResponse, Error>
        var data = Data()
        var response: HTTPURLResponse?
        var failure: Error?

        init(
            maximumResponseBytes: Int,
            continuation: CheckedContinuation<UpdateHTTPResponse, Error>
        ) {
            self.maximumResponseBytes = maximumResponseBytes
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var states: [Int: RequestState] = [:]

    func register(
        task: URLSessionDataTask,
        maximumResponseBytes: Int,
        continuation: CheckedContinuation<UpdateHTTPResponse, Error>
    ) {
        lock.lock()
        states[task.taskIdentifier] = RequestState(
            maximumResponseBytes: maximumResponseBytes,
            continuation: continuation
        )
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        states[task.taskIdentifier]?.failure = UpdateCheckError.unexpectedRedirect
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard let state = states[dataTask.taskIdentifier],
              let response = response as? HTTPURLResponse
        else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }

        state.response = response
        let expectedLength = response.expectedContentLength
        if expectedLength > Int64(state.maximumResponseBytes) {
            state.failure = UpdateCheckError.responseTooLarge
            lock.unlock()
            completionHandler(.cancel)
        } else {
            lock.unlock()
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard let state = states[dataTask.taskIdentifier], state.failure == nil else {
            lock.unlock()
            return
        }
        guard state.data.count <= state.maximumResponseBytes - data.count else {
            state.failure = UpdateCheckError.responseTooLarge
            lock.unlock()
            dataTask.cancel()
            return
        }
        state.data.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        guard let state else { return }
        if let failure = state.failure {
            state.continuation.resume(throwing: failure)
        } else if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(
                returning: UpdateHTTPResponse(
                    data: state.data,
                    statusCode: response.statusCode,
                    url: response.url,
                    mimeType: response.mimeType
                )
            )
        } else {
            state.continuation.resume(throwing: UpdateCheckError.invalidResponse)
        }
    }
}
