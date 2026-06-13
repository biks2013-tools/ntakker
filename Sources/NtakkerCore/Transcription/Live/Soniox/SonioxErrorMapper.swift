// Sources/NtakkerCore/Transcription/Live/Soniox/SonioxErrorMapper.swift
//
// Plan-006 Phase D / Unit D1: typed Soniox streaming errors plus a
// pure-function mapper that translates Soniox HTTP-style status codes
// (delivered as in-band JSON `error_code`) and WebSocket close codes
// into them.
//
// The error type is `Equatable` and `Sendable` so it can flow through
// `StreamingTranscriptionEvent.error(detail:)` (currently a String)
// and also be matched in tests. The associated value for
// `audioPipelineFailure` is intentionally a `String` (not an `Error`)
// to keep the enum `Equatable`.

import Foundation

public enum SonioxStreamingError: Error, LocalizedError, Sendable, Equatable {

    /// HTTP 401 — invalid / expired API key.
    case invalidApiKey

    /// HTTP 402 — account quota exceeded.
    case quotaExceeded

    /// HTTP 408 — server idle timeout (no audio for 20 s).
    case idleTimeout

    /// HTTP 429 — too many concurrent sessions / rate limit.
    case rateLimited

    /// HTTP 400 — malformed config message; optional server detail.
    case malformedConfig(String?)

    /// HTTP 500 — generic server error; optional server detail.
    case serverError(String?)

    /// HTTP 503 — server told us to reconnect (terminated).
    case terminatedReconnect

    /// Local audio capture / downsample pipeline failure. `String`
    /// (not `Error`) so the enum stays `Equatable`.
    case audioPipelineFailure(String)

    /// Server sent something we couldn't parse / didn't expect.
    case unexpectedServerMessage(String)

    /// WebSocket connection closed with a non-normal code.
    case connectionError(code: Int, reason: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidApiKey:
            return "Soniox: invalid or expired API key (401)."
        case .quotaExceeded:
            return "Soniox: account quota exceeded (402)."
        case .idleTimeout:
            return "Soniox: server idle timeout — no audio received (408)."
        case .rateLimited:
            return "Soniox: rate limited / too many concurrent sessions (429)."
        case .malformedConfig(let detail):
            return "Soniox: malformed config (400)\(detail.map { " — \($0)" } ?? "")."
        case .serverError(let detail):
            return "Soniox: server error (500)\(detail.map { " — \($0)" } ?? "")."
        case .terminatedReconnect:
            return "Soniox: server terminated session, reconnect required (503)."
        case .audioPipelineFailure(let detail):
            return "Soniox: local audio pipeline failure — \(detail)."
        case .unexpectedServerMessage(let detail):
            return "Soniox: unexpected server message — \(detail)."
        case .connectionError(let code, let reason):
            return "Soniox: WebSocket closed with code \(code)\(reason.map { " — \($0)" } ?? "")."
        }
    }
}

public enum SonioxErrorMapper {

    /// Map a Soniox `error_code` (HTTP-style integer) to a typed error.
    /// Unknown codes fall through to `.serverError(message)`.
    public static func map(httpCode: Int, message: String?) -> SonioxStreamingError {
        switch httpCode {
        case 400: return .malformedConfig(message)
        case 401: return .invalidApiKey
        case 402: return .quotaExceeded
        case 408: return .idleTimeout
        case 429: return .rateLimited
        case 500: return .serverError(message)
        case 503: return .terminatedReconnect
        default:  return .serverError(message)
        }
    }

    /// Map a WebSocket close code to a typed error. `.normal` returns
    /// `nil` (clean shutdown is not an error).
    public static func map(closeCode: WebSocketTransportCloseCode) -> SonioxStreamingError? {
        switch closeCode {
        case .normal:
            return nil
        default:
            return .connectionError(code: closeCode.rawCode, reason: nil)
        }
    }
}
