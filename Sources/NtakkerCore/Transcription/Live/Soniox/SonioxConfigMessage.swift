// Sources/NtakkerCore/Transcription/Live/Soniox/SonioxConfigMessage.swift
//
// Plan-006 Phase A / Unit A: Soniox WebSocket wire-format Codable types.
//
// SonioxConfigMessage is the FIRST message the client sends on the
// `wss://stt-rt.soniox.com/transcribe-websocket` connection (TEXT frame,
// JSON body). The server begins processing audio immediately after this
// frame; there is no acknowledgment.
//
// Field set is the documented superset for `ntakker-cli` v1 (per
// docs/research/soniox-wire-schema.md §2.1 and docs/design/project-design.md
// §SX-3.1). Fields explicitly OUT OF v1 SCOPE — `translation` — are NOT
// present here. `enable_speaker_diarization`, `context`, and
// `keepalive_interval_ms` are included as Optional so future plans can
// populate them without re-shaping the struct, but `ntakker-cli` v1 leaves
// them `nil` (and the encoder therefore omits them entirely from the
// outgoing JSON, satisfying AC-SX-15-style "only documented keys"
// posture).
//
// IMPORTANT — naming convention deviation from SX-3 design:
// SX-3 prescribes snake_case Swift property names (no `CodingKeys`).
// The Phase A task brief explicitly overrode this with "snake_case JSON
// ↔ camelCase Swift via `CodingKeys`". This file follows the brief.
// See the Unit A summary for the deviation note.
//
// Encoding contract:
// * `JSONEncoder` is used with default `outputFormatting = []` (compact,
//   no sorted keys). Key order in the produced JSON matches the
//   declaration order of `CodingKeys` below — Swift's synthesized
//   `Encodable` implementation iterates the `CodingKeys` enum in source
//   order. Snapshot tests rely on this.
// * `nil` Optional fields are OMITTED entirely (default JSONEncoder
//   behaviour with synthesized Encodable + Optional Codable values).

import Foundation

public struct SonioxConfigMessage: Codable, Sendable, Equatable {

    // MARK: - Required fields

    /// Long-lived API key or temporary key (≤3600 s). Carried in the
    /// JSON body — NEVER in the URL (per Soniox §1 connection auth).
    public let apiKey: String

    /// Real-time STT model id. v1 uses `"stt-rt-v4"` (current active
    /// real-time model per soniox-wire-schema.md §2.1 field reference).
    public let model: String

    /// Audio framing for the binary frames that follow.
    /// `ntakker-cli` always sends `"pcm_s16le"` to match `AudioDownsampler`
    /// output (Int16 LE @ 16 kHz mono). See §2.1.1 of the wire schema.
    public let audioFormat: String

    /// Raw PCM sample rate in Hz. Required for any non-`"auto"`
    /// `audio_format`. `ntakker-cli` uses `16000`.
    public let sampleRate: Int

    /// Channel count for raw PCM. Required for any non-`"auto"`
    /// `audio_format`. `ntakker-cli` uses `1` (mono).
    public let numChannels: Int

    // MARK: - Optional fields

    /// ISO 639-1 hints (NOT BCP-47 — `"el-GR"` causes a 400). Order
    /// is bias, not priority. `ntakker-cli` v1 default is `["el", "en"]`
    /// (Greek + English) per FR-SX-9.
    public let languageHints: [String]?

    /// `true` strongly restricts recognition to listed languages
    /// (best with a single hint). `ntakker-cli` v1 default is `false` —
    /// bias-without-restriction posture.
    public let languageHintsStrict: Bool?

    /// Adds `language` field to each emitted token (FR-SX-10). v1
    /// default is `true`.
    public let enableLanguageIdentification: Bool?

    /// Emits `<end>` marker token at utterance boundaries; gives
    /// clean `final` event semantics that mirror Apple Speech. v1
    /// default is `true`.
    public let enableEndpointDetection: Bool?

    /// Bound on endpoint-detection latency. Soniox accepts 500–3000.
    /// v1 default is `2000` (chosen for clean finals over ultra-low
    /// latency).
    public let maxEndpointDelayMs: Int?

    /// Adds `speaker` field to each emitted token. v1 leaves this
    /// `nil` (out of scope per OQ-SX-3 default — refined request
    /// excludes diarization). Encoder will omit when `nil`.
    public let enableSpeakerDiarization: Bool?

    /// Domain-bias context (terms, free text, key/value pairs).
    /// v1 leaves this `nil`. Encoder will omit when `nil`. See
    /// §2.1.2 of the wire schema for the nested object shape.
    public let context: SonioxContext?

    /// Optional debugging tag that appears in Soniox Console logs.
    /// `ntakker-cli` populates `"ntakker-cli-<recordingId>-<source>"` (max
    /// 256 chars).
    public let clientReferenceId: String?

    /// **Inferred — confirm with probe script.** The Soniox docs
    /// describe `keepalive_interval_ms` as the suggested cadence the
    /// Node SDK uses to send `{"type":"keepalive"}` frames; whether
    /// the server also accepts this on the inbound config message
    /// is undocumented. Kept Optional + omitted by default so the
    /// outgoing JSON contains only fields known-good. A future
    /// Probe-Phase script can verify and either remove this field
    /// or document its server-side semantics.
    public let keepaliveIntervalMs: Int?

    // MARK: - CodingKeys (snake_case JSON ↔ camelCase Swift)

    private enum CodingKeys: String, CodingKey {
        case apiKey                       = "api_key"
        case model                        = "model"
        case audioFormat                  = "audio_format"
        case sampleRate                   = "sample_rate"
        case numChannels                  = "num_channels"
        case languageHints                = "language_hints"
        case languageHintsStrict          = "language_hints_strict"
        case enableLanguageIdentification = "enable_language_identification"
        case enableEndpointDetection      = "enable_endpoint_detection"
        case maxEndpointDelayMs           = "max_endpoint_delay_ms"
        case enableSpeakerDiarization     = "enable_speaker_diarization"
        case context                      = "context"
        case clientReferenceId            = "client_reference_id"
        case keepaliveIntervalMs          = "keepalive_interval_ms"
    }

    // MARK: - Memberwise init (public required so callers outside
    // NtakkerCore can construct the struct).

    public init(
        apiKey: String,
        model: String = "stt-rt-v4",
        audioFormat: String = "pcm_s16le",
        sampleRate: Int = 16_000,
        numChannels: Int = 1,
        languageHints: [String]? = nil,
        languageHintsStrict: Bool? = false,
        enableLanguageIdentification: Bool? = nil,
        enableEndpointDetection: Bool? = nil,
        maxEndpointDelayMs: Int? = nil,
        enableSpeakerDiarization: Bool? = false,
        context: SonioxContext? = nil,
        clientReferenceId: String? = nil,
        keepaliveIntervalMs: Int? = nil
    ) {
        self.apiKey                       = apiKey
        self.model                        = model
        self.audioFormat                  = audioFormat
        self.sampleRate                   = sampleRate
        self.numChannels                  = numChannels
        self.languageHints                = languageHints
        self.languageHintsStrict          = languageHintsStrict
        self.enableLanguageIdentification = enableLanguageIdentification
        self.enableEndpointDetection      = enableEndpointDetection
        self.maxEndpointDelayMs           = maxEndpointDelayMs
        self.enableSpeakerDiarization     = enableSpeakerDiarization
        self.context                      = context
        self.clientReferenceId            = clientReferenceId
        self.keepaliveIntervalMs          = keepaliveIntervalMs
    }
}

// MARK: - Context (nested object shape per §2.1.2)

/// The Soniox `context` object — domain biasing for the recognizer.
/// All four sub-sections are optional. `ntakker-cli` v1 does not populate
/// this (kept available so a future plan can extend without reshape).
public struct SonioxContext: Codable, Sendable, Equatable {

    public let general: [SonioxContextEntry]?
    public let text: String?
    public let terms: [String]?
    public let translationTerms: [SonioxTranslationTerm]?

    private enum CodingKeys: String, CodingKey {
        case general          = "general"
        case text             = "text"
        case terms            = "terms"
        case translationTerms = "translation_terms"
    }

    public init(
        general: [SonioxContextEntry]? = nil,
        text: String? = nil,
        terms: [String]? = nil,
        translationTerms: [SonioxTranslationTerm]? = nil
    ) {
        self.general          = general
        self.text             = text
        self.terms            = terms
        self.translationTerms = translationTerms
    }
}

/// Key/value entry in `context.general`.
public struct SonioxContextEntry: Codable, Sendable, Equatable {

    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Source/target pair in `context.translation_terms`.
public struct SonioxTranslationTerm: Codable, Sendable, Equatable {

    public let source: String
    public let target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}
