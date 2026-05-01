// Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsConfig.swift —
// plan-007 Phase B §B.2.

import Foundation

public struct ElevenLabsConfig: Sendable, Equatable {

    /// `ELEVENLABS_API_KEY`. Sent in the `xi-api-key` header.
    public let apiKey: String

    /// Model id (`scribe_v2` default; `scribe_v1` accepted for older
    /// accounts).
    public let modelId: String

    /// Optional ISO-639-1 (`en`) or ISO-639-3 (`eng`) language code.
    /// `nil` lets ElevenLabs auto-detect.
    public let languageCode: String?

    /// Plan-007 §B.7 — speaker-attribution toggle.
    public let diarize: Bool

    /// Plan-007 §B.7 — tag non-speech audio events (`(laughter)` etc.).
    public let tagAudioEvents: Bool

    /// Plan-007 §B.7 — optional 1..32 speaker count hint.
    public let numSpeakers: Int?

    /// Plan-007 §B.7 — `pcm_s16le_16` (low-latency fast-path) or
    /// `other`. Always-on `pcm_s16le_16` per §13 EL-3 because
    /// `AudioWAVEncoder` always produces matching bytes.
    public let fileFormat: String

    /// Plan-007 §B.7 — entity-detection mode (`pii` | `phi` | `pci` |
    /// `all` | `null`). `nil` = off (+30% surcharge applies when set,
    /// which is why §13 EL-2 picks off as the v1 default).
    public let entityDetection: String?

    /// 2026-05-01 — `keyterms[]` form-field added by ElevenLabs on
    /// 2026-01-12. Each value biases the model toward the supplied
    /// vocabulary; useful for disambiguating a bilingual recording
    /// (Greek + English) where the model would otherwise drift into
    /// neighbouring languages (Italian, French) on phonetic
    /// confusion. Hard limits per the keyterm-prompting guide:
    /// at most 50 entries, each at most 20 characters. Empty array
    /// means "no keyterms" (the form-field is simply not sent).
    public let keyterms: [String]

    /// Plan-007 §B.7 — optional ISO-8601 expiry for the API key.
    public let apiKeyExpiresAt: Date?

    public static let defaultModelId = "scribe_v2"
    public static let maxKeyterms = 50
    public static let maxKeytermLength = 20

    public init(
        apiKey: String,
        modelId: String = ElevenLabsConfig.defaultModelId,
        languageCode: String? = nil,
        diarize: Bool = false,
        tagAudioEvents: Bool = true,
        numSpeakers: Int? = nil,
        fileFormat: String = "pcm_s16le_16",
        entityDetection: String? = nil,
        keyterms: [String] = [],
        apiKeyExpiresAt: Date? = nil
    ) throws {
        guard !apiKey.isEmpty else {
            throw MacrecError.transcriptionApiKeyMissing(provider: "elevenlabs")
        }
        let trimmedModel = modelId.trimmingCharacters(in: .whitespaces)
        guard !trimmedModel.isEmpty else {
            throw MacrecError.transcriptionConfigConflict(
                reason: "ElevenLabs requires a model id (e.g. scribe_v2)"
            )
        }
        if let n = numSpeakers, !(1...32).contains(n) {
            throw MacrecError.transcriptionConfigConflict(
                reason: "ELEVENLABS_NUM_SPEAKERS must be in 1..32 (got \(n))"
            )
        }
        let normalisedFileFormat = fileFormat.lowercased()
        guard ["pcm_s16le_16", "other"].contains(normalisedFileFormat) else {
            throw MacrecError.transcriptionConfigConflict(
                reason: "ELEVENLABS_FILE_FORMAT must be 'pcm_s16le_16' or 'other' (got '\(fileFormat)')"
            )
        }
        if let entityDet = entityDetection {
            let lower = entityDet.lowercased()
            guard ["pii", "phi", "pci", "all"].contains(lower) else {
                throw MacrecError.transcriptionConfigConflict(
                    reason: "ELEVENLABS_ENTITY_DETECTION must be one of: pii, phi, pci, all (got '\(entityDet)')"
                )
            }
        }

        // Validate keyterms: trim each entry, drop empties, dedupe in
        // first-appearance order. Cap at Self.maxKeyterms entries; cap
        // each entry at Self.maxKeytermLength characters. Per ElevenLabs'
        // keyterm-prompting guide.
        var seenKeyterms: Set<String> = []
        var sanitisedKeyterms: [String] = []
        for raw in keyterms {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= Self.maxKeytermLength else {
                throw MacrecError.transcriptionConfigConflict(
                    reason: "ELEVENLABS_KEYTERMS entries must be at most \(Self.maxKeytermLength) characters (got '\(trimmed)' = \(trimmed.count) chars)"
                )
            }
            if seenKeyterms.insert(trimmed).inserted {
                sanitisedKeyterms.append(trimmed)
            }
        }
        guard sanitisedKeyterms.count <= Self.maxKeyterms else {
            throw MacrecError.transcriptionConfigConflict(
                reason: "ELEVENLABS_KEYTERMS must contain at most \(Self.maxKeyterms) entries (got \(sanitisedKeyterms.count))"
            )
        }

        self.apiKey = apiKey
        self.modelId = trimmedModel
        self.languageCode = languageCode
        self.diarize = diarize
        self.tagAudioEvents = tagAudioEvents
        self.numSpeakers = numSpeakers
        self.fileFormat = normalisedFileFormat
        self.entityDetection = entityDetection?.lowercased()
        self.keyterms = sanitisedKeyterms
        self.apiKeyExpiresAt = apiKeyExpiresAt
    }
}
