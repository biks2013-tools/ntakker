// Sources/MacrecCore/Transcription/Providers/Azure/Realtime/RealtimeWireTypes.swift —
// plan-007 Phase A2 §A2.5 / §A2.2.
//
// Codable models for every Azure realtime client + server event used by
// `AzureOpenAIRealtimeSession`. Two non-obvious invariants:
//
// 1. **The `model` field MUST be omitted** from
//    `transcription_session.update.session` — including it triggers
//    `conversation.item.input_audio_transcription.failed` (RT-1, the
//    Azure model-field bug). The Codable types here therefore have
//    NO `model` property anywhere — verified by the round-trip test
//    in `RealtimeWireTypesTests.modelFieldOmitted` (Phase E).
//
// 2. Audio is base64-encoded inside `input_audio_buffer.append`'s JSON
//    envelope; binary WebSocket frames are NEVER used (research §4.3).

import Foundation

public enum RealtimeWireTypes {

    // MARK: - Client → server

    /// `transcription_session.update` — first client event after
    /// `session.created`. Configures VAD, language, noise reduction.
    public struct TranscriptionSessionUpdate: Encodable, Sendable {
        public let type: String = "transcription_session.update"
        public let session: SessionConfig

        public init(session: SessionConfig) {
            self.session = session
        }
    }

    /// `session` payload nested inside `transcription_session.update`.
    /// **Has NO `model` field** (RT-1).
    public struct SessionConfig: Encodable, Sendable {
        public let inputAudioFormat: String                              // "pcm16"
        public let inputAudioTranscription: InputAudioTranscriptionConfig
        public let turnDetection: TurnDetectionConfig?
        public let inputAudioNoiseReduction: NoiseReductionConfig?
        public let include: [String]?

        public init(
            inputAudioFormat: String = "pcm16",
            inputAudioTranscription: InputAudioTranscriptionConfig,
            turnDetection: TurnDetectionConfig? = nil,
            inputAudioNoiseReduction: NoiseReductionConfig? = nil,
            include: [String]? = nil
        ) {
            self.inputAudioFormat = inputAudioFormat
            self.inputAudioTranscription = inputAudioTranscription
            self.turnDetection = turnDetection
            self.inputAudioNoiseReduction = inputAudioNoiseReduction
            self.include = include
        }

        public enum CodingKeys: String, CodingKey {
            case inputAudioFormat = "input_audio_format"
            case inputAudioTranscription = "input_audio_transcription"
            case turnDetection = "turn_detection"
            case inputAudioNoiseReduction = "input_audio_noise_reduction"
            case include
            // NOTE: NO `model` case — Azure rejects it (RT-1).
        }
    }

    /// `input_audio_transcription` sub-object.
    ///
    /// 2026-05-01 field repro: Azure's `intent=transcription` endpoint
    /// REQUIRES `model` here — sending the session update without it
    /// is rejected with `invalid_request_error: Missing required
    /// parameter: 'session.input_audio_transcription.model'`. The
    /// earlier "RT-1 model field bug" claim in
    /// `docs/research/azure-openai-realtime-transcription-wire-schema.md`
    /// only applies to the conversational (`gpt-realtime`) intent;
    /// for the transcription intent, the model name is mandatory and
    /// must match one of Azure's transcription models
    /// (`gpt-4o-mini-transcribe`, `gpt-4o-transcribe`, `whisper-1`).
    public struct InputAudioTranscriptionConfig: Encodable, Sendable {
        public let model: String?
        public let language: String?
        public let prompt: String?

        public init(model: String?, language: String? = nil, prompt: String? = nil) {
            self.model = model
            self.language = language
            self.prompt = prompt
        }
    }

    public struct TurnDetectionConfig: Encodable, Sendable {
        public let type: String                  // "server_vad" | "semantic_vad"
        public let threshold: Float?
        public let prefixPaddingMS: Int?
        public let silenceDurationMS: Int?

        // NOTE (2026-05-01 field repro): `create_response` and
        // `interrupt_response` are CONVERSATIONAL realtime fields
        // (intent=conversation). Azure's transcription endpoint
        // (intent=transcription) returns
        // `invalid_request_error: Unknown parameter:
        // 'session.turn_detection.interrupt_response'` (and the same
        // for `create_response`) when they appear under
        // `transcription_session.update`. Curl-probe of Azure's
        // default `transcription_session.created` payload echoed
        // ONLY type / threshold / prefix_padding_ms /
        // silence_duration_ms. Do NOT add the two response-control
        // fields back here — they belong on a future
        // `RealtimeWireTypes.ConversationalTurnDetectionConfig`
        // type if the conversational intent is ever wired in.

        public init(
            type: String = "server_vad",
            threshold: Float? = nil,
            prefixPaddingMS: Int? = nil,
            silenceDurationMS: Int? = nil
        ) {
            self.type = type
            self.threshold = threshold
            self.prefixPaddingMS = prefixPaddingMS
            self.silenceDurationMS = silenceDurationMS
        }

        public enum CodingKeys: String, CodingKey {
            case type, threshold
            case prefixPaddingMS = "prefix_padding_ms"
            case silenceDurationMS = "silence_duration_ms"
        }
    }

    public struct NoiseReductionConfig: Encodable, Sendable {
        public let type: String     // "near_field" | "far_field"

        public init(type: String) {
            self.type = type
        }
    }

    /// `input_audio_buffer.append` — carries one base64-encoded audio
    /// chunk per message.
    public struct InputAudioBufferAppend: Encodable, Sendable {
        public let type: String = "input_audio_buffer.append"
        public let audio: String                 // base64 of PCM16 bytes

        public init(audio: String) {
            self.audio = audio
        }
    }

    /// `input_audio_buffer.commit` — manually finalise a turn
    /// (unused when `server_vad` is on, but available for a future
    /// "manual mode" toggle).
    public struct InputAudioBufferCommit: Encodable, Sendable {
        public let type: String = "input_audio_buffer.commit"
        public init() {}
    }

    /// `input_audio_buffer.clear` — drop pending uncommitted audio.
    public struct InputAudioBufferClear: Encodable, Sendable {
        public let type: String = "input_audio_buffer.clear"
        public init() {}
    }

    // MARK: - Server → client

    /// Discriminated union of every server event the session reacts
    /// to. Unknown event types decode to `.unknown(typeName)` so the
    /// session can log and continue.
    public enum ServerEvent: Decodable, Sendable {
        case sessionCreated(SessionCreated)
        case sessionUpdated(SessionUpdated)
        case speechStarted(SpeechStarted)
        case speechStopped(SpeechStopped)
        case bufferCommitted(BufferCommitted)
        case transcriptionDelta(TranscriptionDelta)
        case transcriptionCompleted(TranscriptionCompleted)
        case transcriptionFailed(TranscriptionFailed)
        case sessionError(SessionError)
        case rateLimitsUpdated(RateLimitsUpdated)
        case unknown(typeName: String)

        private enum DiscriminatorKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DiscriminatorKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "session.created", "transcription_session.created":
                // Field-verified 2026-05-01 against
                // biksaiservice-east-us-2.openai.azure.com: the actual
                // first server event for `intent=transcription` is
                // `transcription_session.created`, NOT `session.created`
                // as the early wire-schema research note claimed.
                // Treat both the same so `handleEvent(.sessionCreated)`
                // fires `sendSessionConfig()` regardless of which name
                // Azure decides to use. Without this, the session sat
                // open with `input_audio_transcription: null` and Azure
                // never emitted any transcription deltas.
                self = .sessionCreated(try SessionCreated(from: decoder))
            case "session.updated", "transcription_session.updated":
                // Acknowledgement of our `transcription_session.update`.
                // Same payload shape; we keep both names mapped to the
                // same case for log uniformity.
                self = .sessionUpdated(try SessionUpdated(from: decoder))
            case "input_audio_buffer.speech_started":
                self = .speechStarted(try SpeechStarted(from: decoder))
            case "input_audio_buffer.speech_stopped":
                self = .speechStopped(try SpeechStopped(from: decoder))
            case "input_audio_buffer.committed":
                self = .bufferCommitted(try BufferCommitted(from: decoder))
            case "conversation.item.input_audio_transcription.delta":
                self = .transcriptionDelta(try TranscriptionDelta(from: decoder))
            case "conversation.item.input_audio_transcription.completed":
                self = .transcriptionCompleted(try TranscriptionCompleted(from: decoder))
            case "conversation.item.input_audio_transcription.failed":
                self = .transcriptionFailed(try TranscriptionFailed(from: decoder))
            case "error":
                self = .sessionError(try SessionError(from: decoder))
            case "rate_limits.updated":
                self = .rateLimitsUpdated(try RateLimitsUpdated(from: decoder))
            default:
                self = .unknown(typeName: type)
            }
        }
    }

    public struct SessionCreated: Decodable, Sendable {
        public let eventId: String?
        public let session: SessionInfo?

        public enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case session
        }
    }

    public struct SessionInfo: Decodable, Sendable {
        public let id: String?
        public let object: String?
        public let model: String?
    }

    public struct SessionUpdated: Decodable, Sendable {
        public let eventId: String?

        public enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
        }
    }

    public struct SpeechStarted: Decodable, Sendable {
        public let eventId: String?
        public let itemId: String?
        public let audioStartMS: Int?

        public enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case itemId = "item_id"
            case audioStartMS = "audio_start_ms"
        }
    }

    public struct SpeechStopped: Decodable, Sendable {
        public let eventId: String?
        public let itemId: String?
        public let audioEndMS: Int?

        public enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case itemId = "item_id"
            case audioEndMS = "audio_end_ms"
        }
    }

    public struct BufferCommitted: Decodable, Sendable {
        public let eventId: String?
        public let itemId: String?
        public let previousItemId: String?

        public enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case itemId = "item_id"
            case previousItemId = "previous_item_id"
        }
    }

    public struct TranscriptionDelta: Decodable, Sendable {
        public let eventId: String?
        public let itemId: String
        public let delta: String

        public enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case itemId = "item_id"
            case delta
        }
    }

    public struct TranscriptionCompleted: Decodable, Sendable {
        public let eventId: String?
        public let itemId: String
        public let transcript: String

        public enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case itemId = "item_id"
            case transcript
        }
    }

    public struct TranscriptionFailed: Decodable, Sendable {
        public let eventId: String?
        public let itemId: String
        public let error: ErrorPayload

        public enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case itemId = "item_id"
            case error
        }
    }

    public struct SessionError: Decodable, Sendable {
        public let eventId: String?
        public let error: ErrorPayload

        public enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case error
        }
    }

    public struct ErrorPayload: Decodable, Sendable {
        public let type: String?
        public let code: String?
        public let message: String?
        public let param: String?
    }

    public struct RateLimitsUpdated: Decodable, Sendable {
        public let eventId: String?
        public let rateLimits: [RateLimit]?

        public enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case rateLimits = "rate_limits"
        }
    }

    public struct RateLimit: Decodable, Sendable {
        public let name: String?
        public let limit: Int?
        public let remaining: Int?
        public let resetSeconds: Double?

        public enum CodingKeys: String, CodingKey {
            case name, limit, remaining
            case resetSeconds = "reset_seconds"
        }
    }
}
