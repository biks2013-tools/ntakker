// Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeError.swift —
// plan-007 Phase A2 §A2.2.

import Foundation

public enum AzureOpenAIRealtimeError: Error, LocalizedError, Sendable {
    // -- WS connection lifecycle --
    case connectionFailed(underlying: Error)
    case unauthorizedUpgrade               // HTTP 401 on upgrade
    case policyViolation                   // close 1008
    case abnormalClose(code: Int)          // close 1006 / 1001 / 1011
    case sessionExpired                    // 60-min hard cap reached cleanly

    // -- Session-level protocol errors (received as `error` events) --
    case sessionRejected(type: String, message: String)
    case rateLimited(resetSeconds: Double?)
    case internalServerError(message: String)
    case modelFieldRejected                // RT-1: model field included by mistake

    // -- Item-level (non-fatal) --
    case itemTranscriptionFailed(itemId: String, message: String)

    // -- Audio / format --
    case audioFormatMismatch(reason: String)

    // -- Reconnect --
    case reconnectExhausted(attempts: Int)

    // -- Catch-all --
    case unexpectedEvent(name: String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let err):
            return "Azure realtime connection failed: \(err.localizedDescription)"
        case .unauthorizedUpgrade:
            return "Azure realtime: API key invalid or expired"
        case .policyViolation:
            return "Azure realtime: auth policy violation"
        case .abnormalClose(let code):
            return "Azure realtime: connection closed abnormally (code \(code))"
        case .sessionExpired:
            return "Azure realtime: 60-min session cap reached"
        case .sessionRejected(let type, let message):
            return "Azure realtime: session-level \(type): \(message)"
        case .rateLimited(let reset):
            if let reset = reset {
                return "Azure realtime: rate-limited (resets in \(reset)s)"
            }
            return "Azure realtime: rate-limited"
        case .internalServerError(let message):
            return "Azure realtime: server error: \(message)"
        case .modelFieldRejected:
            return "Azure realtime: 'model' field included in transcription_session.update — known Azure bug, must be omitted"
        case .itemTranscriptionFailed(let itemId, let message):
            return "Azure realtime: transcription failed for item \(itemId): \(message)"
        case .audioFormatMismatch(let reason):
            return "Azure realtime: audio format mismatch: \(reason)"
        case .reconnectExhausted(let attempts):
            return "Azure realtime: reconnect exhausted after \(attempts) attempts"
        case .unexpectedEvent(let name):
            return "Azure realtime: unexpected event '\(name)'"
        }
    }
}

extension AzureOpenAIRealtimeError {

    /// Translate to the project's user-facing `MacrecError` for the
    /// surface bits that bubble out to the CLI exit code path.
    func toMacrecError() -> MacrecError {
        switch self {
        case .unauthorizedUpgrade:
            return .transcriptionApiKeyMissing(provider: "azure-openai-realtime")
        case .policyViolation:
            return .transcriptionPermissionDenied(provider: "azure-openai-realtime")
        case .modelFieldRejected:
            return .transcriptionConfigConflict(
                reason: "Azure realtime: 'model' field included in session update — strip the field from RealtimeWireTypes.SessionConfig"
            )
        case .reconnectExhausted(let attempts):
            return .transcriptionProviderUnavailable(
                reason: "Azure realtime: reconnect failed after \(attempts) attempts; recording continues without transcription"
            )
        case .audioFormatMismatch(let reason):
            return .transcriptionProviderUnavailable(
                reason: "Azure realtime: audio format mismatch: \(reason)"
            )
        default:
            return .transcriptionProviderUnavailable(
                reason: errorDescription ?? "Azure realtime error"
            )
        }
    }
}
