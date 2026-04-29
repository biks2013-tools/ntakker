# Azure OpenAI Realtime API — Transcription Intent (`intent=transcription`) Wire Schema

**Model focus**: `gpt-4o-mini-transcribe`  
**Purpose**: Authoritative reference for implementing `AzureRealtimeTranscriptionProvider`
in Phase A2 of plan-007. Every section maps directly to a Swift implementation decision.  
**Verification date**: 2026-04-29  
**Depth**: Deep dive — suitable for direct translation to Swift code  

---

## Assumptions & Scope

| Assumption | Confidence | Impact if wrong |
|---|---|---|
| `2025-04-01-preview` is the current recommended api-version for WS transcription | HIGH | A newer preview may have surfaced; see §1 |
| Delta events ARE emitted by Azure for `gpt-4o-mini-transcribe` with `intent=transcription` | MEDIUM | See §13 — there is a known Azure bug with *conversational* gpt-realtime that does NOT apply when using `intent=transcription` path; verify in code |
| The `model` field in `transcription_session.update` must be OMITTED on Azure | HIGH | Multiple Q&A sources confirm; including it triggers a server_error |
| 24 kHz PCM16 is required (not 16 kHz) for the realtime path | HIGH | The TechCommunity blog uses 24 kHz; the OpenAI guide specifies 24 kHz only |
| `semantic_vad` is available in `intent=transcription` mode | MEDIUM | Docs list both VAD types; not confirmed for transcription-only intent |

---

## 1. Endpoint URL

### WebSocket URL Pattern

```
wss://{resource-name}.openai.azure.com/openai/realtime?api-version=2025-04-01-preview&intent=transcription
```

| Component | Value | Notes |
|---|---|---|
| `resource-name` | Your Azure OpenAI resource subdomain | e.g. `myaoi` in `myaoi.openai.azure.com` |
| Path | `/openai/realtime` | Preview path. GA path is `/openai/v1/realtime` (for conversational realtime; GA transcription path not yet confirmed) |
| `api-version` | `2025-04-01-preview` | The only confirmed version for `intent=transcription` as of 2026-04 |
| `intent` | `transcription` | **Required**. Without this, the session defaults to conversational mode, producing unexpected events and no transcription deltas |

### `deployment` Query Parameter

For the **conversational** Realtime API (preview path), the URL uses a `deployment=` parameter instead of `model=`. For the **transcription intent** path, the TechCommunity reference implementation does NOT include a `deployment=` parameter in the URL — the resource is selected by the hostname alone, and the model is configured in the `transcription_session.update` payload (see §5). However, at least one community source shows `deployment=<name>` alongside `intent=transcription`:

```
wss://{resource}.openai.azure.com/openai/realtime?intent=transcription&deployment={deployment-name}&api-version=2025-04-01-preview
```

**Decision for v1**: Use the URL WITHOUT `deployment=`. If the handshake returns 404 or 400, add `deployment={deployment-name}` as a fallback to try during connection.

> Source: [Azure TechCommunity Blog](https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/real-time-speech-transcription-with-gpt-4o-transcribe-and-gpt-4o-mini-transcribe/4410353), [Azure WebSockets How-To](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-websockets)

### `wscat` / curl verification

```bash
# Confirm 101 Upgrade (no audio needed — just verify connection)
ENDPOINT="myaoi.openai.azure.com"
API_KEY="<your-key>"
API_VERSION="2025-04-01-preview"

wscat \
  --connect "wss://${ENDPOINT}/openai/realtime?api-version=${API_VERSION}&intent=transcription" \
  --header "api-key: ${API_KEY}"

# Expect: Connected (press CTRL+C to quit)
# Server should immediately emit: {"type":"session.created", ...}
```

---

## 2. Authentication

### v1: API Key via HTTP Header (selected for plan-007)

The `api-key` header is passed on the WebSocket upgrade request (HTTP/1.1 101 handshake):

```
api-key: {AZURE_OPENAI_API_KEY}
```

In Foundation's `URLSessionWebSocketTask`, set this before the task is resumed:

```swift
var request = URLRequest(url: url)
request.addValue(apiKey, forHTTPHeaderField: "api-key")
let task = URLSession.shared.webSocketTask(with: request)
task.resume()
```

No `Authorization` header is required when using API key mode.

### v2 (deferred): Microsoft Entra ID Bearer Token

```
Authorization: Bearer {azure_access_token}
```

Token scoped to `https://cognitiveservices.azure.com`. Obtain via:

```bash
az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
```

### v3 (deferred): Ephemeral Session Token for Browser Clients

Mint a short-lived token via REST before the WebSocket connection:

```
POST https://{resource}.openai.azure.com/openai/realtimeapi/transcription_sessions?api-version=2025-04-01-preview
api-key: {AZURE_OPENAI_API_KEY}
Content-Type: application/json
{ "model": "gpt-4o-mini-transcribe" }
```

The response contains a short-lived `client_secret.value` token. The browser then connects with that token via `?token=...` instead of the API key. Not needed for the Swift app.

> Source: [Azure Microsoft Q&A — WebRTC transcription](https://learn.microsoft.com/en-ie/answers/questions/2280938/how-to-get-a-working-realtime-transcription-with-w)

### WebSocket Subprotocol Header

No `Sec-WebSocket-Protocol` value is required. Azure does not mandate a specific subprotocol for the realtime API — the connection uses standard WebSocket framing with no application-level protocol negotiation.

---

## 3. Connection Lifecycle

### Upgrade Response Headers

On successful 101 upgrade, Azure's APIM layer adds headers the Swift logger should capture:

| Header | Example | Purpose |
|---|---|---|
| `apim-request-id` | `c2253873-ed2d-4ce3-85e5-7807e82f5ad0` | Unique session ID for Azure Monitor correlation |
| `x-ms-region` | `East US 2` | Which region served the connection |

### First Server Event After Connect

The server immediately sends `session.created` (NOT `transcription_session.created` — there is no `transcription_session.created` event type):

```json
{
  "type": "session.created",
  "event_id": "event_abc123",
  "session": {
    "id": "sess_xyz789",
    "object": "realtime.session",
    "model": "gpt-4o-mini-transcribe",
    "modalities": ["text", "audio"],
    "input_audio_format": "pcm16",
    "input_audio_transcription": null,
    "turn_detection": {
      "type": "server_vad",
      "threshold": 0.5,
      "prefix_padding_ms": "300",
      "silence_duration_ms": "200"
    },
    "temperature": 0.8,
    "max_response_output_tokens": "inf"
  }
}
```

Note: `session.id` is the session identifier the client should log for diagnostics.

### Session Duration Limits

- **Maximum session lifetime**: 60 minutes (hard cap). Verify current `session.expires_at` field if present in `session.created`.
- **Idle timeout**: Not explicitly documented; implement a periodic ping every 30 s to keep the connection alive (Azure APIM has idle timeout behaviour).
- **After expiry**: Server sends WS close frame (code 1000 normal OR 1006 abrupt) near the 60-minute mark.

### Server Close Codes

| Code | Meaning | Client action |
|---|---|---|
| 1000 | Normal closure (session expired cleanly) | Reconnect if recording still active |
| 1001 | Server going away (deployment restart) | Exponential backoff reconnect |
| 1006 | Abnormal closure — no close frame (most common with Azure) | Reconnect immediately; buffer audio locally for replay |
| 1008 | Policy violation (auth rejected after upgrade — rare) | Check api-key; do NOT retry without fixing credentials |
| 1011 | Server error | Exponential backoff; log APIM request ID |

> Source: [Azure Q&A — 1006 codes](https://learn.microsoft.com/en-us/answers/questions/5567905/using-azure-openai-realtime-api-with-websockets-the-connection-sometimes-stops-suddenly-with-code-1006), [Azure Q&A — 1006 transcription](https://learn.microsoft.com/en-my/answers/questions/5632414/openai-realtime-api-transcription-with-gpt-4o-tran)

---

## 4. Client → Server Messages

All messages are sent as **text frames** containing JSON. Azure does NOT accept binary frames for any protocol message; audio is base64-encoded inside the JSON envelope.

### 4.1 `transcription_session.update` — Session Configuration

This is the transcription-specific variant of `session.update`. Send immediately after `session.created`.

**CRITICAL Azure bug**: Do NOT include a `"model"` field in the `session` object. Including `"model": "gpt-4o-mini-transcribe"` causes `conversation.item.input_audio_transcription.failed` with `"type": "server_error"` on Azure. The model is implied by the deployment specified at connection time.

```json
{
  "type": "transcription_session.update",
  "session": {
    "input_audio_format": "pcm16",
    "input_audio_transcription": {
      "language": "en",
      "prompt": "Optional context hint. E.g. ScreenCaptureKit macOS recording."
    },
    "turn_detection": {
      "type": "server_vad",
      "threshold": 0.5,
      "prefix_padding_ms": 300,
      "silence_duration_ms": 200,
      "create_response": false
    },
    "input_audio_noise_reduction": {
      "type": "near_field"
    }
  }
}
```

#### `session` fields in `transcription_session.update`

| Field | Type | Allowed values | Notes |
|---|---|---|---|
| `input_audio_format` | string | `pcm16`, `g711_ulaw`, `g711_alaw` | Use `pcm16`; the project's existing `[Float]→Int16` path produces this |
| `input_audio_transcription.language` | string | ISO-639-1 code (e.g. `en`, `el`) | Optional; improves accuracy and latency |
| `input_audio_transcription.prompt` | string | Freeform | Optional context hint (GPT-style free text for this model) |
| `input_audio_transcription.model` | string | DO NOT SEND ON AZURE | Azure bug — omit entirely; model is determined by deployment |
| `turn_detection.type` | string | `server_vad`, `semantic_vad` | `server_vad` is the safe default |
| `turn_detection.threshold` | float | 0.0–1.0, default 0.5 | Raise in noisy environments |
| `turn_detection.prefix_padding_ms` | int | ms, default 300 | Audio prepended before detected speech start |
| `turn_detection.silence_duration_ms` | int | ms, default 200 | Silence window to trigger end-of-turn |
| `turn_detection.create_response` | bool | default `true` | Set `false` in pure transcription mode — no response generation needed |
| `turn_detection` (null) | null | — | Manual commit mode: client sends `input_audio_buffer.commit` |
| `input_audio_noise_reduction.type` | string | `near_field`, `far_field` | `near_field` for headset/mic; `far_field` for laptop mic |
| `include[]` | array | `["item.input_audio_transcription.logprobs"]` | Optional; adds per-token logprobs to delta/completed events |

> Source: [Azure Reference Docs](https://learn.microsoft.com/en-us/azure/ai-services/openai/realtime-audio-reference), [TechCommunity Blog](https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/real-time-speech-transcription-with-gpt-4o-transcribe-and-gpt-4o-mini-transcribe/4410353), [Azure Q&A — model field bug](https://learn.microsoft.com/en-gb/answers/questions/2286567/real-time-transcription-error-with-azure-openai-(g)

### 4.2 `session.update` vs `transcription_session.update`

- **`session.update`**: Standard conversational realtime event. Accepted in transcription mode but may not configure transcription-specific fields like `input_audio_noise_reduction`.
- **`transcription_session.update`**: Transcription-specific variant (used by the TechCommunity reference and OpenAI transcription guide). **Use this one** for `intent=transcription` sessions.

In the Azure reference docs the client event type enum includes only `session.update`, but the TechCommunity Python sample uses `transcription_session.update` and it works. Both appear to be accepted for the transcription intent path.

### 4.3 `input_audio_buffer.append` — Audio Streaming

```json
{
  "type": "input_audio_buffer.append",
  "audio": "<base64-encoded PCM16 chunk>"
}
```

- `audio`: base64-encoded raw PCM16 (little-endian, mono, 24 kHz) bytes.
- No per-message acknowledgement is sent by the server.
- **Max message size**: 15 MiB per `input_audio_buffer.append` event (Azure docs confirm this cap). In practice, send 100 ms chunks (~4,800 bytes at 24 kHz mono PCM16) to keep VAD responsive.
- The `event_id` field is optional on client events; omit it for simplicity.

### 4.4 `input_audio_buffer.commit` — Manual Turn Finalization

```json
{
  "type": "input_audio_buffer.commit"
}
```

Only needed when `turn_detection` is `null` (manual mode). In `server_vad` mode the server commits automatically. Sending this in VAD mode is safe but redundant.

### 4.5 `input_audio_buffer.clear`

```json
{
  "type": "input_audio_buffer.clear"
}
```

Discards all buffered audio not yet committed. Useful if the user cancels mid-utterance.

### 4.6 `response.create` / `response.cancel` — Not Used in Transcription Mode

These are conversational events. In pure transcription mode with `create_response: false`, the server does not generate responses. Do not send `response.create`. If the server sends any `response.*` events, log and ignore them.

---

## 5. Server → Client Events

### 5.1 `session.created`

Emitted immediately on connection. Contains the default session configuration.

```json
{
  "type": "session.created",
  "event_id": "event_001",
  "session": {
    "id": "sess_Abc123Xyz",
    "object": "realtime.session",
    "model": "gpt-4o-mini-transcribe",
    "input_audio_format": "pcm16",
    "input_audio_transcription": null,
    "turn_detection": {
      "type": "server_vad",
      "threshold": 0.5,
      "prefix_padding_ms": "300",
      "silence_duration_ms": "200",
      "create_response": true
    },
    "temperature": 0.8
  }
}
```

### 5.2 `session.updated`

Emitted after a successful `transcription_session.update` or `session.update`.

```json
{
  "type": "session.updated",
  "event_id": "event_002",
  "session": {
    "id": "sess_Abc123Xyz",
    "input_audio_format": "pcm16",
    "input_audio_transcription": {
      "language": "en",
      "prompt": "ScreenCaptureKit macOS"
    },
    "turn_detection": {
      "type": "server_vad",
      "threshold": 0.5,
      "prefix_padding_ms": "300",
      "silence_duration_ms": "200",
      "create_response": false
    }
  }
}
```

### 5.3 `input_audio_buffer.speech_started`

Emitted in `server_vad` mode when speech is detected.

```json
{
  "type": "input_audio_buffer.speech_started",
  "event_id": "event_010",
  "audio_start_ms": 1250,
  "item_id": "item_Uvw456Rst"
}
```

| Field | Type | Notes |
|---|---|---|
| `audio_start_ms` | int | Milliseconds from session start when speech was first detected (includes `prefix_padding_ms`) |
| `item_id` | string | ID of the user message item that will be created when speech stops |

### 5.4 `input_audio_buffer.speech_stopped`

Emitted when VAD detects end of speech.

```json
{
  "type": "input_audio_buffer.speech_stopped",
  "event_id": "event_011",
  "audio_end_ms": 3400,
  "item_id": "item_Uvw456Rst"
}
```

### 5.5 `input_audio_buffer.committed`

Emitted automatically (VAD mode) or in response to a manual commit.

```json
{
  "type": "input_audio_buffer.committed",
  "event_id": "event_012",
  "previous_item_id": "item_Prev999",
  "item_id": "item_Uvw456Rst"
}
```

Use `previous_item_id` to maintain ordering when assembling multi-turn transcripts.

### 5.6 `input_audio_buffer.cleared`

Emitted in response to `input_audio_buffer.clear`.

```json
{
  "type": "input_audio_buffer.cleared",
  "event_id": "event_013"
}
```

### 5.7 `conversation.item.created`

Emitted when the audio buffer is committed and a user message item is created.

```json
{
  "type": "conversation.item.created",
  "event_id": "event_014",
  "previous_item_id": "item_Prev999",
  "item": {
    "id": "item_Uvw456Rst",
    "object": "realtime.item",
    "type": "message",
    "role": "user",
    "content": [
      {
        "type": "input_audio",
        "transcript": null
      }
    ],
    "status": "in_progress"
  }
}
```

`transcript` is `null` until `conversation.item.input_audio_transcription.completed` fires.

### 5.8 `conversation.item.input_audio_transcription.delta` — Incremental Partials

This is the key event for live display. Emitted continuously during transcription of a speech segment. For `gpt-4o-mini-transcribe` these are real incremental deltas (unlike `whisper-1` which only sends the final).

```json
{
  "type": "conversation.item.input_audio_transcription.delta",
  "event_id": "event_020",
  "item_id": "item_Uvw456Rst",
  "content_index": 0,
  "delta": "Hello,"
}
```

| Field | Type | Notes |
|---|---|---|
| `event_id` | string | Unique event ID |
| `type` | string | `"conversation.item.input_audio_transcription.delta"` |
| `item_id` | string | Matches `input_audio_buffer.committed.item_id` |
| `content_index` | int | Always 0 for transcription mode |
| `delta` | string | Incremental text fragment. Accumulate across delta events for this `item_id`. |
| `logprobs[]` | array? | Only present if `include: ["item.input_audio_transcription.logprobs"]` was set |

**Azure parity note**: Delta events for `gpt-4o-mini-transcribe` accessed via `intent=transcription` are confirmed to work in the TechCommunity reference implementation. The known Azure bug (missing delta events) affects users connecting a *conversational* `gpt-realtime` deployment with `input_audio_transcription` specified in `session.update` — a different path. When using `intent=transcription` + `transcription_session.update`, delta events are expected to arrive.

### 5.9 `conversation.item.input_audio_transcription.completed` — Final Transcript

```json
{
  "type": "conversation.item.input_audio_transcription.completed",
  "event_id": "event_025",
  "item_id": "item_Uvw456Rst",
  "content_index": 0,
  "transcript": "Hello, how are you doing today?"
}
```

| Field | Type | Notes |
|---|---|---|
| `transcript` | string | Complete final transcript for this utterance. Use this as the authoritative text, not the accumulated deltas. |

Note: `usage` is NOT present in this event for transcription mode (usage is only in `response.done` for conversational mode).

### 5.10 `conversation.item.input_audio_transcription.failed`

```json
{
  "type": "conversation.item.input_audio_transcription.failed",
  "event_id": "event_030",
  "item_id": "item_Uvw456Rst",
  "content_index": 0,
  "error": {
    "type": "server_error",
    "code": null,
    "message": "Input transcription failed for item 'item_Uvw456Rst'.",
    "param": null
  }
}
```

This event is item-scoped (not session-fatal). The session stays open. The Swift provider should map this to a `TranscriptEvent.segmentFailed(itemId:error:)` and surface it to the UI without closing the WS connection.

### 5.11 `error` — Session-Level Error

Most errors are recoverable; the session stays open.

```json
{
  "type": "error",
  "event_id": "event_099",
  "error": {
    "type": "invalid_request_error",
    "code": "invalid_value",
    "message": "Unknown event type: transcription_session.update",
    "param": "type",
    "event_id": "event_client_001"
  }
}
```

| `error.type` values | Meaning |
|---|---|
| `invalid_request_error` | Bad event structure or unsupported field |
| `server_error` | Internal Azure error (e.g. model field bug) |
| `rate_limit_error` | Too much audio / too many tokens per minute |
| `authentication_error` | Key invalid (rare post-upgrade; more common as 401 HTTP) |

### 5.12 `rate_limits.updated`

Emitted at the start of a response cycle (conversational mode) or when rate state changes.

```json
{
  "type": "rate_limits.updated",
  "event_id": "event_050",
  "rate_limits": [
    {
      "name": "requests",
      "limit": 100,
      "remaining": 99,
      "reset_seconds": 60.0
    },
    {
      "name": "tokens",
      "limit": 20000,
      "remaining": 19750,
      "reset_seconds": 60.0
    }
  ]
}
```

---

## 6. Audio Framing Requirements

### PCM16 Specification

| Parameter | Value | Notes |
|---|---|---|
| Encoding | PCM16 (linear, little-endian, signed 16-bit integer) | Mandatory for `input_audio_format: "pcm16"` |
| Sample rate | **24,000 Hz** | The OpenAI docs and TechCommunity reference both use 24 kHz. NOT 16 kHz. This differs from the batch REST path (which accepts any sample rate) |
| Channels | Mono (1) | Stereo not supported |
| Byte order | Little-endian | macOS native byte order; no conversion needed on Apple Silicon |

### Converting the Project's `[Float]` Ring Buffer to PCM16 Base64

The project's existing `HostClockAligner` produces `[Float]` samples at 16 kHz (system audio) or the mic sample rate. Conversion steps:

1. **Resample to 24 kHz** if the source is at a different rate (use `AVAudioConverter`).
2. **Clamp to ±1.0**: `let clamped = max(-1.0, min(1.0, sample))`
3. **Scale to Int16**: `let pcm = Int16(clamped * 32767.0)`
4. **Pack as little-endian bytes**: On Apple Silicon, `withUnsafeBytes` on the Int16 directly is little-endian native.
5. **Base64-encode** the raw byte buffer.

```swift
func pcm16Base64(from floats: [Float]) -> String {
    var samples = [Int16](repeating: 0, count: floats.count)
    for (i, f) in floats.enumerated() {
        samples[i] = Int16(max(-1.0, min(1.0, f)) * 32767.0)
    }
    let data = samples.withUnsafeBytes { Data($0) }
    return data.base64EncodedString()
}
```

### Chunk Size Recommendations

| Chunk duration | PCM16 bytes at 24 kHz mono | Base64 size | VAD responsiveness |
|---|---|---|---|
| 50 ms | 2,400 bytes | ~3,200 chars | Best |
| 100 ms | 4,800 bytes | ~6,400 chars | Good (recommended) |
| 200 ms | 9,600 bytes | ~12,800 chars | Acceptable |

Use **100 ms chunks** for a balance of VAD accuracy and message overhead. The per-message cap is 15 MiB — far above any practical chunk.

---

## 7. VAD Modes

### 7.1 `server_vad` (Default, Recommended)

The server detects speech start/stop automatically. Client just streams audio continuously.

```json
"turn_detection": {
  "type": "server_vad",
  "threshold": 0.5,
  "prefix_padding_ms": 300,
  "silence_duration_ms": 200,
  "create_response": false,
  "interrupt_response": false
}
```

- `threshold` (0.0–1.0): Raise to 0.7+ for noisy environments (recording desktop audio with video playing). Lower to 0.3 for quiet environments.
- `prefix_padding_ms`: Audio retained before speech start. 300 ms avoids clipping sentence starts.
- `silence_duration_ms`: Silence window to mark end of turn. 200 ms is the minimum; raise to 500 ms for slower speech.
- `create_response: false`: **Must be false** in pure transcription mode. Prevents the model from generating LLM responses (wastes tokens, incurs cost).
- `interrupt_response: false`: Prevents the server from interrupting any response (irrelevant when `create_response: false`, but set explicitly for safety).

### 7.2 `semantic_vad`

Uses an LLM model to detect meaningful pauses rather than just silence:

```json
"turn_detection": {
  "type": "semantic_vad",
  "eagerness": "auto",
  "create_response": false
}
```

- Available in Azure per the reference docs (both `server_vad` and `semantic_vad` are listed in `RealtimeTurnDetectionType`).
- Higher latency than `server_vad` but more natural for conversational audio.
- `eagerness`: `low` (wait longer), `auto` (default), `high` (respond faster). Use `auto`.

### 7.3 Manual Mode (`turn_detection: null`)

```json
"turn_detection": null
```

Client must explicitly send `input_audio_buffer.commit` to trigger transcription. Useful when the recording session has known utterance boundaries (e.g., push-to-talk). In this mode, `input_audio_buffer.speech_started` and `input_audio_buffer.speech_stopped` are NOT emitted.

---

## 8. Complete Chronological Session Dump

Minimal happy-path session (server_vad, single utterance):

**Step 1: Client connects**
```
GET /openai/realtime?api-version=2025-04-01-preview&intent=transcription HTTP/1.1
Host: myaoi.openai.azure.com
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
api-key: sk-...

HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
apim-request-id: c2253873-ed2d-4ce3-85e5-7807e82f5ad0
x-ms-region: East US 2
```

**Step 2: Server → `session.created`**
```json
{
  "type": "session.created",
  "event_id": "event_001",
  "session": {
    "id": "sess_Abc123",
    "object": "realtime.session",
    "model": "gpt-4o-mini-transcribe",
    "input_audio_format": "pcm16",
    "turn_detection": { "type": "server_vad", "threshold": 0.5 }
  }
}
```

**Step 3: Client → `transcription_session.update`**
```json
{
  "type": "transcription_session.update",
  "session": {
    "input_audio_format": "pcm16",
    "input_audio_transcription": { "language": "en" },
    "turn_detection": {
      "type": "server_vad",
      "threshold": 0.5,
      "prefix_padding_ms": 300,
      "silence_duration_ms": 200,
      "create_response": false
    },
    "input_audio_noise_reduction": { "type": "near_field" }
  }
}
```

**Step 4: Server → `session.updated`**
```json
{
  "type": "session.updated",
  "event_id": "event_002",
  "session": { "id": "sess_Abc123", "input_audio_transcription": { "language": "en" } }
}
```

**Steps 5a–5z: Client → 50 × `input_audio_buffer.append`** (100 ms each = 5 s of audio)
```json
{ "type": "input_audio_buffer.append", "audio": "AAAAAAAAAA...base64-pcm16-100ms..." }
```

**Step 6: Server → `input_audio_buffer.speech_started`** (at ~500 ms in)
```json
{
  "type": "input_audio_buffer.speech_started",
  "event_id": "event_010",
  "audio_start_ms": 500,
  "item_id": "item_Uvw456"
}
```

**Steps 7a–7n: Server → N × `conversation.item.input_audio_transcription.delta`**
```json
{ "type": "conversation.item.input_audio_transcription.delta", "event_id": "event_020", "item_id": "item_Uvw456", "content_index": 0, "delta": "Hello" }
{ "type": "conversation.item.input_audio_transcription.delta", "event_id": "event_021", "item_id": "item_Uvw456", "content_index": 0, "delta": ", how are" }
{ "type": "conversation.item.input_audio_transcription.delta", "event_id": "event_022", "item_id": "item_Uvw456", "content_index": 0, "delta": " you doing?" }
```

**Step 8: Server → `input_audio_buffer.speech_stopped`**
```json
{
  "type": "input_audio_buffer.speech_stopped",
  "event_id": "event_030",
  "audio_end_ms": 4200,
  "item_id": "item_Uvw456"
}
```

**Step 9: Server → `input_audio_buffer.committed`**
```json
{
  "type": "input_audio_buffer.committed",
  "event_id": "event_031",
  "previous_item_id": null,
  "item_id": "item_Uvw456"
}
```

**Step 10: Server → `conversation.item.input_audio_transcription.completed`**
```json
{
  "type": "conversation.item.input_audio_transcription.completed",
  "event_id": "event_040",
  "item_id": "item_Uvw456",
  "content_index": 0,
  "transcript": "Hello, how are you doing?"
}
```

**Step 11: Client sends WS close frame (code 1000)**
```
Client → Close frame (1000, "Recording stopped")
Server → Close frame (1000, "")
```

---

## 9. Reconnect / Resumability

### Session Resumption

Azure Realtime sessions are **NOT resumable**. When the WebSocket closes (any code), the `session_id` is invalidated. A new WebSocket connection creates an entirely new session.

### Recommended Client Behaviour on Disconnect

1. **Buffer audio locally** (in-memory `[Data]` queue of base64 chunks) for the most recent N seconds (e.g., last 5 s).
2. On disconnect, log the WS close code and the `apim-request-id` from the upgrade response.
3. Reconnect immediately (first attempt) with a new `URLSessionWebSocketTask`.
4. After reconnect + `session.created`, send `transcription_session.update` again.
5. Replay the buffered audio chunks before resuming live streaming.
6. Expose a `reconnecting` state to the UI so the user knows transcription is temporarily paused.

### Reconnect Policy

| Attempt | Wait | Condition |
|---|---|---|
| 1st | 0 ms (immediate) | Any 1006 / 1001 |
| 2nd | 1 s | Still failing |
| 3rd | 4 s + ±20% jitter | Still failing |
| Give up | — | Surface `.networkError` to caller |

Do NOT reconnect on:
- Close 1008 (auth policy violation — fix credentials first)
- Session at 60-minute limit (expected end-of-session; surface clean close to user)

---

## 10. Pricing

### Rate Structure

For `gpt-4o-mini-transcribe` in Realtime mode, pricing follows the per-minute audio model:

| Model | Rate | Per hour |
|---|---|---|
| `gpt-4o-mini-transcribe` | **$0.003 / minute** | $0.18 / hr |
| `gpt-4o-transcribe` | $0.006 / minute | $0.36 / hr |
| `gpt-4o-transcribe-diarize` | $0.006 / minute | $0.36 / hr |
| `whisper-1` (legacy) | $0.006 / minute | $0.36 / hr |

This is the OpenAI-direct rate; Azure pricing aligns with this rate for Global Standard SKU deployments but verify on the [Azure OpenAI pricing page](https://azure.microsoft.com/en-us/pricing/details/azure-openai/).

Billing is per minute of audio streamed, rounded to the nearest second. Unlike the batch REST endpoint where billing is per POST, the realtime endpoint bills for the duration of audio actively committed/processed — NOT for the WebSocket connection time itself.

### Cost Tracking in Code

The `conversation.item.input_audio_transcription.completed` event does NOT include a `usage` field in transcription mode (usage only appears in conversational `response.done`). For cost estimation, calculate locally:

```swift
let audioMinutes = Double(audioSamplesCommitted) / (24000.0 * 60.0)
let estimatedCost = audioMinutes * 0.003  // USD, gpt-4o-mini-transcribe rate
```

> Source: [OpenAI API pricing](https://developers.openai.com/api/docs/pricing), [CostGoat transcription pricing](https://costgoat.com/pricing/openai-transcription)

---

## 11. Region Availability

### Conversational Realtime Models (confirmed)

The conversational `gpt-realtime` family is available in **East US 2** and **Sweden Central** (Global Standard).

### Transcription Intent (`intent=transcription`)

The TechCommunity blog confirms `gpt-4o-mini-transcribe` works via `intent=transcription` over WebSocket. The regions for this capability align with where `gpt-4o-mini-transcribe` is deployed (Global Standard):

| Region | Realtime WS transcription | Notes |
|---|---|---|
| East US 2 | Confirmed | Primary Global Standard region |
| Sweden Central | Confirmed (WebRTC WebRTC endpoint confirmed) | EU data zone preferred region |
| Others | Unconfirmed | Global Standard may route anywhere |

**WebRTC region-specific endpoints** (for reference, not used in the Swift WS path):
- `https://eastus2.realtimeapi-preview.ai.azure.com/v1/realtimertc`
- `https://swedencentral.realtimeapi-preview.ai.azure.com/v1/realtimertc`

> Source: [Azure WebSockets How-To](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-websockets), [Azure Q&A — WebRTC regions](https://learn.microsoft.com/en-ie/answers/questions/2280938/how-to-get-a-working-realtime-transcription-with-w)

---

## 12. Concurrency / Quota

- Azure does NOT publish a single explicit concurrent WebSocket session limit for the transcription API.
- Rate limits are enforced per deployment, per region, expressed as TPM (Tokens per Minute) and RPM (Requests per Minute).
- The server emits `rate_limits.updated` events and may send a session-level `error` event with `type: "rate_limit_error"` if the rate is exceeded.
- For a single-user desktop app (1 concurrent session), quota is unlikely to be a concern.
- If quota is an issue, check the **Azure Portal → Resource → Usage + Quotas** blade and request an increase.

> Source: [Azure quotas docs](https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits), [Azure quota Q&A](https://learn.microsoft.com/en-us/answers/questions/2088437/how-to-increase-azure-openai-concurrency)

---

## 13. Differences from OpenAI Direct Realtime

| Aspect | OpenAI Direct | Azure |
|---|---|---|
| URL path (preview) | `wss://api.openai.com/v1/realtime?intent=transcription` | `wss://{resource}.openai.azure.com/openai/realtime?api-version=2025-04-01-preview&intent=transcription` |
| Auth | `Authorization: Bearer {OPENAI_API_KEY}` | `api-key: {AZURE_OPENAI_API_KEY}` header |
| Model in session update | Include `"model": "gpt-4o-mini-transcribe"` | **OMIT `model` field** (Azure bug: including it causes server_error) |
| APIM headers | None | `apim-request-id`, `x-ms-region` on upgrade response |
| Delta events | Fully supported | Confirmed for `intent=transcription` path; known gap in conversational `gpt-realtime` path |
| Session schema | New nested `audio.input.*` schema (OpenAI v2) | Old flat schema: `input_audio_format`, `input_audio_transcription`, `turn_detection` at top level |
| GA availability | GA for transcription intent | Preview only (`2025-04-01-preview`); no GA date announced |
| Max concurrent WS | Not published | Not published |

**Schema note**: OpenAI's developer docs show a newer nested session schema (`audio.input.format`, `audio.input.transcription`, etc.). The Azure implementation uses the **older flat schema** (`input_audio_format`, `input_audio_transcription` directly in `session`). The TechCommunity Python reference (confirmed to work on Azure) uses the flat schema. Use the flat schema for Azure.

---

## 14. Error Codes → Swift `AzureOpenAISTTError` Extension

Extend the `AzureOpenAISTTError` enum from plan-007 §A.7 with realtime-specific cases:

```swift
// Extension of AzureOpenAISTTError for realtime / WebSocket path
enum AzureOpenAIRealtimeError: Error, Sendable {
    // WebSocket connection errors
    case connectionFailed(underlying: Error)           // URLSession WS handshake error
    case unauthorizedUpgrade                           // HTTP 401 on WS upgrade
    case policyViolation                               // WS close 1008
    case abnormalClosure(code: URLSessionWebSocketTask.CloseCode) // 1006 (most common)
    case serverError(wsCode: Int)                      // 1011

    // Session-level protocol errors
    case sessionRejected(type: String, message: String) // error event, invalid_request_error
    case rateLimited(resetSeconds: Double?)              // error event, rate_limit_error
    case internalServerError(message: String)            // error event, server_error

    // Item-level transcription errors (non-fatal to session)
    case itemTranscriptionFailed(itemId: String, message: String)

    // Authentication (Azure-specific bug: model field)
    case modelFieldForbidden  // server_error caused by including "model" in session update
}
```

### Error-to-Swift Mapping Table

| Source | Condition | Swift case |
|---|---|---|
| WS upgrade HTTP 401 | Auth header rejected | `.unauthorizedUpgrade` |
| WS close 1000 | Normal end-of-session | Not an error; handle as clean close |
| WS close 1001 | Server restart | `.abnormalClosure(1001)` → reconnect |
| WS close 1006 | Abnormal (most common) | `.abnormalClosure(1006)` → reconnect |
| WS close 1008 | Auth policy violation | `.policyViolation` → do not retry |
| WS close 1011 | Server error | `.serverError(1011)` → backoff retry |
| `error` event, `invalid_request_error` | Bad event schema | `.sessionRejected(type:message:)` |
| `error` event, `server_error` with model field | Model field in session update | `.modelFieldForbidden` |
| `error` event, `rate_limit_error` | Quota exceeded | `.rateLimited(resetSeconds:)` |
| `conversation.item.input_audio_transcription.failed` | Per-item ASR failure | `.itemTranscriptionFailed(itemId:message:)` |

---

## 15. Swift Implementation Hints

### File Layout (mirrors Gemini Live pattern from codebase scan IP-5)

```
Sources/MacrecCore/Transcription/Providers/
  AzureRealtimeTranscriptionProvider.swift    // main provider conformer
  AzureRealtimeSession.swift                 // URLSessionWebSocketTask wrapper
  AzureRealtimeEvents.swift                  // Codable event types (Decodable)
  AzurePCM16Encoder.swift                    // [Float] → PCM16 base64 helper
```

### URLSessionWebSocketTask Setup

```swift
func connect(apiKey: String, endpoint: URL) -> AsyncStream<AzureRealtimeEvent> {
    var request = URLRequest(url: endpoint)
    request.addValue(apiKey, forHTTPHeaderField: "api-key")
    let task = URLSession.shared.webSocketTask(with: request)
    task.resume()
    // Log upgrade response headers via URLSession delegate
    return AsyncStream { continuation in
        Task {
            while true {
                let message = try await task.receive()
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(AzureRealtimeEvent.self, from: data) {
                    continuation.yield(event)
                }
            }
        }
    }
}
```

### Event Discriminator (`AzureRealtimeEvent`)

```swift
enum AzureRealtimeEvent: Decodable {
    case sessionCreated(SessionCreatedPayload)
    case sessionUpdated(SessionUpdatedPayload)
    case speechStarted(SpeechStartedPayload)
    case speechStopped(SpeechStoppedPayload)
    case bufferCommitted(BufferCommittedPayload)
    case bufferCleared
    case itemCreated(ItemCreatedPayload)
    case transcriptionDelta(TranscriptionDeltaPayload)
    case transcriptionCompleted(TranscriptionCompletedPayload)
    case transcriptionFailed(TranscriptionFailedPayload)
    case rateLimitsUpdated(RateLimitsPayload)
    case error(ErrorPayload)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decode(String.self, forKey: .type)
        switch type_ {
        case "session.created":    self = .sessionCreated(try SessionCreatedPayload(from: decoder))
        case "session.updated":    self = .sessionUpdated(try SessionUpdatedPayload(from: decoder))
        case "input_audio_buffer.speech_started": self = .speechStarted(try SpeechStartedPayload(from: decoder))
        case "input_audio_buffer.speech_stopped": self = .speechStopped(try SpeechStoppedPayload(from: decoder))
        case "input_audio_buffer.committed":      self = .bufferCommitted(try BufferCommittedPayload(from: decoder))
        case "input_audio_buffer.cleared":        self = .bufferCleared
        case "conversation.item.created":         self = .itemCreated(try ItemCreatedPayload(from: decoder))
        case "conversation.item.input_audio_transcription.delta":
            self = .transcriptionDelta(try TranscriptionDeltaPayload(from: decoder))
        case "conversation.item.input_audio_transcription.completed":
            self = .transcriptionCompleted(try TranscriptionCompletedPayload(from: decoder))
        case "conversation.item.input_audio_transcription.failed":
            self = .transcriptionFailed(try TranscriptionFailedPayload(from: decoder))
        case "rate_limits.updated": self = .rateLimitsUpdated(try RateLimitsPayload(from: decoder))
        case "error":               self = .error(try ErrorPayload(from: decoder))
        default:                    self = .unknown(type: type_)
        }
    }
}
```

### Audio Send Helper

```swift
func sendAudioChunk(_ floats: [Float], over task: URLSessionWebSocketTask) async throws {
    let base64 = pcm16Base64(from: floats)
    let json = #"{"type":"input_audio_buffer.append","audio":"\#(base64)"}"#
    try await task.send(.string(json))
}
```

---

## 16. Open Questions / Verify in Code

1. **`deployment=` in WS URL**: Confirm whether the URL requires `deployment={name}` alongside `intent=transcription`. The TechCommunity sample does NOT include it; some community Q&A sources DO. Test both forms.

2. **Delta events on Azure with `intent=transcription`**: The known gap (missing delta events) is for conversational `gpt-realtime` with `input_audio_transcription` in `session.update`. Verify that `transcription_session.update` + `intent=transcription` reliably emits deltas. If not, fall back to `completed`-only mode and treat it like a fast batch endpoint.

3. **`session.expires_at` field**: Confirm whether the `session.created` payload includes an `expires_at` timestamp that can be used to preemptively reconnect before the 60-minute hard cap.

4. **PCM16 at 16 kHz vs 24 kHz**: The batch REST path accepts any sample rate. The realtime path appears to require 24 kHz based on the OpenAI docs and TechCommunity blog. Verify empirically whether 16 kHz PCM16 is also accepted (Azure may be less strict than OpenAI direct here).

5. **`transcription_session.update` acceptance**: Confirm this event type is accepted by the Azure `2025-04-01-preview` endpoint (some sources suggest only `session.update` is documented in the Azure reference, while `transcription_session.update` is the OpenAI-side event name). If rejected, fall back to `session.update`.

6. **`semantic_vad` in transcription mode**: Verify availability when `intent=transcription`. The Azure reference docs list it in the type enum, but community reports focus on `server_vad`.

7. **`create_response: false` required?**: When using `intent=transcription`, the server may already suppress response generation. Confirm whether `create_response: false` must be explicit or is the default for this intent.

8. **Newer `api-version`**: Check for `2025-08-01-preview` or `2025-11-01-preview` — as of 2026-04-29, `2025-04-01-preview` is the latest confirmed for transcription intent. A newer version may have added GA for this path.

---

## 17. Assumptions & Scope Summary

| Claim | Confidence | Source |
|---|---|---|
| Endpoint: `wss://{resource}.openai.azure.com/openai/realtime?api-version=2025-04-01-preview&intent=transcription` | HIGH | TechCommunity blog, multiple Q&A |
| Auth: `api-key` header on upgrade request | HIGH | TechCommunity Python sample |
| First server event: `session.created` (not `transcription_session.created`) | HIGH | Azure reference docs |
| Max session duration: 60 minutes | HIGH | Multiple community sources, session timeout discussion |
| Audio format: PCM16 mono 24 kHz | HIGH | OpenAI docs, TechCommunity sample (uses `pyaudio` at 24000 Hz) |
| OMIT `model` field in session update (Azure bug) | HIGH | Azure Q&A confirmed, documented workaround |
| Delta events work for `intent=transcription` path | MEDIUM | TechCommunity blog + OpenAI docs confirm; Azure Q&A gap is for different path |
| `semantic_vad` available in transcription mode | MEDIUM | Listed in Azure type enum; not confirmed for transcription intent |
| Pricing: $0.003/min same as batch REST | HIGH | OpenAI pricing page |
| No `usage` field in `.completed` event for transcription | MEDIUM | Inferred from absence in docs; verify empirically |

---

## References

| # | Source | URL | Information gathered |
|---|---|---|---|
| 1 | Azure Realtime Audio Reference (Events) | https://learn.microsoft.com/en-us/azure/ai-services/openai/realtime-audio-reference | Complete event schemas, component types, VAD config |
| 2 | Azure TechCommunity — Realtime Transcription Blog | https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/real-time-speech-transcription-with-gpt-4o-transcribe-and-gpt-4o-mini-transcribe/4410353 | Endpoint URL, Python reference implementation, audio parameters |
| 3 | OpenAI Realtime Transcription Guide | https://developers.openai.com/api/docs/guides/realtime-transcription | Session schema, delta/completed events, VAD guide, logprobs |
| 4 | Azure WebSocket Realtime How-To | https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio-websockets | WS URL patterns, auth options, GA vs preview path |
| 5 | Azure Realtime How-To (general) | https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/realtime-audio | Supported models, region availability, deployment steps |
| 6 | OpenAI Client Events API Reference | https://platform.openai.com/docs/api-reference/realtime-client-events | Client event schemas, buffer size cap (15 MiB) |
| 7 | Azure Q&A — Missing delta events | https://learn.microsoft.com/en-us/answers/questions/5603828/no-user-transcription-deltas-from-azure-openai-rea | Known Azure gap for conversational path; delta issue detail |
| 8 | Azure Q&A — Transcription failed error | https://learn.microsoft.com/en-gb/answers/questions/2286567/real-time-transcription-error-with-azure-openai-(g | Model field bug: OMIT `model` in session update on Azure |
| 9 | Azure Q&A — WebSocket 1006 codes | https://learn.microsoft.com/en-us/answers/questions/5567905/using-azure-openai-realtime-api-with-websockets-the-connection-sometimes-stops-suddenly-with-code-1006 | Close code semantics, reconnect strategies |
| 10 | Azure Q&A — 1006 transcription | https://learn.microsoft.com/en-my/answers/questions/5632414/openai-realtime-api-transcription-with-gpt-4o-tran | Additional 1006 context, mitigation |
| 11 | Azure Q&A — WebRTC transcription setup | https://learn.microsoft.com/en-ie/answers/questions/2280938/how-to-get-a-working-realtime-transcription-with-w | `transcription_sessions` endpoint, region-specific WebRTC URLs |
| 12 | OpenAI API Pricing | https://developers.openai.com/api/docs/pricing | $0.003/min for gpt-4o-mini-transcribe |
| 13 | CostGoat — Transcription pricing | https://costgoat.com/pricing/openai-transcription | Pricing cross-check |
| 14 | Azure OpenAI Quotas & Limits | https://learn.microsoft.com/en-us/azure/foundry/openai/quotas-limits | Quota structure, region limits |
