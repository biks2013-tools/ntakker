# Plan 006 — Additional STT Engines (Azure OpenAI batch + Azure OpenAI Realtime + ElevenLabs Scribe v2)

> **Status**: Design / Implementation plan — single PR scope, awaiting user
> review of §13 Open Decisions before code starts.
>
> **Date**: 2026-04-29 (Phase A2 added 2026-04-29 — see §3 + §A2)
>
> **Engines covered**:
> 1. Azure OpenAI `gpt-4o-mini-transcribe` — **batch REST** (Phase A1).
> 2. Azure OpenAI `gpt-4o-mini-transcribe` — **realtime WebSocket**
>    (Phase A2, `intent=transcription`). Brought into plan-007 on
>    2026-04-29 after the dedicated wire-schema research
>    (`docs/research/azure-openai-realtime-transcription-wire-schema.md`)
>    confirmed the path is real, documented, and within reach for a
>    Foundation `URLSessionWebSocketTask` provider.
> 3. ElevenLabs `scribe_v2` — **batch REST** (Phase B).
>
> **Out of scope for plan-007** (deferred to plan-007 or later):
> - ElevenLabs realtime (`scribe_v2_realtime`).
> - Microsoft Entra ID / managed-identity bearer auth on the Azure path
>   (api-key only in v1).
> - Webhook async mode for ElevenLabs.
>
> **Mandatory inputs** (all relative to this worktree):
> - `docs/design/refined-request-additional-stt-engines.md`
> - `docs/reference/codebase-scan-additional-stt-engines.md`
> - `docs/reference/investigation-additional-stt-engines.md`
>   (plus the 2026-04-29 erratum at the top of that file, which
>   corrects the original "no Azure realtime path" finding)
> - `docs/research/azure-openai-gpt-4o-mini-transcribe-wire-schema.md`
>   (batch REST — §14 patched 2026-04-29 to point at the realtime file)
> - `docs/research/azure-openai-realtime-transcription-wire-schema.md`
>   (realtime WebSocket — primary input for Phase A2)
> - `docs/research/elevenlabs-stt-wire-schema.md`
> - `docs/design/plan-003-live-transcription.md` (deprecated streaming reference)
> - `docs/design/plan-004-rest-batch-transcription.md` (the REST-batch pattern Phase A1 / Phase B mirror)
> - `docs/design/plan-005-apple-speech-streaming.md` (the in-tree streaming-provider pattern Phase A2 mirrors — `StreamingTranscriptionSession`, `AsyncStream<StreamingTranscriptionEvent>`)
>
> **Approved exceptions honoured**:
> - **Exception 001 — Swift, not TypeScript.** All artefacts here are Swift.
> - **Exception 002 — macOS 26 deployment target.** Free use of Swift 6 concurrency.
>
> **Project rules honoured**:
> - **No fallback values for required configuration** — missing required
>   env vars throw `MacrecError.transcriptionApiKeyMissing(...)` or
>   `MacrecError.transcriptionConfigConflict(...)` at provider construction.
> - **No new SwiftPM dependencies** — Foundation `URLSession` + a small
>   in-tree `MultipartFormDataBuilder` helper is sufficient.
> - **Vendor-canonical env-var names** — `AZURE_OPENAI_*` and
>   `ELEVENLABS_API_KEY` per CLAUDE.md eight-standard-providers list.
> - **Expiration companion env vars** for every credential per CLAUDE.md
>   `<configuration-guide>` rule.

---

## 1. Goal

Add two additional `TranscriptionProvider` conformers to the existing
`MacrecCore` transcription subsystem:

1. **Azure OpenAI `gpt-4o-mini-transcribe`** (batch REST) — for users who
   need enterprise data residency, an existing Azure relationship, or
   `gpt-4o`-class transcription quality with multilingual coverage
   (~99 languages) at $0.003/min ($0.18/hr).
2. **ElevenLabs `scribe_v2`** (batch REST) — for users who need
   industry-leading WER (93.5% FLEURS), 90+ languages including Greek,
   native diarization (up to 32 speakers), and word-level timestamps,
   at $0.22/hr.

Both providers slot into the existing `TranscriptionProvider` /
`StreamingTranscriptionSession` / `TranscriptionMode` contract from
plan-005 §4.1 with **no protocol changes**, **no new TCC permissions**,
and **no new SwiftPM dependencies**. They MUST coexist with the four
existing live conformers (`NoOp`, `Fake`, `GeminiREST`, `AppleSpeech`)
plus the in-tree `WhisperKit` provider, none of which are modified
beyond a one-line factory edit and an enum-case fix (the pre-existing
`.whisperkit` drift flagged in the codebase scan §5).

The CLI surface (`macrec --transcribe azure | elevenlabs`) and the
menu-bar provider picker (`Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift`)
gain two new opt-in entries. **Apple SpeechAnalyzer remains the default**
provider per Assumption A-8 — the new providers are explicit opt-ins.

---

## 2. Why this addition

### 2.1 What the existing providers cover today

| Provider          | Mode      | Strengths                                    | Gaps                                              |
|---|---|---|---|
| `NoOp`            | none      | zero-cost smoke test                         | not a real STT                                    |
| `Fake`            | both      | deterministic test fixture                   | not a real STT                                    |
| `GeminiREST`      | batch     | multilingual, Google-region                  | Google data path, no diarization, no word ts      |
| `AppleSpeech`     | streaming | on-device, $0, ~80–250 ms first-partial      | locale-list bound to OS, no diarization           |
| `WhisperKit`      | batch     | on-device, multilingual                      | model download cost, slower than Apple on M-series|

### 2.2 Value-add per new engine

**Azure OpenAI `gpt-4o-mini-transcribe`** brings:
- **Enterprise data residency** — Microsoft contractually commits no
  training on user audio (research §13). Global Standard SKU may route
  through East US 2; Regional / Data Zone deployments pin processing.
- **`gpt-4o` model family quality** — ~50% lower WER than the previous
  preview snapshot per Microsoft's December 2025 release notes.
- **Existing Azure relationship reuse** — for users who already pay
  Azure for other workloads, no new vendor onboarding.

**ElevenLabs `scribe_v2`** brings:
- **Industry-leading WER** on FLEURS benchmark (vendor-cited 93.5%
  accuracy on English; competitive on Greek and 88 other languages).
- **Native diarization** — `diarize=true` returns `speaker_id` per word,
  up to 32 speakers; optional `detect_speaker_roles` labels
  `agent` / `customer` for support call workflows.
- **Word-level timestamps** in the response (`words[].start` / `.end`)
  with optional character-level granularity (`timestamps_granularity=character`).
- **Audio-event tagging** (`(laughter)`, `(footsteps)`, `(music)`) via
  `tag_audio_events=true`.
- **3 GB / 4.5 hr per request** — effectively unlimited for our 2.5 s
  flush cadence.

### 2.3 Why mostly batch in v1 (with a single streaming exception for Azure)

Per the investigation (§Recommendation), modified by the 2026-04-29
realtime-research erratum:

1. **Azure DOES expose a realtime transcription variant for
   `gpt-4o-mini-transcribe`.** The Azure `/realtime` WebSocket serves
   `intent=transcription` (`wss://{resource}.openai.azure.com/openai/realtime?api-version=2025-04-01-preview&intent=transcription`)
   alongside the conversational `gpt-realtime` family. Earlier drafts
   of this plan (and the §14 batch-research stub it was based on)
   stated the opposite. **That earlier finding was incorrect**;
   corrected per
   `docs/research/azure-openai-realtime-transcription-wire-schema.md`.
   The realtime path is in scope as **Phase A2** of this plan.
2. **ElevenLabs DOES expose `scribe_v2_realtime` over WebSocket** (GA
   2025-11-11, ~150 ms first-partial, $0.39/hr) but its wire protocol
   is SDK-mediated and only partially documented. Adding it to plan-007
   would (a) double the implementation surface for ElevenLabs, (b)
   introduce a token-fetch indirection different from the batch
   `xi-api-key` header, and (c) risk shipping against a moving wire
   schema. **Only ElevenLabs realtime stays deferred to plan-007** —
   the user evaluates whether the latency win justifies the cost after
   a release cycle of batch usage.
3. **Apple SpeechAnalyzer already covers the live captioning niche
   on-device** with no API spend; Azure Realtime adds the
   cloud-quality streaming option for users who need a hosted
   alternative.

### 2.4 Why no new SPM dependencies

Both endpoints are documented HTTPS multipart POSTs returning JSON.
Foundation provides `URLSession.data(for:)`, `URLRequest`, and
`JSONDecoder`. Multipart body assembly is ~40 lines of pure Foundation
(see research §16 for Azure and §5 for ElevenLabs). The existing
`AudioWAVEncoder` (`Sources/MacrecCore/Transcription/AudioWAVEncoder.swift`)
already produces the 16 kHz mono Int16 WAV that both providers accept.
A vendor SDK would buy nothing — neither vendor publishes a Swift SDK.

---

## 3. Architectural overview

### 3.1 Component diagram (text)

```
                          ┌────────────────────────────────────────┐
                          │ Sources/macrec/Commands/StartCommand   │
                          │   --transcribe {none|apple|gemini|     │
                          │                whisperkit|azure|       │
                          │                azure-openai-realtime|  │  (NEW: A2)
                          │                elevenlabs}             │  (NEW: azure, elevenlabs, azure-openai-realtime)
                          └──────────────────┬─────────────────────┘
                                             │ ConfigResolver four-tier chain
                                             ▼
                          ┌────────────────────────────────────────┐
                          │ MacrecCore/Config/RecordingOptions     │
                          │   transcriptionProviderId  : String?   │
                          │   transcriptionApiKey      : String?   │
                          │   azureOpenAIEndpoint      : String?   │  (NEW)
                          │   azureOpenAIDeployment    : String?   │  (NEW)
                          │   azureOpenAIApiVersion    : String?   │  (NEW)
                          │   azureOpenAIApiKeyExpiresAt : Date?   │  (NEW)
                          │   elevenLabsApiKeyExpiresAt: Date?     │  (NEW)
                          └──────────────────┬─────────────────────┘
                                             │
                                             ▼
                          ┌─────────────────────────────────────────────────┐
                          │ TranscriptionProviderFactory.build(_:)          │
                          │  switch normalized {                            │
                          │    case "none","": NoOp                         │
                          │    case "gemini":   GeminiREST                  │
                          │    case "apple":    AppleSpeech                 │
                          │    case "whisperkit": WhisperKit                │
                          │    case "azure":                AzureOpenAI       ◄── NEW (A1, batch)
                          │    case "azure-openai-realtime":                  ◄── NEW (A2, streaming)
                          │           AzureOpenAIRealtimeTranscriptionProvider│
                          │    case "elevenlabs":           ElevenLabs        ◄── NEW (B, batch)
                          │  }                                              │
                          └────────────────────┬────────────────────────────┘
                                               │
                                               ▼
                  ┌─────────────────────────────────────────┐
                  │ TranscriptionProvider (Sendable)        │
                  │   .id, .displayName, .supportedModes    │
                  │   .transcribe(samples:source:options:)  │
                  │   .openStreamingSession(...)            │
                  └────────────────────┬────────────────────┘
                                       │
       ┌───────────────────────────────┼─────────────────────────────────┐
       │                               │                                 │
       ▼                               ▼                                 ▼
┌──────────────────────┐  ┌────────────────────────────────────┐  ┌──────────────────────────┐
│ AzureOpenAITranscrip-│  │ AzureOpenAIRealtimeTranscriptionPro │  │ ElevenLabsTranscription- │
│ tionProvider (A1)    │  │ vider (A2 — streaming)              │  │ Provider (B, batch)      │
│ ─────────────────────│  │ ────────────────────────────────────│  │ ─────────────────────────│
│ AudioWAVEncoder      │  │ AudioRingBuffer<Int16>(5 s @ 24 kHz)│  │ AudioWAVEncoder          │
│ MultipartFormDataBldr│  │ AudioResampler16to24                │  │ MultipartFormDataBldr    │
│ URLSession.data(for:)│  │ URLSessionWebSocketTask             │  │ URLSession.data(for:)    │
│ JSONDecoder ──▶ text │  │ RealtimeWireTypes (Codable events)  │  │ JSONDecoder ──▶ text     │
│ supportedModes:      │  │ AzureOpenAIRealtimeSession          │  │ supportedModes: [.batch] │
│   [.batch]           │  │   conforms StreamingTranscriptionSe.│  │                          │
│                      │  │ supportedModes: [.streaming]        │  │                          │
└──────────────────────┘  └────────────────────────────────────┘  └──────────────────────────┘
       │                               │                                 │
       │                               │                                 │
       │                               ▼                                 │
       │                  ┌────────────────────────────────────┐         │
       │                  │ AsyncStream<StreamingTranscription │         │
       │                  │ Event> (.partial / .final /        │         │
       │                  │ .metrics / .error)                 │         │
       │                  └────────────────────┬───────────────┘         │
       │                                       │                         │
       └───────────────────────────────────────┼─────────────────────────┘
                                               ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ TranscriptionManager                                        │
            │   batch path  → SourceBuffer → SegmentCoalescer             │
            │   stream path → consume StreamingTranscriptionEvent stream  │
            │                  → TranscriptSidecarWriter (.batch / .live) │
            └─────────────────────────────────────────────────────────────┘
```

### 3.2 Shared helper vs self-contained types

**Recommendation: each provider is a self-contained type, with one
shared `MultipartFormDataBuilder` value type for body assembly.**

Rationale:
- A `BatchHTTPTranscriptionProvider` superclass would force shared state
  for things that are deliberately different per provider: the URL
  template (Azure has deployment-routing + `api-version`; ElevenLabs
  has a fixed URL), the auth header (`api-key` vs `xi-api-key`), the
  multipart field set (Azure: 6 fields; ElevenLabs: 20+), the response
  decoding (Azure: `{text}`; ElevenLabs: `{text, words[], language_code, …}`),
  and the error envelope (Azure: dual API/APIM format; ElevenLabs:
  FastAPI-style `{detail: {status, message}}`). A superclass would
  collapse to abstract methods on every interesting method, providing
  zero code reuse.
- Swift values that ARE shared:
  - `MultipartFormDataBuilder` — boundary generation, text-field
    append, file-field append, terminator. ~50 LOC.
  - `AudioWAVEncoder.encode(samples:)` — already exists, used
    unchanged.
  - `MacrecError` cases — already exist (`.transcriptionApiKeyMissing`,
    `.transcriptionConfigConflict`, `.transcriptionProviderUnavailable`,
    `.transcriptionPermissionDenied`, `.transcriptionKeyExpired`).
- This mirrors the project's existing pattern: `GeminiRESTTranscriptionProvider`
  is a self-contained `struct` with no superclass; `AppleSpeechTranscriptionProvider`
  is a self-contained `actor`. Adding two more self-contained types is
  consistent and discoverable.

Each provider gets its own folder under `Sources/MacrecCore/Transcription/Providers/`
to keep the wire-format quirks colocated:
- `Sources/MacrecCore/Transcription/Providers/Azure/` — Azure provider,
  config, error, response decoder.
- `Sources/MacrecCore/Transcription/Providers/ElevenLabs/` — ElevenLabs
  provider, config, error, response decoder.

The shared helper lives at:
- `Sources/MacrecCore/Transcription/Net/MultipartFormDataBuilder.swift`

---

## 4. Component contracts (back-compat verification)

### 4.1 `TranscriptionProvider` protocol — no change

The existing protocol at `Sources/MacrecCore/Transcription/TranscriptionProvider.swift:29-44`
(quoted in the codebase scan §IP-1) is sufficient verbatim:

```swift
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedModes: Set<TranscriptionMode> { get }

    func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String

    func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession
}
```

Both new providers declare:

| Member          | Azure                     | ElevenLabs                    |
|-----------------|---------------------------|-------------------------------|
| `id`            | `"azure"`                 | `"elevenlabs"`                |
| `displayName`   | `"Azure OpenAI"`          | `"ElevenLabs Scribe v2"`      |
| `supportedModes`| `[.batch]`                | `[.batch]`                    |
| `transcribe`    | implements                | implements                    |
| `openStreamingSession` | throws `.transcriptionConfigConflict(reason: "Azure provider does not support streaming in v1")` | throws `.transcriptionConfigConflict(reason: "ElevenLabs provider does not support streaming in v1")` |

This matches the `GeminiRESTTranscriptionProvider` pattern at
`Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift:141-148`
verbatim.

### 4.2 Existing conformers — verified back-compat

| Existing conformer | Stays compiling? | Why |
|---|---|---|
| `NoOpTranscriptionProvider`     | YES | Protocol unchanged; no new required member.   |
| `FakeTranscriptionProvider`     | YES | Same.                                         |
| `GeminiRESTTranscriptionProvider` | YES | Same; reference pattern for new providers.  |
| `AppleSpeechTranscriptionProvider` | YES | Same; streaming-mode declaration unchanged.|
| `WhisperKitTranscriptionProvider`  | YES | Same; batch-mode declaration unchanged.    |

No protocol extension is proposed. R-5 of the refined request is
satisfied by leaving the protocol untouched.

### 4.3 `TranscriptionMode` enum — no change

Both new providers use `.batch`. The enum at
`Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift:26-36`
already provides `.batch` and `.streaming`. No new case is required.

### 4.4 `TranscriptionOptions` — no change

Per the codebase scan §IP-8 recommendation, Azure-specific configuration
(endpoint, deployment, apiVersion) is captured at provider construction
time via stored properties on `AzureOpenAITranscriptionProvider` rather
than threaded through `TranscriptionOptions`. This keeps the per-call
options struct stable and avoids churning every existing call site.

ElevenLabs needs nothing beyond what `TranscriptionOptions` already
provides (`apiKey`, `languageHints`, `customSystemInstruction`).

### 4.5 `TranscriptionProviderId` enum — three new cases

The enum at `Sources/MacrecCore/Config/RecordingOptions.swift:74-79`
gains three cases (one to fix pre-existing drift, two new):

```swift
public enum TranscriptionProviderId: String, CaseIterable, Sendable, Codable, Equatable {
    case none
    case apple = "apple"
    case gemini
    case geminiLive = "gemini-live"
    case whisperkit                 // FIX: pre-existing drift (codebase scan §5)
    case azure                       // NEW
    case elevenlabs                  // NEW
}
```

Adding cases is safe — the existing `switch` sites (`ConfigResolver.resolve()`
at line 345-354, `TranscriptionProviderFactory.build()` at lines 46-93)
are explicitly extended in §6 (Phase 0 + Phase A + Phase B).

### 4.6 `TranscriptionProviderFactoryInput` — three new fields

`TranscriptionProviderFactoryInput` (codebase scan §IP-4 lines 5-28)
gains three optional fields, all `nil`-defaulted:

```swift
public struct TranscriptionProviderFactoryInput: Sendable {
    // ... existing fields ...
    public let azureOpenAIEndpoint: String?    // NEW
    public let azureOpenAIDeployment: String?  // NEW
    public let azureOpenAIApiVersion: String?  // NEW
}
```

Existing call sites that don't set these (Gemini, Apple, WhisperKit)
continue to compile because all three are optional with `nil` default.

---

## 5. Configuration variables

All env vars resolved through the existing four-tier chain in
`Sources/MacrecCore/Config/ConfigResolver.swift:89-94`
(`cliOverrides > localEnv > userEnv > shellEnv`). Per CLAUDE.md no
fallback rule, missing required values throw an exception at
factory-build time — never silently default.

### 5.1 New env vars

| Env var | Required | Type | Default | Provider | Notes |
|---|---|---|---|---|---|
| `AZURE_OPENAI_API_KEY`            | YES | String        | none (throw)         | Azure | Vendor-canonical; from Azure portal → Resource → Keys. |
| `AZURE_OPENAI_ENDPOINT`           | YES | URL           | none (throw)         | Azure | Format: `https://{resource-name}.openai.azure.com` (no trailing slash). |
| `AZURE_OPENAI_DEPLOYMENT`         | YES | String        | none (throw)         | Azure | The user-chosen deployment name (NOT the model name). |
| `AZURE_OPENAI_API_VERSION`        | NO  | String        | `"2025-03-01-preview"` (config-guide-documented starter — see §13 Open Decision Az-1) | Azure | Pin to a known-good preview until model GA. |
| `AZURE_OPENAI_API_KEY_EXPIRES_AT` | NO  | ISO-8601 Date | none (no warning)    | Azure | Per CLAUDE.md `<configuration-guide>` rule. |
| `ELEVENLABS_API_KEY`              | YES | String        | none (throw)         | ElevenLabs | Vendor-canonical; from `https://elevenlabs.io/app/settings/api-keys`. |
| `ELEVENLABS_MODEL_ID`             | NO  | String        | `"scribe_v2"`        | ElevenLabs | `scribe_v1` accepted as fallback for older accounts. |
| `ELEVENLABS_LANGUAGE_CODE`        | NO  | String        | unset (auto-detect)  | ElevenLabs | ISO-639-1 (`en`, `el`) or ISO-639-3 (`eng`, `ell`). Strip BCP-47 region. |
| `ELEVENLABS_DIARIZE`              | NO  | Bool          | `false`              | ElevenLabs | When `true`, response carries `speaker_id` per word. |
| `ELEVENLABS_TAG_AUDIO_EVENTS`     | NO  | Bool          | `true`               | ElevenLabs | `(laughter)`, `(music)`, etc. |
| `ELEVENLABS_NUM_SPEAKERS`         | NO  | Int (1..32)   | unset (model default)| ElevenLabs | Hint when count is known. |
| `ELEVENLABS_FILE_FORMAT`          | NO  | Enum          | `pcm_s16le_16` when `AudioWAVEncoder` output detected (see §13 Open Decision EL-3) | ElevenLabs | `pcm_s16le_16` enables low-latency fast-path. |
| `ELEVENLABS_ENTITY_DETECTION`     | NO  | Enum          | unset                | ElevenLabs | When set, enables PII/PHI/PCI detection (+30% surcharge). OFF by default per §13 Open Decision EL-2. |
| `ELEVENLABS_API_KEY_EXPIRES_AT`   | NO  | ISO-8601 Date | none (no warning)    | ElevenLabs | Per CLAUDE.md rule. |

### 5.2 New constants in `ConfigResolver.Keys`

To be added to the `enum Keys` block at
`Sources/MacrecCore/Config/ConfigResolver.swift:401-436`:

```swift
public static let azureOpenAIApiKey            = "AZURE_OPENAI_API_KEY"
public static let azureOpenAIEndpoint          = "AZURE_OPENAI_ENDPOINT"
public static let azureOpenAIDeployment        = "AZURE_OPENAI_DEPLOYMENT"
public static let azureOpenAIApiVersion        = "AZURE_OPENAI_API_VERSION"
public static let azureOpenAIApiKeyExpiresAt   = "AZURE_OPENAI_API_KEY_EXPIRES_AT"

public static let elevenLabsApiKey             = "ELEVENLABS_API_KEY"
public static let elevenLabsModelId            = "ELEVENLABS_MODEL_ID"
public static let elevenLabsLanguageCode       = "ELEVENLABS_LANGUAGE_CODE"
public static let elevenLabsDiarize            = "ELEVENLABS_DIARIZE"
public static let elevenLabsTagAudioEvents     = "ELEVENLABS_TAG_AUDIO_EVENTS"
public static let elevenLabsNumSpeakers        = "ELEVENLABS_NUM_SPEAKERS"
public static let elevenLabsFileFormat         = "ELEVENLABS_FILE_FORMAT"
public static let elevenLabsEntityDetection    = "ELEVENLABS_ENTITY_DETECTION"
public static let elevenLabsApiKeyExpiresAt    = "ELEVENLABS_API_KEY_EXPIRES_AT"
```

### 5.3 Required-vs-optional discipline

Per project rule (Issues - Pending Items.md, no-fallback-for-required):
- `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT`,
  and `ELEVENLABS_API_KEY` are **required** when their provider is active.
  Missing → `MacrecError.transcriptionApiKeyMissing(provider: "azure" | "elevenlabs")`
  (for the API key) or `MacrecError.transcriptionConfigConflict(reason:)`
  (for endpoint / deployment) at factory-build time, exit code 78 / 64.
- `AZURE_OPENAI_API_VERSION` is **optional** with a documented starter
  value (`2025-03-01-preview`) per §13 Open Decision Az-1. The config
  guide explicitly documents this starter as a "known-good pin", not a
  silent fallback — the value lives in `configuration-guide.md` as a
  user-visible default, and the code throws a clear "configure
  `AZURE_OPENAI_API_VERSION` (recommended starter `2025-03-01-preview`)"
  if the variable is absent AND the user did not opt in to the
  documented default. (Decision: see §13 Az-1.)
- ElevenLabs optional fields (`MODEL_ID`, `LANGUAGE_CODE`, `DIARIZE`,
  `TAG_AUDIO_EVENTS`, `NUM_SPEAKERS`, `FILE_FORMAT`, `ENTITY_DETECTION`)
  may be omitted; the provider applies vendor defaults documented in
  the wire-schema research §3.

---

## 6. Phase plan

The plan decomposes into seven phases. Phase 0 is shared scaffolding
that must precede every engine phase. Phases A1 (Azure batch), A2
(Azure realtime — added 2026-04-29), and B (ElevenLabs batch) are
all parallelisable (different files, different folders, different
URL paths, different transports). Phase C wires the UI. Phase D
updates the docs. Phase E adds the tests.

### Phase 0 — Shared scaffolding (BLOCKS Phase A1, Phase A2, and Phase B)

Per the codebase scan anomalies §5 and §IP-15..§IP-19, four pre-existing
issues must be resolved before the new providers can ship cleanly. Phase 0
also adds the one shared helper (`MultipartFormDataBuilder`) that both
new providers consume.

#### Task 0.1 — Add the missing `.whisperkit` enum case (codebase scan §5 anomaly #1)

- **File**: `Sources/MacrecCore/Config/RecordingOptions.swift` line 74-79.
- **Change**: Append `case whisperkit` to `TranscriptionProviderId`.
- **Why first**: `ConfigResolver.parseEnum(...)` currently throws
  `.invalidConfigValue` when `MACREC_TRANSCRIBE=whisperkit` is set,
  because the factory string-matches `"whisperkit"` but the enum is
  missing the case. This is a pre-existing drift; fix it as part of
  the same PR that adds `.azure` and `.elevenlabs`.
- **Verify**: `swift build` (must compile); `MACREC_TRANSCRIBE=whisperkit macrec start` no longer throws.

#### Task 0.2 — Generalise `ControlBar.startTapped()` API-key lookup (codebase scan §IP-18 anomaly #2)

- **File**: `Sources/macrec-ui/Views/ControlBar.swift` lines 253-258.
- **Change**: Replace the hardcoded `ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]`
  with a provider-aware `switch` over `normalizedProvider`:

  ```swift
  let resolvedTranscriptionApiKey: String? = {
      guard transcriptionEnabled else { return nil }
      let envKey: String?
      switch normalizedProvider {
      case "gemini", "gemini-live": envKey = "GOOGLE_API_KEY"
      case "azure":                 envKey = "AZURE_OPENAI_API_KEY"
      case "elevenlabs":            envKey = "ELEVENLABS_API_KEY"
      default:                      envKey = nil  // on-device providers
      }
      guard let envKey else { return nil }
      return ProcessInfo.processInfo.environment[envKey]
          .flatMap { $0.isEmpty ? nil : $0 }
  }()
  ```

  Additionally, when `normalizedProvider == "azure"`, resolve and forward
  `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT`, and
  `AZURE_OPENAI_API_VERSION` into the new `RecordingOptions` fields
  added in §4.5 (Phase A wires those fields end-to-end).
- **Why first**: All UI-driven runs of the new providers go through this
  code path; without the fix `transcriptionMissingKey` would always be
  `true` for the new providers and the run would refuse to start.
- **Verify**: A unit test
  `Tests/MacrecCoreTests/UI/ControlBarKeyResolutionTests.swift`
  exercises each provider id and asserts the correct env var is read.

#### Task 0.3 — Generalise `PrivacyDisclosureSheet.bodyText` (codebase scan §IP-17 anomaly #3)

- **File**: `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift`
  lines 80-84 (per scan §IP-17).
- **Change**: Convert the hardcoded "Google's Gemini API" string into a
  parameterised `bodyText(for providerId: String) -> String` returning
  provider-specific copy:
  - `"gemini"` / `"gemini-live"` → existing Gemini text (unchanged).
  - `"azure"` → exact text from research §13 (Azure-OpenAI privacy
    section — quoted verbatim in §7.1 below).
  - `"elevenlabs"` → exact text from §7.2 below (US-based, SOC 2,
    GDPR, EU residency available enterprise-only).
- **Per-provider acknowledgement flag**: Replace the single
  `com.local.macrec-ui.transcription.privacyDisclosureAcknowledged`
  boolean with a per-provider key
  `com.local.macrec-ui.transcription.privacy.{providerId}.acknowledged`.
  The data-residency posture differs materially between Gemini, Azure,
  and ElevenLabs; users must opt in once per provider, not once
  forever.
- **Migration**: On first run after upgrade, if the legacy boolean is
  `true`, propagate it to the Gemini-specific key and delete the old
  key. Fresh installs see no migration.
- **Verify**: Unit test
  `Tests/MacrecUIKitTests/PrivacyDisclosureSheetCopyTests.swift`
  asserts the body text returns the right snippet per provider id.

#### Task 0.4 — Introduce `ProviderKeyField` (codebase scan §IP-16 anomaly #4)

- **New file**: `Sources/macrec-ui/Views/Transcription/ProviderKeyField.swift`.
- **Change**: Generalise the existing `GeminiKeyField` into a reusable
  view:

  ```swift
  struct ProviderKeyField: View {
      let providerId: String
      let envVarName: String
      let displayLabel: String
      let helpURL: URL?
      // … same secure-text-field + "set in ~/.tool-agents/macrec-ui/.env" body
  }
  ```

- **Edit**: `Sources/macrec-ui/Views/Transcription/GeminiKeyField.swift`
  becomes a 5-line wrapper invoking `ProviderKeyField` with Gemini's
  parameters; ALTERNATIVELY delete the file and have `RootView` call
  `ProviderKeyField(providerId: "gemini", envVarName: "GOOGLE_API_KEY", …)`
  directly. Pick whichever yields fewer call-site changes.
- **Verify**: Visual regression — run `macrec-ui`, select Gemini,
  confirm the key field renders identically to before. Snapshot test
  if available.

#### Task 0.5 — Add `MultipartFormDataBuilder` shared helper

- **New file**: `Sources/MacrecCore/Transcription/Net/MultipartFormDataBuilder.swift`.
- **API**:

  ```swift
  public struct MultipartFormDataBuilder: Sendable {
      public let boundary: String
      public init(boundary: String = "MacrecBoundary-\(UUID().uuidString)")
      public mutating func append(field name: String, value: String)
      public mutating func append(field name: String, fileNamed filename: String, mimeType: String, data: Data)
      public func build() -> (contentType: String, body: Data)
  }
  ```

- **Why a value type**: Allocation cost per request is negligible and
  the value-type semantics avoid actor-related back-pressure for what
  is effectively a `Data` accumulator.
- **Tests**: `Tests/MacrecCoreTests/Transcription/Net/MultipartFormDataBuilderTests.swift`
  asserts:
  - Boundary appears as `--{boundary}` between parts and `--{boundary}--`
    at the end.
  - `Content-Disposition` header is well-formed for both text and file
    parts.
  - Binary file data is appended verbatim (no base64).
  - `contentType` returns `multipart/form-data; boundary={boundary}`.

#### Phase 0 acceptance criteria

- AC-0-1: `swift build` succeeds with the four code edits + one new file.
- AC-0-2: `TranscriptionProviderId.whisperkit` is a recognised raw value
  (verified by setting `MACREC_TRANSCRIBE=whisperkit` and seeing the
  factory dispatch correctly).
- AC-0-3: `ControlBar.startTapped()` resolves `AZURE_OPENAI_API_KEY` when
  the picker is on `"azure"` (verified by the unit test in 0.2).
- AC-0-4: `PrivacyDisclosureSheet` shows provider-specific copy
  (verified by the unit test in 0.3).
- AC-0-5: `ProviderKeyField` renders the existing Gemini UX without
  visual regression (verified by manual smoke + snapshot if available).
- AC-0-6: `MultipartFormDataBuilderTests` pass.

---

### Phase A1 — Azure OpenAI `gpt-4o-mini-transcribe` Batch (REST) provider (depends on Phase 0)

#### A.1 New types

| Type | File |
|---|---|
| `AzureOpenAITranscriptionProvider` | `Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAITranscriptionProvider.swift` |
| `AzureOpenAIConfig`                | `Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAIConfig.swift` |
| `AzureOpenAISTTError`              | `Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAISTTError.swift` |
| `AzureOpenAIResponse`              | `Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAIResponse.swift` |

#### A.2 `AzureOpenAIConfig`

```swift
public struct AzureOpenAIConfig: Sendable, Equatable {
    public let endpoint: URL          // https://{resource}.openai.azure.com (no trailing slash)
    public let deployment: String     // user-chosen deployment name
    public let apiVersion: String     // e.g. "2025-03-01-preview"
    public let apiKey: String         // resolved from AZURE_OPENAI_API_KEY
    public let apiKeyExpiresAt: Date? // optional; surfaces a warning ~7 days before
}
```

Construction validates:
- `endpoint.scheme == "https"` and host ends with `.openai.azure.com`
  (warn but do not throw on mismatch; some users may use a custom domain).
- `deployment` is non-empty.
- `apiVersion` matches `^\d{4}-\d{2}-\d{2}(-preview)?$` (warn but do not
  throw on mismatch).
- `apiKey` is non-empty (caller already enforced).

Missing required field → throws
`MacrecError.transcriptionConfigConflict(reason: "Azure provider requires AZURE_OPENAI_{ENDPOINT|DEPLOYMENT|API_KEY}; got: …")`.

#### A.3 `AzureOpenAITranscriptionProvider`

```swift
public struct AzureOpenAITranscriptionProvider: TranscriptionProvider {
    public let id = "azure"
    public let displayName = "Azure OpenAI"
    public let supportedModes: Set<TranscriptionMode> = [.batch]

    private let config: AzureOpenAIConfig
    private let urlSession: URLSession
    private let logger = LoggerFactory.make("macrec.transcription.azure")

    public init(config: AzureOpenAIConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        // 1. Pre-flight: 25 MB size cap (research §5)
        let wavData = try AudioWAVEncoder.encode(samples: samples)
        guard wavData.count <= 25 * 1024 * 1024 else {
            throw AzureOpenAISTTError.fileTooLarge
        }

        // 2. Build URL: {endpoint}/openai/deployments/{deployment}/audio/transcriptions?api-version={ver}
        var urlComponents = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)!
        urlComponents.path = "/openai/deployments/\(config.deployment)/audio/transcriptions"
        urlComponents.queryItems = [URLQueryItem(name: "api-version", value: config.apiVersion)]
        guard let url = urlComponents.url else {
            throw AzureOpenAISTTError.invalidRequest(message: "Could not build Azure endpoint URL")
        }

        // 3. Build multipart body via shared helper
        var multipart = MultipartFormDataBuilder()
        multipart.append(field: "file", fileNamed: "audio.wav", mimeType: "audio/wav", data: wavData)
        multipart.append(field: "model", value: config.deployment)            // REQUIRED on Azure (research §3)
        multipart.append(field: "response_format", value: "json")             // Only "json" or "text" supported
        if let lang = options.languageHints.first.flatMap(stripBCP47Region) {
            multipart.append(field: "language", value: lang)
        }
        if let prompt = options.customSystemInstruction {
            multipart.append(field: "prompt", value: prompt)
        }
        let (contentType, body) = multipart.build()

        // 4. Build URLRequest
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "api-key")          // NOT "Bearer" — raw key
        request.timeoutInterval = 60

        // 5. POST with retry loop (per research §9)
        let (data, httpResponse) = try await postWithRetries(request: request, body: body)

        // 6. Log diagnostic headers (per research §10)
        logResponseHeaders(httpResponse)

        // 7. Map HTTP status → AzureOpenAISTTError (per research §8)
        try mapStatusCode(httpResponse, body: data)

        // 8. Decode response (json format → {"text": "..."})
        let decoded = try JSONDecoder().decode(AzureOpenAIResponse.self, from: data)
        return decoded.text
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw MacrecError.transcriptionConfigConflict(
            reason: "Azure provider does not support streaming in v1 (gpt-4o-mini-transcribe is REST-only). Use --transcribe apple for streaming."
        )
    }
}
```

`postWithRetries`, `logResponseHeaders`, `mapStatusCode`, and the
`stripBCP47Region` helper are private extensions on the provider. The
retry policy follows research §9 verbatim: 3 attempts max, honour
`Retry-After` header, exponential backoff with ±20% jitter, retry only
on 408/429/500/503 + `URLError.timedOut` / `URLError.networkConnectionLost`.

#### A.4 `AzureOpenAISTTError`

Per research §8, the Swift enum:

```swift
enum AzureOpenAISTTError: Error, Sendable {
    case invalidApiKey                          // 401
    case permissionDenied                       // 403
    case deploymentNotFound                     // 404 (DeploymentNotFound)
    case fileTooLarge                           // 413 / 400 file_too_large
    case unsupportedAudioFormat                 // 415 / 400 invalid_audio_format
    case invalidRequest(message: String)        // other 400s
    case rateLimited(retryAfterSec: Double?)    // 429
    case networkTimeout                         // 408
    case serverError(statusCode: Int)           // 500, 503
    case networkError(underlying: Error)        // URLSession errors
    case unexpectedResponse(statusCode: Int, body: Data)
}
```

Translation to `MacrecError` happens in the provider's call site (so
`MacrecError` does not need a new case set). The mapping table:

| `AzureOpenAISTTError` | `MacrecError` |
|---|---|
| `.invalidApiKey`           | `.transcriptionApiKeyMissing(provider: "azure")` (exit 78)                                          |
| `.permissionDenied`        | `.transcriptionPermissionDenied(provider: "azure")` (exit 77)                                      |
| `.deploymentNotFound`      | `.transcriptionConfigConflict(reason: "Azure deployment '\(name)' not found in resource '\(host)' …")` (exit 64) |
| `.fileTooLarge`            | `.transcriptionProviderUnavailable(reason: "Audio chunk exceeds Azure's 25 MB limit (chunk longer than ~25 min)")` (exit 70) |
| `.unsupportedAudioFormat`  | `.transcriptionProviderUnavailable(reason: "Audio format not accepted by Azure (CAF must be converted to WAV/M4A first)")` (exit 70) |
| `.invalidRequest(msg)`     | `.transcriptionProviderUnavailable(reason: "Azure rejected request: \(msg)")` (exit 70)            |
| `.rateLimited(retryAfter)` | `.transcriptionProviderUnavailable(reason: "Azure rate-limited (retry after \(retryAfter)s); reduce concurrency or upgrade tier")` (exit 70) — only after retries exhausted |
| `.networkTimeout`          | `.transcriptionProviderUnavailable(reason: "Azure read timeout; transient")` (exit 70)             |
| `.serverError(code)`       | `.transcriptionProviderUnavailable(reason: "Azure server error \(code); transient")` (exit 70)     |
| `.networkError(err)`       | `.transcriptionProviderUnavailable(reason: "Azure unreachable: \(err.localizedDescription)")` (exit 70) |
| `.unexpectedResponse(s,_)` | `.transcriptionProviderUnavailable(reason: "Unexpected Azure response (HTTP \(s))")` (exit 70)     |

#### A.5 `AzureOpenAIResponse`

```swift
struct AzureOpenAIResponse: Decodable, Sendable {
    let text: String
}
```

`verbose_json`, `srt`, and `vtt` are NOT supported by `gpt-4o-mini-transcribe`
(research §4.3, §4.4). Sending them returns HTTP 400. v1 only requests
`json`. (`text` format is also valid but unstructured; v1 uses `json`.)

#### A.6 Factory wiring

Add a `case` branch to `TranscriptionProviderFactory.build(_:)` at
`Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift:46-93`:

```swift
case "azure":
    guard let key = input.apiKey, !key.isEmpty else {
        throw MacrecError.transcriptionApiKeyMissing(provider: "azure")
    }
    guard let endpointStr = input.azureOpenAIEndpoint, let endpointURL = URL(string: endpointStr) else {
        throw MacrecError.transcriptionConfigConflict(
            reason: "Azure provider requires AZURE_OPENAI_ENDPOINT (got: \(input.azureOpenAIEndpoint ?? "nil"))"
        )
    }
    guard let deployment = input.azureOpenAIDeployment, !deployment.isEmpty else {
        throw MacrecError.transcriptionConfigConflict(
            reason: "Azure provider requires AZURE_OPENAI_DEPLOYMENT"
        )
    }
    let apiVersion = input.azureOpenAIApiVersion ?? "2025-03-01-preview"   // see §13 Az-1
    let config = AzureOpenAIConfig(
        endpoint: endpointURL,
        deployment: deployment,
        apiVersion: apiVersion,
        apiKey: key,
        apiKeyExpiresAt: input.keyExpiresAt
    )
    return AzureOpenAITranscriptionProvider(config: config)
```

Update the `default` clause's error message to list all six allowed
values: `'none', 'apple', 'gemini', 'whisperkit', 'azure', 'elevenlabs'`.

#### A.7 `ConfigResolver` extension

Extend the API-key resolution switch at lines 345-354:

```swift
case .azure:
    let raw = value(Keys.azureOpenAIApiKey)
    return (raw?.isEmpty == false) ? raw : nil
```

Resolve the three Azure-specific fields (`endpoint`, `deployment`,
`apiVersion`) into new stored properties on `RecordingOptions` (added
at lines 153-205 per the codebase scan §IP-7), and forward them
through `RecordingOptions.withOutput(_:)`.

The expiry-warning logic at lines 357-360 is extended to read
`AZURE_OPENAI_API_KEY_EXPIRES_AT` when the active provider is `.azure`.

#### A.8 CLI flag wiring

In `Sources/macrec/Commands/StartCommand.swift` lines 88-112, update
the `--transcribe` `@Option`'s help text:

```swift
@Option(help: "Transcription provider: none | apple | gemini | whisperkit | azure | elevenlabs")
var transcribe: String?
```

No new `@Option` flags for Azure-specific config — the project's
security model (StartCommand.swift lines 90-93 comment) intentionally
forbids `--transcribe-key` on the CLI; Azure-specific values follow the
same env-var-only pattern. (Decision: do NOT add a
`--transcribe-azure-deployment` flag, per refined-request §IP-14 — keep
the CLI surface stable.)

#### A.9 Cost calculation (per investigation §Cost-summary)

```swift
extension TranscriptionManagerStats {
    static func azureCost(audioSecondsBilled: Double) -> Double {
        return audioSecondsBilled * 0.003 / 60.0    // $0.003 / minute
    }
}
```

Surfaced through the same `TranscriptionMetrics` event channel that
plan-004 §FR-58 already defines.

#### A.10 Phase A1 acceptance criteria

- AC-A-1: `AzureOpenAITranscriptionProvider` declares `id = "azure"`,
  `displayName = "Azure OpenAI"`, `supportedModes = [.batch]`.
- AC-A-2: `transcribe(...)` POSTs to the correct URL pattern with
  `api-key` header (verified by a test using a mock `URLProtocol`).
- AC-A-3: Missing `AZURE_OPENAI_API_KEY` → `MacrecError.transcriptionApiKeyMissing(provider: "azure")` exit 78.
- AC-A-4: Missing `AZURE_OPENAI_ENDPOINT` or `AZURE_OPENAI_DEPLOYMENT`
  → `MacrecError.transcriptionConfigConflict(...)` exit 64.
- AC-A-5: HTTP 404 with `DeploymentNotFound` body
  → `MacrecError.transcriptionConfigConflict(reason: "Azure deployment '…' not found …")`.
- AC-A-6: HTTP 413 → `MacrecError.transcriptionProviderUnavailable(reason: "Audio chunk exceeds 25 MB …")`.
- AC-A-7: HTTP 429 retried up to 3 times with `Retry-After` honoured;
  final failure surfaces `.transcriptionProviderUnavailable`.
- AC-A-8: `openStreamingSession(...)` throws `transcriptionConfigConflict`.
- AC-A-9: Existing four conformers (`NoOp`, `Fake`, `GeminiREST`,
  `AppleSpeech`, `WhisperKit`) still compile and pass their existing
  unit tests unchanged.
- AC-A-10: `e2e-transcription-azure.sh` (Phase E) passes against a real
  Azure deployment.

---

### Phase A2 — Azure OpenAI Realtime Streaming (WebSocket) provider (depends on Phase 0; parallel to Phase A1 and Phase B)

> **Added 2026-04-29.** Brings Azure realtime transcription in scope.
> Sources: `docs/research/azure-openai-realtime-transcription-wire-schema.md`
> (primary), `docs/design/plan-005-apple-speech-streaming.md` (the
> in-tree streaming-provider pattern this phase mirrors).

#### A2.1 Goal & deliverables

**Ships**:
- A new `AzureOpenAIRealtimeTranscriptionProvider` that conforms to
  `TranscriptionProvider` with `id = "azure-openai-realtime"`,
  `displayName = "Azure OpenAI Realtime"`, and
  `supportedModes = [.streaming]`.
- A new `AzureOpenAIRealtimeSession` that conforms to
  `StreamingTranscriptionSession`, drives a Foundation
  `URLSessionWebSocketTask` to the
  `wss://{resource}.openai.azure.com/openai/realtime?api-version=2025-04-01-preview&intent=transcription`
  endpoint, sends 100 ms PCM16 24 kHz mono base64-wrapped JSON audio
  chunks, and emits `StreamingTranscriptionEvent` (.partial / .final /
  .metrics / .error) on its `events` `AsyncStream`.
- A 16→24 kHz `AVAudioConverter` resampler, a 5 s
  `AudioRingBuffer<Int16>` for reconnect-replay, and a 58-min
  pre-emptive reconnect timer.
- Codable wire types for every client + server event from the research
  file (§3-§6) — see §A2.2 / §A2.5.
- Reconnect-with-replay on close 1006 (and 1001 / 1011) with a hard
  cap of 3 attempts within 30 s; pre-emptive reconnect at 58 min for
  the 60-min session cap (RT-3 / RT-4 from the research).
- New CLI mode `--transcribe azure-openai-realtime`; new picker entry
  "Azure OpenAI Realtime" in `TranscriptionPicker`.

**Does NOT ship**:
- `.batch` mode on the realtime provider — it explicitly throws on
  `transcribe(samples:source:options:)`. Batch already exists via
  `AzureOpenAITranscriptionProvider` (Phase A1); having both modes on
  the same type would conflate two distinct wire paths. Each
  provider is single-mode by design.
- Microsoft Entra ID / managed-identity bearer auth — same
  api-key-only posture as Phase A1.
- Ephemeral session-token mint endpoint
  (`/openai/realtimeapi/transcription_sessions`) — not needed for the
  Swift app; the api-key flows directly on the WS upgrade request.
- WebRTC region-pinned endpoints (`https://eastus2.realtimeapi-preview.ai.azure.com/...`)
  — only the standard WebSocket form ships in v1.

#### A2.2 New types

| Type | Kind | Concurrency | One-line purpose |
|---|---|---|---|
| `AzureOpenAIRealtimeTranscriptionProvider` | `public final class` (Sendable) | thread-safe via internal actor | The `TranscriptionProvider` conformer — opens sessions, exposes config, throws on `transcribe(...)`. |
| `AzureOpenAIRealtimeSession` | `actor` (`StreamingTranscriptionSession`) | actor-isolated state | Owns the `URLSessionWebSocketTask`, the receive loop `Task`, the resampler, the ring buffer, the reconnect timer, and the events `AsyncStream` continuation. |
| `AzureOpenAIRealtimeConfig` | `public struct: Sendable, Equatable` | value type | Resolved configuration captured at provider construction (endpoint, deployment, apiVersion, apiKey, VAD config, noise-reduction config, includeLogprobs, deploymentInUrl). |
| `AzureOpenAIRealtimeError` | `public enum: Error, LocalizedError, Sendable` | value type | Realtime-specific typed errors; supplements `AzureOpenAISTTError` from Phase A1 with WS-lifecycle and protocol cases (see list below). |
| `RealtimeWireTypes` | `public enum` (namespace) | value types | Codable models for every client and server event in §3-§6 of the realtime research (see §A2.5 below). |
| `AudioResampler16to24` | `internal struct` | actor-isolated when used in session | `AVAudioConverter` wrapper, 16 kHz Float → 24 kHz Int16 little-endian. |
| `AudioRingBuffer<Sample>` | `internal struct: Sendable` | actor-isolated when used in session | Fixed-capacity FIFO of last N samples for replay-on-reconnect. Generic over `Int16` (PCM) for the realtime session. |

`AzureOpenAIRealtimeError` cases (full):

```swift
public enum AzureOpenAIRealtimeError: Error, LocalizedError, Sendable {
    // WS connection lifecycle
    case connectionFailed(underlying: Error)
    case unauthorizedUpgrade               // HTTP 401 on upgrade
    case policyViolation                   // close 1008
    case abnormalClose(code: Int)          // close 1006 / 1001 / 1011
    case sessionExpired                    // 60-min hard cap reached cleanly

    // Session-level protocol errors (received as `error` events)
    case sessionRejected(type: String, message: String)
    case rateLimited(resetSeconds: Double?)
    case internalServerError(message: String)
    case modelFieldRejected                // RT-1: model field included by mistake

    // Item-level (non-fatal)
    case itemTranscriptionFailed(itemId: String, message: String)

    // Audio / format
    case audioFormatMismatch(reason: String)

    // Reconnect
    case reconnectExhausted(attempts: Int)

    // Catch-all
    case unexpectedEvent(name: String)
}
```

#### A2.3 File locations

All under `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/`
(sibling of the Phase A1 batch files in `…/Azure/`):

| File | One-sentence purpose |
|---|---|
| `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeTranscriptionProvider.swift` | The `TranscriptionProvider` conformer for the realtime path. |
| `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift` | The actor implementing `StreamingTranscriptionSession`, owning the WS lifecycle. |
| `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeConfig.swift` | Resolved configuration struct; validates URL shape and VAD ranges at construction. |
| `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeError.swift` | The `LocalizedError` enum from §A2.2. |
| `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/RealtimeWireTypes.swift` | All Codable client + server event models — see §A2.5. |
| `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AudioResampler16to24.swift` | `AVAudioConverter`-backed 16 kHz Float → 24 kHz Int16 LE. |
| `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AudioRingBuffer.swift` | Generic fixed-capacity FIFO; used at `AudioRingBuffer<Int16>` in the session. |

#### A2.4 New env vars

**Reused (already added by Phase A1)**:

| Env var | Required | Default | Notes |
|---|---|---|---|
| `AZURE_OPENAI_ENDPOINT` | YES | none | Same `https://{resource}.openai.azure.com` shape (provider rewrites scheme to `wss://` and path to `/openai/realtime`). |
| `AZURE_OPENAI_DEPLOYMENT` | YES | none | The deployment name backing `gpt-4o-mini-transcribe` realtime. Required even though the URL may not include `?deployment=` (see OQ-A2-2). |
| `AZURE_OPENAI_API_KEY` | YES | none | Sent as `api-key:` header on the WS upgrade request (RT-8). |
| `AZURE_OPENAI_API_VERSION` | NO | `2025-04-01-preview` (**bumped from `2025-03-01-preview`** — see §A.4.update below) | Realtime requires `2025-04-01-preview`; this version is also accepted by the batch path so plan-007 standardises on it for both. |
| `AZURE_OPENAI_API_KEY_EXPIRES_AT` | NO | none | Same expiry-warning surface as Phase A1. |

> **§A.4.update (api-version)**: Phase A1's documented starter
> `2025-03-01-preview` was the minimum that supported batch `gpt-4o-mini-transcribe`.
> Phase A2 raises the recommended starter to `2025-04-01-preview` (which
> covers both batch AND realtime). Update the configuration-guide and
> the `?? "2025-03-01-preview"` fallback in §A.6 accordingly. Per RT-7
> from the research, this is the only confirmed api-version for the
> realtime path as of 2026-04-29.

**New (realtime-only, all optional)**:

| Env var | Type | Default | Notes |
|---|---|---|---|
| `AZURE_OPENAI_REALTIME_VAD_THRESHOLD` | Float (0.0 .. 1.0) | `0.5` | `turn_detection.threshold`; raise in noisy environments. Invalid value → `MacrecError.transcriptionConfigConflict(reason:)`. |
| `AZURE_OPENAI_REALTIME_VAD_PREFIX_PADDING_MS` | Int (≥ 0) | `300` | `turn_detection.prefix_padding_ms`. |
| `AZURE_OPENAI_REALTIME_VAD_SILENCE_MS` | Int (≥ 0) | `200` | `turn_detection.silence_duration_ms`. |
| `AZURE_OPENAI_REALTIME_NOISE_REDUCTION` | Enum: `near_field` \| `far_field` \| `none` | `near_field` | `near_field` for headset/mic, `far_field` for laptop mic, `none` to omit the field entirely. |
| `AZURE_OPENAI_REALTIME_INCLUDE_LOGPROBS` | Bool | `false` | When `true`, the session includes `["item.input_audio_transcription.logprobs"]` so logprobs ride on delta/completed events. |
| `AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL` | Bool | `false` | Per OQ-A2-2: when `true`, the URL appends `&deployment={name}`; when `false`, it does not. Default off matches the TechCommunity reference; flip to `true` if Azure starts rejecting the URL without it. |

All new vars are subject to the existing **no-fallback rule** for type/parsing —
invalid values throw `MacrecError.transcriptionConfigConflict(reason: …)`
at provider construction time. The default values listed above only
apply when the env var is **unset** (mirroring Phase A1's
`AZURE_OPENAI_API_VERSION` precedent — these are documented protocol
defaults, not silent fallbacks for missing secrets).

The new `ConfigResolver.Keys` constants (additive to §5.2):

```swift
public static let azureOpenAIRealtimeVADThreshold       = "AZURE_OPENAI_REALTIME_VAD_THRESHOLD"
public static let azureOpenAIRealtimeVADPrefixPaddingMS = "AZURE_OPENAI_REALTIME_VAD_PREFIX_PADDING_MS"
public static let azureOpenAIRealtimeVADSilenceMS       = "AZURE_OPENAI_REALTIME_VAD_SILENCE_MS"
public static let azureOpenAIRealtimeNoiseReduction     = "AZURE_OPENAI_REALTIME_NOISE_REDUCTION"
public static let azureOpenAIRealtimeIncludeLogprobs    = "AZURE_OPENAI_REALTIME_INCLUDE_LOGPROBS"
public static let azureOpenAIRealtimeDeploymentInUrl    = "AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL"
```

#### A2.5 Wire summary

Per `docs/research/azure-openai-realtime-transcription-wire-schema.md`
§1-§7 (URL, auth, lifecycle, client events, server events, audio,
VAD), the realtime path is a single bidirectional WebSocket carrying
**TEXT frames containing JSON only** — audio is base64-encoded inside
`input_audio_buffer.append` JSON envelopes; binary frames are NOT
used.

| Aspect | Value |
|---|---|
| URL pattern | `wss://{resource}.openai.azure.com/openai/realtime?api-version=2025-04-01-preview&intent=transcription` (optionally `&deployment={name}` per `AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL`) |
| Auth header | `api-key: {AZURE_OPENAI_API_KEY}` on the upgrade request (RT-8) |
| Audio framing | PCM16 little-endian mono **24 kHz** (research §6); chunk = **100 ms** = 4,800 bytes raw → 6,400 chars base64 wrapped in `input_audio_buffer.append` JSON envelope (~15 MiB / message hard cap, well above the 6.4 KB chunk) |
| Resample | The recorder produces 16 kHz (system audio) or device-rate (mic). The provider runs each chunk through `AudioResampler16to24` before encoding. (See OQ-A2-1.) |
| First server event | `session.created` (NOT `transcription_session.created`) immediately after the 101 Upgrade |
| Required first client event | `transcription_session.update` (NOT `session.update`) carrying the resolved VAD + noise-reduction + include configuration |
| Live partials | `conversation.item.input_audio_transcription.delta` (research §5.8) — accumulate per `item_id` |
| Final per utterance | `conversation.item.input_audio_transcription.completed` (research §5.9) — authoritative `transcript` field |

**⚠️ AZURE-SPECIFIC BUG (RT-1)**: The `session` object in
`transcription_session.update` MUST NOT include a `"model"` field.
Including `"model": "gpt-4o-mini-transcribe"` causes the next item to
fail with
`conversation.item.input_audio_transcription.failed { error.type: "server_error" }`.
The model is implied by the deployment. **Therefore the Codable for
`SessionConfig` must NOT have a `model` property at all.** This is
asserted by `RealtimeWireTypesTests.modelFieldOmitted`. Citation:
realtime research §1.5 / §4.1.

The compiled session-update Codable shape (research §4.1, model field
deliberately absent):

```swift
public enum RealtimeWireTypes {
    /// `transcription_session.update` — sent immediately after `session.created`.
    public struct TranscriptionSessionUpdate: Encodable, Sendable {
        public let type: String = "transcription_session.update"
        public let session: SessionConfig
    }
    public struct SessionConfig: Encodable, Sendable {
        public let inputAudioFormat: String                           // "pcm16"
        public let inputAudioTranscription: InputAudioTranscriptionConfig
        public let turnDetection: TurnDetectionConfig?
        public let inputAudioNoiseReduction: NoiseReductionConfig?
        public let include: [String]?
        // NOTE: NO `model` field — Azure rejects it (RT-1).
        public enum CodingKeys: String, CodingKey {
            case inputAudioFormat = "input_audio_format"
            case inputAudioTranscription = "input_audio_transcription"
            case turnDetection = "turn_detection"
            case inputAudioNoiseReduction = "input_audio_noise_reduction"
            case include
        }
    }
    public struct InputAudioTranscriptionConfig: Encodable, Sendable {
        public let language: String?
        public let prompt: String?
        // NO `model` field — see RT-1.
    }
    /* … turnDetection, noiseReduction, audio append/commit/clear, full
       server event enum below in §A2D-4 of project-design.md … */
}
```

#### A2.6 Event handling state machine

```
┌──────┐  open()           ┌──────────┐  101 Upgrade   ┌──────┐
│ idle ├─────────────────▶ │connecting├──────────────▶ │ready │
└──────┘                   └──────────┘                └──┬───┘
                                                          │ session.created
                                                          ▼
                                                     ┌──────────┐
                                              ┌──────│transcription_session.update sent│
                                              │      └──────────┘
                                              │ session.updated
                                              ▼
                            ┌────────────┐    ingest(samples)    ┌─────────┐
                            │ buffering  │──── audio chunks ────▶│ buffering │
                            └─────┬──────┘                       └────┬────┘
                                  │ delta events                       │
                                  ▼                                    │ speech_stopped
                            (.partial emitted)                         ▼
                                                              ┌────────────┐
                                                              │ committed  │
                                                              └─────┬──────┘
                                                                    │ completed event
                                                                    ▼
                                                              (.final emitted)
                                                                    │
                                                                    ▼
                                                              ┌────────────┐
                                                              │ buffering  │ ◀── next utterance
                                                              └────────────┘

Termination edges (any state → terminal):
  finish() ─────────▶ closing (1000) ──▶ closed
  WS close 1006/1001/1011 ──▶ reconnecting (see §A2.7) ──▶ buffering
  Reconnect attempts > 3   ──▶ closed (.error emitted, .reconnectExhausted)
  58-min timer fires       ──▶ pre-emptive reconnect (see §A2.8)
  WS close 1008            ──▶ closed (.error emitted, .policyViolation, NO retry)
  WS close 1000 at <60 min ──▶ closed (clean end-of-session)
```

#### A2.7 Reconnect-with-replay design

Per research §9 and RT-3, the dominant failure mode is WebSocket close
code **1006** (abnormal, no close frame) — driven by the 60-min cap,
APIM idle timeout, transient APIM edge issues, etc. The provider must
silently recover without dropping audio. Flow:

1. **Detect**: `URLSessionWebSocketTask`'s close handler delivers the
   close code (and reason, if any). 1006 / 1001 / 1011 trigger the
   reconnect path; 1000 (clean end at < 60 min) ends the session;
   1008 surfaces immediately with no retry.
2. **Buffer last 5 s of audio**: the session keeps an
   `AudioRingBuffer<Int16>` sized at **120,000 samples** (5 s × 24 kHz)
   = **240,000 bytes raw PCM** (well below any per-message limit when
   replayed in chunks). Every audio frame appended to the WS is
   simultaneously appended to the ring buffer.
3. **Reconnect**: open a fresh `URLSessionWebSocketTask` to the same
   URL, reattach the `api-key` header, await `session.created`, send
   the same `transcription_session.update` (Codable struct cached
   from initial open; no need to re-resolve config).
4. **Replay**: drain the ring buffer in 100 ms chunks, sending each
   wrapped in `input_audio_buffer.append`. The server's VAD will
   re-detect speech starts from the replayed audio; `item_id` will be
   newly assigned (see RT-RISK-3 — the provider dedupes by tracking
   the most recent `item_id` and discarding any final whose audio
   range overlaps the previous final's range).
5. **Resume**: continue normal `ingest(samples)` flow.
6. **Backoff**: attempt 1 fires immediately. If it also fails:
   attempt 2 after 1 s; attempt 3 after 4 s ± 20% jitter. If attempt
   3 still fails within a 30-second window, surface
   `AzureOpenAIRealtimeError.reconnectExhausted(attempts: 3)` via the
   events stream and close the session.
7. **UI signal**: between attempts the session emits
   `.metrics(StreamingProviderMetrics{errorCount += 1})` and a
   `.error(detail: "Azure realtime: reconnecting (attempt \(n)/3)…")`
   so the live-transcript panel can show a transient "reconnecting"
   indicator without tearing down the recording.

Pseudocode for the close handler (run inside the actor):

```swift
private func handleClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) async {
    switch code {
    case .normalClosure:                    // 1000
        await emit(.metrics(metrics))
        await close()
    case .policyViolation:                  // 1008
        await emit(.error(detail: "Azure realtime: auth policy violation; not retrying"))
        await close()
    default:                                // 1001, 1006, 1011, others
        await attemptReconnectWithReplay()
    }
}
```

#### A2.8 60-min session boundary

Per research §3 (session duration limits), Azure caps any single
realtime session at **60 minutes**. The provider must pre-emptively
reconnect at **58 minutes** to avoid an in-flight transcription being
cut off by the server's hard close.

Implementation:

1. The session records `sessionStart = Date()` after the first
   `session.created` arrives.
2. A long-lived child `Task` awaits
   `try await Task.sleep(for: .seconds(58 * 60))`.
3. On wake, **wait for the next `committed` (or `speech_stopped`) event
   before triggering reconnect** (RT-RISK-4 — never interrupt an
   in-progress utterance). Once the boundary is crossed cleanly,
   trigger the same reconnect-with-replay flow as §A2.7 (but starting
   with a clean 5 s replay of any audio that has accumulated since
   the last `committed`).
4. After the reconnect, `sessionStart` is reset and the 58-min timer
   restarts.

Edge case: the 60-min cap may also fire as a `1000` close. The
provider treats 1000 close at age ≥ 58 min as "session expired
cleanly, reconnect" rather than "user stopped" (the latter is signaled
by `finish()` setting an internal `userInitiatedClose` flag).

#### A2.9 CLI + UI wiring

**CLI**: `Sources/macrec/Commands/StartCommand.swift` — `--transcribe`
help text gains `azure-openai-realtime`:

```swift
@Option(help: "Transcription provider: none | apple | gemini | whisperkit | azure | azure-openai-realtime | elevenlabs")
var transcribe: String?
```

No new `@Option` flags for VAD config — same env-var-only posture as
all other provider tuning.

**Enum**: `TranscriptionProviderId` (see §4.5) gains a fourth new
case:

```swift
case azureOpenAIRealtime = "azure-openai-realtime"
```

(now 8 total cases: `none`, `apple`, `gemini`, `geminiLive`,
`whisperkit`, `azure`, `azureOpenAIRealtime`, `elevenlabs`).

**Picker**: `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift`
(extends Phase C.1) — additional entry between `azure` and
`elevenlabs`:

```swift
Text("Azure OpenAI (cloud, batch)").tag("azure")
Text("Azure OpenAI Realtime (cloud, streaming)").tag("azure-openai-realtime")  // NEW (A2)
Text("ElevenLabs Scribe v2 (cloud)").tag("elevenlabs")
```

Note the relabel of `"azure"` from "Azure OpenAI (cloud)" to
"Azure OpenAI (cloud, batch)" so the two Azure entries are
distinguishable at a glance.

**Privacy disclosure (Phase 0.3 + Phase C.3)** — new variant:
`PrivacyDisclosureSheet.bodyText(for: "azure-openai-realtime")` returns:

> "Audio will be streamed live to Microsoft Azure OpenAI Service for
> transcription over a secure WebSocket. Microsoft contractually
> commits that your audio and transcripts are never used to train AI
> models and are never shared with OpenAI or other parties. Audio is
> processed in real time and is NOT retained per Azure data privacy
> policy. The session is capped at 60 minutes — recordings longer
> than that will reconnect transparently. Data is processed in the
> Azure region associated with your resource (currently Global
> Standard, which may route through East US 2). For full details, see
> Microsoft's Azure OpenAI data privacy documentation at
> https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/data-privacy
> and the Microsoft Online Services DPA at https://aka.ms/DPA."

The per-provider acknowledgement key is
`com.local.macrec-ui.transcription.privacy.azure-openai-realtime.acknowledged`
— distinct from the batch Azure provider's key (the data-flow story
is materially different — streaming vs. file-upload — so the
disclosure must be re-acknowledged).

#### A2.10 Cost calculation

Per research §10, the realtime path uses the same per-minute pricing
as the batch path: **$0.003 / minute** for `gpt-4o-mini-transcribe`
(equivalently $0.18 / hour). Critically, the
`conversation.item.input_audio_transcription.completed` event does NOT
include a `usage` field for the transcription intent — usage only
appears in `response.done` events for conversational mode. The
provider calculates cost locally from the audio actively committed:

```swift
extension AzureOpenAIRealtimeSession {
    func currentEstimatedCostUSD() -> Double {
        let audioMinutes = Double(audioSamplesCommitted) / (24_000.0 * 60.0)
        return audioMinutes * 0.003   // gpt-4o-mini-transcribe per-minute rate
    }
}
```

`audioSamplesCommitted` is incremented when the session sees an
`input_audio_buffer.committed` event (so cost reflects what Azure
actually charges, not the raw audio queued). This value rides on the
existing `TranscriptionMetrics` channel via the
`StreamingProviderMetrics.lastFinalLatencyMs` companion path — the
exact wiring follows §07D-8 of project-design.md (one optional
`Double?` field on `TranscriptionMetrics` named `estimatedCostUSD`,
shared with Phase A1 and Phase B).

#### A2.11 Acceptance criteria for Phase A2

- **AC-A2-1**: `AzureOpenAIRealtimeTranscriptionProvider` declares
  `id = "azure-openai-realtime"`,
  `displayName = "Azure OpenAI Realtime"`,
  `supportedModes = [.streaming]`. Calling `transcribe(...)` throws
  `MacrecError.transcriptionConfigConflict(reason: "Azure realtime provider does not support batch mode; use 'azure' for batch.")`.
- **AC-A2-2**: `RealtimeWireTypes.SessionConfig` does NOT serialise
  the `model` field — verified by a Codable round-trip test that
  encodes a session-update payload and asserts the JSON does not
  contain the substring `"model"`.
- **AC-A2-3**: Audio is resampled from 16 kHz Float to 24 kHz Int16
  LE before each `input_audio_buffer.append` send — verified by a unit
  test that injects a known sine wave and asserts the resampler
  output's sample count matches the expected ratio (1.5×) and the
  RMS is within 1% of the input.
- **AC-A2-4**: Close code 1006 triggers reconnect with audio replay —
  verified by an integration test using a mock URL protocol that
  closes the WS abnormally after 3 s of audio, then asserts the
  reconnect happens within 1 s and the next 5 s of replayed audio is
  re-sent.
- **AC-A2-5**: Pre-emptive reconnect fires at 58 min — verified by a
  unit test that injects a fast-clock test seam (`Clock` abstraction)
  and asserts the reconnect path triggers exactly once at the 58-min
  boundary.
- **AC-A2-6**: First delta event arrives within 3 s of speech start
  in the e2e test — verified by `e2e-transcription-azure-realtime.sh`
  with a 30 s sample audio.
- **AC-A2-7**: WS handshake includes the `api-key` header — verified
  by a `URLProtocol` mock asserting the header is present and equals
  the resolved env-var value (no `Bearer` prefix).
- **AC-A2-8**: `transcription_session.update` is sent within 100 ms
  of `session.created` arriving (verified by a wall-clock assertion
  in the integration test).
- **AC-A2-9**: Session events are surfaced through the
  `AsyncStream<StreamingTranscriptionEvent>` channel — `.partial` for
  every delta, `.final` for every completed, `.error` for every error
  / failed event, `.metrics` snapshots at least once per minute.
- **AC-A2-10**: Missing required env (`AZURE_OPENAI_API_KEY`,
  `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT`) → factory
  throws `MacrecError.transcriptionApiKeyMissing(provider: "azure-openai-realtime")`
  (exit 78) or `MacrecError.transcriptionConfigConflict(...)` (exit 64).
- **AC-A2-11**: Invalid VAD env values (e.g.
  `AZURE_OPENAI_REALTIME_VAD_THRESHOLD=2.0` or `=foo`) throw
  `MacrecError.transcriptionConfigConflict(reason:)` at provider
  construction.
- **AC-A2-12**: `e2e-transcription-azure-realtime-model-field-bug.sh`
  passes — the wire JSON for `transcription_session.update` produced
  by the Codable does NOT contain the `model` key.
- **AC-A2-13**: Existing five non-realtime conformers (`NoOp`,
  `Fake`, `GeminiREST`, `AppleSpeech`, `WhisperKit`) plus the new
  `AzureOpenAITranscriptionProvider` (Phase A1) and
  `ElevenLabsTranscriptionProvider` (Phase B) still compile and pass
  their existing unit tests unchanged.

---

#### B.1 New types

| Type | File |
|---|---|
| `ElevenLabsTranscriptionProvider` | `Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsTranscriptionProvider.swift` |
| `ElevenLabsConfig`                | `Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsConfig.swift` |
| `ElevenLabsSTTError`              | `Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsSTTError.swift` |
| `ElevenLabsResponse`              | `Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsResponse.swift` |

#### B.2 `ElevenLabsConfig`

```swift
public struct ElevenLabsConfig: Sendable, Equatable {
    public let apiKey: String                         // ELEVENLABS_API_KEY (required)
    public let modelId: String                         // default "scribe_v2"
    public let languageCode: String?                   // optional ISO-639-1/-3, auto-detect when nil
    public let diarize: Bool                           // default false
    public let tagAudioEvents: Bool                    // default true
    public let numSpeakers: Int?                       // optional 1..32
    public let fileFormat: ElevenLabsFileFormat        // .pcm_s16le_16 (low-lat) or .other
    public let entityDetection: String?                // nil / "all" / "pii" / etc. — default nil (off)
    public let timestampsGranularity: String?          // "word" (default) | "character"
    public let apiKeyExpiresAt: Date?                  // optional; warning surface

    public enum ElevenLabsFileFormat: String, Sendable {
        case pcm_s16le_16 = "pcm_s16le_16"   // fast-path for 16 kHz mono Int16 WAV from AudioWAVEncoder
        case other = "other"                  // any other supported format (m4a, etc.)
    }
}
```

Construction validates:
- `apiKey` non-empty.
- `modelId ∈ {"scribe_v1", "scribe_v2"}` (warn-only on others).
- `numSpeakers` (if set) in 1..32 range; throw `transcriptionConfigConflict` otherwise.
- `entityDetection` values from research §3.6 enum.

Missing `ELEVENLABS_API_KEY` → caller already enforces (factory).

#### B.3 `ElevenLabsTranscriptionProvider`

```swift
public struct ElevenLabsTranscriptionProvider: TranscriptionProvider {
    public let id = "elevenlabs"
    public let displayName = "ElevenLabs Scribe v2"
    public let supportedModes: Set<TranscriptionMode> = [.batch]

    private let config: ElevenLabsConfig
    private let urlSession: URLSession
    private let logger = LoggerFactory.make("macrec.transcription.elevenlabs")
    private let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    public init(config: ElevenLabsConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        // 1. Encode audio (16 kHz mono Int16 WAV)
        let wavData = try AudioWAVEncoder.encode(samples: samples)

        // 2. Pre-flight checks (research §9.3)
        guard wavData.count <= 3 * 1024 * 1024 * 1024 else {  // 3 GB hard cap
            throw ElevenLabsSTTError.fileTooLarge
        }
        let durationSec = Double(samples.count) / 16_000.0
        guard durationSec >= 0.1 else {
            // < 100 ms → empty transcript, do not waste a request
            return ""
        }
        guard durationSec <= 4.5 * 3600 else {
            throw ElevenLabsSTTError.audioTooLong
        }

        // 3. Build multipart body (research §3 + §5)
        var multipart = MultipartFormDataBuilder()
        multipart.append(field: "model_id", value: config.modelId)
        multipart.append(field: "file_format", value: config.fileFormat.rawValue)
        multipart.append(field: "file", fileNamed: "audio.wav", mimeType: "audio/wav", data: wavData)
        if let lang = config.languageCode ?? options.languageHints.first.flatMap(stripBCP47Region) {
            multipart.append(field: "language_code", value: lang)
        }
        if config.diarize { multipart.append(field: "diarize", value: "true") }
        if let n = config.numSpeakers { multipart.append(field: "num_speakers", value: String(n)) }
        multipart.append(field: "tag_audio_events", value: String(config.tagAudioEvents))
        if let granularity = config.timestampsGranularity {
            multipart.append(field: "timestamps_granularity", value: granularity)
        }
        if let entityDet = config.entityDetection {
            multipart.append(field: "entity_detection", value: entityDet)
        }
        let (contentType, body) = multipart.build()

        // 4. Build URLRequest
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 120                // larger files take longer

        // 5. POST with retry loop (research §8 + concurrency rules §9.1)
        let (data, httpResponse) = try await postWithRetries(request: request, body: body)

        // 6. Log concurrency headers
        logResponseHeaders(httpResponse)

        // 7. Map HTTP status → ElevenLabsSTTError (research §7-§8)
        try mapStatusCode(httpResponse, body: data)

        // 8. Decode response
        let decoded = try JSONDecoder().decode(ElevenLabsResponse.self, from: data)
        return decoded.text
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw MacrecError.transcriptionConfigConflict(
            reason: "ElevenLabs provider does not support streaming in v1 (deferred to plan-007 — scribe_v2_realtime). Use --transcribe apple for streaming."
        )
    }
}
```

The retry policy: 3 attempts max, exponential backoff with ±20% jitter
starting at 1 s and capped at 32 s (research §8 footnote — ElevenLabs
does NOT return `Retry-After`). Retry only on 429 (`rate_limit_exceeded`,
`system_busy`), 500, 503. Do NOT retry on 429 with
`detail.status == "concurrent_limit_exceeded"` — surface directly so
the user sees the concurrency cap.

#### B.4 `ElevenLabsSTTError`

Per research §8:

```swift
enum ElevenLabsSTTError: Error, Sendable {
    case invalidApiKey                              // 401
    case insufficientCredits                        // 402
    case planFeatureGate(feature: String)           // 403
    case fileTooLarge                               // 413 (> 3 GB)
    case audioTooLong                               // 422 audio_too_long (> 4.5 hr)
    case audioTooShort                              // 400 audio_too_short (< 100 ms)
    case unsupportedFormat                          // 400/422 invalid_audio_format / invalid_file_type
    case invalidParameter(field: String, message: String)  // 422 invalid_parameters
    case rateLimited(retryAfterSec: Double?)        // 429 rate_limit_exceeded
    case concurrentLimitExceeded                    // 429 concurrent_limit_exceeded (surface immediately)
    case serverError(code: Int)                     // 500/503
    case networkFailure(underlying: Error)          // URLError
    case decodingFailure(underlying: Error)         // JSONDecoder errors
}
```

Mapping to `MacrecError`:

| `ElevenLabsSTTError` | `MacrecError` |
|---|---|
| `.invalidApiKey`             | `.transcriptionApiKeyMissing(provider: "elevenlabs")` (exit 78)   |
| `.insufficientCredits`       | `.transcriptionProviderUnavailable(reason: "ElevenLabs account out of credits …")` (exit 70) |
| `.planFeatureGate(feature)`  | `.transcriptionProviderUnavailable(reason: "ElevenLabs '\(feature)' requires plan upgrade")` (exit 70) |
| `.fileTooLarge`              | `.transcriptionProviderUnavailable(reason: "Audio chunk exceeds ElevenLabs 3 GB limit")` (exit 70) |
| `.audioTooLong`              | `.transcriptionProviderUnavailable(reason: "Audio exceeds ElevenLabs 4.5 hr limit per request")` (exit 70) |
| `.audioTooShort`             | (caller handled via early return; never raised as an error)        |
| `.unsupportedFormat`         | `.transcriptionProviderUnavailable(reason: "Audio format not accepted by ElevenLabs (CAF must be converted to WAV/M4A first)")` (exit 70) |
| `.invalidParameter(f,m)`     | `.transcriptionConfigConflict(reason: "ElevenLabs rejected '\(f)': \(m)")` (exit 64) |
| `.rateLimited(retryAfter)`   | `.transcriptionProviderUnavailable(reason: "ElevenLabs rate-limited; backoff exhausted")` (exit 70) |
| `.concurrentLimitExceeded`   | `.transcriptionProviderUnavailable(reason: "ElevenLabs concurrent-request limit reached on your plan; reduce concurrency or upgrade")` (exit 70) |
| `.serverError(code)`         | `.transcriptionProviderUnavailable(reason: "ElevenLabs server error \(code); transient")` (exit 70) |
| `.networkFailure(err)`       | `.transcriptionProviderUnavailable(reason: "ElevenLabs unreachable: \(err.localizedDescription)")` (exit 70) |
| `.decodingFailure(err)`      | `.transcriptionProviderUnavailable(reason: "ElevenLabs response malformed: \(err)")` (exit 70) |

#### B.5 `ElevenLabsResponse`

Per research §6.1, the synchronous (non-webhook, non-multi-channel) response:

```swift
struct ElevenLabsResponse: Decodable, Sendable {
    let languageCode: String          // BCP-47-ish (e.g. "en", "el")
    let languageProbability: Double   // 0..1
    let text: String
    let words: [Word]?

    struct Word: Decodable, Sendable {
        let text: String
        let start: Double
        let end: Double
        let type: String              // "word" | "spacing" | "audio_event"
        let speakerId: String?        // present when diarize=true

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
```

The `entities` array (research §3.6) is only present when
`entity_detection` is set; v1 does not request it (off by default per
§13 EL-2), so the decoder ignores it. Multi-channel response
(`MultichannelSpeechToTextResponseModel`) is not handled — `use_multi_channel`
is not requested.

#### B.6 Factory wiring

Add another `case` branch to `TranscriptionProviderFactory.build(_:)`:

```swift
case "elevenlabs":
    guard let key = input.apiKey, !key.isEmpty else {
        throw MacrecError.transcriptionApiKeyMissing(provider: "elevenlabs")
    }
    let config = ElevenLabsConfig(
        apiKey: key,
        modelId: input.elevenLabsModelId ?? "scribe_v2",
        languageCode: input.elevenLabsLanguageCode,
        diarize: input.elevenLabsDiarize ?? false,
        tagAudioEvents: input.elevenLabsTagAudioEvents ?? true,
        numSpeakers: input.elevenLabsNumSpeakers,
        fileFormat: input.elevenLabsFileFormat ?? .pcm_s16le_16,    // see §13 EL-3
        entityDetection: input.elevenLabsEntityDetection,           // nil = off; see §13 EL-2
        timestampsGranularity: nil,                                 // v1 does not request word ts beyond the default
        apiKeyExpiresAt: input.keyExpiresAt
    )
    return ElevenLabsTranscriptionProvider(config: config)
```

(`TranscriptionProviderFactoryInput` gains the matching optional fields
in §B.7.)

#### B.7 `ConfigResolver` + `RecordingOptions` extensions

`ConfigResolver` adds resolution of the eight optional ElevenLabs env
vars (per §5.1) and threads them into new optional fields on
`RecordingOptions`:

- `elevenLabsModelId: String?`
- `elevenLabsLanguageCode: String?`
- `elevenLabsDiarize: Bool?`
- `elevenLabsTagAudioEvents: Bool?`
- `elevenLabsNumSpeakers: Int?`
- `elevenLabsFileFormat: ElevenLabsConfig.ElevenLabsFileFormat?`
- `elevenLabsEntityDetection: String?`
- `elevenLabsApiKeyExpiresAt: Date?`

`RecordingOptions.init(...)` defaults them all to `nil`.
`RecordingOptions.withOutput(_:)` forwards each. The existing
`testWithOutputPreservesTranscriptionFields` regression test (codebase
scan §IP-7) gains assertions for every new field.

#### B.8 CLI flag wiring

In `StartCommand.swift` lines 88-112, `--transcribe`'s help text now
lists `elevenlabs` (already updated in Phase A.8). No new
ElevenLabs-specific flags — all configuration via env vars.

#### B.9 Cost calculation (per investigation §Cost-summary)

```swift
extension TranscriptionManagerStats {
    static func elevenLabsCost(audioSecondsBilled: Double, config: ElevenLabsConfig) -> Double {
        let baseRate = (config.modelId == "scribe_v1") ? 0.22 : 0.22   // both batch tiers $0.22/hr
        var hours = audioSecondsBilled / 3600.0
        var cost = hours * baseRate
        if config.entityDetection != nil { cost *= 1.30 }              // +30%
        // Note: keyterms (+20%) and detect_speaker_roles (+10%) deferred — v1 does not expose them
        return cost
    }
}
```

#### B.10 Phase B acceptance criteria

- AC-B-1: `ElevenLabsTranscriptionProvider` declares `id = "elevenlabs"`,
  `displayName = "ElevenLabs Scribe v2"`, `supportedModes = [.batch]`.
- AC-B-2: `transcribe(...)` POSTs to `https://api.elevenlabs.io/v1/speech-to-text`
  with `xi-api-key` header (verified by mock-URLProtocol test).
- AC-B-3: Missing `ELEVENLABS_API_KEY` → `MacrecError.transcriptionApiKeyMissing(provider: "elevenlabs")` exit 78.
- AC-B-4: HTTP 413 (request too large) → `transcriptionProviderUnavailable`
  with the 3 GB message.
- AC-B-5: HTTP 422 with `audio_too_long` → `transcriptionProviderUnavailable`
  with the 4.5 hr message.
- AC-B-6: HTTP 429 with `concurrent_limit_exceeded` surfaces
  immediately (no retry); `rate_limit_exceeded` is retried with
  exponential backoff up to 3 attempts.
- AC-B-7: Sub-100 ms audio chunks short-circuit to empty string (no
  network call).
- AC-B-8: `openStreamingSession(...)` throws `transcriptionConfigConflict`
  pointing to plan-007.
- AC-B-9: Existing conformers still compile and pass their unit tests
  unchanged.
- AC-B-10: `e2e-transcription-elevenlabs.sh` (Phase E) passes against
  a real ElevenLabs key.

---

### Phase C — UI integration (depends on Phase A1, Phase A2, and Phase B)

Wire the two new providers through the menu-bar UI. Specific files
(per the codebase scan):

#### C.1 Provider picker

- **File**: `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift`
  lines 72-77.
- **Change**: Insert two new entries in declaration order (per
  Assumption A-4 — flat list; see §13 Open Decision UI-1):

  ```swift
  Picker(String(localized: "Transcribe"), selection: $providerRaw) {
      Text("Apple Speech (on-device)").tag("apple")
      Text("WhisperKit (on-device, multilingual)").tag("whisperkit")
      Text("Gemini (cloud)").tag("gemini")
      Text("Azure OpenAI (cloud, batch)").tag("azure")                            // NEW (A1)
      Text("Azure OpenAI Realtime (cloud, streaming)").tag("azure-openai-realtime") // NEW (A2)
      Text("ElevenLabs Scribe v2 (cloud)").tag("elevenlabs")                      // NEW (B)
      Text("None").tag("none")
  }
  ```

- The `missingKeyTooltip` (line 68) becomes a computed property keyed
  off the current selection (already changed by Phase 0.4 generalising
  the key field; the tooltip change is a one-line follow-up).
- **VAD config exposure (deferred)**: Phase A2's four optional VAD
  env vars (`AZURE_OPENAI_REALTIME_VAD_THRESHOLD`,
  `…_VAD_PREFIX_PADDING_MS`, `…_VAD_SILENCE_MS`,
  `AZURE_OPENAI_REALTIME_NOISE_REDUCTION`) are NOT surfaced in the
  popover for v1 — env-var configuration only, matching all other
  cloud-provider tuning. UI exposure deferred to plan-007 if user
  feedback warrants it.

#### C.2 Inline key-entry section

- **File**: `Sources/macrec-ui/RootView.swift` (the disclosure group
  rendering the per-provider key field).
- **Change**: Add two `ProviderKeyField` invocations (component
  introduced in Phase 0.4):

  ```swift
  if transcribeProviderRaw == "azure" || transcribeProviderRaw == "azure-openai-realtime" {
      ProviderKeyField(
          providerId: transcribeProviderRaw,
          envVarName: "AZURE_OPENAI_API_KEY",
          displayLabel: "Azure OpenAI API key",
          helpURL: URL(string: "https://learn.microsoft.com/en-us/azure/ai-services/openai/")
      )
      // Also render small inline labels for endpoint + deployment current values (read-only)
      Text("Endpoint: \(ProcessInfo.processInfo.environment["AZURE_OPENAI_ENDPOINT"] ?? "(not set)")")
      Text("Deployment: \(ProcessInfo.processInfo.environment["AZURE_OPENAI_DEPLOYMENT"] ?? "(not set)")")
      Text("API version: \(ProcessInfo.processInfo.environment["AZURE_OPENAI_API_VERSION"] ?? "2025-04-01-preview (default)")")
      // Realtime-only: show the resolved VAD config so the user can sanity-check it
      if transcribeProviderRaw == "azure-openai-realtime" {
          Text("VAD threshold: \(ProcessInfo.processInfo.environment["AZURE_OPENAI_REALTIME_VAD_THRESHOLD"] ?? "0.5 (default)")")
          Text("VAD silence (ms): \(ProcessInfo.processInfo.environment["AZURE_OPENAI_REALTIME_VAD_SILENCE_MS"] ?? "200 (default)")")
          Text("Noise reduction: \(ProcessInfo.processInfo.environment["AZURE_OPENAI_REALTIME_NOISE_REDUCTION"] ?? "near_field (default)")")
      }
  } else if transcribeProviderRaw == "elevenlabs" {
      ProviderKeyField(
          providerId: "elevenlabs",
          envVarName: "ELEVENLABS_API_KEY",
          displayLabel: "ElevenLabs API key",
          helpURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")
      )
  }
  ```

#### C.3 Privacy-disclosure trigger

- **File**: `Sources/macrec-ui/RootView.swift` lines 316-323
  (`isCloudProvider`).
- **Change**:

  ```swift
  private static func isCloudProvider(_ raw: String) -> Bool {
      switch raw.lowercased() {
      case "gemini", "gemini-live", "azure", "azure-openai-realtime", "elevenlabs":
          return true
      default:
          return false
      }
  }
  ```

- Per Phase 0.3, the disclosure sheet's body text is now
  provider-aware, and the "acknowledged" boolean is per-provider.
  Selecting Azure for the first time after Gemini was already
  acknowledged WILL re-show the dialog (with Azure-specific copy) —
  this is desired because the data-residency story differs.
- Phase A2 introduces a separate "azure-openai-realtime" disclosure
  variant (see §A2.9) — selecting it after the batch Azure entry was
  already acknowledged WILL re-show the disclosure (real-time
  streaming carries a different data-flow story than file upload).

#### C.4 Inline transcript panel (no change)

`Sources/macrec-ui/Views/LiveTranscriptPanel.swift` consumes
`TranscriptSegment` events and is provider-agnostic — no change
required.

#### C.5 Recording controller's `transcriptionMissingKey`

- **File**: `Sources/MacrecUIKit/RecordingController.swift` lines 129-131.
- **Change**: The `transcriptionMissingKey: Bool` property is set in
  `setOptions(_:)` based on whether `options.transcriptionApiKey == nil`
  while a cloud provider is active. The existing logic works unchanged
  for Azure and ElevenLabs because both populate `transcriptionApiKey`
  through the same env-chain.
- The static `missingKeyTooltip` string (per scan §IP-19) becomes
  provider-aware via the same approach as Phase C.1's `TranscriptionPicker`.

#### C.6 Phase C acceptance criteria

- AC-C-1: Selecting "Azure OpenAI (cloud, batch)" in the picker shows
  the Azure-batch-specific privacy-disclosure copy on first-use.
- AC-C-2: Selecting "ElevenLabs Scribe v2 (cloud)" shows the
  ElevenLabs-specific privacy-disclosure copy on first-use.
- AC-C-3: Each provider has its own "acknowledged" persistence key;
  acknowledging one does not silence the other (this includes the
  separate `azure` vs `azure-openai-realtime` keys per A2.9).
- AC-C-4: `ProviderKeyField` renders for Azure (batch + realtime) and
  ElevenLabs with the correct env-var name, label, and help URL.
- AC-C-5: Missing-key red-dot badge appears when the active provider
  is Azure (batch or realtime) or ElevenLabs and the relevant key env
  var is unset.
- AC-C-6: Selecting "Azure OpenAI Realtime (cloud, streaming)" shows
  the realtime-specific privacy-disclosure copy on first-use, even
  if "Azure OpenAI (cloud, batch)" was already acknowledged.
- AC-C-7: When the active provider is "azure-openai-realtime", the
  inline key-entry section additionally shows the resolved VAD
  threshold, silence ms, and noise-reduction values (read-only).

---

### Phase D — Configuration & docs (depends on Phase A1, A2, B, C)

#### D.1 `docs/design/configuration-guide.md` — new sections §LT-Az, §LT-Az-RT, and §LT-EL

Append three new configuration sections following the format used by
the Gemini section:

- **§LT-Az — Azure OpenAI configuration variables (batch path,
  Phase A1)**: one row per env var in §5.1's Azure block. Per the
  existing §LT format:
  - **Purpose**: what the variable does.
  - **How to obtain**: Azure portal → Resource → Keys & Endpoint;
    Foundry portal → Models + endpoints for the deployment name.
  - **Recommended storage**: `~/.tool-agents/macrec-ui/.env` (mode 0600).
  - **Options / values**: any enum or format constraint.
  - **Default**: "(none — required)" for required vars; explicit value
    for `AZURE_OPENAI_API_VERSION` (`2025-04-01-preview` — see Phase A2
    note: bumped from `2025-03-01-preview` because it covers both batch
    AND realtime).
  - **Expiration tracking**: `AZURE_OPENAI_API_KEY_EXPIRES_AT` companion
    documented per CLAUDE.md rule.
- **§LT-Az-RT — Azure OpenAI Realtime configuration variables (Phase A2)**:
  one row per realtime-only env var (see §A2.4):
  - `AZURE_OPENAI_REALTIME_VAD_THRESHOLD` (default 0.5)
  - `AZURE_OPENAI_REALTIME_VAD_PREFIX_PADDING_MS` (default 300)
  - `AZURE_OPENAI_REALTIME_VAD_SILENCE_MS` (default 200)
  - `AZURE_OPENAI_REALTIME_NOISE_REDUCTION` (`near_field` | `far_field`
    | `none`, default `near_field`)
  - `AZURE_OPENAI_REALTIME_INCLUDE_LOGPROBS` (default `false`)
  - `AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL` (default `false` per
    OQ-A2-2)
  - All five reused vars (`AZURE_OPENAI_ENDPOINT`, `…_DEPLOYMENT`,
    `…_API_KEY`, `…_API_VERSION`, `…_API_KEY_EXPIRES_AT`) are
    cross-referenced to §LT-Az.
  - Note the **60-min session cap** and the pre-emptive 58-min reconnect
    behavior so users understand long recordings transparently
    transition.
  - Note the **24 kHz PCM16 audio framing** for diagnostic clarity
    (engineer-readable; not a user-tunable knob).
- **§LT-EL — ElevenLabs configuration variables (Phase B)**: one row per
  env var in §5.1's ElevenLabs block, same format. Document:
  - The `entity_detection` +30% surcharge and that v1 keeps it OFF by
    default (§13 EL-2).
  - The `pcm_s16le_16` low-latency fast-path enablement (§13 EL-3).
  - Where to obtain the key (`https://elevenlabs.io/app/settings/api-keys`).
  - Concurrency caps per plan tier (research §9.2 table).

#### D.2 `docs/tools/macrec.md` — update CLI doc

- Update the `--transcribe` flag enumeration to include `azure`,
  `azure-openai-realtime`, and `elevenlabs`.
- Add a per-provider section listing the required env vars (no `--transcribe-key`
  flag exists; users must configure via env / `.env`).
- Document the cost-line format for the post-stop summary (per §A.9 / §A2.10 / §B.9).
- For `azure-openai-realtime`, document:
  - the new VAD env vars,
  - the 60-min session cap and 58-min pre-emptive reconnect behavior,
  - the user-visible reconnect indicator on close 1006,
  - that recording continues even when transcription transiently fails.

#### D.3 `docs/tools/macrec-ui.md` — update menu-bar app doc

- Update the provider picker section to list "Azure OpenAI (cloud, batch)",
  "Azure OpenAI Realtime (cloud, streaming)", and "ElevenLabs Scribe v2".
- Document the new privacy-disclosure copy for each provider (three
  variants — `azure`, `azure-openai-realtime`, `elevenlabs`).
- Document the new `ProviderKeyField` UI affordance.
- Document the inline display of resolved VAD config (read-only) when
  the active provider is `azure-openai-realtime`.

#### D.4 `Issues - Pending Items.md`

- Add four resolved items (one per Phase 0 anomaly fixed).
- Add new pending items for any open decisions deferred from §13.

#### D.5 Phase D acceptance criteria

- AC-D-1: `configuration-guide.md` contains §LT-Az with all five Azure
  batch env vars documented.
- AC-D-2: `configuration-guide.md` contains §LT-Az-RT with all six
  realtime-only env vars documented (plus cross-references to the
  five reused vars in §LT-Az).
- AC-D-3: `configuration-guide.md` contains §LT-EL with all eight
  ElevenLabs env vars documented.
- AC-D-4: `docs/tools/macrec.md` lists `azure`, `azure-openai-realtime`,
  and `elevenlabs` as valid `--transcribe` values.
- AC-D-5: `docs/tools/macrec-ui.md` documents the three new picker
  entries and the three disclosure-sheet copy variants.

---

### Phase E — Tests (depends on Phase A1, A2, B, C, D)

Per Issues - Pending Items.md R-17/R-22 (no local test runner), the
shell scripts under `test_scripts/` are integration scripts that
require real credentials. The XCTest unit tests can be run locally
with `swift test --filter <name>` once a runner is available; in the
interim they validate by inspection.

#### E.1 New shell scripts under `test_scripts/`

| Script | Purpose | Inputs | Required env | Pass criteria |
|---|---|---|---|---|
| `test_scripts/e2e-transcription-azure.sh` | Happy-path Azure batch transcription. | `samples/short_speech.m4a` (5–10 s of speech); `--transcribe azure --transcribe-source mixed`. | `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT` (deployment must serve `gpt-4o-mini-transcribe`). | `*.transcript.jsonl` exists; the JSONL contains at least one segment with `text` non-empty; exit 0. |
| `test_scripts/e2e-transcription-elevenlabs.sh` | Happy-path ElevenLabs batch transcription. | `samples/short_speech.m4a`; `--transcribe elevenlabs`. | `ELEVENLABS_API_KEY`. | `*.transcript.jsonl` exists; at least one segment with non-empty `text`; exit 0. |
| `test_scripts/e2e-transcription-azure-key-missing.sh` | Verify error exit when key is unset. | Same audio; `--transcribe azure`. | (intentionally unset) `unset AZURE_OPENAI_API_KEY` first. | Exit 78; stderr contains `"AZURE_OPENAI_API_KEY"`. |
| `test_scripts/e2e-transcription-elevenlabs-key-missing.sh` | Same as above for ElevenLabs. | Same audio; `--transcribe elevenlabs`. | `unset ELEVENLABS_API_KEY`. | Exit 78; stderr contains `"ELEVENLABS_API_KEY"`. |
| `test_scripts/e2e-transcription-azure-deployment-not-found.sh` | Verify 404 error mapping. | Same audio; `--transcribe azure`. | Real `AZURE_OPENAI_API_KEY` + `AZURE_OPENAI_ENDPOINT` + a deliberately bad `AZURE_OPENAI_DEPLOYMENT=does-not-exist-xyz`. | Exit 64; stderr contains `"deployment 'does-not-exist-xyz' not found"`. |
| `test_scripts/e2e-transcription-elevenlabs-413-too-large.sh` | Verify 413 error mapping. | A 4 GB filler audio file (or simulate via mock). | Real `ELEVENLABS_API_KEY`. | Exit 70; stderr contains `"3 GB limit"`. (Note: this script is expensive to run against real ElevenLabs; consider gating with a `MACREC_RUN_EXPENSIVE_TESTS=1` opt-in.) |
| `test_scripts/e2e-transcription-azure-realtime.sh` | Happy-path Phase A2 streaming transcription, 30 s sample. | `samples/short_speech.m4a` (≥ 30 s of speech); `--transcribe azure-openai-realtime --transcribe-source mixed`. | `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT` (deployment must serve `gpt-4o-mini-transcribe` realtime in `2025-04-01-preview`). | `*.transcript.jsonl` exists; the JSONL contains at least ONE `partial` segment AND at least ONE `final` segment; first `partial` arrives within 3 s of first speech sample (asserted via timestamp diff in JSONL); exit 0. |
| `test_scripts/e2e-transcription-azure-realtime-reconnect.sh` | Verify the close-1006 reconnect-with-replay path. Uses a kill-switch in the provider when `MACREC_REALTIME_TEST_FORCE_DISCONNECT_S` env var is set. | `samples/short_speech.m4a` (15 s); `--transcribe azure-openai-realtime`; `MACREC_REALTIME_TEST_FORCE_DISCONNECT_S=5` (forces a fake 1006 close at 5 s). | Same as happy-path. | JSONL contains at least one `final` segment whose audio range straddles the 5 s disconnect mark; sidecar `*.transcript.jsonl` does NOT contain duplicate text from the 5 s replay window (dedupe asserted); exit 0. |
| `test_scripts/e2e-transcription-azure-realtime-long.sh` | Verify the 58-min pre-emptive reconnect for the 60-min cap. **Manual / opt-in only — not in CI.** | A 65 min stitched audio sample; `--transcribe azure-openai-realtime`; `MACREC_RUN_EXPENSIVE_TESTS=1`. | Same as happy-path. | JSONL covers the full 65 min; the provider log contains exactly one "pre-emptive reconnect at 58:00" entry; no audio gap > 1 s in the JSONL timeline; exit 0. |
| `test_scripts/e2e-transcription-azure-realtime-model-field-bug.sh` | Wire-format sanity check — encodes a `transcription_session.update` Codable and asserts the JSON does NOT contain the substring `"model"`. Pure local test; no Azure call needed. | Generated in-memory; no audio sample. | (none) | Exit 0; stdout contains `"OK: model field omitted"`. |
| `test_scripts/e2e-transcription-azure-realtime-key-missing.sh` | Verify error exit when key is unset for the realtime provider. | `samples/short_speech.m4a`; `--transcribe azure-openai-realtime`. | `unset AZURE_OPENAI_API_KEY` first. | Exit 78; stderr contains `"AZURE_OPENAI_API_KEY"`. |

Each script is a thin Bash wrapper that invokes the released `macrec`
binary with the appropriate flags, checks exit codes, and `grep`s
stderr / sidecar files. Body templates are not part of this plan; the
plan-005 `e2e-transcription-apple.sh` style is the model.

#### E.2 New XCTest unit test files under `Tests/MacrecCoreTests/Transcription/Providers/`

| Test file | Coverage |
|---|---|
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/AzureOpenAIConfigTests.swift` | Construction validation: endpoint/deployment/apiVersion shape; throws on missing required field; warns (does not throw) on suspicious endpoint. |
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/AzureOpenAITranscriptionProviderTests.swift` | URL construction (path + query); `api-key` header (no "Bearer" prefix); `model` form field equals deployment name; `response_format=json`; `language` form field stripped of BCP-47 region. Mocks `URLSession` with `URLProtocol`. |
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/AzureOpenAIErrorMappingTests.swift` | Per row of §A.4 error table: feed a mock `HTTPURLResponse` + body, assert the `MacrecError` case + exit code. Both error envelope formats (API + APIM). |
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/AzureOpenAIRetryTests.swift` | 429 with `Retry-After: 5` retried after 5 s; 500 retried with backoff; 401 NOT retried; max 3 attempts; jitter respected within ±20%. |
| `Tests/MacrecCoreTests/Transcription/Providers/ElevenLabs/ElevenLabsConfigTests.swift` | Construction validation: `numSpeakers` in 1..32; `modelId` enum check; `entityDetection` enum check. |
| `Tests/MacrecCoreTests/Transcription/Providers/ElevenLabs/ElevenLabsTranscriptionProviderTests.swift` | URL construction; `xi-api-key` header; multipart body field set; `file_format=pcm_s16le_16` set when `AudioWAVEncoder` output detected; sub-100 ms audio short-circuits to empty string. |
| `Tests/MacrecCoreTests/Transcription/Providers/ElevenLabs/ElevenLabsErrorMappingTests.swift` | Per row of §B.4 error table: assert the `MacrecError` case + exit code; `concurrent_limit_exceeded` surfaces immediately (no retry); 422 `audio_too_long` mapped to the right error. |
| `Tests/MacrecCoreTests/Transcription/Providers/ElevenLabs/ElevenLabsResponseDecodingTests.swift` | Decode happy-path response with diarization; decode without diarization; ignore unknown fields; decode multi-channel response is NOT supported (decoder either succeeds with `text=""` or throws — pick the safer behavior in the impl). |
| `Tests/MacrecCoreTests/Transcription/Net/MultipartFormDataBuilderTests.swift` | Per Phase 0.5 acceptance. |
| `Tests/MacrecCoreTests/Config/ConfigResolverAzureElevenLabsTests.swift` | `ConfigResolver.resolve(...)` reads each new env var per the four-tier chain; missing required → throws at factory build time; expiry warning fires when `*_API_KEY_EXPIRES_AT` is < 7 days away. |
| `Tests/MacrecCoreTests/Config/RecordingOptionsAzureElevenLabsTests.swift` | `withOutput(_:)` preserves all new fields. |
| `Tests/MacrecUIKitTests/PrivacyDisclosureSheetCopyTests.swift` | Per Phase 0.3 acceptance. |
| `Tests/MacrecUIKitTests/ControlBarKeyResolutionTests.swift` | Per Phase 0.2 acceptance. |
| `Tests/MacrecUIKitTests/ProviderKeyFieldTests.swift` | Per Phase 0.4 acceptance. |
| `Tests/MacrecCoreTests/Transcription/TranscriptionProviderFactoryAzureElevenLabsTests.swift` | Each new factory branch returns the right provider type; missing `apiKey` → `transcriptionApiKeyMissing`; missing `endpoint` / `deployment` → `transcriptionConfigConflict`; default `apiVersion` resolves to `2025-04-01-preview` (bumped per Phase A2). |
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeConfigTests.swift` | Construction validation: VAD threshold range; VAD ms ≥ 0; noise-reduction enum; deploymentInUrl bool parse; throws `transcriptionConfigConflict` on invalid values. |
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeProviderTests.swift` | Provider id, displayName, supportedModes; `transcribe(...)` throws `transcriptionConfigConflict`; `openStreamingSession(...)` returns a `AzureOpenAIRealtimeSession`. |
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/Realtime/RealtimeWireTypesTests.swift` | Codable round-trip for every event in §A2.5; **assert `transcription_session.update` JSON does NOT contain the substring `"model"`** (RT-1 regression test); decoder dispatches by `type` discriminator across all server-event variants. |
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSessionTests.swift` | URL composition (with and without `&deployment=`); `api-key` header set on the upgrade request; `session.created` triggers `transcription_session.update` send within 100 ms; delta events surface as `.partial` on `events`; completed events surface as `.final`; failed events surface as `.error`. Uses `URLProtocol`-mocked WS or an in-process echo server. |
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeReconnectTests.swift` | Close 1006 triggers reconnect-with-replay (asserts the ring buffer's last 5 s is replayed); close 1008 surfaces immediately with no retry; reconnect attempt 3 failing surfaces `.reconnectExhausted`; pre-emptive 58-min reconnect fires once at the boundary (uses an injected `Clock` test seam). |
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/Realtime/AudioResampler16to24Tests.swift` | 16 kHz Float input of N samples produces 24 kHz Int16 output of `N * 1.5` samples (within ±1 sample); RMS preserved within 1%; sine-wave aliasing under threshold. |
| `Tests/MacrecCoreTests/Transcription/Providers/Azure/Realtime/AudioRingBufferTests.swift` | Generic `AudioRingBuffer<Int16>` of capacity 120,000 (5 s @ 24 kHz) preserves last 120,000 samples after 200,000 writes; `drain()` returns in original chronological order; concurrent reads/writes are serialised by the actor. |
| `Tests/MacrecCoreTests/Config/ConfigResolverAzureRealtimeTests.swift` | `ConfigResolver.resolve(...)` reads each new realtime env var per the four-tier chain; invalid VAD values throw `transcriptionConfigConflict`; default values used only when env unset. |

#### E.3 Phase E acceptance criteria

- AC-E-1: All XCTest files compile.
- AC-E-2: `swift test --filter Azure` passes locally with mock `URLSession` (covers Phase A1 + A2).
- AC-E-3: `swift test --filter AzureOpenAIRealtime` passes locally (covers all eight new realtime test files).
- AC-E-4: `swift test --filter RealtimeWireTypesTests` specifically asserts the model field is OMITTED from the encoded `transcription_session.update`.
- AC-E-5: `swift test --filter ElevenLabs` passes locally with mock `URLSession`.
- AC-E-6: All eleven shell scripts exist with executable bit set (six original + five new realtime scripts).
- AC-E-7: Manual sign-off note added to `Issues - Pending Items.md`
  recording the human verification of the integration scripts (per
  R-17/R-22 caveat from plan-005).

---

## 7. Privacy-disclosure copy

### 7.1 Azure OpenAI — Phase 0.3 + Phase C.3 copy

> "Audio will be sent to Microsoft Azure OpenAI Service for
> transcription. Microsoft contractually commits that your audio and
> transcripts are never used to train AI models and are never shared
> with OpenAI or other parties. Data is processed in the Azure region
> associated with your resource (currently Global Standard, which may
> route through East US 2). A Data Processing Agreement covers this
> transfer. For full details, see Microsoft's Azure OpenAI data privacy
> documentation at https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/data-privacy
> and the Microsoft Online Services DPA at https://aka.ms/DPA."

(Source: research §13.)

### 7.2 ElevenLabs Scribe v2 — Phase 0.3 + Phase C.3 copy

> "Audio will be sent to ElevenLabs (US-based, SOC 2 Type II certified,
> ISO 27001, GDPR-compliant). By default ElevenLabs retains audio and
> transcripts for service operation; Enterprise customers can enable
> Zero Retention mode (`enable_logging=false`). Audio is not used to
> train models without explicit opt-in. EU data residency is available
> on Enterprise tier through account settings. For full details, see
> ElevenLabs' privacy policy at https://elevenlabs.io/privacy and the
> Data Processing Addendum at https://elevenlabs.io/dpa."

(Source: research §11 + §13.)

---

## 8. Error-handling matrix

### 8.1 Azure OpenAI (per research §8 + §A.4)

| HTTP | `error.code` (or APIM `statusCode`) | `AzureOpenAISTTError` | `MacrecError` (exit) | User-facing message | Recovery |
|---|---|---|---|---|---|
| 400 | `invalid_request_error`, `invalid_value`, `invalid_audio` | `.invalidRequest(msg)` | `.transcriptionProviderUnavailable` (70) | "Azure rejected request: {msg}" | Surface to user; no retry. |
| 400 / 413 | `file_too_large` | `.fileTooLarge` | `.transcriptionProviderUnavailable` (70) | "Audio chunk exceeds Azure's 25 MB limit (chunk longer than ~25 min)" | Reduce chunk size; abort current request. |
| 400 / 415 | `unsupported_format` | `.unsupportedAudioFormat` | `.transcriptionProviderUnavailable` (70) | "Audio format not accepted by Azure (CAF must be converted to WAV/M4A first)" | Pre-flight: never send CAF. |
| 401 | `invalid_api_key` / `Unauthorized` | `.invalidApiKey` | `.transcriptionApiKeyMissing(provider: "azure")` (78) | "Azure API key invalid or expired; check `AZURE_OPENAI_API_KEY`" | Surface to user; abort. |
| 403 | `PermissionDenied` / VNet block | `.permissionDenied` | `.transcriptionPermissionDenied(provider: "azure")` (77) | "Azure access denied; check RBAC role or network policy" | Surface; abort. |
| 404 | `DeploymentNotFound` | `.deploymentNotFound` | `.transcriptionConfigConflict(reason)` (64) | "Azure deployment '{name}' not found in resource '{host}'" | Verify deployment name + region; abort. |
| 408 | (timeout) | `.networkTimeout` | `.transcriptionProviderUnavailable` (70) | "Azure read timeout; transient" | Retry with backoff (max 3). |
| 429 | `rate_limit_exceeded` | `.rateLimited(retryAfter)` | `.transcriptionProviderUnavailable` (70) | "Azure rate-limited; backoff exhausted" | Honour `Retry-After`; retry up to 3; surface on exhaustion. |
| 500 / 503 | `server_error` / `service_unavailable` | `.serverError(code)` | `.transcriptionProviderUnavailable` (70) | "Azure server error {code}; transient" | Retry with backoff (max 3). |
| (URLError) | offline / DNS | `.networkError(err)` | `.transcriptionProviderUnavailable` (70) | "Azure unreachable: {description}" | Retry once; surface on failure. |

### 8.1.RT Azure OpenAI Realtime additions (Phase A2 — per realtime research §5 + §10 + §A2.6)

| Source | Condition | `AzureOpenAIRealtimeError` | `MacrecError` (exit) | User-facing message | Recovery |
|---|---|---|---|---|---|
| WS upgrade HTTP 401 | Auth header rejected | `.unauthorizedUpgrade` | `.transcriptionApiKeyMissing(provider:"azure-openai-realtime")` (78) | "Azure realtime API key invalid or expired; check `AZURE_OPENAI_API_KEY`" | Surface; do not retry. |
| WS close 1000 | Normal closure (session expired cleanly at 60 min) | (not an error) | — | (silent — pre-emptive 58-min reconnect should make this rare) | If `userInitiatedClose == false` and `age >= 58 min`, treat as RT-4 and reconnect. |
| WS close 1001 | Server going away | `.abnormalClose(1001)` | `.transcriptionProviderUnavailable` (70) | "Azure realtime: server going away; reconnecting…" | Trigger reconnect-with-replay (§A2.7). |
| WS close 1006 (RT-3) | Abnormal closure, no close frame (most common) | `.abnormalClose(1006)` | `.transcriptionProviderUnavailable` (70) | "Azure realtime: connection lost; reconnecting…" | Reconnect-with-replay (§A2.7); cap at 3 attempts. |
| WS close 1008 | Auth policy violation (rare post-upgrade) | `.policyViolation` | `.transcriptionPermissionDenied(provider:"azure-openai-realtime")` (77) | "Azure realtime: auth policy violation; not retrying" | Surface; do NOT retry. |
| WS close 1011 | Server error | `.abnormalClose(1011)` | `.transcriptionProviderUnavailable` (70) | "Azure realtime: server error; reconnecting…" | Reconnect-with-replay (§A2.7). |
| `error` event, `invalid_request_error` | Bad event structure | `.sessionRejected(type:"invalid_request_error", message:msg)` | `.transcriptionProviderUnavailable` (70) | "Azure realtime rejected event: {msg}" | Log + surface; session stays open. |
| `error` event, `server_error` after `transcription_session.update` containing `model` (RT-1) | The Azure model-field bug | `.modelFieldRejected` | `.transcriptionConfigConflict(reason: "Azure realtime: 'model' field included in session update — this is a known Azure bug. Strip the field from RealtimeWireTypes.SessionConfig.")` (64) | (developer-only — should never reach end users; the Codable omits the field by design) | Surface in logs; this is a code bug, not a user-actionable condition. |
| `error` event, `rate_limit_error` | Quota exceeded | `.rateLimited(resetSeconds:r)` | `.transcriptionProviderUnavailable` (70) | "Azure realtime rate-limited (resets in {r}s); recording continues without transcription" | Surface; close session; recording continues. |
| `error` event, `server_error` (other) | Internal Azure error | `.internalServerError(message:msg)` | `.transcriptionProviderUnavailable` (70) | "Azure realtime server error: {msg}" | Trigger reconnect-with-replay. |
| `conversation.item.input_audio_transcription.failed` | Per-item ASR failure (RT-3 / §5.10) | `.itemTranscriptionFailed(itemId:id, message:msg)` | (no error — surfaced as `StreamingTranscriptionEvent.error`) | "Azure realtime: utterance failed; continuing" | Log; emit `.error` event; session stays open. |
| Reconnect attempts 1+2+3 all fail within 30 s | RT-3 backoff exhausted | `.reconnectExhausted(attempts:3)` | `.transcriptionProviderUnavailable` (70) | "Azure realtime: reconnect failed after 3 attempts; recording continues without transcription" | Surface; close session; recording continues. |
| Resampler failure | `AVAudioConverter` returned `.error` | `.audioFormatMismatch(reason:r)` | `.transcriptionProviderUnavailable` (70) | "Azure realtime: 16→24 kHz resample failed: {r}" | Surface; close session. |
| Server sends event with unknown `type` | Vendor schema drift | `.unexpectedEvent(name:t)` | (no error — log only) | (silent in UI; warning in log) | Tolerate; log; continue. |

### 8.2 ElevenLabs (per research §7 + §B.4)

| HTTP | `detail.status` | `ElevenLabsSTTError` | `MacrecError` (exit) | User-facing message | Recovery |
|---|---|---|---|---|---|
| 400 | `audio_too_short` | (handled pre-flight) | (no error) | (silent — empty transcript) | Pre-flight: skip < 100 ms chunks. |
| 400 / 422 | `invalid_audio_format` / `invalid_file_type` | `.unsupportedFormat` | `.transcriptionProviderUnavailable` (70) | "Audio format not accepted by ElevenLabs (CAF must be converted)" | Pre-flight: never send CAF. |
| 401 | `invalid_api_key` / `missing_api_key` | `.invalidApiKey` | `.transcriptionApiKeyMissing(provider: "elevenlabs")` (78) | "ElevenLabs API key invalid; check `ELEVENLABS_API_KEY`" | Surface; abort. |
| 402 | `insufficient_credits` | `.insufficientCredits` | `.transcriptionProviderUnavailable` (70) | "ElevenLabs account out of credits; top up at https://elevenlabs.io/app/billing" | Surface; abort. |
| 403 | `feature_not_available` / `subscription_required` | `.planFeatureGate(feature)` | `.transcriptionProviderUnavailable` (70) | "ElevenLabs '{feature}' requires plan upgrade" | Surface; abort. |
| 413 | `request_too_large` | `.fileTooLarge` | `.transcriptionProviderUnavailable` (70) | "Audio chunk exceeds ElevenLabs 3 GB limit" | Pre-flight: should never trigger; abort. |
| 422 | `audio_too_long` | `.audioTooLong` | `.transcriptionProviderUnavailable` (70) | "Audio exceeds ElevenLabs 4.5 hr per-request limit" | Pre-flight: split chunks; abort current. |
| 422 | `invalid_parameters` | `.invalidParameter(field, msg)` | `.transcriptionConfigConflict(reason)` (64) | "ElevenLabs rejected '{field}': {msg}" | Surface (config bug); abort. |
| 429 | `rate_limit_exceeded` / `system_busy` | `.rateLimited(nil)` | `.transcriptionProviderUnavailable` (70) | "ElevenLabs rate-limited; backoff exhausted" | Exponential backoff (no `Retry-After` header); retry up to 3. |
| 429 | `concurrent_limit_exceeded` | `.concurrentLimitExceeded` | `.transcriptionProviderUnavailable` (70) | "ElevenLabs concurrent-request limit reached on your plan" | Surface immediately (no retry). |
| 500 / 503 | `internal_error` / `service_unavailable` | `.serverError(code)` | `.transcriptionProviderUnavailable` (70) | "ElevenLabs server error {code}; transient" | Retry with backoff (max 3). |
| (URLError) | offline / DNS | `.networkFailure(err)` | `.transcriptionProviderUnavailable` (70) | "ElevenLabs unreachable: {description}" | Retry once; surface on failure. |
| (decoder) | malformed JSON | `.decodingFailure(err)` | `.transcriptionProviderUnavailable` (70) | "ElevenLabs response malformed: {err}" | Log; surface; abort. |

---

## 9. Risk register

| ID | Severity | Risk | Mitigation |
|---|---|---|---|
| R-006-1 | MED | **Azure preview api-version may change before GA.** `2025-03-01-preview` is the recommended pin (research §1) but is non-GA. Microsoft may bump or retire it at any time. | Make `AZURE_OPENAI_API_VERSION` a documented config variable (§5 + §13 Az-1). Track Azure What's New page; bump when GA api-version covers `gpt-4o-mini-transcribe`. |
| R-006-2 | MED | **EU data residency gap for Azure.** As of 2026-04-29 `gpt-4o-mini-transcribe` Global Standard may route through East US 2; Regional / Data Zone deployments not yet confirmed for this model (research §11). EU users with strict residency requirements cannot satisfy GDPR via this engine alone. | Document the gap in privacy-disclosure copy (§7.1) and configuration-guide §LT-Az. Recommend Apple SpeechAnalyzer (on-device) as the residency fallback. Re-verify region availability before each release. |
| R-006-3 | MED | **ElevenLabs concurrency limits on free tier (8 batch concurrent requests).** Users on the free tier may exhaust the limit when `--transcribe-source both` produces parallel mic+system requests. | Surface `concurrent_limit_exceeded` immediately (no retry — §B.3). Document tier table in configuration-guide §LT-EL. Phase E adds `e2e-transcription-elevenlabs-concurrency.sh` (deferred — opt-in via `MACREC_RUN_EXPENSIVE_TESTS=1`). |
| R-006-4 | LOW | **ElevenLabs accent-aware text normalisation may differ from existing providers' output.** Scribe v2's normalisation (e.g. number rendering, punctuation density, audio-event tags) is unique. SRT/VTT timing alignment driven by Apple-vs-ElevenLabs side-by-side comparisons may show drift. | Phase B keeps `tag_audio_events=true` by default (matches vendor recommendation); document the normalisation in `docs/tools/macrec.md` so users know to expect `(laughter)` markers. SRT/VTT alignment uses ElevenLabs's `words[].start/end` directly when present. |
| R-006-5 | MED | **CAF format silently rejected by both providers.** macrec produces `m4a`, `wav`, `caf`. Both providers' format lists exclude CAF (research §5 / §10). Users picking the `caf` output format with cloud transcription enabled would see opaque 400 errors. | Pre-flight conversion: when `transcriptionProviderId ∈ {azure, elevenlabs}` AND `outputFormat == .caf`, throw `MacrecError.transcriptionConfigConflict(reason: "Cloud transcription requires WAV or M4A output format; CAF is not accepted by Azure or ElevenLabs")` at session start. Or, transparently re-encode the WAV chunk for the wire (already happens — `AudioWAVEncoder.encode(samples:)` always produces WAV regardless of recorded format). The latter is preferred — clarify in the plan that the wire format is decoupled from the on-disk format. |
| R-006-6 | LOW | **`xi-api-key` typo causes 401 with `missing_api_key` instead of `invalid_api_key`.** Easy to mis-type the header name. | Hardcoded constant in `ElevenLabsTranscriptionProvider`; covered by mock-URLProtocol test (E.2). |
| R-006-7 | LOW | **Azure Foundry portal renames "Models + endpoints" → "Deployments" path between releases.** Documentation links in privacy-disclosure copy may stale. | Use stable doc URLs (`/concepts/data-privacy`); review docs annually. |
| R-006-8 | MED | **`gpt-4o-mini-transcribe` model-version retirement.** Research §15: `2025-03-20` snapshot already retired. Future snapshot versions will retire too; users with stale deployments will get 404s. | Document the rename-deployment-to-track-version pattern in §D.1. Surface 404 → "Verify deployment name + region; abort" in the error matrix (§8.1). |
| R-006-9 | LOW | **Pricing assumption ($0.003/min Azure parity with OpenAI direct) unverified at scrape time.** Azure pricing page renders prices in JS (research §12). | Document the assumption explicitly in §A.9; surface a CLI/UI cost estimate clearly labelled "estimated" (not "actual"). |
| R-006-10 | LOW | **`additional_formats` request sub-object schema for ElevenLabs is undocumented.** v1 does not request SRT/VTT from the API; we generate them from `words[]` ourselves via the existing `SRTTranscriptWriter` / `VTTTranscriptWriter`. | Decision §13 EL-4: post-process SRT/VTT from `words[]` rather than request them from the API. Re-evaluate when ElevenLabs publishes the schema. |
| R-006-11 | MED | **Per-provider privacy-disclosure migration could lose users' Gemini acknowledgement.** The existing single boolean flag is reused for one provider during migration (Phase 0.3). | Migration logic in Phase 0.3 explicitly propagates the legacy boolean to the Gemini-specific key. Unit test in `PrivacyDisclosureSheetCopyTests` covers the migration. |
| RT-RISK-1 | MED | **Azure preview api-version `2025-04-01-preview` may change before GA.** Realtime transcription is preview-only as of 2026-04-29; Microsoft may bump or retire the version with little notice. | `AZURE_OPENAI_API_VERSION` is documented and overridable per §5.1; CI smoke test re-runs `e2e-transcription-azure-realtime.sh` on every Azure update; document the bump procedure in §LT-Az-RT. Bump the documented starter as soon as a GA api-version covers `intent=transcription`. |
| RT-RISK-2 | MED | **`AVAudioConverter` 16→24 kHz resample may introduce aliasing.** `AVAudioConverter`'s default quality may produce audible artifacts that degrade transcription WER. | Pin to `AVAudioConverter.primeMethod = .normal` and `.sampleRateConverterQuality = .max`; add `AudioResampler16to24Tests` that injects a 4 kHz sine tone, resamples, and asserts the output spectrum's energy above 12 kHz (the Nyquist of the source) is below -60 dBFS. |
| RT-RISK-3 | HIGH | **Reconnect-with-replay may double-transcribe the 5 s replay overlap.** After reconnect the server re-runs VAD on the replayed audio and emits a fresh `item_id` for what is, semantically, the same utterance. The provider could surface duplicate `final` events to the UI. | The session tracks the wall-clock range of the most recent `final` it emitted (`lastFinalRange: ClosedRange<Date>`). On the next `final` after a reconnect, if the new range overlaps `lastFinalRange` by > 50%, the session **discards** the new final (and its accumulated partials) — only the parts of the new final that fall *after* `lastFinalRange.upperBound` are emitted. Unit test in `AzureOpenAIRealtimeReconnectTests`. |
| RT-RISK-4 | MED | **Pre-emptive reconnect at 58 min may interrupt an in-progress utterance.** If speech is mid-utterance at the 58-min mark, an immediate disconnect would lose the trailing partials and force the next session to re-transcribe from the replay. | Section A2.8: when the 58-min timer fires, the session waits for the next `input_audio_buffer.committed` (or `speech_stopped`) event before triggering reconnect. Caps the wait at 90 s — if no commit arrives by 59:30, force-reconnect anyway (better to drop a 90 s utterance than to be force-closed by Azure at 60:00 and lose more). |
| RT-RISK-5 | LOW | **Region availability for realtime transcription is narrower than batch.** As of 2026-04-29 only East US 2 and Sweden Central are confirmed (research §11). | Document the narrower region matrix in §LT-Az-RT; recommend pinning the resource to East US 2 or Sweden Central in the configuration guide; verify on each release. |
| RT-RISK-6 | LOW | **Pre-existing `[Float]` ring buffer at 16 kHz means resample happens after audio is captured.** The 16→24 kHz resample adds ~5-10 ms latency per chunk on top of the ~80-200 ms first-partial baseline. | Acceptable for v1 — falls within the user's expected "near real-time" UX. If profiling shows the resample is the bottleneck, OQ-A2-1 alternative (capture at 24 kHz directly in `SCKitSystemAudioSource` and `AVMicrophoneSource`) is the cleaner fix. |
| RT-RISK-7 | MED | **WS upgrade may fail if Azure starts requiring `&deployment={name}` in the URL.** Per OQ-A2-2, the URL form is currently inconsistent between vendor docs and community samples. | Provider supports both forms via `AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL`; default `false` matches the TechCommunity reference; users can flip to `true` if Azure starts rejecting the URL without it. Phase E `e2e-transcription-azure-realtime.sh` covers the default; add a manual sub-test for the alternate form. |

---

## 10. Verification criteria

The following commands / file checks prove the plan is implemented.
This is the checklist a downstream verifier or test_builder workflow
would run (see test-orchestration patterns from plan-005 §8.7).

1. **Source presence** (greppable):
   - `grep -r "AzureOpenAITranscriptionProvider" Sources/` → at least the type declaration in
     `Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAITranscriptionProvider.swift`
     and a factory branch in `TranscriptionProviderFactory.swift`.
   - `grep -r "ElevenLabsTranscriptionProvider" Sources/` → analogous to above.
   - `grep -r "MultipartFormDataBuilder" Sources/` → at least the type
     declaration and two consumers (Azure, ElevenLabs).
   - `grep -r "AZURE_OPENAI_API_KEY" Sources/` → in `ConfigResolver.swift`
     and `ControlBar.swift`.
   - `grep -r "ELEVENLABS_API_KEY" Sources/` → in `ConfigResolver.swift`
     and `ControlBar.swift`.
   - `grep -r 'case "azure"' Sources/` → at least the factory branch and
     the picker entry.
   - `grep -r 'case "elevenlabs"' Sources/` → analogous.
   - `grep -r '"whisperkit"' Sources/MacrecCore/Config/RecordingOptions.swift`
     → enum case present (Phase 0.1 fix).

2. **Build** (must succeed):
   - `swift build` (release / debug).
   - `swift build --target MacrecCore`.
   - `swift build --target macrec`.
   - `swift build --target macrec-ui`.

3. **Unit tests** (must pass when run):
   - `swift test --filter MultipartFormDataBuilderTests`.
   - `swift test --filter AzureOpenAIConfigTests`.
   - `swift test --filter AzureOpenAITranscriptionProviderTests`.
   - `swift test --filter AzureOpenAIErrorMappingTests`.
   - `swift test --filter AzureOpenAIRetryTests`.
   - `swift test --filter ElevenLabsConfigTests`.
   - `swift test --filter ElevenLabsTranscriptionProviderTests`.
   - `swift test --filter ElevenLabsErrorMappingTests`.
   - `swift test --filter ElevenLabsResponseDecodingTests`.
   - `swift test --filter ConfigResolverAzureElevenLabsTests`.
   - `swift test --filter RecordingOptionsAzureElevenLabsTests`.
   - `swift test --filter PrivacyDisclosureSheetCopyTests`.
   - `swift test --filter ControlBarKeyResolutionTests`.
   - `swift test --filter ProviderKeyFieldTests`.
   - `swift test --filter TranscriptionProviderFactoryAzureElevenLabsTests`.
   - `swift test --filter AzureOpenAIRealtimeProviderTests` (Phase A2).
   - `swift test --filter AzureOpenAIRealtimeConfigTests` (Phase A2).
   - `swift test --filter AzureOpenAIRealtimeSessionTests` (Phase A2).
   - `swift test --filter AzureOpenAIRealtimeReconnectTests` (Phase A2).
   - `swift test --filter RealtimeWireTypesTests` — Codable round-trip; **specifically asserts the `model` field is OMITTED from `transcription_session.update`** (Phase A2 / RT-1).
   - `swift test --filter AudioResampler16to24Tests` (Phase A2).
   - `swift test --filter AudioRingBufferTests` (Phase A2).
   - `swift test --filter ConfigResolverAzureRealtimeTests` (Phase A2).
   - `swift test --filter GeminiRESTTranscriptionProviderTests` (must
     still pass — back-compat).
   - `swift test --filter AppleSpeechTranscriptionProviderTests` (must
     still pass — back-compat).

4. **Integration scripts** (manual run with real credentials):
   - `bash test_scripts/e2e-transcription-azure.sh` → exit 0; sidecar
     contains non-empty text.
   - `bash test_scripts/e2e-transcription-elevenlabs.sh` → exit 0; sidecar
     contains non-empty text.
   - `bash test_scripts/e2e-transcription-azure-key-missing.sh` → exit 78.
   - `bash test_scripts/e2e-transcription-elevenlabs-key-missing.sh` → exit 78.
   - `bash test_scripts/e2e-transcription-azure-deployment-not-found.sh` → exit 64.
   - `bash test_scripts/e2e-transcription-elevenlabs-413-too-large.sh` → exit 70 (gated by `MACREC_RUN_EXPENSIVE_TESTS=1`).
   - `bash test_scripts/e2e-transcription-azure-realtime.sh` → exit 0; sidecar contains ≥ 1 partial + ≥ 1 final; first partial ≤ 3 s.
   - `bash test_scripts/e2e-transcription-azure-realtime-reconnect.sh` → exit 0; reconnect-with-replay verified (no duplicate text in sidecar).
   - `bash test_scripts/e2e-transcription-azure-realtime-long.sh` → exit 0 (manual / opt-in only — `MACREC_RUN_EXPENSIVE_TESTS=1` because it requires 65 min of wall time; skipped in CI).
   - `bash test_scripts/e2e-transcription-azure-realtime-model-field-bug.sh` → exit 0 (no Azure call; pure local Codable assertion).
   - `bash test_scripts/e2e-transcription-azure-realtime-key-missing.sh` → exit 78.

5. **Doc presence**:
   - `grep -E '##\s+§?LT-Az' docs/design/configuration-guide.md`.
   - `grep -E '##\s+§?LT-EL' docs/design/configuration-guide.md`.
   - `grep "azure" docs/tools/macrec.md`.
   - `grep "elevenlabs" docs/tools/macrec.md`.
   - `grep "Azure OpenAI" docs/tools/macrec-ui.md`.
   - `grep "ElevenLabs" docs/tools/macrec-ui.md`.
   - `grep -E "FR-AZ-1|FR-EL-1" docs/design/project-functions.md`.

6. **Manual smoke** (menu-bar app):
   - Launch `macrec-ui`; pick "Azure OpenAI (cloud)"; observe
     Azure-specific privacy disclosure on first selection; record 10 s
     of speech; observe transcript appears in inline panel within ~5 s
     of speech end; verify sidecar `*.transcript.jsonl` is written.
   - Same flow with "ElevenLabs Scribe v2 (cloud)".

---

## 11. Dependencies & sequencing (DAG)

```
Phase 0 (shared scaffolding)
    │
    ├──► Phase A1 (Azure batch provider)        ─┐
    │                                             │
    ├──► Phase A2 (Azure realtime provider) ─────┤
    │                                             ├──► Phase C (UI integration)
    └──► Phase B  (ElevenLabs batch provider) ───┘            │
                                                                ▼
                                                          Phase D (docs)
                                                                │
                                                                ▼
                                                          Phase E (tests)
```

- **Phase 0** blocks **Phase A1**, **Phase A2**, and **Phase B** because:
  - Phase A1 and B both consume `MultipartFormDataBuilder` (Task 0.5).
    Phase A2 does NOT consume it (no multipart on the WS path) — but
    still depends on Phase 0 for the `.whisperkit` enum drift fix (Task
    0.1) and the new `TranscriptionProviderId` enum cases.
  - All three rely on the `ControlBar.startTapped()` fix (Task 0.2) for
    the UI happy path.
- **Phase A1, Phase A2, and Phase B are independently parallelisable**:
  they touch different folders (`Providers/Azure/` vs
  `Providers/Azure/Realtime/` vs `Providers/ElevenLabs/`), different
  factory branches (`case "azure"` vs `case "azure-openai-realtime"` vs
  `case "elevenlabs"`), different unit test files, and different env
  vars. Three implementers can work side-by-side. The only shared file
  is `TranscriptionProviderFactory.swift` (one new branch each — likely
  no merge conflict if each branch is added before the `default`
  clause in declaration order).
  - A1 and A2 share `AzureOpenAIConfig` shape but each owns its own
    config struct (`AzureOpenAIConfig` vs `AzureOpenAIRealtimeConfig`).
    A2 reuses A1's env vars (`AZURE_OPENAI_ENDPOINT`, `_DEPLOYMENT`,
    `_API_KEY`, `_API_VERSION`) so A2 can ride on the resolver
    extensions A1 already adds — A1 is therefore the "first" Azure phase
    and should land before A2 in the implementation order.
  - A2 and B are fully independent (no overlap).
- **Phase C** depends on all three of A1, A2, B because the picker,
  key field, and disclosure sheet all need to know each provider id.
- **Phase D** depends on A1, A2, B, C: the configuration guide reads
  the finalised env-var lists (including the realtime vars from A2);
  the tool docs reflect the finalised picker entries.
- **Phase E** depends on D: the unit tests assert against the
  documented behavior, and the integration scripts assert against the
  documented exit codes.

---

## 12. Definition of done

A reviewer can sign off the PR when:

1. All Phase 0..E acceptance criteria (AC-0-* through AC-E-*, plus
   AC-A-* for Phase A1, AC-A2-* for Phase A2, AC-B-* for Phase B,
   AC-C-* for Phase C, AC-D-* for Phase D) are met.
2. `swift build` succeeds for all four targets.
3. `swift test` passes for every test file listed in §10.3 (assuming a
   runner exists; otherwise the manual sign-off note in
   `Issues - Pending Items.md` per AC-E-7 stands in).
4. All eleven integration scripts exist with executable bit set
   (six original + five new realtime scripts); at least the
   non-expensive scripts have been run once with real credentials
   and the outcomes recorded in `Issues - Pending Items.md`. The
   65-min realtime long-recording script is opt-in only
   (`MACREC_RUN_EXPENSIVE_TESTS=1`).
5. `docs/design/project-functions.md` contains the new FR rows
   (FR-AZ-1..FR-AZ-12 for Phase A1; FR-AZ-13..FR-AZ-25 for Phase A2;
   FR-EL-1..FR-EL-N for Phase B — see project-functions.md patch
   in this PR).
6. `docs/design/configuration-guide.md` contains §LT-Az, §LT-Az-RT,
   and §LT-EL.
7. `docs/tools/macrec.md` and `docs/tools/macrec-ui.md` reflect the
   new providers (including `azure-openai-realtime`).
8. `Issues - Pending Items.md` lists the four resolved items from
   Phase 0, the PLAN-007-A2 entry, and any deferred items from §13
   (including the five new OQ-A2-* questions).
9. Manual menu-bar smoke (per §10.6) passes for Azure batch, Azure
   realtime, and ElevenLabs.

---

## 13. Open decisions (USER MUST CONFIRM BEFORE CODE STARTS)

These five decisions block Phase A or Phase B kickoff. The planner has
proposed a recommended answer to each; the user confirms or overrides.

### Az-1 — `AZURE_OPENAI_API_VERSION`: required-config or config-guide-documented starter?

- **Question**: The CLAUDE.md no-fallback rule says missing required
  config must throw. But the api-version is a moving target (preview
  versions are bumped every 1-3 months). Should we (a) require the
  user to set it explicitly every time, or (b) document a starter
  value (`2025-03-01-preview`) in `configuration-guide.md` and use
  it as a default in code, with a clear warning when it's stale?
- **Planner's recommendation**: **Option (b) — config-guide-documented
  starter (`2025-03-01-preview`)**. Rationale:
  - The api-version is not a secret; it's a contract version. Treating
    it like a secret is inappropriate.
  - The CLAUDE.md no-fallback rule's spirit is "no silent defaults for
    secrets / credentials". A documented, user-visible default for a
    non-secret protocol-version string is consistent with that spirit.
  - The configuration guide §LT-Az documents the starter explicitly
    and notes when it should be bumped (every Azure What's New cycle).
  - The factory's logging emits the resolved api-version at
    `info` level so the user always sees which value is in play.
- **If the user says (a)**: drop the `?? "2025-03-01-preview"` fallback
  in Phase A.6's factory branch and throw `transcriptionConfigConflict`
  when `AZURE_OPENAI_API_VERSION` is unset; document the recommended
  value in `configuration-guide.md` as text only.

### EL-1 — SRT/VTT generation: API `additional_formats` or post-process from `words[]`?

- **Question**: ElevenLabs supports an `additional_formats` request
  field that may yield SRT/VTT output directly from the API. However
  the sub-object schema is undocumented (research §3.7, §11 OQ-2).
  The existing `SRTTranscriptWriter` / `VTTTranscriptWriter` already
  generate SRT/VTT from segment data. Which path?
- **Planner's recommendation**: **Post-process from `words[]`** (use
  the existing in-tree writers). Rationale:
  - The `words[].start/end` data in the response is sufficient to
    reconstruct correctly-timed SRT/VTT.
  - Avoids depending on an undocumented vendor request shape.
  - Keeps the SRT/VTT format consistent across all providers (Apple,
    Gemini, Azure, ElevenLabs all use the same writer).
- **If the user wants API-side**: open a follow-up to verify the
  `additional_formats` schema against ElevenLabs support; do not
  block plan-007 on it.

### EL-2 — Enable `entity_detection` by default?

- **Question**: ElevenLabs supports PII/PHI/PCI/etc. entity detection
  with a +30% cost surcharge. Should v1 enable it by default?
- **Planner's recommendation**: **OFF by default; opt-in via
  `ELEVENLABS_ENTITY_DETECTION` env var**. Rationale:
  - The 30% surcharge is non-trivial and would surprise users.
  - PII detection is a feature primarily valuable for compliance
    workflows (call recording, legal); the typical macrec recording
    is a meeting or screen capture and doesn't need it.
  - Users who do need it can set
    `ELEVENLABS_ENTITY_DETECTION=pii` (or `=all`) explicitly.
  - The configuration guide documents the surcharge alongside the
    variable.
- **If the user says ON by default**: change the factory's default
  to `entityDetection: input.elevenLabsEntityDetection ?? "all"` and
  update the cost calculator to apply the surcharge by default.

### EL-3 — `pcm_s16le_16` fast-path: always-on, or runtime-checked?

- **Question**: ElevenLabs's `file_format=pcm_s16le_16` enables a
  lower-latency processing path BUT requires the audio to actually be
  16-bit PCM, 16 kHz, mono, little-endian. `AudioWAVEncoder` always
  produces exactly that format. Should the provider always set
  `file_format=pcm_s16le_16` (trusting the encoder), or runtime-check
  the WAV header on each chunk?
- **Planner's recommendation**: **Always-on with a static contract
  comment.** Rationale:
  - `AudioWAVEncoder` is the only producer of the bytes we send;
    its output format is a fixed contract.
  - Runtime-checking the WAV header on every chunk is wasteful (the
    chunks are only 2.5 s long).
  - A unit test in `ElevenLabsTranscriptionProviderTests` asserts the
    `file_format` field is set when the body comes from
    `AudioWAVEncoder.encode(samples:)`.
  - If a future encoder is added that produces a different format, the
    contract comment forces the implementer to revisit.
- **If the user says runtime-check**: parse the WAV header in the
  provider before adding the form field; downgrade to `file_format=other`
  if the header doesn't match the fast-path requirements.

### OQ-A2-1 — Resample location: inside the Realtime provider or in the audio sources?

- **Question**: The recorder produces 16 kHz Float audio (system audio
  from `SCKitSystemAudioSource`; mic varies by device). Azure realtime
  requires 24 kHz PCM16. Two options:
  - (a) Resample 16→24 kHz **inside `AzureOpenAIRealtimeSession`** —
    isolated change, only the realtime provider knows about the bump.
  - (b) Add a **24 kHz capture path** to `SCKitSystemAudioSource` and
    `AVMicrophoneSource` so the realtime provider receives 24 kHz
    natively — architecturally cleaner but touches more files (and
    adds a parallel ring buffer at the source level).
- **Planner's recommendation**: **(a) — resample inside the provider**.
  Rationale:
  - Confines the format quirk to a single file (`AudioResampler16to24.swift`).
  - All other providers (Apple, Gemini, Whisper, ElevenLabs) consume
    16 kHz happily; capturing at 24 kHz natively would force a
    downsample everywhere else or maintain two parallel formats.
  - The added latency (~5-10 ms per chunk per RT-RISK-6) is below
    user-perceptible threshold for the streaming UX.
- **If the user picks (b)**: add `var preferredSampleRate: Int { get }`
  to the audio-source protocol; teach the source classes to negotiate
  per-recording sample rate; remove `AudioResampler16to24` from the
  provider; deferred ~3 days of additional work to plan-007 timeline.

### OQ-A2-2 — `&deployment={name}` in the WebSocket URL?

- **Question**: The TechCommunity reference does NOT include a
  `&deployment=` query parameter; some Azure community Q&A samples DO.
  Should the provider include it?
- **Planner's recommendation**: **Default `false` (omit), behind a
  config flag (`AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL`)**. Rationale:
  - The TechCommunity sample is the most recent canonical reference
    and works without it.
  - Including it on a deployment that doesn't expect it could
    plausibly cause a 404 or 400.
  - If Azure starts rejecting the parameter-less URL, the user can
    flip the flag to `true` without a code change.
- **If the user wants always-on**: change the default to `true`; the
  flag stays available as an escape hatch.
- **If the user wants always-off (no flag)**: drop the env var; hard-
  code the URL without `&deployment=`.

### OQ-A2-3 — Ship A2 with delta events on, or `.completed`-only first?

- **Question**: The realtime research §13 confirms delta events work
  for the `intent=transcription` path on Azure (the known Azure
  delta-events gap is for the *conversational* `gpt-realtime` path,
  which is a different code path). Should A2 ship with deltas
  surfaced as `StreamingTranscriptionEvent.partial`, or only emit
  `.final` on the `.completed` event for safety?
- **Planner's recommendation**: **Ship deltas on (default)**. Rationale:
  - The research confirms the path supports them.
  - Deltas-on matches the live-transcript UX of Apple SpeechAnalyzer
    and Gemini Live — consistent UX across providers.
  - If the empirical e2e test (AC-A2-6) shows delta events do NOT
    arrive, fall back to `.completed`-only via a config flag
    `AZURE_OPENAI_REALTIME_PARTIALS_ENABLED` (default `true`).
- **If the user picks `.completed`-only first**: add the flag, default
  to `false`, document in §LT-Az-RT, gate the `.partial` emission on
  the flag.

### OQ-A2-4 — Expose `turn_detection.threshold` / `prefix_padding_ms` / `silence_duration_ms` as env vars or hardcode?

- **Question**: The realtime research §7.1 documents the recommended
  defaults (0.5 / 300 / 200). Should these be env vars or hardcoded?
- **Planner's recommendation**: **Env vars with documented defaults**
  (chosen — already in §A2.4):
  - `AZURE_OPENAI_REALTIME_VAD_THRESHOLD` (default 0.5)
  - `AZURE_OPENAI_REALTIME_VAD_PREFIX_PADDING_MS` (default 300)
  - `AZURE_OPENAI_REALTIME_VAD_SILENCE_MS` (default 200)
  - Rationale: users with noisy environments (recording desktop audio
    with video playing) need to be able to raise the threshold without
    a code change; hardcoded would force a recompile.
- **If the user prefers hardcoded for v1**: drop the three env vars
  from §A2.4 and §LT-Az-RT; bake the values into
  `AzureOpenAIRealtimeConfig` defaults; document the constants in
  source comments.

### OQ-A2-5 — Single PR for A1 + A2, or split (A1 first, A2 follow-up)?

- **Question**: The user originally asked to enhance plan-007 (single
  PR). A2 adds substantial complexity (WS lifecycle, resampler,
  reconnect-with-replay, 60-min boundary, 8 new test files, 5 new
  shell scripts). Is this still a single PR?
- **Planner's recommendation**: **Default to single PR (per the
  original request)** — but call out the size increase explicitly so
  the user can split if review burden is a concern. Rationale:
  - The Phase 0 / Phase C / Phase D / Phase E surfaces shared by A1,
    A2, and B are easier to land coherently in one PR than to refactor
    twice.
  - The risk register (RT-RISK-1..7) is bounded and reviewed-once.
  - Single PR keeps the privacy-disclosure copy / picker entries /
    config-guide updates atomic.
- **If the user prefers split**: the natural seam is "A1 + B + Phase 0
  + Phase C/D/E for A1+B" in PR 1, then "A2 + Phase C/D/E delta for
  A2" in PR 2. PR 2 would touch only `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/`,
  the picker (one new entry), the disclosure sheet (one new variant),
  and the realtime e2e scripts.

### UI-1 — Picker layout: flat list or "Cloud" submenu?

- **Question**: The picker now has 6 entries (`apple`, `whisperkit`,
  `gemini`, `azure`, `elevenlabs`, `none`). Per Assumption A-4, plan-007
  uses a flat list. Does the user want a "Cloud" submenu instead?
- **Planner's recommendation**: **Flat list** (Assumption A-4). Rationale:
  - 6 entries is well within macOS Picker UX guidelines (no scrolling
    needed at typical popover widths).
  - The current `TranscriptionPicker.swift` uses a flat picker; keeping
    it flat avoids picker-style refactoring.
  - The on-device vs cloud distinction is already telegraphed by the
    label suffix (`(on-device)` vs `(cloud)`).
  - If a 7th entry is added in plan-007 (`elevenlabs-realtime`), revisit
    the layout.
- **If the user picks submenu**: introduce a `Menu` containing two
  sub-`Picker`s — "On-device" (`apple`, `whisperkit`) and "Cloud"
  (`gemini`, `azure`, `elevenlabs`); `none` lives at the top-level.
  This adds ~30 LOC to `TranscriptionPicker.swift` and is reversible.

---

## 14. References

- Refined request: `docs/design/refined-request-additional-stt-engines.md`
- Codebase scan: `docs/reference/codebase-scan-additional-stt-engines.md`
- Investigation: `docs/reference/investigation-additional-stt-engines.md`
- Wire schema (Azure batch): `docs/research/azure-openai-gpt-4o-mini-transcribe-wire-schema.md` (§14 patched 2026-04-29 — points at the realtime file for the WS path)
- Wire schema (Azure realtime — Phase A2 primary input): `docs/research/azure-openai-realtime-transcription-wire-schema.md`
- Wire schema (ElevenLabs): `docs/research/elevenlabs-stt-wire-schema.md`
- Existing batch pattern: `docs/design/plan-004-rest-batch-transcription.md`
- Extended provider contract: `docs/design/plan-005-apple-speech-streaming.md` §4.1
- Project rules: `CLAUDE.md` (Approved Exceptions 001 + 002)
- Function registry: `docs/design/project-functions.md` (FR-AZ-* and FR-EL-* added)
- Configuration guide: `docs/design/configuration-guide.md` (§LT-Az and §LT-EL added)
- Tool docs: `docs/tools/macrec.md` and `docs/tools/macrec-ui.md`
