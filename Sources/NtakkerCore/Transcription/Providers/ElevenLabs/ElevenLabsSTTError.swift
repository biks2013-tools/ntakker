// Sources/NtakkerCore/Transcription/Providers/ElevenLabs/ElevenLabsSTTError.swift —
// plan-007 Phase B §B.4.

import Foundation

enum ElevenLabsSTTError: Error, Sendable {
    case invalidApiKey                                  // 401
    case insufficientCredits                            // 402
    case planFeatureGate(feature: String)               // 403
    case fileTooLarge                                   // 413 (> 3 GB)
    case audioTooLong                                   // 422 audio_too_long
    case audioTooShort                                  // 400 audio_too_short
    case unsupportedFormat                              // 400/422 invalid_audio_format
    case invalidParameter(field: String, message: String)  // 422 invalid_parameters
    case rateLimited(retryAfterSec: Double?)            // 429 rate_limit_exceeded / system_busy
    case concurrentLimitExceeded                        // 429 concurrent_limit_exceeded (no retry)
    case serverError(code: Int)                         // 500 / 503
    case networkFailure(underlying: Error)              // URLError
    case decodingFailure(underlying: Error)             // JSONDecoder
}

extension ElevenLabsSTTError {

    func toNtakkerError() -> NtakkerError {
        switch self {
        case .invalidApiKey:
            return .transcriptionApiKeyMissing(provider: "elevenlabs")
        case .insufficientCredits:
            return .transcriptionProviderUnavailable(
                reason: "ElevenLabs account out of credits; top up at https://elevenlabs.io/app/billing"
            )
        case .planFeatureGate(let feature):
            return .transcriptionProviderUnavailable(
                reason: "ElevenLabs '\(feature)' requires plan upgrade"
            )
        case .fileTooLarge:
            return .transcriptionProviderUnavailable(
                reason: "Audio chunk exceeds ElevenLabs 3 GB limit"
            )
        case .audioTooLong:
            return .transcriptionProviderUnavailable(
                reason: "Audio exceeds ElevenLabs 4.5 hr per-request limit"
            )
        case .audioTooShort:
            // The provider short-circuits sub-100 ms chunks before
            // the network call; this case is here for completeness if
            // the server ever surfaces it directly.
            return .transcriptionProviderUnavailable(
                reason: "Audio shorter than ElevenLabs 100 ms minimum"
            )
        case .unsupportedFormat:
            return .transcriptionProviderUnavailable(
                reason: "Audio format not accepted by ElevenLabs (CAF must be converted to WAV/M4A first)"
            )
        case .invalidParameter(let field, let message):
            return .transcriptionConfigConflict(
                reason: "ElevenLabs rejected '\(field)': \(message)"
            )
        case .rateLimited:
            return .transcriptionProviderUnavailable(
                reason: "ElevenLabs rate-limited; backoff exhausted"
            )
        case .concurrentLimitExceeded:
            return .transcriptionProviderUnavailable(
                reason: "ElevenLabs concurrent-request limit reached on your plan; reduce concurrency or upgrade"
            )
        case .serverError(let code):
            return .transcriptionProviderUnavailable(
                reason: "ElevenLabs server error \(code); transient"
            )
        case .networkFailure(let err):
            return .transcriptionProviderUnavailable(
                reason: "ElevenLabs unreachable: \(err.localizedDescription)"
            )
        case .decodingFailure(let err):
            return .transcriptionProviderUnavailable(
                reason: "ElevenLabs response malformed: \(err.localizedDescription)"
            )
        }
    }
}

/// `{ "detail": { "status": "...", "message": "..." } }` envelope
/// per research §7.
struct ElevenLabsErrorEnvelope: Decodable {
    let detail: Inner
    struct Inner: Decodable {
        let status: String?
        let message: String?
    }

    static func decode(from data: Data) -> ElevenLabsErrorEnvelope? {
        try? JSONDecoder().decode(ElevenLabsErrorEnvelope.self, from: data)
    }
}
