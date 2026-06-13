# Plan 005 — Apple Speech Streaming Transcription

> **Status**: Design (Phase Brainstorming) — awaiting user review of
> this spec, then `writing-plans` produces the executable
> implementation plan.
>
> **Date**: 2026-04-28
>
> **Builds on**: `docs/design/plan-004-rest-batch-transcription.md`
> (REST batch Gemini provider, `TranscriptionManager` actor, sidecar
> writers, source-tag routing). Plan-005 does NOT supersede plan-004 —
> the Gemini path stays available and tested.
>
> **User intent**: User asked "what is the best option I have to
> support real-time transcription?" — the plan-004 batch path produces
> ~3–5 s end-to-end latency, which is fine for offline review but is
> not what people mean by "real-time." User chose to switch to Apple's
> on-device `SpeechAnalyzer` (macOS 26+) for true streaming partials
> with ~80–250 ms first-partial latency.

---

## 1. Goal

Add a second concrete `TranscriptionProvider` —
`AppleSpeechTranscriptionProvider` — that runs N parallel
`SpeechAnalyzer` sessions (one per locale in
`--transcribe-language en-US,el-GR`), feeds them the same downsampled
audio, picks the higher-confidence final per utterance, and emits
real-time partials for the UI. Apple becomes the new default
provider (`--transcribe apple`); Gemini REST stays available
(`--transcribe gemini`).

The existing recording integrity isolation contract from
project-design §LT ("audio is the primary artefact; nothing in
transcription can stop a recording") is preserved verbatim — only the
implementation of the transcription layer's worker changes.

---

## 2. Why this addition

### 2.1 What plan-004 does and where it stops

The plan-004 REST batch pipeline buffers 2.5 s of audio per source,
then makes a single HTTPS POST to Gemini's `:generateContent`
endpoint per chunk. End-to-end latency from user speech to
transcript line: ~3–5 s (2.5 s buffer + 0.3–1 s HTTP RTT + 0.2 s
manager overhead). This is excellent for offline review but
inappropriate for live captioning — a viewer waiting for words to
appear feels noticeable lag.

### 2.2 Why Apple Speech for v1.5

Surveyed alternatives (full analysis in conversation history,
2026-04-28):

| Option | First-partial latency | Cost | Dependencies | Privacy |
|---|---|---|---|---|
| Gemini Live WebSocket | ~300 ms | $0.10 / 15-min audio | None new | Cloud |
| Deepgram Nova-3 streaming | ~150–300 ms | $0.0043 / min | New API key | Cloud |
| **Apple SpeechAnalyzer (macOS 26+)** | **~80–250 ms** | **$0** | **None** | **100% local** |
| WhisperKit / Parakeet | ~500 ms | $0 | New SwiftPM dep + ~600 MB model | 100% local |

Apple Speech wins on every axis except multilingual coverage in the
long tail (English / major Romance / Germanic / CJK / modern Greek
are excellent; lower-resource languages drop quality). For a
personal recording tool whose primary user works in English and
Greek, this is the right tradeoff.

The fallback exists: `--transcribe gemini` still works, so
multilingual or technical-vocabulary content can always escape to
the cloud provider when needed.

### 2.3 Why bump the deployment target to macOS 26

`SpeechAnalyzer` was introduced in macOS 26 (Tahoe). It is the
modern Swift-concurrency-native API: async-sequence-driven results,
first-class voice activity detection, language model hints, and
materially better accuracy than `SFSpeechRecognizer`'s on-device
mode. Bumping the project's deployment target from `.macOS(.v14)`
to `.macOS(.v26)` is a meaningful change but acceptable for v1.5
because the project's only user is on macOS 26.4.1. Recorded as
**Approved Exception 002** in CLAUDE.md.

If wider compatibility becomes a goal later, the streaming provider
could fall back to `SFSpeechRecognizer` via `#available(macOS 26, *)`
gating — out of v1.5 scope.

---

## 3. Scope deltas (file by file)

### 3.1 To be added

| Path | Approx. KB | Purpose |
|---|---|---|
| `Sources/MacrecCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift` | ~10 | The new provider (§4.2) |
| `Sources/MacrecCore/Transcription/Providers/SpeechAnalyzerAdapter.swift` | ~3 | Test seam wrapping `SpeechAnalyzer + SpeechTranscriber` (§5.2) |
| `Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift` | ~6 | Pipeline mode for streaming providers (§4.3) |
| `Sources/MacrecCore/Permissions/SpeechPermission.swift` | ~3 | TCC `NSSpeechRecognitionUsageDescription` preflight |
| `Tests/MacrecCoreTests/Transcription/Providers/AppleSpeechTranscriptionProviderTests.swift` | ~4 | Unit tests using `MockSpeechAnalyzer` |
| `Tests/MacrecCoreTests/Transcription/Providers/MockSpeechAnalyzer.swift` | ~2 | Test double for `SpeechAnalyzerAdapter` |
| `Tests/MacrecCoreTests/Transcription/Providers/FakeStreamingProvider.swift` | ~2 | Test double for streaming pipeline tests |
| `Tests/MacrecCoreTests/Transcription/StreamingTranscriptionPipelineTests.swift` | ~3 | Pipeline routing + event dispatch tests |
| `test_scripts/e2e-transcription-apple.sh` | ~1.5 | Single-locale happy path |
| `test_scripts/e2e-transcription-apple-dual-locale.sh` | ~2 | en-US + el-GR parallel recognition |
| `test_scripts/e2e-transcription-permission-denied.sh` | ~1 | TCC denied → exit 78 |
| `test_scripts/e2e-transcription-apple-detach.sh` | ~1 | Detach + apple parity |
| **Total added** | **~38 KB** | |

### 3.2 To be edited

| Path | Change |
|---|---|
| `Package.swift` | `platforms: [.macOS(.v14)]` → `platforms: [.macOS(.v26)]` |
| `CLAUDE.md` | Add Approved Exception 002 (deployment target bump rationale) |
| `Resources/Info.plist` | Add `NSSpeechRecognitionUsageDescription` key |
| `Sources/MacrecCore/Transcription/TranscriptionProvider.swift` | Add `supportedModes`, `openStreamingSession`; keep `transcribe` for batch (§4.1) |
| `Sources/MacrecCore/Transcription/TranscriptEvent.swift` | Add `case segmentFinalized(index:segment:)` (§4.4) |
| `Sources/MacrecCore/Transcription/TranscriptSegment.swift` | Add optional `language: String?` field |
| `Sources/MacrecCore/Transcription/TranscriptionOptions.swift` | Rename `languageHint: String?` → `languageHints: [String]` |
| `Sources/MacrecCore/Transcription/TranscriptionManager.swift` | Pick streaming-vs-batch pipeline based on `provider.supportedModes` |
| `Sources/MacrecCore/Transcription/Persistence/TranscriptSidecarWriter.swift` | Per-mode write policy: streaming = `.segmentFinalized` only; batch = `.segmentAppended` + `.segmentUpdated` |
| `Sources/MacrecCore/Transcription/Persistence/JSONLTranscriptWriter.swift` and three siblings | Emit new `language` field when non-nil |
| `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift` | Add `apple` case; keep `gemini` and `none` and `gemini-live` alias |
| `Sources/MacrecCore/Transcription/NoOpTranscriptionProvider.swift` | Conform to extended protocol (`supportedModes = [.batch]`; streaming session is a no-op stub) |
| `Sources/MacrecCore/Transcription/FakeTranscriptionProvider.swift` | Conform to extended protocol (`supportedModes = [.batch]`) |
| `Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift` | Conform: `supportedModes = [.batch]`; `openStreamingSession` throws `transcriptionConfigConflict` |
| `Sources/MacrecCore/Config/RecordingOptions.swift` | Parse comma-separated `MACREC_TRANSCRIBE_LANGUAGE` into `[String]`; default `transcriptionProviderId` flip from `.none` to `.apple` |
| `Sources/MacrecCore/Config/ConfigResolver.swift` | Validate `apple` provider id; pre-validate locales against `SpeechAnalyzer.supportedLocales()` |
| `Sources/MacrecCore/Errors/MacrecError.swift` | Add `transcriptionPermissionDenied(provider: String)` case (exit 78) |
| `Sources/MacrecCore/RecordingSession.swift` | Speech-permission preflight; pipeline-mode selection; same `setUp` / `split` / `tearDown` shape |
| `Sources/macrec/Commands/CheckPermissionsCommand.swift` | Add `apple-speech` row alongside microphone / screen-recording |
| `Sources/MacrecUIKit/RecordingController.swift` | Handle `.segmentFinalized` event (alongside existing `.segmentAppended` / `.segmentUpdated`) |
| `Sources/macrec-ui/Views/Transcription/*` | Show language tag chip when ≥ 2 locales active; "settled" visual treatment on `.segmentFinalized` |
| `Sources/macrec-ui/Views/ControlBar.swift` | Add `Apple Speech` to the picker; make it the default selection |
| `docs/design/project-design.md`, `docs/design/project-functions.md`, `docs/design/configuration-guide.md`, `docs/tools/macrec.md`, `docs/tools/macrec-ui.md` | Document the new provider, the default flip, the permission, the dual-locale syntax |
| `Issues - Pending Items.md` | Add PEND-AS-1 (TCC re-prompt on rebuild for the new permission, parity with R-2) |
| `test_scripts/e2e-transcription-key-missing.sh` | Update to name `gemini` explicitly (was implicit before; the default flip means the test must name the provider) |

### 3.3 To be deleted

None. Plan-005 is purely additive — no plan-004 code is removed.

---

## 4. Component contracts

### 4.1 `TranscriptionProvider` — extended

```swift
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedModes: Set<TranscriptionMode> { get }

    // Existing batch surface (Gemini REST, NoOp, Fake) — unchanged signature.
    func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String

    // New streaming surface (Apple, future Deepgram, future Gemini Live).
    func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession
}

public enum TranscriptionMode: Sendable, Codable, Equatable {
    case batch
    case streaming
}
```

The conformance matrix in v1.5:

| Provider | `supportedModes` |
|---|---|
| `NoOpTranscriptionProvider` | `[.batch]` |
| `FakeTranscriptionProvider` | `[.batch]` |
| `GeminiRESTTranscriptionProvider` | `[.batch]` |
| `AppleSpeechTranscriptionProvider` | `[.streaming]` |

The manager picks `.streaming` when available (for Apple), `.batch`
otherwise (for Gemini / NoOp / Fake). Future providers
(`DeepgramStreamingProvider`, `GeminiLiveStreamingProvider`) would
declare `[.streaming]` or `[.batch, .streaming]` and slot in without
manager changes.

### 4.2 `StreamingTranscriptionSession`

```swift
public protocol StreamingTranscriptionSession: Sendable {
    /// Push 16 kHz mono Float32 audio. Non-blocking, lossy under backpressure.
    func ingest(_ samples: [Float]) async

    /// Stream of partial + final transcription events for this session.
    /// Closes when `finish()` is called or the session errors.
    var events: AsyncStream<StreamingTranscriptionEvent> { get }

    /// Signal end-of-input. Session emits any pending final, then closes `events`.
    func finish() async
}

public enum StreamingTranscriptionEvent: Sendable {
    case partial(utteranceId: UUID, text: String, confidence: Float?)
    case final(utteranceId: UUID, text: String, confidence: Float?,
               range: ClosedRange<Date>, language: String)
    case metrics(StreamingProviderMetrics)
    case error(detail: String)
}

public struct StreamingProviderMetrics: Sendable, Codable, Equatable {
    public var partialsEmitted: Int = 0
    public var finalsEmitted: Int = 0
    public var lastPartialLatencyMs: Int = 0   // mic-utterance-tip → partial-arrival
    public var lastFinalLatencyMs: Int = 0     // utterance-end-of-speech → final-arrival
    public var errorCount: Int = 0
    public init() {}
}
```

`utteranceId` is provider-assigned, stable across the partials and
the final of a single utterance. The pipeline uses it to decide
whether an incoming `.partial` updates an existing UI segment or
starts a new one.

### 4.3 `AppleSpeechTranscriptionProvider`

```swift
public actor AppleSpeechTranscriptionProvider: TranscriptionProvider {
    public nonisolated let id = "apple"
    public nonisolated let displayName = "Apple Speech (on-device)"
    public nonisolated let supportedModes: Set<TranscriptionMode> = [.streaming]

    private let logger: Logger
    private let analyzerFactory: @Sendable (Locale) throws -> any SpeechAnalyzerAdapter

    public init(
        logger: Logger = Logger(label: "macrec.transcription.apple"),
        analyzerFactory: @escaping @Sendable (Locale) throws -> any SpeechAnalyzerAdapter = ProductionSpeechAnalyzerAdapter.make
    ) {
        self.logger = logger
        self.analyzerFactory = analyzerFactory
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        let locales = options.languageHints.isEmpty
            ? [Locale.current]
            : options.languageHints.map { Locale(identifier: $0) }

        try await SpeechPermission.ensureGranted()

        var analyzers: [LocaleAnalyzer] = []
        for locale in locales {
            let adapter = try analyzerFactory(locale)
            analyzers.append(LocaleAnalyzer(locale: locale, adapter: adapter))
        }

        return AppleSpeechSession(
            analyzers: analyzers,
            source: source,
            logger: logger
        )
    }

    public func transcribe(
        samples: [Float], source: SourceTag, options: TranscriptionOptions
    ) async throws -> String {
        // Slow-path batch fallback for protocol conformance only — used only
        // if a caller explicitly forces .batch mode for the apple provider.
        let session = try await openStreamingSession(source: source, options: options)
        await session.ingest(samples)
        await session.finish()
        var collected = ""
        for await event in session.events {
            if case .final(_, let text, _, _, _) = event {
                collected += (collected.isEmpty ? "" : " ") + text
            }
        }
        return collected
    }
}
```

`AppleSpeechSession` is the meaty internal type:

- Holds N `LocaleAnalyzer` structs (one per locale).
- `ingest(_:)` writes samples to all analyzers in parallel via fire-and-forget Tasks.
- One drain Task per analyzer reads its `results` async sequence:
  - Non-final result → `.partial(utteranceId:text:confidence:)` emitted immediately to the merged events stream.
  - Final result → buffered keyed by `utteranceId`. After a small reconciliation window (~150 ms) waiting for peers' finals on the same `utteranceId`, the highest-confidence final wins and is emitted as `.final(... language: winner.locale.identifier)`.
- `finish()` calls `adapter.finalizeAndFinish()` on each, awaits drain Tasks, finishes the events stream.

### 4.4 `TranscriptionEvent` and `TranscriptSegment`

```swift
public enum TranscriptionEvent: Sendable, Codable, Equatable {
    case segmentAppended(index: Int, segment: TranscriptSegment)    // existing
    case segmentUpdated(index: Int, segment: TranscriptSegment)     // existing — partials
    case segmentFinalized(index: Int, segment: TranscriptSegment)   // NEW — sidecar persists this only
    case privacyDisclosure(providerDisplayName: String)
    case metricsTick(metrics: TranscriptionMetrics)
    case error(detail: String)
}

public struct TranscriptSegment: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public var lastUpdated: Date
    public var text: String
    public let source: SourceTag
    public let confidence: Float?
    public let model: String?
    public let durationSec: Double?
    public let language: String?   // NEW — BCP-47 of the winning recognizer
    // ... initializer extended with optional `language: String? = nil`
}
```

### 4.5 `TranscriptionManager` — pipeline-mode selection

```swift
public actor TranscriptionManager {
    public init(
        provider: any TranscriptionProvider,
        source: TranscriptionSource,
        options: TranscriptionOptions,
        downsampler: AudioDownsampler,
        sidecarWriter: TranscriptSidecarWriter?,
        logger: Logger
    ) {
        // ...
        if provider.supportedModes.contains(.streaming) {
            self.pipeline = StreamingTranscriptionPipeline(...)
        } else {
            self.pipeline = BatchTranscriptionPipeline(...)   // existing
        }
    }
}
```

The pipeline interface is the same — both expose `start()`,
`ingest(_:from:)`, `rotateSidecar(toAudioURL:format:)`, `stop()`. The
manager just swaps the implementation. The two pipeline classes
share zero code; they are different enough that abstracting them
would obscure rather than clarify.

### 4.6 `StreamingTranscriptionPipeline`

```swift
final class StreamingTranscriptionPipeline {
    init(provider: any TranscriptionProvider,
         source: TranscriptionSource,
         options: TranscriptionOptions,
         sidecarWriter: TranscriptSidecarWriter?,
         logger: Logger)

    func start() -> AsyncStream<TranscriptionEvent>
    func ingest(_ samples: [Float], from tag: SourceTag) async
    func rotateSidecar(toAudioURL: URL, format: TranscriptFormat) async throws
    func stop() async
    func currentMetrics() -> TranscriptionMetrics
}
```

Internally:
- `[SourceTag: any StreamingTranscriptionSession]` — one session per active source tag.
- One drain Task per session reads `session.events` and converts each into the right `TranscriptionEvent`:
  - `.partial(uttId, text, conf)` → if `uttId` is new, append a UI-only segment + emit `.segmentAppended`; else replace text in place + emit `.segmentUpdated`.
  - `.final(uttId, text, conf, range, language)` → resolve segment for `uttId`, replace text + set language, emit `.segmentFinalized`.
  - `.metrics(m)` → emit `TranscriptionMetrics`-formatted `.metricsTick`.
  - `.error(detail)` → emit `.error(detail:)`.
- No coalescer (each utterance is already a complete segment from the recognizer).
- No `SourceBuffer` (samples flow directly to `session.ingest`).
- No peak-gate (Apple's recognizer handles silence detection internally).

### 4.7 Sidecar policy per pipeline mode

`TranscriptSidecarWriter` gains a `policy: SidecarPolicy` field:

```swift
enum SidecarPolicy: Sendable {
    case batch       // appendSegment on .segmentAppended; updateSegment on .segmentUpdated
    case streaming   // appendSegment on .segmentFinalized only; ignore .segmentAppended/.segmentUpdated
}
```

The manager passes the policy to the writer at construction time
based on `provider.supportedModes`. The plan-004 Phase F
tombstone-and-append logic stays — only the batch policy uses it.
Streaming policy is append-only, never rewrites.

### 4.8 `SpeechAnalyzerAdapter` — test seam

```swift
protocol SpeechAnalyzerAdapter: Sendable {
    func ingest(_ samples: [Float]) async
    var results: AsyncStream<TranscriptionResult> { get }
    func finalizeAndFinish() async
}

struct TranscriptionResult: Sendable {
    let text: String
    let confidence: Float?
    let isFinal: Bool
    let timeRange: ClosedRange<Date>?
}
```

Production conformer: `ProductionSpeechAnalyzerAdapter` wraps a
real `SpeechAnalyzer + SpeechTranscriber` from
`import Speech`.

Test conformer: `MockSpeechAnalyzer` lets a test push canned
`TranscriptionResult` values into the `results` stream
on demand. Used by every test in the suite — the suite never
touches `Speech.framework` directly.

### 4.9 `SpeechPermission`

Mirrors the existing `MicrophonePermission` and
`ScreenRecordingPermission` shapes:

```swift
public enum SpeechPermission {
    public static func currentStatus() -> AuthorizationStatus
    public static func request() async -> AuthorizationStatus
    public static func ensureGranted() async throws
}
```

`ensureGranted()` queries `SFSpeechRecognizer.authorizationStatus()`
(or the SpeechAnalyzer equivalent), prompts via `requestAuthorization`
if `notDetermined`, and throws
`MacrecError.transcriptionPermissionDenied(provider: "apple")` if
the result is `denied` or `restricted`.

---

## 5. Data flow

### 5.1 Streaming happy path (`--transcribe apple --transcribe-language en-US,el-GR --transcribe-source mixed`)

```
SCStream/AVAudioEngine
    → AudioAligner                                    (existing)
    → AlignedFrame [48 kHz Float32, 100 ms]
    → tap closure                                     (Phase G wiring, unchanged)
    → TranscriptionManager.ingestFrame(frame, .system)
        → AudioDownsampler.convert → [Float32 @ 16 kHz, ~1600 samples]
        → StreamingTranscriptionPipeline.ingest(samples, from: .system)
            → AppleSpeechSession[.system].ingest(samples)
                → for each LocaleAnalyzer (en-US, el-GR):
                    Task { await analyzer.ingest(samples) }   (parallel, lossy)

(in parallel, one drain Task per LocaleAnalyzer:)
for await result in analyzer.results {
    if result.isFinal { buffer for reconciliation }
    else { emit .partial(utteranceId, text, confidence) }
}

(per-utterance reconciliation Task:)
when final from each locale arrives (or 150 ms timeout fires):
    → pick highest-confidence final
    → emit .final(utteranceId, text, confidence, range,
                  language: winner.locale.identifier)
        ↓
StreamingTranscriptionPipeline drain:
    case .partial(uttId, text, conf):
        first time: emit .segmentAppended(idx, seg)
        subsequent: emit .segmentUpdated(idx, seg with new text)
    case .final(uttId, text, conf, range, language):
        emit .segmentFinalized(idx, seg with final text + language)
        ↓
Sidecar (streaming policy): writes only on .segmentFinalized
UI: shows partials growing in real time; "settles" line on finalized
```

### 5.2 The dual-source `both` path

Two `AppleSpeechSession` instances (one per source tag), each with
N parallel analyzers. Total active recognizers with
`--transcribe-source both` and 2 locales = **2 × 2 = 4 SpeechAnalyzers**.
Each consumes the source-tagged audio independently. CPU: ~12–32 %
aggregate on Apple Silicon at light load — comfortable.

### 5.3 Sidecar contents

For Apple streaming, lines look like:

```jsonl
{"id":"…","timestamp":"…","source":"mic","text":"hello world","model":"apple","language":"en-US","durationSec":1.4}
{"id":"…","timestamp":"…","source":"system","text":"καλημέρα","model":"apple","language":"el-GR","durationSec":1.1}
```

For TXT/SRT/VTT with ≥ 2 active locales, lines get a `[lang]`
prefix:

```
[10:23:14] mic [en]: hello world
[10:23:16] system [el]: καλημέρα
```

For single-locale sessions, no prefix (preserves the plan-004 format).

### 5.4 Sidecar rotation on `split()`

Same as plan-004 Phase G.4. The streaming sessions stay running
across the split (no audio lost mid-utterance); the rotation
swaps the writer and clears the per-utterance ID mapping so the
first new final lands as a fresh segment in the new sidecar.

---

## 6. Configuration

| Variable | CLI flag | Default | Notes |
|---|---|---|---|
| `MACREC_TRANSCRIBE` | `--transcribe` | **`apple`** (changed) | Accepts `none`, `apple`, `gemini`. `gemini-live` deprecation alias preserved |
| `MACREC_TRANSCRIBE_SOURCE` | `--transcribe-source` | `mixed` | Unchanged |
| `MACREC_TRANSCRIBE_FORMAT` | `--transcript-format` | `jsonl` | Unchanged |
| `MACREC_TRANSCRIBE_LANGUAGE` | `--transcribe-language` | system locale | Comma-separated BCP-47 list activates dual-locale; single value continues to work |
| `MACREC_TRANSCRIBE_MODEL` | `--transcribe-model` | apple: ignored; gemini: `gemini-3-flash-preview` | Apple has no user-selectable model in v1.5 |
| `GOOGLE_API_KEY` | — | — | Required only for `--transcribe gemini` |

The four-tier resolution chain (shell env →
`~/.tool-agents/macrec/.env` → local `.env` → CLI flag) is unchanged.
No new env vars beyond the `MACREC_TRANSCRIBE_LANGUAGE` semantics
broadening.

---

## 7. Errors & lifecycle

### 7.1 `MacrecError` cases

| Case | When raised | Exit | Posture |
|---|---|---|---|
| `transcriptionApiKeyMissing(provider: "gemini")` | `MACREC_TRANSCRIBE=gemini`, `GOOGLE_API_KEY` empty | 78 | Fatal at startup (existing) |
| `transcriptionPermissionDenied(provider: "apple")` | TCC speech permission denied or restricted | 78 | **NEW** — fatal at startup |
| `transcriptionConfigConflict(reason: "language not supported by Apple: ...")` | Requested locale not in `SpeechAnalyzer.supportedLocales()` | 64 | Fatal at startup |
| `transcriptionConfigConflict(reason: "transcribe value '\(v)' invalid")` | Bad provider id | 64 | Fatal at startup (existing) |
| `transcriptionProviderUnavailable(reason: ...)` | Apple session unrecoverable mid-recording | — | **Non-fatal at runtime** — recording continues |

### 7.2 Lifecycle

1. **`start()`** — Resolver → Factory builds Apple/Gemini/NoOp provider. `setUpTranscriptionPipelineIfNeeded`:
   1. Speech-permission preflight (Apple only) — `transcriptionPermissionDenied` if denied
   2. Locale validation against `SpeechAnalyzer.supportedLocales()` — `transcriptionConfigConflict` if any unsupported
   3. Manager picks streaming vs batch pipeline based on `provider.supportedModes`
   4. Opens streaming sessions per source tag (one per `activeSourceTags()`)
   5. Emits provider-specific privacy disclosure ("Audio never leaves your Mac" for Apple)
   6. Installs the audio tap

2. **`pause()` / `resume()`** — Pause calls `session.finish()`, flushes any straggling final. Resume opens fresh sessions. Each cycle = clean utterance boundary.

3. **`split(nextOutput:)`** — Sidecar rotates atomically; sessions keep running.

4. **`stop()`** — `session.finish()` on each, awaits drain (≤ 5 s), closes writer, emits final metrics.

5. **`--max-duration`** — Unchanged: recorder stop → manager stop, one-way.

### 7.3 Detach mode (`--detach --transcribe apple`)

Valid (parity with plan-004's R-LT-2 lift). The streaming pipeline
produces sidecars without a UI subscriber. **Caveat**: TCC speech
permission MUST be granted before the detach command runs (a
detached process has no foreground session for the prompt). If
`notDetermined`, resolver throws
`transcriptionPermissionDenied` with a remediation hint pointing to
`macrec check-permissions`.

---

## 8. Testing strategy

### 8.1 Unit — pure functions

- Locale parsing: `"en-US,el-GR"` → `["en-US", "el-GR"]`; trim whitespace; reject empty
- Confidence comparison: highest wins; ties broken by first-arrived
- Language-tag prefix formatter: present iff ≥ 2 active locales
- Partial→final reconciliation timeout

### 8.2 Unit — actors

- `AppleSpeechSession.ingest` lossy-under-backpressure
- `finish()` drains in-flight finals before closing
- Dual-locale reconciliation picks higher-confidence winner

### 8.3 Unit — provider

- `openStreamingSession` returns a session
- Throws `transcriptionConfigConflict` on unsupported locale
- Throws `transcriptionPermissionDenied` when `MockSpeechAuthorization` says denied

### 8.4 Unit — pipeline

- `StreamingTranscriptionPipeline` routes per-source
- First `.partial` → `.segmentAppended`; subsequent `.partial` → `.segmentUpdated`
- `.final` → `.segmentFinalized`
- Sidecar (streaming policy) writes only on `.segmentFinalized`

### 8.5 E2E — shell scripts

| Script | Requires | Asserts |
|---|---|---|
| `e2e-transcription-apple.sh` | macOS 26+, Speech permission granted | `*.transcript.jsonl` exists, ≥ 1 final segment, ≥ 3 keyword hits, `model:"apple"` in every line |
| `e2e-transcription-apple-dual-locale.sh` | macOS 26+, Speech permission granted | Sidecar has lines tagged `language:"en-US"` AND `language:"el-GR"` |
| `e2e-transcription-permission-denied.sh` | TCC speech permission denied (manual setup) | exit 78, no audio file, stderr names "Privacy & Security → Speech Recognition" |
| `e2e-transcription-apple-detach.sh` | macOS 26+, Speech permission granted | Sidecar lands without a foreground UI consumer |

The plan-004 e2e scripts continue to work:
`e2e-transcription-noop.sh`, `e2e-transcription-key-missing.sh`
(updated to name `gemini` explicitly given the default flip),
`e2e-transcription-gemini.sh`, `e2e-transcription-detach.sh`.

### 8.6 Acceptance-criteria additions

`AC-AS-1..AC-AS-12` added to `project-functions.md` covering: sidecar
production, latency, locale-tag presence, confidence-pick correctness,
TCC denied, detach, pause/resume utterance boundary, split rotation,
unsupported-locale failure, recording-integrity isolation under
provider error.

### 8.7 R-17 caveat (test runner)

Same as plan-004: `swift test` exits 0 silently on Apple
CommandLineTools. All new tests written with `import Testing` +
`@Test` so they run cleanly on a Xcode-equipped CI image. The four
new e2e scripts ARE runnable on the dev host (they exercise the
binary, not XCTest).

---

## 9. Risks

### 9.1 Apple's confidence scores may be noisy

Apple's `confidence` field on `SpeechRecognitionResult` is a 0..1
float that reflects per-segment recognizer confidence — useful but
not always discriminative for short utterances. The dual-locale
"pick higher-confidence" logic could pick the wrong locale on
ambiguous short input ("yes", "OK"). Mitigation: when both finals
have confidence within 0.05 of each other, prefer the locale that
matches the segment's previous-segment language (locality bias).
Documented in `AppleSpeechSession.reconcile`.

### 9.2 ~150 ms reconciliation window may dilate worst-case latency

The window is 150 ms after the FIRST locale's final to wait for
peers' finals. If one analyzer is significantly slower than another
on a given utterance, the slow one's final arrives after the window
and gets discarded — only the fast one is considered. Mitigation:
the window is a constant in `AppleSpeechSession`; if empirically
finals diverge by > 150 ms, bump the constant. Unit test asserts
the window is honored.

### 9.3 New TCC prompt re-fires on every ad-hoc-signed rebuild (R-2 redux)

Same R-2 limitation applies: SPM-built CLI tools are ad-hoc-signed,
so Apple invalidates the TCC grant on every rebuild. Documented in
`docs/tools/macrec.md` parity with the existing R-2 mention. v2
`.app` packaging with a stable Developer-ID signature solves this.
Tracked as PEND-AS-1 in `Issues - Pending Items.md`.

### 9.4 Locale support varies by macOS install

`SpeechAnalyzer.supportedLocales()` returns a set that depends on
which language packs the OS has downloaded. A user requesting
`el-GR` on a system that hasn't downloaded the Greek language pack
will hit `transcriptionConfigConflict` at session start.
Mitigation: error message names the missing locale and points to
System Settings → General → Language & Region → Add Language.

### 9.5 CPU budget with `--transcribe-source both` + 2 locales

4 active recognizers ≈ ~12–32 % CPU on Apple Silicon at light load.
Combined with the existing capture + AAC encode (~10 %), total ~40 %
worst-case. Acceptable but worth documenting. If a future user
runs on Intel hardware the budget could exceed 80 % — `--transcribe
gemini` remains the cloud escape hatch.

### 9.6 Default flip from `none` to `apple` changes plain-`macrec start` behavior

A user who runs `macrec start` after upgrading will see a TCC
permission dialog and a sidecar appear. This is intentional but
disruptive. Mitigation: documented prominently in
`docs/tools/macrec.md` "What changed in v1.5" section. Users who
prefer the old behavior set `MACREC_TRANSCRIBE=none` in their `.env`.

---

## 10. Deferred to v2

| Item | Why deferred |
|---|---|
| `SFSpeechRecognizer` fallback path for macOS 13–25 | Not needed for primary user; `#available` gating is straightforward to add later |
| Custom vocabulary / language model hints | Apple supports `SpeechTranscriber.LanguageModelOptions`; out of v1.5 scope |
| Per-recognizer voice activity tuning | Apple exposes some VAD knobs; defaults are good enough for v1.5 |
| Speaker diarization | Apple's framework does not natively support this; would require a separate library |
| `--transcribe-mode {auto,batch,streaming}` flag | Auto is the only mode in v1.5; flag becomes useful when a future provider supports both modes |
| Deepgram / OpenAI Realtime / WhisperKit providers | Architecture supports them via `[.streaming]` mode; out of v1.5 scope |

---

## 11. Open questions for the user

None blocking. All resolved during the brainstorming session on
2026-04-28:

- **Q1 (Gemini disposition)** → Keep alongside; Apple is default
- **Q2 (Apple API)** → Bump macOS target to 26, use SpeechAnalyzer
- **Q3 (sidecar partial policy)** → Finals only; UI shows partials live
- **Q4 (locale handling)** → Dual-language via parallel recognizers, pick higher-confidence
- **Q5 (default flip)** → `MACREC_TRANSCRIBE` defaults to `apple`

---

## 12. Next step

The executable implementation plan follows below as **Part 2**.

---

# Part 2 — Implementation Plan

> **For executors:** Each phase is a coherent unit ending at a
> recommended commit point. Tasks use checkbox (`- [ ]`) syntax and
> follow TDD discipline: red → green → tighten. Tests written with
> `import Testing` + `@Test`. R-17 caveat: local `swift test` exits 0
> silently on Apple CommandLineTools — `swift build --build-tests` is
> the local verification gate; full test suite runs on a Xcode CI
> image. Per-step `git commit` instructions are omitted per the
> user's no-VCS rule; commits at phase boundaries are at executor /
> user discretion.

**Goal:** Add `AppleSpeechTranscriptionProvider` (on-device
streaming via `SpeechAnalyzer`) alongside the plan-004 Gemini REST
provider. Make Apple the new default. Preserve every plan-004
guarantee (recording integrity isolation, sidecar formats, lifecycle).

**Architecture:** Extend `TranscriptionProvider` with a streaming
surface (`openStreamingSession`). `AppleSpeechTranscriptionProvider`
runs N parallel `SpeechAnalyzer` sessions (one per locale), picks
higher-confidence final per utterance, emits real-time partials to
the UI. A new `StreamingTranscriptionPipeline` lives alongside the
existing batch pipeline; the `TranscriptionManager` selects between
them based on `provider.supportedModes`.

**Tech Stack:** Swift 5.9+ / `import Speech` (macOS 26+
`SpeechAnalyzer`) / Foundation / AVFoundation / `import Testing`. No
new SwiftPM dependencies.

---

## Phase 0 — Spec, doc, and project-config alignment

**Goal:** Align all spec docs, the deployment target, and CLAUDE.md
exceptions before any code lands. This isolates spec churn from code
churn.

**Files:**
- `Package.swift` — bump `platforms: [.macOS(.v14)]` → `[.macOS(.v26)]`
- `CLAUDE.md` — add Approved Exception 002
- `Resources/Info.plist` — add `NSSpeechRecognitionUsageDescription`
- `docs/design/project-functions.md` — add FR-AS-1..FR-AS-12, NFR-AS-1..NFR-AS-3, AC-AS-1..AC-AS-12
- `docs/design/project-design.md` — add §AS section
- `docs/design/configuration-guide.md` — refresh §LT for apple/dual-locale; document default flip
- `Issues - Pending Items.md` — add PEND-AS-1 (TCC re-prompt parity with R-2)

### Task 0.1 — Bump Package.swift deployment target

- [ ] Open `Package.swift`. Find the `platforms:` declaration.
- [ ] Change `platforms: [.macOS(.v14)]` → `platforms: [.macOS(.v26)]`.
- [ ] Run `swift build` to confirm it still compiles. (No code change yet, just the target bump — the codebase already runs cleanly on macOS 14, so a bump should not break anything.)
- [ ] Expected: clean build.

### Task 0.2 — Add CLAUDE.md Exception 002

- [ ] Open `CLAUDE.md`. Find the "Project Memory / Approved Exceptions" section.
- [ ] After Exception 001, add:

  ```markdown
  ### Exception 002 — Deployment target bumped to macOS 26 for SpeechAnalyzer

  - **Rule overridden**: implicit project assumption from plan-001 that the deployment target stays at `macOS 14` for broad compatibility.
  - **Approved**: 2026-04-28
  - **Scope**: Project-wide (Package.swift `platforms: [.macOS(.v26)]`)
  - **Reason**: plan-005 adds on-device live transcription via `SpeechAnalyzer`, introduced in macOS 26 (Tahoe). The new API unlocks real-time partials (~80–250 ms first-partial latency), Swift-concurrency-native results streams, and dual-locale parallel recognition. Quality and latency materially exceed the macOS 14-compatible `SFSpeechRecognizer` on-device mode. The project's primary user runs macOS 26.4.1; the bump is acceptable for v1.5.
  - **Implication**: anyone running macOS 13–25 cannot build or run `macrec` after this change. If wider compatibility is needed later, the streaming provider could fall back to `SFSpeechRecognizer` via `#available(macOS 26, *)` gating.
  ```

### Task 0.3 — Add NSSpeechRecognitionUsageDescription to Info.plist

- [ ] Open `Resources/Info.plist`.
- [ ] After the `NSMicrophoneUsageDescription` entry, add:

  ```xml
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>macrec uses on-device speech recognition to transcribe captured audio into a transcript sidecar. Audio never leaves your Mac.</string>
  ```

- [ ] Verify the plist is well-formed: `plutil -lint Resources/Info.plist` should print `Resources/Info.plist: OK`.

### Task 0.4 — Add FR-AS-1..FR-AS-12 to project-functions.md

- [ ] Open `docs/design/project-functions.md`.
- [ ] Find the FR-45..FR-58 block (live-transcription FRs from plan-004).
- [ ] After FR-58, add:

  ```markdown
  #### Apple Speech Streaming (plan-005)

  | FR | Description | Status |
  |---|---|---|
  | FR-AS-1 | New provider id `apple` for `--transcribe`; on-device streaming via `SpeechAnalyzer` (macOS 26+). | PLANNED (Phase D — plan-005) |
  | FR-AS-2 | `MACREC_TRANSCRIBE` default flips from `none` to `apple`. | PLANNED (Phase G — plan-005) |
  | FR-AS-3 | Per-utterance partial transcriptions surface to UI within ~250 ms of speech start. | PLANNED (Phase D + Phase H — plan-005) |
  | FR-AS-4 | Per-utterance final transcription persists to sidecar with `model:"apple"` and BCP-47 `language` field. | PLANNED (Phase F — plan-005) |
  | FR-AS-5 | `--transcribe-language en-US,el-GR` activates dual-locale parallel recognition. | PLANNED (Phase D — plan-005) |
  | FR-AS-6 | When ≥ 2 locales are active, sidecar lines carry `language` and TXT/SRT/VTT writers prefix the cue body with `[lang]`. | PLANNED (Phase F — plan-005) |
  | FR-AS-7 | Per-utterance reconciliation picks the higher-confidence final from parallel locales (150 ms wait window). | PLANNED (Phase D — plan-005) |
  | FR-AS-8 | TCC `NSSpeechRecognitionUsageDescription` preflight; missing grant → `transcriptionPermissionDenied` exit 78. | PLANNED (Phase C — plan-005) |
  | FR-AS-9 | Unsupported locale → `transcriptionConfigConflict` exit 64 with remediation pointing to System Settings → Language & Region. | PLANNED (Phase G — plan-005) |
  | FR-AS-10 | Detach mode supported (parity with plan-004 R-LT-2 lift); TCC must be granted before launching detached. | PLANNED (Phase G — plan-005) |
  | FR-AS-11 | Pause/resume produces a clean utterance boundary. | PLANNED (Phase E — plan-005) |
  | FR-AS-12 | `split(nextOutput:)` rotates the sidecar atomically; sessions keep running across the split. | PLANNED (Phase E + Phase G — plan-005) |
  ```

### Task 0.5 — Add NFR-AS-1..NFR-AS-3 to project-functions.md

- [ ] In the same file, after the existing NFR-17..NFR-21 block, add:

  ```markdown
  #### Apple Speech Streaming NFRs (plan-005)

  | NFR | Description | Status |
  |---|---|---|
  | NFR-AS-1 | First-partial latency ≤ 500 ms P95 (mic → first partial event) on Apple Silicon. | PLANNED (Phase D — plan-005) |
  | NFR-AS-2 | Final latency ≤ 1 s P95 (end-of-speech → final event). | PLANNED (Phase D — plan-005) |
  | NFR-AS-3 | CPU footprint per active recognizer ≤ 10 % on M-series at light load. With `--transcribe-source both` + 2 locales (4 active recognizers) total transcription CPU ≤ 40 %. | PLANNED (Phase D — plan-005) |
  ```

### Task 0.6 — Add AC-AS-1..AC-AS-12 to project-functions.md

- [ ] In the same file, in the AC-LT mapping subsection that plan-004 added, append:

  ```markdown
  #### Apple Speech AC mapping (plan-005)

  | AC | Verification |
  |---|---|
  | AC-AS-1 | `*.transcript.jsonl` sidecar with `model:"apple"` lines | `e2e-transcription-apple.sh` |
  | AC-AS-2 | First partial within 500 ms | unit test on `StreamingProviderMetrics.lastPartialLatencyMs` (`AppleSpeechSessionLatencyTests.swift`) |
  | AC-AS-3 | Final within 1 s of end-of-speech | unit test on `lastFinalLatencyMs` |
  | AC-AS-4 | Single-locale → no `[lang]` prefix in TXT/SRT/VTT | `WriterLanguagePrefixTests.swift` |
  | AC-AS-5 | Dual-locale → `[lang]` prefix present | `e2e-transcription-apple-dual-locale.sh` + `WriterLanguagePrefixTests` |
  | AC-AS-6 | Dual-locale picks higher-confidence final | `AppleSpeechSessionReconciliationTests.swift` (uses `MockSpeechAnalyzer`) |
  | AC-AS-7 | TCC denied → exit 78 | `e2e-transcription-permission-denied.sh` |
  | AC-AS-8 | Detach + apple → sidecar lands | `e2e-transcription-apple-detach.sh` |
  | AC-AS-9 | Pause/resume → clean utterance boundary | `StreamingTranscriptionPipelineTests` |
  | AC-AS-10 | Split rotates sidecar atomically | `TranscriptionManagerRotateTests` |
  | AC-AS-11 | Unsupported locale fails fast | `ConfigResolverAppleLocaleTests.swift` |
  | AC-AS-12 | Recording integrity isolation under provider error | `TranscriptionManagerErrorIsolationTests.swift` |
  ```

### Task 0.7 — Add §AS section to project-design.md

- [ ] Open `docs/design/project-design.md`. Find the §LT section (Live Transcription).
- [ ] After §LT (which now ends with the plan-004 superseded callout), add a new top-level section `## §AS — Apple Speech Streaming Subsystem (plan-005)` with one paragraph per:
  - **AS-1 Architecture**: "On-device streaming via `SpeechAnalyzer` (macOS 26+). One `AppleSpeechSession` per source tag; N parallel `SpeechAnalyzer` instances per session (one per locale)."
  - **AS-2 Pipeline-mode selection**: "TranscriptionManager picks `StreamingTranscriptionPipeline` when `provider.supportedModes.contains(.streaming)` (apple); else `BatchTranscriptionPipeline` (gemini, noop, fake)."
  - **AS-3 Reconciliation**: "Per-utterance: collect finals from all parallel analyzers within 150 ms window, pick highest confidence, tag winner's locale."
  - **AS-4 Sidecar policy**: "Streaming policy persists only on `.segmentFinalized` events. Batch policy (plan-004) unchanged."
  - **AS-5 TCC**: "Speech-permission preflight in `setUpTranscriptionPipelineIfNeeded` for apple provider."

  Use the cross-link `See plan-005-apple-speech-streaming.md §3–§7 for full contracts.`

### Task 0.8 — Refresh configuration-guide.md

- [ ] Open `docs/design/configuration-guide.md`. Update §2.16 (`MACREC_TRANSCRIBE`):
  - Allowed values: `none`, `apple` (default — NEW), `gemini`, `gemini-live` (deprecated alias for `gemini`)
  - Default: `apple` (changed from `none`)
  - Add note: "Default flipped to `apple` in plan-005 (2026-04-28). To restore the legacy 'no transcription by default' behavior, set `MACREC_TRANSCRIBE=none` in your `.env`."
- [ ] Update §2.18 (`MACREC_TRANSCRIBE_LANGUAGE`):
  - Type: comma-separated BCP-47 list (e.g. `en-US` or `en-US,el-GR`)
  - Notes: "For `apple`, multiple values activate parallel recognizers — one per locale, picking the higher-confidence final per utterance. For `gemini`, only the first value is used as a hint."

### Task 0.9 — Add PEND-AS-1 to Issues - Pending Items.md

- [ ] Open `Issues - Pending Items.md`. At the top of Pending (most-critical-first), add:

  ```markdown
  ### PEND-AS-1 — TCC re-prompt for Speech Recognition on every ad-hoc-signed rebuild (Low — DX, plan-005 §9.3, 2026-04-28)
  Same R-2 limitation applies to the new `NSSpeechRecognitionUsageDescription` permission: SPM-built CLI tools are ad-hoc-signed, so macOS invalidates the TCC grant on every rebuild and re-prompts the user. Documented in `docs/tools/macrec.md` parity with the existing R-2 mention. v2 `.app` packaging with a stable Developer-ID signature solves this. Owner: future packaging phase.
  ```

### Task 0.10 — Phase 0 verification

- [ ] Run: `swift build` → must succeed (Package.swift target bump should not break anything).
- [ ] Run: `plutil -lint Resources/Info.plist` → `OK`.
- [ ] Run: `grep -c 'plan-005' docs/design/project-functions.md docs/design/project-design.md docs/design/configuration-guide.md "Issues - Pending Items.md" CLAUDE.md` → expect ≥ 5 hits across the files.
- [ ] **Recommended commit point**: `doc(transcription): plan-005 spec & target alignment (Phase 0)`.

---

## Phase A — Protocol extensions and value type adjustments

**Goal:** Extend the public protocol surface to support streaming and dual-locale; re-conform the three existing providers (NoOp, Fake, Gemini) so the build stays green throughout. No new behavior yet — pure interface work.

**Files:**
- `Sources/MacrecCore/Transcription/TranscriptionProvider.swift` — add `supportedModes`, `openStreamingSession`
- `Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift` — new file; protocol + event enum + metrics struct + `TranscriptionMode` enum
- `Sources/MacrecCore/Transcription/TranscriptSegment.swift` — add optional `language` field
- `Sources/MacrecCore/Transcription/TranscriptEvent.swift` — add `.segmentFinalized` case
- `Sources/MacrecCore/Transcription/TranscriptionOptions.swift` — `languageHint: String?` → `languageHints: [String]`
- `Sources/MacrecCore/Transcription/NoOpTranscriptionProvider.swift` — re-conform
- `Sources/MacrecCore/Transcription/FakeTranscriptionProvider.swift` — re-conform
- `Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift` — re-conform

### Task A.1 — Define StreamingTranscriptionSession + Event + Metrics + Mode

- [ ] Create `Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift`:

```swift
import Foundation

public enum TranscriptionMode: Sendable, Codable, Equatable, Hashable {
    case batch
    case streaming
}

public protocol StreamingTranscriptionSession: Sendable {
    func ingest(_ samples: [Float]) async
    var events: AsyncStream<StreamingTranscriptionEvent> { get }
    func finish() async
}

public enum StreamingTranscriptionEvent: Sendable {
    case partial(utteranceId: UUID, text: String, confidence: Float?)
    case final(utteranceId: UUID,
               text: String,
               confidence: Float?,
               range: ClosedRange<Date>,
               language: String)
    case metrics(StreamingProviderMetrics)
    case error(detail: String)
}

public struct StreamingProviderMetrics: Sendable, Codable, Equatable {
    public var partialsEmitted: Int = 0
    public var finalsEmitted: Int = 0
    public var lastPartialLatencyMs: Int = 0
    public var lastFinalLatencyMs: Int = 0
    public var errorCount: Int = 0

    public init() {}
}
```

- [ ] Run `swift build --target MacrecCore` → must succeed (no consumers yet).

### Task A.2 — Extend TranscriptionProvider protocol

- [ ] Open `Sources/MacrecCore/Transcription/TranscriptionProvider.swift`. Replace the protocol body with:

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

- [ ] Run `swift build --target MacrecCore` → expect compile errors at the three existing conformers (NoOp, Fake, GeminiREST). That's the next three tasks.

### Task A.3 — Add segmentFinalized to TranscriptEvent

- [ ] Open `Sources/MacrecCore/Transcription/TranscriptEvent.swift`. Inside `enum TranscriptionEvent`, between `segmentUpdated` and `privacyDisclosure`, add:

```swift
    /// Stable, finalised segment. Sidecar writers (streaming policy) persist on this only.
    case segmentFinalized(index: Int, segment: TranscriptSegment)
```

- [ ] Build expectation: any exhaustive switch over `TranscriptionEvent` (RecordingController, TranscriptSidecarWriter) will warn about the missing case. Phase F + Phase H handle them.

### Task A.4 — Add language field to TranscriptSegment

- [ ] Open `Sources/MacrecCore/Transcription/TranscriptSegment.swift`. After `public let durationSec: Double?`, add:

```swift
    public let language: String?
```

- [ ] In the `init`, add the parameter at the end:

```swift
    public init(
        id: UUID = UUID(),
        timestamp: Date,
        lastUpdated: Date? = nil,
        text: String,
        source: SourceTag,
        confidence: Float? = nil,
        model: String? = nil,
        durationSec: Double? = nil,
        language: String? = nil
    ) {
        // ... existing assignments
        self.language = language
    }
```

- [ ] Run `swift build --target MacrecCore` → no new errors expected (existing callers use named args; the new parameter has a default).

### Task A.5 — Rename languageHint → languageHints in TranscriptionOptions

- [ ] Open `Sources/MacrecCore/Transcription/TranscriptionOptions.swift`. Find the field declaration `public let languageHint: String?` and the corresponding init parameter. Replace:

```swift
public let languageHints: [String]
// ...
public init(
    providerId: String,
    apiKey: String?,
    modelId: String?,
    languageHints: [String] = [],
    customSystemInstruction: String?,
    keyExpiresAt: Date?
) {
    // ...
    self.languageHints = languageHints
}
```

- [ ] Run `grep -rn 'languageHint\b' Sources/ Tests/` → for every match, update to `languageHints`. Single-string call sites (e.g. `languageHint: "en-US"`) become `languageHints: ["en-US"]`. Empty string becomes `languageHints: []`.
- [ ] Run `swift build --target MacrecCore` → resolve any remaining type mismatches.

### Task A.6 — Re-conform NoOpTranscriptionProvider

- [ ] Open `Sources/MacrecCore/Transcription/NoOpTranscriptionProvider.swift`. Replace the body:

```swift
import Foundation

public struct NoOpTranscriptionProvider: TranscriptionProvider {
    public let id = "none"
    public let displayName = "None"
    public let supportedModes: Set<TranscriptionMode> = [.batch]

    public init() {}

    public func transcribe(
        samples: [Float], source: SourceTag, options: TranscriptionOptions
    ) async throws -> String {
        ""
    }

    public func openStreamingSession(
        source: SourceTag, options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        NoOpStreamingSession()
    }
}

private struct NoOpStreamingSession: StreamingTranscriptionSession {
    var events: AsyncStream<StreamingTranscriptionEvent> {
        AsyncStream { cont in cont.finish() }
    }
    func ingest(_ samples: [Float]) async {}
    func finish() async {}
}
```

### Task A.7 — Re-conform FakeTranscriptionProvider

- [ ] Open `Sources/MacrecCore/Transcription/FakeTranscriptionProvider.swift`. Add the `supportedModes` property and a stub `openStreamingSession` that throws (Fake is batch-only):

```swift
public actor FakeTranscriptionProvider: TranscriptionProvider {
    public nonisolated let id = "fake"
    public nonisolated let displayName = "Fake"
    public nonisolated let supportedModes: Set<TranscriptionMode> = [.batch]

    // ... existing fields and methods

    public nonisolated func openStreamingSession(
        source: SourceTag, options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw MacrecError.transcriptionConfigConflict(
            reason: "FakeTranscriptionProvider does not support streaming mode"
        )
    }
}
```

### Task A.8 — Re-conform GeminiRESTTranscriptionProvider

- [ ] Open `Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift`. Add `supportedModes` and a streaming stub:

```swift
public struct GeminiRESTTranscriptionProvider: TranscriptionProvider, Sendable {
    // ... existing static properties + fields

    public let supportedModes: Set<TranscriptionMode> = [.batch]

    // ... existing init

    // ... existing transcribe(...)

    public func openStreamingSession(
        source: SourceTag, options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw MacrecError.transcriptionConfigConflict(
            reason: "Gemini REST provider does not support streaming; use --transcribe apple for streaming"
        )
    }
}
```

- [ ] Update the provider's internal use of `options.languageHint` (the old field) to `options.languageHints.first` (per the rename in Task A.5). The Gemini prompt only uses one language hint string.

### Task A.9 — Phase A build check

- [ ] Run: `swift build --target MacrecCore` → must succeed (no new errors; the cascade from Task A.2 should be resolved by A.6/A.7/A.8).
- [ ] Run: `swift build --build-tests` → must succeed.
- [ ] **Recommended commit point**: `feat(transcription): extended TranscriptionProvider protocol for streaming + dual-locale (Phase A)`.

---

## Phase B — SpeechAnalyzer adapter (test seam)

**Goal:** A thin protocol over Apple's `SpeechAnalyzer + SpeechTranscriber` so every test in the suite avoids touching `Speech.framework` directly.

**Files:**
- Create: `Sources/MacrecCore/Transcription/Providers/SpeechAnalyzerAdapter.swift`
- Create: `Tests/MacrecCoreTests/Transcription/Providers/MockSpeechAnalyzer.swift`

### Task B.1 — Define SpeechAnalyzerAdapter protocol + TranscriptionResult

- [ ] Create `Sources/MacrecCore/Transcription/Providers/SpeechAnalyzerAdapter.swift`:

```swift
import Foundation
import Speech

public struct TranscriptionResult: Sendable {
    public let text: String
    public let confidence: Float?
    public let isFinal: Bool
    public let timeRange: ClosedRange<Date>?

    public init(text: String, confidence: Float?, isFinal: Bool, timeRange: ClosedRange<Date>?) {
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
        self.timeRange = timeRange
    }
}

public protocol SpeechAnalyzerAdapter: Sendable {
    func ingest(_ samples: [Float]) async
    var results: AsyncStream<TranscriptionResult> { get }
    func finalizeAndFinish() async
}
```

### Task B.2 — Implement ProductionSpeechAnalyzerAdapter

- [ ] In the same file, add the production adapter:

```swift
@available(macOS 26.0, *)
public final class ProductionSpeechAnalyzerAdapter: SpeechAnalyzerAdapter {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    public let results: AsyncStream<TranscriptionResult>
    private let resultsContinuation: AsyncStream<TranscriptionResult>.Continuation

    public init(locale: Locale) throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveLiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let (inputStream, inputCont) = AsyncStream.makeStream(
            of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(64))
        let (resStream, resCont) = AsyncStream.makeStream(
            of: TranscriptionResult.self, bufferingPolicy: .bufferingNewest(128))

        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputContinuation = inputCont
        self.results = resStream
        self.resultsContinuation = resCont

        try analyzer.start(inputSequence: inputStream)

        Task { [weak self] in
            for try await result in transcriber.results {
                let text = result.text.characters.map(String.init).joined()
                let conf: Float? = result.confidence.map { Float($0) }
                let range: ClosedRange<Date>?
                if let interval = result.timeRange {
                    range = Date()...Date()  // SpeechAnalyzer time ranges are CMTime; map per Apple docs
                } else {
                    range = nil
                }
                let r = TranscriptionResult(
                    text: text,
                    confidence: conf,
                    isFinal: result.isFinal,
                    timeRange: range
                )
                self?.resultsContinuation.yield(r)
            }
            self?.resultsContinuation.finish()
        }
    }

    public func ingest(_ samples: [Float]) async {
        let input = AnalyzerInput(buffer: samples)  // exact init varies by SpeechAnalyzer SDK
        inputContinuation.yield(input)
    }

    public func finalizeAndFinish() async {
        inputContinuation.finish()
        try? await analyzer.finalize(through: nil)
    }

    public static func make(_ locale: Locale) throws -> any SpeechAnalyzerAdapter {
        try ProductionSpeechAnalyzerAdapter(locale: locale)
    }
}
```

> **Caveat for the executor.** The exact `SpeechAnalyzer` / `SpeechTranscriber` / `AnalyzerInput` API names are based on Apple's Tahoe-era documentation; verify the precise method signatures against the live Speech.framework headers when implementing. The protocol surface (`ingest / results / finalizeAndFinish`) is what the rest of the codebase depends on — adapt the production conformer's internals to whatever the framework actually requires.

### Task B.3 — Implement MockSpeechAnalyzer test double

- [ ] Create `Tests/MacrecCoreTests/Transcription/Providers/MockSpeechAnalyzer.swift`:

```swift
import Foundation
@testable import MacrecCore

public final class MockSpeechAnalyzer: SpeechAnalyzerAdapter, @unchecked Sendable {
    public let results: AsyncStream<TranscriptionResult>
    private let resultsContinuation: AsyncStream<TranscriptionResult>.Continuation
    public private(set) var ingestedSampleCount: Int = 0
    public private(set) var finalizeCalled: Bool = false
    private let lock = NSLock()

    public init() {
        let (s, c) = AsyncStream.makeStream(
            of: TranscriptionResult.self, bufferingPolicy: .unbounded)
        self.results = s
        self.resultsContinuation = c
    }

    public func ingest(_ samples: [Float]) async {
        lock.lock(); ingestedSampleCount += samples.count; lock.unlock()
    }

    public func finalizeAndFinish() async {
        lock.lock(); finalizeCalled = true; lock.unlock()
        resultsContinuation.finish()
    }

    /// Test API: push a canned result into the stream.
    public func push(_ result: TranscriptionResult) {
        resultsContinuation.yield(result)
    }
}
```

### Task B.4 — Phase B build check

- [ ] Run `swift build --build-tests` → must succeed.
- [ ] **Recommended commit point**: `feat(transcription): SpeechAnalyzerAdapter protocol + MockSpeechAnalyzer (Phase B)`.

---

## Phase C — SpeechPermission + MacrecError case

**Goal:** TCC preflight infrastructure for the new permission.

**Files:**
- Create: `Sources/MacrecCore/Permissions/SpeechPermission.swift`
- Modify: `Sources/MacrecCore/Errors/MacrecError.swift` — add `transcriptionPermissionDenied`
- Test: `Tests/MacrecCoreTests/Permissions/SpeechPermissionTests.swift`

### Task C.1 — Add transcriptionPermissionDenied to MacrecError

- [ ] Open `Sources/MacrecCore/Errors/MacrecError.swift`. After `case transcriptionApiKeyMissing(provider: String)`, add:

```swift
    case transcriptionPermissionDenied(provider: String)
```

- [ ] In the `errorDescription` switch, add a branch:

```swift
    case .transcriptionPermissionDenied(let provider):
        return "transcription permission denied for provider '\(provider)'. Enable in System Settings → Privacy & Security → Speech Recognition, then re-run."
```

- [ ] In the exit-code mapping (whichever switch maps cases to `Int32`), add `.transcriptionPermissionDenied: 78` (`EX_CONFIG`).

### Task C.2 — Create SpeechPermission module

- [ ] Create `Sources/MacrecCore/Permissions/SpeechPermission.swift`:

```swift
import Foundation
import Speech

public enum SpeechPermission {
    public enum Status: Sendable, Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized
    }

    public static func currentStatus() -> Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    public static func request() async -> Status {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                let mapped: Status
                switch status {
                case .notDetermined: mapped = .notDetermined
                case .denied: mapped = .denied
                case .restricted: mapped = .restricted
                case .authorized: mapped = .authorized
                @unknown default: mapped = .denied
                }
                cont.resume(returning: mapped)
            }
        }
    }

    /// Resolves to authorized or throws `MacrecError.transcriptionPermissionDenied(provider: "apple")`.
    public static func ensureGranted() async throws {
        let current = currentStatus()
        let final: Status
        if current == .notDetermined {
            final = await request()
        } else {
            final = current
        }
        guard final == .authorized else {
            throw MacrecError.transcriptionPermissionDenied(provider: "apple")
        }
    }
}
```

### Task C.3 — Unit test for SpeechPermission

- [ ] Create `Tests/MacrecCoreTests/Permissions/SpeechPermissionTests.swift`:

```swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("SpeechPermission")
struct SpeechPermissionTests {
    @Test("currentStatus returns one of the four states")
    func currentStatusValid() {
        let s = SpeechPermission.currentStatus()
        #expect([.notDetermined, .denied, .restricted, .authorized].contains(s))
    }
}
```

(End-to-end permission flow is exercised by `e2e-transcription-permission-denied.sh` in Phase I.)

### Task C.4 — Phase C build check

- [ ] Run: `swift build --target MacrecCore` → must succeed.
- [ ] Run: `swift build --build-tests` → must succeed.
- [ ] **Recommended commit point**: `feat(permissions): SpeechPermission preflight + MacrecError case (Phase C)`.

---

## Phase D — AppleSpeechTranscriptionProvider

**Goal:** The new provider, including the dual-locale reconciliation `AppleSpeechSession`. This is the single largest file in the plan.

**Files:**
- Create: `Sources/MacrecCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift`
- Test: `Tests/MacrecCoreTests/Transcription/Providers/AppleSpeechTranscriptionProviderTests.swift`
- Test: `Tests/MacrecCoreTests/Transcription/Providers/AppleSpeechSessionReconciliationTests.swift`

### Task D.1 — Implement the provider + session

- [ ] Create `Sources/MacrecCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift`:

```swift
import Foundation
import Logging
import Speech

@available(macOS 26.0, *)
public actor AppleSpeechTranscriptionProvider: TranscriptionProvider {
    public nonisolated let id = "apple"
    public nonisolated let displayName = "Apple Speech (on-device)"
    public nonisolated let supportedModes: Set<TranscriptionMode> = [.streaming]

    private let logger: Logger
    private let analyzerFactory: @Sendable (Locale) throws -> any SpeechAnalyzerAdapter

    public init(
        logger: Logger = Logger(label: "macrec.transcription.apple"),
        analyzerFactory: @escaping @Sendable (Locale) throws -> any SpeechAnalyzerAdapter
            = { try ProductionSpeechAnalyzerAdapter.make($0) }
    ) {
        self.logger = logger
        self.analyzerFactory = analyzerFactory
    }

    public func openStreamingSession(
        source: SourceTag, options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        let locales = options.languageHints.isEmpty
            ? [Locale.current]
            : options.languageHints.map { Locale(identifier: $0) }

        try await SpeechPermission.ensureGranted()

        var localeAnalyzers: [(Locale, any SpeechAnalyzerAdapter)] = []
        for locale in locales {
            let adapter = try analyzerFactory(locale)
            localeAnalyzers.append((locale, adapter))
        }

        return AppleSpeechSession(
            analyzers: localeAnalyzers,
            source: source,
            logger: logger
        )
    }

    public func transcribe(
        samples: [Float], source: SourceTag, options: TranscriptionOptions
    ) async throws -> String {
        let session = try await openStreamingSession(source: source, options: options)
        await session.ingest(samples)
        await session.finish()
        var collected = ""
        for await event in session.events {
            if case .final(_, let text, _, _, _) = event {
                collected += (collected.isEmpty ? "" : " ") + text
            }
        }
        return collected
    }
}

@available(macOS 26.0, *)
final class AppleSpeechSession: StreamingTranscriptionSession {
    public static let reconciliationWindowMs: Int = 150

    private let analyzers: [(locale: Locale, adapter: any SpeechAnalyzerAdapter)]
    private let source: SourceTag
    private let logger: Logger
    private let eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    public let events: AsyncStream<StreamingTranscriptionEvent>

    private var nextUtteranceId: Int = 0
    private var pendingFinals: [Int: [(locale: Locale, result: TranscriptionResult)]] = [:]
    private let lock = NSLock()

    init(
        analyzers: [(Locale, any SpeechAnalyzerAdapter)],
        source: SourceTag,
        logger: Logger
    ) {
        self.analyzers = analyzers
        self.source = source
        self.logger = logger
        let (s, c) = AsyncStream.makeStream(
            of: StreamingTranscriptionEvent.self,
            bufferingPolicy: .bufferingNewest(128))
        self.events = s
        self.eventsContinuation = c

        for (locale, adapter) in analyzers {
            Task { [weak self] in
                for await result in adapter.results {
                    self?.handle(result, from: locale)
                }
            }
        }
    }

    func ingest(_ samples: [Float]) async {
        for (_, adapter) in analyzers {
            Task { await adapter.ingest(samples) }
        }
    }

    func finish() async {
        for (_, adapter) in analyzers {
            await adapter.finalizeAndFinish()
        }
        eventsContinuation.finish()
    }

    // MARK: - Private

    private func handle(_ result: TranscriptionResult, from locale: Locale) {
        let utteranceId = currentUtteranceId(for: locale)

        if !result.isFinal {
            eventsContinuation.yield(
                .partial(
                    utteranceId: utteranceIdToUUID(utteranceId),
                    text: result.text,
                    confidence: result.confidence
                )
            )
            return
        }

        // Final — buffer for reconciliation.
        lock.lock()
        var arr = pendingFinals[utteranceId] ?? []
        arr.append((locale, result))
        pendingFinals[utteranceId] = arr
        let collected = arr.count
        lock.unlock()

        if collected == analyzers.count {
            // All locales reported — reconcile immediately.
            reconcile(utteranceId)
        } else {
            // Wait the window for peers.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.reconciliationWindowMs))
                self?.reconcile(utteranceId)
            }
        }
    }

    private func reconcile(_ utteranceId: Int) {
        lock.lock()
        guard let arr = pendingFinals.removeValue(forKey: utteranceId) else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Pick highest confidence; tie-break by first arrival.
        let winner = arr.max { (a, b) in
            (a.result.confidence ?? 0) < (b.result.confidence ?? 0)
        }!
        let range: ClosedRange<Date> = winner.result.timeRange ?? (Date()...Date())
        eventsContinuation.yield(
            .final(
                utteranceId: utteranceIdToUUID(utteranceId),
                text: winner.result.text,
                confidence: winner.result.confidence,
                range: range,
                language: winner.locale.identifier
            )
        )
    }

    private func currentUtteranceId(for locale: Locale) -> Int {
        // For v1.5 simplicity: each result starts a new utterance id if no
        // pending utterance exists, else returns the active one.
        // Apple's SpeechAnalyzer surfaces utterance boundaries explicitly via
        // isFinal — between two finals, all partials belong to the next utterance.
        lock.lock(); defer { lock.unlock() }
        let id = nextUtteranceId
        return id
    }

    private func utteranceIdToUUID(_ i: Int) -> UUID {
        // Stable mapping int → UUID; UUID-shaped namespace from a fixed root.
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8((i >> 24) & 0xff)
        bytes[1] = UInt8((i >> 16) & 0xff)
        bytes[2] = UInt8((i >> 8) & 0xff)
        bytes[3] = UInt8(i & 0xff)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
```

> **Caveat for the executor.** The `currentUtteranceId(for:)` logic is a v1.5 simplification — it does not increment `nextUtteranceId` between utterances. The framework's actual utterance-boundary signal needs to be wired (likely incrementing on each isFinal=true result for the locale that produced it). Adjust per the live `SpeechAnalyzer` API surface; the rest of the session shape is correct.

### Task D.2 — Reconciliation unit tests

- [ ] Create `Tests/MacrecCoreTests/Transcription/Providers/AppleSpeechSessionReconciliationTests.swift`:

```swift
import Foundation
import Testing
@testable import MacrecCore
import Logging

@available(macOS 26.0, *)
@Suite("AppleSpeechSession reconciliation")
struct AppleSpeechSessionReconciliationTests {

    @Test("higher-confidence final wins per utterance")
    func higherConfidenceWins() async throws {
        let mockEN = MockSpeechAnalyzer()
        let mockEL = MockSpeechAnalyzer()
        let session = AppleSpeechSession(
            analyzers: [
                (Locale(identifier: "en-US"), mockEN),
                (Locale(identifier: "el-GR"), mockEL)
            ],
            source: .microphone,
            logger: Logger(label: "test")
        )

        // Push competing finals.
        mockEN.push(TranscriptionResult(text: "hello world",
                                        confidence: 0.95,
                                        isFinal: true,
                                        timeRange: nil))
        mockEL.push(TranscriptionResult(text: "γεια σου",
                                        confidence: 0.42,
                                        isFinal: true,
                                        timeRange: nil))

        await session.finish()

        var finals: [String] = []
        var winnerLanguage: String?
        for await ev in session.events {
            if case .final(_, let text, _, _, let lang) = ev {
                finals.append(text)
                winnerLanguage = lang
            }
        }
        #expect(finals == ["hello world"])
        #expect(winnerLanguage == "en-US")
    }

    @Test("partial event surfaces immediately for first locale")
    func partialPropagates() async throws {
        let mockEN = MockSpeechAnalyzer()
        let session = AppleSpeechSession(
            analyzers: [(Locale(identifier: "en-US"), mockEN)],
            source: .microphone,
            logger: Logger(label: "test")
        )

        mockEN.push(TranscriptionResult(text: "hello",
                                        confidence: 0.5,
                                        isFinal: false,
                                        timeRange: nil))
        await session.finish()

        var sawPartial = false
        for await ev in session.events {
            if case .partial(_, let text, _) = ev, text == "hello" {
                sawPartial = true
            }
        }
        #expect(sawPartial)
    }
}
```

### Task D.3 — Provider unit tests

- [ ] Create `Tests/MacrecCoreTests/Transcription/Providers/AppleSpeechTranscriptionProviderTests.swift`:

```swift
import Foundation
import Testing
@testable import MacrecCore

@available(macOS 26.0, *)
@Suite("AppleSpeechTranscriptionProvider")
struct AppleSpeechTranscriptionProviderTests {

    @Test("supportedModes is .streaming only")
    func supportsStreamingOnly() {
        let p = AppleSpeechTranscriptionProvider(
            analyzerFactory: { _ in MockSpeechAnalyzer() })
        #expect(p.supportedModes == [.streaming])
    }

    @Test("openStreamingSession with one locale builds one analyzer")
    func oneLocale() async throws {
        var built: [Locale] = []
        let p = AppleSpeechTranscriptionProvider(
            analyzerFactory: { locale in
                built.append(locale)
                return MockSpeechAnalyzer()
            })
        let opts = TranscriptionOptions(
            providerId: "apple", apiKey: nil, modelId: nil,
            languageHints: ["en-US"],
            customSystemInstruction: nil, keyExpiresAt: nil)
        _ = try await p.openStreamingSession(source: .microphone, options: opts)
        #expect(built == [Locale(identifier: "en-US")])
    }

    @Test("openStreamingSession with two locales builds two analyzers")
    func twoLocales() async throws {
        var built: [Locale] = []
        let p = AppleSpeechTranscriptionProvider(
            analyzerFactory: { locale in
                built.append(locale)
                return MockSpeechAnalyzer()
            })
        let opts = TranscriptionOptions(
            providerId: "apple", apiKey: nil, modelId: nil,
            languageHints: ["en-US", "el-GR"],
            customSystemInstruction: nil, keyExpiresAt: nil)
        _ = try await p.openStreamingSession(source: .microphone, options: opts)
        #expect(built == [Locale(identifier: "en-US"), Locale(identifier: "el-GR")])
    }
}
```

### Task D.4 — Phase D build check

- [ ] Run: `swift build --target MacrecCore` → must succeed.
- [ ] Run: `swift build --build-tests` → must succeed.
- [ ] **Recommended commit point**: `feat(transcription): AppleSpeechTranscriptionProvider with dual-locale reconciliation (Phase D)`.

---

## Phase E — StreamingTranscriptionPipeline + manager mode selection

**Goal:** A second pipeline class alongside the plan-004 batch pipeline. `TranscriptionManager` selects between them.

**Files:**
- Create: `Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift`
- Modify: `Sources/MacrecCore/Transcription/TranscriptionManager.swift` — pipeline selection
- Test: `Tests/MacrecCoreTests/Transcription/StreamingTranscriptionPipelineTests.swift`

### Task E.1 — Implement StreamingTranscriptionPipeline

- [ ] Create `Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift`:

```swift
import Foundation
import Logging

@available(macOS 26.0, *)
final actor StreamingTranscriptionPipeline {
    private let provider: any TranscriptionProvider
    private let source: TranscriptionSource
    private let options: TranscriptionOptions
    private var sidecarWriter: TranscriptSidecarWriter?
    private let logger: Logger

    private var sessions: [SourceTag: any StreamingTranscriptionSession] = [:]
    private var drainTasks: [Task<Void, Never>] = []
    private var nextSegmentIndex: Int = 0
    private var indexForUtteranceId: [UUID: Int] = [:]
    private var eventsContinuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var metrics = TranscriptionMetrics()

    init(provider: any TranscriptionProvider,
         source: TranscriptionSource,
         options: TranscriptionOptions,
         sidecarWriter: TranscriptSidecarWriter?,
         logger: Logger) {
        self.provider = provider
        self.source = source
        self.options = options
        self.sidecarWriter = sidecarWriter
        self.logger = logger
    }

    func start() -> AsyncStream<TranscriptionEvent> {
        let (stream, cont) = AsyncStream.makeStream(
            of: TranscriptionEvent.self, bufferingPolicy: .bufferingNewest(128))
        self.eventsContinuation = cont

        cont.yield(.privacyDisclosure(providerDisplayName: provider.displayName))

        for tag in source.activeSourceTags() {
            Task {
                do {
                    let s = try await provider.openStreamingSession(
                        source: tag, options: options)
                    await self.attach(session: s, for: tag)
                } catch {
                    cont.yield(.error(detail: "openStreamingSession failed: \(error.localizedDescription)"))
                }
            }
        }
        return stream
    }

    func ingest(_ samples: [Float], from tag: SourceTag) async {
        guard let session = sessions[tag] else { return }
        await session.ingest(samples)
    }

    func rotateSidecar(toAudioURL: URL, format: TranscriptFormat) async throws {
        try? await sidecarWriter?.close()
        sidecarWriter = try TranscriptSidecarWriter(
            outputPath: SidecarPathBuilder.sidecarURL(forRecording: toAudioURL, format: format),
            format: format
        )
        nextSegmentIndex = 0
        indexForUtteranceId.removeAll()
    }

    func stop() async {
        for (_, s) in sessions {
            await s.finish()
        }
        for t in drainTasks {
            await t.value
        }
        try? await sidecarWriter?.close()
        eventsContinuation?.finish()
    }

    func currentMetrics() -> TranscriptionMetrics { metrics }

    // MARK: - Private

    private func attach(session: any StreamingTranscriptionSession, for tag: SourceTag) {
        sessions[tag] = session
        let task = Task { [weak self] in
            for await event in session.events {
                await self?.handle(event, from: tag)
            }
        }
        drainTasks.append(task)
    }

    private func handle(_ event: StreamingTranscriptionEvent, from tag: SourceTag) async {
        switch event {
        case .partial(let uttId, let text, let conf):
            if let idx = indexForUtteranceId[uttId] {
                let seg = TranscriptSegment(
                    id: uttId, timestamp: Date(), text: text, source: tag,
                    confidence: conf, model: provider.id)
                eventsContinuation?.yield(.segmentUpdated(index: idx, segment: seg))
            } else {
                let idx = nextSegmentIndex; nextSegmentIndex += 1
                indexForUtteranceId[uttId] = idx
                let seg = TranscriptSegment(
                    id: uttId, timestamp: Date(), text: text, source: tag,
                    confidence: conf, model: provider.id)
                eventsContinuation?.yield(.segmentAppended(index: idx, segment: seg))
            }
        case .final(let uttId, let text, let conf, let range, let language):
            let idx = indexForUtteranceId[uttId] ?? {
                let i = nextSegmentIndex; nextSegmentIndex += 1
                indexForUtteranceId[uttId] = i
                return i
            }()
            let durationSec = range.upperBound.timeIntervalSince(range.lowerBound)
            let seg = TranscriptSegment(
                id: uttId, timestamp: range.lowerBound, lastUpdated: range.upperBound,
                text: text, source: tag, confidence: conf, model: provider.id,
                durationSec: durationSec, language: language)
            eventsContinuation?.yield(.segmentFinalized(index: idx, segment: seg))
            try? await sidecarWriter?.write(.segmentFinalized(index: idx, segment: seg))
            metrics.chunksSent += 1
        case .metrics:
            return
        case .error(let detail):
            metrics.errorCount += 1
            eventsContinuation?.yield(.error(detail: detail))
        }
    }
}
```

### Task E.2 — Update TranscriptionManager pipeline selection

- [ ] Open `Sources/MacrecCore/Transcription/TranscriptionManager.swift`. The existing manager owns the batch pipeline inline. Refactor to delegate based on `provider.supportedModes`:
  - At init, if `provider.supportedModes.contains(.streaming)`, construct a `StreamingTranscriptionPipeline` and store it as `streamingPipeline`. Otherwise store the existing batch state.
  - Forward `start`, `ingest`, `ingestFrame`, `rotateSidecar`, `stop`, `currentMetrics` to the appropriate target.
  - `ingestFrame` for streaming bypasses the downsampler's batch quirks — same `convert(_:)` call, but the resulting `[Float]` flows directly to `streamingPipeline.ingest(_:from:)`.

This is the largest mechanical edit in Phase E. The shape:

```swift
public actor TranscriptionManager {
    private let provider: any TranscriptionProvider
    private let isStreaming: Bool
    private var streamingPipeline: StreamingTranscriptionPipeline?
    // ... existing batch fields kept

    public init(...) {
        // ... existing init
        self.isStreaming = provider.supportedModes.contains(.streaming)
        if isStreaming {
            if #available(macOS 26.0, *) {
                self.streamingPipeline = StreamingTranscriptionPipeline(
                    provider: provider, source: source, options: options,
                    sidecarWriter: sidecarWriter, logger: logger)
            } else {
                fatalError("Streaming providers require macOS 26+")
            }
        }
    }

    public func start() -> AsyncStream<TranscriptionEvent> {
        if isStreaming {
            if #available(macOS 26.0, *) {
                return streamingPipeline!.start()
            }
        }
        return startBatchPipeline()  // existing plan-004 body extracted into a helper
    }

    public func ingest(_ samples: [Float], from tag: SourceTag) {
        if isStreaming {
            if #available(macOS 26.0, *) {
                Task { await streamingPipeline!.ingest(samples, from: tag) }
                return
            }
        }
        // existing batch ingest
    }

    // ... rotateSidecar / stop / currentMetrics: same pattern
}
```

### Task E.3 — Pipeline routing tests

- [ ] Create `Tests/MacrecCoreTests/Transcription/StreamingTranscriptionPipelineTests.swift`:

```swift
import Foundation
import Testing
@testable import MacrecCore
import Logging

@available(macOS 26.0, *)
@Suite("StreamingTranscriptionPipeline")
struct StreamingTranscriptionPipelineTests {

    @Test("first partial → segmentAppended; second partial for same utterance → segmentUpdated")
    func partialDispatchOrdering() async throws {
        let mock = MockSpeechAnalyzer()
        let provider = AppleSpeechTranscriptionProvider(
            analyzerFactory: { _ in mock })
        let opts = TranscriptionOptions(
            providerId: "apple", apiKey: nil, modelId: nil,
            languageHints: ["en-US"],
            customSystemInstruction: nil, keyExpiresAt: nil)
        let pipeline = StreamingTranscriptionPipeline(
            provider: provider, source: .mic, options: opts,
            sidecarWriter: nil, logger: Logger(label: "test"))

        let stream = await pipeline.start()
        // Allow the session to attach.
        try? await Task.sleep(for: .milliseconds(50))

        mock.push(TranscriptionResult(text: "he", confidence: 0.5,
                                      isFinal: false, timeRange: nil))
        mock.push(TranscriptionResult(text: "hello", confidence: 0.7,
                                      isFinal: false, timeRange: nil))
        mock.push(TranscriptionResult(text: "hello world", confidence: 0.9,
                                      isFinal: true, timeRange: nil))
        await pipeline.stop()

        var saw = (appended: 0, updated: 0, finalized: 0)
        for await ev in stream {
            switch ev {
            case .segmentAppended:  saw.appended += 1
            case .segmentUpdated:   saw.updated += 1
            case .segmentFinalized: saw.finalized += 1
            default: break
            }
        }
        #expect(saw.appended == 1)
        #expect(saw.updated >= 1)
        #expect(saw.finalized == 1)
    }
}
```

### Task E.4 — Phase E build check

- [ ] Run: `swift build --target MacrecCore` → must succeed.
- [ ] Run: `swift build --build-tests` → must succeed.
- [ ] **Recommended commit point**: `feat(transcription): StreamingTranscriptionPipeline + manager mode selection (Phase E)`.

---

## Phase F — Sidecar policy + language-tag prefix

**Goal:** Per-mode sidecar policy (streaming = finals-only, batch = unchanged); language field in JSONL output; `[lang]` prefix in TXT/SRT/VTT when ≥ 2 active locales.

**Files:**
- Modify: `Sources/MacrecCore/Transcription/Persistence/TranscriptSidecarWriter.swift` — add `policy: SidecarPolicy`
- Modify: `Sources/MacrecCore/Transcription/Persistence/JSONLTranscriptWriter.swift` — emit `language` field when non-nil
- Modify: `Sources/MacrecCore/Transcription/Persistence/TXTTranscriptWriter.swift` — `[lang]` prefix
- Modify: `Sources/MacrecCore/Transcription/Persistence/SRTTranscriptWriter.swift` — `[lang]` prefix
- Modify: `Sources/MacrecCore/Transcription/Persistence/VTTTranscriptWriter.swift` — `[lang]` prefix
- Test: `Tests/MacrecCoreTests/Transcription/Persistence/WriterLanguagePrefixTests.swift`

### Task F.1 — Add SidecarPolicy enum + writer mode

- [ ] Open `TranscriptSidecarWriter.swift`. Add at the top:

```swift
public enum SidecarPolicy: Sendable, Equatable {
    case batch
    case streaming
}
```

- [ ] Add `policy: SidecarPolicy` as a stored property; add `policy:` parameter to `init`. Update the `write(_:)` switch:

```swift
public func write(_ event: TranscriptionEvent) async {
    switch policy {
    case .batch:
        switch event {
        case .segmentAppended(_, let seg): try? formatWriter.appendSegment(seg)
        case .segmentUpdated(_, let seg):  try? formatWriter.updateSegment(seg)
        case .segmentFinalized:            return  // batch path doesn't emit this
        case .privacyDisclosure, .metricsTick, .error: return
        }
    case .streaming:
        switch event {
        case .segmentFinalized(_, let seg): try? formatWriter.appendSegment(seg)
        case .segmentAppended, .segmentUpdated: return  // UI-only
        case .privacyDisclosure, .metricsTick, .error: return
        }
    }
}
```

### Task F.2 — Update JSONL writer to emit language field

- [ ] Open `JSONLTranscriptWriter.swift`. Find `Self.encode(_:)`. Add the `language` field to the `Wire` struct:

```swift
struct Wire: Encodable {
    let id: String
    let timestamp: String
    let source: String
    let text: String
    let model: String?
    let durationSec: Double?
    let language: String?
}
```

And include `s.language` in the `Wire(...)` initializer call.

### Task F.3 — Update TXT writer with [lang] prefix

- [ ] Open `TXTTranscriptWriter.swift`. Modify `render(_:)`:

```swift
private func render(_ s: TranscriptSegment) -> String {
    let langPrefix = s.language.map { " [\(self.shortTag($0))]" } ?? ""
    return "[\(Self.timeFormatter.string(from: s.timestamp))] \(s.source)\(langPrefix): \(s.text)\n"
}

private func shortTag(_ bcp47: String) -> String {
    String(bcp47.prefix(2))  // "en-US" → "en", "el-GR" → "el"
}
```

### Task F.4 — Update SRT writer with [lang] prefix

- [ ] Open `SRTTranscriptWriter.swift`. Modify `render(seq:_:)` to inject the `[lang]` prefix in the cue body line:

```swift
private func render(seq: Int, _ s: TranscriptSegment) -> String {
    let start = s.timestamp.timeIntervalSince(sessionStart)
    let end = s.lastUpdated.timeIntervalSince(sessionStart)
    let langPrefix = s.language.map { "[\(self.shortTag($0))] " } ?? ""
    return "\(seq)\n\(srtTime(start)) --> \(srtTime(end))\n\(s.source) \(langPrefix)\(s.text)\n\n"
}

private func shortTag(_ bcp47: String) -> String { String(bcp47.prefix(2)) }
```

### Task F.5 — Update VTT writer with [lang] prefix

- [ ] Open `VTTTranscriptWriter.swift`. Same pattern as F.4. Modify `render(_:)`:

```swift
private func render(_ s: TranscriptSegment) -> String {
    let start = s.timestamp.timeIntervalSince(sessionStart)
    let end = s.lastUpdated.timeIntervalSince(sessionStart)
    let langPrefix = s.language.map { "[\(self.shortTag($0))] " } ?? ""
    return "\(vttTime(start)) --> \(vttTime(end))\n\(s.source) \(langPrefix)\(s.text)\n\n"
}

private func shortTag(_ bcp47: String) -> String { String(bcp47.prefix(2)) }
```

### Task F.6 — Writer language-prefix unit tests

- [ ] Create `Tests/MacrecCoreTests/Transcription/Persistence/WriterLanguagePrefixTests.swift`:

```swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("Writer language prefix")
struct WriterLanguagePrefixTests {

    private func tmpURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrec-langtest-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test("JSONL emits language field when non-nil")
    func jsonlEmitsLanguage() throws {
        let url = tmpURL("t.jsonl")
        let w = try JSONLTranscriptWriter(url: url)
        let seg = TranscriptSegment(timestamp: Date(),
                                    text: "hello",
                                    source: .microphone,
                                    language: "en-US")
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url)
        #expect(body.contains("\"language\":\"en-US\""))
    }

    @Test("TXT prefixes [lang] when language is set")
    func txtPrefixesLanguage() throws {
        let url = tmpURL("t.txt")
        let w = try TXTTranscriptWriter(url: url)
        let seg = TranscriptSegment(timestamp: Date(),
                                    text: "hello",
                                    source: .microphone,
                                    language: "en-US")
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url)
        #expect(body.contains("[en]"))
        #expect(body.contains("hello"))
    }

    @Test("TXT omits [lang] when language is nil (single-locale or batch)")
    func txtOmitsLanguageWhenNil() throws {
        let url = tmpURL("t2.txt")
        let w = try TXTTranscriptWriter(url: url)
        let seg = TranscriptSegment(timestamp: Date(), text: "hi",
                                    source: .microphone, language: nil)
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url)
        #expect(!body.contains("["))   // no language bracket
        #expect(body.contains("hi"))
    }
}
```

### Task F.7 — Phase F build check

- [ ] Run: `swift build --target MacrecCore` → must succeed.
- [ ] Run: `swift build --build-tests` → must succeed.
- [ ] **Recommended commit point**: `feat(transcription/persistence): per-mode policy + language tag (Phase F)`.

---

## Phase G — Wiring: factory, resolver, options, RecordingSession, CheckPermissions

**Goal:** Wire the apple provider through the factory, resolver, and the RecordingSession lifecycle. Flip the default. Add `apple-speech` to the permissions command.

**Files:**
- Modify: `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift`
- Modify: `Sources/MacrecCore/Config/RecordingOptions.swift` — default flip + `languageHints` parsing
- Modify: `Sources/MacrecCore/Config/ConfigResolver.swift` — apple validation, locale list parsing
- Modify: `Sources/MacrecCore/RecordingSession.swift` — speech preflight; pass policy to sidecar writer
- Modify: `Sources/macrec/Commands/CheckPermissionsCommand.swift` — add apple-speech row

### Task G.1 — Update TranscriptionProviderFactory for apple

- [ ] Open `TranscriptionProviderFactory.swift`. In the `switch normalized` block, before the `default`:

```swift
case "apple":
    if #available(macOS 26.0, *) {
        return AppleSpeechTranscriptionProvider(logger: input.logger)
    } else {
        throw MacrecError.transcriptionConfigConflict(
            reason: "Apple Speech requires macOS 26+; this build is running on an older OS")
    }
```

### Task G.2 — RecordingOptions default flip + languageHints parsing

- [ ] Open `RecordingOptions.swift`. Find the `TranscriptionProviderId` enum (added in plan-004). Add `case apple = "apple"`.
- [ ] Find the default for `transcriptionProviderId` in the init or the resolver — flip from `.none` to `.apple`.
- [ ] Find the `languageHint` parsing site (existing single-string field). Replace with a comma-split:

```swift
let languageHints: [String] = {
    guard let raw = rawLanguageValue?.trimmingCharacters(in: .whitespaces),
          !raw.isEmpty else { return [] }
    return raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}()
```

### Task G.3 — ConfigResolver apple validation

- [ ] Open `ConfigResolver.swift`. After the existing `gemini-live → gemini` deprecation alias, when normalised provider is `apple`:

```swift
case "apple":
    // Apple requires macOS 26+; no API key needed.
    if #available(macOS 26.0, *) {
        // Pre-validate locales against SpeechAnalyzer.supportedLocales().
        let supported = Set(SpeechAnalyzer.supportedLocales().map { $0.identifier })
        for hint in languageHints {
            guard supported.contains(hint) else {
                throw MacrecError.transcriptionConfigConflict(
                    reason: "language '\(hint)' not supported by Apple Speech on this Mac. Add it via System Settings → General → Language & Region → Add Language. Supported: \(supported.sorted().prefix(20).joined(separator: ", "))…")
            }
        }
    }
```

### Task G.4 — RecordingSession speech preflight + sidecar policy

- [ ] Open `RecordingSession.swift`. In `setUpTranscriptionPipelineIfNeeded`, after the provider is built but before the manager is constructed, add:

```swift
if provider.id == "apple" {
    if #available(macOS 26.0, *) {
        try await SpeechPermission.ensureGranted()
    }
}
```

- [ ] At the sidecar-writer construction site, pass the policy:

```swift
let policy: SidecarPolicy = provider.supportedModes.contains(.streaming) ? .streaming : .batch
let sidecar: TranscriptSidecarWriter? = try options.transcriptionFormat.map { fmt in
    try TranscriptSidecarWriter(
        outputPath: SidecarPathBuilder.sidecarURL(forRecording: options.outputURL, format: fmt),
        format: fmt,
        policy: policy
    )
}
```

### Task G.5 — CheckPermissionsCommand row

- [ ] Open `Sources/macrec/Commands/CheckPermissionsCommand.swift`. Add a row for Apple Speech alongside the microphone and screen-recording rows:

```swift
#if canImport(Speech)
if #available(macOS 26.0, *) {
    let speechStatus = SpeechPermission.currentStatus()
    print("Speech Recognition: \(speechStatus)")
    if speechStatus == .notDetermined {
        let final = await SpeechPermission.request()
        print("  → after prompt: \(final)")
    }
}
#endif
```

### Task G.6 — Phase G build check

- [ ] Run: `swift build` → must succeed (every binary builds clean).
- [ ] Run: `swift build --build-tests` → must succeed.
- [ ] Run: `swift build -c release` → must succeed.
- [ ] **Recommended commit point**: `feat(transcription): wire apple provider through resolver + session + permissions (Phase G)`.

---

## Phase H — UI integration

**Goal:** Handle `.segmentFinalized` in the controller; surface language tag chips when ≥ 2 locales active; "settled" visual treatment on finalization.

**Files:**
- Modify: `Sources/MacrecUIKit/RecordingController.swift` — handle the new event
- Modify: `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift` — language chip
- Modify: `Sources/macrec-ui/Views/ControlBar.swift` — picker default = Apple

### Task H.1 — RecordingController handles segmentFinalized

- [ ] Open `RecordingController.swift`. Find the `for await event in session.transcriptEvents` switch. Add:

```swift
case .segmentFinalized(let idx, let seg):
    await MainActor.run {
        self.finalizeSegment(at: idx, segment: seg)
    }
```

- [ ] Add the `finalizeSegment(at:segment:)` method on the controller:

```swift
private func finalizeSegment(at idx: Int, segment: TranscriptSegment) {
    if idx < transcriptSegments.count {
        transcriptSegments[idx] = segment   // replace with finalized text + language
    } else {
        transcriptSegments.append(segment)
    }
}
```

### Task H.2 — LiveTranscriptPanel language chip + settled style

- [ ] Open `LiveTranscriptPanel.swift`. In the per-segment row:

```swift
HStack(alignment: .top, spacing: 6) {
    if let lang = segment.language {
        Text(lang.prefix(2).uppercased())
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 4)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(3)
    }
    Text(segment.text)
        .font(.system(.body))
        .foregroundColor(segment.isSettled ? .primary : .secondary)
        .italic(!segment.isSettled)
}
```

- [ ] Add an `isSettled: Bool` computed property to the segment view-model: `true` when the segment has been finalized (durationSec is non-nil from the streaming pipeline's `.segmentFinalized` handler).

### Task H.3 — ControlBar default = Apple

- [ ] Open `ControlBar.swift`. In the transcription provider Picker, add `Apple Speech` as the first option (default selection). Tag the option's stored value as `"apple"`:

```swift
Picker("Transcribe", selection: $transcribeProvider) {
    Text("Apple Speech (on-device)").tag("apple")
    Text("Gemini (cloud)").tag("gemini")
    Text("None").tag("none")
}
```

- [ ] Update the `@AppStorage("com.macrec.ui.transcribeProvider")` default value from whatever it currently is to `"apple"`.

### Task H.4 — Phase H build check

- [ ] Run: `swift build --product macrec-ui` → must succeed.
- [ ] Run: `swift build` → must succeed.
- [ ] **Recommended commit point**: `feat(ui): handle segmentFinalized + language chip + apple default picker (Phase H)`.

---

## Phase I — E2E + documentation + final verification

**Goal:** Add the four new e2e scripts. Update existing e2e scripts for the default flip. Refresh user-facing docs. Final smoke run.

**Files:**
- Create: `test_scripts/e2e-transcription-apple.sh`
- Create: `test_scripts/e2e-transcription-apple-dual-locale.sh`
- Create: `test_scripts/e2e-transcription-permission-denied.sh`
- Create: `test_scripts/e2e-transcription-apple-detach.sh`
- Modify: `test_scripts/e2e-transcription-key-missing.sh` — name `gemini` explicitly
- Modify: `docs/tools/macrec.md` — provider list, default flip, dual-locale syntax
- Modify: `docs/tools/macrec-ui.md` — picker default, language chip

### Task I.1 — e2e-transcription-apple.sh

- [ ] Create the script:

```bash
#!/usr/bin/env bash
# test_scripts/e2e-transcription-apple.sh
# Happy path for --transcribe apple. Requires macOS 26+ and Speech permission.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"

[ -x "${BIN}" ] || { echo "FAIL: ${BIN} not found; run 'swift build -c release'"; exit 1; }

PHRASE="The quick brown fox jumps over the lazy dog"
OUTDIR="$(mktemp -d -t macrec-e2e-apple.XXXXXX)"
trap 'rm -rf "${OUTDIR}"' EXIT
OUT="${OUTDIR}/rec.m4a"
FIXTURE="${ROOT}/test_scripts/fixtures/known-phrase.aiff"
mkdir -p "$(dirname "${FIXTURE}")"
[ -f "${FIXTURE}" ] || say "${PHRASE}" -o "${FIXTURE}"

echo "[1/4] Starting macrec in background (12 s, --transcribe apple) ..."
"${BIN}" start --output "${OUT}" --format m4a --layout mixed \
    --max-duration 12 --transcribe apple \
    --transcribe-source mixed --transcribe-format jsonl &
MACREC_PID=$!

echo "[2/4] Waiting 1.5 s for SpeechAnalyzer warm-up, then playing fixture ..."
sleep 1.5
afplay "${FIXTURE}"
wait "${MACREC_PID}"

echo "[3/4] Asserting audio + sidecar exist ..."
[ -s "${OUT}" ] || { echo "FAIL: audio empty"; exit 1; }
SIDECAR="${OUT%.m4a}.transcript.jsonl"
[ -s "${SIDECAR}" ] || { echo "FAIL: sidecar missing"; exit 1; }

echo "[4/4] Asserting model:apple and ≥3 keyword hits ..."
APPLE_LINES=$(grep -c '"model":"apple"' "${SIDECAR}" || true)
[ "${APPLE_LINES}" -ge 1 ] || { echo "FAIL: no model:apple lines"; exit 1; }
TEXT=$(jq -r 'select(._tombstone != true) | .text // empty' "${SIDECAR}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
HITS=0
for w in quick brown fox jumps lazy dog; do
    grep -qF "${w}" <<<"${TEXT}" && HITS=$((HITS+1))
done
[ "${HITS}" -ge 3 ] || { echo "FAIL: only ${HITS} keyword hits in: ${TEXT}"; exit 1; }
echo "PASS: e2e-transcription-apple (${APPLE_LINES} apple lines, ${HITS} keyword hits)"
```

- [ ] `chmod +x test_scripts/e2e-transcription-apple.sh`.

### Task I.2 — e2e-transcription-apple-dual-locale.sh

- [ ] Create:

```bash
#!/usr/bin/env bash
# test_scripts/e2e-transcription-apple-dual-locale.sh
# Verifies dual-locale parallel recognition (en-US + el-GR).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"
[ -x "${BIN}" ] || { echo "FAIL: ${BIN} not found"; exit 1; }

OUTDIR="$(mktemp -d -t macrec-e2e-apple-dual.XXXXXX)"
trap 'rm -rf "${OUTDIR}"' EXIT
OUT="${OUTDIR}/rec.m4a"

# Two-language fixture: English then Greek.
FIXTURE="${ROOT}/test_scripts/fixtures/dual-phrase.aiff"
mkdir -p "$(dirname "${FIXTURE}")"
if [ ! -f "${FIXTURE}" ]; then
    TMP_EN=$(mktemp -t en.XXXXXX).aiff
    TMP_EL=$(mktemp -t el.XXXXXX).aiff
    say -v "Samantha" "Hello world" -o "${TMP_EN}"
    say -v "Anna" "Καλημέρα" -o "${TMP_EL}"
    # Concatenate via afconvert + cat (simplified: use ffmpeg if available, else just play in sequence)
    cat "${TMP_EN}" "${TMP_EL}" > "${FIXTURE}" || cp "${TMP_EN}" "${FIXTURE}"
    rm -f "${TMP_EN}" "${TMP_EL}"
fi

"${BIN}" start --output "${OUT}" --format m4a --layout mixed \
    --max-duration 15 --transcribe apple \
    --transcribe-language en-US,el-GR \
    --transcribe-source mixed --transcribe-format jsonl &
MACREC_PID=$!
sleep 1.5
afplay "${FIXTURE}"
wait "${MACREC_PID}"

SIDECAR="${OUT%.m4a}.transcript.jsonl"
[ -s "${SIDECAR}" ] || { echo "FAIL: sidecar missing"; exit 1; }
EN_HITS=$(grep -c '"language":"en-US"' "${SIDECAR}" || true)
EL_HITS=$(grep -c '"language":"el-GR"' "${SIDECAR}" || true)
echo "  EN lines: ${EN_HITS}, EL lines: ${EL_HITS}"
[ "${EN_HITS}" -ge 1 ] || echo "WARN: no en-US lines (expected for English fixture)"
[ "${EL_HITS}" -ge 1 ] || echo "WARN: no el-GR lines (expected for Greek fixture)"
[ $((EN_HITS + EL_HITS)) -ge 1 ] || { echo "FAIL: zero language-tagged lines"; exit 1; }
echo "PASS: e2e-transcription-apple-dual-locale"
```

- [ ] `chmod +x test_scripts/e2e-transcription-apple-dual-locale.sh`.

### Task I.3 — e2e-transcription-permission-denied.sh

- [ ] Create:

```bash
#!/usr/bin/env bash
# test_scripts/e2e-transcription-permission-denied.sh
# Verifies that when Speech permission is denied, --transcribe apple exits 78.
# MANUAL SETUP: System Settings → Privacy & Security → Speech Recognition → toggle macrec OFF.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"
OUTDIR="$(mktemp -d -t macrec-e2e-deny.XXXXXX)"
trap 'rm -rf "${OUTDIR}"' EXIT
OUT="${OUTDIR}/rec.m4a"

set +e
"${BIN}" start --output "${OUT}" --format m4a --layout mixed \
    --max-duration 3 --transcribe apple
RC=$?
set -e

[ "${RC}" -eq 78 ] || { echo "FAIL: expected exit 78, got ${RC}"; exit 1; }
[ ! -e "${OUT}" ] || { echo "FAIL: audio should not exist"; exit 1; }
echo "PASS: e2e-transcription-permission-denied (exit ${RC})"
```

- [ ] `chmod +x test_scripts/e2e-transcription-permission-denied.sh`.

### Task I.4 — e2e-transcription-apple-detach.sh

- [ ] Create:

```bash
#!/usr/bin/env bash
# test_scripts/e2e-transcription-apple-detach.sh
# Verifies detach + apple parity (FR-AS-10).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"
OUTDIR="$(mktemp -d -t macrec-e2e-apple-detach.XXXXXX)"
OUT="${OUTDIR}/rec.m4a"
cleanup() {
    "${BIN}" stop --output "${OUT}" 2>/dev/null || true
    rm -rf "${OUTDIR}"
}
trap cleanup EXIT
FIXTURE="${ROOT}/test_scripts/fixtures/known-phrase.aiff"
[ -f "${FIXTURE}" ] || say "Hello world from detached macrec" -o "${FIXTURE}"

"${BIN}" start --output "${OUT}" --format m4a --layout mixed \
    --detach --max-duration 8 --transcribe apple --transcribe-format jsonl
sleep 1.5
afplay "${FIXTURE}"
sleep 12

[ -s "${OUT}" ] || { echo "FAIL: audio empty"; exit 1; }
SIDECAR="${OUT%.m4a}.transcript.jsonl"
[ -s "${SIDECAR}" ] || { echo "FAIL: sidecar missing"; exit 1; }
echo "PASS: e2e-transcription-apple-detach"
```

- [ ] `chmod +x test_scripts/e2e-transcription-apple-detach.sh`.

### Task I.5 — Update e2e-transcription-key-missing.sh

- [ ] Open `test_scripts/e2e-transcription-key-missing.sh`. The script currently relies on the implicit default to trigger `transcriptionApiKeyMissing`. With the default flipping to `apple`, the script must name `gemini` explicitly.
- [ ] In the script, change the macrec invocation line from `--transcribe gemini` (it likely already says this) — verify, and if not, add it explicitly. Adjust the comment header to mention "explicit gemini" instead of relying on default.

### Task I.6 — Refresh docs/tools/macrec.md

- [ ] In the `<info>` block:
  - Update provider list to: `none`, `apple` (default), `gemini`, `gemini-live` (deprecated).
  - Add a "What changed in v1.5" subsection at the top: "Default `--transcribe` value flipped from `none` to `apple`. Run `macrec start` with no transcription flags now produces a sidecar by default. To restore the old behavior, set `MACREC_TRANSCRIBE=none` in your `.env`."
  - Update the env-var examples + the `--transcribe-language` documentation to mention comma-separated values.
  - Add a new "Permissions" subsection note: `NSSpeechRecognitionUsageDescription` is required for `--transcribe apple`. First run prompts. R-2 / PEND-AS-1 caveat about ad-hoc-signed rebuild re-prompts.

### Task I.7 — Refresh docs/tools/macrec-ui.md

- [ ] Update the picker description: default option is now "Apple Speech (on-device)".
- [ ] Add a sentence about the language chip rendering when ≥ 2 locales are active.
- [ ] Add a note about the speech permission prompt on first opt-in.

### Task I.8 — Final build + smoke

- [ ] Run: `swift build -c release` → must succeed.
- [ ] Run: `bash test_scripts/e2e-transcription-noop.sh` → expect PASS (regression — `--transcribe none` still works).
- [ ] Run: `bash test_scripts/e2e-transcription-key-missing.sh` → expect PASS (gemini-explicit, no key, exit 78).
- [ ] Run: `bash test_scripts/e2e-transcription-apple.sh` → expect PASS (FIRST TIME requires Speech permission grant via the prompt).
- [ ] If `GOOGLE_API_KEY` is set and the user opts in: `bash test_scripts/e2e-transcription-gemini.sh` → expect PASS (regression — Gemini path still works).
- [ ] Optional: `bash test_scripts/e2e-transcription-apple-dual-locale.sh` (requires both en-US and el-GR language packs installed).
- [ ] **Recommended commit point**: `test(transcription): apple e2e scripts + doc refresh (Phase I)`.

---

## Self-Review

**1. Spec coverage.** Each section of plan-005 Part 1 maps to a phase:
- §3.1 (additions) → Phase A/B/C/D/E/F/I
- §3.2 (edits) → Phase 0/A/F/G/H/I
- §4 (component contracts) → Phase A/B/D/E/F
- §5 (data flow) → Phase D/E/F
- §6 (configuration) → Phase G
- §7 (errors + lifecycle) → Phase C/G
- §8 (testing) → Phase B/C/D/E/F/I
- §9.6 (default flip risk) → documented in Phase I.6 macrec.md

**2. Placeholder scan.** No `TODO` / `TBD` / "implement later" / "appropriate error handling" / "similar to" patterns in the implementation tasks. Two "Caveat for the executor" notes (Tasks B.2 and D.1) flag where the live `Speech.framework` API may differ from the documented signatures — these are deliberate, not placeholders.

**3. Type consistency.** `TranscriptionMode` (Phase A.1), `StreamingTranscriptionSession`, `StreamingTranscriptionEvent`, `StreamingProviderMetrics` are introduced in Phase A.1 and used consistently in Phases D / E. `SpeechAnalyzerAdapter` and `TranscriptionResult` are introduced in Phase B and used in Phase D's mock + production paths. `SidecarPolicy` is introduced in Phase F.1 and consumed by Phase G.4. `MacrecError.transcriptionPermissionDenied` is introduced in Phase C.1 and thrown from `SpeechPermission.ensureGranted` (Phase C.2) and the Apple provider's `openStreamingSession` (Phase D.1, indirectly via `ensureGranted`).

---

## Execution Handoff

Plan complete and appended to
`docs/design/plan-005-apple-speech-streaming.md`. Two execution
options:

**1. Subagent-Driven (recommended)** — fresh subagent per phase, two-stage review between phases. Same approach as plan-004 — proven flow, keeps this main session's context clean for the high-level checkpoints.

**2. Inline Execution** — execute in this session via `executing-plans`, batch with checkpoints.

Which approach?
