// Sources/NtakkerCore/Transcription/Providers/Azure/AzureOpenAISTTError.swift —
// plan-007 Phase A1 §A.4.
//
// Provider-internal error enum mapped to `NtakkerError` at the call
// site (so the `NtakkerError` surface stays unchanged — see plan-007
// §4.4 / §A.4 mapping table).

import Foundation

enum AzureOpenAISTTError: Error, Sendable {
    case invalidApiKey                          // 401
    case permissionDenied                       // 403
    case deploymentNotFound                     // 404 / DeploymentNotFound
    case fileTooLarge                           // 413 or 400/file_too_large
    case unsupportedAudioFormat                 // 415 or 400/invalid_audio_format
    case invalidRequest(message: String)        // other 400s
    case rateLimited(retryAfterSec: Double?)    // 429
    case networkTimeout                         // 408
    case serverError(statusCode: Int)           // 500, 503
    case networkError(underlying: Error)        // URLError
    case unexpectedResponse(statusCode: Int, body: Data)
}

extension AzureOpenAISTTError {

    /// Translate to the project's user-facing `NtakkerError`. Lives on
    /// the provider-internal type so the cross-walk is colocated with
    /// the cases. Plan-007 §A.4 mapping.
    func toNtakkerError(deployment: String, host: String) -> NtakkerError {
        switch self {
        case .invalidApiKey:
            return .transcriptionApiKeyMissing(provider: "azure")
        case .permissionDenied:
            return .transcriptionPermissionDenied(provider: "azure")
        case .deploymentNotFound:
            return .transcriptionConfigConflict(
                reason: "Azure deployment '\(deployment)' not found in resource '\(host)' (verify the deployment name in the Azure portal)"
            )
        case .fileTooLarge:
            return .transcriptionProviderUnavailable(
                reason: "Audio chunk exceeds Azure's 25 MB limit (chunk longer than ~25 min)"
            )
        case .unsupportedAudioFormat:
            return .transcriptionProviderUnavailable(
                reason: "Audio format not accepted by Azure (CAF must be converted to WAV/M4A first)"
            )
        case .invalidRequest(let message):
            return .transcriptionProviderUnavailable(
                reason: "Azure rejected request: \(message)"
            )
        case .rateLimited(let retryAfter):
            let retryStr = retryAfter.map { String(format: "%.1f", $0) } ?? "unknown"
            return .transcriptionProviderUnavailable(
                reason: "Azure rate-limited (retry after \(retryStr)s); reduce concurrency or upgrade tier"
            )
        case .networkTimeout:
            return .transcriptionProviderUnavailable(
                reason: "Azure read timeout; transient"
            )
        case .serverError(let code):
            return .transcriptionProviderUnavailable(
                reason: "Azure server error \(code); transient"
            )
        case .networkError(let err):
            return .transcriptionProviderUnavailable(
                reason: "Azure unreachable: \(err.localizedDescription)"
            )
        case .unexpectedResponse(let code, _):
            return .transcriptionProviderUnavailable(
                reason: "Unexpected Azure response (HTTP \(code))"
            )
        }
    }
}

/// Decodable Azure error envelope. Two variants per research §7:
///   * Format A — API layer: `{ "error": { "code", "message", … } }`
///   * Format B — APIM layer: `{ "statusCode", "message" }`
///
/// `decode(from:)` tries A first then falls back to B; either yields a
/// `(code, message)` tuple for the call site to inspect.
struct AzureOpenAIErrorEnvelope {
    let code: String?
    let message: String

    static func decode(from data: Data) -> AzureOpenAIErrorEnvelope? {
        // Format A
        if let parsed = try? JSONDecoder().decode(FormatA.self, from: data) {
            return AzureOpenAIErrorEnvelope(
                code: parsed.error.code,
                message: parsed.error.message ?? ""
            )
        }
        // Format B
        if let parsed = try? JSONDecoder().decode(FormatB.self, from: data) {
            return AzureOpenAIErrorEnvelope(
                code: parsed.statusCode.map(String.init),
                message: parsed.message
            )
        }
        return nil
    }

    private struct FormatA: Decodable {
        let error: Inner
        struct Inner: Decodable {
            let code: String?
            let message: String?
            let type: String?
            let param: String?
        }
    }
    private struct FormatB: Decodable {
        let statusCode: Int?
        let message: String
    }
}
