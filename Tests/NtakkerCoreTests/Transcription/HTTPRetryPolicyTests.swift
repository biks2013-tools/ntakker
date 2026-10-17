import Foundation
import Logging
import Testing
@testable import NtakkerCore

/// EVAL-2026-06-12 F31 + EVAL-2026-10-16 TR-16 (plan-023 T1).
@Suite("HTTPRetryPolicy", .serialized)
struct HTTPRetryPolicyTests {

    /// Answers each request with the next scripted result.
    final class ScriptedProtocol: URLProtocol, @unchecked Sendable {
        enum Step { case status(Int, [String: String]), urlError(URLError.Code) }
        nonisolated(unsafe) static var steps: [Step] = []
        nonisolated(unsafe) static var requests = 0

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let step = Self.steps.isEmpty ? .status(200, [:]) : Self.steps.removeFirst()
            Self.requests += 1
            switch step {
            case .status(let code, let headers):
                let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8))
                client?.urlProtocolDidFinishLoading(self)
            case .urlError(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        }
        override func stopLoading() {}
    }

    private let request = URLRequest(url: URL(string: "https://retry.test/x")!)
    private let logger = Logger(label: "test")

    private func session(_ steps: [ScriptedProtocol.Step]) -> URLSession {
        ScriptedProtocol.steps = steps
        ScriptedProtocol.requests = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProtocol.self]
        return URLSession(configuration: config)
    }

    private final class Sleeps: @unchecked Sendable {
        var values: [Double] = []
    }

    @Test("retries a retryable status, then returns the success")
    func retriesThenSucceeds() async throws {
        let policy = HTTPRetryPolicy(label: "t", retryableStatuses: [503])
        let sleeps = Sleeps()
        let (_, http) = try await policy.send(request, session: session([.status(503, [:]), .status(200, [:])]),
                                              logger: logger, sleep: { sleeps.values.append($0) })
        #expect(http.statusCode == 200)
        #expect(ScriptedProtocol.requests == 2)
        #expect(sleeps.values.count == 1 && sleeps.values[0] >= 0.8 && sleeps.values[0] <= 1.2)
    }

    @Test("gives up after maxAttempts and returns the last response")
    func exhausts() async throws {
        let policy = HTTPRetryPolicy(label: "t", retryableStatuses: [500])
        let (_, http) = try await policy.send(request, session: session(Array(repeating: .status(500, [:]), count: 5)),
                                              logger: logger, sleep: { _ in })
        #expect(http.statusCode == 500)
        #expect(ScriptedProtocol.requests == 3)
    }

    @Test("Retry-After is honoured but capped (TR-16)")
    func retryAfterCapped() async throws {
        let policy = HTTPRetryPolicy(label: "t", retryableStatuses: [429])
        let sleeps = Sleeps()
        _ = try await policy.send(request, session: session([.status(429, ["Retry-After": "600"]), .status(200, [:])]),
                                  logger: logger, sleep: { sleeps.values.append($0) })
        #expect(sleeps.values == [HTTPRetryPolicy.maxRetryAfterSeconds])
    }

    @Test("shouldRetry can veto a retryable status")
    func veto() async throws {
        let policy = HTTPRetryPolicy(label: "t", retryableStatuses: [429], shouldRetry: { _, _ in false })
        let (_, http) = try await policy.send(request, session: session([.status(429, [:]), .status(200, [:])]),
                                              logger: logger, sleep: { _ in })
        #expect(http.statusCode == 429)
        #expect(ScriptedProtocol.requests == 1)
    }

    @Test("transient URLErrors are retried; others are thrown at once")
    func urlErrors() async throws {
        let policy = HTTPRetryPolicy(label: "t", retryableStatuses: [])
        let (_, http) = try await policy.send(request, session: session([.urlError(.timedOut), .status(200, [:])]),
                                              logger: logger, sleep: { _ in })
        #expect(http.statusCode == 200)

        await #expect(throws: URLError.self) {
            _ = try await policy.send(request, session: session([.urlError(.badURL), .status(200, [:])]),
                                      logger: logger, sleep: { _ in })
        }
        #expect(ScriptedProtocol.requests == 1)
    }
}
