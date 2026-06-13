# plan-010 — Dual-Provider Live Transcription Mode (Apple on-device EN + Apple Cloud EL)

**Type:** feature plan (Phase 4 of the 10-phase workflow).
**Date:** 2026-05-01.
**Scope:** add a NEW "Dual" live-transcription mode to `MacrecCore`, `macrec-ui`, and `macrec`, running `apple` (Channel A, on-device, English by default) and `apple-cloud` (Channel B, cloud, Greek by default) in parallel against the same captured audio. Single-mode UI and runtime MUST remain unchanged (hard constraint).

**Source documents:**
- Refined request: `docs/design/refined-request-dual-transcription.md` (FR-1..FR-11, NFR-1..NFR-7, AC-1..AC-11, A-1..A-6, OQ-1..OQ-6)
- Investigation: `docs/reference/investigation-dual-transcription.md` (Q1..Q7, recommendation 1A + 2A + 3B + 4A)
- Codebase scan: `docs/reference/codebase-scan-dual-transcription.md` (IP-1..IP-16)
- Reused investigation: `docs/reference/apple-cloud-stt-investigation-2026-05.md`
- Project conventions: `CLAUDE.md` (Exception 001 — Swift; Exception 002 — macOS 26)

**Cross-references:**
- plan-003 (live transcription baseline), plan-005 (Apple SpeechAnalyzer streaming), plan-007 (Apple Cloud + additional STT engines), plan-008 (UI redesign and theming)
- `Issues - Pending Items.md` PLAN-007-DONE-14 (Apple Cloud caveat)

---

## 0. Conventions adopted by this plan

- **Architecture (decided in investigation, not re-litigated here):** new `DualTranscriptionManager` actor (Option 1A) wrapping two `StreamingTranscriptionPipeline` instances; per-channel `AudioDownsampler` with synchronous fan-out (Option 2A); manual two-Task drain merging into one `AsyncStream<TranscriptionEvent>` (Option 3B); failure isolation per channel.
- **Naming:** new code lives under `Sources/MacrecCore/Transcription/Dual/` and `Sources/macrec-ui/Views/Transcription/Dual/` so the dual subsystem is grep-able and the single-mode subsystem is untouched.
- **AppStorage namespace:** all dual-mode keys live under the `com.macrec.ui.dual.*` prefix (full list in Phase A).
- **No fallback configuration:** if a Channel A or Channel B locale is missing at the manager construction site, the manager raises `MacrecError.transcriptionConfigurationMissing(field:)` rather than substituting a default. The spec-mandated defaults (`en-US` for A, `el-GR` for B) are persisted UI defaults — they are written into AppStorage at first use, never silently substituted at the engine layer.
- **File header comment:** every new file MUST follow the project convention `// <target>/<file>.swift — see project-design.md §<section>, plan-010 §<phase> (<FR-NN>)`.
- **Test framework:** Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest. Test scripts go under `test_scripts/`; in-target tests go under `Tests/MacrecCoreTests/Transcription/Dual/` and `Tests/MacrecUITests/Transcription/Dual/`.
- **Hard constraint enforcement:** every PR for this plan MUST run `Tests/MacrecUITests/ControlBarStartTappedKeysRegressionTests.swift` and verify Single-mode JSONL byte-equivalence (AC-1).

---

## 1. Open design questions deferred to Phase 5 (designer)

These are NOT resolved by this plan. They are listed here so the designer (Phase 5) closes them before any code lands.

1. **OQ-1 — Mode-switch control type.** Investigator recommends a segmented `Picker("Mode", selection:).pickerStyle(.segmented)` ["Single" | "Dual"] at the top of the Live Transcription panel (Option 4A). Designer may overrule in favour of Toggle below (4B), Tabbed sub-panel (4D), or a sub-section header. Whatever is chosen MUST satisfy AC-1 (Single-mode field controls render unchanged).
2. **OQ-3 — Exact CLI flag spelling.** Investigator recommends `--transcribe dual --transcribe-dual-locale-a en-US --transcribe-dual-locale-b el-GR` (Option A from codebase scan IP-11). Alternatives: reuse `--transcribe-language` / `--transcribe-language2`, or `--transcribe apple+apple-cloud`. Designer picks the final spelling and corresponding `MACREC_*` env-var names.
4. **OQ-4 — SRT/VTT channel-labelling convention when both channels overlap.** Investigator default: VTT uses `<v EN>...</v>` voice tags; SRT uses `EN: ...` / `EL: ...` cue speaker prefixes; cues are emitted in arrival order with overlapping start times allowed. Designer ratifies or proposes alternatives (e.g. interleaved with `NOTE` separators).
5. **OQ-6 — Generic vs. specific orchestrator.** Investigator recommends specific (`apple` + `apple-cloud` only) for v1 — generic N>2 SessionGroup is explicitly out of scope per refined request. Designer confirms and documents the rationale; if designer flips to generic, Phase B effort grows materially.
6. **OQ-5 — Dual-lane UI layout.** Side-by-side, stacked, or single chronological feed with channel chips. Driven by readability under the existing macrec-ui popover width. Designer picks; Phase G reserves the integration point.
7. **OQ-2 — Per-channel pause / disable semantics.** Refined request FR-11 says pause/resume/split apply to both channels atomically. OQ-2 raises whether Dual mode should additionally allow temporarily *disabling* one channel without leaving Dual mode. Designer decides (a) atomic-only (no per-channel disable), (b) per-channel enable toggles in the panel that gate `ingest` per channel, or (c) a per-channel mute that suppresses display but keeps transcription running.

The plan structure below assumes the investigator's defaults; if Phase 5 overrules any of them, only the affected phase changes (the actor signature, test list, and AppStorage keys are stable across all candidate UI/CLI shapes).

---

## 2. Phase decomposition

Ten phases, A through J. Sequential dependencies are noted; parallelisable lanes are called out per phase. Total estimated LOC: ~900–1,400 across `MacrecCore`, `MacrecUIKit`, `macrec-ui`, `macrec`, and tests.

| Phase | Title | Depends on | Parallel with | Phase 5 inputs needed before this can start |
|---|---|---|---|---|
| A | Foundation — types, enums, AppStorage keys, locale-set helpers | — | — | OQ-3 (env-var names) |
| B | Core orchestration — `DualTranscriptionManager` actor + fan-out + merged stream | A | — | OQ-6 (generic vs specific) |
| C | `RecordingController` / `RecordingSession` wiring (dispatcher protocol) | B | — | — |
| D | Sidecar writer extensions for channel-tagged JSONL/TXT/SRT/VTT | A, C | E (UI mode switch) | OQ-4 (SRT/VTT convention) |
| E | UI — top-of-panel mode switch + dynamic content swap | A, C | D, H (CLI parity) | OQ-1 (control type) |
| F | UI — Dual sub-panel controls (locale pickers, source picker, format picker, per-channel error display) | E | G (live transcript display) | OQ-2 (per-channel disable) |
| G | UI — dual-lane live transcript display | F | — | OQ-5 (lane layout) |
| H | CLI parity — `--transcribe-dual-*` flags, env-var resolution, daemon support | A, B, C | E, F | OQ-3 (flag spelling) |
| I | Telemetry & per-channel metrics surfacing in panel | C | J (privacy disclosure) | — |
| J | Privacy disclosure trigger for Dual-mode first run | C, E | I | — |

Visual dependency graph:

```
A → B → C → D ─┐
              │  → I, J (parallel)
              ├──→ E → F → G
              └─────→ H

D, E run in parallel after C.
F follows E; G follows F.
H runs in parallel with E once C is done.
I and J run in parallel after C; both publish into the panel built by F/G.
```

Phase 5 (designer) may proceed in parallel with Phase A coding because A is only types/enums/AppStorage keys and does not commit to any UI/CLI shape.

---

## 3. Phase A — Foundation: types, enums, AppStorage keys, locale-set helpers

**Goal:** introduce the type vocabulary and persisted-defaults registry the dual subsystem needs, without writing any orchestration code.

### A.1 Files to create

- `Sources/MacrecCore/Transcription/Dual/TranscriptionMode.swift` (new)
  - Public `enum TranscriptionMode: String, Codable, Sendable, CaseIterable { case single, dual }`. Default `.single`. Used by both `MacrecCore` (for `RecordingOptions`) and `macrec-ui` (for the `@AppStorage` key `"com.macrec.ui.transcriptionMode"`).
- `Sources/MacrecCore/Transcription/Dual/DualChannelTag.swift` (new)
  - Public `enum DualChannelTag: String, Codable, Sendable, CaseIterable { case channelA, channelB }`. Routing tag for per-channel metrics, errors, and sidecar convenience fields. Per the investigation, this tag is **NOT** added to `TranscriptionSegment`; it is computed at event-emission time inside `DualTranscriptionManager` from `segment.model`.
- `Sources/MacrecCore/Transcription/Dual/DualTranscriptionConfig.swift` (new)
  - Public struct `DualTranscriptionConfig: Sendable, Equatable` with fields:
    - `channelALocale: String` (BCP-47, MUST be a member of `SpeechTranscriber.supportedLocales`)
    - `channelBLocale: String` (BCP-47, MUST be a member of `SFSpeechRecognizer.supportedLocales()`)
    - `source: TranscriptionSource` (reuses existing enum: `.system | .microphone | .mixed | .both`)
    - `transcriptFormat: TranscriptFormat` (reuses existing enum: `jsonl | txt | srt | vtt`)
  - Validation initialiser `init(channelA:channelB:source:format:) throws` that:
    - throws `MacrecError.transcriptionConfigurationMissing(field:)` if any field is empty,
    - throws `MacrecError.transcriptionDualLocaleUnsupported(channel:locale:)` if either locale is not in the corresponding provider's supported set,
    - throws `MacrecError.transcriptionDualLocaleConflict(locale:)` if both channels resolve to the **same provider AND same locale** (defensive — in v1 the providers are always different by construction, so this is structurally unreachable but documented as a guard for OQ-6 future-genericity).
- `Sources/MacrecCore/Transcription/Dual/DualLocaleSets.swift` (new)
  - Public static helpers:
    - `static var channelASupportedLocales: [Locale]` — returns the macOS-26 `SpeechTranscriber.supportedLocales` filtered to "constrained" set. Per the user use case ("Greek with English code-switched words") the v1 Channel A picker exposes English variants first, then other supported locales. The helper returns the FULL `SpeechTranscriber.supportedLocales` set ordered with English variants on top; UI may filter further.
    - `static var channelBSupportedLocales: [Locale]` — returns `SFSpeechRecognizer.supportedLocales()` in stable sorted order (BCP-47 alphabetical), with `el-GR` and English variants surfaced at the top.
    - `static let channelADefaultLocale: String = "en-US"` (spec default).
    - `static let channelBDefaultLocale: String = "el-GR"` (spec default).
  - **Note (per investigator):** the existing `TranscriptionLanguagePicker` uses `SFSpeechRecognizer.supportedLocales()` (which DOES include Greek). The Channel A picker MUST NOT reuse that source — Channel A is `apple` on-device and `el-GR` is not in `SpeechTranscriber.supportedLocales` at macOS 26 launch. This helper enforces the distinction in one place.
- `Sources/MacrecCore/Errors/MacrecError+Dual.swift` (new — extension on existing `MacrecError`)
  - Add cases `transcriptionConfigurationMissing(field: String)`, `transcriptionDualLocaleUnsupported(channel: DualChannelTag, locale: String)`, `transcriptionDualLocaleConflict(locale: String)`, `transcriptionDualChannelFailure(channel: DualChannelTag, underlying: Error)`. All cases produce actionable error messages mirroring existing `MacrecError` style; `transcriptionDualChannelFailure` is the failure-isolation channel-tag wrapper used by Phase B.

### A.2 Files to modify

- `Sources/MacrecCore/Config/RecordingOptions.swift` (IP-10/IP-12 region)
  - Add optional `dualTranscription: DualTranscriptionConfig?` field. Mutually exclusive with the existing `transcribeProvider` having a non-`.dual` value — the construction site (`ControlBar.startTapped()` / `StartCommand`) decides which path to populate. The field is `nil` for Single mode (which leaves the existing serialisation byte-identical — verified by AC-1 regression test).
  - Add `var transcriptionMode: TranscriptionMode { dualTranscription == nil ? .single : .dual }` computed accessor.
- `Sources/macrec-ui/Defaults/AppStorageKeys.swift` (or wherever the centralised `@AppStorage` key constants live; if no central registry exists yet, the keys are hard-coded with comments cross-referencing this plan in `ControlBar.swift` per the existing convention).
  - Add five new constants with default values:
    - `"com.macrec.ui.transcriptionMode"` → `"single"` (TranscriptionMode rawValue)
    - `"com.macrec.ui.dual.channelALocale"` → `"en-US"`
    - `"com.macrec.ui.dual.channelBLocale"` → `"el-GR"`
    - `"com.macrec.ui.dual.source"` → `"mixed"`
    - `"com.macrec.ui.dual.transcriptFormat"` → `"jsonl"`
  - Per CLAUDE.md no-fallback rule, these are spec-defined defaults (acceptable) not silent substitutions for missing required configuration.

### A.3 Acceptance criteria satisfied at end of phase A

- (none of AC-1..AC-11 individually satisfied — Phase A is type-only foundation; it unblocks all subsequent phases)
- AC-2 partial (round-trip preservation guaranteed by separate AppStorage namespace)
- AC-1 partial (no Single-mode AppStorage keys touched)

### A.4 Verification

```bash
swift build --target MacrecCore
swift test --filter DualTranscriptionFoundationTests
```

Tests to add (new file):

- `Tests/MacrecCoreTests/Transcription/Dual/DualTranscriptionFoundationTests.swift`
  - `@Test func transcriptionMode_defaultsToSingle()`
  - `@Test func dualChannelTag_isSendable()`
  - `@Test func dualConfig_throwsForUnsupportedChannelALocale_elGR()` (`el-GR` is in `SFSpeechRecognizer.supportedLocales()` but NOT in `SpeechTranscriber.supportedLocales` → must reject as Channel A locale)
  - `@Test func dualConfig_throwsForUnsupportedChannelBLocale_zzZZ()`
  - `@Test func dualConfig_acceptsSpecDefaults_enUS_elGR()`
  - `@Test func recordingOptions_transcriptionMode_isSingleWhenDualNil()`
  - `@Test func channelADefault_isEnUS_andChannelBDefault_isElGR()`

### A.5 Dependencies

- None.

### A.6 Parallelisation opportunities within phase A

- `TranscriptionMode`, `DualChannelTag`, `DualLocaleSets`, and the `RecordingOptions` extension are independent files; can be authored in parallel by separate coder agents (Phase 6).

### A.7 Risks & mitigations

- **Risk:** `SpeechTranscriber.supportedLocales` may have surprises on the developer's machine vs. release — Apple updates the on-device asset list with OS minor releases.
  - **Mitigation:** test asserts only that `en-US` is present and `el-GR` is absent (these two are spec-anchored). Non-spec locales are not asserted.
- **Risk:** introducing `DualTranscriptionConfig?` on `RecordingOptions` could change Codable serialisation of existing Single-mode `RecordingOptions` records.
  - **Mitigation:** declare the new field as optional with explicit `Codable` keys; add a regression test that serialises a Single-mode `RecordingOptions` and asserts the JSON does not include a `dualTranscription` key (achieved via `try container.encodeIfPresent`).

---

## 4. Phase B — Core orchestration: `DualTranscriptionManager` actor

**Goal:** implement the actor that owns two `StreamingTranscriptionPipeline` instances, fans out audio, merges events, and isolates per-channel failures.

### B.1 Files to create

- `Sources/MacrecCore/Transcription/Dual/DualTranscriptionManager.swift` (new — primary deliverable, ~400 LOC)
  - Public `actor DualTranscriptionManager: Sendable` mirroring `TranscriptionManager`'s public surface so `RecordingSession` can dispatch via a protocol (Phase C):
    - `init(config: DualTranscriptionConfig, sidecarBaseURL: URL, sidecarPolicy: SidecarPolicy = .streaming, providerFactory: TranscriptionProviderFactory = .shared) throws`
    - `func start() async throws -> AsyncStream<TranscriptionEvent>` — opens both providers and both pipelines; returns the merged event stream.
    - `func ingest(_ samples: [Float], from tag: SourceTag) async` — synchronous fan-out: calls `pipelineA.ingest(samples, from: tag)` then `pipelineB.ingest(samples, from: tag)`. Per investigator, both pipelines' `ingest` is non-blocking (each downstream session has its own internal queue), so sequential fan-out does not stall capture.
    - `func ingestFrame(_ frame: AlignedFrame, from tag: SourceTag) async` — calls `downsamplerA.convert(frame)` then `pipelineA.ingest(samplesA, from: tag)`, then `downsamplerB.convert(frame)` then `pipelineB.ingest(samplesB, from: tag)`. Two `AudioDownsampler` instances per IP-4 (the type is not thread-safe; each consumer owns one).
    - `func stop() async` — calls `pipelineA.stop()` and `pipelineB.stop()` concurrently with `async let`; awaits both; finishes the merged-stream continuation.
    - `func rotateSidecar(toAudioURL: URL, format: TranscriptFormat) async throws` — calls `rotateSidecar` on both pipelines with the same target URL (per IP-5 / FR-11 atomic split).
    - `func currentMetrics() async -> DualChannelMetrics` — returns per-channel `TranscriptionMetrics` (new struct, see B.2).
  - Internals:
    - `private let pipelineA: StreamingTranscriptionPipeline` (constructed with `apple` provider, locale = `config.channelALocale`).
    - `private let pipelineB: StreamingTranscriptionPipeline` (constructed with `apple-cloud` provider, locale = `config.channelBLocale`).
    - `private let downsamplerA: AudioDownsampler`
    - `private let downsamplerB: AudioDownsampler`
    - `private let sidecarWriter: TranscriptSidecarWriter` (one shared writer; both pipelines append to the same sidecar tagged by `model`/`language` per IP-6)
    - `private var mergedContinuation: AsyncStream<TranscriptionEvent>.Continuation!`
    - `private var drainTaskA: Task<Void, Never>?`
    - `private var drainTaskB: Task<Void, Never>?`
    - `private var channelAErrored: Bool = false`
    - `private var channelBErrored: Bool = false`
  - Failure-isolation contract (per investigator Q3 + Q7):
    - Each drain Task wraps `for await event in pipelineX.events { mergedContinuation.yield(event) }` in `do { ... } catch { ... }`.
    - On catch: log channel-tagged error, mark `channelXErrored = true`, yield a synthetic `TranscriptionEvent.error(MacrecError.transcriptionDualChannelFailure(channel: X, underlying: e))` into the merged stream, do **NOT** finish the continuation, do **NOT** cancel the other Task.
    - If both channels error, the recording continues capturing audio (capture is independent of transcription); the merged stream's continuation is finished only when `stop()` is called.

### B.2 Supporting new types

- `Sources/MacrecCore/Transcription/Dual/DualChannelMetrics.swift` (new)
  - `public struct DualChannelMetrics: Sendable, Equatable { public let channelA: TranscriptionMetrics; public let channelB: TranscriptionMetrics }`
- `Sources/MacrecCore/Transcription/TranscriptionEvent.swift` (modify — add error case)
  - Add `case error(MacrecError)` to `TranscriptionEvent` if not already present. Per IP-6 the existing event enum has `.segmentFinalized`, `.segmentUpdated`, etc.; if `.error(MacrecError)` already exists, no change needed.

### B.3 Files to modify

- None outside the new `Dual/` subdirectory and the `TranscriptionEvent` extension. Critically, `StreamingTranscriptionPipeline.swift` and `TranscriptionManager.swift` are NOT modified (NFR-1 hard constraint).

### B.4 Phase-5 micro-investigation pre-work (mandatory before B.1 is implemented)

The investigation flagged ONE remaining micro-question: the buffering policy of `AppleSpeechSession`'s internal `AnalyzerInput` `AsyncStream`. This is a 30-second code-read in `Sources/MacrecCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift`:

- If the stream is created with `bufferingPolicy: .unbounded`: leave it as-is for v1 (the existing single-mode behaviour is unbounded and has not exhibited memory issues; dual mode does not change the per-channel memory profile).
- If the stream is bounded (`.bufferingNewest(N)`): no change needed.
- If the stream is unbounded AND we want defensive backpressure for dual mode: introduce a wrapper or change the policy to `.bufferingNewest(1024)` ONLY for dual-mode constructions of `AppleSpeechTranscriptionProvider`. This avoids touching single-mode behaviour.

The coder for Phase B MUST resolve this micro-question in the first commit and document the finding inline in `DualTranscriptionManager.swift`.

### B.5 Acceptance criteria satisfied at end of phase B

- AC-3 partial (manager can start both channels — verified by unit test with mock providers; live verification deferred to Phase E/H integration).
- AC-4 partial (channel isolation verified by mock-failure unit test).
- AC-7 partial (atomic stop / rotateSidecar verified by mock test; live verification deferred to Phase C).
- AC-9 partial (permissions error from Channel B is wrapped as `transcriptionDualChannelFailure` and does NOT propagate to Channel A — verified by injecting a failing `FakeTranscriptionProvider`).

### B.6 Verification

```bash
swift build --target MacrecCore
swift test --filter DualTranscriptionManagerTests
swift test --filter DualChannelIsolationTests
```

Tests to add:

- `Tests/MacrecCoreTests/Transcription/Dual/DualTranscriptionManagerTests.swift`
  - `@Test func startOpensBothChannels()` (mock providers; assert `openStreamingSession` called twice)
  - `@Test func ingestFrameFansOutToBothPipelines()` (mock pipelines; assert both received the same `[Float]` count and content)
  - `@Test func stopFinishesMergedStream()`
  - `@Test func rotateSidecarRotatesBothPipelines()` (assert both pipelines received `rotateSidecar` with the same URL/format)
- `Tests/MacrecCoreTests/Transcription/Dual/DualChannelIsolationTests.swift`
  - `@Test func channelBFailureDoesNotTerminateChannelA()` (inject failing `FakeTranscriptionProvider` for Channel B; assert Channel A continues to emit events; assert `transcriptionDualChannelFailure(channel: .channelB, ...)` event yielded)
  - `@Test func bothChannelsFailDoesNotFinishMergedStream()` (only `stop()` finishes it)
  - `@Test func channelAErrorIsTaggedAsChannelA()` (symmetry with the previous test)

### B.7 Dependencies

- Phase A complete (types and `RecordingOptions` field are required).

### B.8 Parallelisation opportunities within phase B

- `DualChannelMetrics` and `MacrecError+Dual` cases (already in Phase A) can be assembled by a separate agent.
- The two test files can be authored in parallel with the manager file — they only need the public API surface from B.1 to compile.

### B.9 Risks & mitigations

- **Risk:** ordering of events from Channel A vs. Channel B in the merged stream depends on Task scheduling; downstream code may inadvertently rely on stream-A-then-stream-B ordering.
  - **Mitigation:** test asserts events from BOTH channels appear in the merged stream within a bounded time window, but does NOT assert cross-channel ordering. Documented in `DualTranscriptionManager.swift` header comment.
- **Risk:** `pipelineA.stop()` or `pipelineB.stop()` could deadlock if either pipeline's drain Task is awaiting an event that never arrives.
  - **Mitigation:** use `async let` to call both stops concurrently with a per-stop timeout (5 s, matching FR-57's existing single-mode drain-timeout). On timeout, log and continue.
- **Risk:** the shared `TranscriptSidecarWriter` is an actor and serialises appends, so two pipelines writing concurrently is safe — but if Phase B accidentally instantiates two writers (one per pipeline), the sidecar file becomes corrupt (interleaved writes from two file handles).
  - **Mitigation:** the manager's `init` constructs ONE `TranscriptSidecarWriter` and injects it into BOTH `StreamingTranscriptionPipeline` constructions. A unit test asserts `sidecarWriter === pipelineA.sidecarWriter` and `sidecarWriter === pipelineB.sidecarWriter` (or uses an equivalent identity probe).

---

## 5. Phase C — `RecordingController` / `RecordingSession` wiring

**Goal:** route dual-mode start/stop/pause/resume/split through `DualTranscriptionManager` while leaving the single-mode path untouched (NFR-1 hard constraint).

### C.1 Files to create

- `Sources/MacrecCore/Transcription/TranscriptionDispatcher.swift` (new — protocol extraction per investigator §1A mitigation)
  - `public protocol TranscriptionDispatcher: Sendable, Actor { ... }` declaring the common surface `start() async throws -> AsyncStream<TranscriptionEvent>`, `ingestFrame(_:from:)`, `stop()`, `rotateSidecar(toAudioURL:format:)`, `currentMetrics()`.
  - Conformance added retroactively to `TranscriptionManager` (existing) and `DualTranscriptionManager` (new from Phase B). The `TranscriptionManager` conformance is purely additive — no signature changes.

### C.2 Files to modify

- `Sources/MacrecCore/Recording/RecordingSession.swift` (or wherever `TranscriptionManager` is constructed and held — need to grep at implementation time)
  - Replace `private let transcriptionManager: TranscriptionManager?` with `private let dispatcher: (any TranscriptionDispatcher)?`.
  - Construction-site branch:
    ```swift
    if let dualConfig = options.dualTranscription {
        self.dispatcher = try DualTranscriptionManager(config: dualConfig, sidecarBaseURL: ..., providerFactory: ...)
    } else if options.transcribeProvider != "none" {
        self.dispatcher = try TranscriptionManager(/* existing args */)
    } else {
        self.dispatcher = nil
    }
    ```
  - All call sites of `transcriptionManager?.start()` / `.ingestFrame(...)` / `.stop()` / `.rotateSidecar(...)` change to `dispatcher?....`. Method signatures are unchanged (the protocol mirrors the existing surface).
- `Sources/MacrecUIKit/RecordingController.swift` (per IP-14)
  - Add published properties (per investigator):
    - `@Published public private(set) var transcriptionMode: TranscriptionMode = .single` (mirrors the AppStorage value at session-start time so the panel can render the correct lane layout without re-reading AppStorage)
    - `@Published public private(set) var dualMetrics: DualChannelMetrics?`
    - `@Published public private(set) var dualChannelErrors: (channelA: String?, channelB: String?)?`
  - In the event-drain Task that consumes the merged `AsyncStream<TranscriptionEvent>`, branch on `event` cases — for `transcriptionDualChannelFailure(channel:underlying:)`, update the corresponding `dualChannelErrors` field.
  - The existing `transcriptSegments: [TranscriptSegment]` array is unchanged. Per investigator §3 / IP-13, the segment's `model` and `language` fields suffice to identify the channel; the panel partitions by `model` at render time.

### C.3 Acceptance criteria satisfied at end of phase C

- AC-3 (dual starts both channels — now end-to-end through `RecordingSession`)
- AC-4 (channel isolation — verified end-to-end)
- AC-7 (pause/resume/split atomic — verified end-to-end; pause is achieved by the existing capture-graph-level pause that stops `ingestFrame` calls; both channels naturally go quiet)
- AC-1 partial (Single-mode runtime path now goes through the dispatcher protocol but the implementation is byte-identical — verified by an explicit AC-1 regression test that diffs Single-mode JSONL output before vs. after this PR)

### C.4 Verification

```bash
swift build --target MacrecCore --target MacrecUIKit
swift test --filter RecordingSessionDualDispatchTests
swift test --filter SingleModeRegressionTests   # AC-1 byte-equivalence
```

Tests to add:

- `Tests/MacrecCoreTests/Recording/RecordingSessionDualDispatchTests.swift`
  - `@Test func recordingSessionPicksDualDispatcherWhenDualConfigPresent()`
  - `@Test func recordingSessionPicksSingleDispatcherWhenDualConfigAbsent()`
  - `@Test func recordingSessionRoutesIngestToDualDispatcherWhenDualSelected()`
- `Tests/MacrecCoreTests/Transcription/SingleModeRegressionTests.swift` (AC-1 hard-constraint test)
  - `@Test func singleModeJSONLOutputIsByteIdenticalAcrossDispatcherRefactor()` — uses a `FakeTranscriptionProvider` that emits a fixed sequence of segments; runs once via the legacy code path (captured as a golden file from a pre-change build) and once via the new dispatcher path; asserts byte-equality.

### C.5 Dependencies

- Phase A and B complete.

### C.6 Parallelisation opportunities within phase C

- The `TranscriptionDispatcher` protocol extraction (C.1) and the `RecordingController` published-property additions (C.2) are independent files; can be done in parallel.

### C.7 Risks & mitigations

- **Risk:** introducing the dispatcher protocol changes the type of `RecordingSession.transcriptionManager` and may cascade into `MacrecUIKit` and tests.
  - **Mitigation:** keep the property name (rename to `dispatcher`, but expose a public read-only `var transcriptionManager: TranscriptionManager? { dispatcher as? TranscriptionManager }` shim if needed for backward source-compat in tests — drop the shim after Phase 9 sweep).
- **Risk:** `RecordingController` published-property additions could leak across to single-mode binding sites (e.g. SwiftUI views that observe the controller). If the controller publishes a `dualMetrics?` change while the panel is in single mode, the panel may re-render unnecessarily.
  - **Mitigation:** views that don't care about dual mode read only `transcriptSegments` / `transcriptionMetrics` (existing properties); SwiftUI's diffing means a `dualMetrics` change does not invalidate views that don't reference it.

---

## 6. Phase D — Sidecar writer extensions for channel-tagged JSONL/TXT/SRT/VTT

**Goal:** ensure the four sidecar formats correctly serialise a two-channel input. Per investigator §Q5, JSONL needs no schema change, TXT needs a line-prefix convention, SRT needs cue speaker prefixes, VTT uses voice tags.

### D.1 Files to modify

- `Sources/MacrecCore/Transcription/Persistence/JSONLTranscriptWriter.swift` (per IP-6)
  - Add an OPTIONAL convenience field `channel: String?` to the `Wire` struct, populated only when the writer is constructed in dual mode (it knows because `DualTranscriptionManager` constructs the writer with a `dualModeContext` flag). The `channel` value is `"A"` or `"B"` derived from `segment.model` (`"apple"` → `"A"`, `"apple-cloud"` → `"B"`). For single-mode writes, `channel` is omitted (`encodeIfPresent`) and the JSONL output is byte-identical to today's (AC-1).
- `Sources/MacrecCore/Transcription/Persistence/TXTTranscriptWriter.swift` (modify or create if not present)
  - Single-mode line format unchanged. Dual-mode line format: `[<MM:SS.mmm>] [<channel-label>] <text>` where `<channel-label>` is the BCP-47 primary language uppercased (`EN`, `EL`). The writer reads `segment.language` to derive the label; if `language` is nil, falls back to the BCP-47 region-code-only form (defensive).
- `Sources/MacrecCore/Transcription/Persistence/SRTTranscriptWriter.swift` (modify or create if not present)
  - Single-mode cue text unchanged. Dual-mode cue text prefixed with `<channel-label>: ` (e.g. `EN: Hello world` / `EL: Καλημέρα`). Cues are emitted in arrival order. **Overlapping cue start/end times are allowed** per investigator (SubRip ignores overlap; mpv/VLC stack overlapping cues; this is the documented v1 behaviour).
- `Sources/MacrecCore/Transcription/Persistence/VTTTranscriptWriter.swift` (modify or create if not present)
  - Single-mode cue text unchanged. Dual-mode cue text wrapped in WebVTT voice tags: `<v EN>Hello world</v>` / `<v EL>Καλημέρα</v>`. Same overlap policy.

### D.2 Files to create

- `Sources/MacrecCore/Transcription/Dual/DualSidecarLabel.swift` (new — small helper)
  - `static func channelLabel(for segment: TranscriptSegment) -> String` returning the uppercased BCP-47 primary language code (`"EN"` for `"en-US"`, `"EL"` for `"el-GR"`, etc.). Used by all four writers. Centralised so OQ-4 channel-labelling convention has one canonical implementation.

### D.3 Mode selection at writer construction

Per IP-6, the dual orchestrator constructs ONE `TranscriptSidecarWriter` and injects into BOTH pipelines. The writer needs to know it is in dual mode to enable the channel-prefix logic without affecting single-mode output. Two implementation options:

- **Option D.3a — explicit mode flag:** `TranscriptSidecarWriter.init(..., mode: TranscriptionMode = .single)`. Each format writer reads the flag. Simple, explicit.
- **Option D.3b — implicit by counting models:** the writer observes the first few segments and notices ≥2 distinct `model` values; switches to channel-prefix output. Convenient but ambiguous and fails for the first 1–2 segments.

**Decision:** adopt D.3a (explicit `mode` parameter). Phase 5 may overrule.

### D.4 Acceptance criteria satisfied at end of phase D

- AC-5 (sidecar output for all four formats with channel + locale + timestamps + isFinal — verified by new tests).
- AC-1 partial (single-mode sidecar byte-equivalence — verified by SingleModeRegressionTests in Phase C, extended here to cover all four formats).

### D.5 Verification

```bash
swift test --filter DualSidecarWriterTests
swift test --filter SingleModeSidecarRegressionTests
```

Tests to add:

- `Tests/MacrecCoreTests/Transcription/Persistence/Dual/DualSidecarWriterTests.swift`
  - One test per format (`@Test func dualJSONLEmitsChannelTaggedLines()`, ditto txt/srt/vtt).
  - Each test feeds a fixed sequence of `.segmentFinalized` events with alternating `model = "apple"` (lang `"en-US"`) and `model = "apple-cloud"` (lang `"el-GR"`); asserts the on-disk file matches a golden expected output.
  - Includes one `@Test func srtAllowsOverlappingCues()` to document and lock the overlap policy.
- `Tests/MacrecCoreTests/Transcription/Persistence/SingleModeSidecarRegressionTests.swift` (AC-1)
  - One test per format asserting that with `mode: .single`, the writer produces byte-identical output to the pre-change build (golden files captured at `test_scripts/golden/sidecar/single-mode-{jsonl,txt,srt,vtt}.golden`).

### D.6 Dependencies

- Phase A (DualChannelTag, helpers) and Phase C (writer is constructed inside `DualTranscriptionManager`, which is in turn constructed by `RecordingSession`).

### D.7 Parallelisation opportunities within phase D

- All four format writers can be modified in parallel (independent files).
- Test golden-file capture is independent of writer changes once the contract is settled.

### D.8 Risks & mitigations

- **Risk:** the JSONL `channel` field becomes a load-bearing key for downstream tools, but its presence is mode-conditional (omitted in single mode) — downstream consumers may be surprised.
  - **Mitigation:** document explicitly in `docs/tools/macrec.md` AC-5 schema section that `channel` is present only in dual-mode JSONL.
- **Risk:** SRT/VTT players may not handle voice tags / speaker prefixes uniformly.
  - **Mitigation:** the v1 default reuses the most widely-supported convention (VTT `<v>` tags are first-class WebVTT; SRT speaker prefixes are de-facto standard). Document tested players in `docs/tools/macrec.md`. OQ-4 is open for designer input if a different convention is preferred.

---

## 7. Phase E — UI: top-of-panel mode switch + dynamic content swap

**Goal:** introduce the mode switch and the panel-swap logic so the Single sub-view renders the existing controls verbatim and the Dual sub-view renders the new controls. Hard constraint: AC-1 (Single sub-view is pixel-identical to today).

### E.1 Files to create

- `Sources/macrec-ui/Views/Transcription/TranscriptionModeSwitch.swift` (new)
  - SwiftUI view: segmented `Picker("Mode", selection: $mode).pickerStyle(.segmented)` ["Single", "Dual"], bound to `@AppStorage("com.macrec.ui.transcriptionMode")`. (Designer may overrule in OQ-1; if so, this file is replaced with a `Toggle`-based or other variant — the panel-swap caller code below is unaffected because it only reads the persisted value.)
  - Compact (one row, ~28 pt). Idiomatic macOS pattern.
- `Sources/macrec-ui/Views/Transcription/SingleTranscriptionControls.swift` (new — extracted view)
  - Wraps the EXISTING control set (TranscriptionPicker + TranscriptionSourcePicker + TranscriptionFormatPicker + TranscriptionLanguagePicker) verbatim. This extraction is a **pure refactor with zero behavioural change** — the existing layout, AppStorage keys, defaults, and labels are preserved character-for-character.
  - Phase 9 review checks visual diff against pre-change build.
- `Sources/macrec-ui/Views/Transcription/Dual/DualTranscriptionControls.swift` (new — Phase F populates this; created as an empty `View` in Phase E so the mode switch's swap target compiles)

### E.2 Files to modify

- `Sources/macrec-ui/RootView.swift` (or whichever top-level composes the Live Transcription panel — likely under `Sources/macrec-ui/Views/`)
  - Insert `TranscriptionModeSwitch` at the top of the Live Transcription panel section.
  - Replace the inline existing-controls block with a conditional:
    ```swift
    switch transcriptionMode {
    case .single: SingleTranscriptionControls()
    case .dual:   DualTranscriptionControls()
    }
    ```
  - The Live Transcription panel header ("Live Transcription"), the section gate toggle (FR-UI-TRANSCRIPTION-GATE from plan-008), and the live-transcript display area (Phase G) are outside this conditional.

### E.3 Acceptance criteria satisfied at end of phase E

- AC-1 (Single sub-view renders existing controls EXACTLY — verified by visual diff and by an automated test that reads the SwiftUI view tree of `SingleTranscriptionControls()` and asserts the same labels and AppStorage keys are present).
- AC-2 (toggling Single↔Dual swaps the panel with no app restart and no recording in progress; round-trip preserves Single-mode AppStorage values intact — guaranteed by the separate AppStorage namespace established in Phase A).

### E.4 Verification

```bash
swift build --product macrec-ui
swift test --filter TranscriptionModeSwitchTests
swift test --filter SingleTranscriptionControlsRegressionTests
```

Tests to add:

- `Tests/MacrecUITests/Transcription/Dual/TranscriptionModeSwitchTests.swift`
  - `@Test func defaultModeIsSingle()` (asserts AppStorage defaults to `"single"`)
  - `@Test func togglingToDualPersistsValue()` 
  - `@Test func togglingBackToSingleRestoresSingleControls()`
- `Tests/MacrecUITests/Transcription/SingleTranscriptionControlsRegressionTests.swift`
  - `@Test func singleControlsExposeAllTenLegacyAppStorageKeys()` — extends the existing `ControlBarStartTappedKeysRegressionTests` pattern; asserts the extracted view does not drop or rename any of the ten Single-mode AppStorage keys.

### E.5 Manual visual-diff verification (AC-1 ratification)

Coder runs `swift run macrec-ui` before and after this PR; takes a screenshot of the Live Transcription panel in Single mode; diffs the two PNGs. The new top-of-panel mode switch IS expected (it adds one row); the controls below the switch must be pixel-identical.

### E.6 Dependencies

- Phase A (AppStorage key registry).
- Phase C (`RecordingController.transcriptionMode` published property — used at Start time).

### E.7 Parallelisation opportunities within phase E

- `TranscriptionModeSwitch.swift`, the `SingleTranscriptionControls` extraction, and the empty `DualTranscriptionControls` placeholder are independent files; can be authored in parallel.

### E.8 Risks & mitigations

- **Risk:** the top-of-panel mode switch is itself a *new* visible row in Single mode. The user's verbatim directive is "I do NOT want to change the existing live transcription option."
  - **Mitigation:** investigator's interpretation (and recommended phrasing for the designer in Phase 5) is that AC-1 refers to the *field controls* below the mode switch, not to the absence of a mode-selector row above them. If the user pushes back, fall back to OQ-1 Option B (Toggle below the panel). The implementation surface is a one-file swap (`TranscriptionModeSwitch.swift`).
- **Risk:** extracting `SingleTranscriptionControls` from `RootView` might subtly change SwiftUI view-identity and break existing animations/state preservation.
  - **Mitigation:** wrap the extraction in `Group { ... }` with the same modifiers; verify with `LiveTranscriptPanelTests` and visual-diff.

---

## 8. Phase F — UI: Dual sub-panel controls

**Goal:** populate `DualTranscriptionControls` with the Dual-specific control set per FR-3.

### F.1 Files to modify

- `Sources/macrec-ui/Views/Transcription/Dual/DualTranscriptionControls.swift` (filled in)
  - Layout (top-to-bottom, single column, mirroring single-mode visual rhythm):
    1. **Audio Source picker** — reuses `TranscriptionSourcePicker` but bound to `@AppStorage("com.macrec.ui.dual.source")`. Shows the same Mixed / Microphone / System options.
    2. **Channel A row** — labelled "Channel A — Apple (on-device)". Locale picker bound to `@AppStorage("com.macrec.ui.dual.channelALocale")` with options sourced from `DualLocaleSets.channelASupportedLocales`. Default `en-US`. Inline error display (FR-4): if `RecordingController.dualChannelErrors?.channelA != nil`, render the error text in red below the picker.
    3. **Channel B row** — labelled "Channel B — Apple Cloud". Locale picker bound to `@AppStorage("com.macrec.ui.dual.channelBLocale")` with options sourced from `DualLocaleSets.channelBSupportedLocales`. Default `el-GR`. Inline error display analogous to Channel A.
    4. **Sidecar Transcript Format picker** — reuses `TranscriptionFormatPicker` but bound to `@AppStorage("com.macrec.ui.dual.transcriptFormat")`. Same four options: jsonl, txt, srt, vtt.
    5. **Per-channel disable toggles** (only if Phase 5 resolves OQ-2 in favour) — two `Toggle("Enable Channel A/B", isOn:)` rows. If OQ-2 resolves to atomic-only, skip.
- `Sources/macrec-ui/Views/Transcription/Dual/DualLocalePicker.swift` (new — extracted from existing `TranscriptionLanguagePicker` for reuse with constrained locale sets)
  - `struct DualLocalePicker: View { let label: String; let storageKey: String; let supportedLocales: [Locale]; let defaultLocale: String; ... }`. Renders a `Picker` with the constrained set.

### F.2 Files to modify

- `Sources/macrec-ui/Views/ControlBar.swift` (per IP-10) — `startTapped()` branches on the mode key:
  - If `transcriptionMode == .dual`: read `dual.channelALocale`, `dual.channelBLocale`, `dual.source`, `dual.transcriptFormat`; construct `DualTranscriptionConfig` and assign to `RecordingOptions.dualTranscription`. The single-mode AppStorage keys are NOT read in this branch (and round-trip Single→Dual→Single preserves them — AC-2).
  - If `transcriptionMode == .single`: existing code path unchanged.
  - Validation: if either dual locale is empty (defensive), surface `MacrecError.transcriptionConfigurationMissing(field:)` via the same error UI used today for missing API keys.

### F.3 Acceptance criteria satisfied at end of phase F

- FR-3 satisfied (Dual controls present per the spec).
- AC-3 (starting a Dual recording with default locales now works end-to-end through the UI).
- FR-4 (inline per-channel error display).
- FR-8 trigger point (when `startTapped()` constructs the Dual config, it checks the apple-cloud disclosure flag — Phase J implements the actual disclosure trigger).

### F.4 Verification

```bash
swift build --product macrec-ui
swift test --filter DualTranscriptionControlsTests
swift test --filter ControlBarStartTappedDualTests
```

Tests to add:

- `Tests/MacrecUITests/Transcription/Dual/DualTranscriptionControlsTests.swift`
  - `@Test func channelALocalePickerLimitedToSpeechTranscriberSupportedLocales()`
  - `@Test func channelBLocalePickerIncludesElGR()`
  - `@Test func dualControlsRenderInlineChannelErrors()`
- `Tests/MacrecUITests/ControlBarStartTappedDualTests.swift`
  - `@Test func dualModeStartTappedConstructsDualTranscriptionConfig()`
  - `@Test func dualModeStartTappedDoesNotReadSingleModeAppStorageKeys()`
  - `@Test func emptyDualLocaleRaisesConfigurationMissingError()`

### F.5 Dependencies

- Phase A (locale-set helpers, AppStorage keys).
- Phase C (`RecordingOptions.dualTranscription` field).
- Phase E (the empty `DualTranscriptionControls` placeholder).

### F.6 Parallelisation opportunities within phase F

- `DualLocalePicker.swift` and the `DualTranscriptionControls` body can be authored in parallel.

### F.7 Risks & mitigations

- **Risk:** the user changes Channel A locale to a value that `SpeechTranscriber.supportedLocales` does not actually have on the user's installed OS minor (asset list drift).
  - **Mitigation:** the picker is constrained to the live-queried supported set, so the value cannot be entered in the first place. Defensive validation in `DualTranscriptionConfig.init` rejects unknown values with `transcriptionDualLocaleUnsupported`.

---

## 9. Phase G — UI: dual-lane live transcript display

**Goal:** render Channel A and Channel B partials/finals in two visually distinct lanes (FR-6). Layout choice (side-by-side, stacked, single feed with chips) is OQ-5; the planner reserves the integration point and codes the partition; the designer picks the layout.

### G.1 Files to modify

- `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift` (per IP-13)
  - Read `recordingController.transcriptionMode`. If `.single`, render the existing flat list verbatim (AC-1 preservation). If `.dual`, render the dual-lane layout per OQ-5.
  - The dual-lane layout partitions `recordingController.transcriptSegments` into two arrays by `segment.model`:
    - `channelA = segments.filter { $0.model == "apple" }`
    - `channelB = segments.filter { $0.model == "apple-cloud" }`
  - Renders each partition with a labelled lane header ("EN — Apple" / "EL — Apple Cloud") and the existing per-segment row treatment (language chip, italic for partials, secondary colour for partials).
  - The `Clear transcript` button (existing, line 79-89) clears BOTH lanes atomically (a single call to `recordingController.clearTranscriptSegments()` already empties the underlying array).

### G.2 Files to create

- `Sources/macrec-ui/Views/Transcription/Dual/DualLiveTranscriptLane.swift` (new — single-lane component reusable in side-by-side or stacked layouts)
  - `struct DualLiveTranscriptLane: View { let label: String; let segments: [TranscriptSegment] }`
- `Sources/macrec-ui/Views/Transcription/Dual/DualLiveTranscriptView.swift` (new — composes two lanes per OQ-5 layout choice)
  - Phase 5 designer specifies whether this is `HStack { laneA; laneB }`, `VStack { laneA; laneB }`, or a single chronological feed. Phase G coder implements the chosen layout; the lane component is layout-agnostic.

### G.3 Acceptance criteria satisfied at end of phase G

- FR-6 (two visually distinct lanes for partials and finals).
- AC-3 (live partials appearing in both lanes within latency budget — verified manually with a real Dual recording in Phase 9 / 10).
- AC-1 (Single mode display unchanged — verified by an automated test that asserts `LiveTranscriptPanel(mode: .single)` is structurally identical to the pre-change panel).

### G.4 Verification

```bash
swift build --product macrec-ui
swift test --filter DualLiveTranscriptViewTests
swift test --filter LiveTranscriptPanelSingleModeTests
```

Tests to add:

- `Tests/MacrecUITests/Transcription/Dual/DualLiveTranscriptViewTests.swift`
  - `@Test func dualPanelPartitionsSegmentsByModel()`
  - `@Test func dualPanelRendersLaneHeaders()`
  - `@Test func dualPanelClearTranscriptClearsBothLanes()`
- `Tests/MacrecUITests/Transcription/LiveTranscriptPanelSingleModeTests.swift`
  - Extension of the existing `LiveTranscriptPanelTests` to assert `mode: .single` rendering is unchanged.

### G.5 Dependencies

- Phase C (`RecordingController.transcriptionMode` published property).
- Phase F (Dual mode is selectable from the panel).

### G.6 Parallelisation opportunities within phase G

- Lane component and composing view are independent files.

### G.7 Risks & mitigations

- **Risk:** the popover width is tight; side-by-side may force unreadable line lengths in each lane.
  - **Mitigation:** lane component is layout-agnostic; designer picks per OQ-5. If side-by-side is too cramped, fall back to stacked.

---

## 10. Phase H — CLI parity

**Goal:** expose Dual mode through `macrec` CLI flags and env vars per FR-10. Exact spelling is OQ-3.

### H.1 Files to modify

- `Sources/macrec/Commands/StartCommand.swift` (per IP-11)
  - Add new flags (assuming OQ-3 resolves to investigator's Option A — designer may rename):
    - `--transcribe-dual` (Bool — switches from the per-provider `--transcribe` flag to dual mode). Mutually exclusive with `--transcribe <id>` where `<id> != none`.
    - OR: extend `--transcribe` to accept a new value `dual`. Investigator marginally prefers the dedicated `--transcribe-dual` boolean for clarity; designer to confirm.
    - `--transcribe-dual-locale-a <bcp47>` — default `en-US`. Env: `MACREC_TRANSCRIBE_DUAL_LOCALE_A`.
    - `--transcribe-dual-locale-b <bcp47>` — default `el-GR`. Env: `MACREC_TRANSCRIBE_DUAL_LOCALE_B`.
    - `--transcribe-dual-source <src>` — default `mixed`. Env: `MACREC_TRANSCRIBE_DUAL_SOURCE`.
    - `--transcribe-dual-format <fmt>` — default `jsonl`. Env: `MACREC_TRANSCRIBE_DUAL_FORMAT`.
  - `buildCLIOverrides()` forwards these to `ConfigResolver` keys.
- `Sources/MacrecCore/Config/ConfigResolver.swift` (per IP-11)
  - Add `Keys.MACREC_TRANSCRIBE_DUAL_LOCALE_A` etc. constants. Continue four-tier resolution (shell env → `~/.tool-agents/macrec/.env` → local `.env` → CLI flag) per the existing convention.
- `Sources/MacrecCore/Config/RecordingOptions.swift`
  - The `from(cliOverrides:)` factory branches on `--transcribe-dual` to construct `dualTranscription: DualTranscriptionConfig?` instead of a single-provider `transcribeProvider`.

### H.2 Acceptance criteria satisfied at end of phase H

- FR-10 (CLI parity with UI Dual mode).
- AC-8 (CLI Dual mode produces functionally equivalent output to UI Dual mode for the same inputs — verified by a script in `test_scripts/`).

### H.3 Verification

```bash
swift build --product macrec
swift run macrec start --transcribe-dual --transcribe-dual-locale-a en-US --transcribe-dual-locale-b el-GR --transcribe-dual-source mixed --transcribe-dual-format jsonl --output /tmp/dual-cli-test.m4a
# (manual verification: speak Greek + English; stop after ~30s; inspect /tmp/dual-cli-test.transcript.jsonl for tagged segments)
swift test --filter StartCommandDualFlagsTests
```

Tests to add:

- `Tests/MacrecTests/Commands/StartCommandDualFlagsTests.swift`
  - `@Test func dualFlagConstructsDualTranscriptionConfig()`
  - `@Test func dualFlagMutuallyExclusiveWithTranscribeProvider()`
  - `@Test func dualFlagsResolveFromEnvVars()`
  - `@Test func dualFlagsDefaultToEnUSAndElGR()`
- `test_scripts/dual_cli_parity_smoke.sh` — runs the CLI and the UI sequentially against the same audio file (recorded once, replayed via `--input`), diffs the two JSONL sidecars after normalising timestamps; asserts segment count and channel labelling match.

### H.4 Dependencies

- Phase A (config), Phase B (manager), Phase C (RecordingSession dispatch).

### H.5 Parallelisation opportunities within phase H

- Can run in parallel with Phase E (UI mode switch) once Phase C is done — they touch disjoint code paths.

### H.6 Risks & mitigations

- **Risk:** flag name ambiguity if `--transcribe dual` is chosen instead of `--transcribe-dual` boolean — designer may collide with other `--transcribe-*` semantics.
  - **Mitigation:** designer picks one; coder implements; documentation in `docs/tools/macrec.md` is the source of truth.

---

## 11. Phase I — Telemetry & per-channel metrics surfacing

**Goal:** display per-channel latency and (for the cloud channel) cost / quota usage in the Dual panel (FR-9).

### I.1 Files to modify

- `Sources/MacrecUIKit/RecordingController.swift`
  - The `dualMetrics: DualChannelMetrics?` published property (added in Phase C) is updated by polling `dispatcher?.currentMetrics()` on the existing metrics-update timer (the single-mode timer already polls `transcriptionManager?.currentMetrics()`).
- `Sources/macrec-ui/Views/Transcription/Dual/DualTranscriptionMetricsView.swift` (new)
  - Mirrors the existing `TranscriptionMetricsView` but renders TWO rows (one per channel) showing:
    - Channel A: latency (median first-partial lag, ms), chunks sent, error count.
    - Channel B: latency, chunks sent, error count, **and** apple-cloud quota indicator (current 1,000-req/hr usage if available — `AppleCloudStreamingSession` may need a small surface to expose this; if not already exposed, leave the indicator stubbed in v1 and document as a v2 follow-up).

### I.2 Acceptance criteria satisfied at end of phase I

- FR-9 (per-channel telemetry visible in UI).

### I.3 Verification

```bash
swift build --product macrec-ui
swift test --filter DualTranscriptionMetricsViewTests
```

### I.4 Dependencies

- Phase C (published property).
- Phase F (Dual panel exists to embed the metrics view).

### I.5 Parallelisation opportunities within phase I

- Can run in parallel with Phase J once Phase C is done.

### I.6 Risks & mitigations

- **Risk:** the apple-cloud quota indicator may not be observable from `AppleCloudStreamingSession` today.
  - **Mitigation:** if not, ship FR-9 v1 with latency + chunks + errors; defer the quota indicator to a v2 follow-up explicitly noted in `Issues - Pending Items.md`.

---

## 12. Phase J — Privacy disclosure trigger for Dual-mode first run

**Goal:** when the user enables Dual for the first time and starts a recording without having previously acknowledged the apple-cloud disclosure, the existing disclosure sheet fires; once acknowledged, subsequent Dual recordings do not re-prompt (FR-8 / AC-6).

### J.1 Files to modify

- `Sources/macrec-ui/RootView.swift` (or wherever the existing single-mode disclosure trigger lives — per IP-7)
  - Add a parallel trigger: when `transcriptionMode == .dual` AND user clicks Start AND `PrivacyDisclosureViewModel.acknowledgedKey(for: "apple-cloud")` is `false`, present `PrivacyDisclosureSheet(selectedProvider: "apple-cloud", ...)` BEFORE allowing `startTapped()` to invoke the recorder.
  - The disclosure body text is the existing `appleCloudBodyText` (per IP-15) — no new copy is needed.
  - On acceptance, set the AppStorage flag and proceed with `startTapped()`. On dismissal, abort the start.
- `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift` — no change needed (the per-provider key mechanism is already in place).

### J.2 Acceptance criteria satisfied at end of phase J

- FR-8 / AC-6 (privacy disclosure fires once on first Dual start; not again after acceptance).

### J.3 Verification

```bash
swift build --product macrec-ui
swift test --filter DualPrivacyDisclosureTests
```

Tests to add:

- `Tests/MacrecUITests/Transcription/Dual/DualPrivacyDisclosureTests.swift`
  - `@Test func dualStart_promptsAppleCloudDisclosureWhenUnacknowledged()`
  - `@Test func dualStart_doesNotPromptWhenAppleCloudAlreadyAcknowledged()`
  - `@Test func singleAppleCloudAcknowledgement_carriesIntoDualMode()` (the per-provider key mechanism means a user who accepted the disclosure under single-mode `apple-cloud` is not re-prompted in Dual mode).

### J.4 Dependencies

- Phase C (mode known at Start), Phase E (mode switch exists), Phase F (Dual panel).

### J.5 Parallelisation opportunities within phase J

- Can run in parallel with Phase I.

### J.6 Risks & mitigations

- **Risk:** the existing single-mode disclosure trigger lives in `RootView` `.onChange(of: transcribeProviderRaw)`. In Dual mode there is no `transcribeProvider` change; the trigger must be on `transcriptionMode` change AND on Start-tap.
  - **Mitigation:** add a Start-tap guard separate from the picker-change `.onChange`. The Phase J test asserts the disclosure fires on Start, not on mode toggle alone (so the user can preview Dual controls without committing to apple-cloud disclosure).

---

## 13. Documentation updates (cross-phase, AC-11)

These updates land alongside the corresponding code phases (NOT in a separate documentation phase) so each PR is self-documenting:

- `docs/tools/macrec.md` — add Dual-mode section: CLI flags (Phase H), JSONL `channel` field convention (Phase D), TXT line-prefix convention (Phase D), SRT/VTT speaker-tag conventions (Phase D), apple-cloud caveat reuse (Phase J).
- `docs/tools/macrec-ui.md` — add Dual-mode section: mode switch (Phase E), Dual panel controls (Phase F), dual-lane transcript display (Phase G), per-channel metrics (Phase I), privacy disclosure trigger (Phase J).
- `CLAUDE.md` Tools section — update the `macrec` and `macrec-ui` entry summaries to mention Dual mode in one sentence each (the full documentation lives in `docs/tools/`).
- `docs/design/project-design.md` — add a new section "Dual Transcription Subsystem" describing the actor topology, fan-out path, merged-event stream, sidecar tagging, and AppStorage namespace. Cross-reference plan-010.
- `docs/design/project-functions.md` — register FR-1..FR-11 from the refined request as new functional requirements. (This update lands as part of the same commit as this plan file — see report below.)
- `Issues - Pending Items.md` — register a `PLAN-010-PENDING-{phase}` entry per phase as work proceeds; move to the Completed section as each phase merges.

AC-11 is satisfied when ALL the above docs are updated by the end of Phase 9 (code review).

---

## 14. Test summary (AC-10 coverage)

New test files (12 total):

| File | Phase | What it covers |
|---|---|---|
| `DualTranscriptionFoundationTests.swift` | A | Types, enums, AppStorage defaults |
| `DualTranscriptionManagerTests.swift` | B | Manager start/ingest/stop/rotate |
| `DualChannelIsolationTests.swift` | B | Per-channel failure isolation |
| `RecordingSessionDualDispatchTests.swift` | C | Dispatcher protocol routing |
| `SingleModeRegressionTests.swift` | C | AC-1 byte-equivalence (JSONL) |
| `DualSidecarWriterTests.swift` | D | All four formats with two-channel input |
| `SingleModeSidecarRegressionTests.swift` | D | AC-1 byte-equivalence (txt/srt/vtt) |
| `TranscriptionModeSwitchTests.swift` | E | Mode toggle + persistence |
| `SingleTranscriptionControlsRegressionTests.swift` | E | Extracted view preserves all keys |
| `DualTranscriptionControlsTests.swift` | F | Dual panel controls + locale constraints |
| `ControlBarStartTappedDualTests.swift` | F | Dual-mode Start construction |
| `DualLiveTranscriptViewTests.swift` | G | Lane partition + clear behaviour |
| `LiveTranscriptPanelSingleModeTests.swift` | G | Single-mode rendering unchanged |
| `StartCommandDualFlagsTests.swift` | H | CLI flag parsing + env var resolution |
| `DualTranscriptionMetricsViewTests.swift` | I | Per-channel metrics rendering |
| `DualPrivacyDisclosureTests.swift` | J | First-run apple-cloud disclosure trigger |

Plus one shell-based smoke test in `test_scripts/`:

- `test_scripts/dual_cli_parity_smoke.sh` — UI vs CLI sidecar parity (Phase H).

Plus a manual e2e test plan in `test_scripts/dual_e2e_manual.md` (because TCC + real microphone + real network make full automation impractical):

1. Launch `dist/macrec-ui.app` (NOT raw binary — apple-cloud SIGABRT caveat).
2. Switch to Dual mode; accept apple-cloud disclosure if prompted.
3. Start a 60-second recording with default locales; speak: "Καλημέρα, this is a test, πώς είσαι σήμερα, the weather is nice."
4. Stop; inspect:
   - Audio file is present and plays back.
   - `<basename>.transcript.jsonl` contains both `model: "apple"` (en-US) and `model: "apple-cloud"` (el-GR) entries.
   - Live UI showed both lanes with partials during recording.
5. Disable network mid-recording (Wi-Fi off); verify Channel B errors out and Channel A continues; verify the lane shows the actionable error.
6. Repeat step 1–4 via CLI (`swift run macrec start --transcribe-dual ...`) and diff the JSONL sidecars (after timestamp normalisation).

---

## 15. Risk register (consolidated)

| Risk | Phase(s) | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Single-mode regression (AC-1 violation) | C, D, E, G | Low | High | Byte-equivalence regression tests in Phase C and D; visual diff in Phase E; structural diff in Phase G |
| Mode switch is itself a visible Single-mode change (AC-1 wording dispute) | E | Medium | Medium | Investigator default (segmented picker) is one row; fallback to Toggle below (OQ-1) is a one-file swap |
| `AudioDownsampler` shared-state corruption | B | Low | High | Two instances per dual manager (per IP-4 + investigator §Q2 Option 2A) |
| Two pipelines double-write to one sidecar via two writer instances | B | Low | High | Phase B test asserts writer identity (`pipelineA.sidecarWriter === pipelineB.sidecarWriter`) |
| Channel-B network failure escalates to recording termination | B | Low | Medium | Per-channel drain Tasks with `do { ... } catch`; Phase B isolation test |
| Apple-cloud SIGABRT under raw binary launch | H, J | High (already known) | High | Reuse existing `isRunningFromAppBundle` gate; no new mitigation needed (NFR-7) |
| Quota indicator (FR-9) not observable from `AppleCloudStreamingSession` | I | Medium | Low | Ship v1 without quota indicator; document as v2 follow-up |
| Designer changes flag spelling between Phase 5 and Phase H coding | H | Medium | Low | Phase H is gated on OQ-3 resolution; flag rename is mechanical |
| OQ-2 (per-channel disable) flips late | F | Low | Low | The control surface is additive; Phase F can trivially add per-channel toggles after the fact |

---

## 16. Phase 5 designer hand-off summary

The designer (Phase 5) MUST close OQ-1, OQ-2, OQ-3, OQ-4, OQ-5, OQ-6 before the corresponding implementation phases can start. Suggested ordering for the designer's session:

1. **OQ-6** (generic vs specific orchestrator) — affects Phase B scope; resolve first. Investigator strongly recommends specific.
2. **OQ-1** (mode-switch control type) — affects Phase E. Investigator recommends segmented picker; user pushback risk is medium.
3. **OQ-3** (CLI flag spelling) — affects Phase H. Investigator recommends `--transcribe-dual` boolean + dedicated `--transcribe-dual-locale-{a,b}`.
4. **OQ-4** (SRT/VTT channel labelling) — affects Phase D. Investigator recommends VTT `<v>` tags + SRT `EN: ` / `EL: ` prefixes.
5. **OQ-5** (dual-lane UI layout) — affects Phase G. Investigator does not pre-pick; designer's call.
6. **OQ-2** (per-channel disable) — affects Phase F additively. Investigator does not pre-pick; designer's call.

After Phase 5, the planner (this document) does not need to be revised unless the designer flips OQ-6 to generic — in which case Phase B is rewritten and Phase A's `DualChannelTag` becomes a `[ChannelTag]` list.

---

## 17. Out of plan-010 scope (deferred to v2 candidates)

Captured here so they are visible but do NOT distract Phase 5–10:

- Generic N-way SessionGroup (OQ-6 generic resolution → defer).
- Cross-channel deduplication / NLP-based merging into a single linear transcript stream (refined request §Out of scope).
- Triple-mode (3+ providers) (refined request §Out of scope).
- Apple-cloud quota indicator UI surfacing (Phase I if not feasible in v1 → defer to v2).
- Translation between channels (refined request §Out of scope).
- Dual mode for non-Apple provider pairs (Soniox + Gemini etc.) (refined request §Out of scope).

---

## 18. Sign-off checklist (for Phase 9 reviewer / Phase 10 integration verifier)

- [ ] All 11 functional requirements (FR-1..FR-11) traceable to a code change in this plan.
- [ ] All 7 non-functional requirements (NFR-1..NFR-7) addressed with verification.
- [ ] All 11 acceptance criteria (AC-1..AC-11) covered by tests or manual verification steps.
- [ ] Single-mode JSONL byte-equivalence (AC-1) verified by automated test.
- [ ] Visual diff of Single-mode panel before/after this PR shows no field-control changes.
- [ ] All 6 open questions (OQ-1..OQ-6) resolved by Phase 5 designer; resolution documented in this plan or a follow-up amendment.
- [ ] `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`, `CLAUDE.md`, `docs/design/project-design.md`, `docs/design/project-functions.md` all updated.
- [ ] `Issues - Pending Items.md` final entry moved to Completed section.

---

*End of plan-010.*
