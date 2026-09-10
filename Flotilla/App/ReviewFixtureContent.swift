import Foundation

/// File bodies for the `UI_TESTING_SIMULATE_REVIEW_SESSION` review fixture,
/// kept out of ``AppEnvironment`` so the seeding logic there stays readable.
///
/// The committed/working pairs are hand-tuned to produce a useful spread in
/// the review window: multi-hunk modifications, an added file, a deleted
/// file, a rename, nested directories, and at least one line long enough to
/// wrap in a Side by Side column.
enum ReviewFixture {

    // MARK: - Uploader.swift  (multi-hunk rewrite, carries the over-long line)

    static let committedUploader = """
    import Foundation

    struct Uploader {
        let session: Session
        let transport: Transport

        func upload(_ chunk: Chunk) {
            legacyUpload(chunk)
        }

        private func legacyUpload(_ chunk: Chunk) {
            // Best-effort: one attempt, no retry, failures are swallowed.
            transport.send(chunk)
        }
    }
    """

    static let workingUploader = """
    import Foundation
    import OSLog

    struct Uploader {
        let session: Session
        let transport: Transport
        let policy: RetryPolicy

        func upload(_ chunk: Chunk) async throws {
            var attempt = 0
            while true {
                do {
                    try await send(chunk, attempt: attempt)
                    return
                } catch {
                    attempt += 1
                    guard policy.shouldRetry(attempt) else { throw error }
                    try await Task.sleep(for: policy.backoff(attempt))
                }
            }
        }

        private func send(_ chunk: Chunk, attempt: Int) async throws {
            let endpoint = URL(string: "https://uploads.example.com/v3/sessions/\\(session.id)/chunks/\\(chunk.index)?checksum=\\(chunk.sha256)&attempt=\\(attempt)&compression=zstd&clientVersion=\\(session.clientVersion)&trace=\\(session.traceID)")!
            try await transport.send(chunk, to: endpoint)
        }
    }
    """

    // MARK: - HTTPClient.swift  (two separated edits -> two hunks)

    static let committedHTTPClient = """
    import Foundation

    final class HTTPClient {
        private let session: URLSession

        init(session: URLSession = .shared) {
            self.session = session
        }

        func send(_ request: URLRequest) async throws -> Data {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.nonHTTPResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw HTTPError.status(http.statusCode)
            }
            return data
        }
    }
    """

    static let workingHTTPClient = """
    import Foundation

    final class HTTPClient {
        private let session: URLSession

        init(session: URLSession = .shared, timeout: TimeInterval = 30) {
            let configuration = session.configuration
            configuration.timeoutIntervalForRequest = timeout
            self.session = URLSession(configuration: configuration)
        }

        func send(_ request: URLRequest) async throws -> Data {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.nonHTTPResponse
            }
            if http.statusCode == 429, let retryAfter = http.value(forHTTPHeaderField: "Retry-After") {
                throw HTTPError.rateLimited(seconds: Double(retryAfter) ?? 1)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw HTTPError.status(http.statusCode)
            }
            return data
        }
    }
    """

    // MARK: - UploadTask.swift  (deleted in the working tree)

    static let committedUploadTask = """
    import Foundation

    /// Superseded by `Uploader.upload(_:)`, which now drives retries directly.
    struct UploadTask {
        let chunk: Chunk
        var attempts: Int = 0

        mutating func recordAttempt() {
            attempts += 1
        }
    }
    """

    // MARK: - UploadChunk.swift -> Chunk.swift  (renamed, with edits)

    static let committedUploadChunk = """
    import Foundation

    struct UploadChunk {
        let index: Int
        let data: Data

        var sha256: String { data.sha256Hex }
    }
    """

    static let workingChunk = """
    import Foundation
    import CryptoKit

    struct Chunk {
        let index: Int
        let data: Data

        var sha256: String { data.sha256Hex }
        var byteCount: Int { data.count }
    }
    """

    // MARK: - Tests/UploaderTests.swift  (adds a test with a long line)

    static let committedTests = """
    import XCTest
    @testable import Uploader

    final class UploaderTests: XCTestCase {
        func testLegacyUploadSendsChunkOnce() {
            let transport = SpyTransport()
            let uploader = Uploader(session: .stub, transport: transport)
            uploader.upload(.stub)
            XCTAssertEqual(transport.sent.count, 1)
        }
    }
    """

    static let workingTests = """
    import XCTest
    @testable import Uploader

    final class UploaderTests: XCTestCase {
        func testLegacyUploadSendsChunkOnce() {
            let transport = SpyTransport()
            let uploader = Uploader(session: .stub, transport: transport)
            try? uploader.upload(.stub)
            XCTAssertEqual(transport.sent.count, 1)
        }

        func testRetriesUntilThePolicyGivesUp() async {
            let transport = SpyTransport(failuresBeforeSuccess: .max)
            let uploader = Uploader(session: .stub, policy: RetryPolicy(maxAttempts: 4), transport: transport)
            await XCTAssertThrowsErrorAsync(try await uploader.upload(.stub), "the uploader should stop once RetryPolicy no longer permits an attempt and re-throw the final transport error to its caller unchanged")
            XCTAssertEqual(transport.attempts, 4)
        }
    }
    """

    // MARK: - RetryPolicy.swift  (new, untracked -> added)

    static let workingRetryPolicy = """
    import Foundation

    /// Decides whether another upload attempt is worth making, and how long to
    /// wait first. Exponential backoff with full jitter, capped.
    struct RetryPolicy {
        var maxAttempts: Int = 6
        var baseDelay: Duration = .milliseconds(200)
        var maxDelay: Duration = .seconds(20)

        func shouldRetry(_ attempt: Int) -> Bool {
            attempt < maxAttempts
        }

        func backoff(_ attempt: Int) -> Duration {
            let exponent = Double(max(0, attempt - 1))
            let exponential = baseDelay * Int(pow(2.0, exponent))
            let capped = min(exponential, maxDelay)
            // Full jitter: wait a random amount anywhere between zero and the capped exponential delay, which spreads a thundering herd of retrying clients evenly across the window instead of synchronising them.
            return capped * Double.random(in: 0...1)
        }
    }
    """
}
