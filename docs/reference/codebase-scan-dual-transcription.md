---
language: swift
framework: swiftui
package_manager: swift-package-manager
build_command: "swift build --product macrec && swift build --product macrec-ui"
test_command: "swift test"
lint_command: null
entry_points:
  - Sources/macrec/main.swift
  - Sources/macrec-ui/MacrecUIApp.swift
last_scanned_commit: c2e7080d1c0400f67ea0fb78bd6fff3242fa6d40
scanned_for_request: refined-request-dual-transcription.md
scanned_at: "2026-05-01T12:00:00Z"
---

# Codebase Scan — macrec / macrec-ui (Dual Transcription)

> Prior scans already mapped the full module structure and conventions in
> detail. This document narrows to the **integration points** relevant to
> the dual-provider live-transcription feature described in
> `docs/design/refined-request-dual-transcription.md`. Refer to
> `docs/reference/codebase-scan-soniox-streaming.md` for the complete
> module map and conventions, and `docs/reference/codebase-scan-ui-redesign.md`
> for the full UI module and AppStorage inventory.

---

## 1. Project Overview

Swift-only, macOS 26+ SwiftPM workspace (swift-tools-version 6.2, Swift 5
language mode). Three key products: `MacrecCore` (shared domain library),
`macrec` (CLI, ArgumentParser), and `macrec-ui` (SwiftUI menu-bar app,
`LSUIElement = true`, bundle id `com.local.macrec-ui`). A fourth library,
`MacrecUIKit`, isolates UI domain logic (`RecordingController`,
`SessionCoordinator`) from the executable target so unit tests can import it.
The live-transcription subsystem sits entirely in
`Sources/MacrecCore/Transcription/` (pipeline + providers + persistence) and
`Sources/macrec-ui/Views/Transcription/` (UI panel). The dual-transcription
feature adds a second concurrent orchestrator path to this subsystem without
touching audio capture or encoding.

---

## 2. Module Map (transcription-subsystem focus)

| Path | Purpose | Key symbols |
|---|---|---|
| `Sources/MacrecCore/Transcription/TranscriptionProvider.swift` | Provider protocol — every backend conforms to this | `TranscriptionProvider`, `TranscriptionMode` |
| `Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift` | Streaming session protocol + event enum | `StreamingTranscriptionSession`, `StreamingTranscriptionEvent` |
| `Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift` | Per-session streaming orchestrator (actor); drives one provider, one source | `StreamingTranscriptionPipeline` |
| `Sources/MacrecCore/Transcription/TranscriptionManager.swift` | Top-level orchestrator; selects batch vs streaming pipeline; ingests CMSampleBuffer/frames | `TranscriptionManager` |
| `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift` | `switch`-based provider registry; builds concrete providers from `TranscriptionProviderFactoryInput` | `TranscriptionProviderFactory`, `TranscriptionProviderFactoryInput` |
| `Sources/MacrecCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift` | On-device SpeechAnalyzer streaming provider (Channel A) | `AppleSpeechTranscriptionProvider`, `AppleSpeechSession` |
| `Sources/MacrecCore/Transcription/Providers/AppleCloudTranscriptionProvider.swift` | Cloud SFSpeechRecognizer streaming provider (Channel B) | `AppleCloudTranscriptionProvider`, `AppleCloudStreamingSession` |
| `Sources/MacrecCore/Transcription/Persistence/TranscriptSidecarWriter.swift` | Actor-isolated sidecar writer; policy-dispatched (batch vs streaming) | `TranscriptSidecarWriter`, `SidecarPolicy` |
| `Sources/MacrecCore/Transcription/Persistence/TranscriptFormatWriter.swift` | Per-format writer protocol | `TranscriptFormatWriter` |
| `Sources/MacrecCore/Transcription/Persistence/JSONLTranscriptWriter.swift` | JSONL format writer with tombstone-and-append in-place rewrite | `JSONLTranscriptWriter` |
| `Sources/MacrecCore/Transcription/TranscriptSegment.swift` | Per-utterance data model (id, text, source, language, model, durationSec) | `TranscriptSegment` |
| `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift` | SwiftUI panel — renders `transcriptSegments` with language chip, settled/partial treatment | `LiveTranscriptPanel` |
| `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift` | Provider picker; `@AppStorage("com.macrec.ui.transcribeProvider")`; exposes `requiredKeyEnvVar(for:)` | `TranscriptionPicker` |
| `Sources/macrec-ui/Views/Transcription/TranscriptionLanguagePicker.swift` | Primary + secondary + tertiary BCP-47 locale pickers; `@AppStorage` key slots | `TranscriptionLanguagePicker` |
| `Sources/macrec-ui/Views/Transcription/TranscriptionSourcePicker.swift` | Audio source picker; `@AppStorage("com.macrec.ui.transcribeSource")` | `TranscriptionSourcePicker` |
| `Sources/macrec-ui/Views/Transcription/TranscriptionFormatPicker.swift` | Sidecar format picker; `@AppStorage("com.macrec.ui.transcriptFormat")` | `TranscriptionFormatPicker` |
| `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift` | Per-provider privacy disclosure sheet + view-model | `PrivacyDisclosureSheet`, `PrivacyDisclosureViewModel` |
| `Sources/macrec-ui/Views/Transcription/TranscriptionMetricsView.swift` | Per-session cost/latency footer | `TranscriptionMetricsView` |
| `Sources/macrec-ui/Views/Transcription/TranscriptionStatusBadge.swift` | Active/Error pill badge | `TranscriptionStatusBadge` |
| `Sources/macrec/Commands/StartCommand.swift` | CLI `start` subcommand; all `--transcribe*` flags live here | `StartCommand` |
| `Tests/MacrecCoreTests/Transcription/` | Unit tests for pipeline, providers, persistence | `StreamingTranscriptionPipelineTests`, provider suites |
| `Tests/MacrecUITests/Transcription/` | UI tests for panel, picker, disclosure | `LiveTranscriptPanelTests`, `TranscriptionPickerTests`, `PrivacyDisclosureTests` |

---

## 3. Conventions

(Unchanged from prior scans — see `codebase-scan-soniox-streaming.md §3` for
the full list. Key points repeated for this scan's consumers.)

- **`@Suite` / `@Test` / `#expect`** — Swift Testing framework throughout; not XCTest.
  (`Tests/MacrecCoreTests/Transcription/StreamingTranscriptionPipelineTests.swift`)

- **`actor` isolation for streaming sessions.** `AppleCloudStreamingSession` is
  a Swift `actor`; `StreamingTranscriptionPipeline` is `final actor`. Dual mode
  must follow the same pattern for the orchestrator that runs two sessions.
  (`Sources/MacrecCore/Transcription/Providers/AppleCloudTranscriptionProvider.swift:186`)

- **`AsyncStream.makeStream` + `.bufferingNewest(N)` for event flow.** Every
  pipeline creates its public `AsyncStream<TranscriptionEvent>` via
  `makeStream` and drives it via `eventsContinuation`. Dual mode will produce
  ONE merged public stream from TWO per-channel private streams.
  (`Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift:87-92`)

- **`String(localized:)` for all user-visible text.** Every label, button, and
  help string in the UI layer uses `String(localized:)`.
  (`Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift:87`)

- **No `#Preview` blocks.** CLI toolchain (`swift build`) is canonical; Xcode
  previews are intentionally omitted across the UI layer.
  (`Sources/macrec-ui/Views/FilenameField.swift:62-67`)

- **File header comment convention.** Every source file opens with:
  `// <target>/<file>.swift — see project-design.md §<section>, plan-<N>-*.md §<phase> (<FR-NN>)`.

---

## 4. Integration Points

### 4.1 In-Scope Touch Points

---

#### IP-1 — Provider Protocol + Both Provider Conformers

**File:** `Sources/MacrecCore/Transcription/TranscriptionProvider.swift:29-44`

The `TranscriptionProvider` protocol is the contract both providers must satisfy.
Both `apple` and `apple-cloud` already fully conform and declare
`supportedModes = [.streaming]`.

- **`AppleSpeechTranscriptionProvider`** (`Sources/MacrecCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift`) — Channel A. Wraps macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`. Supports up to two locales via `languageHints[0]` and `languageHints[1]` in `TranscriptionOptions`. On `openStreamingSession(source:options:)` it returns an `AppleSpeechSession` actor. The session exposes `events: AsyncStream<StreamingTranscriptionEvent>`.

- **`AppleCloudTranscriptionProvider`** (`Sources/MacrecCore/Transcription/Providers/AppleCloudTranscriptionProvider.swift:35-177`) — Channel B. Wraps `SFSpeechRecognizer` with `requiresOnDeviceRecognition = false`. **Single-locale per session** (locale-pinned at `openStreamingSession`; lines 100-107). Auto-rotates the underlying `SFSpeechRecognitionTask` every 55 s (`AppleCloudStreamingSession:318-356`) to stay under Apple's 60 s per-task cap (QA1951). Authorisation branch at lines 132-152: safe only from a `.app` bundle; raw CLI raises a clear error (NFR-7 from the request). Session type: `AppleCloudStreamingSession` (actor, lines 186-481).

**Dual-mode implication:** The dual orchestrator must construct ONE `AppleSpeechTranscriptionProvider` (Channel A, `en-US` locale in `options.languageHints[0]`) and ONE `AppleCloudTranscriptionProvider` (Channel B, `el-GR` in `options.languageHints[0]`) separately and call `openStreamingSession` on each. Neither provider needs modification.

---

#### IP-2 — `StreamingTranscriptionPipeline` — Current Single-Provider Orchestrator

**File:** `Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift:50-257`

Key internals that dual mode must understand:

- `sessions: [SourceTag: any StreamingTranscriptionSession]` (line 57) — maps audio source tags to open sessions. Today one provider means one or two sessions (e.g. `.system` + `.microphone` for `TranscriptionSource.both`).
- `attach(session:for:)` (lines 175-184) — registers a session and spawns a per-session drain `Task` that ranges over `session.events` and calls `handle(_:from:)`.
- `handle(_:from:)` (lines 190-256) — translates `StreamingTranscriptionEvent` → `TranscriptionEvent` and yields into `eventsContinuation`. Uses `indexForUtteranceId: [UUID: Int]` to correlate partial/final pairs across events.
- `ingest(_:from:)` (lines 117-122) — routes downsampled Float32 samples to `sessions[tag]`. Fire-and-forget if the session is not yet attached.

**Dual-mode implication:** The dual orchestrator must either:
  (a) subclass/replace `StreamingTranscriptionPipeline` with a `DualStreamingTranscriptionPipeline` that holds two provider+session pairs, or
  (b) introduce a thin "tee" wrapper that feeds the same samples to both pipelines' `ingest` methods while merging their event streams into one.

Option (b) is lower-risk (no changes to existing pipeline). The tee must be an `actor` (or otherwise isolated) so it serialises the dual `ingest` calls without blocking capture.

The `nextSegmentIndex` and `indexForUtteranceId` state (lines 59-60) are per-pipeline; in the dual case each channel needs its own index space so segments from Channel A and Channel B are independently numbered (or globally monotonically increasing with a channel tag stamped on each `TranscriptSegment`).

---

#### IP-3 — `TranscriptionManager` — Top-Level Audio Ingestion Entry Point

**File:** `Sources/MacrecCore/Transcription/TranscriptionManager.swift:24-426`

This is the surface that `RecordingSession` calls. Key methods:

- `start() async -> AsyncStream<TranscriptionEvent>` (line 132) — starts either the batch or streaming pipeline. Returns the event stream consumed by the UI.
- `ingest(_ samples: [Float], from tag: SourceTag)` (line 173) — receives downsampled Float32 buffers from the capture graph. For streaming providers it delegates to `streamingPipeline?.ingest(samples, from: tag)`.
- `ingestFrame(_ frame: AlignedFrame, from tag: SourceTag)` (lines 190-206) — higher-level entry: receives a `CMSampleBuffer`-backed `AlignedFrame`, downsamples, and calls `ingest`.
- `stop() async` (line 243), `rotateSidecar(toAudioURL:format:)` (line 213), `currentMetrics() async` (line 286).

**Dual-mode implication:**

`TranscriptionManager` today holds ONE `private let provider` (line 51) and ONE optional `streamingPipeline` (line 73). A `DualTranscriptionManager` must either:
  (a) hold TWO providers + TWO pipelines and fan both `ingest` calls, merging two event streams, or
  (b) hold a single `DualStreamingTranscriptionPipeline` that internally manages both.

The `RecordingSession` → `TranscriptionManager` contract (constructed at session start with a single factory-built provider) must be generalised. The cleanest approach is a new `DualTranscriptionManager` (a distinct type that mirrors the same public surface: `start()`, `ingest`, `ingestFrame`, `stop`, `rotateSidecar`, `currentMetrics`) so the existing `TranscriptionManager` is unchanged (NFR-1 single-mode preservation).

---

#### IP-4 — Audio Fan-Out — How the Same Samples Reach a Second Consumer

**File:** `Sources/MacrecCore/Transcription/TranscriptionManager.swift:190-206` (ingestFrame)

Today the capture graph delivers `AlignedFrame` values (containing `systemBuffer: CMSampleBuffer?` and `micBuffer: CMSampleBuffer?`) to one `TranscriptionManager`. The downsampler (`AudioDownsampler`) inside the manager converts the `CMSampleBuffer` to `[Float]` and calls `ingest(_:from:)`.

`AudioDownsampler` is **not thread-safe** — one instance per session (per the Soniox scan §4.1.F). It converts 48 kHz Float32 non-interleaved → 16 kHz mono Int16 LE Data → Float32. Each provider channel needs its own `AudioDownsampler` instance.

**Current single-consumer fan-out path:**
```
RecordingSession
  └─ TranscriptionManager.ingestFrame(AlignedFrame)
       └─ AudioDownsampler.convert(AVAudioPCMBuffer) → [Float]
       └─ StreamingTranscriptionPipeline.ingest([Float], from: SourceTag)
            └─ AppleSpeechSession.ingest([Float])      (or AppleCloudStreamingSession)
```

**Dual fan-out required for FR-5 (identical frames to both channels):**
```
RecordingSession
  └─ DualTranscriptionManager.ingestFrame(AlignedFrame)
       ├─ AudioDownsampler_A.convert(buffer) → [Float]
       │    └─ pipelineA.ingest([Float], from: tag)   → AppleSpeechSession
       └─ AudioDownsampler_B.convert(buffer) → [Float]
            └─ pipelineB.ingest([Float], from: tag)   → AppleCloudStreamingSession
```

Note: `convert(buffer)` on `AudioDownsampler` is not `async` — it is a synchronous conversion. The `DualTranscriptionManager` can call both sequentially on the actor or dispatch to two tasks with bounded channel buffers (NFR-3 backpressure requirement). The per-channel `Task` approach avoids one slow consumer stalling the capture graph.

Each provider may require different audio formats downstream — `AppleCloudStreamingSession.ingest` wraps Float32 samples into `AVAudioPCMBuffer` at 16 kHz (line 263-283); `AppleSpeechSession` feeds `SpeechAnalyzer`'s `AnalysisInput`. Both start from the same `[Float]` 16 kHz representation, so the shared `AudioDownsampler` output is compatible. **Two `AudioDownsampler` instances are required** because the type's internal state (accumulator) is not thread-safe to share.

---

#### IP-5 — `StreamingTranscriptionPipeline` — pause/resume/split semantics

**File:** `Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift:149-161`

`stop()` calls `session.finish()` on all sessions then awaits all drain tasks. There is no explicit `pause()` / `resume()` on the pipeline today (pause is handled at the `RecordingSession` level by stopping the capture graph's delivery of new frames; the pipeline naturally goes quiet when `ingest` is not called).

`rotateSidecar(toAudioURL:format:)` (lines 129-144) replaces the sidecar writer and resets `nextSegmentIndex` + `indexForUtteranceId`.

**Dual-mode implication for FR-11 (atomic pause/resume/split):** The dual orchestrator must apply `stop()`, `rotateSidecar`, and the equivalent of `pause` to BOTH pipelines atomically. Since pause is frame-delivery level (not pipeline level), atomic pause is achieved by ensuring neither pipeline's `ingest` is called after the pause point — which is natural if both share the same `ingestFrame` call site in the dual manager. Split (`rotateSidecar`) must be called on BOTH channel pipelines, producing two sidecar file rotations that share the same audio segment timestamp.

---

#### IP-6 — `TranscriptSidecarWriter` + `TranscriptFormatWriter` — Channel Tagging

**File:** `Sources/MacrecCore/Transcription/Persistence/TranscriptSidecarWriter.swift:65-248`

The current writer is single-channel. It dispatches on `SidecarPolicy` (`.batch` or `.streaming`). For streaming providers (both Apple providers are `.streaming`), it calls `formatWriter.appendSegment(segment)` once per `.segmentFinalized` event (line 152).

**`TranscriptSegment` fields today** (`TranscriptSegment.swift:4-36`):
```swift
public let id: UUID
public let timestamp: Date
public var lastUpdated: Date
public var text: String
public let source: SourceTag   // .system or .microphone
public let confidence: Float?
public let model: String?      // e.g. "apple", "apple-cloud"
public let durationSec: Double?
public let language: String?   // BCP-47, e.g. "en-US", "el-GR"
```

The `model` field already distinguishes the two providers (`"apple"` vs `"apple-cloud"`). The `language` field carries the BCP-47 locale per segment. **No schema change to `TranscriptSegment` is needed for channel tagging** — the existing `model` + `language` fields are sufficient to identify which channel produced which segment.

**For the JSONL writer** (`JSONLTranscriptWriter.swift:122-143`), the `Wire` struct already encodes `model` and `language`. A dual-channel JSONL sidecar is structurally the same as today's file — segments from both channels interleave in arrival order, each tagged with `"model":"apple"/"apple-cloud"` and `"language":"en-US"/"el-GR"`.

**For SRT/VTT writers**, dual-channel labelling requires a convention choice (OQ-4 in the request). The `SRTTranscriptWriter` and `VTTTranscriptWriter` must be inspected; however, since the request specifies channel + locale in cue speaker tags, the segment's `model` and `language` fields can supply that information — a thin wrapper around `appendSegment` that inserts speaker syntax needs to go into the format writers.

**Key decision for the design phase:** Dual mode writes ONE merged sidecar file (FR-7), not two separate files. The `DualTranscriptionManager` routes `.segmentFinalized` events from BOTH channels into ONE `TranscriptSidecarWriter` instance. The writer receives segments tagged by `model` and `language` from both channels without any writer changes — the existing `appendSegment` path writes them in arrival order.

**Writer construction:** The dual mode must pass `.streaming` policy (same as the single-provider streaming path). The sidecar path is computed by `SidecarPathBuilder.sidecarURL(forRecording:format:)` — no changes needed here.

---

#### IP-7 — `PrivacyDisclosureViewModel` + `PrivacyDisclosureSheet` — Cloud Disclosure for Dual Mode

**File:** `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift:30-301`

`PrivacyDisclosureViewModel` is per-provider keyed under:
`"com.local.macrec-ui.transcription.privacy.<providerId>.acknowledged"`

For `apple-cloud` (line 48-49):
```swift
public static func acknowledgedKey(for providerId: String) -> String {
    "com.local.macrec-ui.transcription.privacy.\(providerId).acknowledged"
}
```

The disclosure sheet for `apple-cloud` is already implemented (lines 288-300: `appleCloudBodyText`). The headline is "Live transcription will use Apple's Speech Recognition cloud" (line 190).

**Dual-mode implication (FR-8):** When the user selects Dual mode for the first time, the disclosure must fire for `apple-cloud` if it has not been previously acknowledged (even if the user has used `apple` single-mode before). The gate logic in `RootView` today checks the disclosure per-provider when the picker changes. For dual mode:
- If `apple-cloud` is already acknowledged: no disclosure needed.
- If `apple-cloud` is NOT acknowledged: the existing `apple-cloud` disclosure sheet fires (using the existing `appleCloudBodyText`).
- No new disclosure text is required — `apple-cloud` is the cloud channel and its disclosure already covers the privacy posture.

The `RootView` currently reads `@AppStorage("com.macrec.ui.transcribeProvider")` and fires the disclosure when it changes to a cloud provider. The new "Dual" mode selection will need to trigger a check for `"apple-cloud"` disclosure state regardless of whether the single-mode provider is also `"apple-cloud"`.

**Touch point:** The `RootView` `.onChange` on `transcribeProviderRaw` that presents `PrivacyDisclosureSheet` — this logic must also fire when the mode switch flips to "Dual", passing `selectedProvider: "apple-cloud"`.

---

#### IP-8 — `TranscriptionPicker` + Single-Mode Controls — MUST NOT CHANGE

**File:** `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift:42-130`

The eight-provider picker is the Single-mode control that must remain pixel-identical (FR-2, hard constraint). The `@AppStorage` key `"com.macrec.ui.transcribeProvider"` with default `"apple"` (line 52) and all 9 `Text(...).tag(...)` rows (lines 105-113) must be preserved exactly.

`requiredKeyEnvVar(for:)` (lines 77-85) already handles `"apple-cloud"` returning `nil` (no API key required for cloud-path Apple). `missingKeyTooltip(for:)` (lines 90-95) similarly returns `""` for no-key providers. **No change to `TranscriptionPicker` is needed for dual mode** — it is the single-mode control and must be wrapped verbatim inside a conditional block when the mode switch is on "Single".

---

#### IP-9 — `TranscriptionLanguagePicker` — Existing Dual-Locale Pattern (Apple Single-Mode)

**File:** `Sources/macrec-ui/Views/Transcription/TranscriptionLanguagePicker.swift:61-391`

The existing picker already has a dual-locale concept for the `apple` single-mode provider — a toggle "Add a second language (Apple dual-locale)" (lines 223-234) that exposes a secondary `@AppStorage("com.macrec.ui.transcribeLanguage2")` slot. This mechanism is separate from and must not be confused with the new Dual-provider mode.

For the new Dual-provider mode, each channel's locale is independently selectable:
- Channel A locale: English variants from `SpeechTranscriber.supportedLocales` (macOS 26 `SpeechAnalyzer` set — 42 locales, all English variants present, no Greek).
- Channel B locale: `SFSpeechRecognizer.supportedLocales()` (~57 locales, includes `el-GR`).

New `@AppStorage` keys are needed for the Dual panel — separate from the Single-mode keys. Reusing `transcribeLanguage` / `transcribeLanguage2` for Dual-mode channel locales would corrupt Single-mode state on round-trip (AC-2).

**Recommended new AppStorage keys for Dual mode:**
- `"com.macrec.ui.dual.channelALocale"` — default `"en-US"`
- `"com.macrec.ui.dual.channelBLocale"` — default `"el-GR"`
- `"com.macrec.ui.dual.source"` — default `"mixed"` (audio source for Dual mode; separate from Single-mode `"com.macrec.ui.transcribeSource"`)
- `"com.macrec.ui.dual.transcriptFormat"` — default `"jsonl"` (format for Dual sidecar; separate from Single `"com.macrec.ui.transcriptFormat"`)
- `"com.macrec.ui.transcriptionMode"` — `"single"` / `"dual"`, default `"single"` (the mode switch itself)

---

#### IP-10 — `ControlBar` — `startTapped()` — Where `RecordingOptions` Is Assembled

**File:** `Sources/macrec-ui/Views/ControlBar.swift` (referenced from `codebase-scan-ui-redesign.md §4c`)

`startTapped()` reads the ten `@AppStorage` keys and builds `RecordingOptions`. For Dual mode, `startTapped()` must read the mode switch key and branch:
- If `"single"`: existing code path unchanged (reads `transcribeProvider`, `transcribeSource`, `transcribeLanguage`, `transcribeLanguage2`, `transcriptFormat` as today).
- If `"dual"`: reads `dual.channelALocale`, `dual.channelBLocale`, `dual.source`, `dual.transcriptFormat` and constructs a `RecordingOptions` that signals to the engine to start Dual mode.

The cleanest signal is a new value in `TranscriptionProviderId` — e.g. `"dual"` — that the factory recognises and builds a `DualTranscriptionManager` instead of a single `TranscriptionManager`. Alternatively, a dedicated flag on `RecordingOptions` (`isDualMode: Bool`) plus two locale fields keeps the factory interface minimal.

**Existing ten `@AppStorage` keys read at start (from codebase-scan-ui-redesign.md §4c):**
The keys enumerated in the prior scan must NOT be renamed or removed (acceptance criterion 11 of the redesign, which is still in force). Dual mode's new keys are additive.

---

#### IP-11 — `StartCommand` (CLI) — Existing `--transcribe*` Flags

**File:** `Sources/macrec/Commands/StartCommand.swift:88-115`

Current live-transcription flags:
- `--transcribe <id>` (line 95): `none | apple | gemini | whisperkit | soniox | azure | azure-openai-realtime | elevenlabs`. Env: `MACREC_TRANSCRIBE`.
- `--transcribe-source <src>` (line 98): `system | mic | mixed | both`. Env: `MACREC_TRANSCRIBE_SOURCE`.
- `--transcribe-format <fmt>` (line 101): `jsonl | srt | vtt | txt`. Env: `MACREC_TRANSCRIBE_FORMAT`.
- `--transcribe-model <id>` (line 104). Env: `MACREC_TRANSCRIBE_MODEL`.
- `--transcribe-language <bcp47>` (line 107). Env: `MACREC_TRANSCRIBE_LANGUAGE`.
- `--transcribe-key-expires-at <iso8601>` (line 110). Env: `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`.
- `--soniox-endpoint <url>` (line 113). Env: `MACREC_SONIOX_ENDPOINT`.

**No `--transcribe-key` flag exists** (by design — API keys are env-var only).

**Dual-mode CLI surface (FR-10, OQ-3):** The design phase must choose between:

Option A (extend `--transcribe`):
```
macrec start --transcribe dual --transcribe-source mixed \
  --transcribe-dual-locale-a en-US \
  --transcribe-dual-locale-b el-GR \
  --transcribe-format jsonl
```
Adds `--transcribe-dual-locale-a` and `--transcribe-dual-locale-b` flags to `StartCommand`. `--transcribe-language` remains Single-mode only. Env vars: `MACREC_TRANSCRIBE_DUAL_LOCALE_A`, `MACREC_TRANSCRIBE_DUAL_LOCALE_B`.

Option B (reuse `--transcribe-language` + secondary):
```
macrec start --transcribe dual --transcribe-source mixed \
  --transcribe-language en-US \
  --transcribe-language2 el-GR \
  --transcribe-format jsonl
```
Reuses existing language slots; less flag surface but ambiguous with Apple single-mode dual-locale.

Option A is cleaner and unambiguous. The `buildCLIOverrides()` function (line ~216) forwards these to `ConfigResolver` keys. New constants needed in `ConfigResolver.Keys`.

---

#### IP-12 — `TranscriptionProviderFactory` — Factory Extension Point

**File:** `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift:108-300`

Today the factory returns `any TranscriptionProvider`. For dual mode the factory needs to return TWO providers (or a composite). Options:

Option A: Add `case "dual":` to the switch that returns a `DualTranscriptionProvider` composite (which holds both child providers and multiplexes `openStreamingSession` → two sessions).

Option B: Dual mode is handled upstream (in `RecordingSession` or a new `DualTranscriptionManager`) — the factory is called twice with `"apple"` and `"apple-cloud"` separately.

Option B is less invasive (factory contract unchanged). The `DualTranscriptionManager` calls `TranscriptionProviderFactory.build(...)` twice with distinct inputs (locales passed via `languageHints`).

The factory's `default:` error message (line 297) lists all accepted provider IDs. If `"dual"` is added as a valid `providerId` for the CLI, it must be added to this message. If dual mode is handled entirely in the manager without a factory `"dual"` case, the message remains unchanged.

---

#### IP-13 — `LiveTranscriptPanel` — Channel Lane Rendering

**File:** `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift:20-203`

The panel today renders `recordingController.transcriptSegments` as a flat `VStack` of `segmentView(_:)` rows. Each row shows an optional language chip (`segment.language?.prefix(2).uppercased()`) and the segment text, with italic/secondary treatment for unfinished segments.

For Dual mode (FR-6), the panel must render two visually distinct lanes. The existing `model` field on `TranscriptSegment` (`"apple"` vs `"apple-cloud"`) distinguishes channels. The `language` field carries the locale.

**Key observations:**
- `segments` today is `[TranscriptSegment]` with NO explicit channel tag beyond `model`. The existing language chip already provides per-segment identification.
- For Dual mode, the panel must EITHER partition `transcriptSegments` into two sub-arrays (by `model`) and render two side-by-side or stacked lanes, OR render them interleaved with a stronger per-row channel indicator (coloured chip or label per OQ-5).
- `RecordingController.transcriptSegments` is the published property the panel reads. It does NOT need to be changed in shape — the dual orchestrator emits the same `TranscriptionEvent.segmentFinalized` events as the single-mode pipeline; the segment's `model` field identifies the channel.

**What DOES need to change:** The panel must know it is in Dual mode to render two lanes instead of one. A new published property on `RecordingController` (e.g. `isDualTranscriptionMode: Bool`) or reading the same mode `@AppStorage` key from the panel can toggle the rendering path.

The header "Transcript" label (line 74) and the "Clear transcript" button (lines 79-89) remain as-is for both modes. The scroll container (lines 103-130) splits into two in Dual mode.

---

#### IP-14 — `RecordingController` (`MacrecUIKit`) — Published Properties Surface

**File:** `Sources/MacrecUIKit/RecordingController.swift` (not read in this scan; referenced from `codebase-scan-ui-redesign.md §4k`)

Properties the panel and `ControlBar` depend on and their dual-mode extension needs:

| Property | Current shape | Dual-mode extension |
|---|---|---|
| `transcriptSegments: [TranscriptSegment]` | Flat list, single provider | No shape change; `model` field distinguishes channels |
| `transcriptionStatus: TranscriptionUIState` | Single provider status | Needs to surface per-channel status OR a compound dual status |
| `transcriptionMissingKey: Bool` | Single-provider API key flag | Dual mode: `apple` = no key; `apple-cloud` = no key; always `false` for both |
| `transcriptionMetrics: TranscriptionMetrics` | Single-provider metrics | Needs per-channel metrics OR compound struct |
| `latestError: MacrecError?` | Single error | Dual mode: errors must be per-channel (FR-4 channel isolation) |

The dual-mode design phase (Phase 5) must decide whether to extend `RecordingController` with per-channel variants or to add a `dualChannelStates: [DualChannelState]` array. The simplest approach that avoids breaking existing tests is to add a new optional `dualMetrics: (channelA: TranscriptionMetrics, channelB: TranscriptionMetrics)?` alongside the existing `transcriptionMetrics` property, and a `dualErrors: (channelA: String?, channelB: String?)?` for per-channel error display.

---

#### IP-15 — `PrivacyDisclosureSheet` — `apple-cloud` Body Text Already Present

**File:** `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift:288-300`

The `appleCloudBodyText` static property already exists and covers the Apple Cloud privacy posture accurately (mentions 1,000 req/hr quota, 55 s rotation, Apple privacy policy). No new disclosure text is needed for Dual mode — the existing `apple-cloud` disclosure is reused verbatim (FR-8).

The acknowledged key `"com.local.macrec-ui.transcription.privacy.apple-cloud.acknowledged"` is computed by `acknowledgedKey(for: "apple-cloud")`. Dual mode checks this key before recording starts; if unset, it presents `PrivacyDisclosureSheet(selectedProvider: "apple-cloud", ...)`.

---

#### IP-16 — Test Infrastructure — Existing Tests That Must Not Break

| File | What it tests | Dual-mode risk |
|---|---|---|
| `Tests/MacrecCoreTests/Transcription/StreamingTranscriptionPipelineTests.swift` | Single-pipeline start/ingest/stop/handle lifecycle | Low — tests use `FakeTranscriptionProvider`; dual adds a new type |
| `Tests/MacrecCoreTests/Transcription/Providers/AppleSpeechTranscriptionProviderTests.swift` | `AppleSpeechTranscriptionProvider` with `MockSpeechAnalyzer` | No change needed |
| `Tests/MacrecUITests/Transcription/LiveTranscriptPanelTests.swift` | Panel auto-scroll, segment cap, isSettled | Medium — panel will gain new rendering modes; tests must not be broken by the dual path |
| `Tests/MacrecUITests/Transcription/TranscriptionPickerTests.swift` | `requiredKeyEnvVar(for:)` + `missingKeyTooltip(for:)` static helpers | No change to `TranscriptionPicker` itself |
| `Tests/MacrecUITests/Transcription/PrivacyDisclosureTests.swift` | `PrivacyDisclosureViewModel` round-trip, per-provider flags | Low — `"apple-cloud"` key already tested |
| `Tests/MacrecCoreTests/Transcription/Persistence/` | Sidecar writers (JSONL, SRT, VTT, TXT) | Low — writer contract unchanged; dual adds segments tagged by `model` |
| `Tests/MacrecCoreTests/Transcription/Providers/TranscriptionProviderFactoryTests.swift` | Factory build for each provider | Low if factory is not modified for dual |

**New tests to create (AC-10):**
- `Tests/MacrecCoreTests/Transcription/DualStreamingPipelineTests.swift` — fan-out delivers identical `[Float]` buffers to both channel pipelines; verify via mock sessions that `ingest` is called on both.
- `Tests/MacrecCoreTests/Transcription/DualChannelIsolationTests.swift` — inject a failing session for Channel B; assert Channel A continues to emit `segmentFinalized` events and recording is not terminated.
- `Tests/MacrecCoreTests/Transcription/Persistence/DualSidecarWriterTests.swift` — feed `.segmentFinalized` events with `model = "apple"` and `model = "apple-cloud"` to one `TranscriptSidecarWriter`; assert all four format outputs include channel-labelled entries from both.

---

### 4.2 Out-of-Scope Modules

These modules are NOT implicated by the dual-transcription feature:

- `Sources/MacrecCore/Capture/` — audio capture graph (`ScreenCaptureKit` + `AVFoundation`). Dual mode consumes existing capture output via a fan-out downstream of capture; capture is not modified.
- `Sources/MacrecCore/Encoding/` — M4A/WAV/CAF encoders. Sidecar output is orthogonal to audio encoding.
- `Sources/MacrecCore/Daemon/` — daemonizer for `--detach` mode. Detach semantics are the same regardless of transcription mode.
- `Sources/MacrecCore/Mixing/` — mix/split routing. Dual mode uses one audio source (user-selected); no mix topology changes.
- `Sources/MacrecCore/Aligning/` — `HostClockAligner`; provider-independent.
- `Sources/MacrecCore/Transcription/SegmentCoalescer.swift` — used by the batch pipeline only; both Apple providers are streaming and do not use the coalescer.
- `Sources/MacrecCore/Transcription/TranscriptSanitizer.swift` — provider-agnostic; untouched.
- `Sources/MacrecCore/Transcription/SourceBuffer.swift` — batch-pipeline buffer; streaming path does not use it.
- `Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift` — not used by Dual mode.
- `Sources/MacrecCore/Transcription/Providers/WhisperKitTranscriptionProvider.swift` — not used by Dual mode.
- All Soniox, Azure, ElevenLabs provider files — not used by Dual mode.
- `Sources/macrec-ui/Settings/` — settings dialog. No new settings category is needed for dual mode (no API keys, no per-provider settings beyond what is in the popover panel).
- `Sources/MacrecUIKit/SessionCoordinator.swift` — coordinator invokes `RecordingController`; may need a minor update to handle dual-mode start, but is otherwise unchanged.
- `Sources/macrec-ui/Views/` (non-transcription views) — `ControlBar` buttons, `LevelMeterView`, `FilenameField`, `FormatPicker`, `LayoutPicker`, `FolderPicker`, `MicrophonePicker`, `ResizeHandle` — all unchanged.

---

### 4.3 New Integration Points (artifacts to create)

| Artifact | Landing location | Notes |
|---|---|---|
| `DualTranscriptionManager` | `Sources/MacrecCore/Transcription/DualTranscriptionManager.swift` | New actor; mirrors `TranscriptionManager` public surface; holds two providers + two pipelines; merges two event streams; fans-out `ingestFrame` to two `AudioDownsampler` instances |
| `DualStreamingTranscriptionPipeline` (optional) | `Sources/MacrecCore/Transcription/DualStreamingTranscriptionPipeline.swift` | If dual logic is extracted from the manager; may be subsumed into `DualTranscriptionManager` directly |
| New `@AppStorage` keys in `ControlBar` | `Sources/macrec-ui/Views/ControlBar.swift` (at `startTapped()`) | `"com.macrec.ui.transcriptionMode"`, `"com.macrec.ui.dual.channelALocale"`, `"com.macrec.ui.dual.channelBLocale"`, `"com.macrec.ui.dual.source"`, `"com.macrec.ui.dual.transcriptFormat"` |
| `DualTranscriptionPanel` (or dual branch in `LiveTranscriptPanel`) | `Sources/macrec-ui/Views/Transcription/` | SwiftUI view rendering two channel lanes; may be a new `DualLiveTranscriptView.swift` composed alongside the existing `LiveTranscriptPanel` |
| Mode switch control | `Sources/macrec-ui/RootView.swift` (or a new `TranscriptionModeSwitch.swift`) | Segmented control or toggle `"Single"` / `"Dual"` inserted at the top of the Live Transcription disclosure group |
| Dual-mode control set view | `Sources/macrec-ui/Views/Transcription/DualTranscriptionControls.swift` | Source picker, Channel A locale picker (constrained to Apple on-device locales), Channel B locale picker (constrained to `SFSpeechRecognizer.supportedLocales()`), format picker |
| Per-channel metrics + error display in `RecordingController` | `Sources/MacrecUIKit/RecordingController.swift` | New published properties: `dualMetrics`, `dualChannelErrors` (or similar) |
| New CLI flags in `StartCommand` | `Sources/macrec/Commands/StartCommand.swift` | `--transcribe-dual-locale-a`, `--transcribe-dual-locale-b` (if Option A flag spelling is chosen in Phase 5) |
| New `ConfigResolver.Keys` constants | `Sources/MacrecCore/Config/ConfigResolver.swift` | `MACREC_TRANSCRIBE_DUAL_LOCALE_A`, `MACREC_TRANSCRIBE_DUAL_LOCALE_B` |
| `TranscriptionProviderId.dual` (optional) | `Sources/MacrecCore/Config/RecordingOptions.swift` | Only if factory-dispatch approach chosen; otherwise not needed |
| `DualStreamingPipelineTests.swift` | `Tests/MacrecCoreTests/Transcription/` | Fan-out delivers to both channels; isolation test |
| `DualSidecarWriterTests.swift` | `Tests/MacrecCoreTests/Transcription/Persistence/` | Two-channel sidecar output for all four formats |

---

## 5. Notes

- **`AppleCloudStreamingSession` is locale-pinned at construction.** Each session is tied to one `SFSpeechRecognizer(locale:)` instance. For Dual mode the `el-GR` session is a dedicated `AppleCloudStreamingSession` with Greek — no changes to the provider or session are needed. The user cannot change Channel B's locale while a recording is in progress (the provider throws `transcriptionPermissionDenied` if auth is missing; the session is locale-immutable after `open()`).

- **`SpeechAnalyzer` (Channel A) does NOT support Greek.** The apple provider's locale set excludes `el-GR` at macOS 26 launch (`SpeechTranscriber.supportedLocales` has 42 locales, Greek absent — confirmed in `docs/reference/apple-cloud-stt-investigation-2026-05.md §Q5`). The Channel A locale picker must be constrained to English variants and other `SpeechTranscriber.supportedLocales` members only. The existing `TranscriptionLanguagePicker` populates its list from `SFSpeechRecognizer.supportedLocales()` (which INCLUDES Greek) — the Dual-mode Channel A picker must use `SpeechTranscriber.supportedLocales` instead.

- **The `apple-cloud` SIGABRT-on-raw-binary caveat (NFR-7) applies unchanged to Dual mode.** `AppleCloudTranscriptionProvider.openStreamingSession` checks `isRunningFromAppBundle()` (line 66-72) and raises a clear error for raw CLI launches. This error surface is already implemented and reused by Dual mode's Channel B without modification.

- **`TranscriptionMetrics` is a single struct** (`Sources/MacrecCore/Transcription/TranscriptEvent.swift` or `TranscriptionOptions.swift`). The dual orchestrator will need either to merge metrics into a combined struct (for existing UI path) or expose two separate `TranscriptionMetrics` instances for the per-channel latency/cost indicators (FR-9). The simpler v1 approach is a merged aggregate for the existing badge and a new per-channel pair for the Dual panel only.

- **`ControlBarStartTappedKeysRegressionTests.swift`** (`Tests/MacrecUITests/`) validates that all ten Single-mode `@AppStorage` keys survive across `startTapped()` refactors. Any new dual-mode keys added to `startTapped()` must not collide with existing keys or the test will catch it. This test is a useful regression guard for the Single-mode preservation constraint (NFR-1, FR-2).
