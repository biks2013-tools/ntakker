---
research_for: investigation-soniox-streaming.md
researched_at: "2026-04-29"
depth: intermediate
topic: "Soniox WebSocket wire-schema deep dive (request and response shapes)"
sources:
  - https://soniox.com/docs/stt/api-reference/websocket-api
  - https://soniox.com/docs/stt/api-reference/websocket-api.mdx
  - https://soniox.com/docs/stt/rt/real-time-transcription
  - https://soniox.com/docs/stt/rt/endpoint-detection
  - https://soniox.com/docs/stt/rt/manual-finalization
  - https://soniox.com/docs/stt/rt/connection-keepalive
  - https://soniox.com/docs/stt/rt/error-handling
  - https://soniox.com/docs/stt/rt/limits-and-quotas
  - https://soniox.com/docs/stt/concepts/language-hints
  - https://soniox.com/docs/stt/concepts/language-identification
  - https://soniox.com/docs/stt/concepts/language-restrictions
  - https://soniox.com/docs/stt/concepts/speaker-diarization
  - https://soniox.com/docs/stt/concepts/context
  - https://soniox.com/docs/stt/concepts/supported-languages
  - https://soniox.com/docs/stt/models
  - https://soniox.com/docs/stt/data-residency
  - https://soniox.com/docs/sdk/node-SDK/reference/types
  - https://reference-server.pipecat.ai/en/latest/_modules/pipecat/services/soniox/stt.html
  - https://soniox.com/blog/2026-02-05-soniox-v4-real-time
---

# Soniox WebSocket Wire Schema

## CRITICAL FINDINGS — Read Before Implementing

The following findings **sharpen or correct** details that were uncertain in
`investigation-soniox-streaming.md`:

1. **The `finished` response is NOT a bare `{"finished": true}`.** The canonical
   wire shape is a full token-response envelope with `finished: true` appended:
   `{"tokens": [], "final_audio_proc_ms": N, "total_audio_proc_ms": N, "finished": true}`.
   The `tokens` array is present (usually empty) and both timing fields are present.
   A bare `{"finished": true}` would fail `Decodable` conformance if the struct
   requires `tokens`, `final_audio_proc_ms`, and `total_audio_proc_ms`.

2. **Error responses also carry the `tokens` array.** The error envelope is
   `{"tokens": [], "error_code": N, "error_message": "..."}`, NOT a separate
   message type. A single `SonioxServerMessage` struct with all fields optional
   handles both normal responses and errors without a discriminant field.

3. **`<end>` and `<fin>` are delivered as ordinary tokens with special `text`
   values.** They appear as a token object inside the `tokens` array, with
   `is_final: true` and `confidence` typically `1.0`. There is no separate
   top-level field (no `"type": "endpoint"` marker outside the token array).
   Detection: `token.text == "<end>"` or `token.text == "<fin>"`.

4. **The end-of-stream frame MUST be an empty string text frame, not an empty
   binary Data frame.** The Pipecat open-source implementation (the most
   comprehensive reference implementation available) sends `""` (empty string) as
   a WebSocket text message, not `Data()` (empty binary). The official docs say
   "binary or text" but the SDK sends an empty text frame. For `URLSessionWebSocketTask`
   use `.string("")` rather than `.data(Data())`. **Inferred — confirm with probe script.**

5. **Session duration is 300 minutes (5 hours), NOT 5 hours as stated in the
   investigation.** 300 min = 5 h exactly — both are correct — but the Limits &
   Quotas page confirms "300 minutes" as the hard cap per session.

6. **Regional endpoints exist.** The US endpoint `wss://stt-rt.soniox.com/transcribe-websocket`
   is default. EU (`wss://stt-rt.eu.soniox.com/transcribe-websocket`) and
   Japan (`wss://stt-rt.jp.soniox.com/transcribe-websocket`) variants are available
   for data-residency projects. `MACREC_SONIOX_ENDPOINT` is therefore useful
   immediately, not just forward-looking.

7. **The Node SDK's default keepalive interval is 5 000 ms (5 s), not 10 s.**
   The investigation recommended 10 s; 5 s is safe and aligned with the SDK
   default. The hard ceiling is 20 s of silence before the server may close.

8. **`language_hints` order matters for tie-breaking but NOT for restriction.**
   The docs do not guarantee that the first element is "preferred" — hints are a
   probability bias. For `["el", "en"]` vs `["en", "el"]`, there is no documented
   priority difference. **Inferred — confirm with probe script** using a known
   Greek audio sample.

9. **`400 Bad Request` ("Invalid language hint.") is the error for unsupported or
   malformed language codes.** BCP-47 codes like `"el-GR"` are not automatically
   stripped — they will cause a `400` error. The provider must strip region tags
   before sending.

10. **`503 Service Unavailable` is the mid-session reconnect signal**, not a
    standard 5xx server outage. `503` with message
    `"Cannot continue request (code N). Please restart the request."` means the
    server terminated the session early (e.g., model overload). The client
    should reconnect immediately rather than back off.

---

## Overview

The Soniox real-time STT WebSocket protocol is deliberately flat. A single
persistent WebSocket connection carries:

- **One** JSON text frame from client → server: the session config.
- **N** binary frames from client → server: raw PCM audio.
- **Occasional** JSON text frames from client → server: `keepalive` and `finalize`
  control messages.
- **One** empty text (or binary) frame from client → server: end-of-stream signal.
- **M** JSON text frames from server → client: token-response batches.
- **One** JSON text frame from server → client: the `finished` response.
- OR **one** JSON text frame from server → client: an error response (then close).

There is no setup-acknowledgment message (unlike Gemini Live's `setupComplete`).
The server begins transcribing the moment it receives the first audio frame.
There is no session-resumption protocol.

---

## 1. Connection and Authentication

### Canonical Endpoint

```
wss://stt-rt.soniox.com/transcribe-websocket
```

### Regional Endpoint Variants

| Region | WebSocket Endpoint |
|---|---|
| United States (default) | `wss://stt-rt.soniox.com/transcribe-websocket` |
| European Union | `wss://stt-rt.eu.soniox.com/transcribe-websocket` |
| Japan | `wss://stt-rt.jp.soniox.com/transcribe-websocket` |

Regional endpoints are tied to a project's data-residency setting in the Soniox
Console. An API key from a regional project must use that region's endpoint.

### TLS / Transport Requirements

- WebSocket over TLS (`wss://`). Standard TLS; no pinning requirement documented.
- No custom HTTP headers are required during the WebSocket handshake.
- No `Sec-WebSocket-Protocol` subprotocol is required or documented.
- Authentication occurs entirely inside the JSON session-config message sent after
  the connection is open.

**Swift URLRequest setup (no special headers):**

```swift
let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
let task = URLSession.shared.webSocketTask(with: url)
task.resume()
// No custom headers needed. API key goes inside the first JSON message.
```

### Authentication Mechanism

The API key is sent in the **first JSON message** as the `api_key` field. It is
never placed in the URL, never in a `Authorization` HTTP header, and never in a
`Sec-WebSocket-Protocol` value. This is a privacy advantage over Gemini Live
(whose key sits in the URL).

### Connection-Level Limits

| Limit | Value | Notes |
|---|---|---|
| Stream duration | 300 minutes per session | Hard cap; open a new session to continue |
| Concurrent sessions per org | 10 (default) | Raiseable via Soniox Console |
| Requests per minute | 100 (default) | Raiseable via Soniox Console |
| Max `client_reference_id` length | 256 chars | `400` if exceeded |
| Max `context` total length | 10 000 chars | `400` if exceeded |
| No-audio idle timeout | 20 s | Send `keepalive` at least every 20 s |

---

## 2. Message Catalog — Client → Server

### 2.1 Session Config Message (first message, TEXT frame, JSON)

This is the ONLY configuration message. It must be sent before any audio.
The server begins processing audio immediately after receiving this message;
there is no explicit acknowledgment.

#### Full wire JSON (all supported fields)

```json
{
  "api_key": "<SONIOX_API_KEY>",
  "model": "stt-rt-v4",
  "audio_format": "pcm_s16le",
  "sample_rate": 16000,
  "num_channels": 1,
  "language_hints": ["el", "en"],
  "language_hints_strict": false,
  "enable_language_identification": true,
  "enable_endpoint_detection": true,
  "max_endpoint_delay_ms": 2000,
  "enable_speaker_diarization": false,
  "context": {
    "general": [
      { "key": "domain", "value": "meeting" }
    ],
    "text": "Background text context here.",
    "terms": ["MacRec", "ScreenCaptureKit"],
    "translation_terms": [
      { "source": "MacRec", "target": "MacRec" }
    ]
  },
  "client_reference_id": "macrec-<recordingId>-<source>",
  "translation": {
    "type": "one_way",
    "target_language": "en"
  }
}
```

> **For `macrec`** — use only the subset below. Do NOT include `translation`,
> `enable_speaker_diarization`, or `context` unless the plan explicitly enables them.
> Soniox is documented to return `400` for malformed parameters but NOT for
> unknown fields (this is unconfirmed — see Assumption table). However, sending
> only known fields is safest. **Inferred — confirm with probe script.**

#### Minimal recommended config for `macrec`

```json
{
  "api_key": "<SONIOX_API_KEY>",
  "model": "stt-rt-v4",
  "audio_format": "pcm_s16le",
  "sample_rate": 16000,
  "num_channels": 1,
  "language_hints": ["el", "en"],
  "language_hints_strict": false,
  "enable_language_identification": true,
  "enable_endpoint_detection": true,
  "max_endpoint_delay_ms": 2000,
  "client_reference_id": "macrec-<recordingId>-<source>"
}
```

#### Field-by-field reference

| Field | Type | Required | Default | Notes |
|---|---|---|---|---|
| `api_key` | string | YES | — | Long-lived API key or temporary key (≤3600 s); NEVER in URL |
| `model` | string | YES | — | `"stt-rt-v4"` (current active real-time model) |
| `audio_format` | string | YES | — | See §2.1.1. `"pcm_s16le"` for raw PCM; `"auto"` for container formats |
| `sample_rate` | number | YES (raw) | — | Integer Hz; required for all raw PCM formats; not needed for `"auto"` |
| `num_channels` | number | YES (raw) | — | 1 (mono); not needed for `"auto"` |
| `language_hints` | `string[]` | NO | — | ISO 639-1 codes ONLY (e.g. `"el"`, `"en"`). NOT BCP-47. `"el-GR"` → `400` error |
| `language_hints_strict` | bool | NO | false | true = strongly bias to listed languages only (best-effort); best with single language |
| `enable_language_identification` | bool | NO | false | Adds `language` field to each token |
| `enable_endpoint_detection` | bool | NO | false | Emits `<end>` token at utterance boundary |
| `max_endpoint_delay_ms` | number | NO | 2000 | 500–3000 ms; lower = faster endpoint but more false triggers |
| `enable_speaker_diarization` | bool | NO | false | Adds `speaker` field to each token |
| `context` | object | NO | — | Domain biasing; see §2.1.2 |
| `client_reference_id` | string | NO | — | Max 256 chars; appears in Soniox Console logs for debugging |
| `translation` | object | NO | — | One-way or two-way translation; out of scope for `macrec` |

#### 2.1.1 Audio Format Values

**Auto-detected formats (set `audio_format: "auto"`, omit `sample_rate` and `num_channels`):**

```json
{ "audio_format": "auto" }
```

Soniox auto-detects: WAV, MP3, FLAC, Ogg/Vorbis, WebM/Opus, AAC, and other
common container formats from the binary stream header.

**Raw PCM formats (must include `sample_rate` and `num_channels`):**

| `audio_format` value | Bit depth | Encoding | Notes |
|---|---|---|---|
| `"pcm_s8"` | 8-bit | Signed integer | Little-endian |
| `"pcm_s16le"` | 16-bit | Signed integer | **Recommended for `macrec`** — matches `AudioDownsampler` output |
| `"pcm_s16be"` | 16-bit | Signed integer | Big-endian |
| `"pcm_s24le"` | 24-bit | Signed integer | Little-endian |
| `"pcm_s24be"` | 24-bit | Signed integer | Big-endian |
| `"pcm_s32le"` | 32-bit | Signed integer | Little-endian |
| `"pcm_s32be"` | 32-bit | Signed integer | Big-endian |
| `"pcm_u8"` | 8-bit | Unsigned integer | — |
| `"pcm_u16le"` | 16-bit | Unsigned integer | Little-endian |
| `"pcm_u16be"` | 16-bit | Unsigned integer | Big-endian |
| `"pcm_u24le"` | 24-bit | Unsigned integer | Little-endian |
| `"pcm_u24be"` | 24-bit | Unsigned integer | Big-endian |
| `"pcm_u32le"` | 32-bit | Unsigned integer | Little-endian |
| `"pcm_u32be"` | 32-bit | Unsigned integer | Big-endian |
| `"pcm_f32le"` | 32-bit float | IEEE 754 | Little-endian |
| `"pcm_f32be"` | 32-bit float | IEEE 754 | Big-endian |
| `"pcm_f64le"` | 64-bit float | IEEE 754 | Little-endian |
| `"pcm_f64be"` | 64-bit float | IEEE 754 | Big-endian |
| `"mulaw"` | 8-bit | G.711 µ-law | Telecom companding |
| `"alaw"` | 8-bit | G.711 A-law | Telecom companding |

**Example config for `pcm_s16le` at 16 kHz mono:**

```json
{
  "api_key": "...",
  "model": "stt-rt-v4",
  "audio_format": "pcm_s16le",
  "sample_rate": 16000,
  "num_channels": 1
}
```

#### 2.1.2 Context Object Format

```json
{
  "context": {
    "general": [
      { "key": "domain",   "value": "Healthcare" },
      { "key": "topic",    "value": "Cardiology consultation" },
      { "key": "doctor",   "value": "Dr. Smith" }
    ],
    "text": "Longer free-form background text, up to the 10 000-char total limit.",
    "terms": [
      "Amoxicillin",
      "ScreenCaptureKit",
      "MacRec"
    ],
    "translation_terms": [
      { "source": "MacRec", "target": "MacRec" }
    ]
  }
}
```

All four sections (`general`, `text`, `terms`, `translation_terms`) are optional.
Include only what is relevant. Total context string length must not exceed
10 000 characters (400 error if exceeded).

#### 2.1.3 Language Hints — Critical Details

- **Format**: ISO 639-1 two-letter codes ONLY. `"en"`, `"el"`, `"es"`, etc.
- **NOT BCP-47**: `"el-GR"`, `"en-US"`, `"en-GB"` will cause a `400 Bad Request`
  with message `"Invalid language hint."`.
- **Order**: hints are a bias, not a priority queue. Order does not guarantee which
  language is preferred when both are acoustically plausible. **Inferred — confirm
  with probe script.**
- **Strict mode**: `language_hints_strict: true` strongly restricts to listed
  languages. Best with a single language only. Using `["el", "en"]` + `strict: true`
  may degrade accuracy on ambiguous speech.
- **For `macrec`**: use `language_hints: ["el", "en"]` with `language_hints_strict: false`
  to bias without restriction. This allows unexpected languages to still be
  transcribed, which is consistent with the "no-fallback" posture.

### 2.2 Audio Frame Messages (BINARY frames)

After the config message, all subsequent audio is sent as raw binary WebSocket
frames. There is NO JSON envelope around audio data — just the raw bytes.

```
Frame type:  BINARY
Payload:     raw PCM bytes (e.g. Int16 LE, 16 kHz, mono)
Length:      implementation choice; ~2048 bytes (1024 samples × 2 bytes) typical
Header:      NONE — no WAV/RIFF header, no length prefix, no framing
```

**Key facts:**

- Frame boundaries have NO semantic meaning. The server accumulates a continuous
  stream; chunk size only affects network granularity.
- Typical chunk size: **2048 bytes** (1024 samples at 16 kHz = ~64 ms of audio).
  This matches Gemini Live precedent in the project.
- The server tolerates consecutive frames without pacing. Back-pressure from the
  server is not documented. **Inferred — confirm with probe script.**
- Audio must arrive at near-real-time speed. Prolonged bursts or lags may result
  in `408` disconnection (message: `"Input too slow"`).
- Float32 → Int16 conversion must be done in the provider before sending. The
  `AudioDownsampler` already produces Int16 LE at 16 kHz mono.

**Swift send pattern:**

```swift
// pcm16Data: Data containing raw Int16 LE samples at 16 kHz, mono
try await webSocketTask.send(.data(pcm16Data))
```

### 2.3 Control Messages (TEXT frames, JSON)

Control messages are sent as JSON text frames. They can be sent at any point
during the session, interleaved with binary audio frames.

#### Keepalive

```json
{ "type": "keepalive" }
```

- **When to send**: whenever no audio has been sent for ≥ 5 s. Hard requirement:
  at least once every 20 s of silence, or the server closes the connection.
- **Server response**: none. Keepalive is fire-and-forget.
- **Recommended cadence for `macrec`**: send every 10 s when audio is paused
  (gives a 2× safety margin over the 20 s ceiling).

```swift
let keepalive = """
{"type": "keepalive"}
"""
try await webSocketTask.send(.string(keepalive))
```

#### Finalize

```json
{ "type": "finalize" }
```

- **Effect**: forces all pending non-final tokens to be finalized immediately.
  The server emits a batch of final tokens followed by the `<fin>` marker token.
  Audio streaming may continue afterward.
- **When to send**: on recording Pause (to flush pending utterance before
  suspending audio).
- **Restriction**: do NOT send too frequently. The documentation warns that
  sending `finalize` every few seconds may cause disconnections. Sending once per
  Pause event is fine.
- **Timing guidance**: send `finalize` only after ≥ 200 ms of silence following
  the end of speech. Triggering too early degrades accuracy.

```swift
let finalize = """
{"type": "finalize"}
"""
try await webSocketTask.send(.string(finalize))
```

### 2.4 End-of-Stream Signal

The end of stream is signaled by sending an **empty text frame** (empty string):

```swift
// End-of-stream: empty string text frame
try await webSocketTask.send(.string(""))
```

The docs say "binary or text" but reference SDK implementations use an empty
string text message. Using `.data(Data())` (empty binary) should also work per
the spec. **Inferred — confirm with probe script using both variants.**

After receiving the end-of-stream frame, the server:

1. Finalizes any remaining audio.
2. Emits any final token batches.
3. Emits the `finished` response.
4. Closes the WebSocket connection.

---

## 3. Message Catalog — Server → Client

All server messages are **JSON text frames**. There is a single structural
envelope (`SonioxServerMessage`) that covers normal token responses, the finished
response, and error responses. Fields are differentiated by which optional fields
are populated.

### 3.1 Streaming Token Response (normal, mid-session)

A batch of tokens emitted as audio is transcribed. May contain final tokens,
non-final tokens, or a mix of both.

#### Example: Non-final tokens only (instant feedback)

```json
{
  "tokens": [
    {
      "text": "How",
      "start_ms": 120,
      "end_ms": 280,
      "confidence": 0.72,
      "is_final": false
    },
    {
      "text": " are",
      "start_ms": 280,
      "end_ms": 440,
      "confidence": 0.68,
      "is_final": false
    }
  ],
  "final_audio_proc_ms": 0,
  "total_audio_proc_ms": 440
}
```

#### Example: Mixed final + non-final tokens

```json
{
  "tokens": [
    {
      "text": "How",
      "start_ms": 120,
      "end_ms": 280,
      "confidence": 0.97,
      "is_final": true
    },
    {
      "text": " are",
      "start_ms": 280,
      "end_ms": 440,
      "confidence": 0.94,
      "is_final": true
    },
    {
      "text": " you",
      "start_ms": 440,
      "end_ms": 600,
      "confidence": 0.61,
      "is_final": false
    }
  ],
  "final_audio_proc_ms": 440,
  "total_audio_proc_ms": 600
}
```

#### Example: All final tokens (endpoint detected, includes `<end>` marker)

```json
{
  "tokens": [
    {
      "text": " doing",
      "start_ms": 600,
      "end_ms": 880,
      "confidence": 0.95,
      "is_final": true
    },
    {
      "text": "?",
      "start_ms": 880,
      "end_ms": 920,
      "confidence": 0.91,
      "is_final": true
    },
    {
      "text": "<end>",
      "start_ms": 920,
      "end_ms": 920,
      "confidence": 1.0,
      "is_final": true
    }
  ],
  "final_audio_proc_ms": 920,
  "total_audio_proc_ms": 920
}
```

#### Example: With `language` field (when `enable_language_identification: true`)

```json
{
  "tokens": [
    {
      "text": "Καλημέρα",
      "start_ms": 120,
      "end_ms": 480,
      "confidence": 0.97,
      "is_final": true,
      "language": "el"
    },
    {
      "text": " good",
      "start_ms": 500,
      "end_ms": 640,
      "confidence": 0.89,
      "is_final": true,
      "language": "en"
    },
    {
      "text": " morning",
      "start_ms": 640,
      "end_ms": 820,
      "confidence": 0.93,
      "is_final": true,
      "language": "en"
    },
    {
      "text": "<end>",
      "start_ms": 820,
      "end_ms": 820,
      "confidence": 1.0,
      "is_final": true,
      "language": "en"
    }
  ],
  "final_audio_proc_ms": 820,
  "total_audio_proc_ms": 820
}
```

#### Example: With `speaker` field (when `enable_speaker_diarization: true`)

```json
{
  "tokens": [
    {
      "text": "Hello",
      "start_ms": 600,
      "end_ms": 760,
      "confidence": 0.97,
      "is_final": true,
      "speaker": "1"
    },
    {
      "text": " there",
      "start_ms": 760,
      "end_ms": 900,
      "confidence": 0.95,
      "is_final": true,
      "speaker": "1"
    }
  ],
  "final_audio_proc_ms": 900,
  "total_audio_proc_ms": 900
}
```

#### Token field reference

| Field | Type | Always present? | Notes |
|---|---|---|---|
| `text` | string | YES | The transcribed text; may be `"<end>"` or `"<fin>"` |
| `start_ms` | number | Usually | Start timestamp ms relative to audio stream start; absent when `translation_status == "translation"` |
| `end_ms` | number | Usually | End timestamp ms relative to audio stream start; absent for translation tokens |
| `confidence` | number | YES | 0.0–1.0; `<end>` and `<fin>` tokens typically have `1.0` |
| `is_final` | bool | YES | `true` = never changes; `false` = provisional, may be revised |
| `language` | string | When LID enabled | ISO 639-1 code (e.g. `"el"`, `"en"`); absent if `enable_language_identification: false` |
| `speaker` | string | When diarization enabled | Speaker label (e.g. `"1"`, `"2"`); absent if `enable_speaker_diarization: false` |
| `translation_status` | string | When translation enabled | `"none"`, `"original"`, or `"translation"`; absent for non-translation sessions |
| `source_language` | string | When translation enabled | Source language of translated token; absent for non-translation sessions |

#### Response-level fields

| Field | Type | Always present? | Notes |
|---|---|---|---|
| `tokens` | `Token[]` | YES | May be empty `[]` (e.g., in the finished response) |
| `final_audio_proc_ms` | number | YES | Milliseconds of audio committed to final tokens |
| `total_audio_proc_ms` | number | YES | Milliseconds of audio processed in total (final + non-final) |
| `finished` | bool | Only in last response | `true` in the terminal response after empty-frame close |
| `error_code` | number | Only in error response | HTTP status code (see §3.4) |
| `error_message` | string | Only in error response | Human-readable error description |

### 3.2 Endpoint Detection Response (`<end>` token)

The `<end>` token appears inside the `tokens` array as the last element of the
response batch that signals end of utterance. It is ALWAYS `is_final: true`.
Its `start_ms` and `end_ms` values equal the previous token's `end_ms`.

```json
{
  "tokens": [
    {
      "text": "<end>",
      "start_ms": 1240,
      "end_ms": 1240,
      "confidence": 1.0,
      "is_final": true,
      "language": "el"
    }
  ],
  "final_audio_proc_ms": 1240,
  "total_audio_proc_ms": 1240
}
```

**Detection in Swift:**

```swift
let isEndToken = token.text == "<end>"
```

### 3.3 Manual Finalization Response (`<fin>` token)

After the client sends `{"type": "finalize"}`, the server emits a batch
containing the finalized tokens and the `<fin>` marker. The `<fin>` token
always appears last, is always `is_final: true`, and its timestamps equal
the previous token's `end_ms`.

```json
{
  "tokens": [
    {
      "text": " recording",
      "start_ms": 2100,
      "end_ms": 2440,
      "confidence": 0.92,
      "is_final": true
    },
    {
      "text": "<fin>",
      "start_ms": 2440,
      "end_ms": 2440,
      "confidence": 1.0,
      "is_final": true
    }
  ],
  "final_audio_proc_ms": 2440,
  "total_audio_proc_ms": 2440
}
```

**Note**: if a `<fin>` token arrives and the buffer contains only `<fin>` (nothing
else), it means finalize was called with no in-flight audio — the response may be:

```json
{
  "tokens": [
    {
      "text": "<fin>",
      "start_ms": 0,
      "end_ms": 0,
      "confidence": 1.0,
      "is_final": true
    }
  ],
  "final_audio_proc_ms": 0,
  "total_audio_proc_ms": 0
}
```

**Inferred — confirm with probe script.**

**Detection in Swift:**

```swift
let isFinToken = token.text == "<fin>"
```

### 3.4 Finished Response (terminal, after end-of-stream frame)

The terminal response after the client sends the empty-frame close:

```json
{
  "tokens": [],
  "final_audio_proc_ms": 5600,
  "total_audio_proc_ms": 5600,
  "finished": true
}
```

The `tokens` array is always present (may be empty). Both timing fields are
always present. After emitting this response, the server closes the WebSocket.

**Detection in Swift:**

```swift
if message.finished == true {
    // Session complete — close local resources
}
```

### 3.5 Error Response

Error responses use the same envelope as token responses. The `tokens` array is
always present (empty), plus `error_code` and `error_message` are added.

```json
{
  "tokens": [],
  "error_code": 401,
  "error_message": "Invalid API key."
}
```

After emitting the error response, the server closes the WebSocket.

#### Complete error code catalog

| Code | Meaning | Example error messages | Recommended `macrec` action |
|---|---|---|---|
| **400** | Bad request / malformed config | `"Invalid language hint."`, `"Invalid model specified."`, `"Audio data channels must be specified for PCM formats"`, `"Context is too long (max length 10000)."`, `"Invalid audio data format: avi"`, `"Language hints must be unique."`, `"Missing API key."`, `"Start request is malformed."`, `"Start request must be a text message."`, `"No audio received."`, `"Received too much audio data in total."` | Log `MacrecError.transcriptionConfigError`; do NOT retry without fixing config |
| **401** | Authentication failure | `"Invalid API key."`, `"Invalid/expired temporary API key."`, `"Missing API key."` | Surface `MacrecError.transcriptionApiKeyInvalid`; stop retrying |
| **402** | Billing / quota exhausted | `"Organization balance exhausted. Please either add funds manually or enable autopay."`, `"Organization monthly budget exhausted. Please increase it."`, `"Project monthly budget exhausted. Please increase it."` | Emit `.warning` event; recording continues; sidecar may have gaps |
| **408** | Idle timeout / slow input | `"Request timeout."`, `"Start request timeout"`, `"Timed out while waiting for the first audio chunk"`, `"Input too slow"`, `"Audio data decode timeout"` | Reconnect immediately; if on Pause, verify keepalive is running |
| **429** | Rate limit / concurrent cap | `"Rate limit for your organization has been exceeded."`, `"Your organization has exceeded max number of concurrent requests."`, `"Your project has exceeded max number of concurrent requests."` | Back off with exponential delay; emit `.warning` |
| **500** | Internal server error | `"The server had an error processing your request. Sorry about that! You can retry your request..."` | Reconnect after short backoff (1–5 s); emit `.warning` |
| **503** | Session terminated early | `"Cannot continue request (code N). Please restart the request."` | Reconnect immediately; this is an expected operational event, not a bug |

---

## 4. Token Semantics — Non-final Evolution and Finalization

### 4.1 Non-final to Final Progression

Non-final tokens (`is_final: false`) are provisional. The server may:

1. Re-emit the same word with a different spelling/casing as a new non-final.
2. Merge multiple non-final tokens into fewer final tokens.
3. Emit a batch of all-final tokens when the preceding non-final tokens are
   confirmed.

The client is responsible for maintaining a non-final buffer and replacing it
on each new server response:

```
Time 1: tokens=["How're", "you"]                          (non-final)
Time 2: tokens=["How", " are", " you"]                    (non-final, revised)
Time 3: tokens=["How", " are", " you"] final + ["?"] nf   (mix)
Time 4: tokens=["How", " are", " you", "?", "<end>"]      (all final)
```

**Rule for `macrec`**:
- Accumulate non-final tokens in a buffer. Display them as `partial` events.
- Replace the buffer on each response (do not append non-final tokens).
- On receiving `<end>` or `<fin>`, concatenate all accumulated final tokens
  (excluding the marker), emit as `StreamingTranscriptionEvent.final`, and
  clear the buffer.

### 4.2 Segmentation Strategy for `macrec`

```
Non-final token received  →  emit partial event
Final token received       →  append to final_buffer
<end> or <fin> received    →  emit final event from final_buffer; clear buffer
```

For the `final` event:
- `text` = joined text of all final tokens between the previous and current marker
- `startTime` = `final_buffer.first.start_ms / 1000.0`
- `endTime` = `final_buffer.last.end_ms / 1000.0`
- `language` = mode of `language` fields (or first non-nil)
- `confidence` = average of `confidence` values

---

## 5. Session Lifecycle — Annotated Flow

```
CLIENT                                          SERVER
  |                                               |
  |-- WS Handshake (TLS, no subprotocol) -------->|
  |<----------------------------------------- 101 |
  |                                               |
  |-- JSON config (TEXT frame) ------------------>|  [session configured]
  |                                               |  [server begins accepting audio]
  |                                               |
  |-- Binary audio frame 1 (2048 bytes) -------->|
  |-- Binary audio frame 2 (2048 bytes) -------->|
  |-- Binary audio frame 3 (2048 bytes) -------->|
  |<-- JSON token response (non-final) ----------|
  |-- Binary audio frame 4 (2048 bytes) -------->|
  |<-- JSON token response (mix final+non-final) |
  |                                               |
  |  [recording paused by user]                  |
  |-- JSON {"type": "finalize"} (TEXT) -------->|
  |<-- JSON token response (final + <fin>) -------|
  |                                               |
  |  [keepalive loop begins, every 10 s]         |
  |-- JSON {"type": "keepalive"} (TEXT) -------->|
  |-- JSON {"type": "keepalive"} (TEXT) -------->|
  |                                               |
  |  [recording resumed by user]                 |
  |-- Binary audio frame N (2048 bytes) -------->|
  |<-- JSON token response (non-final) ----------|
  |<-- JSON token response (final + <end>) -------|
  |                                               |
  |  [user stops recording]                      |
  |-- Empty TEXT frame ("") (end-of-stream) ----->|
  |<-- JSON finished response -------------------|
  |<---- WS Close (server-initiated) ------------|
  |--- WS Close ack (CLIENT) -------------------->|
```

---

## 6. Pause / Resume / Split Semantics

### Pause (recording suspended, no new audio)

1. Send `{"type": "finalize"}`.
2. Wait for the `<fin>` token batch (up to 2 s).
3. Stop sending audio frames.
4. Start sending `{"type": "keepalive"}` every 10 s.
5. Keep the WebSocket connection open.

### Resume (recording restarted)

1. Stop the keepalive timer.
2. Resume sending binary audio frames.
3. The session continues as if uninterrupted (context preserved).

### Split (rotate sidecar output file)

The recommended strategy (per the investigation) is to close the current
WebSocket session and open a new one for the next segment:

1. Send empty TEXT frame `""` (end-of-stream).
2. Wait up to 2 s for the `finished` response.
3. Close the WebSocket.
4. Open a new WebSocket connection for the next segment.
5. Send a fresh config message (same settings, new `client_reference_id`).

**Rationale**: Soniox does NOT support session resumption. Opening a new WebSocket
is the only way to reset the context for a new segment. The 300-min session cap
makes this even more important for long recordings.

### Mid-stream Silence (no VAD, audio present but quiet)

If the user is silent but recording is active, audio frames still flow (containing
near-zero PCM data). The server handles silence correctly — no keepalive is needed
while audio frames are being sent. Only send keepalive when audio frames have
STOPPED (e.g., on actual Pause, not just silence in the audio).

---

## 7. Error Handling — Connection Close Behavior

The Soniox server uses standard WebSocket close codes (RFC 6455). All error
information is conveyed BEFORE the close in the JSON error response. There is
no error-discriminant in the WebSocket close code itself.

Typical close sequence on error:

```
Server → JSON error response: {"tokens": [], "error_code": 401, "error_message": "Invalid API key."}
Server → WebSocket CLOSE frame (code 1000 Normal Closure or 1001 Going Away)
```

The WebSocket close code is therefore NOT a reliable error discriminant. Always
parse the JSON error response first. **Inferred — confirm with probe script.**

In `URLSessionWebSocketTask`, connection close causes `task.receive()` to throw.
The JSON error response arrives as a regular message BEFORE the throw:

```swift
// Receive loop pattern
while true {
    do {
        let message = try await webSocketTask.receive()
        // Process message normally (may be error response)
        if case .string(let json) = message {
            let response = try decoder.decode(SonioxServerMessage.self, from: Data(json.utf8))
            if let code = response.errorCode {
                // Handle error before connection closes
                handle(errorCode: code, message: response.errorMessage)
                return
            }
            // ... handle normal response
        }
    } catch {
        // WebSocket closed — either normal (after finished) or abrupt
        break
    }
}
```

---

## 8. Greek (`el`) and English (`en`) Specifics

### Accuracy Benchmarks

- Soniox `stt-rt-v4` achieves **7.4% Word Error Rate (WER)** for Greek in
  independent benchmarks — the best among all tested STT providers (vs. 15.9% WER
  for OpenAI, per the Soniox 2025 benchmark report).
- Benchmarks normalize text (remove punctuation, ignore casing) before WER
  calculation. Real-world output WILL contain punctuation and proper casing —
  the WER improvement reflects acoustic accuracy, not formatting.
- English WER is also industry-leading per the same benchmark.

### Punctuation and Capitalization

- Soniox generates punctuation and capitalization automatically in the output
  (`stt-rt-v4`). Greek output uses standard Greek punctuation (`.`, `;` for
  question marks in some contexts — verify with probe script).
- Tokens may include punctuation attached to words (e.g., `"ευχαριστώ."` rather
  than `"ευχαριστώ"` + `"."`). The exact tokenization granularity for punctuation
  is not documented. **Inferred — confirm with probe script.**

### Language Identification in Real-time

- Language tags (`language` field) may be provisional for non-final tokens and
  can be revised as more context arrives. A token initially tagged as `"en"` may
  be re-tagged as `"el"` in the next response if surrounding context shifts.
- For final tokens, language tags are stable (will not be revised after `is_final:
  true`).
- Mixed Greek/English sentences: the model uses sentence-level coherence.
  An English word embedded in a Greek sentence (e.g., `"Κάνε screenshot"`) will
  likely be tagged as `"el"` for the whole sentence.

### Language Hint Ordering for Greek/English Bilingual

- Use `language_hints: ["el", "en"]` (Greek first) to signal that Greek is the
  primary language. This is a bias, not a hard constraint.
- `language_hints_strict: false` is essential for Greek/English bilingual use —
  strict mode degrades accuracy when both languages are plausible.
- If a session is expected to be English-only, override with `["en"]` and
  `language_hints_strict: false` (or `true` if only English is expected with no
  Greek whatsoever).

### Confidence Score Interpretation

- Confidence scores range from 0.0 to 1.0. Non-final tokens typically have
  lower confidence (0.5–0.8 range). Final tokens are usually 0.85–0.99.
- `<end>` and `<fin>` markers have confidence `1.0` (artificial; they are not
  ASR results).
- Confidence scores for Greek may be slightly lower than English for heavily
  accented or colloquial speech. **Inferred.**

---

## 9. Swift Implementation — `Codable` Type Definitions

These types can be placed directly in
`Sources/MacrecCore/Transcription/Providers/SonioxTypes.swift`.

```swift
import Foundation

// MARK: - Client → Server messages

/// Top-level client configuration message (first message, TEXT frame, JSON).
/// Sent exactly once at the start of the session.
struct SonioxSessionConfig: Encodable {
    let apiKey: String
    let model: String
    let audioFormat: String
    var sampleRate: Int?
    var numChannels: Int?
    var languageHints: [String]?
    var languageHintsStrict: Bool?
    var enableLanguageIdentification: Bool?
    var enableEndpointDetection: Bool?
    var maxEndpointDelayMs: Int?
    var enableSpeakerDiarization: Bool?
    var context: SonioxContext?
    var clientReferenceId: String?

    enum CodingKeys: String, CodingKey {
        case apiKey                     = "api_key"
        case model
        case audioFormat                = "audio_format"
        case sampleRate                 = "sample_rate"
        case numChannels                = "num_channels"
        case languageHints              = "language_hints"
        case languageHintsStrict        = "language_hints_strict"
        case enableLanguageIdentification = "enable_language_identification"
        case enableEndpointDetection    = "enable_endpoint_detection"
        case maxEndpointDelayMs         = "max_endpoint_delay_ms"
        case enableSpeakerDiarization   = "enable_speaker_diarization"
        case context
        case clientReferenceId          = "client_reference_id"
    }
}

/// Context object for vocabulary biasing.
struct SonioxContext: Encodable {
    var general: [SonioxContextEntry]?
    var text: String?
    var terms: [String]?
    var translationTerms: [SonioxTranslationTerm]?

    enum CodingKeys: String, CodingKey {
        case general
        case text
        case terms
        case translationTerms = "translation_terms"
    }
}

struct SonioxContextEntry: Encodable {
    let key: String
    let value: String
}

struct SonioxTranslationTerm: Encodable {
    let source: String
    let target: String
}

/// Control message for keepalive and finalize.
struct SonioxControlMessage: Encodable {
    let type: String  // "keepalive" or "finalize"
}

// MARK: - Server → Client messages

/// Server response envelope. All fields are optional because:
/// - Normal response: has tokens + timing fields
/// - Finished response: has tokens + timing + finished: true
/// - Error response: has tokens + error_code + error_message
struct SonioxServerMessage: Decodable {
    let tokens: [SonioxToken]
    let finalAudioProcMs: Int?
    let totalAudioProcMs: Int?
    let finished: Bool?
    let errorCode: Int?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case finalAudioProcMs   = "final_audio_proc_ms"
        case totalAudioProcMs   = "total_audio_proc_ms"
        case finished
        case errorCode          = "error_code"
        case errorMessage       = "error_message"
    }
}

/// A single transcription token.
struct SonioxToken: Decodable {
    let text: String
    let startMs: Int?
    let endMs: Int?
    let confidence: Double
    let isFinal: Bool
    let language: String?
    let speaker: String?
    let translationStatus: String?
    let sourceLanguage: String?

    enum CodingKeys: String, CodingKey {
        case text
        case startMs            = "start_ms"
        case endMs              = "end_ms"
        case confidence
        case isFinal            = "is_final"
        case language
        case speaker
        case translationStatus  = "translation_status"
        case sourceLanguage     = "source_language"
    }

    /// True if this token signals end of utterance (endpoint detection).
    var isEndMarker: Bool { text == "<end>" }

    /// True if this token signals manual finalization complete.
    var isFinMarker: Bool { text == "<fin>" }

    /// True if this token is a segment boundary marker.
    var isMarker: Bool { isEndMarker || isFinMarker }
}
```

---

## 10. Swift Implementation — WebSocket Session Pattern

```swift
import Foundation

// MARK: - Provider core

actor SonioxWebSocketSession {
    private var webSocketTask: URLSessionWebSocketTask?
    private let config: SonioxSessionConfig
    private let endpoint: URL
    private var keepaliveTask: Task<Void, Never>?

    init(config: SonioxSessionConfig, endpoint: URL) {
        self.config = config
        self.endpoint = endpoint
    }

    // MARK: Open

    func open() async throws {
        let task = URLSession.shared.webSocketTask(with: endpoint)
        task.resume()
        self.webSocketTask = task

        // Send config as the first JSON text frame
        let encoder = JSONEncoder()
        let configData = try encoder.encode(config)
        guard let configJSON = String(data: configData, encoding: .utf8) else {
            throw SonioxError.encodingFailed
        }
        // IMPORTANT: no wait for ack — Soniox does not send setupComplete
        try await task.send(.string(configJSON))
    }

    // MARK: Send audio

    func sendAudio(_ pcm16LEData: Data) async throws {
        guard let task = webSocketTask else { return }
        try await task.send(.data(pcm16LEData))
    }

    // MARK: Send control messages

    func sendKeepalive() async throws {
        guard let task = webSocketTask else { return }
        try await task.send(.string(#"{"type":"keepalive"}"#))
    }

    func sendFinalize() async throws {
        guard let task = webSocketTask else { return }
        try await task.send(.string(#"{"type":"finalize"}"#))
    }

    // MARK: End of stream

    func sendEndOfStream() async throws {
        guard let task = webSocketTask else { return }
        // Empty text frame signals end-of-stream per Soniox protocol
        // NOTE: docs say "binary or text" — empty string is what SDK implementations use
        try await task.send(.string(""))
    }

    // MARK: Keepalive management

    func startKeepalive(interval: TimeInterval = 10) {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                try? await self?.sendKeepalive()
            }
        }
    }

    func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    // MARK: Receive loop

    func receiveLoop() -> AsyncThrowingStream<SonioxServerMessage, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let task = self.webSocketTask else {
                    continuation.finish(throwing: SonioxError.notConnected)
                    return
                }
                let decoder = JSONDecoder()
                while true {
                    do {
                        let wsMessage = try await task.receive()
                        guard case .string(let json) = wsMessage else {
                            // Binary frames from server are not expected
                            continue
                        }
                        let serverMsg = try decoder.decode(
                            SonioxServerMessage.self,
                            from: Data(json.utf8)
                        )
                        continuation.yield(serverMsg)
                        if serverMsg.finished == true || serverMsg.errorCode != nil {
                            continuation.finish()
                            return
                        }
                    } catch {
                        // WebSocket closed (normal after finished, or abrupt on error)
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
        }
    }

    // MARK: Close

    func close() {
        stopKeepalive()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }
}

// MARK: - Config builder

func makeSonioxConfig(
    apiKey: String,
    model: String = "stt-rt-v4",
    recordingId: String,
    source: String,
    languageHints: [String] = ["el", "en"]
) -> SonioxSessionConfig {
    SonioxSessionConfig(
        apiKey: apiKey,
        model: model,
        audioFormat: "pcm_s16le",
        sampleRate: 16000,
        numChannels: 1,
        languageHints: languageHints,
        languageHintsStrict: false,
        enableLanguageIdentification: true,
        enableEndpointDetection: true,
        maxEndpointDelayMs: 2000,
        enableSpeakerDiarization: false,
        clientReferenceId: "macrec-\(recordingId)-\(source)"
    )
}

// MARK: - BCP-47 to ISO 639-1 stripping helper

/// Strips BCP-47 region subtags to produce Soniox-compatible ISO 639-1 codes.
/// "el-GR" → "el", "en-US" → "en", "en-GB" → "en", "zh-Hant" → "zh"
/// Sending BCP-47 codes to Soniox causes a 400 error: "Invalid language hint."
func sonioxLanguageCode(from bcp47: String) -> String {
    // ISO 639-1 codes are the first two lowercase characters before any hyphen
    let parts = bcp47.components(separatedBy: "-")
    return parts[0].lowercased()
}

// MARK: - Error types

enum SonioxError: Error, LocalizedError {
    case notConnected
    case encodingFailed
    case apiKeyInvalid(message: String)
    case quotaExhausted(message: String)
    case configurationError(code: Int, message: String)
    case rateLimitExceeded(message: String)
    case serverError(code: Int, message: String)
    case sessionTerminatedEarly(message: String)

    static func from(errorCode: Int, message: String) -> SonioxError {
        switch errorCode {
        case 401: return .apiKeyInvalid(message: message)
        case 402: return .quotaExhausted(message: message)
        case 400: return .configurationError(code: errorCode, message: message)
        case 429: return .rateLimitExceeded(message: message)
        case 503: return .sessionTerminatedEarly(message: message)
        default:  return .serverError(code: errorCode, message: message)
        }
    }
}
```

---

## 11. Complete Wire Lifecycle — Annotated JSON Trace

Below is the exact JSON bytes at each step of a minimal session (PCM16, mono,
16 kHz, two utterances in Greek and English, one pause).

### Step 1: Client → Server — Session Config (TEXT frame)

```json
{
  "api_key": "sk-proj-abc123...",
  "model": "stt-rt-v4",
  "audio_format": "pcm_s16le",
  "sample_rate": 16000,
  "num_channels": 1,
  "language_hints": ["el", "en"],
  "language_hints_strict": false,
  "enable_language_identification": true,
  "enable_endpoint_detection": true,
  "max_endpoint_delay_ms": 2000,
  "client_reference_id": "macrec-rec001-microphone"
}
```

### Step 2: Client → Server — Binary audio frames (BINARY frames, repeated)

```
[raw PCM16 LE bytes — 2048 bytes per frame, 16 kHz, mono, no header]
```

### Step 3: Server → Client — Non-final tokens (TEXT frame)

```json
{
  "tokens": [
    {
      "text": "Καλ",
      "start_ms": 80,
      "end_ms": 200,
      "confidence": 0.61,
      "is_final": false,
      "language": "el"
    }
  ],
  "final_audio_proc_ms": 0,
  "total_audio_proc_ms": 200
}
```

### Step 4: Server → Client — Revised non-final tokens (TEXT frame)

```json
{
  "tokens": [
    {
      "text": "Καλημέρα",
      "start_ms": 80,
      "end_ms": 480,
      "confidence": 0.78,
      "is_final": false,
      "language": "el"
    }
  ],
  "final_audio_proc_ms": 0,
  "total_audio_proc_ms": 480
}
```

### Step 5: Server → Client — Final tokens + endpoint marker (TEXT frame)

```json
{
  "tokens": [
    {
      "text": "Καλημέρα",
      "start_ms": 80,
      "end_ms": 480,
      "confidence": 0.97,
      "is_final": true,
      "language": "el"
    },
    {
      "text": " good",
      "start_ms": 520,
      "end_ms": 680,
      "confidence": 0.91,
      "is_final": true,
      "language": "en"
    },
    {
      "text": " morning",
      "start_ms": 680,
      "end_ms": 900,
      "confidence": 0.94,
      "is_final": true,
      "language": "en"
    },
    {
      "text": "<end>",
      "start_ms": 900,
      "end_ms": 900,
      "confidence": 1.0,
      "is_final": true,
      "language": "en"
    }
  ],
  "final_audio_proc_ms": 900,
  "total_audio_proc_ms": 900
}
```

→ On receiving `<end>`: emit `StreamingTranscriptionEvent.final` with
  `text = "Καλημέρα good morning"`, `startTime = 0.080`, `endTime = 0.900`.

### Step 6: Client → Server — Finalize on Pause (TEXT frame)

```json
{"type": "finalize"}
```

### Step 7: Server → Client — Finalization response with `<fin>` (TEXT frame)

```json
{
  "tokens": [
    {
      "text": " σε",
      "start_ms": 940,
      "end_ms": 1080,
      "confidence": 0.88,
      "is_final": true,
      "language": "el"
    },
    {
      "text": " παρακαλώ",
      "start_ms": 1080,
      "end_ms": 1360,
      "confidence": 0.93,
      "is_final": true,
      "language": "el"
    },
    {
      "text": "<fin>",
      "start_ms": 1360,
      "end_ms": 1360,
      "confidence": 1.0,
      "is_final": true,
      "language": "el"
    }
  ],
  "final_audio_proc_ms": 1360,
  "total_audio_proc_ms": 1360
}
```

→ On receiving `<fin>`: emit `StreamingTranscriptionEvent.final` with
  `text = " σε παρακαλώ"`, `startTime = 0.940`, `endTime = 1.360`.

### Step 8: Client → Server — Keepalive during pause (TEXT frame, every 10 s)

```json
{"type": "keepalive"}
```

### Step 9: Client → Server — End of stream (TEXT frame, empty string)

```
""
```

(An empty WebSocket TEXT frame — zero-byte payload after the frame header.)

### Step 10: Server → Client — Finished response (TEXT frame)

```json
{
  "tokens": [],
  "final_audio_proc_ms": 1360,
  "total_audio_proc_ms": 1360,
  "finished": true
}
```

→ Session complete. Server closes the WebSocket.

---

## 12. Best Practices and Common Pitfalls

### Best Practices

1. **Send config as TEXT frame, audio as BINARY frames.** The server discriminates
   by WebSocket frame type: TEXT = JSON control or config, BINARY = audio bytes.

2. **Do not include BCP-47 region tags in `language_hints`.** `"el-GR"` causes a
   `400` error. Always strip to ISO 639-1: `"el-GR" → "el"`, `"en-US" → "en"`.

3. **Do not wait for an acknowledgment after the config message.** Soniox starts
   processing the first audio frame immediately. Waiting for a non-existent ack
   will hang the session.

4. **Send keepalive every ≤ 10 s during pause (not during active audio).** While
   binary audio frames are flowing, keepalive is unnecessary. Only send keepalive
   when audio has stopped.

5. **Finalize before pausing; close with empty-frame when stopping.** This
   sequence ensures all in-flight tokens are committed and no utterance is lost.

6. **Handle `<end>` and `<fin>` as markers, not transcribed text.** Never include
   `"<end>"` or `"<fin>"` in the text output to users or sidecars.

7. **Use `max_endpoint_delay_ms: 2000` (the default).** Lower values increase
   false endpoint triggers; higher values increase latency. 2000 ms is the sweet
   spot for conversational speech.

8. **Log `client_reference_id`** with each session to correlate `macrec` logs
   against the Soniox Console's request log for debugging.

9. **Set `confidence` threshold for display**, not for discarding tokens. All
   final tokens will be emitted; confidence is an indication of certainty, not
   correctness.

10. **For split/rotation**, close the session cleanly (empty-frame → wait for
    `finished` → cancel task) before opening the next one to avoid duplicate
    tokens across segments.

### Common Pitfalls

| Pitfall | Consequence | Fix |
|---|---|---|
| Sending BCP-47 code (`"el-GR"`) in `language_hints` | `400 Bad Request: "Invalid language hint."` — session never starts | Strip region subtag before sending |
| Not sending keepalive during pause | `408 Request timeout: "Request timeout."` after 20 s | Start keepalive loop on Pause |
| Sending `finalize` too frequently (every few seconds) | Possible disconnection | Only send on Pause / Stop |
| Not checking for `<end>` and `<fin>` before rendering text | Users see `<end>` or `<fin>` in captions | Filter markers before emitting events |
| Treating `finished` as a bare `{"finished": true}` | Decoder fails if struct requires `tokens` field | Use optional `finished: Bool?` in the same envelope |
| Sending audio at faster-than-real-time speed (pre-recorded file test) | `408: "Input too slow"` (confusingly — actually TOO fast) | Throttle to real-time pace in test scripts |
| Including unknown fields in the config | Likely `400: "Start request is malformed."` | Only send documented fields **Inferred — confirm** |
| Opening a second session before the first is fully closed | Concurrent session count may hit limit (10 per org) | Always close cleanly before reopening |
| Parsing only `finished` and ignoring `error_code` on the same message | Error goes undetected | Parse all fields of every message |

---

## 13. Assumptions and Scope

### Assumptions Made

| Assumption | Confidence | Source | Impact if Wrong |
|---|---|---|---|
| End-of-stream is an empty TEXT frame (`.string("")`), not empty binary | MEDIUM | Pipecat Python SDK source code; vendor docs say "binary or text" | If binary is required, `task.send(.string(""))` will not trigger the `finished` response; use `task.send(.data(Data()))` instead |
| Server JSON error response arrives before the WebSocket close frame | HIGH | Pipecat implementation pattern; common WebSocket convention | If server closes without sending JSON error first, error details are lost — catch close code as fallback |
| Unknown fields in config cause `400` | LOW | No explicit documentation; `400` catalog mentions `"Start request is malformed."` | If server silently ignores unknown fields, not a problem; but to be safe, only send documented fields |
| `language_hints` order does not affect language priority | MEDIUM | Docs state "bias not restriction" without ordering semantics | If order matters, Greek should be listed first (`["el", "en"]`) for the bilingual use case |
| `<fin>` token on an empty finalize (no in-flight audio) still arrives | MEDIUM | Finalization docs state `<fin>` is always returned | If `<fin>` is not returned on an empty finalize, the finalize wait-logic will hang; add a timeout |
| WebSocket close code is always 1000 on both normal and error close | LOW | Not documented by Soniox | If error closes use distinct codes, they could be used for error discrimination |
| Confidence on `<end>` and `<fin>` tokens is always `1.0` | MEDIUM | Logical inference; marker tokens are not ASR results | If confidence varies, marker detection should rely on `text` comparison, not `confidence` threshold |
| Server tolerates back-to-back binary frames without pacing | MEDIUM | Not documented; `"Input too slow"` message implies too-fast is also penalized | If pacing is required, add a 20–30 ms sleep between frames in the test script |

### What is Explicitly Out of Scope

- **Translation** (`translation` field, `translation_status`, `source_language` tokens)
- **Speaker diarization** (`enable_speaker_diarization`, `speaker` token field)
- **Temporary API keys** (REST `POST /v1/auth/temporary-api-key`)
- **Async (non-streaming) API** (`stt-async-v4`)
- **REST transcription API**
- **TTS WebSocket API** (`wss://tts-rt.soniox.com/tts-websocket`)
- **Webhook callbacks**
- **Session resumption** (Soniox does not support this)

### Confidence Levels Summary

- HIGH confidence (multiple sources agree, official docs explicit): endpoint,
  error codes, audio format list, language code format, keepalive timing,
  `finished` envelope shape, token field names.
- MEDIUM confidence (one authoritative source or logical inference): `<end>`/`<fin>`
  timestamp behavior, empty `<fin>` response shape, language hint ordering,
  BCP-47 causing 400.
- LOW confidence (inferred from code, unverified): empty TEXT vs binary for
  end-of-stream, unknown field handling, WebSocket close code semantics.

---

## 14. Clarifying Questions for Follow-up

1. **End-of-stream frame type**: Does the server respond to an empty binary frame
   (`Data()`) as well as an empty text frame (`""`)? The probe script should test
   both to confirm which the Swift `URLSessionWebSocketTask` implementation should
   use.

2. **Empty `finalize` behavior**: If `finalize` is sent when no audio has been
   in-flight (e.g., immediately after a previous `<end>` or `<fin>`), does the
   server still return a `<fin>` token? Or does it return an empty `tokens: []`
   batch? This affects the pause-finalize wait logic.

3. **Language hint ordering**: Does the order of codes in `language_hints`
   produce any measurable bias difference (e.g., Greek first vs. English first)
   for genuinely bilingual audio? The probe script (AC-SX-4 bilingual test) should
   run both orders on the same audio to compare results.

4. **Unknown fields in config**: Does including an undocumented field in the config
   JSON cause a `400` error, or does the server ignore it? This determines whether
   the `SonioxSessionConfig` encoder needs `encodeIfPresent`-only patterns (which
   it should use regardless) or whether there is any risk of including extra keys.

5. **WebSocket close code on error**: What close code does the server use when
   closing after an error response? 1000 (normal) or 1001 (going away) or a
   different code? The probe script should capture the close code for all error
   scenarios (401, 402, 408).

6. **Punctuation token granularity for Greek**: Are punctuation marks (`.`, `;`,
   `,`) emitted as part of the preceding word token or as separate tokens? This
   affects how `macrec` joins tokens into sentences for the `.txt` sidecar.

7. **`<end>` token `start_ms` / `end_ms`**: The docs do not specify the timestamps
   for marker tokens. Do they equal the previous token's `end_ms`, or are they
   `0`, or do they reflect the actual endpoint detection time? The probe script
   should log these values.

---

## 15. References

| # | Source | URL | Information Gathered |
|---|---|---|---|
| 1 | Soniox WebSocket API reference (MDX source) | https://soniox.com/docs/stt/api-reference/websocket-api.mdx | Canonical verbatim JSON for config, response, finished, and error envelopes; full error code catalog (400–503); session duration 300 min |
| 2 | Soniox WebSocket API reference (rendered) | https://soniox.com/docs/stt/api-reference/websocket-api | Parameter list; audio streaming rules; end-of-stream handshake ("binary or text") |
| 3 | Soniox Real-time transcription | https://soniox.com/docs/stt/rt/real-time-transcription | Token evolution semantics (`is_final` lifecycle); audio format table; `pcm_s16le` confirmed; `final_audio_proc_ms` / `total_audio_proc_ms` semantics |
| 4 | Soniox Endpoint detection | https://soniox.com/docs/stt/rt/endpoint-detection | `<end>` token described; always `is_final: true`; appears once per detected endpoint; `max_endpoint_delay_ms` range 500–3000 |
| 5 | Soniox Manual finalization | https://soniox.com/docs/stt/rt/manual-finalization | `{"type": "finalize"}` wire format; `<fin>` token; "do not finalize too frequently"; 200 ms post-silence timing advice |
| 6 | Soniox Connection keepalive | https://soniox.com/docs/stt/rt/connection-keepalive | `{"type": "keepalive"}` wire format; 20 s hard deadline; 5–10 s recommended cadence |
| 7 | Soniox Error handling | https://soniox.com/docs/stt/rt/error-handling | Error response sent before connection close; `503` = reconnect immediately |
| 8 | Soniox Limits and quotas | https://soniox.com/docs/stt/rt/limits-and-quotas | 300 min/session cap; 10 concurrent sessions; 100 req/min |
| 9 | Soniox Language hints | https://soniox.com/docs/stt/concepts/language-hints | ISO 639-1 codes only; `language_hints` is a bias, not a restriction |
| 10 | Soniox Language identification | https://soniox.com/docs/stt/concepts/language-identification | Per-token `language` field; real-time tags may be revised; sentence-level coherence |
| 11 | Soniox Language restrictions | https://soniox.com/docs/stt/concepts/language-restrictions | `language_hints_strict: true`; best with single language; `stt-rt-v4` and `stt-rt-v3` only |
| 12 | Soniox Speaker diarization | https://soniox.com/docs/stt/concepts/speaker-diarization | `speaker` field format (string label, e.g. `"1"`); up to 15 speakers |
| 13 | Soniox Context | https://soniox.com/docs/stt/concepts/context | `context` object schema (`general`, `text`, `terms`, `translation_terms`); 10 000-char limit |
| 14 | Soniox Supported languages | https://soniox.com/docs/stt/concepts/supported-languages | Greek (`el`) confirmed; English (`en`) confirmed; ISO 639-1 codes verified |
| 15 | Soniox Models | https://soniox.com/docs/stt/models | `stt-rt-v4` active; `stt-rt-v3` → routes to v4 after 2026-02-28; aliases `stt-rt-v3-preview`, `stt-rt-preview-v2` point to v3 |
| 16 | Soniox Data residency | https://soniox.com/docs/stt/data-residency | Regional endpoints (US/EU/JP); EU: `stt-rt.eu.soniox.com`; JP: `stt-rt.jp.soniox.com` |
| 17 | Soniox Node SDK types reference | https://soniox.com/docs/sdk/node-SDK/reference/types | `SttSessionConfig` type; `RealtimeToken` type (all optional fields); `RealtimeResult` type (confirmed `finished` field on result); keepalive_interval_ms default 5000 |
| 18 | Pipecat Soniox STT service source | https://reference-server.pipecat.ai/en/latest/_modules/pipecat/services/soniox/stt.html | Most complete open-source reference implementation; confirmed empty string end-of-stream (`await self._websocket.send("")`); confirmed `KEEPALIVE_MESSAGE = '{"type": "keepalive"}'`; confirmed `FINALIZE_MESSAGE = '{"type": "finalize"}'`; confirmed `END_TOKEN = "<end>"` and `FINALIZED_TOKEN = "<fin>"`; confirmed token processing logic (accumulate finals, emit on `<end>`) |
| 19 | Soniox v4 Real-Time blog post | https://soniox.com/blog/2026-02-05-soniox-v4-real-time | Semantic endpointing behavior; `max_endpoint_delay_ms` semantics; manual finalization latency "milliseconds" |
| 20 | Soniox Greek benchmarks | https://soniox.com/compare/soniox-vs-openai/greek | Greek WER 7.4% (Soniox) vs 15.9% (OpenAI); normalization removes punctuation and casing from WER calculation |
| 21 | Internal: Investigation | docs/reference/investigation-soniox-streaming.md | Context and requirements driving this research |
| 22 | Internal: Gemini Live wire schema | docs/research/gemini-live-wire-schema.md | Template and comparison reference |
