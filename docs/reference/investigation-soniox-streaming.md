---
investigation_for: refined-request-soniox-streaming.md
investigated_at: "2026-04-29"
researcher: investigation-agent
related_codebase_scan: codebase-scan-soniox-streaming.md
---

# Investigation: Adding Soniox Real-Time Speech-to-Text as a Third Transcription Provider

## Executive Summary

Soniox is a strong fit for the recording-tool's third streaming transcription
provider. It exposes a **single, well-defined WebSocket endpoint**
(`wss://stt-rt.soniox.com/transcribe-websocket` — see §References) that streams
JSON configuration in, then binary PCM audio frames, and streams JSON token
responses out — almost the inverse of Gemini Live's all-JSON envelope, and
much simpler. The service supports **Greek (`el`) and English (`en`) natively**
in its single multilingual model `stt-rt-v4` (the active default as of
2026-04-29), with **token-level language identification, multi-language hints,
mid-sentence language switching, semantic endpoint detection, manual
finalization, and a connection keepalive control message**.

The recommended approach is:

1. **Hand-roll a `URLSessionWebSocketTask`-based provider** — there is no
   official Soniox Swift SDK at <https://github.com/soniox> (only Python, JS,
   and a TypeScript web library). The wire protocol is small enough
   (one config JSON in, binary PCM frames, JSON token responses out, two
   simple control messages — `keepalive` and `finalize`, plus an
   end-of-stream empty frame) that adopting an SPM dependency is not
   justified per NFR-SX-7.
2. **Pin `stt-rt-v4` as the default model id** (multilingual, real-time,
   60+ languages including `el` and `en`, low-latency, semantic
   endpointing). Aliases (e.g. `stt-rt-preview`) work but float — pinning
   `stt-rt-v4` matches the project's "no-fallback / explicit config" posture.
3. **Use `language_hints: ["el", "en"]`** (NOT `el-GR` — Soniox uses bare
   ISO 639-1 codes only; see §1.3) with `language_hints_strict: false` so
   Greek and English are biased without restricting other accidental input.
4. **Stream raw PCM16-LE at 16 kHz mono** — Soniox accepts `pcm_s16le` as a
   raw audio format with explicit `sample_rate: 16000` + `num_channels: 1`,
   matching exactly what `AudioDownsampler` already produces. No WAV
   header, no Opus, no resampling needed beyond the existing pipeline.
5. **Send a `keepalive` control message every ~10 s during pause/silence**
   so Soniox does not time out the session at its 20 s no-audio ceiling.
6. **Use Bearer auth with `SONIOX_API_KEY`** — the API key goes in the
   first JSON config message as `"api_key": "<key>"`, NOT in a URL query
   parameter or HTTP header. This is a privacy win over Gemini Live (whose
   key sits in the URL where it can leak via logs).

The investigation found **no blocker** — every assumption A-SX-1 through
A-SX-10 in the refined request is confirmed. Several open questions are
answerable now: OQ-SX-2, OQ-SX-4, OQ-SX-5, OQ-SX-7, OQ-SX-11. The remaining
open questions (OQ-SX-1, OQ-SX-3, OQ-SX-6, OQ-SX-8, OQ-SX-9, OQ-SX-10,
OQ-SX-12) are policy decisions for plan-006 rather than vendor lookups.

One follow-up technical research item is recommended (not blocking, but
helpful for plan-006): a **Soniox WebSocket wire-schema deep dive** analogous
to `gemini-live-wire-schema.md`, capturing the exact JSON shapes for the
config message, the response token envelope, the `finished` and `error`
messages, and the close handshake. The vendor docs cover this at the
schema-field level but do NOT publish a JSON Schema or formal IDL, so
reproducing one from the docs + an exploratory probe script is the right
investment before coding.

---

## Context

### What was investigated

How to add **Soniox** as a third streaming-STT provider in `macrec` /
`macrec-ui` next to Gemini Live and Apple SpeechAnalyzer, satisfying:

- Greek + English real-time recognition with low latency.
- The existing `TranscriptionProvider` protocol surface in
  `Sources/MacrecCore/Transcription/`.
- The four-tier env-var resolution chain in `ConfigResolver`.
- The `*.transcript.{jsonl,txt,srt,vtt}` sidecar parity (FR-SX-11).
- The "no-fallback, no leaking key" privacy posture (NFR-SX-3..NFR-SX-4).
- The "no new SPM dependency unless justified" rule (NFR-SX-7).

Refined request: [`docs/design/refined-request-soniox-streaming.md`](../design/refined-request-soniox-streaming.md)

Codebase scan: [`docs/reference/codebase-scan-soniox-streaming.md`](codebase-scan-soniox-streaming.md)

### Key requirements driving the evaluation

- FR-SX-1 — `--transcribe soniox` accepted.
- FR-SX-3 — vendor-canonical `SONIOX_API_KEY` resolved through four-tier chain.
- FR-SX-8 — accept the project's Float32/16 kHz/mono buffers; convert
  in-provider only.
- FR-SX-9 — Greek + English language strategy with multi-hint preference.
- FR-SX-10 — per-segment BCP-47 language tagging from server.
- NFR-SX-2 — ≤ 1.5 s P95 utterance-end → final on disk; ≤ 500 ms first-partial.
- NFR-SX-7 — prefer Foundation `URLSessionWebSocketTask`; SDK only if it
  delivers material value.

---

## Options Identified

### Option 1 — Hand-rolled `URLSessionWebSocketTask` client (Foundation only)

- **Description**: Implement `SonioxStreamingTranscriptionProvider` as a
  Swift `actor` (or `@unchecked Sendable` class) that opens a single
  `URLSessionWebSocketTask` per `(SourceTag)`, sends one JSON config
  message, then streams binary PCM16-LE 16 kHz mono frames + occasional
  `keepalive` JSON control messages, and consumes JSON token-response
  messages, mapping them into the existing `StreamingTranscriptionEvent`
  enum (`partial`, `final`, `metrics`, `error`). Mirrors the WebSocket
  pattern documented in `docs/research/websocket-asyncstream-pattern.md`.
- **Strengths**:
  - Zero new SPM dependencies (matches NFR-SX-7 default disposition and
    AC-SX-15).
  - Same pattern the team has already operationalized for Gemini Live —
    reuses the existing test stub mechanism (`URLProtocol`-style fake)
    and the established `AsyncStream` event-yielding lifecycle in
    `AppleSpeechSession`.
  - Full control over: API key transit (sent inside the JSON body, never
    URL-logged), keepalive cadence, finalize/close handshake, error
    classification, and metrics emission.
  - Soniox protocol is small — one config JSON, binary audio, two control
    messages, JSON responses, empty-frame close — easy to audit and to
    write `URLProtocol`-style stubs against.
  - Supports the project's privacy posture (NFR-SX-3) end-to-end:
    `URLSessionWebSocketTask` does not log message bodies.
- **Weaknesses**:
  - Reconnection-on-drop logic must be hand-implemented (Soniox does not
    offer built-in session resumption — see §1.5).
  - Token-evolution semantics (non-final → revised non-final → final)
    must be implemented in-provider (an existing `SegmentCoalescer`
    helper exists; needs adaptation for Soniox's token-rather-than-segment
    granularity).
- **Effort/Complexity**: **Medium** — comparable to the existing Gemini
  Live provider; possibly slightly less because Soniox's protocol is
  flatter (no setup-ack, no `goAway`, no model-modality lockout).
- **Risk**: **Low** — proven transport, vendor-documented schema, no
  experimental APIs.
- **Best suited when**: privacy and dependency hygiene matter (they do
  here), and the protocol is small enough that the SDK's value-add is
  marginal (it is — see Option 2).

### Option 2 — Adopt an official Soniox SDK

- **Description**: Add a Soniox-published SDK as a new SPM dependency.
- **Strengths**:
  - Would absorb wire-protocol changes automatically.
  - Vendor-blessed handling of edge cases (e.g. `keepalive` cadence,
    binary framing, tokenization).
- **Weaknesses**:
  - **There is no official Soniox Swift SDK as of 2026-04-29.** The
    Soniox GitHub org publishes: `soniox-python` (Python), `soniox-js`
    (Node TypeScript), `speech-to-text-web` (browser TypeScript),
    `langchain-js`, `langchain-soniox`, `vercel-ai-sdk-provider`,
    `tanstackai-adapter`, `n8n-nodes-soniox`. None target Swift,
    Objective-C, iOS, or macOS.
  - Wrapping a non-Swift SDK (e.g. via a Python sidecar process) adds
    massive complexity and a new runtime dependency — disqualifying.
  - Even the JS/Python SDKs are thin wrappers around the same
    WebSocket protocol — they offer little beyond what
    `URLSessionWebSocketTask` already provides.
- **Effort/Complexity**: **N/A** — no Swift SDK to evaluate.
- **Risk**: **High** if pursued through a sidecar/IPC bridge.
- **Best suited when**: a vendor publishes a first-party Swift package.
  Re-evaluate if/when Soniox ships one.

### Option 3 — Use a community / third-party Swift WebSocket client (e.g. Starscream)

- **Description**: Replace `URLSessionWebSocketTask` with a feature-rich
  third-party WebSocket client.
- **Strengths**:
  - More built-in lifecycle hooks (per-message metrics, automatic ping
    handling, simpler error API).
- **Weaknesses**:
  - New SPM dependency — violates NFR-SX-7 default disposition without
    delivering material value. The Gemini Live provider already proves
    `URLSessionWebSocketTask` is sufficient for production STT
    streaming on the same project's macOS 26 target.
  - Foundation's WebSocket support handles binary frames, ping/pong,
    and graceful close — exactly what Soniox needs.
- **Effort/Complexity**: **Medium** (rewrite of transport).
- **Risk**: **Low** technically, but **violates project conventions**.
- **Best suited when**: Foundation's WebSocket support proves
  insufficient. It hasn't.

### Option 4 — Use Soniox's REST async API and poll

- **Description**: Drop streaming; record audio chunks and POST them to
  Soniox's `stt-async-v4` model as files.
- **Strengths**:
  - Simpler transport (HTTP POST only).
  - Cheaper per-hour ($0.10 vs $0.12 per hour).
- **Weaknesses**:
  - **Defeats the entire purpose** — the request is for live, low-latency
    streaming (NFR-SX-2: ≤ 1.5 s P95). The async API targets recorded
    files; round-trip latency would be tens of seconds at minimum.
  - Out of scope per the refined request ("Batch / file-upload
    transcription via Soniox's REST API … Out of scope").
- **Effort/Complexity**: Low.
- **Risk**: High — does not satisfy the requirement.
- **Best suited when**: latency does not matter and per-hour cost is
  paramount. Not the case here.

---

## Comparison Matrix

| Criterion | Option 1 (Hand-rolled WS) | Option 2 (Official SDK) | Option 3 (Starscream) | Option 4 (REST async) |
|---|---|---|---|---|
| Satisfies streaming-latency requirement (NFR-SX-2) | Yes | N/A | Yes | **NO** |
| Supports Greek + English (FR-SX-9) | Yes | N/A | Yes | Yes |
| Native Swift / macOS support today | Yes | **NO** (no Swift SDK exists) | Yes (via SPM) | Yes |
| Adheres to NFR-SX-7 (no new SPM dep) | Yes | N/A | **No** | Yes |
| Reuses existing project pattern (Gemini Live) | Yes | N/A | Partial | No |
| API key never on URL (NFR-SX-3 stricter than Gemini) | Yes (key in JSON body) | N/A | Yes | Yes |
| Per-token language tagging (FR-SX-10) | Yes (server-emitted) | N/A | Yes | Yes |
| Implementation complexity | Medium | N/A | Medium | Low |
| Vendor-protocol-change risk | Medium (hand-rolled) | N/A (none exist) | Medium | Low |
| Long-term viability | High | Pending vendor | Medium | High |
| **Recommended?** | **YES** | No | No | No |

---

## Recommendation

**Adopt Option 1 — Hand-rolled `URLSessionWebSocketTask` client.**

Justification:

1. **Option 2 is unavailable.** No official Swift SDK exists at
   <https://github.com/soniox> as of 2026-04-29. The Python and JS SDKs are
   not consumable from a Swift macOS process without a sidecar — a step
   change in complexity that is unjustified.
2. **Option 3 violates NFR-SX-7.** The project already uses
   `URLSessionWebSocketTask` for Gemini Live; introducing a second WebSocket
   client just for Soniox is dependency creep without payoff.
3. **Option 4 misses the requirement.** Async REST cannot meet NFR-SX-2's
   1.5 s P95 utterance-end → final-on-disk target.
4. **Option 1 maps cleanly onto existing project artefacts.** The wire
   protocol is JSON config + binary frames + JSON responses — exactly the
   shape `URLSessionWebSocketTask` was designed for. The provider can
   bridge Soniox's token stream to the existing
   `StreamingTranscriptionEvent` enum and reuse the
   `TranscriptSidecarWriter` (`.streaming` policy) without modification.

Conditions under which this recommendation would change:

- If Soniox publishes an **official Swift SDK** before plan-006 closes,
  re-evaluate Option 2. Sign of life would be a new repo at
  `https://github.com/soniox/soniox-swift` or similar.
- If Soniox switches to **gRPC-only** or **HTTP/3 streaming** in a future
  major version, Foundation may no longer be sufficient and a third-party
  client could become justified. No indication this is planned.

Caveats / prerequisites:

- A real `SONIOX_API_KEY` must be obtained from
  <https://console.soniox.com/> for AC-SX-1..AC-SX-4 e2e validation.
  Console signup, key generation, and billing all live there.
- Soniox does **not advertise a perpetual free tier**. New accounts get
  some trial credit ("usage-based billing" + "self-service control center
  for everything Soniox" per the docs landing page) but no fixed monthly
  free quota is published. **The user should confirm trial credit
  availability when signing up before plan-006 e2e budget is set.** If no
  trial credit, projected cost for full-suite e2e runs is bounded by the
  $0.12/hour streaming rate (e.g. 10 minutes of e2e audio per CI run = ~$0.02).

---

## Key Findings — Soniox API Surface (verbatim from vendor docs)

### 1.1 Endpoint and connection

- **Streaming endpoint**: `wss://stt-rt.soniox.com/transcribe-websocket`
  (canonical real-time endpoint; documented at
  <https://soniox.com/docs/stt/api-reference/websocket-api> — the page
  reads "Connect to the API using:" followed by the URL in a code block).
- **Single global endpoint** — no published regional variants today.
  Therefore `MACREC_SONIOX_ENDPOINT` (FR-SX-7) is forward-looking; the
  default is `wss://stt-rt.soniox.com/transcribe-websocket`.
- **Transport**: WebSocket over TLS (`wss://`). All Soniox client examples
  open a single WebSocket per session.
- **Session duration**: up to **5 hours** under a single WebSocket
  connection (per the 2025-10-29 model update note on the Models page).
  Plan-006 must still implement `split(nextOutput:)` rotation (FR-SX-13)
  but does NOT need to handle a 10-min auto-disconnect like Gemini Live.

### 1.2 Authentication

- **API key location**: inside the **first JSON config message** as the
  `api_key` field. NOT in the URL, NOT in an `Authorization` header.
- **Vendor-canonical env var name**: there is **no convention published**
  by Soniox; their docs simply say "Export it as an environment
  variable". The Python and JS SDK examples both use `SONIOX_API_KEY`,
  which is also the canonical name in the official documentation's
  "Get API key" section. **Confirm `SONIOX_API_KEY` as the canonical
  name** (resolves OQ-SX-2).
- **Optional**: short-lived "temporary API keys" for client apps via
  `POST https://api.soniox.com/v1/auth/temporary-api-key`
  (`usage_type: transcribe_websocket`, `expires_in_seconds`: 1..3600).
  Useful for browser apps; **NOT needed for the macrec server-side
  process** (the desktop app holds the long-lived key locally with the
  same posture as `GOOGLE_API_KEY`).

### 1.3 Configuration JSON (sent as the first WebSocket message — TEXT frame, JSON)

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

Field-by-field provenance (all from
<https://soniox.com/docs/stt/api-reference/websocket-api>):

| Field | Required | Notes |
|---|---|---|
| `api_key` | yes | string |
| `model` | yes | `stt-rt-v4` (active default 2026-04-29) — see §1.4 |
| `audio_format` | yes (when raw) | `pcm_s16le` is in the supported encoding list |
| `sample_rate` | yes (raw only) | integer Hz; Soniox accepts arbitrary sample rates for raw PCM |
| `num_channels` | yes (raw only) | 1 (mono) recommended for STT |
| `language_hints` | optional | array of ISO 639-1 codes — NOT BCP-47, NOT `el-GR` |
| `language_hints_strict` | optional bool | false = bias only; true = restrict (best with single language) |
| `enable_language_identification` | optional bool | per-token `language` field on response |
| `enable_endpoint_detection` | optional bool | semantic endpointing → `<end>` token |
| `max_endpoint_delay_ms` | optional | 500..3000, default 2000 |
| `enable_speaker_diarization` | optional bool | adds `speaker` field per token (out of scope per OQ-SX-3) |
| `context` | optional object | domain-specific vocabulary biasing (out of scope) |
| `translation` | optional object | speech translation (out of scope per refined request) |
| `client_reference_id` | optional string | useful for `recordingId|source` correlation in Soniox console logs |

**Critical: language codes are bare ISO 639-1, NOT BCP-47.** Soniox uses
`el`, `en`, `es` etc. — not `el-GR`, `en-US`. The provider must accept
the existing `--transcribe-language` BCP-47 input but **strip the region
suffix** before forwarding (e.g. `el-GR` → `el`, `en-US` → `en`,
`en-GB` → `en`). This preserves user-facing BCP-47 consistency while
satisfying the Soniox wire format. The per-token `language` field on the
response will likewise be a bare ISO code; the provider may map it back
to a BCP-47 default (e.g. `el` → `el`, `en` → `en` — leaving the region
unspecified is BCP-47-valid).

### 1.4 Models — recommended default

Per <https://soniox.com/docs/stt/models> (table snapshot 2026-04-29):

| Model | Type | Status |
|---|---|---|
| `stt-rt-v4` | Real-time | Active |
| `stt-rt-v3` | Real-time | Active (auto-routes to v4 after 2026-02-28) |
| `stt-async-v4` | Async | Active |
| `stt-async-v3` | Async | Active (auto-routes to v4 after 2026-02-28) |

Aliases: `stt-rt-preview` and `stt-rt-preview-v2` both currently point to
`stt-rt-v3` — these float and should NOT be the project's pinned default.

**Recommendation (resolves OQ-SX-4): pin `"stt-rt-v4"` as the default**.
- Latest active real-time model.
- "Higher accuracy across all supported languages."
- "Better multilingual detection and mid-sentence language switching" —
  directly relevant to the Greek + English bilingual test (AC-SX-4).
- "Lower endpoint latency with faster final transcription" — directly
  helpful for NFR-SX-2.
- "Improved semantic endpointing for more natural turn-taking" —
  pairs naturally with `enable_endpoint_detection: true` for clean
  utterance boundaries (FR-SX-13 pause/resume parity).

If the user wants forward-compatibility without code changes, they can
override at runtime via `MACREC_TRANSCRIBE_MODEL=stt-rt-preview` to ride
the alias. The provider must accept any model id (FR-SX-6).

### 1.5 Audio streaming

- After the config message, the client sends **binary WebSocket frames**
  containing raw PCM bytes (no length prefix, no envelope — just the
  bytes). Frame size is implementation choice; the Gemini Live precedent
  in the project uses ~64 ms (1024 samples at 16 kHz = 2048 bytes for
  PCM16). Soniox imposes no documented chunk-size constraint.
- **Audio format options**:
  - **Raw PCM (recommended for macrec)**: `pcm_s16le` at 16 kHz, mono.
    Direct match for `AudioDownsampler` output. No WAV header needed.
    `AudioWAVEncoder` is **not** required.
  - Auto-detected container formats (FLAC, WAV, MP3, Opus, AAC, etc.)
    are also supported but add complexity (header generation) for no
    quality benefit on the macrec capture path.
- **No reconnection / session resumption protocol** is documented.
  Per NFR-SX-5 ("Bounded retry posture"), this is acceptable: on
  drop, the provider closes the events stream and emits a `.error`
  event; the recording continues per NFR-SX-1.

### 1.6 Control messages

Sent as **TEXT WebSocket frames** carrying JSON:

- **Keepalive** (must be sent every ≤ 20 s during silence):
  ```json
  { "type": "keepalive" }
  ```
- **Manual finalize** (force pending non-final tokens to be marked final
  + emits a `<fin>` marker token):
  ```json
  { "type": "finalize" }
  ```
- **End of stream**: send an **empty WebSocket frame** (binary or text
  per docs; binary recommended). Server will emit `finished` response,
  optionally with last finals, then close.

Plan-006 should:
- Send `keepalive` from a `Task` running every 10 s when no audio has
  been pushed for ≥ 5 s (matches the `5–10s common` recommendation in the
  vendor docs).
- Send `finalize` on **Pause** (FR-SX-13) so the partial in-flight
  utterance gets reconciled before the recording is suspended.
- Send the empty-frame close on **Stop** and on **`split()`**
  (FR-SX-13 / FR-SX-14) — wait up to 5 s for `finished` per FR-SX-14.

### 1.7 Server response envelope

```json
{
  "tokens": [
    {
      "text": "Καλημέρα",
      "start_ms": 120,
      "end_ms": 480,
      "confidence": 0.97,
      "is_final": true,
      "language": "el",
      "speaker": null,
      "translation_status": null,
      "source_language": null
    }
  ],
  "final_audio_proc_ms": 4800,
  "total_audio_proc_ms": 5250
}
```

Special tokens:
- `<end>` — emitted once per detected endpoint (when
  `enable_endpoint_detection: true`). Always `is_final: true`.
- `<fin>` — emitted once per `finalize` control message. Always
  `is_final: true`.

These are the **provider's segmentation signals**. Plan-006 should
coalesce all final tokens between consecutive `<end>` (or `<fin>`)
markers into a single `StreamingTranscriptionEvent.final` segment with:

- `text` = concatenation of `tokens[].text` (excluding the `<end>` /
  `<fin>` markers themselves).
- `startTime` = first token's `start_ms / 1000`.
- `endTime` = last token's `end_ms / 1000`.
- `language` = mode of `tokens[].language` (or first non-null).
- `confidence` = mean of `tokens[].confidence`.
- `model` = `"soniox"` (fixed string per FR-SX-11).

For **partial** events, emit one per server response that contains
non-final tokens, with the same shape but `model="soniox"` and only the
non-final-token text. Sidecar policy `.streaming` already filters partials
out of disk writes — only finals are persisted.

### 1.8 Termination — `finished` and `error`

After the empty-frame close, the server emits:
```json
{ "finished": true }
```
or, on error (immediately, then closes the socket):
```json
{ "error_code": 401, "error_message": "Invalid API key" }
```

`error_code` is a standard HTTP status code — useful for the provider's
error mapping:
- 401 → `MacrecError.transcriptionApiKeyInvalid` (or similar).
- 402/403 → quota / billing — surface as `.warning` in events stream;
  recording continues.
- 4xx (other) → request-shape bug in the provider — non-fatal, recording
  continues, log `.error` once.
- 5xx → vendor outage — non-fatal, recording continues.

### 1.9 Pricing

From <https://soniox.com/pricing>:
- Real-time streaming: **$2.00 per 1M input audio tokens + $4.00 per 1M
  output text tokens**, equivalent to **~$0.12 per hour** of streamed
  audio.
- Async file: ~$0.10 per hour.
- 1 hour of audio = ~30 000 input audio tokens; 1 hour of speech = ~15 000
  output text tokens; 1 character of output ≈ 0.3 tokens.

No fixed free tier is published. Trial credit upon signup is implied
(self-service console mentions "view usage, logs, and billing") but the
amount is not on the public pricing page. **User action required**:
sign up at <https://console.soniox.com/signup> and confirm the trial
credit before plan-006 e2e runs are budgeted (resolves OQ-SX-5 partially).

### 1.10 Privacy / data retention

Soniox does NOT publish a per-request data-retention toggle in the
WebSocket config schema. The console does provide usage logs by request
(via `client_reference_id`). Plan-006 should:
- Set `client_reference_id` to a non-PII identifier
  (`macrec-<recordingId>-<source>`) — useful for vendor-side debugging
  without leaking host metadata (NFR-SX-4 compliant: no filename, no
  username, no host name).
- For OQ-SX-10 (data-retention controls), recommend **deferring** to
  plan-006 — defer pending vendor confirmation. If Soniox does not
  expose a public toggle, the only mitigation is the user-side
  organizational data-retention setting in the Soniox console (not a
  per-request flag the macrec process can set).

---

## Resolved Open Questions

| OQ ID | Resolution | Source |
|---|---|---|
| **OQ-SX-2** (canonical env var) | **`SONIOX_API_KEY`** confirmed — used in all official examples and the docs' "Get API key" section. | <https://soniox.com/docs/stt/get-started> |
| **OQ-SX-4** (default model id) | **`stt-rt-v4`** — active, multilingual, lowest latency, best Greek + English. | <https://soniox.com/docs/stt/models> |
| **OQ-SX-5** (pricing) | **$0.12/hour streaming** confirmed; **trial credit existence** still requires user signup confirmation. | <https://soniox.com/pricing> |
| **OQ-SX-7** (multi-language hints) | **Honour comma-separated list (parity with `apple` provider).** Soniox accepts `language_hints` as a **native array** of ISO codes. The provider can/should pass all hints as bare ISO codes (after stripping BCP-47 region tags). Default: `["el", "en"]`. | <https://soniox.com/docs/stt/concepts/language-hints> |
| **OQ-SX-11** (Swift SDK or hand-rolled) | **Hand-rolled.** No official Soniox Swift SDK exists; protocol is small enough that one is unwarranted. | <https://github.com/soniox> |

## Open Questions Still Requiring User / Plan-006 Decision

| OQ ID | Status | Note |
|---|---|---|
| **OQ-SX-1** (protocol extension?) | **Defer to plan-006 prototype.** Default disposition KEEP existing protocol; the `AppleSpeechSession` pattern is a solid template — Soniox can do the same. | — |
| **OQ-SX-3** (diarization / endpointing exposure in v1) | **Defer.** Default: enable `enable_endpoint_detection: true` (no API knob exposed) for clean `final` semantics; do NOT expose diarization (out of scope). Confirm with user. | — |
| **OQ-SX-6** (latency SLO target) | **Confirm with user.** Soniox docs do not publish a P95 SLO; the proposed 1.5 s / 500 ms targets in NFR-SX-2 are reasonable based on Soniox's "ultra-low latency" advertising language but unverified. | — |
| **OQ-SX-8** (picker order) | **Defer to plan-006 UI cut.** Default: append after Gemini → `None | Apple | WhisperKit | Gemini | Soniox`. | — |
| **OQ-SX-9** (default `--transcribe-source`) | **Defer.** Inherit project default `mixed`. | — |
| **OQ-SX-10** (data-retention controls) | **Defer.** Soniox does not expose a per-request retention toggle in the WebSocket config schema. Recommend documenting the org-level Soniox-console setting in the configuration guide instead. | — |
| **OQ-SX-12** (per-provider expiry env vars) | **Defer to plan-006 architectural decision.** Out of vendor-research scope. | — |

---

## Soniox vs Gemini Live vs Apple SpeechAnalyzer (provider-fit comparison)

| Dimension | Gemini Live | Apple SpeechAnalyzer | Soniox |
|---|---|---|---|
| Transport | WebSocket (JSON-only, base64 audio) | Local OS framework (no network) | WebSocket (JSON config + binary audio + JSON response) |
| Greek (`el`) support | Yes (via Live API multilingual) | Yes (macOS `SFSpeechRecognizer` `el-GR` locale) | Yes (`el` ISO code, multilingual model) |
| English (`en`) support | Yes | Yes (multiple locales `en-US`, `en-GB`, …) | Yes (`en` ISO code) |
| Bilingual single-session | Yes (auto-detect) | Yes (parallel per-locale recognizers — `apple` provider runs both) | Yes (single multilingual model + `language_hints: ["el", "en"]`) |
| Token-level language tagging | Partial (per-segment via `inputTranscription`) | Yes (from per-locale winner) | **Yes (per-token native)** |
| Semantic endpointing (utterance boundary) | Yes (`AutomaticActivityDetection`) | Yes (driver-provided in macOS 26 SpeechAnalyzer) | **Yes (`<end>` token + `enable_endpoint_detection`)** |
| Manual finalization | No documented control | Implicit (driver-side) | **Yes (`{type: "finalize"}` control message)** |
| Speaker diarization | No | No | Yes (out of scope for v1) |
| API key transit | URL query (`?key=…`) | N/A (no key) | **Inside JSON body (better)** |
| Connection ceiling | ~10 min (with `goAway`) | N/A | **5 hours per session** |
| Session resumption | Yes (`sessionResumption`) | N/A | No (must reconnect manually) |
| Cost (streaming) | Variable (per million tokens, model-dependent) | Free | $0.12/hour |
| Native macOS SDK | No | **Yes** (system framework) | No |
| Best for macrec when | LLM-aware transcription needed | Privacy-first (on-device) + already supported language | Multilingual + low-latency + paid OK |

Soniox occupies a clean middle ground — **strictly better than Gemini Live
on protocol simplicity, key-leak risk, and session length**, while losing
the on-device privacy of Apple SpeechAnalyzer. For Greek + English
bilingual dictation, Soniox is the **best pure-cloud option** of the three.

---

## Technical Research Guidance

**Research needed**: **YES (one topic).**

### Topic 1: Soniox WebSocket wire-schema deep dive (analogous to `gemini-live-wire-schema.md`)

- **Why**: Plan-006's `SonioxStreamingTranscriptionProvider` will need
  exact JSON shapes for the four message types (config out, audio frame
  out, token-response in, finished/error in) plus the close handshake.
  Soniox's docs cover field-level schemas but do NOT publish a formal
  schema document, JSON Schema, OpenAPI spec, or canonical example
  payloads with all optional fields populated. Building the provider
  without a captured wire-trace risks subtle bugs (e.g. the empty-frame
  close handshake; JSON encoding of the keepalive; the exact form of the
  `<end>` and `<fin>` marker tokens — are they emitted as
  `{"text": "<end>", ...}` or via a separate marker field?).
- **Focus**:
  - Verbatim JSON for the config message including all optional fields,
    with vendor-confirmed examples for each `audio_format` value.
  - Verbatim response envelope across the three lifecycle phases:
    (a) initial non-final tokens, (b) endpoint-detected
    finalization burst, (c) `finished` close message.
  - Exact wire form of the `<end>` and `<fin>` marker tokens — special
    text values, special token type, or distinct top-level field?
  - Exact wire form of the empty-frame close (binary zero-length vs
    text-frame with empty body) and what the server returns afterward.
  - Error response shapes for the common failure modes (401 invalid key,
    402 quota, 408 timeout, 4xx malformed config, 5xx outage).
  - Whether `URLSessionWebSocketTask` correctly handles Soniox's
    binary-frame audio (it does in principle; needs an end-to-end
    confirmation against a real key).
- **Depth**: Intermediate (one focused day of research + a small
  exploratory probe script under `test_scripts/probe-soniox-ws.swift`
  using a real key, capturing the wire trace into
  `docs/research/soniox-wire-schema.md`).
- **Relevance**: Directly enables FR-SX-2 (provider conformer), FR-SX-8
  (audio format adaptation), FR-SX-10 (per-segment language tagging),
  FR-SX-13 (pause/resume/split lifecycle), and FR-SX-14 (drain on stop).
  The Gemini Live equivalent (`docs/research/gemini-live-wire-schema.md`)
  caught seven CRITICAL FINDINGS that contradicted the upstream
  investigation; the same risk exists here.

### Topics where research is NOT needed

- **Greek-language model behaviour** — Soniox advertises a single
  multilingual model (`stt-rt-v4`) covering 60+ languages including
  Greek; per-language model variants are NOT a Soniox concept. The
  e2e-validation step in plan-006 (AC-SX-2) exercises Greek end-to-end;
  no upfront language-specific research is required.
- **Swift SDK surface** — N/A (no SDK exists).
- **Authentication scheme** — sufficiently documented (key-in-config-body).
- **Pricing model** — sufficiently documented above for budget purposes.
- **macOS network entitlements** — A-SX-7 already establishes the project
  is not sandboxed; standard outbound TLS is the only requirement.

---

## Implementation Considerations (notes for plan-006)

- **API key handling**: stored in `~/.tool-agents/macrec/.env` as
  `SONIOX_API_KEY=…` (mode `0600` per existing convention). Resolved
  via the four-tier chain in `ConfigResolver` (FR-SX-3); branch
  `case .soniox:` in the API-key resolution switch at
  `Sources/MacrecCore/Config/ConfigResolver.swift:345`. Add
  `Keys.sonioxApiKey = "SONIOX_API_KEY"` and
  `Keys.sonioxEndpoint = "MACREC_SONIOX_ENDPOINT"`.
- **Endpoint default**: `wss://stt-rt.soniox.com/transcribe-websocket`.
  Override via `MACREC_SONIOX_ENDPOINT` (FR-SX-7) or `--soniox-endpoint`.
- **Model default**: pin `"stt-rt-v4"`. Override via
  `MACREC_TRANSCRIBE_MODEL` / `--transcribe-model`. Unknown ids pass
  through with `info` log line (FR-SX-6).
- **Language strategy**: default `language_hints = ["el", "en"]`,
  `language_hints_strict = false`, `enable_language_identification = true`.
  When `--transcribe-language` is set, parse the BCP-47 input,
  strip region tags (`el-GR` → `el`, `en-US` → `en`, `en-GB` → `en`),
  deduplicate, and forward as the hint list. Document the BCP-47 →
  ISO-639-1 stripping in plan-006.
- **Audio format**: `pcm_s16le` at `sample_rate: 16000`,
  `num_channels: 1`. Reuse `AudioDownsampler` for Float32 → Int16
  conversion at 16 kHz mono (the existing helper already produces
  exactly this Data shape). No `AudioWAVEncoder` needed for Soniox.
- **Frame size**: 1024 samples per binary frame (~64 ms at 16 kHz =
  2048 bytes), matching the Gemini Live precedent. No vendor-imposed
  constraint.
- **Lifecycle**:
  - Open WS → send config JSON → wait for first server response
    (no explicit ack — Soniox starts processing on first audio).
  - Per-source binary audio frames at ~64 ms cadence.
  - Background `Task` sends `{"type":"keepalive"}` every 10 s when no
    audio has been pushed for ≥ 5 s.
  - On Pause: send `{"type":"finalize"}`; consume final tokens until
    `<fin>` arrives, then suspend audio sends but keep socket open
    (with keepalives) until Resume or Stop.
  - On Resume: simply resume audio sends.
  - On `split(nextOutput:)`: send empty-frame close, wait up to 2 s
    for `finished`, open a fresh WebSocket for the new sidecar.
  - On Stop / SIGINT / SIGTERM: send empty-frame close, wait up to 5 s
    for `finished` (FR-SX-14), then cancel.
- **Error handling**: on `error_code: 401`, surface
  `MacrecError.transcriptionApiKeyInvalid` (or new variant); recording
  continues silently (NFR-SX-1). All other errors → `.warning` log,
  recording continues, sidecar may have gaps.
- **Metrics** (FR-SX-15): track and emit on stop:
  - `chunksSent` = binary audio frames sent.
  - `messagesSent` = chunks + control messages.
  - `billableSeconds` = sum of `(end_ms - start_ms) / 1000` over all
    final tokens (proxy for billing — actual billing is by stream
    duration, but token-time is the closest in-process signal).
  - `errorCount`.
  - `lastRTTMs` = elapsed time from last audio frame send → first
    response receive (sliding-window observation).
  - `firstPartialLatencyMsP95`, `endpointLatencyMsP95` (NFR-SX-2 / AC-SX-18).
- **Privacy disclosure** (FR-SX-16): the existing
  `PrivacyDisclosureSheet.swift` body is Gemini-keyed; needs a
  `soniox` variant naming Soniox.com as the destination.
- **Help text** (FR-SX-18): `StartCommand.swift:95` is already stale
  ("none | gemini-live") — bring the help text up to date with the full
  set in the same edit.
- **Testing**: mirror the existing pattern. Create
  `Tests/MacrecCoreTests/Transcription/Providers/SonioxWebSocketStubProtocol.swift`
  using the `URLProtocol` subclass approach (or, if
  `URLSessionWebSocketTask` cannot be intercepted via `URLProtocol`,
  inject a `WebSocketTransport` protocol with a fake conformer for
  tests — same pattern as `analyzerFactory` in
  `AppleSpeechTranscriptionProvider`). The Gemini Live tests will
  inform which approach is more practical.

---

## References

| # | Source | URL | What was learned |
|---|---|---|---|
| 1 | Soniox Docs — Landing | <https://soniox.com/docs> | Multi-product platform (STT, TTS, translation); REST + WebSocket; 60+ languages; console-managed API keys |
| 2 | Soniox Docs — STT WebSocket API reference | <https://soniox.com/docs/stt/api-reference/websocket-api> | Full config field list; response token shape; `finished` and error envelope; up-to-300-min stream limit (note: 5h per Models page is more recent); empty-frame close handshake |
| 3 | Soniox Docs — Real-time transcription | <https://soniox.com/docs/stt/rt/real-time-transcription> | `is_final` token-evolution semantics; `final_audio_proc_ms` / `total_audio_proc_ms` progress fields; raw PCM encoding list including `pcm_s16le`; auto-detected container formats |
| 4 | Soniox Docs — Models | <https://soniox.com/docs/stt/models> | Active models (`stt-rt-v4`, `stt-rt-v3`); aliases (`stt-rt-preview`); model release notes; 5-hour single-session ceiling |
| 5 | Soniox Docs — Language hints | <https://soniox.com/docs/stt/concepts/language-hints> | Bare ISO 639-1 codes (`en`, `es`, `el` — NOT BCP-47); hint biases, does not restrict |
| 6 | Soniox Docs — Language identification | <https://soniox.com/docs/stt/concepts/language-identification> | Token-level language tagging; sentence-level coherence; real-time tags may be revised |
| 7 | Soniox Docs — Language restrictions | <https://soniox.com/docs/stt/concepts/language-restrictions> | `language_hints_strict: true`; best with single language; v3 and v4 only |
| 8 | Soniox Docs — Endpoint detection | <https://soniox.com/docs/stt/rt/endpoint-detection> | Semantic endpointing; `<end>` marker token; `max_endpoint_delay_ms` 500..3000 (default 2000) |
| 9 | Soniox Docs — Manual finalization | <https://soniox.com/docs/stt/rt/manual-finalization> | `{"type":"finalize"}`; `<fin>` marker token; "do not send too frequently"; charged for full stream duration |
| 10 | Soniox Docs — Connection keepalive | <https://soniox.com/docs/stt/rt/connection-keepalive> | `{"type":"keepalive"}`; required every ≤ 20 s when not sending audio; charged for full duration |
| 11 | Soniox Docs — Speaker diarization | <https://soniox.com/docs/stt/concepts/speaker-diarization> | `enable_speaker_diarization`; up to 15 speakers; out of scope for v1 |
| 12 | Soniox Docs — Supported languages | <https://soniox.com/docs/stt/concepts/supported-languages> | Greek (`el`) confirmed; English (`en`) confirmed; 60+ languages on a single unified model |
| 13 | Soniox Docs — Get started | <https://soniox.com/docs/stt/get-started> | `SONIOX_API_KEY` env var convention used in all official examples |
| 14 | Soniox Docs — Temporary API key | <https://soniox.com/docs/api-reference/auth/create_temporary_api_key> | `POST /v1/auth/temporary-api-key` for short-lived browser keys (not needed for desktop tool) |
| 15 | Soniox Pricing | <https://soniox.com/pricing> | $0.12/hour streaming; token-based; ~30 000 input audio tokens / hour |
| 16 | Soniox GitHub Org | <https://github.com/soniox> | No Swift SDK; Python, JS, TypeScript, n8n, langchain SDKs only |
| 17 | Soniox Examples Repo | <https://github.com/soniox/soniox_examples> | Reference implementations in Python, Node, React, React Native — no Swift |
| 18 | Internal: Codebase Scan | [`docs/reference/codebase-scan-soniox-streaming.md`](codebase-scan-soniox-streaming.md) | New artefacts list; integration touch points; provider patterns to mirror |
| 19 | Internal: Refined Request | [`docs/design/refined-request-soniox-streaming.md`](../design/refined-request-soniox-streaming.md) | FR-SX-* / NFR-SX-* / AC-SX-* / OQ-SX-* requirements |
| 20 | Internal: Gemini Live wire schema | [`docs/research/gemini-live-wire-schema.md`](../research/gemini-live-wire-schema.md) | Template for the recommended Soniox wire-schema research deliverable |

---

## Original Request

```
Add Soniox real-time speech-to-text as a transcription option to the recording-tool
project (a macOS Swift CLI + menu-bar app that records system audio + microphone
and supports live transcription via streaming providers).

The user wants this to be a NEW provider option alongside the existing
transcription providers (Gemini Live, Apple Speech). Primary supported languages:
Greek (el / el-GR) and English (en / en-US / en-GB), in that order of priority.

Reference material the user provided:
- https://github.com/soniox (the Soniox GitHub organization — has SDKs and code samples)
- https://soniox.com/docs (the official Soniox documentation site)

The user wants me to study these sources as needed.
```

Refined request: [`docs/design/refined-request-soniox-streaming.md`](../design/refined-request-soniox-streaming.md)
