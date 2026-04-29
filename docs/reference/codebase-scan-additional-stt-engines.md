---
language: swift
framework: none
package_manager: swift-package-manager
build_command: "swift build"
test_command: "swift test"
lint_command: null
entry_points:
  - Sources/macrec/main.swift
  - Sources/macrec-ui/MacrecUIApp.swift
last_scanned_commit: c56425e54dd1286d36e255e6c8bcf6959129c1d1
scanned_for_request: refined-request-additional-stt-engines.md
scanned_at: "2026-04-29T00:00:00Z"
---

# Codebase Scan — macrec / macrec-ui (additional-stt-engines narrowing)

## 1. Project Overview

Swift-only SwiftPM workspace (macOS 26 deployment target, Approved Exception 002) with
three products: `macrec` (CLI), `macrec-ui` (menu-bar app), and `MacrecCore` (shared
library). A fourth library target `MacrecUIKit` bridges `MacrecCore` to the SwiftUI
layer. External dependencies: `swift-argument-parser` and `swift-log` only; no
vendor STT SDK exists. The transcription subsystem is fully implemented under
`Sources/MacrecCore/Transcription/` with four live providers as of this commit:
`NoOp`, `Fake`, `GeminiREST` (batch, plan-004), `AppleSpeech` (streaming, plan-005),
plus `WhisperKit` (on-device batch, plan-004 extension). The new Azure OpenAI and
ElevenLabs providers slot in as additional conformers to the existing `TranscriptionProvider`
protocol without breaking any existing path.

---

## 2. Module Map

| Path | Purpose | Representative symbols |
|---|---|---|
| `Sources/MacrecCore/Transcription/` | All STT orchestration, protocols, types | `TranscriptionManager`, `TranscriptionProvider`, `StreamingTranscriptionSession` |
| `Sources/MacrecCore/Transcription/Providers/` | Concrete provider impls + factory | `GeminiRESTTranscriptionProvider`, `AppleSpeechTranscriptionProvider`, `TranscriptionProviderFactory` |
| `Sources/MacrecCore/Transcription/Persistence/` | Sidecar writers for jsonl/srt/vtt/txt | `TranscriptSidecarWriter`, `SidecarPolicy`, `SidecarPathBuilder` |
| `Sources/MacrecCore/Config/` | Four-tier env-var resolver, options value type | `ConfigResolver`, `RecordingOptions`, `TranscriptionProviderId` |
| `Sources/MacrecCore/Errors/` | Typed error enum with locked exit codes | `MacrecError` |
| `Sources/MacrecCore/Capture/` | PCM acquisition (system audio + mic) | `SCKitSystemAudioSource`, `AVMicrophoneSource` |
| `Sources/MacrecCore/Aligning/` | 100 ms aligned-frame production | `HostClockAligner`, `AlignedFrame` |
| `Sources/MacrecUIKit/` | UI domain layer — controller, coordinator, meters | `RecordingController`, `SessionCoordinator` |
| `Sources/macrec/Commands/` | CLI subcommands (ArgumentParser) | `StartCommand`, `StopCommand`, `RootCommand` |
| `Sources/macrec-ui/Views/Transcription/` | UI picker, privacy sheet, transcript panel | `TranscriptionPicker`, `PrivacyDisclosureSheet`, `GeminiKeyField` |
| `Sources/macrec-ui/Views/` | Non-transcription UI views | `ControlBar`, `FormatPicker`, `RootView` |

---

## 3. Conventions

- **Protocol + actor + `AsyncStream` pattern.** `TranscriptionProvider` is a `Sendable`
  protocol (`TranscriptionProvider.swift:29`). Streaming sessions implement
  `StreamingTranscriptionSession` (`StreamingTranscriptionSession.swift:42`) with an
  `events: AsyncStream<StreamingTranscriptionEvent>` output and fire-and-forget `ingest`.
  The manager selects batch vs streaming at construction time based on
  `provider.supportedModes` (`TranscriptionManager.swift:104-123`). New batch-only
  providers (Azure, ElevenLabs) declare `supportedModes = [.batch]` and implement only
  `transcribe(samples:source:options:)`; `openStreamingSession(...)` throws
  `.transcriptionConfigConflict(...)` — exactly the pattern in `GeminiRESTTranscriptionProvider.swift:141-148`.

- **No fallback for missing config.** `ConfigResolver.resolve(cliOverrides:)` resolves
  API keys via the four-tier `value(_:)` closure (`ConfigResolver.swift:89-94`).
  A missing key for an active provider is NOT thrown at parse time; it surfaces as
  `MacrecError.transcriptionApiKeyMissing(provider:)` at
  `TranscriptionProviderFactory.build(_:)` (`TranscriptionProviderFactory.swift:50-52`)
  when the factory checks `guard let key = input.apiKey, !key.isEmpty`.
  New providers MUST follow this exact guard pattern.

- **`URLSession.shared` for HTTP.** `GeminiRESTTranscriptionProvider.init` receives
  `urlSession: URLSession = .shared` (`GeminiRESTTranscriptionProvider.swift:47`),
  injected from the factory (`TranscriptionProviderFactory.swift:58`). Auth is
  expressed as a query parameter (`?key=apiKey`) or header. New providers should
  accept an injected `URLSession` for testability.

- **`SidecarPolicy.batch` for REST providers; `.streaming` for streaming providers.**
  `TranscriptSidecarWriter` switches on `SidecarPolicy`
  (`TranscriptSidecarWriter.swift:48-60`) to persist only the right event subset. Azure
  OpenAI (batch) uses `.batch`; ElevenLabs (batch) uses `.batch`. If Azure realtime
  is added later it uses `.streaming`.

- **`TranscriptionManager.rotateSidecar(toAudioURL:format:)` reconstructs writers.**
  When a segment rotates (`TranscriptionManager.swift:213-238`), the batch pipeline
  calls `SidecarPathBuilder.sidecarURL(forRecording:format:)` and constructs a new
  `TranscriptSidecarWriter(outputPath:format:policy:.batch)`. New batch providers
  participate automatically — no changes to the manager.

---

## 4. Integration Points

### IP-1 — `TranscriptionProvider` Protocol

- **File**: `Sources/MacrecCore/Transcription/TranscriptionProvider.swift`
- **Lines**: 29–44 (entire protocol declaration)
- **Symbol**: `TranscriptionProvider`

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

- **What changes**: No change to the protocol itself (R-5 verified). Each new provider
  is a new `struct` (or `actor`) that conforms to this protocol, placed in
  `Sources/MacrecCore/Transcription/Providers/`. Batch-only providers implement
  `transcribe(...)` and throw `.transcriptionConfigConflict(...)` from
  `openStreamingSession(...)`.
- **Drift check**: Protocol matches plan-005 §4.1 exactly. No drift detected.

---

### IP-2 — `TranscriptionMode` Enum

- **File**: `Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift`
- **Lines**: 26–36

```swift
public enum TranscriptionMode: Sendable, Codable, Equatable, Hashable {
    case batch
    case streaming
}
```

- **What changes**: No new cases required. Azure REST uses `.batch`; ElevenLabs (batch)
  uses `.batch`. A future Azure Realtime WebSocket path would also use `.streaming`
  (already available). The enum is closed — adding a case would require all `switch`
  sites to be updated, so the plan should verify that neither provider truly needs a
  third mode before proposing one.

---

### IP-3 — `StreamingTranscriptionSession` Protocol

- **File**: `Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift`
- **Lines**: 42–56

```swift
public protocol StreamingTranscriptionSession: Sendable {
    func ingest(_ samples: [Float]) async
    var events: AsyncStream<StreamingTranscriptionEvent> { get }
    func finish() async
}
```

- **What changes**: Not required for Azure or ElevenLabs in v1 (both batch-only per
  Assumptions A-1 and A-5). If Azure Realtime WebSocket is confirmed during research
  (Q1), a new `AzureRealtimeSession` actor implementing this protocol would be added
  in `Sources/MacrecCore/Transcription/Providers/`. ElevenLabs batch-only means no
  session type needed. `StreamingTranscriptionEvent` (`lines 65-87`) with `.partial`,
  `.final`, `.metrics`, `.error` variants would be used unchanged for a streaming variant.

---

### IP-4 — `TranscriptionProviderFactory`

- **File**: `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift`
- **Lines**: 30–94
- **Symbol**: `TranscriptionProviderFactory.build(_:)` — `lines 33–93`

The entire `switch normalized { ... }` block at lines 46–93 is the factory dispatch.
Currently handles: `"none"/"" → NoOp`, `"gemini" → GeminiREST`, `"apple" → AppleSpeech`,
`"whisperkit" → WhisperKit`. The `default` clause at line 89 throws
`.transcriptionConfigConflict(reason: "transcribe value '\(normalized)' invalid ...")`.

```swift
// Lines 46–93 (abridged):
switch normalized {
case "none", "": return NoOpTranscriptionProvider()
case "gemini": ...
case "apple": ...
case "whisperkit": ...
default:
    throw MacrecError.transcriptionConfigConflict(
        reason: "transcribe value '\(normalized)' invalid (allowed: 'none', 'apple', 'gemini', 'whisperkit')"
    )
}
```

- **What changes**: Add two new `case` branches before `default`:
  - `case "azure"` — guards `apiKey != nil`, resolves `endpoint`/`deployment`/`apiVersion`
    from `input` (or new fields added to `TranscriptionProviderFactoryInput`), constructs
    `AzureOpenAITranscriptionProvider`.
  - `case "elevenlabs"` — guards `apiKey != nil`, constructs `ElevenLabsTranscriptionProvider`.
  - Update the `default` error message to list all six allowed values.
  - **Note**: `TranscriptionProviderFactoryInput` (lines 5–28) may need new fields for
    Azure (`endpoint: String?`, `deploymentName: String?`, `apiVersion: String?`) since
    these are Azure-specific and not covered by the existing `providerId`/`apiKey`/`modelId`
    tuple. Alternatively, pass them via `TranscriptionOptions.customSystemInstruction`
    as a JSON blob — but a typed approach is cleaner. This is an extension point requiring
    a plan decision (§4 of plan-007).

---

### IP-5 — `TranscriptionProviderId` Enum (Config-parse-time enum)

- **File**: `Sources/MacrecCore/Config/RecordingOptions.swift`
- **Lines**: 74–79

```swift
public enum TranscriptionProviderId: String, CaseIterable, Sendable, Codable, Equatable {
    case none
    case apple = "apple"
    case gemini
    case geminiLive = "gemini-live"
}
```

- **What changes**: Add two new cases:
  - `case azure = "azure"`
  - `case elevenlabs = "elevenlabs"`
  - Also add `case whisperkit = "whisperkit"` if not already present (it is not — the
    factory handles `"whisperkit"` by string match but the resolver enum does NOT have a
    `.whisperkit` case; this is a pre-existing drift that plan-007 should note).
  - `ConfigResolver.resolve()` at line 235 calls `parseEnum(key:raw:default:)` against
    this enum. Adding the new cases makes the resolver recognize the new wire values and
    lowers them to the provider `String` stored in `RecordingOptions.transcriptionProviderId`.
  - The `transcriptionApiKey` resolution switch at lines 345–354 must be extended to
    resolve the appropriate vendor-canonical env-var for each new provider
    (`AZURE_OPENAI_API_KEY` and `ELEVENLABS_API_KEY`).

---

### IP-6 — `ConfigResolver.resolve(cliOverrides:)` — Env-Var Resolution Chain

- **File**: `Sources/MacrecCore/Config/ConfigResolver.swift`
- **Lines**: 83–399 (full `resolve` method); key sub-ranges below

| Sub-range | What it does |
|---|---|
| 89–94 | `value(_:)` closure — implements `cliOverrides > localEnv > userEnv > shellEnv` |
| 234–260 | Resolves `MACREC_TRANSCRIBE` → `TranscriptionProviderId` → lowered `String` |
| 345–354 | Resolves provider API key — currently Gemini-only (`GOOGLE_API_KEY`) |
| 357–360 | Resolves `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` |
| 401–436 | `enum Keys` — all `static let` env-var name constants |

- **What changes (API key resolution, lines 345–354)**:

```swift
// Current (lines 345–354):
let transcriptionApiKey: String? = {
    guard transcribeIsActive else { return nil }
    switch transcribeProviderEnum {
    case .gemini, .geminiLive:
        let raw = value(Keys.googleApiKey)
        return (raw?.isEmpty == false) ? raw : nil
    case .apple, .none:
        return nil
    }
}()
```

Extend the `switch` with:
  - `case .azure`: resolve `value(Keys.azureOpenAIApiKey)` (new constant `AZURE_OPENAI_API_KEY`).
  - `case .elevenlabs`: resolve `value(Keys.elevenLabsApiKey)` (new constant `ELEVENLABS_API_KEY`).
  - `case .whisperkit`: `return nil` (no key needed — same as `.apple`).

- **What changes (`enum Keys`, lines 401–436)**:
  Add new `static let` constants after the existing transcription block:

```swift
// New keys to add to ConfigResolver.Keys:
public static let azureOpenAIApiKey      = "AZURE_OPENAI_API_KEY"
public static let azureOpenAIEndpoint    = "AZURE_OPENAI_ENDPOINT"
public static let azureOpenAIDeployment  = "AZURE_OPENAI_DEPLOYMENT"
public static let azureOpenAIApiVersion  = "AZURE_OPENAI_API_VERSION"
public static let elevenLabsApiKey       = "ELEVENLABS_API_KEY"
// Expiry companions (CLAUDE.md configuration-guide rule):
public static let azureOpenAIApiKeyExpiresAt   = "AZURE_OPENAI_API_KEY_EXPIRES_AT"
public static let elevenLabsApiKeyExpiresAt    = "ELEVENLABS_API_KEY_EXPIRES_AT"
```

- **What changes (`resolve`, Azure-specific fields)**:
  Azure requires three additional resolved values (`endpoint`, `deployment`, `apiVersion`)
  beyond the generic `apiKey` field. Two options:
  1. Add new stored properties to `RecordingOptions` (preferred — type-safe, consistent).
  2. Pack them into a JSON string passed via `TranscriptionOptions.customSystemInstruction`
     (a hack — not recommended).
  Option 1 requires updating `RecordingOptions.init`, `RecordingOptions.withOutput(_:)`,
  `ConfigResolver.resolve()`, `ControlBar.startTapped()`, and
  `TranscriptionProviderFactoryInput.init`. This is the correct approach.

---

### IP-7 — `RecordingOptions` — Per-Session Configuration Struct

- **File**: `Sources/MacrecCore/Config/RecordingOptions.swift`
- **Lines**: 100–332

Relevant transcription fields (lines 153–205):
- `transcriptionProviderId: String?` (line 160) — wire id of the selected provider.
- `transcriptionApiKey: String?` (line 183) — resolved key (nil for on-device providers).
- `transcriptionKeyExpiresAt: Date?` (line 188) — expiry companion.
- `transcriptionModelId: String?` (line 194) — model override.
- `transcriptionLanguageHints: [String]` (line 205) — BCP-47 hints.

`withOutput(_:)` at line 306 must be updated for every new field added.
The regression test `testWithOutputPreservesTranscriptionFields` (mentioned in code comment
at line 302) should be extended to cover the new Azure-specific fields.

- **What changes**:
  Add new `let` properties for Azure-specific config (no equivalents exist today):
  - `azureOpenAIEndpoint: String?` — the base endpoint URL (e.g. `https://<resource>.openai.azure.com`).
  - `azureOpenAIDeployment: String?` — deployment name (the user's portal-configured name).
  - `azureOpenAIApiVersion: String?` — e.g. `"2024-06-01"`.
  - `azureOpenAIApiKeyExpiresAt: Date?` — expiry companion.
  - `elevenLabsApiKeyExpiresAt: Date?` — expiry companion for ElevenLabs key.
  - Update `init(...)` default parameters for each (all `nil` — optional).
  - Update `withOutput(_:)` to forward every new field.

---

### IP-8 — `TranscriptionOptions` — Per-Call Options Struct

- **File**: `Sources/MacrecCore/Transcription/TranscriptionOptions.swift`
- **Lines**: 21–75

Key fields:
- `providerId: String` (line 29) — wire id passed to the provider at call time.
- `apiKey: String?` (line 35) — already resolved key.
- `modelId: String?` (line 39) — provider-specific model override.
- `languageHints: [String]` (line 46) — BCP-47 list.
- `customSystemInstruction: String?` (line 52) — passthrough hint field.
- `keyExpiresAt: Date?` (line 58) — expiry timestamp for warning.

- **What changes**:
  Azure requires `endpoint`, `deploymentName`, and `apiVersion` at call time. Three paths:
  1. Add typed fields to `TranscriptionOptions` (breaks all existing `init` call sites —
     significant churn).
  2. Add typed fields to `TranscriptionProviderFactoryInput` only (the factory passes them
     to the provider's `init`, which stores them; `transcribe(...)` uses `self.endpoint`).
     This is the **preferred** approach — `TranscriptionOptions` stays stable, the provider
     captures Azure-specific config at construction time.
  3. Encode into `customSystemInstruction` (a hack — not recommended).

  **Recommendation**: Azure-specific config (endpoint, deployment, apiVersion, second expiry)
  flows via `TranscriptionProviderFactoryInput` new fields + provider stored properties.
  `TranscriptionOptions` is left unchanged. ElevenLabs needs only `apiKey` — no new fields.

---

### IP-9 — `TranscriptionManager.init` — Pipeline Mode Dispatch

- **File**: `Sources/MacrecCore/Transcription/TranscriptionManager.swift`
- **Lines**: 89–124 (`init`); 132–142 (`start`)

```swift
// Lines 104–123 (init, pipeline selection):
let streamingSelected = provider.supportedModes.contains(.streaming)
self.isStreaming = streamingSelected
if streamingSelected {
    if #available(macOS 26.0, *) {
        self.streamingPipeline = StreamingTranscriptionPipeline(...)
    } else {
        self.streamingPipeline = nil
    }
} else {
    self.streamingPipeline = nil
}
```

- **What changes**: Nothing. Both Azure (batch) and ElevenLabs (batch) declare
  `supportedModes = [.batch]`, so `isStreaming == false` and the existing batch pipeline
  (`processLoop` → `runProviderCall` → `provider.transcribe(...)`) is used unchanged.
  The manager is agnostic to which concrete provider is in `self.provider`.

---

### IP-10 — `TranscriptSidecarWriter` and `SidecarPolicy`

- **File**: `Sources/MacrecCore/Transcription/Persistence/TranscriptSidecarWriter.swift`
- **Lines**: 48–60 (`SidecarPolicy`); 65–248 (`TranscriptSidecarWriter` actor)

```swift
public enum SidecarPolicy: Sendable, Equatable {
    case batch      // lines 52–58: persists .segmentAppended + .segmentUpdated
    case streaming  // lines 59–60: persists .segmentFinalized only
}
```

`TranscriptSidecarWriter.init(outputPath:format:policy:)` at line 87 is where the writer
is constructed. The factory at `makeFormatWriter(for:url:)` (line 221) dispatches to
`JSONLTranscriptWriter`, `SRTTranscriptWriter`, `VTTTranscriptWriter`, `TXTTranscriptWriter`.

- **What changes**: Nothing for Azure or ElevenLabs batch. Both use `policy: .batch`.
  The `TranscriptionManager.rotateSidecar(...)` batch branch (lines 222–237) already
  constructs the writer with `.batch`; new providers inherit this automatically.
  Format support (jsonl/srt/vtt/txt) is complete — no new format writer needed.

---

### IP-11 — `GeminiRESTTranscriptionProvider` — Batch REST Pattern to Mirror

- **File**: `Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift`
- **Lines**: 1–149 (full file)

This is the **reference implementation** for both Azure and ElevenLabs. Key pattern elements:

| Element | Line(s) | Notes for new providers |
|---|---|---|
| `struct` declaration with `Sendable` | 7 | Use `struct` (stateless per call); or `actor` if session reuse is needed |
| `id`, `displayName`, `supportedModes` | 37–39 | Use `"azure"` / `"elevenlabs"` / `[.batch]` |
| `URLSession` injected via `init` | 44–56 | Same pattern; `.shared` default; tests inject mock |
| `AudioWAVEncoder.encode(samples:)` | 63 | Produces `Data` (16 kHz mono Int16 WAV); Azure and ElevenLabs both accept WAV |
| `URLRequest` + `httpMethod = "POST"` | 91–94 | Azure: `api-key` header; ElevenLabs: `xi-api-key` header |
| `urlSession.data(for:)` | 98 | Plain `URLSession` data task — no SDK |
| HTTP non-2xx error handling | 111–121 | Map 401/403/413/429/5xx to `.transcriptionProviderUnavailable(reason:)` until new error cases are added |
| JSON decode → raw string | 123–134 | Each provider has its own response schema |
| `openStreamingSession` throws | 141–148 | Batch-only guard; copy verbatim for Azure/ElevenLabs batch |

- **Azure-specific differences**:
  - URL: `{endpoint}/openai/deployments/{deployment}/audio/transcriptions?api-version={apiVersion}`
  - Auth: `api-key: {apiKey}` request header (not a query parameter).
  - Request body: `multipart/form-data` (not JSON). Fields: `file` (WAV bytes), `model`
    (deployment name, required by the schema), `language` (BCP-47 hint, optional),
    `response_format` (`json` or `verbose_json` for timestamps).
  - Response: OpenAI-compatible `{"text": "..."}` for `json` format.
  - **Note**: The Gemini provider base64-encodes audio inside JSON; Azure uses multipart.
    `URLSession` supports multipart via `URLRequest.httpBody = buildMultipart(...)`.
    No third-party library needed.

- **ElevenLabs-specific differences**:
  - URL: `https://api.elevenlabs.io/v1/speech-to-text`
  - Auth: `xi-api-key: {apiKey}` request header.
  - Request body: `multipart/form-data`. Fields: `audio` (WAV bytes), `model_id`
    (e.g. `"scribe_v1"`), `language_code` (ISO-639-1), `diarize` (bool).
  - Response: `{"text": "...", "words": [...], "language_code": "..."}`.

---

### IP-12 — Audio Ring Buffer / PCM Feed to Provider

- **File**: `Sources/MacrecCore/Transcription/TranscriptionManager.swift`
- **Lines**: 173–206 (`ingest` and `ingestFrame` public methods)

```swift
// Line 173: fire-and-forget ingest for 16 kHz Float32 samples
public func ingest(_ samples: [Float], from tag: SourceTag) { ... }

// Line 190: convenience for AlignedFrame from HostClockAligner tap
public func ingestFrame(_ frame: AlignedFrame, from tag: SourceTag) { ... }
```

`ingestFrame` downsamples 48 kHz CMSampleBuffer → 16 kHz Float32 via `AudioDownsampler`
and forwards to `ingest`. The batch pipeline buffers samples in `SourceBuffer` actors
(`buffers[tag]`, line 77) and drains every 2 s via `processLoop` (line 297).

- **What changes**: Nothing. New providers receive the same `[Float]` at 16 kHz mono
  when `TranscriptionManager.runProviderCall(samples:source:isFinal:)` calls
  `provider.transcribe(samples:source:options:)`. The PCM format contract
  (`samples: [Float]`, 16 kHz mono, `[-1, 1]`) documented in `TranscriptionProvider.swift:27`
  applies equally to Azure and ElevenLabs — both accept 16 kHz mono WAV.

Audio encoding for the wire: `AudioWAVEncoder.encode(samples:)` at
`Sources/MacrecCore/Transcription/AudioWAVEncoder.swift` converts `[Float]` to a
16 kHz / 16-bit / mono WAV `Data` blob. Both new providers should call this same encoder.

---

### IP-13 — `MacrecError` — Error Enum Extensions Needed

- **File**: `Sources/MacrecCore/Errors/MacrecError.swift`
- **Lines**: 18–69 (enum + `exitCode` switch)

Existing transcription cases (lines 61–65):
```swift
case transcriptionApiKeyMissing(provider: String)        // exit 78
case transcriptionPermissionDenied(provider: String)     // exit 77
case transcriptionProviderUnavailable(reason: String)    // exit 70
case transcriptionConfigConflict(reason: String)         // exit 64
case transcriptionKeyExpired(provider: String, expiredAt: Date)  // exit 78
```

- **What changes**:
  New providers reuse all five existing cases — no new `MacrecError` cases are strictly
  required for v1. However, plan-004 Phase G has a TODO (line 90 in factory, lines 82/87/100/108/117
  in GeminiRESTTranscriptionProvider.swift) to rename `.transcriptionProviderUnavailable(reason:)`
  to `.transcriptionProviderFailed(detail:)`. Plan-007 should either:
  1. Complete that rename before adding new providers (cleaner).
  2. Accept the existing name for Azure and ElevenLabs (lower risk).

  Azure-specific failure modes that map to existing cases:
  - HTTP 401/403 → `.transcriptionApiKeyMissing(provider: "azure")` or `.transcriptionProviderUnavailable`
  - HTTP 404 (deployment not found) → `.transcriptionConfigConflict(reason: "Azure deployment '\(deployment)' not found ...")`
  - HTTP 413 (payload too large) → `.transcriptionProviderUnavailable(reason: "audio too large ...")`
  - HTTP 429 (rate limit) → `.transcriptionProviderUnavailable(reason: "rate limited ...")`
  - HTTP 5xx → `.transcriptionProviderUnavailable(reason: "server error \(statusCode)")`

  ElevenLabs failure modes: identical mapping pattern.

  The `description` and `remediation` strings at lines 208–320 are locked by design §2.1.
  New providers inherit the existing messages via their provider name in the `(provider:)` payload.

---

### IP-14 — CLI Surface — `StartCommand` (Flag Parser)

- **File**: `Sources/macrec/Commands/StartCommand.swift`
- **Lines**: 36–224

Existing transcription `@Option` flags (lines 88–112):

```swift
@Option var transcribe: String?           // → ConfigResolver.Keys.transcribe
@Option var transcribeSource: String?     // → ConfigResolver.Keys.transcribeSource
@Option var transcribeFormat: String?     // → ConfigResolver.Keys.transcribeFormat
@Option var transcribeModel: String?      // → ConfigResolver.Keys.transcribeModel
@Option var transcribeLanguage: String?   // → ConfigResolver.Keys.transcribeLanguage
@Option var transcribeKeyExpiresAt: String?  // → ConfigResolver.Keys.transcribeKeyExpiresAt
```

`buildCLIOverrides()` at line 199 maps each flag to the env-var key dictionary.

- **What changes**:
  - The `--transcribe` flag help text (line 95) currently lists `none | gemini-live`;
    update to include `azure | elevenlabs`.
  - No new `@Option` flags are required for Azure-specific config (`AZURE_OPENAI_ENDPOINT`,
    `AZURE_OPENAI_DEPLOYMENT`, `AZURE_OPENAI_API_VERSION`) — per the project's security model
    (comment at lines 90–93: "there is intentionally NO `--transcribe-key` flag").
    Azure-specific config follows the same pattern: set in env or `.env` file.
  - No new flags for ElevenLabs — only `ELEVENLABS_API_KEY` needed, resolved via env chain.
  - Optional: add `--transcribe-azure-deployment` for the deployment name (a non-secret
    config value that IS appropriate as a CLI flag). Decision deferred to plan-007 §5.

---

### IP-15 — UI Provider Picker — `TranscriptionPicker`

- **File**: `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift`
- **Lines**: 35–93

Current picker `Picker` items (lines 72–77):
```swift
Picker(String(localized: "Transcribe"), selection: $providerRaw) {
    Text("Apple Speech (on-device)").tag("apple")
    Text("WhisperKit (on-device, multilingual)").tag("whisperkit")
    Text("Gemini (cloud)").tag("gemini")
    Text("None").tag("none")
}
```

`@AppStorage("com.macrec.ui.transcribeProvider")` (line 43) persists the selection.
`missingKeyTooltip` (line 68) currently references only `GOOGLE_API_KEY`.

- **What changes** (per Assumption A-4 — flat list):
  ```swift
  Text("Azure OpenAI (cloud)").tag("azure")
  Text("ElevenLabs (cloud)").tag("elevenlabs")
  ```
  Inserted after `"Gemini (cloud)"` and before `"None"`.
  Update `missingKeyTooltip` to be provider-aware (or make the tooltip a computed property
  that derives the correct env-var name from the current selection).

---

### IP-16 — UI API Key Field — `GeminiKeyField` (Pattern to Extend)

- **File**: `Sources/macrec-ui/Views/Transcription/GeminiKeyField.swift`
- **Lines**: 1–end (full file; not read but located)
- **Symbol**: `GeminiKeyField`

This view provides inline key entry / display for `GOOGLE_API_KEY`, shown only when
the Gemini provider is selected. The same pattern must be replicated for Azure and
ElevenLabs. Two design options:

  1. Add `AzureKeyField` and `ElevenLabsKeyField` views following the same
     `GeminiKeyField` pattern, shown conditionally in `RootView`'s "Live transcription"
     disclosure group based on `transcribeProviderRaw`.
  2. Generalize `GeminiKeyField` into a `ProviderKeyField(envVarName:providerLabel:)` view.

Plan-007 §7 should specify which approach to use (option 2 reduces duplication).

---

### IP-17 — Privacy Disclosure Trigger — `RootView`

- **File**: `Sources/macrec-ui/RootView.swift`
- **Lines**: 192–203 (`.onChange(of: transcribeProviderRaw)` handler); 316–323 (`isCloudProvider`)

```swift
// Lines 316–323:
private static func isCloudProvider(_ raw: String) -> Bool {
    switch raw.lowercased() {
    case "gemini", "gemini-live":
        return true
    default:
        return false
    }
}
```

The `.onChange` handler (line 192) shows `PrivacyDisclosureSheet` when `isCloudProvider`
returns `true` AND `!privacyAcknowledged`.

- **What changes**:
  Extend `isCloudProvider` to return `true` for `"azure"` and `"elevenlabs"`:
  ```swift
  case "gemini", "gemini-live", "azure", "elevenlabs":
      return true
  ```
  The `PrivacyDisclosureSheet` body text (lines 80–84 in `PrivacyDisclosureSheet.swift`)
  currently says "e.g., Google's Gemini API". This must be updated to either:
  - Reference all cloud providers generically ("a cloud STT service"),
  - Or become provider-specific copy passed via parameter (cleaner for data-residency
    differences between Azure OpenAI and ElevenLabs — see request §R-8).
  
  The `userDefaultsKey` (`com.local.macrec-ui.transcription.privacyDisclosureAcknowledged`)
  is a single boolean flag. If per-provider disclosure copy is required (R-8), a
  per-provider flag (e.g. `...azure.privacyAcknowledged`, `...elevenlabs.privacyAcknowledged`)
  is needed, OR the sheet is shown fresh for each new provider even if Gemini was already
  accepted.

---

### IP-18 — `ControlBar.startTapped()` — API Key Resolution for UI

- **File**: `Sources/macrec-ui/Views/ControlBar.swift`
- **Lines**: 185–302 (`startTapped` method)

The critical section is lines 253–258 where the API key is resolved:
```swift
// Lines 254–257 (key resolution for Gemini only):
let resolvedTranscriptionApiKey: String? = transcriptionEnabled
    ? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
        .flatMap { $0.isEmpty ? nil : $0 }
    : nil
```

This is **hardcoded to `GOOGLE_API_KEY`** — a known limitation. When `"azure"` or
`"elevenlabs"` is selected, the wrong env-var is consulted and `resolvedTranscriptionApiKey`
will always be `nil`, triggering `transcriptionApiKeyMissing` at session start.

- **What changes**:
  Refactor to a provider-aware lookup:
  ```swift
  let resolvedTranscriptionApiKey: String? = {
      guard transcriptionEnabled else { return nil }
      let envKey: String
      switch normalizedProvider {
      case "gemini", "gemini-live": envKey = "GOOGLE_API_KEY"
      case "azure":                 envKey = "AZURE_OPENAI_API_KEY"
      case "elevenlabs":            envKey = "ELEVENLABS_API_KEY"
      default:                      return nil  // on-device providers
      }
      return ProcessInfo.processInfo.environment[envKey]
          .flatMap { $0.isEmpty ? nil : $0 }
  }()
  ```
  Additionally, Azure requires `endpoint`, `deployment`, and `apiVersion` to be resolved
  and forwarded in `RecordingOptions`. If these are added as stored properties (IP-7), the
  `options = RecordingOptions(...)` call at line 282 must pass them.

---

### IP-19 — `RecordingController.transcriptionMissingKey` — Missing-Key Badge

- **File**: `Sources/MacrecUIKit/RecordingController.swift`
- **Lines**: 129–131

```swift
public private(set) var transcriptionMissingKey: Bool = false
```

Updated in `setOptions(_:)`. The `TranscriptionPicker` reads `recordingController?.transcriptionMissingKey`
(line 63 of `TranscriptionPicker.swift`) to show/hide the red-dot badge.
`missingKeyTooltip` is hardcoded to `"Set GOOGLE_API_KEY in ~/.tool-agents/macrec-ui/.env"`.

- **What changes**:
  `transcriptionMissingKey` logic is set in `RecordingController.setOptions(_:)` based on
  whether `options.transcriptionApiKey == nil` while a cloud provider is active. This works
  unchanged for the new providers — they also set `transcriptionApiKey` from the env chain.
  The `missingKeyTooltip` static string should become provider-aware (or be generalized to
  "Set the provider's API key in ~/.tool-agents/macrec-ui/.env").

---

## 4.1 Out of Scope (modules unaffected by plan-007)

The following modules have no integration point with the two new providers and must not
be modified:

- `Sources/MacrecCore/Capture/` — PCM acquisition is provider-agnostic.
- `Sources/MacrecCore/Aligning/` — frame alignment is upstream of providers.
- `Sources/MacrecCore/Mixing/` — `BufferSummer` is unchanged.
- `Sources/MacrecCore/Encoding/` — audio recorders are independent of transcription.
- `Sources/MacrecCore/Daemon/` — detach mode remains unsupported for transcription.
- `Sources/MacrecCore/Permissions/` — no new TCC permissions required (REST + WebSocket only).
- `Sources/MacrecCore/Bootstrap/` — `ToolAgentsBootstrap` works unchanged; new keys live in existing `.env` files.
- `Sources/MacrecCore/Logging/` — `LoggerFactory` unchanged; new providers use `LoggerFactory.make("macrec.transcription.azure")` etc.
- `Sources/macrec/Commands/StopCommand.swift` — unchanged.
- `Sources/macrec/Commands/ListDevicesCommand.swift` — unchanged.
- `Sources/macrec/Commands/CheckPermissionsCommand.swift` — unchanged.
- `Sources/MacrecCore/Transcription/Persistence/` — sidecar writers are unchanged; both new providers use the existing `.batch` policy and `jsonl`/`srt`/`vtt`/`txt` formats.
- `Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift` — streaming pipeline untouched for batch-only providers.
- `Sources/MacrecCore/Transcription/AudioDownsampler.swift` — used unchanged by the batch pipeline.
- `Sources/MacrecCore/Transcription/AudioWAVEncoder.swift` — used unchanged by new providers to produce the WAV wire format.
- `Sources/MacrecUIKit/SessionCoordinator.swift` — segment lifecycle and sidecar rotation work without change.
- `Sources/MacrecUIKit/LevelMeterPublisher.swift` — unchanged.
- `Sources/macrec-ui/Views/LiveTranscriptPanel.swift` — consumes `TranscriptSegment` events; no provider-specific code.

---

## 5. Notes

- **`TranscriptionProviderId` enum is missing `whisperkit` and will fail resolver
  validation.** The factory (`TranscriptionProviderFactory.swift:83-88`) handles
  `"whisperkit"` via raw string match, but `TranscriptionProviderId` in
  `RecordingOptions.swift:74-79` does NOT have a `.whisperkit` case. This means
  `ConfigResolver.parseEnum(key:raw:default:)` will throw `.invalidConfigValue`
  when `MACREC_TRANSCRIBE=whisperkit` is set — `"whisperkit"` is NOT a valid raw
  value of the enum. Plan-007 should add `.whisperkit` to the enum as part of the
  same PR that adds `.azure` and `.elevenlabs` (pre-existing drift fix).

- **`GeminiKeyField` is hardcoded to Gemini; Azure and ElevenLabs have no equivalent
  UI for inline key entry.** Currently the UI only shows a key-entry field when
  `transcribeProviderRaw` is `"gemini"` (or `"gemini-live"`). New providers need
  either new dedicated views or a generalized `ProviderKeyField` component. Plan-007
  §7 must specify this explicitly to avoid silently shipping providers that require
  env-var-only key setup with no UI affordance.

- **`PrivacyDisclosureSheet.bodyText` is hardcoded to reference "Google's Gemini API"**
  (`PrivacyDisclosureSheet.swift:80-84`). Azure OpenAI has materially different data
  residency (in-Azure-region, no training by default) vs ElevenLabs (US-based,
  different DPA). Plan-007 §R-8 must propose either generalized copy or
  per-provider copy and how the single `privacyAcknowledged` boolean is extended to
  handle multiple cloud providers.

- **`ControlBar.startTapped()` API key lookup is hardcoded to `GOOGLE_API_KEY`
  (line 255).** This is a latent bug for all existing non-Gemini cloud providers
  (including the currently-shipping WhisperKit path, which is on-device and thus
  returns `nil` correctly by accident). Plan-007 must patch this alongside adding
  the new providers (see IP-18 for the fix pattern).
