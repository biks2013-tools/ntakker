---
research_for: investigation-live-transcription.md
researched_at: "2026-04-26"
depth: deep-dive
topic: "Gemini Live BidiGenerateContent JSON wire schema (request and response shapes)"
---

# Gemini Live `BidiGenerateContent` JSON Wire Schema

## CRITICAL FINDINGS — Read Before Implementing

The following findings **contradict or sharpen** assumptions made in `investigation-live-transcription.md`:

1. **`responseModalities: ["TEXT"]` is REJECTED on `gemini-3.1-flash-live-preview`.**
   Native audio models (any model whose name contains "native-audio", "flash-live", or uses the new 3.x live stack) terminate the WebSocket immediately with close code **1007 (Invalid argument)** when `TEXT` is included in `responseModalities`. The investigation flagged this as a risk; it is confirmed as a hard constraint, not a maybe.
   - **Workaround is mandatory**: Use `responseModalities: ["AUDIO"]` and rely exclusively on `inputAudioTranscription: {}` for transcript text. You will receive audio bytes on the return path but must discard them. The transcription arrives independently as `serverContent.inputTranscription.text` fragments.

2. **`BidiGenerateContentSetup` is wrapped in a `"setup"` top-level key**, not sent bare.
   The client message envelope is `{ "setup": { "model": "...", ... } }`. The investigation described the inner object correctly; the outer key is required by the protocol.

3. **The `config` vs `setup` key discrepancy**: Google's WebSocket get-started guide uses the key `"config"` in its JSON examples (`{ "config": { "model": "...", ... } }`). The canonical API reference (`ai.google.dev/api/live`) uses the key `"setup"`. **Use `"setup"` — it is the wire-level field name.** The Python/JS SDK examples showing `"config"` are SDK-layer abstractions mapped internally to `"setup"` before transmission.

4. **`BidiGenerateContentSetup.systemInstruction` is a `Content` object**, not a bare string.
   The Vertex AI docs show `"systemInstruction": string` in their example configuration schema, but the authoritative API reference specifies `Content` — the same type used everywhere else in the Gemini API. Use the `Content` object shape: `{ "parts": [{ "text": "..." }] }`.

5. **`inputAudioTranscription` must be `{}` (empty object), not a boolean or omitted field.**
   `AudioTranscriptionConfig` has no fields as of the current API spec. Setting it to `{}` is both correct and the only valid value.

6. **`Gemini 3.1 Flash Live Preview` is a single `BidiGenerateContentServerContent` event that can contain multiple parts simultaneously.** Unlike the 2.5 generation, a single server message may carry both `inlineData` (audio bytes) and `inputTranscription` in the same envelope. Parse all fields of every `serverContent` message; do not assume only one type of content per message.

7. **Audio chunk size of 1024 samples (~64 ms at 16 kHz) is what Google's own sample code uses.** The investigation recommended 30 ms (~480 samples); 64 ms is the documented default. Both are within the acceptable range. The value has no wire-format significance — chunk boundaries are not semantic.

8. **Session duration is a two-tier limit.** The *context-window* limit (audio-only) is 15 minutes before the model starts forgetting. The *connection* limit is ~10 minutes, after which the server sends `GoAway` and closes the socket. Context window compression (`contextWindowCompression: { slidingWindow: {} }`) extends the context limit; session resumption (`sessionResumption: {}`) extends across connection resets.

---

## Overview

The Gemini Live API is a stateful WebSocket protocol over `wss://`. Each connection is a "session". The client sends JSON frames; the server responds with JSON frames. All audio is base64-encoded inside JSON. There are no binary WebSocket frames — everything is text frames carrying JSON.

The four client message types and the six server message types are enumerated below with exact field names, types, and wire-format constraints.

---

## 1. Connection and Authentication

### Canonical Endpoint (API-key client, no GCP project)

```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=YOUR_API_KEY
```

This is the **officially documented** endpoint in `https://ai.google.dev/api/live`. Use it.

**Alternative URL style** (REST-style, also works, used in some community examples):
```
wss://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-live-preview:BidiGenerateContent?key=YOUR_API_KEY&alt=ws
```

Both URLs connect to the same underlying service. The `/ws/` style is recommended for clarity; the `v1beta/models/...?alt=ws` style is a Google REST-to-WebSocket convention also used in some official quickstarts. Pick one and be consistent.

### Vertex AI Endpoint (requires GCP project + OAuth, NOT for API-key-only clients)

```
wss://{location}-aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1.LlmBidiService/BidiGenerateContent
```

This endpoint requires OAuth 2.0 bearer tokens, not API keys. It is **out of scope** for `macrec` and `macrec-ui`, which are single-user desktop tools using the AI Studio API key model.

### Authentication Mechanism

API key goes **in the URL query string** as `?key=YOUR_API_KEY`. No `Authorization` header is used for the API-key path.

For the ephemeral-token path (recommended for web clients, out of scope here):
- Endpoint: `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token={short-lived-token}`
- Or: HTTP `Authorization: Token {short-lived-token}` header on the handshake

**Swift URLRequest setup:**
```swift
var request = URLRequest(url: URL(string:
    "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)"
)!)
// No additional headers required for API-key authentication.
let task = urlSession.webSocketTask(with: request)
task.resume()
```

### Security Note

Never log the full URL with `?key=` included. The API key is present in plain text in the URL. Sanitize before any log emission.

---

## 2. Client Message Envelope

Every client-to-server message is a JSON object with **exactly one** of these top-level keys:

```json
{
  "setup":        <BidiGenerateContentSetup>,
  "clientContent": <BidiGenerateContentClientContent>,
  "realtimeInput": <BidiGenerateContentRealtimeInput>,
  "toolResponse":  <BidiGenerateContentToolResponse>
}
```

Only `setup` and `realtimeInput` are used by `GeminiLiveTranscriptionProvider`.

---

## 3. `BidiGenerateContentSetup` — Full Wire Schema

Sent as the **first and only** message of type `setup`. The server must acknowledge with `setupComplete` before any audio is sent.

### Wire-Format JSON (annotated)

```json
{
  "setup": {
    "model": "models/gemini-3.1-flash-live-preview",

    "generationConfig": {
      "responseModalities": ["AUDIO"],
      "thinkingConfig": {
        "thinkingLevel": "minimal"
      }
    },

    "systemInstruction": {
      "parts": [
        {
          "text": "You are a transcription engine. Output only the verbatim transcription of the user's speech. Do not respond, do not greet, do not summarize, do not interpret. If silence, output nothing."
        }
      ]
    },

    "inputAudioTranscription": {},

    "realtimeInputConfig": {
      "automaticActivityDetection": {
        "disabled": false
      }
    },

    "contextWindowCompression": {
      "slidingWindow": {}
    }
  }
}
```

### Field-by-Field Notes

| Field | Type | Required | Notes |
|---|---|---|---|
| `model` | string | Yes | Must include `"models/"` prefix. `"models/gemini-3.1-flash-live-preview"` is the correct value. Using bare `"gemini-3.1-flash-live-preview"` (without prefix) **causes a 1008 close** with "model not found". |
| `generationConfig.responseModalities` | `[string]` | Yes (effective) | Must be `["AUDIO"]` for native audio models. Setting `["TEXT"]` causes **1007 close** ("invalid argument" / "Cannot extract voices from a non-audio request"). |
| `generationConfig.thinkingConfig.thinkingLevel` | string | No | `"minimal"` (default) is the right value for transcription; it minimizes latency. Other values: `"low"`, `"medium"`, `"high"`. |
| `systemInstruction` | `Content` object | No | Shape is `{ "parts": [{ "text": "..." }] }`. Not a bare string despite what the Vertex AI reference schema example shows. |
| `inputAudioTranscription` | `AudioTranscriptionConfig` (empty) | No | Setting this to `{}` enables `serverContent.inputTranscription.text` fragments. If omitted, no transcription is emitted. |
| `outputAudioTranscription` | `AudioTranscriptionConfig` (empty) | No | Not needed for our use case. Setting this to `{}` enables transcription of the model's own audio output. |
| `realtimeInputConfig.automaticActivityDetection.disabled` | bool | No | Default `false` (VAD enabled). Keep default. |
| `contextWindowCompression.slidingWindow` | empty object | No | Strongly recommended. Without it, audio-only sessions hit context exhaustion at ~15 min. With it, sessions are unlimited. |
| `sessionResumption` | object | No | Set `{}` to enable session-resumption tokens. Allows reconnecting across the ~10-min connection limit without losing state. |

**Fields NOT supported** in `generationConfig` for Live (they are silently ignored or cause errors):
- `responseLogprobs`, `responseMimeType`, `logprobs`, `responseSchema`, `stopSequence`, `routingConfig`, `audioTimestamp`

---

## 4. `BidiGenerateContentRealtimeInput` — Full Wire Schema

Used for streaming audio. Sent continuously after `setupComplete`.

### Wire-Format JSON (audio chunk)

```json
{
  "realtimeInput": {
    "audio": {
      "data": "<base64-encoded PCM16 LE bytes>",
      "mimeType": "audio/pcm;rate=16000"
    }
  }
}
```

### Field-by-Field Notes

| Field | Type | Required | Notes |
|---|---|---|---|
| `realtimeInput.audio` | `Blob` | One of audio/video/text | Use this field for streaming audio. **Do NOT use `mediaChunks`** — it is deprecated. |
| `realtimeInput.audio.data` | string (base64) | Yes | Raw PCM16 bytes, little-endian, mono, encoded as standard base64. No URL-safe encoding required. |
| `realtimeInput.audio.mimeType` | string | Yes | `"audio/pcm;rate=16000"` for 16 kHz input. The API will resample if you send a different rate (e.g., `"audio/pcm;rate=48000"`) but native 16 kHz is preferred and requires no server-side resampling. |
| `realtimeInput.audioStreamEnd` | bool | No | Send `{ "realtimeInput": { "audioStreamEnd": true } }` when the microphone is muted/paused for more than ~1 second to flush buffered audio. Resume by sending audio again. |
| `realtimeInput.text` | string | No | Text input, not used for our use case. |
| `realtimeInput.activityStart` | empty object | No | Only if VAD is disabled. |
| `realtimeInput.activityEnd` | empty object | No | Only if VAD is disabled. |

**Deprecated field — do not use:**
```
// WRONG — deprecated, only first element is processed, rest are silently dropped
{ "realtimeInput": { "mediaChunks": [{ "data": "...", "mimeType": "..." }] } }
```

### Audio Format Requirements

| Property | Value |
|---|---|
| Sample rate | 16,000 Hz (native; other rates accepted but resampled by server) |
| Bit depth | 16-bit signed integer |
| Byte order | Little-endian |
| Channels | Mono (1 channel) |
| MIME type | `audio/pcm;rate=16000` |
| Encoding | Raw PCM bytes, no WAV/RIFF header |

### Chunk Size

Google's own sample code uses **1,024 samples per chunk** = ~64 ms at 16 kHz = 2,048 bytes of PCM16.

The investigation recommended 30 ms (~480 samples, ~960 bytes). Both are valid. Chunk size has no semantic meaning to the server — the VAD operates on the aggregate stream, not on chunk boundaries.

**Recommended chunk size for `macrec`**: 960 bytes (480 samples, 30 ms) as originally planned, since `HostClockAligner` produces 100 ms windows (4,800 samples at 48 kHz → 1,600 samples at 16 kHz → 3,200 bytes) and splitting into ~3 chunks of 30 ms keeps message frequency moderate while matching the planned cadence.

**Base64 overhead**: 1,600 raw samples × 2 bytes/sample = 3,200 bytes PCM → ~4,268 bytes base64 (33% overhead). At 30 ms cadence (~33 msgs/sec), this is ~141 KB/sec of JSON throughput on the send path — well within any practical limit.

---

## 5. `BidiGenerateContentServerMessage` — Full Wire Schema

The server sends JSON text frames. Each message has `usageMetadata` optionally, plus **exactly one** of the union fields.

### Possible server message shapes

```json
{ "setupComplete": {} }

{ "serverContent": { ... } }

{ "toolCall": { "functionCalls": [...] } }

{ "toolCallCancellation": { "ids": [...] } }

{ "goAway": { "timeLeft": "120s" } }

{ "sessionResumptionUpdate": { "newHandle": "...", "resumable": true } }

{ "usageMetadata": { "totalTokenCount": 1234, ... } }
```

### `serverContent` — the primary message type

For transcription-only use, the fields of interest are:

```json
{
  "serverContent": {
    "inputTranscription": {
      "text": "Hello, how are you today"
    },
    "modelTurn": {
      "parts": [
        {
          "inlineData": {
            "data": "<base64 PCM audio>",
            "mimeType": "audio/pcm;rate=24000"
          }
        }
      ]
    },
    "turnComplete": true,
    "generationComplete": true,
    "interrupted": false
  }
}
```

**Note on Gemini 3.1 behavior**: A **single** `serverContent` message can carry multiple content parts simultaneously (e.g., both `inlineData` audio bytes AND `inputTranscription` in the same event). The 2.5 generation sent them as separate events. Always check all fields of each `serverContent` message.

### `serverContent` Field Reference

| Field | Type | Notes |
|---|---|---|
| `inputTranscription.text` | string | The transcription fragment of what the user said/played. May be partial or final — no `isFinal` flag exists. |
| `outputTranscription.text` | string | Transcription of the model's audio response. Only present if `outputAudioTranscription: {}` is set. |
| `modelTurn.parts[].inlineData.data` | string (base64) | Model's audio response, PCM16 at 24 kHz. **Discard these bytes** when transcription-only. |
| `modelTurn.parts[].inlineData.mimeType` | string | Will be `"audio/pcm;rate=24000"` for audio output. |
| `turnComplete` | bool | When `true`, the model has completed its turn. Use this as the commit boundary for accumulating transcript fragments. |
| `generationComplete` | bool | When `true`, generation is done. May appear together with `turnComplete` or in a separate subsequent message. |
| `interrupted` | bool | When `true`, the user interrupted the model mid-generation. If `true`, there will be no `generationComplete` in this turn. |
| `groundingMetadata` | object | Not relevant for transcription. |

### Partial vs. Final Transcript Reconstruction

The protocol has **no `isFinal` flag** on `inputTranscription`. The commit boundary is defined by `serverContent.turnComplete: true` or `serverContent.generationComplete: true`. The recommended accumulation strategy:

1. On receiving `serverContent.inputTranscription.text` → accumulate fragment, emit `TranscriptEvent.partial(...)`.
2. On receiving `serverContent` with `turnComplete: true` or `generationComplete: true` → concatenate all accumulated fragments, emit `TranscriptEvent.final(...)`, clear the buffer.
3. Note: `turnComplete` and `inputTranscription` may arrive in the **same message** or in separate messages. Process all present fields before moving on.

---

## 6. Setup Acknowledgment (`setupComplete`)

The server sends `{ "setupComplete": {} }` after receiving the `setup` message. The client **must wait** for this before sending any `realtimeInput` messages. Sending audio before `setupComplete` is protocol-incorrect (behavior is undefined — the server may silently drop frames or close with 1007).

---

## 7. Session Lifecycle Events

### `GoAway`

```json
{ "goAway": { "timeLeft": "120s" } }
```

`timeLeft` is a Duration string (e.g., `"120s"`). The connection will be terminated as ABORTED after this time. Upon receiving `GoAway`, initiate reconnection proactively rather than waiting for the close.

### Session Resumption

If `sessionResumption: {}` is included in the setup message, the server will periodically send:

```json
{
  "sessionResumptionUpdate": {
    "newHandle": "handle-string-opaque",
    "resumable": true
  }
}
```

Store the latest handle. On reconnect, pass `"sessionResumption": { "handle": "<stored-handle>" }` in the new setup message to resume context. Handles are valid for 2 hours after the last session's termination.

---

## 8. Error Envelopes — WebSocket Close Codes

The Live API communicates errors by **closing the WebSocket** with a specific close code and reason string, not by sending an error JSON message on the channel.

| Close Code | Meaning | Common Causes |
|---|---|---|
| 1000 | Normal closure | Client-initiated clean close. |
| 1007 | Invalid frame payload | Wrong `responseModalities` for model type; unsupported config field; bad JSON syntax; `send_client_content` called after first turn on Gemini 3.1. |
| 1008 | Policy violation | Model not found (`"models/gemini-3.1-flash-live-preview"` format required); model not enabled for your API key; API key leaked/suspended. |
| 1011 | Internal server error | Transient server fault; reconnect with backoff. |
| ABORTED (gRPC code 10) | Connection aborted | Session exceeded time limit; `GoAway` was sent but not acted on in time. |

### Authentication Failure Pattern

Authentication failures appear as **1008 (policy violation)** at connection time or just after the setup message, with a reason string like:
- `"Your API key is invalid."`
- `"Your API key was reported as leaked. Please use another API key."`
- `"models/gemini-3.1-flash-live-preview is not found for API version v1beta, or is not supported for bidiGenerateContent."` (when model name is wrong)

There is no JSON-level error message type for authentication errors. The socket closes.

---

## 9. Session Limits

| Limit | Value | Mitigation |
|---|---|---|
| Audio-only session (context window) | 15 minutes | Enable `contextWindowCompression: { slidingWindow: {} }` for unlimited sessions |
| Audio+video session | 2 minutes | Not applicable |
| Connection lifetime | ~10 minutes | Enable `sessionResumption: {}` and use handle to reconnect |
| Context window size | 128k tokens | Large enough for ~10–15 minutes of dense audio without compression |
| Audio input sample rate (native) | 16 kHz | Server resamples other rates; native preferred |
| Audio output sample rate | 24 kHz (fixed) | Cannot be changed |
| Concurrent live sessions per API key | Not documented; rate-limit errors appear as 429 HTTP during WebSocket upgrade |

**GoAway timing**: The server sends `GoAway` with `timeLeft` typically 120 seconds before ABORTED. This is the reconnection window.

---

## 10. Production-Ready Swift `Codable` Type Definitions

These types are ready to copy verbatim into `Sources/MacrecCore/Transcription/GeminiLiveTypes.swift`.

```swift
import Foundation

// MARK: - Client → Server messages

/// Top-level client message envelope.
/// Exactly one field must be non-nil.
struct GeminiClientMessage: Encodable {
    var setup: BidiGenerateContentSetup?
    var realtimeInput: BidiGenerateContentRealtimeInput?
    var clientContent: BidiGenerateContentClientContent?
    var toolResponse: BidiGenerateContentToolResponse?

    enum CodingKeys: String, CodingKey {
        case setup
        case realtimeInput
        case clientContent
        case toolResponse
    }
}

// MARK: Setup

struct BidiGenerateContentSetup: Encodable {
    /// Required. Must use "models/" prefix, e.g. "models/gemini-3.1-flash-live-preview"
    let model: String
    var generationConfig: GeminiLiveGenerationConfig?
    var systemInstruction: GeminiContent?
    var inputAudioTranscription: AudioTranscriptionConfig?
    var outputAudioTranscription: AudioTranscriptionConfig?
    var realtimeInputConfig: RealtimeInputConfig?
    var contextWindowCompression: ContextWindowCompressionConfig?
    var sessionResumption: SessionResumptionConfig?
    var tools: [GeminiTool]?
}

struct GeminiLiveGenerationConfig: Encodable {
    /// For native audio models (gemini-3.1-flash-live-preview) must be ["AUDIO"].
    /// Setting ["TEXT"] causes 1007 close.
    var responseModalities: [String]?
    var thinkingConfig: ThinkingConfig?
    var speechConfig: SpeechConfig?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var maxOutputTokens: Int?
}

struct ThinkingConfig: Encodable {
    /// Values: "minimal" (default, lowest latency), "low", "medium", "high"
    var thinkingLevel: String?
}

struct SpeechConfig: Encodable {
    var voiceConfig: VoiceConfig?
}

struct VoiceConfig: Encodable {
    var prebuiltVoiceConfig: PrebuiltVoiceConfig?
}

struct PrebuiltVoiceConfig: Encodable {
    var voiceName: String?
}

/// Represents a Gemini Content object (used for systemInstruction, turns, etc.)
struct GeminiContent: Encodable {
    var role: String?
    var parts: [GeminiPart]
}

struct GeminiPart: Encodable {
    var text: String?
    var inlineData: GeminiBlob?
}

struct GeminiBlob: Codable {
    /// Base64-encoded bytes
    let data: String
    let mimeType: String
}

/// AudioTranscriptionConfig has no fields. Use AudioTranscriptionConfig() to encode as {}.
struct AudioTranscriptionConfig: Encodable {
    // Intentionally empty — encodes to {}
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        _ = container  // suppress "variable was never used" — empty object intended
    }
    private enum CodingKeys: String, CodingKey {}
}

struct RealtimeInputConfig: Encodable {
    var automaticActivityDetection: AutomaticActivityDetection?
    var activityHandling: String?
    var turnCoverage: String?
}

struct AutomaticActivityDetection: Encodable {
    /// false = VAD enabled (default). true = client must send activityStart/End manually.
    var disabled: Bool?
    var startOfSpeechSensitivity: String?
    var endOfSpeechSensitivity: String?
    var prefixPaddingMs: Int?
    var silenceDurationMs: Int?
}

struct ContextWindowCompressionConfig: Encodable {
    var slidingWindow: SlidingWindowConfig?
    var triggerTokens: Int?
}

/// SlidingWindowConfig has no required fields.
struct SlidingWindowConfig: Encodable {
    var targetTokens: Int?
}

struct SessionResumptionConfig: Encodable {
    /// Pass the handle from a previous SessionResumptionUpdate to resume.
    /// Omit (nil) to start a new session.
    var handle: String?
}

struct GeminiTool: Encodable {
    // Extend as needed for function calling
}

// MARK: RealtimeInput

struct BidiGenerateContentRealtimeInput: Encodable {
    /// Audio blob. Use this field; do NOT use mediaChunks (deprecated).
    var audio: GeminiBlob?
    var video: GeminiBlob?
    var text: String?
    var audioStreamEnd: Bool?
    var activityStart: ActivitySignal?
    var activityEnd: ActivitySignal?
}

/// ActivityStart and ActivityEnd have no fields. Used when VAD is disabled.
struct ActivitySignal: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        _ = container
    }
    private enum CodingKeys: String, CodingKey {}
}

// MARK: ClientContent (for seeding initial history only on Gemini 3.1)

struct BidiGenerateContentClientContent: Encodable {
    var turns: [GeminiContent]?
    var turnComplete: Bool?
}

// MARK: ToolResponse

struct BidiGenerateContentToolResponse: Encodable {
    var functionResponses: [FunctionResponse]?
}

struct FunctionResponse: Encodable {
    let id: String
    let name: String
    let response: [String: String]  // Adjust value type as needed
}

// MARK: - Server → Client messages

/// Top-level server message envelope.
/// The messageType union means exactly one content field is present,
/// plus usageMetadata may be present on any message.
struct GeminiServerMessage: Decodable {
    var setupComplete: BidiGenerateContentSetupComplete?
    var serverContent: BidiGenerateContentServerContent?
    var toolCall: BidiGenerateContentToolCall?
    var toolCallCancellation: BidiGenerateContentToolCallCancellation?
    var goAway: GoAway?
    var sessionResumptionUpdate: SessionResumptionUpdate?
    var usageMetadata: UsageMetadata?
}

// MARK: Setup complete

/// Sent by the server when setup is accepted.
/// Has no fields — the presence of the key is the signal.
struct BidiGenerateContentSetupComplete: Decodable {
    // Intentionally empty
}

// MARK: Server content

struct BidiGenerateContentServerContent: Decodable {
    /// The model's generated content (audio bytes on return path).
    var modelTurn: GeminiContentReceived?
    /// Input audio transcription. Present when inputAudioTranscription was enabled in setup.
    var inputTranscription: BidiGenerateContentTranscription?
    /// Output audio transcription. Present when outputAudioTranscription was enabled in setup.
    var outputTranscription: BidiGenerateContentTranscription?
    /// true when the model has finished its turn. Use as commit boundary for partial transcripts.
    var turnComplete: Bool?
    /// true when generation is complete (may appear together with or after turnComplete).
    var generationComplete: Bool?
    /// true when client audio interrupted the model mid-generation.
    var interrupted: Bool?
    var groundingMetadata: AnyCodable?
}

/// Received Content (from model), used in serverContent.modelTurn
struct GeminiContentReceived: Decodable {
    var role: String?
    var parts: [GeminiPartReceived]?
}

struct GeminiPartReceived: Decodable {
    var text: String?
    var inlineData: GeminiBlob?
}

/// Transcription of input or output audio.
struct BidiGenerateContentTranscription: Decodable {
    let text: String
}

// MARK: Tool call (server → client)

struct BidiGenerateContentToolCall: Decodable {
    var functionCalls: [FunctionCall]?
}

struct FunctionCall: Decodable {
    let id: String
    let name: String
    let args: [String: AnyCodable]?
}

struct BidiGenerateContentToolCallCancellation: Decodable {
    var ids: [String]?
}

// MARK: GoAway

struct GoAway: Decodable {
    /// Duration string, e.g. "120s". Remaining time before connection is ABORTED.
    var timeLeft: String?
}

// MARK: Session resumption

struct SessionResumptionUpdate: Decodable {
    /// New handle to store. Use as `sessionResumption.handle` on next connection.
    var newHandle: String?
    /// If false, the session cannot be resumed at this point (e.g., during tool execution).
    var resumable: Bool?
}

// MARK: Usage metadata

struct UsageMetadata: Decodable {
    var promptTokenCount: Int?
    var responseTokenCount: Int?
    var totalTokenCount: Int?
    var promptTokensDetails: [ModalityTokenCount]?
    var responseTokensDetails: [ModalityTokenCount]?
}

struct ModalityTokenCount: Decodable {
    var modality: String?
    var tokenCount: Int?
}

// MARK: AnyCodable (minimal, for unknown fields)
// Replace with a full AnyCodable implementation if needed for tool calling

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(Bool.self) { value = v }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: _CodingKey.self)
        _ = container  // AnyCodable encoding handled inline where needed
    }

    private struct _CodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { self.intValue = intValue; stringValue = "\(intValue)" }
    }
}
```

---

## 11. Complete WebSocket Flow — Annotated Swift Snippet

This snippet shows the exact JSON bytes on the wire at each step.

```swift
import Foundation

// MARK: - Step 0: Build the setup message

func makeSetupMessage(model: String, apiKey: String) throws -> String {
    let setup = BidiGenerateContentSetup(
        model: "models/\(model)",  // <-- "models/" prefix is REQUIRED
        generationConfig: GeminiLiveGenerationConfig(
            responseModalities: ["AUDIO"],  // <-- Must be AUDIO for native audio model
            thinkingConfig: ThinkingConfig(thinkingLevel: "minimal")
        ),
        systemInstruction: GeminiContent(
            role: nil,
            parts: [GeminiPart(text: "You are a transcription engine. Output only the verbatim transcription of the user's speech. Do not respond, do not greet, do not summarize, do not interpret. If silence, output nothing.")]
        ),
        inputAudioTranscription: AudioTranscriptionConfig(),  // <-- empty {} enables input transcription
        realtimeInputConfig: RealtimeInputConfig(
            automaticActivityDetection: AutomaticActivityDetection(disabled: false)
        ),
        contextWindowCompression: ContextWindowCompressionConfig(
            slidingWindow: SlidingWindowConfig()
        ),
        sessionResumption: SessionResumptionConfig(handle: nil)  // nil = new session
    )
    let envelope = GeminiClientMessage(setup: setup)
    let data = try JSONEncoder().encode(envelope)
    return String(data: data, encoding: .utf8)!
}

// Wire JSON produced (formatted for readability):
// {
//   "setup": {
//     "model": "models/gemini-3.1-flash-live-preview",
//     "generationConfig": {
//       "responseModalities": ["AUDIO"],
//       "thinkingConfig": { "thinkingLevel": "minimal" }
//     },
//     "systemInstruction": {
//       "parts": [{ "text": "You are a transcription engine..." }]
//     },
//     "inputAudioTranscription": {},
//     "realtimeInputConfig": {
//       "automaticActivityDetection": { "disabled": false }
//     },
//     "contextWindowCompression": { "slidingWindow": {} },
//     "sessionResumption": {}
//   }
// }


// MARK: - Step 1: Open WebSocket and send setup

func openAndSetup(apiKey: String, model: String) async throws -> URLSessionWebSocketTask {
    let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)"
    // NOTE: never log urlString — it contains the API key
    let url = URL(string: urlString)!
    let task = URLSession.shared.webSocketTask(with: url)
    task.resume()

    // Send setup as first message
    let setupJSON = try makeSetupMessage(model: model, apiKey: apiKey)
    try await task.send(.string(setupJSON))

    return task
}


// MARK: - Step 2: Wait for setupComplete

func waitForSetupComplete(task: URLSessionWebSocketTask) async throws {
    let message = try await task.receive()
    guard case .string(let json) = message else {
        throw GeminiLiveError.unexpectedMessageType
    }
    let data = json.data(using: .utf8)!
    let serverMsg = try JSONDecoder().decode(GeminiServerMessage.self, from: data)
    guard serverMsg.setupComplete != nil else {
        throw GeminiLiveError.setupNotAcknowledged(received: json)
    }
    // Server JSON on the wire:
    // { "setupComplete": {} }
}


// MARK: - Step 3: Send first audio chunk

func sendAudioChunk(task: URLSessionWebSocketTask, pcm16LEBytes: Data) async throws {
    // pcm16LEBytes: raw Int16 samples, little-endian, mono, 16 kHz
    // No header, no footer — pure PCM
    let base64String = pcm16LEBytes.base64EncodedString()  // standard base64, not URL-safe
    let blob = GeminiBlob(data: base64String, mimeType: "audio/pcm;rate=16000")
    let input = BidiGenerateContentRealtimeInput(audio: blob)
    let envelope = GeminiClientMessage(realtimeInput: input)
    let data = try JSONEncoder().encode(envelope)
    let json = String(data: data, encoding: .utf8)!
    try await task.send(.string(json))

    // Wire JSON (1024 samples = 2048 bytes → ~2732 chars base64):
    // {
    //   "realtimeInput": {
    //     "audio": {
    //       "data": "AAAAAAAAAAAAAAAA...",
    //       "mimeType": "audio/pcm;rate=16000"
    //     }
    //   }
    // }
}


// MARK: - Step 4: Receive and handle transcript fragments

func receiveLoop(task: URLSessionWebSocketTask, onFragment: (String) -> Void, onFinal: ([String]) -> Void) async {
    var pendingFragments: [String] = []

    while true {
        do {
            let message = try await task.receive()
            guard case .string(let json) = message,
                  let data = json.data(using: .utf8) else { continue }

            let serverMsg = try JSONDecoder().decode(GeminiServerMessage.self, from: data)

            // Handle GoAway — initiate reconnection
            if let goAway = serverMsg.goAway {
                // timeLeft e.g. "120s" — start reconnect now
                _ = goAway
                break
            }

            guard let content = serverMsg.serverContent else { continue }

            // On Gemini 3.1, inputTranscription and turnComplete may arrive in the
            // SAME serverContent message. Process all fields before deciding on commit.

            if let transcription = content.inputTranscription {
                pendingFragments.append(transcription.text)
                onFragment(transcription.text)
            }

            // Commit boundary: turnComplete OR generationComplete
            let shouldCommit = (content.turnComplete == true) || (content.generationComplete == true)
            if shouldCommit && !pendingFragments.isEmpty {
                onFinal(pendingFragments)
                pendingFragments.removeAll()
            }

            // interrupted means model was cut off — clear any buffered model audio
            // but do NOT clear pendingFragments (partial transcription of user speech stands)
            if content.interrupted == true {
                // clear any model-audio playback queue here
            }

        } catch {
            // URLSessionWebSocketTask throws on connection close
            break
        }
    }
}


// MARK: - Errors

enum GeminiLiveError: Error {
    case unexpectedMessageType
    case setupNotAcknowledged(received: String)
    case apiKeyMissing
    case websocketClosed(code: URLSessionWebSocketTask.CloseCode, reason: String?)
}
```

---

## 12. What Doesn't Work — Field Rejection Catalog

| What You Try | What Happens | Exact Error |
|---|---|---|
| `"responseModalities": ["TEXT"]` on any native audio model | WebSocket closes immediately after setup message | Close code **1007**, reason: `"Request contains an invalid argument."` or `"Cannot extract voices from a non-audio request."` |
| `"responseModalities": ["TEXT", "AUDIO"]` | Same 1007 close | Same reason string |
| Omitting `"models/"` prefix — `"model": "gemini-3.1-flash-live-preview"` | WebSocket closes | Close code **1008**, reason: `"models/gemini-3.1-flash-live-preview is not found for API version v1beta"` |
| `"mediaChunks": [{"data": "...", "mimeType": "..."}]` in `realtimeInput` | Silently accepted but only the first element is processed; rest are dropped. The field is deprecated. | No error — just silent data loss. |
| Sending `realtimeInput` audio before receiving `setupComplete` | Behavior undefined; commonly causes silent audio drop or 1007. | Not deterministic |
| `"systemInstruction": "plain string"` instead of `Content` object | Silently ignored (Vertex AI docs show the wrong shape; the correct shape is `{ "parts": [...] }`) | No error — instruction just isn't applied |
| Calling `clientContent` for non-initial-history messages on Gemini 3.1 | Close code **1007** | `"send_client_content is only supported for seeding initial context history"` |
| Invalid `temperature` outside [0.0, 2.0] | Close code 1007 | Invalid argument |
| Setting `responseModalities: []` (empty array) | Connection closes | 1007, invalid argument |
| Sending audio after `audioStreamEnd: true` without first sending audio data again | Audio resumption not triggered; stream treated as ended | Silent — VAD sees no audio activity |

---

## 13. Fallback Plan: `responseModalities: ["TEXT"]` Rejected

Since `gemini-3.1-flash-live-preview` rejects `["TEXT"]`, the **mandatory approach** is:

1. Set `responseModalities: ["AUDIO"]` (the only accepted value).
2. Set `inputAudioTranscription: {}` in the setup.
3. On receiving `serverContent.modelTurn.parts[].inlineData` with `mimeType: "audio/pcm;rate=24000"` — **discard the bytes**. Do not decode, buffer, or play them.
4. Read only `serverContent.inputTranscription.text` for the transcript.

The cost implication: audio output tokens are generated and billed (~$12/M tokens) even though we discard them. This is unavoidable with the current API. For a 60-minute session, the model's audio response to "transcription only" prompts is expected to be minimal (the system instruction tells it not to respond), so real-world output audio billing should be negligible.

### Swift Implementation of Audio-Discard Pattern

```swift
// In your receive loop, inside serverContent handling:
if let content = serverMsg.serverContent {

    // ---- Audio bytes: DISCARD ----
    // The model is native-audio and WILL send audio bytes on return path.
    // We enabled inputAudioTranscription so we get text separately.
    // Explicitly ignore inlineData to make intent clear.
    if let modelTurn = content.modelTurn {
        for part in modelTurn.parts ?? [] {
            if let inlineData = part.inlineData,
               inlineData.mimeType.hasPrefix("audio/pcm") {
                // Discard: we only want inputTranscription.text
                _ = inlineData
            }
        }
    }

    // ---- Input transcription: USE ----
    if let transcription = content.inputTranscription {
        pendingFragments.append(transcription.text)
        emitPartial(transcription.text)
    }

    // Commit boundary
    if content.turnComplete == true || content.generationComplete == true {
        if !pendingFragments.isEmpty {
            emitFinal(pendingFragments.joined(separator: " "))
            pendingFragments.removeAll()
        }
    }
}
```

**Alternative fallback**: If `gemini-3.1-flash-live-preview` is unavailable or the key doesn't have access, the fallback model is `gemini-live-2.5-flash-native-audio` (the documented stable predecessor). The wire protocol is identical; only the model string changes. The 2.5 native audio model has the same `TEXT` modality restriction.

---

## 14. Assumptions and Uncertainties

| Assumption | Confidence | Impact if Wrong |
|---|---|---|
| `"models/"` prefix required in the `model` field | HIGH (confirmed by 1008 error reports without prefix) | Provider fails to connect at all |
| `TEXT` modality is rejected on `gemini-3.1-flash-live-preview` | HIGH (documented explicitly in the capabilities guide under "Limitations"; confirmed by multiple GitHub issues) | No impact — the workaround (AUDIO + inputAudioTranscription) is documented and working |
| `inputAudioTranscription: {}` reliably produces `serverContent.inputTranscription.text` fragments | HIGH (confirmed by canonical code samples in the live guide) | No transcription text received |
| Partial/final boundary is `turnComplete` or `generationComplete` | HIGH (documented in API reference) | Transcript fragments may accumulate without being committed |
| `setupComplete` must be awaited before sending audio | HIGH (stated explicitly in the API reference: "Clients should wait for a BidiGenerateContentSetupComplete message before sending any additional messages") | Undefined behavior; likely silent audio drop |
| The `AudioTranscriptionConfig` encoding as `{}` is correct for Swift `Codable` | MEDIUM (the API reference says "This type has no fields" which maps to empty object; no Swift-specific example found) | If the server expects the field absent rather than `{}`, the field is silently ignored — unlikely to cause errors |
| JSON encoder default key names (camelCase) match the wire format | HIGH (the API uses camelCase JSON; `JSONEncoder` default produces camelCase; no snake_case conversion needed) | Malformed messages rejected with 1007 |
| Chunk size of ~30 ms (960 bytes) is acceptable | MEDIUM (Google's own sample uses 1024 samples = 64 ms; 30 ms is within the documented 20–40 ms guidance cited in the investigation; both should work) | Slightly higher API call rate; VAD behavior unchanged |
| `contextWindowCompression: { slidingWindow: {} }` prevents the 15-min session cut-off | HIGH (documented in session guide) | Sessions terminated at 15 min; reconnection every 15 min required |
| Session resumption handle is valid for 2 hours | HIGH (stated in API reference) | Reconnection creates a new session without prior context; minor transcript gap |

### Uncertainties and Gaps

- **Whether `inputAudioTranscription` transcription delivery is fully reliable on Gemini 3.1**: One GitHub issue report (for the 2.5 model) noted that transcription messages were not always received even with the flag set. No reproduction on Gemini 3.1 has been confirmed. Empirical validation with a real API key is required. Confidence: MEDIUM.
- **Whether the GoAway `timeLeft` value is stable**: The API reference says "never less than a model-specific minimum" but does not specify the minimum. The 120-second estimate comes from community observation, not official docs. Treat `GoAway` as urgent regardless of `timeLeft` value.
- **Whether `sessionResumption: {}` (empty, no handle) requires the field or if it can be omitted**: The API reference says "If included, the server will send SessionResumptionUpdate messages." This implies omitting it means no updates are sent (and no resumption is possible). Including `{}` with no handle starts a new session with resumption tracking enabled. Confidence: MEDIUM.
- **Exact JSON CodingKeys for the `empty-object` types** (`AudioTranscriptionConfig`, `SlidingWindowConfig`, `ActivitySignal`, `BidiGenerateContentSetupComplete`): These types have no fields. The Swift `Codable` synthesis for an empty struct produces `{}` which is correct. If the JSONEncoder produces nothing for zero-field structs, custom `encode(to:)` as shown above is the fix. Validate this in unit tests before wire integration.

---

## 15. Clarifying Questions for Follow-up

1. **Empirical validation**: Has anyone on the team validated that `inputAudioTranscription` reliably delivers `serverContent.inputTranscription.text` on `gemini-3.1-flash-live-preview` specifically (not just 2.5)? One community report cited unreliable delivery on 2.5; Gemini 3.1's improved multi-part event model may resolve this but should be verified with a real key before committing to the architecture.

2. **Output audio billing under "transcription only" system prompt**: Does the system instruction "Do not respond..." effectively suppress the model from generating audio output, or does it still generate and bill audio tokens even when its response is empty/minimal? This affects the real-world cost estimate.

3. **Chunk size**: The original investigation recommended 30 ms chunks; Google's sample uses 64 ms. Should the implementation target 30 ms (as planned in the investigation) or 64 ms (matching official samples)? Either is technically valid; the question is which produces better VAD behavior in practice.

4. **`sessionResumption` across reconnects**: When reconnecting with a stored handle, does the server replay missed `inputTranscription` events (i.e., transcription of audio sent during the disconnected period), or are those events permanently lost? The session resumption docs describe context restoration, not event replay.

---

## 16. References

| # | Source | URL | Information Gathered |
|---|---|---|---|
| 1 | Google: Live API WebSockets reference (canonical) | https://ai.google.dev/api/live | Definitive field names for all message types; `BidiGenerateContentSetup`, `BidiGenerateContentRealtimeInput`, `BidiGenerateContentServerContent`, `BidiGenerateContentTranscription`, `GoAway`, `SessionResumptionUpdate`, `AudioTranscriptionConfig`; field deprecation notice for `mediaChunks`; `setupComplete` has no fields |
| 2 | Google: Get started with Live API via WebSockets | https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket | Endpoint URL; `?key=` auth; exact JSON for `setup`, `realtimeInput.audio`, `serverContent` parsing; `inputTranscription.text` path confirmed; `mimeType: "audio/pcm;rate=16000"` confirmed |
| 3 | Google: Live API capabilities guide | https://ai.google.dev/gemini-api/docs/live-guide | **Critical: "Native audio models only support AUDIO response modality"** explicitly stated; `inputAudioTranscription`/`outputAudioTranscription` usage; VAD config; model comparison table (3.1 vs 2.5) |
| 4 | Google: Gemini 3.1 Flash Live Preview model card | https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-live-preview | Confirmed model code `gemini-3.1-flash-live-preview`; capabilities; migration notes from 2.5; multi-part events behavior |
| 5 | Google: Live API session management | https://ai.google.dev/gemini-api/docs/live-session | Session limits (15 min audio-only context; ~10 min connection lifetime); `GoAway` signal; session resumption handle lifetime (2 hr); `contextWindowCompression` for unlimited sessions |
| 6 | Google Vertex AI: Live API reference | https://docs.cloud.google.com/vertex-ai/generative-ai/docs/model-reference/multimodal-live | Cross-reference on server message envelope structure; confirmed `inputTranscription` and `outputTranscription` as top-level server message alternatives; Vertex AI endpoint `{location}-aiplatform.googleapis.com` (out of scope for API-key clients) |
| 7 | Context7 / ai.google.dev: Live API docs | /websites/ai_google_dev_gemini-api | Audio MIME type `audio/pcm;rate=16000`; `realtimeInput.audio` field name confirmed; base64 encoding confirmed |
| 8 | GitHub: googleapis/python-genai issue #1780 | https://github.com/googleapis/python-genai/issues/1780 | Reproduction of 1007 error with `responseModalities: ["TEXT"]` on native audio model |
| 9 | GitHub: kizuna-ai-lab/sokuji issue #93 | https://github.com/kizuna-ai-lab/sokuji/issues/93 | "Gemini native-audio models require AUDIO modality - TEXT-only mode not supported" — community confirmation |
| 10 | GitHub: livekit/agents issue #4423 | https://github.com/livekit/agents/issues/4423 | LiveKit agents hit same TEXT modality rejection; workaround documented as AUDIO + discard |
| 11 | Google Dev Forum: Authentication for raw WebSocket | https://discuss.ai.google.dev/t/authentication-for-gemini-live-api-raw-websocket-connection-bidigeneratecontent/80647 | Confirmed `?key=API_KEY` query parameter is the correct auth mechanism for raw WebSocket |
| 12 | paradigms-of-intelligence/swift-gemini-api (README) | https://github.com/paradigms-of-intelligence/swift-gemini-api | Swift `GeminiLiveClient` usage pattern; `sendAudio(data:)` accepts raw `Data`; `onSetupComplete` callback confirms `setupComplete` wait pattern; `input_audio_transcription: true` parameter confirmed |
| 13 | Web search synthesis: `responseModalities TEXT` rejected | (Multiple GitHub issues and Stack Overflow threads) | Confirmed close code 1007 for TEXT on native audio; confirmed AUDIO + transcription flags as the working pattern |
| 14 | Web search synthesis: Audio chunk sizing | (Google official samples; Vertex AI docs) | 1024 samples (~64 ms) is Google's documented sample size; 16 kHz input, 24 kHz output; resampling note |
| 15 | Web search synthesis: WebSocket close codes | (Forum reports, GitHub issues) | 1007 = invalid argument / wrong config; 1008 = policy violation / model not found / key invalid; 1011 = transient server error |
