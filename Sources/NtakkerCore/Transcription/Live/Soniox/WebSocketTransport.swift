// NtakkerCore/Transcription/Live/Soniox/WebSocketTransport.swift —
// see docs/design/plan-006-soniox-streaming.md §4.8 + §11 Phase C
// (Task C.5) and docs/design/project-design.md §SX-4 / §SX-13 (C↔D
// interface contract).
//
// Test-seam protocol that abstracts `URLSessionWebSocketTask` so the
// `SonioxStreamingSession` (Unit D) can be exercised against a
// scripted in-memory mock. `URLSessionWebSocketTask` cannot be
// intercepted via `URLProtocol` (per the codebase scan §4.1.K and
// research/websocket-asyncstream-pattern.md "Why URLProtocol Does
// Not Work for WebSocket Tests"), so dependency injection via this
// protocol is the only viable route to deterministic unit tests.
//
// The protocol shape is the SX-4 design (six methods including a
// dedicated `messages()` AsyncThrowingStream and split text/binary
// `send(...)` overloads) — richer than the four-method shape sketched
// in plan-006 §4.8 because:
//   * `send(text:)` / `send(data:)` make the call sites in the session
//     read more directly (config = text, audio = binary) without a
//     wrapping enum at every call site.
//   * `messages()` lets the session use a `for try await` loop instead
//     of an explicit while-loop around `receive()`, which matches the
//     Donny Wals / Thomas Smedmann pattern documented in the research
//     note (websocket-asyncstream-pattern.md §"Wrapping URLSession
//     Messages in an AsyncThrowingStream").
//   * The `WebSocketTransportCloseCode` enum carries an explicit
//     `rawCode: Int` so the session can both map to
//     `URLSessionWebSocketTask.CloseCode` (production) and assert
//     specific RFC 6455 values (tests) without case duplication.
//
// All public types are `Sendable`. The production adapter is a
// `final class` so its single mutable property — the underlying
// `URLSessionWebSocketTask` — can be replaced atomically across
// `connect(...)` calls; it is `@unchecked Sendable` because
// `URLSessionWebSocketTask` carries Foundation-managed shared state
// that the wrapper itself does not synchronise.

import Foundation
import Logging

// MARK: - WebSocketTransportMessage

/// A frame received from (or sent to) the WebSocket. `.text` is the JSON
/// control / config / server-response channel; `.data` is the binary
/// audio channel. Matches `URLSessionWebSocketTask.Message`'s two-case
/// shape exactly; no other frame types are part of RFC 6455 data frames.
public enum WebSocketTransportMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

// MARK: - WebSocketTransportCloseCode

/// Maps `URLSessionWebSocketTask.CloseCode` 1:1 plus a `.custom(Int)`
/// escape hatch for vendor-specific application-layer codes (Soniox
/// closes with 1000 on every shutdown — error responses arrive in-band
/// as JSON BEFORE the close — but this enum is general-purpose and
/// future Soniox or other-provider error codes may map here).
///
/// The "reserved" cases (1005 No Status, 1006 Abnormal, 1015 TLS) are
/// included for completeness so receive-side code can express them, but
/// per RFC 6455 they MUST NOT be used in a Close frame sent by the
/// endpoint. The production adapter logs a warning and falls back to
/// `.invalid` (Foundation's wire-equivalent for "do not send a code")
/// if the caller passes one of these to `close(...)`.
public enum WebSocketTransportCloseCode: Sendable, Equatable {
    /// 1000 Normal Closure — used for clean shutdown.
    case normal
    /// 1001 Going Away — peer shutting down.
    case goingAway
    /// 1002 Protocol Error.
    case protocolError
    /// 1003 Unsupported Data — frame type not accepted.
    case unsupportedData
    /// 1005 No Status Received — RESERVED, do not send.
    case noStatus
    /// 1006 Abnormal Closure — RESERVED, do not send.
    case abnormalClosure
    /// 1007 Invalid Frame Payload Data — non-UTF-8 in a text frame.
    case invalidFramePayload
    /// 1008 Policy Violation.
    case policyViolation
    /// 1009 Message Too Large.
    case messageTooLarge
    /// 1010 Mandatory Extension Missing — only sent by clients.
    case mandatoryExtensionMissing
    /// 1011 Internal Server Error.
    case internalServerError
    /// 1015 TLS Handshake — RESERVED, do not send.
    case tlsHandshake
    /// Application-layer code outside RFC 6455's named set
    /// (e.g., Soniox 4xxx/5xxx ranges if/when they materialise).
    case custom(Int)

    /// The 4-digit (or 4xxx for `.custom`) wire value. Tests assert on
    /// this; the production adapter uses it to convert to
    /// `URLSessionWebSocketTask.CloseCode` via `init(rawValue:)`.
    public var rawCode: Int {
        switch self {
        case .normal: return 1000
        case .goingAway: return 1001
        case .protocolError: return 1002
        case .unsupportedData: return 1003
        case .noStatus: return 1005
        case .abnormalClosure: return 1006
        case .invalidFramePayload: return 1007
        case .policyViolation: return 1008
        case .messageTooLarge: return 1009
        case .mandatoryExtensionMissing: return 1010
        case .internalServerError: return 1011
        case .tlsHandshake: return 1015
        case .custom(let code): return code
        }
    }

    /// Whether this code is a "reserved" RFC 6455 sentinel that MUST
    /// NOT be sent in a Close frame. Used by the production adapter to
    /// avoid asking Foundation to send an invalid code.
    public var isReservedReceiveOnly: Bool {
        switch self {
        case .noStatus, .abnormalClosure, .tlsHandshake:
            return true
        default:
            return false
        }
    }
}

// MARK: - WebSocketTransport protocol

/// The dependency-injection seam used by `SonioxStreamingSession`
/// (Unit D, Phase D). Conformers are expected to be safe to call from
/// arbitrary tasks; the production adapter relies on the underlying
/// `URLSessionWebSocketTask`'s thread-safety guarantee and the test
/// adapter is an `actor`.
///
/// All async methods are `throws`-able to surface transport-layer
/// failures (DNS, TLS, send-after-close, etc.). The session wraps these
/// in higher-level `NtakkerError` cases at its own boundary.
public protocol WebSocketTransport: Sendable {
    /// Open the connection. Headers are applied to the upgrade
    /// request. Soniox's API key is sent in the first JSON config frame
    /// (NOT as a header) — but the parameter exists so future providers
    /// or auth flows that DO use header-based auth can reuse this
    /// transport unchanged.
    ///
    /// Throws on TLS failure, DNS failure, HTTP-upgrade rejection, or
    /// any underlying `URLError`.
    func connect(url: URL, headers: [String: String]) async throws

    /// Send a JSON text frame (Soniox config, control messages such as
    /// `keepalive` / `finalize`, or the empty-string end-of-stream
    /// sentinel). Throws on send failure (typically: socket closed).
    func send(text: String) async throws

    /// Send a binary frame (Soniox PCM16 audio chunks). Throws on send
    /// failure.
    func send(data: Data) async throws

    /// Receive the next message synchronously (one-shot). Returns `nil`
    /// when the transport is observed to be closed cleanly; throws on
    /// any transport error.
    ///
    /// Most callers should prefer `messages()` — the streaming variant
    /// — but this single-shot form is exposed because some session
    /// state-machine paths (e.g., wait-for-`finished`-then-close)
    /// read more naturally as discrete awaits.
    func receive() async throws -> WebSocketTransportMessage?

    /// Close the connection. Idempotent. The adapter is responsible for
    /// mapping `WebSocketTransportCloseCode` to the underlying close
    /// code and for tearing down its `URLSessionWebSocketTask` /
    /// `URLSession` so no resources leak.
    func close(code: WebSocketTransportCloseCode, reason: String?) async

    /// Stream of incoming messages. The stream finishes (returns `nil`
    /// from its iterator) when the peer closes cleanly; it throws when
    /// the underlying transport produces an error. Production
    /// implementations may build this from `receive()` calls under the
    /// hood; tests may bypass `receive()` entirely.
    ///
    /// Per the Donny Wals pattern: each call to this method should
    /// return a fresh stream wrapping the same underlying task; the
    /// session calls it once and iterates with `for try await`.
    func messages() -> AsyncThrowingStream<WebSocketTransportMessage, Error>
}

// MARK: - URLSessionWebSocketTask close-code bridge

extension WebSocketTransportCloseCode {
    /// Convert to the Foundation enum used by `URLSessionWebSocketTask
    /// .cancel(with:reason:)`. Returns `.invalid` for reserved-receive
    /// codes (caller must NOT send them) and for `.custom(N)` values
    /// outside Foundation's named set (Foundation does not expose a
    /// "send arbitrary close code" API).
    public func toURLSessionCloseCode() -> URLSessionWebSocketTask.CloseCode {
        switch self {
        case .normal: return .normalClosure
        case .goingAway: return .goingAway
        case .protocolError: return .protocolError
        case .unsupportedData: return .unsupportedData
        case .noStatus: return .noStatusReceived
        case .abnormalClosure: return .abnormalClosure
        case .invalidFramePayload: return .invalidFramePayloadData
        case .policyViolation: return .policyViolation
        case .messageTooLarge: return .messageTooBig
        case .mandatoryExtensionMissing: return .mandatoryExtensionMissing
        case .internalServerError: return .internalServerError
        case .tlsHandshake: return .tlsHandshakeFailure
        case .custom:
            // Foundation has no "raw integer" close code on the public
            // API. The adapter logs a warning and uses `.invalid`,
            // which Foundation translates to "no close code" on the
            // wire (a valid RFC 6455 outcome).
            return .invalid
        }
    }
}
