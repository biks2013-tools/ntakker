---
investigation_for: refined-request-additional-stt-engines.md
investigated_at: "2026-04-29"
researcher: investigation-agent
related_codebase_scan: codebase-scan-additional-stt-engines.md
related_existing_baselines:
  - docs/design/plan-004-rest-batch-transcription.md  # Gemini REST batch baseline
  - docs/design/plan-005-apple-speech-streaming.md    # Apple SpeechAnalyzer streaming baseline
---

# Investigation: Adding Azure OpenAI `gpt-4o-mini-transcribe` and ElevenLabs Speech-to-Text as Additional `TranscriptionProvider` Implementations

> **ERRATUM 2026-04-29**: An earlier version of this investigation
> stated "Azure has no realtime variant for `gpt-4o-mini-transcribe`".
> **This is INCORRECT.** Azure exposes the model via
> `wss://{resource}.openai.azure.com/openai/realtime?api-version=2025-04-01-preview&intent=transcription`
> using a `transcription_session.update` configuration message and the
> standard `input_audio_buffer.append` / `…speech_started` /
> `…speech_stopped` / `…committed` / `conversation.item.input_audio_transcription.delta`
> / `…completed` event vocabulary. The realtime path is now in scope
> for plan-007 **Phase A2** (the original Phase A is now Phase A1, the
> batch REST path). See
> `docs/research/azure-openai-realtime-transcription-wire-schema.md`
> for the full wire schema and `docs/design/plan-007-additional-stt-engines.md`
> §A2 for the implementation plan. The "deferred to plan-007" decision
> in the original recommendation now applies ONLY to ElevenLabs
> realtime (`scribe_v2_realtime`).

## Executive Summary

Both engines fit cleanly into the existing `TranscriptionProvider` /
`StreamingTranscriptionSession` contract from plan-005 §4.1 with **no
SwiftPM dependencies, no protocol changes, and no new TCC permissions**.
`URLSession` (multipart POST) and `URLSessionWebSocketTask` (one-direction
JSON config + binary PCM out, JSON events in) cover both engines end-to-end.
The recommended v1 shape is:

| Engine | v1 mode | Pattern to mirror | Provider id |
|---|---|---|---|
| **Azure OpenAI `gpt-4o-mini-transcribe`** | **Batch** (REST) | `GeminiRESTTranscriptionProvider` (plan-004) | `"azure"` |
| **ElevenLabs `scribe_v2` (batch)** | **Batch** (REST) | `GeminiRESTTranscriptionProvider` (plan-004) | `"elevenlabs"` |
| (optional follow-up) **ElevenLabs `scribe_v2_realtime`** | **Streaming** (WebSocket) | Gemini Live WebSocket pattern | `"elevenlabs-realtime"` |

Three findings drive the recommendation:

1. **Azure OpenAI's `gpt-4o-mini-transcribe` is batch-only.** Azure does
   expose a `/realtime` WebSocket but only for the `gpt-realtime` /
   `gpt-realtime-mini` family, which is a *conversational* speech-in /
   speech-out modality, not a transcription-only stream. The
   `gpt-4o-mini-transcribe` model is published exclusively under the
   `/audio/transcriptions` REST surface (multipart upload, 25 MB max). This
   confirms refined-request Assumption A-1 for Azure: streaming is **not
   available** for the chosen model in v1; batch-only is the only path.

2. **ElevenLabs DOES expose a public realtime STT WebSocket** —
   `scribe_v2_realtime`, GA since 2025-11-11, with ~150 ms first-partial
   latency, 90+ languages including Greek, native VAD and manual commit.
   This **refutes refined-request Assumption A-5** ("STT is batch-only").
   The realtime variant is a strong fit for Greek + English live
   captioning workloads where Apple SpeechAnalyzer's quality is
   insufficient. However, since (a) the SDK-only docs make the wire
   protocol opaque, (b) the existing `GeminiRESTTranscriptionProvider`
   pattern already covers ElevenLabs `scribe_v2` (batch) end-to-end with
   trivial effort, and (c) the realtime variant requires WebSocket
   plumbing that doubles the implementation surface, the recommendation is
   to **ship ElevenLabs as batch-only in plan-007 v1 and capture
   `scribe_v2_realtime` as a v2 follow-up plan-007**. This preserves the
   single-PR scope and lets Apple SpeechAnalyzer remain the streaming
   default for Greek + English.

3. **No new SwiftPM dependencies are needed.** Both batch providers
   require: `URLSession.shared.data(for:)`, `multipart/form-data` body
   construction (40-line helper in pure Foundation), and `JSONDecoder`.
   Azure's deployment-routing and `api-version` query parameter are URL
   construction concerns, not transport concerns. The existing
   `AudioWAVEncoder` (16 kHz mono Int16 WAV) produces exactly the wire
   format both providers accept.

The investigation also resolves several open questions ahead of plan-007:

- **OQ-Az-1 (streaming for Azure)**: **NO** — `gpt-4o-mini-transcribe`
  has no realtime variant. Confirmed.
- **OQ-EL-1 (streaming for ElevenLabs)**: **YES** — `scribe_v2_realtime`
  WebSocket exists and is GA. Recommend deferring to plan-007.
- **OQ-Auth-Az**: **`api-key` header** for v1 (per Assumption A-7).
  Microsoft Entra ID (AAD bearer) is documented as the recommended
  production path but adds the `azure-identity` SDK dependency cost —
  defer to v2.
- **OQ-Az-Region**: **eastus2 + swedencentral** are the current Global
  Standard regions for `gpt-4o-mini-transcribe`. The Swedish region is
  appropriate for EU residency.
- **OQ-EL-Diarize**: ElevenLabs natively supports speaker diarization
  (`diarize=true`, up to 32 speakers). For v1 the project's existing
  single-source pipeline does not need it; expose as an optional
  `TranscriptionOptions.diarize` flag in a future revision.

Two technical research deep-dives are recommended before plan-007 is
written: one per engine, capturing the verbatim wire schemas to a
`docs/research/<engine>-wire-schema.md` file (analogous to
`gemini-live-wire-schema.md` and `soniox-wire-schema.md`).

---

## Context

### What was investigated

How to add **Azure OpenAI `gpt-4o-mini-transcribe`** and **ElevenLabs
Speech-to-Text** as additional `TranscriptionProvider` conformers in
`Sources/MacrecCore/Transcription/Providers/`, alongside the existing
five providers (`NoOp`, `Fake`, `GeminiREST`, `AppleSpeech`, `WhisperKit`),
and surface them through the `macrec` CLI (`--transcribe azure |
elevenlabs`) and the `macrec-ui` `ControlBar` provider picker.

Refined request: [`docs/design/refined-request-additional-stt-engines.md`](../design/refined-request-additional-stt-engines.md)

Codebase scan: [`docs/reference/codebase-scan-additional-stt-engines.md`](codebase-scan-additional-stt-engines.md)

Existing baselines (treated as immutable for this investigation):
- [`docs/design/plan-004-rest-batch-transcription.md`](../design/plan-004-rest-batch-transcription.md) — Gemini REST batch pattern
- [`docs/design/plan-005-apple-speech-streaming.md`](../design/plan-005-apple-speech-streaming.md) — Apple SpeechAnalyzer streaming pattern + extended `TranscriptionProvider` protocol

### Key requirements driving the evaluation

- **R-1**: Adapt to existing `TranscriptionProvider` protocol with no
  breaking changes (R-5 of refined request).
- **R-2**: Wire-schema research notes per engine
  (`docs/research/<engine>-wire-schema.md`).
- **R-4**: Single combined plan-007 with one phase per engine.
- **R-6**: Configuration via four-tier env-var resolution chain in
  `ConfigResolver`; no fallbacks; expiration companions for credentials.
- **NFR (Constraint)**: No new SwiftPM dependencies.
- **NFR (Constraint)**: macOS 26 deployment target (Approved Exception 002).
- **NFR (Constraint)**: Apple SpeechAnalyzer remains the default; new
  providers are explicit opt-ins (Assumption A-8).

---

## Options Identified

### Option 1 — Azure batch + ElevenLabs batch (RECOMMENDED for plan-007 v1)

- **Description**: Both engines added as **batch-only** providers,
  mirroring the `GeminiRESTTranscriptionProvider` pattern verbatim.
  Azure uses `POST {endpoint}/openai/deployments/{deployment}/audio/transcriptions?api-version=2024-10-21`
  with `multipart/form-data` body (`file`, `response_format`, optional
  `language` ISO-639-1 hint, optional `prompt`). ElevenLabs uses
  `POST https://api.elevenlabs.io/v1/speech-to-text` with
  `multipart/form-data` body (`model_id="scribe_v2"`, `file`,
  `language_code` ISO-639-1, optional `diarize`, `tag_audio_events`).
  Both share `AudioWAVEncoder` for the wire payload. Both declare
  `supportedModes = [.batch]` and throw
  `MacrecError.transcriptionConfigConflict(...)` from
  `openStreamingSession(...)` — exactly mirroring lines 141–148 of
  `GeminiRESTTranscriptionProvider.swift`.
- **Strengths**:
  - **Zero new SPM deps** — Foundation `URLSession` + `JSONDecoder` only.
  - **Smallest implementation surface** — each provider is ~150 LOC,
    matching `GeminiRESTTranscriptionProvider.swift` size.
  - **Reuses existing batch pipeline** — `TranscriptionManager`'s
    `processLoop` (line 297) and `runProviderCall` (line 173) are
    provider-agnostic; no manager changes needed.
  - **Reuses `SidecarPolicy.batch`** — no new persistence work.
  - **Single PR scope** — keeps plan-007 to one combined plan with one
    phase per engine, as the user explicitly requested.
- **Weaknesses**:
  - Latency floor of ~3–5 s per chunk (same as Gemini REST today).
    Apple SpeechAnalyzer remains the only sub-500-ms option.
  - Forfeits ElevenLabs's `scribe_v2_realtime` advantage (~150 ms
    first-partial, native VAD) — addressed by capturing it as a v2
    plan-007 follow-up.
- **Effort/Complexity**: **Low** — comparable to plan-004 effort.
- **Risk**: **Low** — proven REST surfaces, well-documented schemas,
  no experimental APIs.
- **Best suited when**: shipping value quickly with bounded scope,
  while Apple SpeechAnalyzer covers live use cases. **This matches the
  refined request precisely.**

### Option 2 — Azure batch + ElevenLabs realtime (combined v1)

- **Description**: Same Azure batch path as Option 1, but ship ElevenLabs
  as a streaming `StreamingTranscriptionSession` using
  `scribe_v2_realtime` over WebSocket. Mirrors the Gemini Live WebSocket
  pattern (one JSON config message in, then binary PCM frames in, plus
  control messages; JSON event stream out: `session_started`,
  `partial_transcript`, `committed_transcript`,
  `committed_transcript_with_timestamps`, `error`, `close`).
- **Strengths**:
  - Best-in-class ElevenLabs experience with ~150 ms first-partial.
  - Differentiates from Apple via 90+ language coverage and superior
    diarization.
- **Weaknesses**:
  - **Doubles the implementation surface** for ElevenLabs (batch +
    streaming), violating the single-phase-per-engine spirit of the
    refined request.
  - **Wire protocol is opaque** — ElevenLabs's docs only show their
    SDK API surface (`RealtimeEvents.PARTIAL_TRANSCRIPT` etc.), not the
    raw WebSocket URL, JSON envelope, or binary frame layout. A
    research probe is required first (`elevenlabs-realtime-wire-schema.md`).
  - **Auth is single-use-token-based** — the realtime API requires
    fetching a short-lived token from
    `POST /v1/realtime/token` (or similar) before connecting, NOT a
    long-lived `xi-api-key` header. This is a different auth flow from
    the batch endpoint; managing the token-fetch step adds a
    `TokenProvider` indirection in the provider that doesn't exist for
    Gemini Live (which uses URL-query key) or Soniox (which puts the
    key in the JSON body).
  - **Recovers no protocol-extension cost** — the existing
    `StreamingTranscriptionSession` protocol is already extended for
    streaming; would require nothing new on the protocol side.
  - **Pricing premium** — Realtime is $0.39/hr vs $0.22/hr batch
    (~77% higher), worth flagging in privacy-disclosure copy.
- **Effort/Complexity**: **Medium-High** — requires WebSocket plumbing,
  token-provider indirection, exploratory probe to capture wire schema,
  plus the batch path for the case where the user prefers offline.
- **Risk**: **Medium** — undocumented WebSocket schema requires
  reverse engineering from the SDK source; vendor-side schema changes
  before the docs catch up are likely.
- **Best suited when**: live captioning quality on non-en/el languages
  is a priority. **Not the case for v1** — Apple SpeechAnalyzer covers
  the user's en/el dual-locale workflow with no API cost.

### Option 3 — Azure realtime via the `gpt-realtime` family + ElevenLabs batch

- **Description**: Use Azure's `/realtime` WebSocket with the
  `gpt-realtime-mini` deployment for a streaming transcription
  experience, even though this model is conversational (`audio in,
  audio out`).
- **Strengths**:
  - Brings Azure into the streaming bucket for parity with Apple.
- **Weaknesses**:
  - **Wrong product fit**: `gpt-realtime` is built for "speech in, speech
    out" agent loops, not transcription. Configuring
    `output_modalities: ["text"]` is undocumented and unsupported; the
    server expects to generate audio responses, which incurs output
    audio token costs (`$32 / 1M input audio tokens, $64 / 1M output
    audio tokens` for `gpt-realtime-1.5`) for capabilities not used.
  - **Not the model the user requested** — refined request specifies
    `gpt-4o-mini-transcribe` explicitly (Assumption A-3).
  - **Conversational state machine adds complexity** — `session.update`,
    `conversation.item.create`, `response.create`, VAD events,
    function-call events — far heavier than `/audio/transcriptions`.
- **Effort/Complexity**: **High**.
- **Risk**: **High** — using a model outside its intended modality.
- **Best suited when**: building a voice agent loop. **Not the case here.**

### Option 4 — Adopt vendor SDKs (`@azure/openai`, `elevenlabs` Python)

- **Description**: Add Azure OpenAI Python/JS SDK + ElevenLabs Python/JS
  SDK as helpers via a sidecar process or polyglot bridge.
- **Strengths**: Vendor handles wire-protocol changes.
- **Weaknesses**:
  - **No Swift SDK exists** for either vendor — same situation as Soniox.
    Bridging Python/JS into a Swift macOS process is a sidecar
    nightmare (extra runtime dep, IPC, packaging cost).
  - Both vendors' wire protocols are simple HTTPS multipart; SDKs are
    thin wrappers that buy little.
- **Effort/Complexity**: **High** (sidecar), **N/A** (Swift SDK).
- **Risk**: **High**.
- **Best suited when**: a vendor publishes a first-party Swift package.
  Re-evaluate if/when this happens.

---

## Comparison Matrix

### Per-engine, v1 transport choice

| Criterion | Azure batch (REST) | Azure realtime (`/realtime`) | ElevenLabs batch (REST) | ElevenLabs realtime (`scribe_v2_realtime`) |
|---|---|---|---|---|
| Right product for transcription | **Yes** (`gpt-4o-mini-transcribe`) | No (conversational, not STT-only) | **Yes** (`scribe_v2`) | Yes (`scribe_v2_realtime`) |
| Available for the requested model | **Yes** | **No** (model not exposed under `/realtime`) | **Yes** | Yes (different model id) |
| First-partial latency | ~3–5 s end-to-end | ~200 ms (if used) | ~3–5 s end-to-end | **~150 ms** |
| Multipart `URLSession` sufficient | **Yes** | No (WebSocket) | **Yes** | No (WebSocket) |
| Wire schema documented in detail | **Yes** | Yes (extensive event spec) | **Yes** | **No** (SDK-only docs) |
| Auth = single API key in header | **Yes** (`api-key`) | Yes (`api-key` header or query) | **Yes** (`xi-api-key`) | **No** (single-use token from REST endpoint, then WebSocket) |
| Cost per audio hour | ~$0.18/hr (≈ $0.003/min) [OpenAI rate; Azure parity assumed] | $32 / 1M in audio tokens (≈ $5/hr+) | **$0.22/hr** | **$0.39/hr** |
| Adds new SwiftPM dep | **No** | No (URLSessionWebSocketTask) | **No** | No (URLSessionWebSocketTask) |
| Existing pattern to mirror | **`GeminiRESTTranscriptionProvider`** | (no streaming Gemini provider since plan-004 deletion) | **`GeminiRESTTranscriptionProvider`** | (would resurrect Gemini Live's WebSocket pattern) |
| Greek (`el`) supported | Yes (Whisper-class language coverage) | Yes | **Yes** | **Yes** (90+ languages incl. Greek) |
| Diarization native | No | Limited (per-speaker turn detection) | **Yes** (up to 32 speakers) | Yes (via VAD-tagged segments) |
| Word-level timestamps | Yes (via `response_format=verbose_json`) | N/A | **Yes** (`timestamps_granularity=word|character`) | Yes (`COMMITTED_TRANSCRIPT_WITH_TIMESTAMPS` event) |
| Max file size (batch) / session ceiling (stream) | **25 MB** | 30 min sessions per Azure docs | **3.0 GB** | Not published |
| Recommended for plan-007 v1 | **YES** | NO | **YES** | Defer to plan-007 |

### All four (existing + new) provider-fit comparison (per refined-request R-3)

| Dimension | Gemini REST (existing batch) | Apple SpeechAnalyzer (existing streaming) | Azure OpenAI `gpt-4o-mini-transcribe` (NEW batch) | ElevenLabs `scribe_v2` (NEW batch) |
|---|---|---|---|---|
| Mode | Batch (REST) | Streaming (on-device) | Batch (REST) | Batch (REST) |
| Transport | HTTPS POST (JSON inline base64) | Local OS framework | HTTPS POST (multipart) | HTTPS POST (multipart) |
| First-partial latency | ~3–5 s | **~80–250 ms** | ~3–5 s | ~3–5 s |
| Final latency (P95) | ~3–5 s | < 1.5 s | ~3–5 s | ~3–5 s |
| Cost per hour | varies (Gemini token rates) | **$0** (on-device) | ~$0.18/hr | **$0.22/hr** |
| English (`en`) quality | Excellent | Excellent | Excellent (GPT-4o family) | **Industry-leading** (lowest WER on FLEURS per vendor 2026-01) |
| Greek (`el`) quality | Good (multilingual) | **Good** (`el-GR` locale, on-device) | Good (Whisper-class) | **Good** (90+ languages incl. `el`) |
| Privacy posture | Cloud (Google) | **On-device only** | Cloud (Azure region-pinned, no training by default) | Cloud (US-based; SOC 2, ISO 27001, GDPR; EU residency option) |
| Max audio per request | (chunked at 2 s) | (continuous) | **25 MB** (~25 min @ 16 kHz mono Int16 WAV) | **3.0 GB** (effectively unlimited for our use) |
| Sample rate / codec | 16 kHz Int16 WAV (project-side) | 16 kHz Float32 (project-side) | All major audio/video formats; we send 16 kHz Int16 WAV | All major audio/video formats; PCM_S16LE_16 for low-latency |
| Languages list breadth | Multilingual (Gemini) | Limited to OS-supported locales | Multilingual (Whisper-derived; ISO-639-1 hint) | **90+ languages** (auto-detect or ISO-639-1/3 hint) |
| Diarization | No | No | No (in v1 model) | **Yes** (up to 32 speakers, `detect_speaker_roles` for agent/customer) |
| Word-level timestamps | No (segment-level via Gemini) | Yes (driver-provided) | Yes (`response_format=verbose_json`) | **Yes** (word + character granularity) |
| Native Swift SDK | No (used `URLSession`) | **Yes** (system framework) | No (use `URLSession` + multipart) | No (use `URLSession` + multipart) |
| Recommended use case | Multi-language fallback when Apple gaps | Default for live captioning + privacy | Enterprise-data-residency (Azure region), `gpt-4o`-class quality | Multilingual + diarization-rich + lowest WER for batch |

---

## Recommendation

**Adopt Option 1 — Azure batch + ElevenLabs batch — for plan-007 v1.**

Justification:

1. **It precisely satisfies the refined request.** R-4 calls for "a single
   combined plan with one phase per engine"; Option 1 produces exactly
   that. R-5 requires no breaking change to the `TranscriptionProvider`
   protocol; Option 1 satisfies that (batch-only providers exist already
   in the codebase — `GeminiREST`, `WhisperKit`).
2. **It minimises risk.** Both providers are documented at the wire-schema
   level (Azure: full OpenAPI spec via Microsoft Learn; ElevenLabs: full
   request/response field list at
   `/docs/api-reference/speech-to-text/convert`). No reverse-engineering
   needed.
3. **It preserves the existing latency posture.** Apple SpeechAnalyzer
   remains the default, low-latency path; the new providers are explicit
   opt-ins for users who need Azure data residency or ElevenLabs's
   diarization / language breadth.
4. **It defers the one open implementation risk.** ElevenLabs's
   `scribe_v2_realtime` WebSocket protocol is opaque (SDK-only docs).
   Shipping it in plan-007 would require an exploratory probe and a
   wire-schema research note, doubling the work. Capturing it as
   plan-007 lets the user evaluate whether the latency / quality win
   justifies the extra implementation cost after living with the
   batch path for a release cycle.
5. **It keeps the dependency surface flat.** Zero new SwiftPM packages.
   `URLSession` + multipart helper + `JSONDecoder` is the entire
   transport story.

### Per-engine v1 decisions

- **Azure OpenAI `gpt-4o-mini-transcribe`** → **batch only** in v1.
  Mirror `GeminiRESTTranscriptionProvider.swift` exactly. No realtime
  variant available for this model.
  - Provider id: `"azure"`.
  - Wire endpoint:
    `POST {AZURE_OPENAI_ENDPOINT}/openai/deployments/{AZURE_OPENAI_DEPLOYMENT}/audio/transcriptions?api-version={AZURE_OPENAI_API_VERSION}`
  - Auth header: `api-key: {AZURE_OPENAI_API_KEY}`.
  - Body: `multipart/form-data`; required `file`; optional `language`
    (ISO-639-1), `prompt`, `response_format` (default `json`),
    `temperature`.
  - Default API version: pin `2024-10-21` (the GA date for the
    transcriptions surface as documented in the inference REST
    reference).
  - Default deployment: required configuration (no fallback per
    project rule); user creates the deployment in the Azure portal and
    sets `AZURE_OPENAI_DEPLOYMENT`.

- **ElevenLabs `scribe_v2`** → **batch only** in v1.
  Mirror `GeminiRESTTranscriptionProvider.swift` exactly.
  - Provider id: `"elevenlabs"`.
  - Wire endpoint: `POST https://api.elevenlabs.io/v1/speech-to-text`.
  - Auth header: `xi-api-key: {ELEVENLABS_API_KEY}`.
  - Body: `multipart/form-data`; required `model_id="scribe_v2"`;
    required `file` OR `cloud_storage_url`; optional `language_code`
    (ISO-639-1 / -3), `tag_audio_events`, `num_speakers` (1–32),
    `timestamps_granularity` (`word` | `character`), `diarize`,
    `file_format` (`pcm_s16le_16` for the macrec output, lower
    latency), `temperature`, `seed`, `webhook=false`.
  - Default model: pin `"scribe_v2"`. (Per vendor docs `scribe_v1` is
    "outclassed" by v2; `scribe_v2_realtime` is the streaming variant
    deferred to plan-007.)
  - For our use case (16 kHz mono Int16 WAV from `AudioWAVEncoder`),
    set `file_format=pcm_s16le_16` to enable the lower-latency path.
  - Default `language_code`: leave unset (auto-detect); when
    `--transcribe-language` is set, strip BCP-47 region tags
    (`el-GR` → `el`, `en-US` → `en`).

### Per-engine v1 cost-summary surface

`StreamingTranscriptionSession.stop()` returns a `costSummary` field
(per plan-005 §4.2). Even though both new providers are batch-only and
do not use `StreamingTranscriptionSession`, the manager's batch path
emits `TranscriptionManagerStats` (per `TranscriptionManager.swift`
§FR-15-equivalent in plan-005 §4.5). Cost-summary fields per provider:

- **Azure OpenAI batch**:
  - `chunksPosted` = count of HTTPS POSTs.
  - `audioSecondsBilled` = sum of chunk durations sent.
  - `estimatedCost` = `audioSecondsBilled / 60 * 0.003` USD
    (using OpenAI's published `$0.003 / minute` for `gpt-4o-mini-transcribe`;
    Azure is parity-priced as of 2026-04-29 unless the user enables
    "Provisioned" or "Data Zone" SKUs).
  - `lastRTTMs` = elapsed time from POST send to response receive on
    the most recent chunk.
- **ElevenLabs batch**:
  - `chunksPosted` = count of HTTPS POSTs.
  - `audioSecondsBilled` = sum of chunk durations sent.
  - `estimatedCost` = `audioSecondsBilled / 3600 * 0.22` USD (vendor
    rate $0.22/hour for `scribe_v2`). Multipliers: +30 % if
    `entity_detection` enabled; +20 % if `keyterms` provided
    (>100 keyterms triggers a 20 s minimum billable per request); +10 %
    if `detect_speaker_roles` enabled.
  - `lastRTTMs` = elapsed time from POST send to response receive on
    the most recent chunk.

These are surfaced through the existing
`StreamingTranscriptionEvent.metrics(...)` channel (or the equivalent
`TranscriptionManager` end-of-segment stat) — no protocol change needed.

### Conditions under which this recommendation would change

- If the user prioritises sub-500 ms first-partial captioning for
  non-English languages, **revisit Option 2 (ElevenLabs realtime)** as a
  same-PR addition. Implementation cost is real but bounded once the
  wire-schema research note is captured.
- If Microsoft Foundry exposes a transcription-only realtime variant of
  `gpt-4o-mini-transcribe` (currently only `gpt-realtime` family is
  realtime), **revisit Option 3** for Azure streaming.
- If a vendor (Azure or ElevenLabs) ships a first-party Swift SDK,
  **revisit Option 4** to reduce wire-maintenance cost.

### Caveats / prerequisites

- A real `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, and
  `AZURE_OPENAI_DEPLOYMENT` (with a deployed `gpt-4o-mini-transcribe`
  model) must be obtained before the AC `e2e-transcription-azure.sh`
  passes. Resource creation: Azure portal → Foundry / Azure OpenAI
  resource → Models + endpoints → Deploy base model →
  `gpt-4o-mini-transcribe`.
- A real `ELEVENLABS_API_KEY` must be obtained from
  `https://elevenlabs.io/app/settings/api-keys` before
  `e2e-transcription-elevenlabs.sh` passes.
- **Azure regional availability**: as of 2026-04-29,
  `gpt-4o-mini-transcribe` Global Standard is available in
  **eastus2, swedencentral, southindia, francecentral, canadacentral,
  polandcentral, westeurope** (per Microsoft Learn region table — see
  References §3). The Swedish region is the recommended EU residency
  default.
- **Azure cost confirmation**: Azure's pricing page renders prices via
  JS (we observed the public page returns `$-` placeholders to
  unauthenticated fetchers). The plan should cite OpenAI's published
  rate ($0.003 / minute for `gpt-4o-mini-transcribe`) as the upper-bound
  estimate and note that Azure may apply a regional uplift for
  Data Zone or Regional deployments.

---

## Key Findings — Engine API Surfaces

### A. Azure OpenAI `gpt-4o-mini-transcribe` (batch)

#### A.1 Endpoint and connection

- **Endpoint URL pattern**:
  ```
  POST {AZURE_OPENAI_ENDPOINT}/openai/deployments/{AZURE_OPENAI_DEPLOYMENT}/audio/transcriptions?api-version={AZURE_OPENAI_API_VERSION}
  ```
  Example:
  ```
  POST https://my-aoai-resource.openai.azure.com/openai/deployments/gpt-4o-mini-transcribe-prod/audio/transcriptions?api-version=2024-10-21
  ```
- **Endpoint format**: `https://{your-resource-name}.openai.azure.com`
  (no trailing slash). Found in Azure portal → Resource → Keys & Endpoint.
- **Deployment name**: a free-form string the user chose when deploying
  the model in Microsoft Foundry portal → Models + endpoints. NOT the
  same as the underlying model id (e.g. user might name their deployment
  `gpt-4o-mini-transcribe-prod` even though the model is
  `gpt-4o-mini-transcribe (2025-12-15)`).
- **API version**: required query parameter. Pin `2024-10-21` (latest GA
  for transcriptions). Plan-007 documents
  `AZURE_OPENAI_API_VERSION` as a configurable override.
- **Transport**: HTTPS POST. No streaming response variant for this model.
- **No realtime variant**: confirmed via Microsoft Learn 2026-04-29.
  Realtime models are only `gpt-realtime`, `gpt-realtime-mini`,
  `gpt-realtime-1.5`, all conversational. `gpt-4o-mini-transcribe` is
  exclusively `/audio/transcriptions` REST.

#### A.2 Authentication

- **Header name**: `api-key`.
- **Header value**: the resource API key (Azure portal → Resource →
  Keys & Endpoint → KEY1 or KEY2). NOT prefixed with "Bearer".
- **Vendor-canonical env-var name**: `AZURE_OPENAI_API_KEY` (per
  Microsoft Learn quickstarts and CLAUDE.md eight-standard-providers
  list).
- **Alternative auth (NOT v1)**: Microsoft Entra ID via
  `Authorization: Bearer {token}` header. Recommended by Microsoft for
  production but requires the `azure-identity` / MSAL SDK or manual
  token-fetch logic. Defer to v2 per Assumption A-7.
- **CLAUDE.md `<X>_EXPIRES_AT` companion**: `AZURE_OPENAI_API_KEY_EXPIRES_AT`
  (ISO-8601). Azure keys do not auto-expire by date in the portal but
  rotation is recommended; the project's expiration-warning
  infrastructure applies uniformly per plan-005 precedent.

#### A.3 Request body (multipart/form-data)

| Field | Required | Type | Notes |
|---|---|---|---|
| `file` | yes | binary | Audio bytes; we send 16 kHz mono Int16 WAV from `AudioWAVEncoder.encode(samples:)`. Filename in Content-Disposition is purely cosmetic (e.g. `audio.wav`). |
| `prompt` | optional | string | Style hint OR continuation of a prior segment. Should match the audio language. Useful when chunked audio crosses sentence boundaries. |
| `response_format` | optional | enum | `json` (default; `{"text":"..."}`), `text` (raw string), `srt`, `vtt`, `verbose_json` (adds segments + word timestamps). For our pipeline, `json` is sufficient — we re-emit segments through our own sidecar writers. |
| `temperature` | optional | number 0..1 | Default 0; auto-increases on log-prob threshold. |
| `language` | optional | string ISO-639-1 | Improves accuracy and latency. Strip BCP-47 region tags (`el-GR` → `el`). |

**Maximum file size**: **25 MB** per request. At 16 kHz mono Int16 WAV
(2 bytes/sample), this is ~13 minutes of audio per chunk — well above
the project's existing 2.5 s chunk cadence.

#### A.4 Response body

- **`json` format** (default):
  ```json
  { "text": "The complete transcription." }
  ```
- **`verbose_json` format** (when word timestamps wanted):
  ```json
  {
    "task": "transcribe",
    "language": "english",
    "duration": 8.47,
    "text": "The complete transcription.",
    "segments": [
      { "id": 0, "start": 0.0, "end": 4.5, "text": "The complete", ... }
    ],
    "words": [
      { "word": "The", "start": 0.0, "end": 0.18 },
      ...
    ]
  }
  ```
- **`text` / `srt` / `vtt`**: response body is `text/plain` (not JSON).

#### A.5 Error responses

| HTTP status | Cause | Response shape | Map to MacrecError |
|---|---|---|---|
| 400 | Malformed multipart, unsupported `language` | `{"error": {"code": "...", "message": "..."}}` | `.transcriptionConfigConflict(reason:)` |
| 401 | Missing/invalid `api-key` | `{"error": {"code": "401", "message": "Access denied due to invalid subscription key..."}}` | `.transcriptionApiKeyMissing(provider: "azure")` |
| 403 | Subscription quota / disabled feature | `{"error": {"code": "403", "message": "..."}}` | `.transcriptionProviderUnavailable(reason:)` |
| 404 | Deployment name not found in this resource | `{"error": {"code": "DeploymentNotFound", "message": "The API deployment for this resource does not exist..."}}` | `.transcriptionConfigConflict(reason: "Azure deployment '{name}' not found in resource '{endpoint}'")` |
| 413 | Audio file > 25 MB | `{"error": {"code": "...", "message": "..."}}` | `.transcriptionProviderUnavailable(reason: "audio chunk exceeds 25 MB Azure limit")` |
| 429 | Rate limit (TPM / RPM exhausted) | `{"error": {"code": "429", "message": "Rate limit is exceeded. Try again in {n} seconds."}}` | `.transcriptionProviderUnavailable(reason:)`; retry with exponential backoff per `Retry-After` header |
| 500/502/503 | Transient | `{"error": {...}}` | `.transcriptionProviderUnavailable(reason:)`; backoff + retry |
| (timeout) | Network unreachable | (no body) | `.transcriptionProviderUnavailable(reason: "Azure unreachable")` |

#### A.6 Pricing (per minute of input audio)

- **OpenAI direct**: `gpt-4o-mini-transcribe` = **$0.003 / minute**
  (≈ $0.18 / hour) — confirmed via OpenAI public pricing page, 2026-04-29.
- **Azure OpenAI**: parity assumed at $0.003 / minute on Global Standard
  deployment. Data Zone / Regional / Provisioned SKUs may carry a
  regional uplift; the published Azure pricing table renders client-side
  and was not text-scrapable on 2026-04-29 — the plan should cite the
  OpenAI rate as a baseline and direct the user to confirm via the Azure
  pricing calculator for their chosen region.
- **Token-counting model**: priced per-minute, not per-token, for the
  audio path. Underlying OpenAI rate card lists
  `Input: $1.25 / 1M tokens; Output: $5.00 / 1M tokens; Estimated cost:
  $0.003 / minute` (effective per-minute is the published billing unit).

#### A.7 Rate limits

- Per-resource TPM (tokens-per-minute) and RPM (requests-per-minute)
  quotas controlled via Azure portal → Resource → Quotas. Default
  quotas vary by region and tier.
- HTTP 429 responses include a `Retry-After: {seconds}` header. The
  provider should honour this and back off accordingly.

#### A.8 Supported languages

- The audio model under the hood is the GPT-4o-mini family, which
  supports the same language set as Whisper / GPT-4o (~99 languages
  including Greek). The `language` parameter accepts ISO-639-1 codes.
  Supplying the language hint improves accuracy and latency.

#### A.9 Diarization, word-level timestamps

- **Diarization**: `gpt-4o-transcribe-diarize (2025-10-15)` is a separate
  model id with native diarization. `gpt-4o-mini-transcribe` does NOT
  diarize. (If diarization is needed via Azure, the user can deploy
  `gpt-4o-transcribe-diarize` and override `AZURE_OPENAI_DEPLOYMENT`.)
- **Word-level timestamps**: available via `response_format=verbose_json`.

#### A.10 Privacy / data residency

- **Azure region pinning**: data is processed in the Azure region of
  the deployed model. For Global Standard SKU, Microsoft may route to
  any global region. For **Data Zone** SKU, processing stays within EU
  or US zones. For **Regional** SKU, processing stays within the named
  region (e.g. `swedencentral`).
- **No training on user audio**: per Microsoft's Azure OpenAI data
  privacy commitments (see References §11), customer prompts and
  completions are NOT used to train Microsoft / OpenAI models, and
  customer data is processed only for the duration of the request
  unless the customer enables Azure Diagnostics / abuse-monitoring
  logging.
- **Abuse monitoring**: by default, Microsoft retains a 30-day audit
  log of prompts/responses for abuse-monitoring purposes. Enterprise
  customers can disable this via the "Limited Access" / abuse-monitoring
  exemption form.

### B. ElevenLabs `scribe_v2` (batch)

#### B.1 Endpoint and connection

- **Endpoint URL** (batch):
  ```
  POST https://api.elevenlabs.io/v1/speech-to-text
  ```
- **Optional query parameters**:
  - `enable_logging` (boolean, default `true`) — when `false`, "zero
    retention mode" is used (enterprise-only).
- **Transport**: HTTPS POST. No streaming response on this endpoint;
  realtime is a separate `scribe_v2_realtime` model on a separate
  WebSocket endpoint (see §B.7).

#### B.2 Authentication

- **Header name**: `xi-api-key`.
- **Header value**: the API key from
  `https://elevenlabs.io/app/settings/api-keys`.
- **Vendor-canonical env-var name**: `ELEVENLABS_API_KEY` (per official
  Python and Node SDK examples and CLAUDE.md guidance).
- **CLAUDE.md `<X>_EXPIRES_AT` companion**: `ELEVENLABS_API_KEY_EXPIRES_AT`.
  ElevenLabs keys do not auto-expire by date but rotation is
  recommended; the project's existing expiration-warning infrastructure
  applies uniformly.

#### B.3 Request body (multipart/form-data)

| Field | Required | Type | Notes |
|---|---|---|---|
| `model_id` | **yes** | enum | Pin `"scribe_v2"` for batch. (`scribe_v1` is outclassed; `scribe_v2_realtime` is the streaming model on a different endpoint.) |
| `file` | yes (or `cloud_storage_url`) | binary | Audio bytes; min 100 ms; max **3.0 GB**. Major audio + video formats supported. |
| `cloud_storage_url` | yes (or `file`) | string (HTTPS) | Alternative input — server fetches the audio. Deprecated; out of scope for our use. |
| `language_code` | optional | string ISO-639-1 / -3 | When `null` (default), auto-detect. Strip BCP-47 region tags (`el-GR` → `el`). |
| `tag_audio_events` | optional | bool | Default `true`; tags `(laughter)`, `(footsteps)`, etc. |
| `num_speakers` | optional | int 1–32 | Helps speaker prediction. Default `null`. |
| `timestamps_granularity` | optional | enum | `word` (default) or `character`. |
| `diarize` | optional | bool | Default `false`. When `true`, emits `speaker_id` per word. |
| `diarization_threshold` | optional | float 0.1–0.4 | Tunes diarization sensitivity. |
| `additional_formats` | optional | list | Export additional formats (e.g. SRT). |
| `file_format` | optional | enum | `pcm_s16le_16` (16-bit PCM, 16 kHz mono, little-endian — **lower latency**, matches our `AudioWAVEncoder` output minus the WAV header) or `other` (default). |
| `webhook` | optional | bool | When `true`, request returns immediately and result delivered via webhook. **Not used for our synchronous pipeline.** |
| `webhook_id`, `webhook_metadata` | optional | — | Webhook companions. |
| `temperature` | optional | float 0–2 | Sampling determinism. |
| `seed` | optional | int 0..2147483647 | Deterministic sampling (best-effort). |
| `use_multi_channel` | optional | bool | Treat each channel as a separate speaker (max 5). Cost scales linearly with channel count. |
| `entity_detection` | optional | enum / list | Detect PII / PHI / PCI / offensive_language. **+30% surcharge.** |
| `entity_redaction` | optional | enum / list | Redact entities. **+30% surcharge.** |
| `entity_redaction_mode` | optional | enum | `redacted` / `entity_type` / `enumerated_entity_type`. |
| `no_verbatim` | optional | bool | When `true`, removes filler words. **scribe_v2 only.** |
| `detect_speaker_roles` | optional | bool | Tag agent vs customer (when `diarize=true`). **+10% surcharge.** |
| `keyterms` | optional | list[string] | Bias transcription toward up to 1000 keyterms (max 50 chars each, max 5 words after normalization). **+20% surcharge.** When >100 keyterms, 20 s minimum billable per request. |

**Maximum file size**: **3.0 GB** for `file`; 2 GB for `cloud_storage_url`.

#### B.4 Response body (synchronous, single-channel)

```json
{
  "language_code": "en",
  "language_probability": 1.0,
  "text": "With a soft and whispery American accent, I'm the ideal choice for ...",
  "words": [
    { "text": "With", "start": 0.119, "end": 0.259, "type": "word", "speaker_id": "speaker_0" },
    { "text": " ",    "start": 0.239, "end": 0.299, "type": "spacing", "speaker_id": "speaker_0" },
    { "text": "a",    "start": 0.279, "end": 0.359, "type": "word", "speaker_id": "speaker_0" },
    ...
  ]
}
```

For multi-channel input: top-level `transcripts: [...]` array with one
entry per channel. For webhook mode: a `SpeechToTextWebhookResponseModel`
shape (request_id only; transcript delivered later).

#### B.5 Error responses

| HTTP status | Cause | Map to MacrecError |
|---|---|---|
| 401 | Missing / invalid `xi-api-key` | `.transcriptionApiKeyMissing(provider: "elevenlabs")` |
| 403 | Quota exhausted / plan disallows feature | `.transcriptionProviderUnavailable(reason:)` |
| 422 | "Unprocessable Entity" — schema violation (wrong field type, unsupported `model_id`, etc.) | `.transcriptionConfigConflict(reason:)` |
| 413 | Audio > 3 GB (unlikely) | `.transcriptionProviderUnavailable(reason:)` |
| 429 | Concurrency limit hit (free=8, starter=12, creator=20, …) | `.transcriptionProviderUnavailable(reason:)`; retry with backoff |
| 5xx | Transient | `.transcriptionProviderUnavailable(reason:)`; retry with backoff |

#### B.6 Pricing

- **`scribe_v1` / `scribe_v2`** (batch): **$0.22 / hour** (≈ $0.0037 /
  minute) — confirmed via vendor pricing page 2026-04-29.
- **`scribe_v2_realtime`**: $0.39 / hour (~77% premium over batch).
- **Surcharges**:
  - `entity_detection` or `entity_redaction`: **+30%** of base.
  - `keyterms`: **+20%** of base (with 20 s minimum billable per
    request when >100 keyterms).
  - `detect_speaker_roles`: **+10%** of base.
- **Concurrency limits** (per plan tier — affects how many parallel
  segments the manager can process):
  - Free: 8 STT concurrent, 6 realtime STT.
  - Starter: 12 STT, 9 realtime.
  - Creator: 20 STT, 15 realtime.
  - Pro: 40 STT, 30 realtime.
  - Scale / Business: 60 STT, 45 realtime.

#### B.7 Streaming variant — `scribe_v2_realtime` (DEFER to plan-007)

- **Model id**: `scribe_v2_realtime`.
- **Latency**: ~150 ms first-partial.
- **Languages**: 90+, including Greek.
- **Audio formats**: PCM (8 kHz to 48 kHz) and μ-law.
- **Features**: VAD, manual commit, text conditioning (continuation
  across reconnects), automatic language detection with mid-conversation
  switching.
- **Auth**: single-use token fetched server-side (per the React/Python
  SDK examples — `await fetchTokenFromServer()` then
  `scribe.connect({token})`). The exact REST endpoint for token issuance
  is not documented in the public docs as of 2026-04-29 — this is the
  primary unknown that motivates the plan-007 wire-schema research note.
- **Wire protocol shape (inferred from SDK events)**:
  - Outbound: WebSocket TEXT (JSON config) + WebSocket BINARY (PCM
    frames) + WebSocket TEXT (control: commit, finalize, etc.).
  - Inbound: WebSocket TEXT (JSON events): `session_started`,
    `partial_transcript`, `committed_transcript`,
    `committed_transcript_with_timestamps`, `error`, `close`.
- **Why deferred**: the wire schema (URL, exact JSON shapes, token
  endpoint, frame layout) is documented only via the SDK source. Adding
  this to plan-007 would require an exploratory probe and a separate
  research deliverable, doubling the scope. Capturing it as plan-007
  preserves single-PR focus.

#### B.8 Privacy / data residency

- **Default mode**: ElevenLabs retains audio + transcripts for
  observability (plan-tier-dependent retention policy).
- **Zero retention mode**: `enable_logging=false` query parameter —
  **enterprise-only**, available on paid plans, no transcript storage.
- **Compliance**: SOC 2, ISO 27001, PCI DSS L1, HIPAA, GDPR; EU and
  India data residency options on Enterprise.
- **Important for plan-007 §R-8 disclosure copy**: ElevenLabs is
  US-based by default; EU residency requires Enterprise tier.

---

## Resolved Open Questions (from refined request)

| ID | Resolution | Source |
|---|---|---|
| **A-1** (streaming desirable but not mandatory) | **Confirmed for both engines.** Azure: streaming not available for `gpt-4o-mini-transcribe`; only batch. ElevenLabs: streaming available (`scribe_v2_realtime`) but deferred to plan-007 to keep plan-007 scope tight. | Microsoft Learn audio-models §; ElevenLabs models page |
| **A-3** (Azure deployment-name routing) | **Confirmed.** URL pattern `{endpoint}/openai/deployments/{deployment}/audio/transcriptions?api-version=…` is the only path; deployment is portal-configured and free-form. | Microsoft Learn whisper-quickstart, REST reference |
| **A-5** (ElevenLabs STT batch-only) | **REFUTED.** `scribe_v2_realtime` exists and is GA since 2025-11-11. **Plan-007 should still ship batch-only in v1** (per Recommendation §) and document the realtime option as a v2 follow-up (plan-007). | ElevenLabs blog 2025-11-11; models page; client/server-side streaming guides |
| **A-6** (`URLSession` sufficient) | **Confirmed for both batch providers.** Foundation `URLSession` + multipart helper is enough; no SDK needed. | Provider docs |
| **A-7** (Azure auth via `api-key` header in v1) | **Confirmed.** AAD/Entra is the future option; defer to v2. | Microsoft Learn quickstart |
| **A-8** (Apple stays default) | **Confirmed.** Both new providers are explicit opt-ins. | Refined request §A-8 |

## Open Questions Still Requiring Plan-007 Decision

| ID | Status | Note |
|---|---|---|
| **A-2** (latency/quality/cost SLOs) | **Defer.** No SLO hard targets; plan-007 reports observed values per provider. | — |
| **A-4** (UI flat list vs grouped) | **Defer.** Default flat list — append `Azure OpenAI (cloud)` and `ElevenLabs (cloud)` after `Gemini (cloud)`. Picker becomes 5 entries (Apple, WhisperKit, Gemini, Azure, ElevenLabs, None) — still readable. Revisit if it grows past 7. | — |
| **NEW Q1 — `WhisperKit` enum drift** | **Action required** in plan-007. The codebase scan (§5) flagged that `TranscriptionProviderId` (`RecordingOptions.swift:74`) is missing the `.whisperkit` case while the factory accepts the string. Plan-007 should add `.azure`, `.elevenlabs`, AND `.whisperkit` to fix this pre-existing drift in the same PR. | — |
| **NEW Q2 — Azure deployment as CLI flag?** | **Recommend NO** for parity with Gemini's "no `--transcribe-key` flag" privacy posture. Use env-var only (`AZURE_OPENAI_DEPLOYMENT`). | — |
| **NEW Q3 — Per-provider privacy disclosure copy** | **Plan-007 §R-8 must propose verbatim copy for Azure (region-pinned, no training by default) and ElevenLabs (US-based, EU residency on Enterprise).** Sheet currently single-flag `privacyAcknowledged`; recommend per-provider flag (`com.local.macrec-ui.transcription.privacyDisclosureAcknowledged.{providerId}`). | — |
| **NEW Q4 — `ControlBar.startTapped()` API key resolution refactor** | **Action required.** Current code is hardcoded to `GOOGLE_API_KEY` (line 254-257); plan-007 must refactor to provider-aware lookup as part of Azure / ElevenLabs wiring (see codebase scan IP-18). | — |
| **NEW Q5 — Azure deployment-not-found UX** | **Recommend** dedicated remediation message that names the deployment and the endpoint to disambiguate ("Deployment 'foo' not found in resource 'https://...'. Verify the deployment exists in Azure portal → Models + endpoints."). | — |

---

## Provider-Fit Summary (per AC-3 of refined request)

(Reproduced as a single side-by-side block for AC-3 deliverable parity.)

| Axis | Gemini REST (existing) | Apple SpeechAnalyzer (existing) | Azure OpenAI gpt-4o-mini-transcribe (NEW) | ElevenLabs scribe_v2 (NEW) |
|---|---|---|---|---|
| **Mode** | Batch | Streaming | Batch | Batch |
| **First-partial latency** | ~3–5 s | **~80–250 ms** | ~3–5 s | ~3–5 s |
| **Final latency P95** | ~3–5 s | < 1.5 s | ~3–5 s | ~3–5 s |
| **Cost / hour audio** | varies | **$0** | ~$0.18 | $0.22 |
| **English quality** | Excellent | Excellent | Excellent | **Industry-leading** |
| **Greek quality** | Good | Good | Good | Good |
| **Privacy posture** | Cloud (Google) | **On-device** | Cloud, region-pinned, no training default | Cloud (US default; EU on Enterprise); Zero retention enterprise-only |
| **Max audio / request** | (chunked) | continuous | **25 MB** (~13 min @ 16 kHz Int16 WAV) | **3.0 GB** |
| **Supported sample rates / codecs** | (project-side: 16 kHz Float32 → 16 kHz Int16 WAV) | (project-side: 16 kHz Float32) | All major (we send 16 kHz Int16 WAV) | All major (PCM_S16LE_16 explicit option for low latency) |
| **Language list breadth** | Multilingual | Limited to OS-supported locales | ~99 (Whisper-class) | **90+** |
| **Diarization** | No | No | No (use `gpt-4o-transcribe-diarize` model instead) | **Yes** (≤32 speakers, optional agent/customer roles) |
| **Word-level timestamps** | No (segment) | Yes | Yes (`verbose_json`) | **Yes** (word + character) |
| **Native Swift SDK** | No | **Yes** (system framework) | No | No |
| **Recommended use case** | Multi-language fallback when Apple gaps | **Live captioning + privacy** | Enterprise data residency, GPT-4o-class quality | Multilingual + diarization + lowest WER for batch |
| **Provider id (plan-007)** | `gemini` | `apple` | `azure` | `elevenlabs` |

---

## Technical Research Guidance

**Research needed**: **YES (two topics, one optional third).**

### Topic 1: Azure OpenAI Audio API wire-schema deep dive

- **Topic name (slug)**: `azure-openai-gpt-4o-mini-transcribe-wire-schema`
  → file `docs/research/azure-openai-gpt-4o-mini-transcribe-wire-schema.md`.
- **Why**: plan-007's `AzureOpenAITranscriptionProvider.swift` will need
  the verbatim multipart envelope, every header, every error-response
  payload shape, every response-format variant, and the precise
  `api-version` matrix. Microsoft's REST reference is comprehensive but
  spread across many pages — consolidating to one project-local source
  prevents the kind of drift that bit plan-003 (where the upstream
  Gemini Live spec moved underneath the implementation).
- **Focus areas (do not skip)**:
  - Verbatim multipart request envelope including `Content-Type`,
    boundary, per-part `Content-Disposition`, per-part `Content-Type`
    (`application/octet-stream` for the `file` part).
  - All four `response_format` variants (`json`, `text`, `verbose_json`,
    `srt`, `vtt`) with sample payloads.
  - Verbatim error JSON for 400, 401, 403, 404 (DeploymentNotFound),
    413, 429, 5xx.
  - The `Retry-After` header semantics and Azure-specific
    `x-ratelimit-remaining-requests` / `x-ratelimit-remaining-tokens`
    headers if present.
  - The exact api-version pin recommendation (`2024-10-21` GA vs
    `2025-04-01-preview`) and the impact of pinning vs floating.
  - Confirmation that `gpt-4o-mini-transcribe` accepts `language` as a
    bare ISO-639-1 code (vs BCP-47).
  - Region-availability matrix at the date of research (eastus2,
    swedencentral, southindia, francecentral, canadacentral,
    polandcentral, westeurope per the Microsoft Learn 2026-04-29
    snapshot — confirm at probe time).
- **Depth**: **Standard** — full schema capture, no probe required if
  the user lacks an Azure resource yet; otherwise a single live POST
  to confirm the boundary cases is recommended.
- **Relevance**: directly enables Phase A of plan-007 (Azure provider
  implementation, error-handling matrix §AC-7, configuration §AC-6).

### Topic 2: ElevenLabs `scribe_v2` (batch) wire-schema deep dive

- **Topic name (slug)**: `elevenlabs-stt-wire-schema` → file
  `docs/research/elevenlabs-stt-wire-schema.md`.
- **Why**: ElevenLabs's `/v1/speech-to-text` endpoint has the **richest
  optional-field surface** of any provider in this project (24+
  optional fields including diarization, entity detection, keyterm
  prompting, multi-channel, additional formats, webhook mode). Plan-007
  needs to commit to a v1 subset (likely `model_id`, `file`,
  `language_code`, `tag_audio_events`, `timestamps_granularity`,
  `file_format=pcm_s16le_16`) and document the rest as deferred — that
  decision needs the full schema in front of the planner.
- **Focus areas (do not skip)**:
  - Verbatim multipart envelope for the canonical happy-path call
    (`model_id=scribe_v2`, `file`, `language_code`, `file_format=pcm_s16le_16`).
  - Verbatim response shape for: single-channel sync mode (default),
    multi-channel sync mode (`use_multi_channel=true`), webhook mode.
  - Entity detection: full list of detectable categories (PII / PHI /
    PCI / `offensive_language` / `other` and their sub-types). Document
    the surcharge (+30%).
  - Diarization: speaker_id format (`speaker_0`, `speaker_1`, … or
    `agent`/`customer`); how `num_speakers` interacts with
    `diarization_threshold`; the cost interaction with
    `detect_speaker_roles` (+10%).
  - Keyterm prompting: 1000-keyterm cap, 50-char per-keyterm cap,
    >100 keyterm = 20 s minimum billable rule.
  - Verbatim error JSON for 401, 403, 422 (Unprocessable Entity),
    429.
  - Concurrency-limit response headers
    (`current-concurrent-requests`, `maximum-concurrent-requests`).
  - Verify whether `language_code` accepts ISO-639-1 only or also
    ISO-639-3 (the docs say "ISO-639-1 or ISO-639-3"); document
    whether `el` (Greek 639-1) and `ell` (Greek 639-3) are both
    accepted.
- **Depth**: **Standard** — full schema capture, no probe needed if
  the user has an `ELEVENLABS_API_KEY`; otherwise a single live POST
  with a small WAV is recommended.
- **Relevance**: directly enables Phase B of plan-007 (ElevenLabs
  provider implementation, diarization-defer rationale §, error
  matrix §AC-7).

### Topic 3 (OPTIONAL — defer to plan-007): ElevenLabs `scribe_v2_realtime` WebSocket wire-schema deep dive

- **Topic name (slug)**: `elevenlabs-scribe-v2-realtime-wire-schema`
  → file `docs/research/elevenlabs-scribe-v2-realtime-wire-schema.md`.
- **Why**: if/when plan-007 picks up the realtime variant, the wire
  schema will need a deep dive analogous to Soniox's
  `soniox-wire-schema.md`. The vendor's docs publish only the SDK
  surface (`useScribe`, `RealtimeEvents.PARTIAL_TRANSCRIPT`, etc.); the
  raw WebSocket URL, JSON config envelope, binary-frame layout, and
  control-message protocol must be captured from a probe. **NOT REQUIRED
  for plan-007 — flagged here so the user is aware of the v2 cost.**
- **Focus areas (when picked up)**:
  - The single-use-token issuance endpoint (POST URL, request body,
    response shape, token TTL).
  - The WebSocket connect URL (likely
    `wss://api.elevenlabs.io/v1/realtime?model=scribe_v2_realtime&token=…`
    or similar — confirm).
  - The first JSON config message shape (audio format, sample rate,
    language, VAD threshold, manual-commit toggle, text-conditioning
    field).
  - Binary audio frame format (PCM raw bytes, μ-law, frame size
    constraints).
  - Inbound JSON event envelopes for: `session_started`,
    `partial_transcript`, `committed_transcript`,
    `committed_transcript_with_timestamps`, `error`, `close`.
  - Outbound control messages (`commit`, `finalize`, `keepalive`?,
    `update_session`?).
  - Error model and reconnection strategy.
- **Depth**: **Deep** (requires live probe with a real key + traffic
  capture).
- **Relevance**: zero for plan-007; foundational for plan-007.

### Topics where research is NOT needed

- **Azure realtime audio models** — not the model the user requested;
  out of scope.
- **Microsoft Entra ID / managed-identity auth** — Assumption A-7
  defers this to v2.
- **Vendor SDK consumption from Swift** — both vendors' SDKs are
  Python/JS; no Swift SDK; out of scope per NFR.
- **TCC permissions** — REST + WebSocket; no new TCC permissions
  needed (network is already implicit).
- **Sidecar formats (jsonl/srt/vtt/txt)** — implemented; no provider-side
  changes.

---

## Implementation Considerations (notes for plan-007)

- **Provider id strings** (per IP-5 of codebase scan):
  - `"azure"` → `AzureOpenAITranscriptionProvider`.
  - `"elevenlabs"` → `ElevenLabsTranscriptionProvider`.
  - Add cases to `TranscriptionProviderId` enum + factory `switch`.
  - Pre-existing drift: also add `.whisperkit` (codebase-scan §5).

- **Configuration** (per IP-6 / IP-7 of codebase scan):
  - New `ConfigResolver.Keys` constants:
    `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`,
    `AZURE_OPENAI_DEPLOYMENT`, `AZURE_OPENAI_API_VERSION`,
    `ELEVENLABS_API_KEY`, plus `AZURE_OPENAI_API_KEY_EXPIRES_AT`,
    `ELEVENLABS_API_KEY_EXPIRES_AT`.
  - `RecordingOptions` gains: `azureOpenAIEndpoint: String?`,
    `azureOpenAIDeployment: String?`, `azureOpenAIApiVersion: String?`,
    `azureOpenAIApiKeyExpiresAt: Date?`, `elevenLabsApiKeyExpiresAt: Date?`.
  - `TranscriptionProviderFactoryInput` gains the same fields (passed
    to provider `init`); `TranscriptionOptions` stays unchanged
    (Azure-specific config flows via the factory input, not per-call).
  - **No defaults** for any required value (`AZURE_OPENAI_ENDPOINT`,
    `AZURE_OPENAI_DEPLOYMENT`, `AZURE_OPENAI_API_KEY`,
    `ELEVENLABS_API_KEY`); `AZURE_OPENAI_API_VERSION` defaults to
    `"2024-10-21"` (a documented GA value, not a fallback for missing
    user input — the value is immutable at compile time).

- **API-key lookup refactor in `ControlBar.startTapped()`** (per IP-18):
  Replace the hardcoded `GOOGLE_API_KEY` lookup with a switch on
  `normalizedProvider` that resolves to the correct vendor env var
  per provider. **Plan-007 must include this — it's a latent bug today.**

- **Privacy disclosure** (per IP-17 / R-8):
  Two cloud providers added → recommend per-provider acknowledgment
  flag (`com.local.macrec-ui.transcription.privacyDisclosureAcknowledged.azure`,
  `…elevenlabs`) so accepting Gemini's disclosure does not silently
  authorize Azure or ElevenLabs. Suggested copy:
  - **Azure OpenAI**: "Selecting Azure OpenAI sends your audio to
    Microsoft Azure for transcription. Audio is processed in the
    Azure region of your deployment (typically EU or US, depending on
    your resource configuration). Microsoft does not use your audio
    to train its models by default. See Microsoft's Azure OpenAI Data,
    Privacy and Security FAQ at
    https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/privacy."
  - **ElevenLabs**: "Selecting ElevenLabs sends your audio to
    ElevenLabs servers (US-based by default; EU residency available on
    Enterprise plans) for transcription. Audio and transcripts are
    retained per ElevenLabs's plan-tier retention policy. See
    https://elevenlabs.io/privacy and
    https://elevenlabs.io/safety for details. To request zero-retention
    mode, upgrade to an Enterprise plan."

- **Error mapping** (per IP-13):
  Reuse all five existing transcription `MacrecError` cases — no new
  cases required. Specific Azure mappings:
  - HTTP 404 (DeploymentNotFound) → `.transcriptionConfigConflict(reason:)`
    with the deployment name and endpoint in the message.
  - HTTP 413 (file > 25 MB) → `.transcriptionProviderUnavailable(reason:)`
    with explicit "Audio chunk exceeded Azure's 25 MB limit; reduce
    `--transcribe-chunk-seconds` if set" remediation.
  - HTTP 429 → backoff per `Retry-After`; if exhausted, surface as
    `.transcriptionProviderUnavailable(reason:)`.

- **CLI help text** (per IP-14):
  Update `StartCommand.swift:95` to list all valid providers:
  `"none | apple | gemini | whisperkit | azure | elevenlabs"`.

- **UI picker** (per IP-15, Assumption A-4):
  Add two `Text("...").tag(...)` rows to `TranscriptionPicker.swift:72`
  in declaration order:
  ```swift
  Text("Azure OpenAI (cloud)").tag("azure")
  Text("ElevenLabs (cloud)").tag("elevenlabs")
  ```
  Inserted after `"Gemini (cloud)"` and before `"None"`. Update
  `missingKeyTooltip` to be provider-aware.

- **Test plan**:
  - `test_scripts/e2e-transcription-azure.sh` — record 10 s of `say`-
    generated audio, run `macrec start --transcribe azure --once`,
    expect a `*.transcript.jsonl` sidecar with at least one segment
    matching the spoken text. Requires `AZURE_OPENAI_*` env vars.
  - `test_scripts/e2e-transcription-elevenlabs.sh` — same shape;
    requires `ELEVENLABS_API_KEY`.
  - Both scripts must skip cleanly with a clear message if the env
    vars are unset (do NOT fail the suite when the user lacks an
    account).

- **Cost tracking** (per FR-15-equivalent):
  Surface the `costSummary` per the "Per-engine v1 cost-summary
  surface" section above. The math is provider-specific and needs to
  match the vendor's billing unit (per-minute for Azure, per-hour for
  ElevenLabs, with surcharges for opt-in features).

---

## References

| # | Source | URL | What was learned |
|---|---|---|---|
| 1 | Microsoft Learn — Audio quickstart for `gpt-4o-mini-transcribe` (Whisper-style) | <https://learn.microsoft.com/en-us/azure/ai-services/openai/whisper-quickstart> | Confirms `POST {endpoint}/openai/deployments/{deployment}/audio/transcriptions?api-version=2024-02-01`, multipart upload, `api-key` header, `{"text":"..."}` JSON response |
| 2 | Microsoft Learn — Audio models concept | <https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/audio> | Three audio API surfaces (`/realtime`, `/chat/completions`, `/audio`); `gpt-4o-mini-transcribe` lives under `/audio/transcriptions` |
| 3 | Microsoft Learn — Foundry Models sold directly by Azure (audio models) | <https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-models/concepts/models-sold-directly-by-azure?tabs=standard-audio> | `gpt-4o-mini-transcribe` versions: `(2025-03-20)` and `(2025-12-15)`, both Preview; **25 MB max file size**; region availability matrix (eastus2, swedencentral, southindia, francecentral, canadacentral, polandcentral, westeurope as of 2026-04-29); diarize variant `gpt-4o-transcribe-diarize (2025-10-15)` is a separate model |
| 4 | Microsoft Learn — Azure OpenAI realtime audio overview | <https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/realtime-audio> | Realtime API only for `gpt-realtime` family (conversational; speech-in/speech-out); WebRTC ~100 ms / WebSocket ~200 ms; `gpt-4o-mini-transcribe` is NOT a realtime-supported model |
| 5 | Microsoft Learn — Realtime audio via WebSockets | <https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/realtime-audio-websockets> | URL pattern `wss://{resource}.openai.azure.com/openai/v1/realtime?model={deployment}` (GA) or `/openai/realtime?api-version=2025-04-01-preview&deployment={name}` (Preview); auth via `api-key` header or query string, or Microsoft Entra Bearer; only conversational models |
| 6 | Microsoft Learn — Azure OpenAI REST reference (audio transcriptions) | <https://learn.microsoft.com/en-us/azure/ai-services/openai/reference> | Verbatim `POST {endpoint}/openai/deployments/{deployment-id}/audio/transcriptions?api-version=2024-10-21`; multipart request; fields: `file`, `prompt`, `response_format`, `temperature`, `language`; response schema (`audioResponse` / `audioVerboseResponse`) |
| 7 | OpenAI Pricing — Transcription models (used as Azure parity baseline) | <https://platform.openai.com/docs/pricing> | `gpt-4o-mini-transcribe` = **$0.003 / minute** ($1.25 / 1M input tokens; $5.00 / 1M output tokens) |
| 8 | ElevenLabs Docs — Speech-to-Text Convert (batch endpoint) | <https://elevenlabs.io/docs/api-reference/speech-to-text/convert> | `POST /v1/speech-to-text`; multipart fields: `model_id`, `file`, `language_code`, `tag_audio_events`, `num_speakers`, `timestamps_granularity`, `diarize`, `additional_formats`, `file_format` (incl. `pcm_s16le_16`), `webhook`, `temperature`, `seed`, `use_multi_channel`, `entity_detection`, `entity_redaction`, `keyterms`, `no_verbatim`, `detect_speaker_roles`; **3.0 GB max file**; 100 ms min audio; `enable_logging=false` query for zero retention |
| 9 | ElevenLabs Docs — Models overview | <https://elevenlabs.io/docs/models> | Models: `scribe_v1`, `scribe_v2`, `scribe_v2_realtime` (90+ langs); concurrency limits per plan; `scribe_v2_realtime` features (PCM 8–48 kHz, μ-law, VAD, manual commit, ~150 ms first-partial) |
| 10 | ElevenLabs Docs — Speech-to-Text capability page | <https://elevenlabs.io/docs/capabilities/speech-to-text> | Verbatim response shape (`language_code`, `language_probability`, `text`, `words[]` with `text`/`start`/`end`/`type` (`word`|`spacing`)/`speaker_id`) |
| 11 | ElevenLabs Pricing — API tier | <https://elevenlabs.io/pricing/api> | **Scribe v1/v2 = $0.22/hour batch**; **Scribe v2 Realtime = $0.39/hour**; entity detection +30%, keyterms +20%, detect_speaker_roles +10% |
| 12 | ElevenLabs Blog — Introducing Scribe v2 (batch) | <https://elevenlabs.io/blog/introducing-scribe-v2> | `scribe_v2` features: keyterm prompting (≤100 words), entity detection (56 categories), automatic multi-language, dynamic audio tagging, smart speaker diarization, EU + India residency on Enterprise, zero retention |
| 13 | ElevenLabs Blog — Introducing Scribe v2 Realtime | <https://elevenlabs.io/blog/introducing-scribe-v2-realtime> | `scribe_v2_realtime` GA 2025-11-11; <150 ms first-partial; 90 langs; negative-latency (next word + punctuation prediction); text conditioning; VAD; manual commit; PCM 48 kHz + μ-law; SOC 2, ISO 27001, PCI DSS L1, HIPAA, GDPR; EU + India residency; zero retention |
| 14 | ElevenLabs Docs — Realtime client-side streaming guide | <https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/client-side-streaming> | React SDK pattern (`useScribe({modelId: "scribe_v2_realtime"})`), single-use token from server, events: `onPartialTranscript`, `onCommittedTranscript`, `onCommittedTranscriptWithTimestamps` |
| 15 | ElevenLabs Docs — Realtime server-side streaming guide | <https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/server-side-streaming> | Python SDK realtime API (`elevenlabs.speech_to_text.realtime.connect(...)`), `RealtimeEvents`: SESSION_STARTED, PARTIAL_TRANSCRIPT, COMMITTED_TRANSCRIPT, COMMITTED_TRANSCRIPT_WITH_TIMESTAMPS, ERROR, CLOSE |
| 16 | ElevenLabs Help — Supported Languages (TTS reference; STT 90+ langs documented separately) | <https://help.elevenlabs.io/hc/en-us/articles/13313366263441-What-languages-are-supported> | Greek (`ELL`) supported across multiple TTS models; corroborates STT 90+ language coverage including Greek |
| 17 | Internal: codebase scan | [`docs/reference/codebase-scan-additional-stt-engines.md`](codebase-scan-additional-stt-engines.md) | Integration touch points (IP-1 through IP-19); pre-existing drift (`whisperkit` enum case missing); `ControlBar` GOOGLE_API_KEY hardcoding (IP-18) |
| 18 | Internal: refined request | [`docs/design/refined-request-additional-stt-engines.md`](../design/refined-request-additional-stt-engines.md) | R-1..R-8 / AC-1..AC-12 / Assumptions A-1..A-10 |
| 19 | Internal: plan-004 (Gemini REST batch baseline) | [`docs/design/plan-004-rest-batch-transcription.md`](../design/plan-004-rest-batch-transcription.md) | The batch-REST pattern Azure and ElevenLabs both mirror |
| 20 | Internal: plan-005 (Apple SpeechAnalyzer streaming baseline) | [`docs/design/plan-005-apple-speech-streaming.md`](../design/plan-005-apple-speech-streaming.md) | Extended `TranscriptionProvider` protocol (`supportedModes`, `openStreamingSession`); `StreamingTranscriptionSession` shape |
| 21 | Internal: Soniox investigation (template + provider-fit reference) | [`docs/reference/investigation-soniox-streaming.md`](investigation-soniox-streaming.md) | Investigation document template; cross-engine comparison conventions |

---

## Original Request

```
Investigate available approaches for adding two new speech-to-text engines as
additional `TranscriptionProvider` implementations in a macOS Swift recording
app:

1. Azure OpenAI gpt-4o-mini-transcribe (deployment-based; uses an Azure
   OpenAI resource with a model deployment named e.g. `gpt-4o-mini-transcribe`).
   Reference: https://learn.microsoft.com/azure/ai-services/openai/concepts/models#audio-models
   and the OpenAI Audio API surface (`/audio/transcriptions`, plus the new
   `gpt-4o-transcribe` realtime/streaming variant where applicable).
2. ElevenLabs Speech-to-Text API. Reference:
   https://elevenlabs.io/docs/api-reference/introduction (Speech-to-Text
   endpoints, both batch and streaming where supported).

A third engine — Apple SpeechAnalyzer — is in scope as the existing baseline
(already implemented in plan-005); the user does NOT want a new implementation
for it. Reference it as the existing comparator only.

Goal: study the public API documentation of the two new engines and produce
a plan + design to add them as additional `TranscriptionProvider`
implementations alongside the existing Gemini Live (streaming) and
Apple SpeechAnalyzer (on-device) providers, plus the existing batch REST
provider documented in plan-004.

The user has decided up front:
- Output of this workflow is a single combined plan
  (`plan-007-additional-stt-engines.md`) with one phase per engine.
- No code is to be written by this workflow — only research, plan, and
  design artifacts.
- Implementation language is Swift (per Exception 001 in CLAUDE.md).
- Deployment target is macOS 26 (per Exception 002 in CLAUDE.md).
```

Refined request: [`docs/design/refined-request-additional-stt-engines.md`](../design/refined-request-additional-stt-engines.md)
