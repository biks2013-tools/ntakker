// NtakkerCore/Transcription/Net/HTTPRetryPolicy.swift
//
// EVAL-2026-06-12 F31 + EVAL-2026-10-16 TR-16 (plan-023 T1): the one
// retry loop for the REST batch providers (Azure batch, ElevenLabs,
// Gemini). Each used to carry its own copy — same attempt count, same
// jitter band, same transient-error set — and the copies had drifted:
// only Azure honoured `Retry-After`, and it did so without a cap, so
// one 429 asking for minutes held a transcription slot that long.
//
// The policy sends a request, retries retryable HTTP statuses and
// transient `URLError`s with exponential backoff and ±20 % jitter, and
// returns the final response — success or not — for the provider to
// map. A transport error that is not transient, or is still failing on
// the last attempt, is rethrown as the `URLError` so the provider can
// map it to its own error type.

import Foundation
import Logging

public struct HTTPRetryPolicy: Sendable {

    /// The response was not an `HTTPURLResponse`.
    public struct NonHTTPResponse: Error, Sendable {}

    /// `URLError` codes worth another attempt.
    public static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .dnsLookupFailed, .cannotConnectToHost,
    ]

    /// TR-16: the longest `Retry-After` honoured, in seconds. A server
    /// asking for longer gets this; the chunk then fails rather than
    /// holding its slot.
    public static let maxRetryAfterSeconds: Double = 30

    /// Label used in log lines (`"azure"`, `"gemini"`, …).
    public let label: String
    public let maxAttempts: Int
    public let retryableStatuses: Set<Int>
    /// Backoff before attempt n+1 is `baseDelay · 2ⁿ⁻¹`, ±20 %.
    public let baseDelay: Double
    public let honoursRetryAfter: Bool
    /// Return false to hand a retryable status back without retrying
    /// (ElevenLabs' `concurrent_limit_exceeded` 429).
    public let shouldRetry: @Sendable (HTTPURLResponse, Data) -> Bool

    public init(
        label: String,
        maxAttempts: Int = 3,
        retryableStatuses: Set<Int>,
        baseDelay: Double = 1,
        honoursRetryAfter: Bool = true,
        shouldRetry: @escaping @Sendable (HTTPURLResponse, Data) -> Bool = { _, _ in true }
    ) {
        precondition(maxAttempts >= 1, "maxAttempts must be >= 1")
        self.label = label
        self.maxAttempts = maxAttempts
        self.retryableStatuses = retryableStatuses
        self.baseDelay = baseDelay
        self.honoursRetryAfter = honoursRetryAfter
        self.shouldRetry = shouldRetry
    }

    /// Seconds to wait before attempt `attempt + 1`.
    public func delay(afterAttempt attempt: Int, retryAfter: String?) -> Double {
        if honoursRetryAfter, let retryAfter, let seconds = Double(retryAfter), seconds >= 0 {
            return min(seconds, Self.maxRetryAfterSeconds)
        }
        return baseDelay * pow(2, Double(attempt - 1)) * Double.random(in: 0.8...1.2)
    }

    /// Send `request` with retries. Returns the last response, which
    /// may be a non-2xx status; throws `NonHTTPResponse` or the final
    /// `URLError` / other transport error.
    public func send(
        _ request: URLRequest,
        session: URLSession,
        logger: Logger,
        sleep: @Sendable (Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw NonHTTPResponse() }
                if retryableStatuses.contains(http.statusCode),
                   attempt < maxAttempts,
                   shouldRetry(http, data) {
                    let wait = delay(afterAttempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                    logger.warning("\(label): HTTP \(http.statusCode); retry \(attempt)/\(maxAttempts) after \(String(format: "%.2f", wait))s")
                    await sleep(wait)
                    continue
                }
                return (data, http)
            } catch let error as URLError
                where Self.transientURLErrorCodes.contains(error.code) && attempt < maxAttempts {
                let wait = delay(afterAttempt: attempt, retryAfter: nil)
                logger.warning("\(label): URLError \(error.code.rawValue); retry \(attempt)/\(maxAttempts) after \(String(format: "%.2f", wait))s")
                await sleep(wait)
            }
        }
    }
}
