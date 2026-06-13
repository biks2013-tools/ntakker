// Sources/NtakkerCore/Transcription/Live/Soniox/SonioxToken.swift
//
// Plan-006 Phase A / Unit A: Soniox token shape.
//
// A Soniox `token` is the atomic unit emitted inside the `tokens`
// array of every server message. Per soniox-wire-schema.md §3.1 only
// `text`, `confidence`, and `is_final` are guaranteed; the rest are
// conditional on session config (LID / diarization / translation) or
// translation-token-specific.
//
// Marker tokens — used to signal end-of-utterance / end-of-finalize:
//   * `text == "<end>"` — endpoint detector fired (auto)
//   * `text == "<fin>"` — server processed a `{"type":"finalize"}`
// Both are always `is_final: true` and typically have `confidence: 1.0`.
//
// IMPORTANT — protocol field decisions:
//
// * `confidence` is OPTIONAL here. The wire schema lists it as "always
//   present", but downstream-robustness is preferred — making it
//   Optional avoids decode failure if a future Soniox version drops
//   `confidence` from a server-level diagnostic frame. Test #9
//   (forward-compat) covers the analogous case.
//
// * `startMs` / `endMs` are Optional because the schema notes they are
//   absent for translation tokens (`translation_status == "translation"`).
//
// * `translationStatus` and `sourceLanguage` are kept as Optional
//   `String` for forward-compat even though `ntakker-cli` v1 never enables
//   translation.
//
// Naming convention deviation note: see SonioxConfigMessage.swift —
// SX-3 prescribed snake_case Swift names; the Phase A task brief
// overrode with snake_case JSON ↔ camelCase Swift via `CodingKeys`.

import Foundation

public struct SonioxToken: Codable, Sendable, Equatable {

    /// The transcribed text. May be `"<end>"` or `"<fin>"` for
    /// marker tokens.
    public let text: String

    /// `true` = will never change. `false` = provisional, may be
    /// revised by a later non-final batch.
    public let isFinal: Bool

    /// Start timestamp ms relative to audio stream start. Absent for
    /// translation tokens.
    public let startMs: Int?

    /// End timestamp ms relative to audio stream start. Absent for
    /// translation tokens.
    public let endMs: Int?

    /// 0.0–1.0. Marker tokens (`<end>`, `<fin>`) typically `1.0`.
    /// Optional for downstream robustness even though the schema
    /// lists this as always-present.
    public let confidence: Double?

    /// ISO 639-1 code (`"el"`, `"en"`). Present when
    /// `enable_language_identification: true`.
    public let language: String?

    /// Speaker label (`"1"`, `"2"`, …). Present when
    /// `enable_speaker_diarization: true`. Unused in v1.
    public let speaker: String?

    /// `"none"` | `"original"` | `"translation"`. Present only when
    /// translation is enabled. Unused in v1.
    public let translationStatus: String?

    /// Source language of a translated token. Present only when
    /// translation is enabled. Unused in v1.
    public let sourceLanguage: String?

    private enum CodingKeys: String, CodingKey {
        case text              = "text"
        case isFinal           = "is_final"
        case startMs           = "start_ms"
        case endMs             = "end_ms"
        case confidence        = "confidence"
        case language          = "language"
        case speaker           = "speaker"
        case translationStatus = "translation_status"
        case sourceLanguage    = "source_language"
    }

    public init(
        text: String,
        isFinal: Bool,
        startMs: Int? = nil,
        endMs: Int? = nil,
        confidence: Double? = nil,
        language: String? = nil,
        speaker: String? = nil,
        translationStatus: String? = nil,
        sourceLanguage: String? = nil
    ) {
        self.text              = text
        self.isFinal           = isFinal
        self.startMs           = startMs
        self.endMs             = endMs
        self.confidence        = confidence
        self.language          = language
        self.speaker           = speaker
        self.translationStatus = translationStatus
        self.sourceLanguage    = sourceLanguage
    }

    // MARK: - Marker helpers

    /// Endpoint-detected end-of-utterance marker (`text == "<end>"`).
    public var isEndMarker: Bool { text == "<end>" }

    /// Manual-finalize end-of-batch marker (`text == "<fin>"`).
    public var isFinalizeMarker: Bool { text == "<fin>" }

    /// Either marker variant.
    public var isMarker: Bool { isEndMarker || isFinalizeMarker }
}
