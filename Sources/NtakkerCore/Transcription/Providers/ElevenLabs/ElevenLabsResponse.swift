// Sources/NtakkerCore/Transcription/Providers/ElevenLabs/ElevenLabsResponse.swift —
// plan-007 Phase B §B.5.

import Foundation

/// `SpeechToTextChunkResponseModel` per research §6.1. The provider
/// only requires `text` to satisfy the existing
/// `TranscriptionProvider.transcribe(...)` contract, but the optional
/// `words[]` payload is decoded so future plan-007 follow-ups (SRT/VTT
/// generation, diarization-aware output) can pivot off the same
/// struct without a wire change.
///
/// Multi-channel (`MultichannelSpeechToTextResponseModel`) and webhook
/// (`SpeechToTextWebhookResponseModel`) variants are NOT decoded here;
/// `use_multi_channel` and `webhook` are not requested in v1.
struct ElevenLabsResponse: Decodable, Sendable {

    let languageCode: String?
    let languageProbability: Double?
    let text: String
    let words: [Word]?

    struct Word: Decodable, Sendable {
        let text: String
        let start: Double
        let end: Double
        let type: String           // "word" | "spacing" | "audio_event"
        let speakerId: String?     // present when diarize=true

        enum CodingKeys: String, CodingKey {
            case text, start, end, type
            case speakerId = "speaker_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case text, words
        case languageCode = "language_code"
        case languageProbability = "language_probability"
    }
}
