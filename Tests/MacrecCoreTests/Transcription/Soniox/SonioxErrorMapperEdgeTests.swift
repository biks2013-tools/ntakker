// Tests/MacrecCoreTests/Transcription/Soniox/SonioxErrorMapperEdgeTests.swift
//
// Plan-006 Phase D / Test-Build (soniox-error-paths): edge-case and
// augmentation coverage for `SonioxErrorMapper` beyond what
// `SonioxErrorMapperTests` already covers (401, 402, 503, close codes
// .normal and .internalServerError).
//
// New cases exercised here:
//   1. HTTP 400 → .malformedConfig  — message payload carried through
//   2. HTTP 408 → .idleTimeout
//   3. HTTP 429 → .rateLimited
//   4. HTTP 500 → .serverError      — message payload carried through
//   5. HTTP 418 (unknown)           → .serverError (default fallthrough)
//   6. Close code .policyViolation  → .connectionError(code: 1008, reason: nil)

import XCTest
@testable import MacrecCore

final class SonioxErrorMapperEdgeTests: XCTestCase {

    // MARK: - HTTP code mapping

    func test400MalformedConfigCarriesMessage() {
        // 400 errors should produce .malformedConfig with the server's
        // detail string preserved verbatim so the operator sees the
        // specific validation failure rather than a generic description.
        let message = "audio_format must be one of: pcm_s16le, auto"
        let result = SonioxErrorMapper.map(httpCode: 400, message: message)
        XCTAssertEqual(result, .malformedConfig(message),
                       "HTTP 400 must produce .malformedConfig carrying the server message")
    }

    func test408MapsToIdleTimeout() {
        // 408 — server closes the session when it receives no audio for
        // 20 s (per soniox-wire-schema.md §3.5). The mapper must produce
        // the dedicated .idleTimeout case, NOT .serverError.
        let result = SonioxErrorMapper.map(httpCode: 408, message: nil)
        XCTAssertEqual(result, .idleTimeout,
                       "HTTP 408 must produce .idleTimeout, not .serverError")
    }

    func test429MapsToRateLimited() {
        // 429 — too many concurrent sessions or per-second request
        // limit hit. Must map to the dedicated .rateLimited case.
        let result = SonioxErrorMapper.map(httpCode: 429, message: nil)
        XCTAssertEqual(result, .rateLimited,
                       "HTTP 429 must produce .rateLimited")
    }

    func test500ServerErrorCarriesMessage() {
        // 500 should produce .serverError with the message payload
        // carried through unchanged (nil is allowed; non-nil must pass).
        let message = "internal transcription engine fault"
        let result = SonioxErrorMapper.map(httpCode: 500, message: message)
        XCTAssertEqual(result, .serverError(message),
                       "HTTP 500 must produce .serverError carrying the server message")
    }

    func testUnknownHttpCodeFallsThrough() {
        // Any code not explicitly handled (e.g. 418 "I'm a teapot",
        // or a future Soniox extension code) must not crash or return
        // an unrelated case — the default fallthrough produces .serverError.
        let result = SonioxErrorMapper.map(httpCode: 418, message: nil)
        // Pattern-match rather than XCTAssertEqual because .serverError has
        // an associated value; we only care about the outer case shape here.
        if case .serverError = result {
            // pass — the unknown code fell through to .serverError as expected
        } else {
            XCTFail("Unknown HTTP code 418 must fall through to .serverError, got \(result)")
        }
    }

    // MARK: - WebSocket close-code mapping

    func testPolicyViolationCloseCodeProducesConnectionError1008() {
        // RFC 6455 close code 1008 (Policy Violation) is emitted when
        // the server decides the client violated an application-level rule
        // (e.g. sending audio before the config frame, or reusing a spent
        // session token). The mapper must surface this as
        // .connectionError(code: 1008, reason: nil) — not as .normal (nil).
        let result = SonioxErrorMapper.map(closeCode: .policyViolation)
        XCTAssertEqual(result, .connectionError(code: 1008, reason: nil),
                       "Close code .policyViolation (1008) must produce .connectionError(code: 1008, reason: nil)")
    }
}
