// Sources/NtakkerCore/Transcription/Live/Soniox/SonioxServerMessage.swift
//
// Plan-006 Phase A / Unit A: Soniox unified server-message envelope.
//
// Per soniox-wire-schema.md CRITICAL FINDINGS #1 and #2 the SAME JSON
// envelope shape carries:
//   * Normal token batches (mid-session)         — `tokens` populated
//   * Endpoint-detected batches (with `<end>`)   — `tokens` populated
//   * Manual-finalize batches (with `<fin>`)     — `tokens` populated
//   * Terminal `finished` response                — `tokens: []`,
//                                                    `finished: true`,
//                                                    timing fields set
//   * Error response                              — `tokens: []`,
//                                                    `error_code` + `error_message` set
//
// The decoder therefore tolerates ALL fields except `tokens` being
// absent (and the schema documents `tokens` as always present, possibly
// empty `[]`). All other top-level keys are Optional.
//
// Forward-compatibility: synthesized `Decodable` ignores unknown keys.
// Test #9 asserts this explicitly.
//
// Naming convention deviation note: see SonioxConfigMessage.swift —
// SX-3 prescribed snake_case Swift names; the Phase A task brief
// overrode with snake_case JSON ↔ camelCase Swift via `CodingKeys`.

import Foundation

public struct SonioxServerMessage: Codable, Sendable, Equatable {

    /// Always present (may be `[]`).
    public let tokens: [SonioxToken]

    /// Milliseconds of audio committed to final tokens. Present in
    /// normal batches and in the terminal `finished` response.
    public let finalAudioProcMs: Int?

    /// Milliseconds of audio processed in total (final + non-final).
    /// Present in normal batches and in the terminal `finished`
    /// response.
    public let totalAudioProcMs: Int?

    /// `true` ONLY in the terminal response after the client sends
    /// the empty-frame end-of-stream signal. The server then closes
    /// the WebSocket.
    public let finished: Bool?

    /// HTTP-style status code (4xx / 5xx). Present only in error
    /// responses. See §3.5 for the catalog (400, 401, 402, 408, 429,
    /// 500, 503).
    public let errorCode: Int?

    /// Human-readable error description. Present only in error
    /// responses.
    public let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case tokens           = "tokens"
        case finalAudioProcMs = "final_audio_proc_ms"
        case totalAudioProcMs = "total_audio_proc_ms"
        case finished         = "finished"
        case errorCode        = "error_code"
        case errorMessage     = "error_message"
    }

    public init(
        tokens: [SonioxToken],
        finalAudioProcMs: Int? = nil,
        totalAudioProcMs: Int? = nil,
        finished: Bool? = nil,
        errorCode: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.tokens           = tokens
        self.finalAudioProcMs = finalAudioProcMs
        self.totalAudioProcMs = totalAudioProcMs
        self.finished         = finished
        self.errorCode        = errorCode
        self.errorMessage     = errorMessage
    }

    // MARK: - Convenience classifiers

    /// True when this envelope is the terminal close-confirmation.
    public var isFinishedResponse: Bool { finished == true }

    /// True when this envelope carries a 4xx/5xx error.
    public var isErrorResponse: Bool { errorCode != nil }
}
