# Plan 003 — Live Transcription Side-Channel for `macrec` / `macrec-ui`

> Phase 4 (Planner) deliverable for the live-transcription v1.2 feature. Sibling
> document to `plan-001-recording-tool.md` (CLI engine) and
> `plan-002-toolbar-ui.md` (menu-bar UI). Consumed downstream by Phase 5
> (Designer), Phase 6 (parallel Coders), Phase 7 (Code Reviewer), Phase 8
> (Dependency Validator), Phase 9 (Test Builders), and Phase 10 (Integration
> Verifier).
>
> **Date**: 2026-04-26
>
> **Source documents (read in this order before executing this plan):**
>
> 1. `docs/design/refined-request-live-transcription.md` — refined spec
>    (FR-45..FR-58, NFR-17..NFR-21, AC-LT-1..AC-LT-25, A-LT-1..A-LT-10,
>    OQ-LT-1..OQ-LT-7). Authoritative for scope.
> 2. `docs/reference/investigation-live-transcription.md` — investigation
>    deliverable. Authoritative for the architectural shape and provider
>    choice (Gemini 3.1 Flash Live via direct `URLSessionWebSocketTask`).
> 3. `docs/research/gemini-live-wire-schema.md` — exact JSON wire schema and
>    Codable types. **Critical: `responseModalities: ["TEXT"]` is rejected
>    on `gemini-3.1-flash-live-preview` — must use `["AUDIO"]` +
>    `inputAudioTranscription: {}` and discard returned audio bytes.**
> 4. `docs/research/audio-downsample-conversion.md` — drop-in
>    `AudioDownsampler` Swift class for Float32-48k → PCM16-16k via
>    `AVAudioConverter`.
> 5. `docs/research/websocket-asyncstream-pattern.md` — `WebSocketSession`
>    actor and reconnection state machine.
> 6. `docs/reference/codebase-scan-live-transcription.md` — exact file
>    paths and integration points.
> 7. `docs/design/project-design.md` — current architecture (audio pipeline,
>    `RecordingSession`, exit-code table, error contract).
> 8. `docs/design/plan-001-recording-tool.md` and
>    `docs/design/plan-002-toolbar-ui.md` — phasing-style precedent.
>
> **Project rules honored** (recorded for the executors):
>
> - Implementation language is **Swift** (CLAUDE.md project memory Exception 001).
> - **No fallback values for missing config.** A non-`None` provider with
>   no API key resolves to `MacrecError.transcriptionApiKeyMissing` —
>   never silently default to `None`.
> - **Sidecar files only.** Never modify the on-disk audio output.
> - **Provider abstraction.** `TranscriptionProvider` protocol with
>   `Gemini Live` as v1's first concrete impl; OpenAI Realtime / Deepgram /
>   AssemblyAI must drop in without orchestration-code changes.
> - **Tests cannot use real API keys** — drive integration via
>   `FakeTranscriptionProvider`.
> - **Tests cannot drive `ScreenCaptureKit` from `XCTest`** — pipeline
>   tests use synthetic `AVAudioPCMBuffer` fixtures.
> - **No new SwiftPM dependencies.** Pure Foundation / AVFoundation /
>   Network.
> - **No new `~/.tool-agents/` folder.** Transcription keys live in the
>   existing `~/.tool-agents/macrec/.env` and `~/.tool-agents/macrec-ui/.env`.

---

## Section 0 — Pre-Plan Decisions

### 0.1 Resolved Open Questions (from refined-request §Open Questions)

The planner resolves the open questions below from the research and
investigation findings. Each is recorded so that downstream phases do
not re-litigate.

| OQ | Resolution | Rationale |
|---|---|---|
| **OQ-LT-1** — Exact Gemini model id | **`gemini-3.1-flash-live-preview`** (with `models/` prefix). Pinned in `RecordingOptions.transcriptionModelId`; fallback if removed: `gemini-live-2.5-flash-native-audio` (same wire protocol, only the string changes). | Investigation §Recommendation pt. 1; research §1; vendor-canonical model name in vendor docs. |
| **OQ-LT-2** — Default source: `mixed` vs `both` | **`mixed`** as default; `both` exposed as a UI option for users who want speaker-labeled output. | Refined-request A-LT-1 + investigation Implementation Considerations. Confirmed by the planner — minor UX tradeoff, easy to switch later. |
| **OQ-LT-3** — Inline panel vs separate window | **Inline panel** below the level meters with fixed max-height ~120 pt and "Jump to live" affordance. Separate window logged as v2 in `Issues - Pending Items.md`. | Refined-request FR-52 default; investigation pt. 14. Avoids window-management complexity in v1. |
| **OQ-LT-4** — Transport: WebSocket vs gRPC | **`URLSessionWebSocketTask`** (Foundation, JSON over wss). | Investigation §Recommendation pt. 2; research §1; avoids new SwiftPM dep. |
| **OQ-LT-5** — Detach-mode transcription | **Excluded from v1** (per A-LT-4). v1 transcription requires foreground execution (CLI without `--detach` or via `macrec-ui`). The CLI flag combination `--detach --transcribe <provider!=none>` exits 64 (`EX_USAGE`) with a remediation hint. v2 follow-up logged in `Issues - Pending Items.md`. | Daemonised process has no terminal to render partials; sidecar-only detach transcription multiplies risk surface and is not justified for v1. |
| **OQ-LT-6** — Maximum session length | **Mitigated by `contextWindowCompression: { slidingWindow: {} }` + `sessionResumption: {}`** in the setup message. The 15-minute audio-only context limit is removed by sliding window; the ~10-minute connection limit is bridged by handle-based resumption. Brief gap (≤ 1 s) at every reconnect is documented in `docs/tools/macrec.md` and surfaced in the post-stop disclosure. Acceptable for v1. | Research §3 setup-message annotations + §7 (session resumption) + §9 (limits). |
| **OQ-LT-7** — `--max-duration` propagates to transcription | **Yes (default), one-way only.** Transcription stops when the recording stops; transcription cannot extend the recording. No new flag. | Refined-request §Constraints — recording integrity isolation; tap is a side-channel only. |

### 0.2 Escalated Open Questions (require user decision)

The planner could not confidently resolve the following from research alone.
Each carries a recommended default the executors will use unless the user
overrides before Phase F coding begins.

| Escalation | Recommended default | Why escalated |
|---|---|---|
| **ESC-LT-1 — Empirical reliability of `inputAudioTranscription` on Gemini 3.1 Flash Live** | Phase A and Phase F use the wire-schema as documented; Phase I (manual smoke test) is the gate. If empirical reliability is poor, escalate to the user with two paths: (a) switch to `gemini-live-2.5-flash-native-audio` (proven), or (b) switch v1 default provider to OpenAI Realtime (GA, more expensive). | Research §15 question 1 — community report flagged unreliability on Gemini 2.5; no public reproduction yet on 3.1. |
| **ESC-LT-2 — `maxAttempts` in WebSocket reconnection state machine** | **`maxAttempts = 8`** (~110 s worst-case backoff wall clock) instead of the 12 the research-doc default suggests. | Research §"Performance Notes" recommends 8 for shorter user-perceived pause. User may prefer 12 (more retry margin, slower failure surfacing). |

### 0.3 Inconsistencies Between Inputs — How Resolved

| Inconsistency | Resolution |
|---|---|
| Refined request §§Investigation deliverables and Recommendation pt. 5 say `responseModalities: ["TEXT"]`. Research §"CRITICAL FINDINGS" pt. 1 confirms `["TEXT"]` is rejected on `gemini-3.1-flash-live-preview` with close code 1007. | **Adopt the research finding.** v1 sends `responseModalities: ["AUDIO"]` + `inputAudioTranscription: {}` and discards the returned PCM bytes (research §13 "Fallback Plan"). Documented in Phase F gate criteria. |
| Investigation §Recommendation pt. 9 says `bufferingNewest(64)` for the PCM tap. Research §"Performance Notes" suggests `bufferingNewest(32)` for the event stream. | **Both are kept — they are different streams.** PCM tap (audio in): `bufferingNewest(64)` — 64 chunks × ~960 bytes ≈ 60 KB. Event stream (transcript out): `bufferingNewest(32)` — 32 events × ~150 bytes ≈ 5 KB. Both far below NFR-19's 8 MB ceiling. |
| Investigation §Recommendation pt. 3 says 30 ms chunk cadence. Research §4 says Google's official sample uses 64 ms (1024 samples). | **Adopt 30 ms** (research §4 explicitly says 30 ms is acceptable). Aligner produces 100 ms windows; downsampling to 16 kHz produces 1600 samples = 100 ms PCM16. We pre-split into ~3 × 30 ms chunks before base64 to keep WebSocket message frequency moderate. |
| Refined request says "30 s clean-shutdown drain timeout"; some text in the spec uses 5 s. | **Use 5 s** (matches FR-57 in the spec body). The 30 s figure is the existing recorder's `finishWriting` timeout (FR-20), not the transcription drain. |

### 0.4 FR / NFR Numbering for `project-functions.md`

The next free FR number is **FR-45** (FR-1..FR-44 are taken; FR-25..FR-29 detach
mode, FR-30..FR-44 toolbar UI). The next free NFR number is **NFR-17**
(NFR-1..NFR-16 taken). The fourteen new FRs (FR-45..FR-58) and five new NFRs
(NFR-17..NFR-21) line up with the proposals in the refined request. **Phase 0
of this plan writes them into `project-functions.md`.**

---

## Section 1 — Goal

Add an opt-in, model-pluggable, **side-channel live transcription**
capability to `macrec` and `macrec-ui` so a user can stream the captured
audio in parallel to a real-time audio-in / text-out service while the
recording is in progress. v1 ships with two providers: `None` (default,
true no-op) and `Gemini Live` (`gemini-3.1-flash-live-preview` over
`URLSessionWebSocketTask`). The transcription path is fully isolated
from the recording path — a hang or crash in transcription cannot
affect the on-disk audio file, which remains the project's primary
artefact.

The work is broken into ten sequenced phases (Phase 0..I) mirroring the
gate-criteria style of `plan-001` and `plan-002`. The execution order
respects dependencies: Phase 0 sets up docs and FR registration; Phase A
defines the protocol and fakes; Phase B integrates the audio tap; Phase C
plumbs configuration; Phase D adds sidecar persistence; Phase E delivers
the reusable `WebSocketSession` actor; Phase F implements
`GeminiLiveTranscriptionProvider`; Phase G integrates the UI; Phase H
updates documentation; Phase I is a manual end-to-end smoke test against
a real Gemini API key.

The plan is strictly additive: every existing AC in `plan-001` (AC-1..AC-20)
and `plan-002` (AC-UI-1..AC-UI-18) MUST continue to pass unchanged. With
`--transcribe none` (the default), the build is bit-for-bit equivalent in
behavior to the pre-plan-003 build (AC-LT-1, AC-LT-16).

---

## Section 2 — Scope

### 2.1 In scope (v1)

Direct mirror of refined-spec §"In scope":

- A new `MacrecCore.Transcription` namespace housing:
  - `TranscriptionProvider` protocol (FR-45).
  - `TranscriptionPCMChunk`, `TranscriptEvent`,
    `TranscriptionAudioFormat`, `TranscriptionOptions`,
    `CaptureSourceTag` value types.
  - `NoOpTranscriptionProvider` (FR-45).
  - `FakeTranscriptionProvider` (test-only — drives unit + integration
    tests deterministically without network).
  - `GeminiLiveTranscriptionProvider` (FR-45 + Phase F).
  - `TranscriptionDriver` actor — owns the audio downsampler, the
    bounded `AsyncStream<TranscriptionPCMChunk>`, the provider task,
    and the sidecar writer.
  - `AudioDownsampler` (Float32/48k → PCM16/16k mono — research-doc
    drop-in).
  - `WebSocketSession` actor + `WebSocketTransport` protocol +
    `LiveWebSocketTransport` (research-doc drop-in).
  - `TranscriptSidecarWriter` (jsonl/srt/vtt/txt; FR-51).
- New CLI flags on `macrec start`: `--transcribe`, `--transcribe-source`,
  `--transcript-output`, `--transcript-format`, `--transcribe-key-expires-at`
  (FR-48).
- New `MacrecError` cases: `transcriptionApiKeyMissing`,
  `transcriptionProviderUnavailable`, `transcriptionSessionFailed`,
  `transcriptionDetachUnsupported`, `transcriptionInvalidProvider`
  (extends FR-18 exit-code table).
- New `RecordingOptions` stored properties for transcription settings,
  with a corrected `withOutput(_:)` that copies them (closes the latent
  bug from codebase-scan §5).
- New `~/.tool-agents/macrec/.env` durable defaults: `GOOGLE_API_KEY`,
  `MACREC_TRANSCRIBE_PROVIDER`, `MACREC_TRANSCRIBE_SOURCE`,
  `MACREC_TRANSCRIPT_FORMAT`, `MACREC_TRANSCRIBE_MODEL`,
  `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`. Same six in
  `~/.tool-agents/macrec-ui/.env`.
- New `macrec-ui` Views:
  - `TranscriptionPicker` (None / Gemini Live).
  - `TranscriptionSourcePicker` (system / mic / mixed / both).
  - `TranscriptFormatPicker` (jsonl / txt / srt / vtt).
  - `TranscriptPanel` (live, scrollable, ~120 pt max-height, partials in
    muted style, finals committed; "Jump to live" affordance).
  - `TranscriptionPrivacyAlert` (one-time-per-bundle disclosure).
  - `TranscriptionMissingKeyBadge` (red-dot + tooltip when API key not
    configured).
- `RecordingController` extensions: `transcriptEvents`,
  `transcriptionState`, `transcriptionProviderMissingKey`,
  `transcriptionMetrics` observed properties; `transcriptionDriver` task
  lifecycle.
- `SessionCoordinator` segment-rotation hooks driving sidecar rotation
  (FR-51 multi-segment naming).
- Documentation: `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`,
  `docs/design/configuration-guide.md`, `docs/design/project-design.md`
  (new "Transcription Architecture" section), `docs/design/project-functions.md`
  (FR-45..FR-58 + NFR-17..NFR-21), `CLAUDE.md` "Tools" section
  (entries unchanged but references the new docs sections).
- Tests: a Swift Testing suite per file, all using
  `FakeTranscriptionProvider` to bypass real network calls. Integration
  tests gated on `GOOGLE_API_KEY` environment variable presence (skip
  cleanly when absent).
- One end-to-end shell script `test_scripts/e2e-transcription.sh` that
  runs only when `GOOGLE_API_KEY` is exported, exercises `--transcribe
  gemini-live` end-to-end against the real API for a 30 s synthetic
  audio fixture, and asserts that the resulting `recording-….transcript.jsonl`
  parses, contains at least one final, and the audio file is byte-identical
  to a control recording.

### 2.2 Out of scope (v1)

Direct mirror of refined-spec §"Out of scope":

- On-device transcription (Apple Speech, WhisperKit). Logged as v2
  follow-up.
- Speaker diarization beyond the `system` / `mic` source label.
- Translation (target-language selection).
- In-app transcript editing or post-processing.
- Re-transcription of finished recordings.
- Detach-mode transcription (excluded by OQ-LT-5).
- Multi-recording cost dashboards.

### 2.3 Architectural Locks (do not re-litigate)

These are sealed by the investigation + research and are NOT re-debated
during execution.

- **Provider for v1**: Gemini 3.1 Flash Live via direct
  `URLSessionWebSocketTask`. (Investigation §Recommendation pt. 1+2.)
- **Wire protocol**: JSON-over-WebSocket. **No SDK dependency.**
  (Investigation §Recommendation pt. 2; research §1.)
- **Audio format on the wire**: PCM16 / 16 kHz / mono / little-endian.
  (Research §4.)
- **Setup message**: `responseModalities: ["AUDIO"]` +
  `inputAudioTranscription: {}` + system instruction "transcribe verbatim,
  do not respond" + `contextWindowCompression: { slidingWindow: {} }` +
  `sessionResumption: {}`. The `["TEXT"]` modality is **forbidden** on
  this model. (Research §3 + §13.)
- **Audio tap point**: `HostClockAligner.onAlignedFrame` for `mixed`,
  `system`, and `mic` sources; per-source taps on
  `SCKitSystemAudioSource.transcriptionTap` and
  `AVMicrophoneSource.transcriptionTap` for the `system`/`mic`/`both`
  modes. (Codebase scan §4.1; investigation §Recommendation pt. 4.)
- **Bounded queue policy**: `AsyncStream<TranscriptionPCMChunk>` with
  `.bufferingNewest(64)`. Drops increment a metric; no back-pressure to
  capture queues. (Investigation §Recommendation pt. 9.)
- **Audio downsampler**: dedicated `AVAudioConverter` per
  `TranscriptionDriver`; never reused with the recorder. (Refined-request
  §Technical; research-doc drop-in.)
- **WebSocket reconnection**: bounded exponential backoff with jitter
  (base 0.5 s, cap 30 s, ±25 %), `maxAttempts = 8`, `NWPathMonitor`-driven
  fast-resume on connectivity-restored. (Research §"Reconnection State
  Machine" + planner ESC-LT-2.)
- **Heartbeat**: 15 s app-level ping, fire-and-forget. (Research
  §"Heartbeat Implementation".)
- **Provider abstraction**: `TranscriptionProvider` protocol shape
  per investigation §Recommendation pt. 10 — verbatim copy.
- **Sidecar default format**: `jsonl`. (A-LT-2.)
- **Privacy disclosure**: one-time-per-bundle, suppressible by checkbox,
  re-discoverable via tooltip. (A-LT-9.)
- **Cost / metrics**: tracked in sidecar header + post-stop log line;
  no separate dashboard UI. (FR-58.)
- **No fallback for missing API key**: throws
  `MacrecError.transcriptionApiKeyMissing` mapped to exit 78. (Refined-
  request §Technical — no-fallback rule.)

---

## Section 3 — Phasing Overview

```
Phase 0 — pre-flight (docs + FR registry)
   │
   ├─ Phase A — Provider protocol + NoOp + Fake (no networking)
   │     │
   │     ├─ Phase B — Audio tap + AudioDownsampler  (depends on A)
   │     │     │
   │     │     ▼
   │     ├─ Phase C — Configuration plumbing      (depends on A; parallel with B)
   │     │     │
   │     │     ▼
   │     ├─ Phase D — Sidecar persistence         (depends on A + C)
   │     │     │
   │     ├─ Phase E — WebSocketSession actor      (parallel with A; independent)
   │     │     │
   │     ▼     ▼
   │   Phase F — GeminiLiveTranscriptionProvider  (depends on A + E)
   │     │
   ├─────┴── Phase G — macrec-ui integration       (depends on D + F)
   │
   ├─ Phase H — Documentation                       (depends on G)
   │
   └─ Phase I — Manual end-to-end smoke test       (depends on H; user-driven)
```

### Parallelization Map

- After **Phase 0** completes, **Phase A and Phase E run in parallel**
  (both are independent foundational pieces — the protocol abstraction and
  the network transport).
- **Phase B and Phase C run in parallel** after Phase A completes (one
  touches the audio pipeline, the other touches configuration; no file
  overlap).
- **Phase D** depends on both A (event types) and C (sidecar format
  selection in `RecordingOptions`).
- **Phase F** depends on A (protocol) and E (WebSocket transport); it
  can start once both are merged.
- **Phase G** depends on D (sidecar wiring) and F (real provider) — but
  large parts of the UI (pickers, privacy alert, panel layout) can be
  built against `FakeTranscriptionProvider` from Phase A as soon as Phase
  A is merged. The **only** Phase G work that is gated on Phase F is the
  end-to-end "live transcription with real Gemini" smoke flow, which
  belongs to Phase I.
- **Phase H** runs after Phase G is functionally complete; the doc
  updates are mechanical.
- **Phase I** is a manual checklist driven by the user — the final
  acceptance gate.

---

## Section 4 — Phase Detail

Each phase below lists: **Goal**, **Files**, **Dependencies**,
**Parallelizable units within the phase**, **Acceptance criteria**
(which AC-LT-* IDs are satisfied), **Verification command**, and
**Risks + mitigation**.

---

### Phase 0 — Pre-flight: docs scaffolding + functional registry

- **Goal**: Stand up the documentation entries and FR registry **before
  any code is written** so subsequent phases land in a conformant project
  state.

- **Files to modify** (no new files):
  - `docs/design/project-functions.md` — append §1.5 "Added by plan-003 —
    Live transcription side-channel" with FR-45..FR-58 and
    NFR-17..NFR-21, all `Status: PLANNED`, with phase mapping from this
    plan.
  - `Issues - Pending Items.md` — pre-register R-26..R-30 (this plan's
    risk register, §6) so Phase 7 / Phase 10 see them.
  - `CLAUDE.md` "Tools" section — **no change needed** (tools are
    `macrec` and `macrec-ui`; transcription is a feature of those tools,
    not a new tool, per refined-request §Process). Verify the entries
    still point at `docs/tools/macrec.md` and `docs/tools/macrec-ui.md`.

- **Files NOT touched in Phase 0**:
  - `docs/tools/macrec.md` and `docs/tools/macrec-ui.md` — updated by
    Phase H (after the implementation behavior is locked).
  - `~/.tool-agents/macrec/.env` and `~/.tool-agents/macrec-ui/.env` —
    transcription keys are *additive* env vars, not new files; the
    existing folders and files stay in place. Phase H's documentation
    changes describe how to add the new keys; users add them themselves
    as they would any other config value.

- **Dependencies**: none.

- **Parallelizable units**: the three file edits (FR registry, Issues,
  CLAUDE.md verification) are independent.

- **Acceptance criteria**:
  - **AC-LT-24** (project-functions.md updated with FR-45..FR-58 +
    NFR-17..NFR-21).
  - Partial-credit toward **AC-LT-25** (Issues — Pending Items.md
    updated; full credit lands at end of Phase H).

- **Verification command**:
  - `swift build` exits 0 (no regression — this phase touches only
    markdown).
  - `grep -c '^#### FR-' docs/design/project-functions.md` returns the
    expected count (44 + 14 = 58).
  - `grep -c '^#### NFR-' docs/design/project-functions.md` returns the
    expected count (16 + 5 = 21).

- **Risks + mitigation**:
  - **R-Phase0** — Wrong FR numbers due to off-by-one. Mitigation:
    Phase 0 reads the existing `project-functions.md` and appends after
    the highest existing number; the planner has confirmed 44 / 16 are
    the highest.

---

### Phase A — Provider protocol, value types, NoOp, Fake (no networking)

- **Goal**: Land the `TranscriptionProvider` protocol contract,
  associated value types (`TranscriptionPCMChunk`, `TranscriptEvent`,
  `TranscriptionAudioFormat`, `TranscriptionOptions`), the
  `NoOpTranscriptionProvider`, and the `FakeTranscriptionProvider` used
  by every downstream test. **No networking. No audio integration.** All
  of Phase A's tests run with zero TCC requirements.

- **Files to create** (all under `Sources/MacrecCore/Transcription/`):
  - `TranscriptionProvider.swift` — protocol definition (verbatim from
    investigation §Recommendation pt. 10):
    ```swift
    public protocol TranscriptionProvider: Sendable {
        var providerId: String { get }
        var displayName: String { get }
        var requiredApiKey: String? { get }
        var requiredAudioFormat: TranscriptionAudioFormat { get }
        func run(
            audio: AsyncStream<TranscriptionPCMChunk>,
            options: TranscriptionOptions
        ) -> AsyncStream<TranscriptEvent>
    }
    ```
  - `TranscriptionPCMChunk.swift` — `Sendable` value type with fields:
    `pcmData: Data`, `sampleRate: Int`, `channelCount: Int`,
    `source: CaptureSourceTag`, `hostTime: UInt64`.
  - `TranscriptEvent.swift` — `Sendable` enum:
    `partial(text:source:hostTime:)`,
    `final(text:source:startedAt:endedAt:)`,
    `error(reason:isFatal:)`, `sessionEnded(reason:)`.
  - `TranscriptionAudioFormat.swift` — `Sendable` value type
    (`sampleRate: Int`, `bitDepth: Int`, `channelCount: Int`,
    `byteOrder: ByteOrder`).
  - `TranscriptionOptions.swift` — `Sendable` struct with
    `provider: TranscriptionProviderId`, `source: TranscriptionSource`,
    `format: TranscriptFormat`, `apiKey: String?`,
    `modelId: String?` (Gemini-specific override),
    `keyExpiresAt: Date?`.
  - `TranscriptionProviderId.swift` — `Sendable` enum:
    `none`, `geminiLive`, `openaiRealtime` (placeholder, future),
    `deepgram` (placeholder, future), `assemblyAI` (placeholder, future).
    `RawValue`-based string mapping (`"none"`, `"gemini-live"`, etc.).
    A `static func parse(_ raw: String) throws -> Self` that throws
    `MacrecError.transcriptionInvalidProvider(raw:registered:)` on bad
    input.
  - `TranscriptionSource.swift` — `Sendable` enum: `system`,
    `microphone`, `mixed`, `both`.
  - `TranscriptFormat.swift` — `Sendable` enum: `jsonl`, `txt`, `srt`,
    `vtt`. `RawValue`-based string mapping.
  - `CaptureSourceTag.swift` — *Move* the existing `CaptureSourceTag`
    from `Capture/CaptureBuffer.swift:21` here? **No** — leave it where
    it is; transcription imports it. (No file change required if
    `CaptureSourceTag` is already `public Sendable`; verify in Phase A.)
  - `NoOpTranscriptionProvider.swift` — concrete provider that returns
    an `AsyncStream<TranscriptEvent>` which immediately calls
    `continuation.finish()`. Used when `options.provider == .none`.
  - `FakeTranscriptionProvider.swift` — **test-only** but lives in
    `Sources/MacrecCore/Transcription/` (not in `Tests/`) so the UI's
    test target can also use it. Driven by an *injected script* —
    `init(script: [TranscriptScriptStep])` where each step is one of:
    `.partial(text:after:)`, `.final(text:after:)`, `.error(reason:after:fatal:)`,
    `.disconnect(after:)`, `.hang(after:)`. Its `run()` consumes audio
    chunks (counting them for assertions) and emits the scripted events
    on a separate `Task`.

- **Files to modify**:
  - `Sources/MacrecCore/Errors/MacrecError.swift` — extend `enum`:
    - `transcriptionApiKeyMissing(provider: String, key: String, sourcesChecked: [String])` — exit 78.
    - `transcriptionProviderUnavailable(provider: String, reason: String)` — exit 70.
    - `transcriptionSessionFailed(provider: String, reason: String)` — non-fatal in `MacrecError.exitCode` switch (returns 0; logged but doesn't stop the recording).
    - `transcriptionDetachUnsupported` — exit 64 (`EX_USAGE`); raised when `--detach --transcribe` is used.
    - `transcriptionInvalidProvider(raw: String, registered: [String])` — exit 64.
    Each new case extends `description` and `remediation` text per the file-header style note (line 7).
  - `Tests/MacrecCoreTests/MacrecErrorTests.swift` — add cases verifying
    each new exit-code mapping (locked-string regression).

- **Test files to create** (all under `Tests/MacrecCoreTests/Transcription/`):
  - `TranscriptionProviderProtocolTests.swift` — exercises `NoOp` end-to-end:
    feed a few chunks, assert the event stream is empty and finishes.
  - `FakeTranscriptionProviderTests.swift` — verifies every script step:
    partials are emitted with correct text, finals are emitted, errors
    surface as `TranscriptEvent.error`, `disconnect` and `hang` behave
    as documented.
  - `TranscriptEventCodableTests.swift` — `TranscriptEvent` is
    JSON-Codable (round-trips through `JSONEncoder`/`JSONDecoder`). Used
    by Phase D's sidecar writer.

- **Dependencies**: Phase 0 (FR registry exists).

- **Parallelizable units within the phase**:
  - Unit P-A1: All eight value-type files
    (`TranscriptionPCMChunk`, `TranscriptEvent`, `TranscriptionAudioFormat`,
    `TranscriptionOptions`, `TranscriptionProviderId`,
    `TranscriptionSource`, `TranscriptFormat`, plus the protocol shell
    `TranscriptionProvider.swift`). Independent files; one coder.
  - Unit P-A2: `NoOpTranscriptionProvider.swift` + its test. Independent
    once P-A1 lands; one coder.
  - Unit P-A3: `FakeTranscriptionProvider.swift` + its test. Independent
    once P-A1 lands; one coder.
  - Unit P-A4: `MacrecError` extension + test. Independent of P-A1..A3;
    one coder.
  - **Wave 1** (parallel after Phase 0): P-A1, P-A4. **Wave 2** (parallel
    after Wave 1): P-A2, P-A3.

- **Acceptance criteria**:
  - **AC-LT-1** (None is a true no-op): partial-credit; final integration
    happens in Phase B.
  - **AC-LT-17** (invalid provider name fails with `EX_USAGE`):
    `TranscriptionProviderId.parse(...)` throws
    `transcriptionInvalidProvider`, mapped to exit 64.
  - Test infra credit: `FakeTranscriptionProvider` exists and is usable
    by every downstream phase's tests.

- **Verification command**:
  - `swift build` exits 0 with zero warnings.
  - `swift test --filter TranscriptionProviderProtocolTests` exits 0.
  - `swift test --filter FakeTranscriptionProviderTests` exits 0.
  - `swift test --filter TranscriptEventCodableTests` exits 0.
  - `swift test --filter MacrecErrorTests` exits 0 (no regression on
    existing cases; new cases pass).

- **Risks + mitigation**:
  - **R-Phase A.1** — `Sendable` conformance on enums with associated
    values (e.g., `TranscriptEvent.error(reason:isFatal:)`). Mitigation:
    `String` and `Bool` are `Sendable`; the enum is `Sendable` by
    synthesis. Tests verify by spawning a Task that yields and consumes
    the event.
  - **R-Phase A.2** — `FakeTranscriptionProvider` placement. Refined-
    request §"In scope" says it lives in
    `Sources/MacrecCore/Transcription/`, NOT `Tests/`. Rationale:
    `Tests/MacrecUITests/` cannot import a symbol that lives in
    `Tests/MacrecCoreTests/`. Marked `public` so both test targets can
    instantiate it. Document this in the file's header so reviewers
    don't move it.

---

### Phase B — Audio tap + downsampler + bounded `AsyncStream` plumbing

- **Goal**: Wire the live PCM tap from the audio pipeline into a
  `TranscriptionDriver` actor that uses the `AudioDownsampler` from the
  research doc and feeds a bounded `AsyncStream<TranscriptionPCMChunk>`.
  At the end of this phase, the driver instantiates a
  `NoOpTranscriptionProvider` and a 30-s recording with
  `--transcribe none` (the default) emits zero events and produces a
  byte-identical audio file vs. the pre-Phase-B build.

- **Files to create** (under `Sources/MacrecCore/Transcription/`):
  - `AudioDownsampler.swift` — verbatim copy of the research-doc
    drop-in (`docs/research/audio-downsample-conversion.md` §"Drop-In
    AudioDownsampler Swift Class"). No behavior changes.
  - `AudioDownsamplerError.swift` — separate file for the error enum
    (per the project's convention of one-symbol-per-file in the
    error / type folders).
  - `TranscriptionDriver.swift` — `actor TranscriptionDriver`. Owns:
    - The `AudioDownsampler` (created lazily on the first non-nil
      `AlignedFrame`'s format).
    - The bounded
      `AsyncStream<TranscriptionPCMChunk>.makeStream(of:bufferingPolicy:.bufferingNewest(64))`
      and its continuation.
    - The provider task: `Task { for await event in provider.run(audio:
      audioStream, options:) { ... handle ... } }`.
    - Metrics: `secondsStreamed`, `partialCount`, `finalCount`,
      `droppedFrameCount` (FR-58).
    - The (optional) sidecar writer (wired in Phase D — Phase B leaves
      a `transcriptSink: TranscriptSink?` slot).
    - A consumer-facing `events: AsyncStream<TranscriptEvent>` that
      re-emits provider events to the UI (lifetime: driver lifetime).
    Methods:
    - `start(provider: TranscriptionProvider, options: TranscriptionOptions)` —
      starts the provider task.
    - `enqueue(_ frame: AlignedFrame)` — non-blocking: downsamples and
      yields into the bounded stream, increments `droppedFrameCount` on
      `.dropped` yield result.
    - `enqueue(_ buffer: CaptureBuffer)` — for `system` / `mic`
      single-source modes; downsamples directly without summing.
    - `stop(drainTimeout: Duration)` — finalizes: closes the audio
      stream's continuation; awaits the provider task with a 5-s drain
      bound; emits any final pending event.
- **Files to modify**:
  - `Sources/MacrecCore/RecordingSession.swift`:
    - Add a public optional property
      `public var transcriptionTap: ((AlignedFrame) -> Void)?` analogous
      to `levelTap` on capture sources. The closure fires on
      `macrec.aligner.serial`, must be enqueue-and-return only.
    - In the `aligner.onAlignedFrame` closure (line 382-394), invoke
      `self.transcriptionTap?(frame)` AFTER the recorder write. The tap
      stays alive across `split(nextOutput:)` calls per refined-request
      §Tap Point B notes — confirmed by codebase scan §4.1.
  - `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift`:
    - Add `public var transcriptionTap: ((CaptureBuffer) -> Void)?`
      alongside `levelTap` (line 178). Invoked synchronously after
      `levelTap` in `handleAudioBuffer` (line 339-345).
  - `Sources/MacrecCore/Capture/AVMicrophoneSource.swift`:
    - Same `transcriptionTap` addition (mirror SCKit pattern).
  - **Test infra**: add `Sources/MacrecCore/Transcription/SyntheticAudioFixture.swift`
    — utility that produces an `AVAudioPCMBuffer` of mono / stereo
    Float32 / 48 kHz containing scriptable content (silence, 1 kHz sine,
    speech-like burst). Used by Phase B's pipeline tests in lieu of
    `ScreenCaptureKit`.

- **Test files to create** (under `Tests/MacrecCoreTests/Transcription/`):
  - `AudioDownsamplerTests.swift` — verifies the three test cases from
    the research doc (zeros → zeros, 1 kHz sine → 1 kHz sine, two 50 ms
    chunks → ~1600 frames total).
  - `TranscriptionDriverTests.swift` — drives the actor with synthetic
    `AlignedFrame`s + `FakeTranscriptionProvider`:
    - 1 s of silence → 10 chunks delivered, 0 final events emitted (the
      fake script is empty).
    - 1 s of audio with a fake script that emits one final at 800 ms →
      verifies the final reaches the driver's `events` stream.
    - 1 s of audio with a `FakeTranscriptionProvider.hang(after: 1)`
      script → verifies that the bounded queue drops chunks (drop counter
      increases) and that the driver's `enqueue(_:)` never `await`s.
  - `TranscriptionTapIntegrationTests.swift` — uses
    `RecordingSession` + `FakeAudioSource` + `FakeTranscriptionProvider`
    → asserts that with the tap installed, the audio file is byte-for-byte
    identical to a control recording without the tap (file content hash
    via `shasum`).

- **Dependencies**: Phase A (provider protocol, fakes); Phase 0 (FR
  registry).

- **Parallelizable units within the phase**:
  - Unit P-B1: `AudioDownsampler.swift` + `AudioDownsamplerError.swift` +
    `AudioDownsamplerTests.swift`. Verbatim drop-in; one coder.
  - Unit P-B2: `transcriptionTap` additions on the three source files
    (`SCKitSystemAudioSource.swift`, `AVMicrophoneSource.swift`,
    `RecordingSession.swift`). One coder (touches all three; small
    edits).
  - Unit P-B3: `TranscriptionDriver.swift` + `TranscriptionDriverTests.swift`.
    Depends on P-B1; one coder.
  - Unit P-B4: `SyntheticAudioFixture.swift` +
    `TranscriptionTapIntegrationTests.swift`. Depends on P-B2 + P-B3;
    one coder.

- **Acceptance criteria**:
  - **AC-LT-2** (recording integrity unaffected by transcription
    presence): asserted by `TranscriptionTapIntegrationTests.swift` via
    SHA comparison.
  - **AC-LT-3** (recording integrity unaffected by transcription
    failure): asserted by injecting `FakeTranscriptionProvider.hang`.
  - **AC-LT-11** (bounded queue drops, never blocks): asserted by the
    drop-counter / hanging-fake test.
  - **AC-LT-12** (source selection routes correctly): partial credit;
    full route happens in Phase C+G when CLI / UI selection wires through.

- **Verification command**:
  - `swift build` exits 0 with zero warnings.
  - `swift test --filter AudioDownsamplerTests` exits 0.
  - `swift test --filter TranscriptionDriverTests` exits 0.
  - `swift test --filter TranscriptionTapIntegrationTests` exits 0.
  - **Regression gate**: `swift test --filter RecordingSessionTests` and
    `swift test --filter HostClockAlignerTests` still exit 0 with no
    behavior change.

- **Risks + mitigation**:
  - **R-Phase B.1** — Tap closure runs on `macrec.aligner.serial`;
    accidentally `await`-ing inside it would dead-lock the aligner.
    Mitigation: `TranscriptionDriver.enqueue(_:)` is a `nonisolated`
    method that calls `continuation.yield(_:)` (synchronous, non-blocking)
    and returns. **Code-review checklist item**: every line in the tap
    closure must be synchronous.
  - **R-Phase B.2** — Format derivation timing. `AudioDownsampler`
    requires the input format up-front. Mitigation: `TranscriptionDriver`
    creates the downsampler lazily on the first non-nil
    `AlignedFrame.systemBuffer ?? micBuffer` — captures the format from
    the live buffer rather than guessing.
  - **R-Phase B.3** — `BufferSummer.sum(_:_:)` returns `nil` when both
    inputs are `nil` (gap-filled by aligner). Mitigation: `enqueue`
    short-circuits when the summed buffer is `nil` (no PCM data,
    nothing to send).
  - **R-Phase B.4** — `SyntheticAudioFixture.swift` may not produce a
    truly representative ASBD. Mitigation: derive the format by using
    `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
    channels: 2, interleaved: false)` — the exact shape SCKit produces,
    documented in `audio-downsample-conversion.md` §"Validated
    Assumptions".

---

### Phase C — Configuration plumbing (CLI flags + env vars + RecordingOptions)

- **Goal**: Plumb the new transcription configuration through every
  layer: `RecordingOptions` stored properties, `ConfigResolver.Keys`,
  `ConfigResolver.resolve(...)`, the `--transcribe`,
  `--transcribe-source`, `--transcript-output`, `--transcript-format`,
  `--transcribe-key-expires-at` CLI flags, and the four-tier env-var
  resolution chain. Critically, **update `RecordingOptions.withOutput(_:)`**
  to copy the new fields (latent bug per codebase scan §5).

- **Files to modify**:
  - `Sources/MacrecCore/Config/RecordingOptions.swift`:
    - Add stored properties (all `let`, `Sendable`, `Equatable`):
      ```swift
      let transcriptionProvider: TranscriptionProviderId    // default: .none
      let transcriptionSource: TranscriptionSource          // default: .mixed
      let transcriptionFormat: TranscriptFormat             // default: .jsonl
      let transcriptionApiKey: String?                      // nil unless provider needs one and resolver found it
      let transcriptionModelId: String?                     // nil = use provider's default
      let transcriptionOutputPath: URL?                     // nil = derive from output basename
      let transcriptionKeyExpiresAt: Date?                  // nil = no expiry warning
      ```
    - Update `withOutput(_:)` at line 185 to copy the seven new fields.
      **Closes the latent bug from codebase-scan §5 — without this fix,
      every pause/resume rotation silently loses transcription options.**
    - `Equatable` synthesis still works; verify with a unit test in
      `Tests/MacrecCoreTests/RecordingOptionsTests.swift`.
  - `Sources/MacrecCore/Config/ConfigResolver.swift`:
    - In `enum Keys` (line 235-251), add:
      `static let transcribeProvider = "MACREC_TRANSCRIBE_PROVIDER"`,
      `static let transcribeSource = "MACREC_TRANSCRIBE_SOURCE"`,
      `static let transcriptFormat = "MACREC_TRANSCRIPT_FORMAT"`,
      `static let transcriptOutputPath = "MACREC_TRANSCRIPT_OUTPUT"`,
      `static let googleApiKey = "GOOGLE_API_KEY"`,
      `static let transcribeModel = "MACREC_TRANSCRIBE_MODEL"`,
      `static let transcribeKeyExpiresAt = "MACREC_TRANSCRIBE_KEY_EXPIRES_AT"`.
    - In `resolve(...)` (line 82), add resolution logic:
      1. Resolve `transcribeProvider` via `value(_:)`. If absent,
         default to `.none` (sole permitted default — the env var
         defines whether transcription is enabled).
      2. If `provider != .none`:
         - Resolve `transcribeSource` (default `.mixed`).
         - Resolve `transcriptFormat` (default `.jsonl`).
         - Resolve `transcribeModel` (default per provider — Gemini's
           default is `gemini-3.1-flash-live-preview`; documented in the
           configuration guide).
         - Resolve the provider-specific API key. For
           `provider == .geminiLive`, key name is `GOOGLE_API_KEY`. If
           `value("GOOGLE_API_KEY")` returns `nil`, **throw**
           `MacrecError.transcriptionApiKeyMissing(provider: "gemini-live",
           key: "GOOGLE_API_KEY", sourcesChecked: [...])`. **No
           fallback. Project invariant.**
         - Resolve `transcribeKeyExpiresAt` (optional). If present and
           in the past, log a warning at `info` level: "Your
           GOOGLE_API_KEY has expired (expired YYYY-MM-DD). Recording
           will start but transcription may fail." Do NOT block start —
           the key may have been renewed without updating the env var.
         - If `provider == .geminiLive` and `--detach` is true, throw
           `MacrecError.transcriptionDetachUnsupported`.
      3. Stuff the resolved values into the new `RecordingOptions`
         fields.
  - `Sources/macrec/Commands/StartCommand.swift`:
    - Add `@Option` flags (line 36):
      ```swift
      @Option(name: [.customLong("transcribe")], help: "Live transcription provider: none|gemini-live")
      var transcribe: String?

      @Option(name: [.customLong("transcribe-source")], help: "Audio source for transcription: system|mic|mixed|both")
      var transcribeSource: String?

      @Option(name: [.customLong("transcript-output")], help: "Override the sidecar transcript path")
      var transcriptOutput: String?

      @Option(name: [.customLong("transcript-format")], help: "Sidecar transcript format: jsonl|txt|srt|vtt (default: jsonl)")
      var transcriptFormat: String?

      @Option(name: [.customLong("transcribe-key-expires-at")], help: "ISO-8601 expiry date for the transcription API key")
      var transcribeKeyExpiresAt: String?
      ```
    - In `buildCLIOverrides()` (line 174), add the five overrides.
    - In `run()` (line 92), add the early-exit check: if
      `transcribe != nil && transcribe != "none"` AND the existing
      `--detach` flag is true, throw
      `MacrecError.transcriptionDetachUnsupported`. (Belt-and-suspenders;
      `ConfigResolver.resolve` enforces the same.)
  - `Sources/MacrecCore/RecordingSession.swift`:
    - Add an optional injection point on the public initializer:
      `transcriptionProvider: (any TranscriptionProvider)? = nil` and
      `transcriptionSink: TranscriptSink? = nil` (slot for Phase D).
      Default `nil` → `RecordingSession` selects
      `NoOpTranscriptionProvider` if `options.transcriptionProvider ==
      .none`, otherwise instantiates the matching provider via a small
      registry function (see Phase F for the Gemini factory). Tests
      inject `FakeTranscriptionProvider`.

- **Test files to create**:
  - `Tests/MacrecCoreTests/Transcription/TranscriptionConfigResolverTests.swift`:
    - Provider defaults to `.none` when no env var or flag is set.
    - Setting `MACREC_TRANSCRIBE_PROVIDER=gemini-live` with no
      `GOOGLE_API_KEY` throws `transcriptionApiKeyMissing`.
    - All four sources of the chain are exercised
      (shellEnv → userEnv → localEnv → cliOverride) — the highest-priority
      value wins.
    - `--transcribe-source` parses `system | mic | mixed | both`;
      everything else throws `transcriptionInvalidProvider`-equivalent
      error (extend or alias the error case for source values).
    - `--detach --transcribe gemini-live` throws
      `transcriptionDetachUnsupported`.
  - `Tests/MacrecCoreTests/RecordingOptionsTests.swift`:
    - **Critical regression test** — `withOutput(_:)` round-trips all
      transcription fields. Constructs an `options` with non-default
      transcription values; calls `withOutput(URL("file:///tmp/x.m4a"))`;
      asserts every transcription field is preserved.

- **Dependencies**: Phase A (`TranscriptionProviderId`,
  `TranscriptionSource`, `TranscriptFormat`, `MacrecError` extensions).

- **Parallelizable units within the phase**:
  - Unit P-C1: `RecordingOptions` extension + `withOutput` fix +
    its tests. Independent; one coder.
  - Unit P-C2: `ConfigResolver.Keys` extension + `resolve` logic +
    `TranscriptionConfigResolverTests`. Depends on P-C1; one coder.
  - Unit P-C3: `StartCommand` flag wiring. Depends on P-C2; one coder.

- **Acceptance criteria**:
  - **AC-LT-4** (missing API key fails fast before audio capture):
    asserted by `TranscriptionConfigResolverTests`.
  - **AC-LT-15** (`macrec start --help` lists all new flags): asserted
    by capturing `macrec start --help` output in a regression test.
  - **AC-LT-16** (`--transcribe none` is the default and produces zero
    behavioral change vs current build): asserted by re-running
    `test_scripts/e2e-30s-mixed.sh` unchanged.
  - **AC-LT-17** (invalid provider name fails with `EX_USAGE`): full
    credit (Phase A had partial).

- **Verification command**:
  - `swift build` exits 0.
  - `swift test --filter TranscriptionConfigResolverTests` exits 0.
  - `swift test --filter RecordingOptionsTests` exits 0.
  - `swift run macrec start --help` shows the five new flags.

- **Risks + mitigation**:
  - **R-Phase C.1** — Forgetting to update `withOutput(_:)`. Mitigation:
    the test in `RecordingOptionsTests.swift` is **mandatory**; reviewer
    must verify it passes before this phase merges.
  - **R-Phase C.2** — `TranscriptionSource.parse` accepting unexpected
    values. Mitigation: add a `MacrecError.transcriptionInvalidProvider`
    sibling case `transcriptionInvalidSource(raw:registered:)` mapped to
    exit 64. Test it.
  - **R-Phase C.3** — Default `MACREC_TRANSCRIBE_MODEL` violating the
    no-fallback rule. **Resolution**: the model id default is recorded
    in source code as a `TranscriptionProviderId`-level constant, NOT
    resolved through `value(_:)`. The user can override via env var; the
    env var default is `nil` (means "use the provider's pinned default").
    Documented in §0.3 of this plan and in the configuration guide.

---

### Phase D — Sidecar persistence (`TranscriptSidecarWriter`)

- **Goal**: Implement the four sidecar formats (`jsonl`, `txt`, `srt`,
  `vtt`) with deterministic naming for single-segment, `partNN`, and
  `--layout split` cases. Wire the writer as a `TranscriptEvent`
  consumer in the driver. Sidecars rotate alongside audio segments.

- **Files to create** (under `Sources/MacrecCore/Transcription/`):
  - `TranscriptSidecarWriter.swift` — `actor TranscriptSidecarWriter`:
    - `init(audioOutputURL: URL, format: TranscriptFormat, headerMetadata: TranscriptHeader)`
      — derives the sidecar URL from the audio URL using
      `TranscriptSidecarNamer` (below).
    - `consume(_ event: TranscriptEvent) async` — appends per the
      format:
      - `jsonl`: one JSON object per event. Header is the first line
        (re-written on every flush — open-truncate-write because jsonl
        permits a single header line at the top per `macrec.transcript.v1`
        schema).
      - `txt`: writes only `final` events' text, newline-separated.
      - `srt` / `vtt`: buffers finals in memory until close; writes the
        whole file on `finalize()`.
    - `finalize() async throws` — flushes the in-memory buffers; closes
      the file handle.
    - `metricsSnapshot() -> TranscriptHeader` — returns current
      `secondsStreamed`, `partialCount`, `finalCount`, `droppedFrames`
      for inclusion in the header (FR-58).
  - `TranscriptSidecarNamer.swift` — pure helper:
    - `sidecarURL(forAudio audioURL: URL, layoutSourceTag: SourceTag?, format: TranscriptFormat) -> URL`.
    - For audio path `recording-2026-04-26.m4a`, returns
      `recording-2026-04-26.transcript.jsonl`.
    - For audio path `recording-2026-04-26.part01.m4a`, returns
      `recording-2026-04-26.part01.transcript.jsonl`.
    - For `--layout split` with `transcribeSource == .both`, takes a
      `layoutSourceTag` arg and returns
      `recording-2026-04-26.mic.transcript.jsonl` /
      `recording-2026-04-26.system.transcript.jsonl`.
    - Verbatim FR-51 rules.
  - `TranscriptHeader.swift` — `Codable Sendable struct`:
    `schema: String` (constant `"macrec.transcript.v1"`),
    `provider: String`, `model: String`,
    `audioPath: String`, `startedAt: String` (ISO-8601),
    `endedAt: String?`, `secondsStreamed: Double`,
    `partialCount: Int`, `finalCount: Int`, `droppedFrames: Int`.
  - `TranscriptSink.swift` — protocol abstracting sidecar consumption
    so tests can substitute an in-memory sink:
    ```swift
    public protocol TranscriptSink: Sendable {
        func consume(_ event: TranscriptEvent) async
        func finalize() async throws
    }
    ```
    `TranscriptSidecarWriter` conforms; the in-memory test fake also
    conforms.

- **Files to modify**:
  - `Sources/MacrecCore/Transcription/TranscriptionDriver.swift`:
    - Wire the sink: every `TranscriptEvent` received from the provider
      is forwarded to `transcriptSink.consume(event)` (await),
      `eventContinuation.yield(event)` (re-emit to UI), and metrics are
      updated.
    - On `stop(drainTimeout:)`, await `transcriptSink.finalize()` after
      draining.
  - `Sources/MacrecCore/RecordingSession.swift`:
    - In `split(nextOutput:)`, after the recorder swap, call
      `await transcriptionDriver?.rotateSidecar(toAudioURL: nextOutput)`.
      That method on the driver finalizes the current sidecar and opens
      a new one with the next path.
  - `Sources/MacrecUIKit/SessionCoordinator.swift`:
    - In the segment-completion hook (line ~266 / ~294), the coordinator
      already finalizes one segment and opens the next. Add a call to
      the driver's `rotateSidecar(toAudioURL:)` so the sidecar aligns
      with the new segment's path.

- **Test files to create** (under `Tests/MacrecCoreTests/Transcription/`):
  - `TranscriptSidecarNamerTests.swift` — exhaustive cases:
    - Single segment, mixed: `recording.m4a` → `recording.transcript.jsonl`.
    - Multi-segment: `recording.part01.m4a` → `recording.part01.transcript.jsonl`.
    - Split layout, source = `both`: writes two sidecars.
    - Split layout, source = `mixed` / `system` / `mic`: writes one
      sidecar.
    - Format selection: `txt` extension, `srt` extension, `vtt`
      extension all materialize correctly.
  - `TranscriptSidecarWriterTests.swift`:
    - jsonl: feed 3 partials + 1 final; assert the file has 5 lines (1
      header + 3 partials + 1 final), each parses as JSON.
    - jsonl: header is rewritten on flush (open-truncate semantics).
      After 3 finals, header.finalCount == 3.
    - txt: feed 5 partials + 2 finals; assert the file contains exactly
      2 lines of text (only finals).
    - srt: feed 2 finals with different `startedAt` / `endedAt`
      timestamps; assert the file validates against an SRT grammar
      (sequence number, timestamp range, blank line separator).
    - vtt: same as srt but with `WEBVTT` header and `.` decimal
      separator.
  - `TranscriptionDriverWithSinkTests.swift` — drives the driver +
    `FakeTranscriptionProvider` + an in-memory sink; asserts every event
    is forwarded.

- **Dependencies**: Phase A (`TranscriptEvent`, `TranscriptFormat`),
  Phase C (`RecordingOptions.transcriptionFormat` selection).

- **Parallelizable units within the phase**:
  - Unit P-D1: `TranscriptHeader.swift` + `TranscriptSink.swift`. One
    coder.
  - Unit P-D2: `TranscriptSidecarNamer.swift` + its test. Independent;
    one coder.
  - Unit P-D3: `TranscriptSidecarWriter.swift` + its test. Depends on
    P-D1; one coder.
  - Unit P-D4: `TranscriptionDriver` wiring + `RecordingSession` /
    `SessionCoordinator` rotation hooks. Depends on P-D3; one coder.

- **Acceptance criteria**:
  - **AC-LT-5** (sidecar naming follows segmentation): asserted by
    `TranscriptSidecarNamerTests`.
  - **AC-LT-6** (sidecar formats are valid): asserted by
    `TranscriptSidecarWriterTests` (jsonl line-by-line JSON parse;
    SRT/VTT grammar regex; txt finals-only).
  - **AC-LT-13** (clean shutdown drains finals): asserted by
    `TranscriptionDriverWithSinkTests` — issues a stop with a
    pending-partial and a 5 s drain budget; verifies the sidecar's last
    line is the corresponding final (or the partial promoted to a
    final-with-`{drained:true}` flag).
  - **AC-LT-14** (cost metrics emitted): asserted in the same suite —
    after stop, the header line contains correct counts.
  - **AC-LT-20** (transcript panel survives Pause/Resume across
    segments): partial credit — the segment rotation hook is wired here;
    the UI panel rendering happens in Phase G.

- **Verification command**:
  - `swift build` exits 0.
  - `swift test --filter TranscriptSidecar` exits 0 (matches both
    namer and writer tests).
  - `swift test --filter TranscriptionDriverWithSinkTests` exits 0.

- **Risks + mitigation**:
  - **R-Phase D.1** — File-handle ownership across `rotateSidecar`.
    Mitigation: the writer is an actor; `rotateSidecar` is a method that
    finalizes the old handle and opens the new one **inside the actor**
    — no leaked handles.
  - **R-Phase D.2** — JSONL header rewrite races with append writes.
    Mitigation: the writer uses a single `FileHandle` opened in `r+w`
    mode; header rewrite uses `seek(toOffset: 0)` + `write` of the
    encoded header padded to a fixed 512-byte boundary (so subsequent
    appends don't need to recompute offsets). Documented in code.
  - **R-Phase D.3** — `srt` / `vtt` formatting bugs (off-by-one on
    seconds, wrong decimal separator). Mitigation: golden-file fixtures
    in the test suite (`Tests/MacrecCoreTests/Fixtures/expected.srt`,
    `expected.vtt`) — exact-string match.

---

### Phase E — `WebSocketSession` actor + `WebSocketTransport` protocol

- **Goal**: Land the reusable `WebSocketSession` actor and the
  `WebSocketTransport` protocol used by every future provider. Phase E
  is **provider-agnostic** — it knows nothing about Gemini's JSON
  schema. Phase F bolts the schema on top.

- **Files to create** (under `Sources/MacrecCore/Transcription/`):
  - `WebSocketTransport.swift` — protocol verbatim from
    `docs/research/websocket-asyncstream-pattern.md` §3 (and §10's
    full source).
  - `LiveWebSocketTransport.swift` — `final class LiveWebSocketTransport: WebSocketTransport, @unchecked Sendable`
    — verbatim from research §10.
  - `WebSocketSession.swift` — `actor WebSocketSession` — verbatim
    from research §10. Exposes `events: AsyncStream<ServerEvent>`,
    `start()`, `send(_:)`, `cancel()`. Embeds the
    `runConnectionLoop` + `runReceiveLoop` + `runHeartbeat` +
    `NWPathMonitor` integration.
  - `WebSocketSessionTypes.swift` — `ServerEvent`,
    `WebSocketConnectionState`, `WebSocketSessionError` enums (per
    research §"Public Types"). **Sets `maxAttempts = 8`** per ESC-LT-2
    recommendation.

- **Test files to create** (under `Tests/MacrecCoreTests/Transcription/`):
  - `WebSocketSessionTests.swift` — verbatim from research §11
    (Testing Strategy → Complete XCTest Example), adapted to Swift
    Testing's `@Suite` / `@Test`. Includes:
    - `connect → receive → cancel`.
    - `connect → disconnect (transient) → reconnect → cancel`.
    - `fatal auth error → state moves to .paused, stream stays open`.
    - `consumer cancellation tears down actor`.
  - `FakeWebSocketTransportTests.swift` — sanity test for the fake
    transport itself (so the testing infra is itself tested).

- **Dependencies**: none (independent of Phase A — the `WebSocketSession`
  and `TranscriptionProvider` protocols are decoupled). **Phase E can
  run in parallel with Phase A.**

- **Parallelizable units within the phase**:
  - Unit P-E1: types + `WebSocketTransport` protocol + `LiveWebSocketTransport`.
    One coder.
  - Unit P-E2: `WebSocketSession` actor + tests. Depends on P-E1; one
    coder.

- **Acceptance criteria**:
  - **AC-LT-10** (reconnect on transient failure): partial credit;
    `WebSocketSessionTests.testReconnectionOnTransientError` asserts the
    state machine's reconnect path. Full integration credit happens in
    Phase F.

- **Verification command**:
  - `swift build` exits 0.
  - `swift test --filter WebSocketSessionTests` exits 0.

- **Risks + mitigation**:
  - **R-Phase E.1** — `URLSessionWebSocketTask` thread-safety with
    Swift 6 strict concurrency. Mitigation: `LiveWebSocketTransport`
    uses `@unchecked Sendable` with a documented justification (the
    underlying `URLSessionWebSocketTask` is thread-safe per Foundation
    docs; the actor's isolation prevents concurrent access from inside
    `WebSocketSession`). Reviewed by Phase 7.
  - **R-Phase E.2** — `sendPing` double-resume crash. Mitigation: the
    research-doc implementation uses fire-and-forget semantics (no
    continuation bridge). The receive loop detects disconnects on its
    own; the heartbeat does NOT trigger reconnection.
  - **R-Phase E.3** — `URLProtocol`-based WebSocket testing doesn't
    work. Mitigation: tests use `FakeWebSocketTransport` injected via
    `transportFactory` parameter (research §11). No `URLProtocol`.
  - **R-Phase E.4** — `NWPathMonitor` queue-thread interaction with the
    actor. Mitigation: the path monitor's `pathUpdateHandler` only yields
    into a `Sendable` `AsyncStream<NWPath>`; the actor consumes that
    stream in a `for await` loop on its own executor. No cross-thread
    method calls.

---

### Phase F — `GeminiLiveTranscriptionProvider`

- **Goal**: Implement the first concrete provider on top of
  `WebSocketSession`. Wire the JSON schema from
  `docs/research/gemini-live-wire-schema.md` §10 (Codable types) and the
  step-by-step flow from §11 (annotated Swift snippet). Critically,
  adopt the **`responseModalities: ["AUDIO"]` workaround** with audio
  byte discard on the receive path.

- **Files to create** (under `Sources/MacrecCore/Transcription/`):
  - `GeminiLiveTypes.swift` — verbatim copy of the Codable types from
    research §10 (`GeminiClientMessage`, `BidiGenerateContentSetup`,
    `GeminiLiveGenerationConfig`, `ThinkingConfig`,
    `GeminiContent`, `GeminiPart`, `GeminiBlob`,
    `AudioTranscriptionConfig`, `RealtimeInputConfig`,
    `AutomaticActivityDetection`, `ContextWindowCompressionConfig`,
    `SlidingWindowConfig`, `SessionResumptionConfig`,
    `BidiGenerateContentRealtimeInput`, `ActivitySignal`,
    `BidiGenerateContentClientContent`, `BidiGenerateContentToolResponse`,
    `FunctionResponse`, `GeminiServerMessage`,
    `BidiGenerateContentSetupComplete`,
    `BidiGenerateContentServerContent`, `GeminiContentReceived`,
    `GeminiPartReceived`, `BidiGenerateContentTranscription`,
    `BidiGenerateContentToolCall`, `FunctionCall`,
    `BidiGenerateContentToolCallCancellation`, `GoAway`,
    `SessionResumptionUpdate`, `UsageMetadata`, `ModalityTokenCount`,
    `AnyCodable`).
  - `GeminiLiveTranscriptionProvider.swift` — `final class
    GeminiLiveTranscriptionProvider: TranscriptionProvider`:
    - `providerId == "gemini-live"`, `displayName == "Gemini Live"`,
      `requiredApiKey == "GOOGLE_API_KEY"`,
      `requiredAudioFormat == .pcm16le16k1ch`.
    - `init(apiKey: String, modelId: String = "gemini-3.1-flash-live-preview", webSocketSessionFactory: ...)`.
    - `run(audio:options:)`:
      1. Open `WebSocketSession` to the wss URL with the API key in
         the query parameter.
      2. Send the setup message
         (`responseModalities: ["AUDIO"]` + `inputAudioTranscription:
         {}` + system instruction "transcribe verbatim, do not respond"
         + `contextWindowCompression: { slidingWindow: {} }` +
         `sessionResumption: {}`).
      3. Wait for `setupComplete` on the receive stream.
      4. Spawn a **send task**: `for await chunk in audio` → split each
         100 ms chunk into ~3 × 30 ms chunks → base64-encode → wrap
         in `BidiGenerateContentRealtimeInput.audio` → send via the
         session.
      5. Spawn a **receive task**: for each `serverContent` event,
         maintain `pendingFragments: [String]`. On
         `inputTranscription.text`, append to fragments and emit
         `TranscriptEvent.partial(text:source:hostTime:)`. On
         `turnComplete: true || generationComplete: true`, concatenate
         pending fragments, emit `TranscriptEvent.final(...)`, clear
         buffer. **Discard `modelTurn.parts[].inlineData`** (the
         AUDIO-modality bytes; research §13).
      6. On `goAway`, proactively close the session and let the
         WebSocket-level reconnection handle the resume (a new session
         opens; setup is re-sent with the stored
         `sessionResumption.handle`).
      7. On session-level error (state moves to `.paused`), emit
         `TranscriptEvent.error(reason: ..., isFatal: false)` and let
         the recording continue.
      8. On consumer cancellation (the audio stream's continuation
         finishes), send a graceful close frame
         (`URLSessionWebSocketTask.CloseCode.normalClosure`).
  - `GeminiLiveProviderRegistry.swift` — small factory used by
    `RecordingSession` to instantiate the provider from
    `RecordingOptions`:
    ```swift
    public enum TranscriptionProviderFactory {
        public static func make(_ options: TranscriptionOptions) -> any TranscriptionProvider {
            switch options.provider {
            case .none: return NoOpTranscriptionProvider()
            case .geminiLive:
                guard let key = options.apiKey else {
                    return NoOpTranscriptionProvider()  // unreachable — resolver throws
                }
                return GeminiLiveTranscriptionProvider(
                    apiKey: key,
                    modelId: options.modelId ?? "gemini-3.1-flash-live-preview"
                )
            // future providers added here
            }
        }
    }
    ```

- **Files to modify**:
  - `Sources/MacrecCore/RecordingSession.swift` — in the `init` /
    `start` path, when `options.transcriptionProvider != .none` and no
    explicit provider was injected (test path), call
    `TranscriptionProviderFactory.make(...)` to materialize the live
    provider.

- **Test files to create** (under `Tests/MacrecCoreTests/Transcription/`):
  - `GeminiLiveTypesEncodingTests.swift` — verifies the JSON encoding of
    each Codable type matches the wire-format examples in the research
    doc (§3, §4, §5). Uses **golden strings** — exact match.
  - `GeminiLiveProviderTests.swift` — instantiates the provider with an
    **injected** `WebSocketSessionFactory` that returns a mocked session
    whose `events` stream emits scripted server messages:
    - Inject `setupComplete` → assert provider transitions to "sending
      audio" state.
    - Inject `serverContent.inputTranscription.text = "hello"` →
      assert `TranscriptEvent.partial("hello")` is emitted.
    - Inject `serverContent.turnComplete = true` → assert
      `TranscriptEvent.final("hello")` is emitted.
    - Inject a sequence with `inputTranscription.text` and
      `modelTurn.parts[].inlineData` (audio) → assert the audio bytes
      are NOT in any emitted event (discard verification).
    - Inject `goAway` with `timeLeft: "120s"` → assert the provider
      requests a graceful reconnect.
  - `GeminiLiveLiveSmokeTest.swift` — **gated on `GOOGLE_API_KEY`
    environment variable**. Skipped cleanly when absent. When present:
    - Opens a real session with a 5 s synthetic audio fixture (1 kHz
      sine + simulated speech burst from `SyntheticAudioFixture`).
    - Asserts at least one `TranscriptEvent.final` arrives within 15 s.
    - Asserts the session closes cleanly on cancel.
    Marked `@Suite(.disabled(if: ProcessInfo.processInfo.environment["GOOGLE_API_KEY"] == nil))`.

- **Dependencies**: Phase A (provider protocol), Phase E
  (`WebSocketSession`).

- **Parallelizable units within the phase**:
  - Unit P-F1: `GeminiLiveTypes.swift` + `GeminiLiveTypesEncodingTests.swift`.
    Verbatim drop-in; one coder.
  - Unit P-F2: `GeminiLiveTranscriptionProvider.swift` + its protocol
    test (mocked session). Depends on P-F1; one coder.
  - Unit P-F3: `GeminiLiveProviderRegistry.swift` + factory wiring in
    `RecordingSession`. Depends on P-F2; one coder.
  - Unit P-F4: `GeminiLiveLiveSmokeTest.swift`. Independent of P-F3
    (lives in tests). One coder.

- **Acceptance criteria**:
  - **AC-LT-10** (reconnect on transient failure): full credit via
    `GeminiLiveProviderTests` injecting a `goAway` event.
  - End-to-end gate criteria fall to Phase I (manual smoke test).

- **Verification command**:
  - `swift build` exits 0.
  - `swift test --filter GeminiLive` exits 0 (matches the unit + types
    tests; smoke test skipped without API key).
  - With `GOOGLE_API_KEY=...`, `swift test --filter GeminiLiveLiveSmokeTest`
    exits 0 within ~30 s.

- **Risks + mitigation**:
  - **R-Phase F.1** — `responseModalities: ["TEXT"]` accidentally
    sneaks in (e.g., copied from refined-request-text into the
    setup-message constructor). Mitigation: a unit test in
    `GeminiLiveTypesEncodingTests` explicitly asserts the encoded JSON
    contains `"responseModalities":["AUDIO"]` and **does not** contain
    `"TEXT"`.
  - **R-Phase F.2** — `inputAudioTranscription` reliability on
    `gemini-3.1-flash-live-preview` (ESC-LT-1). Mitigation: the smoke
    test in Phase I is the empirical gate. If the smoke test fails to
    produce a final within 30 s for a 5 s speech-like burst, escalate to
    the user with the documented fallback (switch to
    `gemini-live-2.5-flash-native-audio` — same wire protocol, only the
    string changes).
  - **R-Phase F.3** — API key leaking into logs via the URL.
    Mitigation: extend `LoggerFactory` with a `redact(_:)` helper that
    strips the `key` query parameter; route every URL log through it.
    Reviewed by Phase 7.
  - **R-Phase F.4** — Audio chunk fragmentation (1 chunk of 100 ms vs
    3 chunks of ~30 ms). Mitigation: the provider performs the split
    internally; tests assert the bytes match (concat of three 30 ms
    chunks == one 100 ms chunk; sum of base64 sizes == base64 of
    100 ms PCM).
  - **R-Phase F.5** — Setup message ordering. Audio sent before
    `setupComplete` is undefined behavior (silent drop or 1007 close).
    Mitigation: provider blocks on `await receiveSetupComplete()` before
    spawning the send task. Test asserts no audio is sent before the
    setup-complete event arrives in the mock.

---

### Phase G — `macrec-ui` integration

- **Goal**: Surface the transcription feature in the menu-bar UI.
  Add the picker, source picker, transcript panel, privacy disclosure,
  missing-key affordance, and per-recording cost metric. The UI drives
  `TranscriptionDriver` in-process via `RecordingController`.

- **Files to create** (under `Sources/macrec-ui/Views/`):
  - `TranscriptionPicker.swift` — mirror of `FormatPicker.swift`
    (codebase scan §4.3). `@AppStorage("com.macrec.ui.transcribeProvider")`.
    Picker entries: `None` (default), `Gemini Live`. Disabled while
    `recordingController.state` is not in `{.idle, .stopped, .failed}`.
    Renders a red-dot `TranscriptionMissingKeyBadge` when the selected
    provider's API key is not resolved.
  - `TranscriptionSourcePicker.swift` — `@AppStorage("com.macrec.ui.transcribeSource")`.
    Picker entries: `system`, `mic`, `mixed` (default), `both`.
    Disabled while recording.
  - `TranscriptFormatPicker.swift` — `@AppStorage("com.macrec.ui.transcriptFormat")`.
    Picker entries: `jsonl` (default), `txt`, `srt`, `vtt`. Disabled
    while recording.
  - `TranscriptionMissingKeyBadge.swift` — small SwiftUI view: red dot
    + tooltip text "Set GOOGLE_API_KEY in `~/.tool-agents/macrec-ui/.env`".
    On click, opens a popover with the env-var name, the .env path, and
    a "Copy path" button.
  - `TranscriptPanel.swift` — `ScrollView`-based view. Reads
    `recordingController.transcriptEvents: [TranscriptEvent]`. Layout:
    - Each `final` event renders as a normal-style line.
    - The current pending `partial` (if any) renders as a muted-color
      line at the bottom (replaced in-place when a new partial arrives;
      cleared when promoted to a final).
    - Auto-scrolls to the bottom unless the user has scrolled up; in
      that case, a "Jump to live" button appears in the bottom-right.
    - Fixed max-height ~120 pt; the popover stays self-contained.
  - `TranscriptionPrivacyAlert.swift` — `.alert(...)` modifier triggered
    by `@AppStorage("com.macrec.ui.transcribePrivacyAccepted") == false`
    AND user picks a non-`None` provider. Body: "the audio captured
    during this recording will be sent to a third-party API
    (`<provider name>`) for transcription." Two buttons: "Cancel" (sets
    picker back to `None`), "Continue" (sets accepted-flag to `true`,
    dismisses). A "Don't show again" checkbox is implicit — once
    accepted, the alert never re-fires.

- **Files to modify**:
  - `Sources/macrec-ui/RootView.swift`:
    - Add the three new pickers in the popover form (between the
      microphone picker and the level meters), wrapped in a collapsible
      "Live transcription" disclosure group.
    - Add the `TranscriptPanel` below the level meters, fixed
      max-height 120 pt.
    - Wire the privacy alert via `.alert(...)` modifier.
  - `Sources/MacrecUIKit/RecordingController.swift`:
    - Add `@MainActor`-isolated observed properties:
      - `transcriptEvents: [TranscriptEvent]` — capped at 1000 entries
        (drop oldest); rebuilt on each `final` arrival.
      - `currentPartial: String?` — the active in-flight partial.
      - `transcriptionState: TranscriptionState` — `.idle | .active |
        .paused | .error(message)`.
      - `transcriptionMissingKey: Bool` — driven by
        `RecordingOptions.transcriptionApiKey == nil` AND
        `transcriptionProvider != .none`.
      - `transcriptionMetrics: TranscriptHeader?` — populated on stop
        for the post-stop disclosure (FR-58).
    - In `start(options:)`, if `options.transcriptionProvider !=
      .none`, open a `for await event in transcriptionDriver.events`
      task; on `.partial`, set `currentPartial`; on `.final`, clear
      `currentPartial` and append to `transcriptEvents`; on `.error`,
      set `transcriptionState = .error(...)`.
    - In `requestStop()`, await the driver's metrics snapshot and set
      `transcriptionMetrics`.
  - `Sources/MacrecUIKit/SessionCoordinator.swift`:
    - On segment-completion, append a separator-marker event to
      `transcriptEvents` (e.g., a `final` with text
      `"--- part NN ---"`) so the UI panel can render the `partNN`
      transition (per AC-LT-20).
  - `Sources/macrec-ui/Views/SavedToDisclosure.swift`:
    - Extend the post-stop disclosure to list each transcript sidecar
      path alongside the audio path. Use the URL-array from the
      `TranscriptionDriver` finalized state.

- **Test files to create** (under `Tests/MacrecUITests/`):
  - `TranscriptionPickerTests.swift` — drives the controller through
    UI-state transitions; asserts picker is disabled while recording.
  - `TranscriptionMissingKeyBadgeTests.swift` — drives
    `transcriptionMissingKey == true`; asserts badge is visible.
  - `TranscriptPanelTests.swift` — feeds a script of 3 partials + 1
    final + 2 partials + 1 final; asserts the panel shows 2 finalized
    lines + the latest partial.
  - `TranscriptionPrivacyAlertTests.swift` — asserts alert fires
    once per `transcribePrivacyAccepted` flip-flop; "Cancel" resets
    picker; "Continue" sets accepted flag.
  - `RecordingControllerTranscriptionTests.swift` — drives the full
    lifecycle with `FakeTranscriptionProvider`; asserts the
    `transcriptionMetrics` is populated on stop.

- **Dependencies**: Phase D (sidecar wiring), Phase F (real provider) —
  but **most of Phase G can start once Phase A merges** because the UI
  drives `FakeTranscriptionProvider` until the real provider lands.

- **Parallelizable units within the phase**:
  - Unit P-G1: Three picker views + `TranscriptionMissingKeyBadge`.
    Independent file edits; one coder per picker (4 coders).
  - Unit P-G2: `TranscriptPanel.swift`. Independent; one coder.
  - Unit P-G3: `TranscriptionPrivacyAlert.swift` + `RootView` wiring.
    Depends on P-G1 (picker exists). One coder.
  - Unit P-G4: `RecordingController` extensions + `SessionCoordinator`
    extensions. Depends on P-G2 (panel reads the controller's state).
    One coder.
  - Unit P-G5: `SavedToDisclosure.swift` extension. Depends on P-G4.
    One coder.

- **Acceptance criteria**:
  - **AC-LT-7** (live UI panel shows partials, then commits finals):
    asserted by `TranscriptPanelTests`.
  - **AC-LT-8** (UI surfaces missing-key state): asserted by
    `TranscriptionMissingKeyBadgeTests`.
  - **AC-LT-9** (privacy disclosure shown on first opt-in): asserted by
    `TranscriptionPrivacyAlertTests`.
  - **AC-LT-12** (source selection routes correctly): full credit;
    Phase B had partial. Asserted by `RecordingControllerTranscriptionTests`.
  - **AC-LT-14** (cost metrics emitted): full credit (sidecar header is
    Phase D; UI surfaces it in the post-stop disclosure here).
  - **AC-LT-18** (live transcription picker present in popover):
    asserted by `TranscriptionPickerTests`.
  - **AC-LT-19** (picker disabled while recording): asserted by the
    same suite.
  - **AC-LT-20** (transcript panel survives Pause/Resume across
    segments): full credit; the segment-marker event from
    `SessionCoordinator` is the visual separator.

- **Verification command**:
  - `swift build` exits 0.
  - `swift test --filter TranscriptionPickerTests` exits 0.
  - `swift test --filter TranscriptPanelTests` exits 0.
  - `swift test --filter TranscriptionPrivacyAlertTests` exits 0.
  - Manual smoke: launch `macrec-ui`, open the popover, verify the
    pickers + panel + badge + privacy alert behave per spec.

- **Risks + mitigation**:
  - **R-Phase G.1** — `@AppStorage` defaults race vs. the privacy alert
    (alert fires before AppStorage initializes). Mitigation: read the
    flag in `RootView.onAppear`; defer alert presentation by one
    runloop turn.
  - **R-Phase G.2** — `transcriptEvents` array growing unbounded for
    multi-hour recordings. Mitigation: cap at 1000 entries; oldest are
    dropped (the sidecar file remains the persistent record). UI panel
    only renders the last 100 anyway.
  - **R-Phase G.3** — Popover pixel-cramped with three new pickers + a
    transcript panel. Mitigation: collapse the three pickers under a
    "Live transcription" disclosure group; default-collapsed when
    `provider == .none`. Phase G's coder uses the existing
    `DisclosureGroup` SwiftUI primitive.

---

### Phase H — Documentation

- **Goal**: Update the public-facing documentation to reflect the new
  feature. All updates are mechanical at this point — the behavior is
  locked by Phases A-G.

- **Files to modify**:
  - `docs/tools/macrec.md`:
    - Add five new flags to the `<command>` and `<info>` blocks per
      the `<toolName>` XML format.
    - Add a "Sidecar naming" table showing single-segment, multi-segment,
      split-layout cases.
    - Add a worked example: `macrec start --transcribe gemini-live
      --transcribe-source mixed --output ~/Recordings/talk.m4a`.
    - Document the 15-min context limit / 10-min connection limit
      mitigation (`contextWindowCompression` + `sessionResumption`).
    - Document the new exit codes (78 for missing key, 64 for
      `--detach --transcribe`, 64 for invalid provider name).
  - `docs/tools/macrec-ui.md`:
    - Document the three new pickers, the panel, the privacy alert,
      the missing-key badge.
    - Add a screenshot description of the popover with transcription
      enabled.
    - Reference the same exit-code documentation as `macrec.md`.
  - `docs/design/configuration-guide.md`:
    - Add §2.16 `MACREC_TRANSCRIBE_PROVIDER` — purpose, allowed values
      (`none`, `gemini-live`), default (`none`), recommended storage
      (CLI: `~/.tool-agents/macrec/.env`; UI: `~/.tool-agents/macrec-ui/.env`),
      no expiration.
    - Add §2.17 `MACREC_TRANSCRIBE_SOURCE`, §2.18 `MACREC_TRANSCRIPT_FORMAT`,
      §2.19 `MACREC_TRANSCRIPT_OUTPUT`, §2.20 `MACREC_TRANSCRIBE_MODEL`.
    - Add §2.21 `GOOGLE_API_KEY` — purpose, how to obtain
      (aistudio.google.com), recommended storage (`~/.tool-agents/macrec/.env`
      mode 0600), expiration handling (paired with
      `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`).
    - Add §2.22 `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` — ISO-8601 date for
      proactive expiration warning per CLAUDE.md configuration-guide
      rule.
  - `docs/design/project-design.md`:
    - Add §1.4 "Transcription Architecture" component diagram showing:
      `HostClockAligner.onAlignedFrame` → `TranscriptionDriver`
      (downsampler + bounded queue) → `TranscriptionProvider` → events
      fan-out to (a) `TranscriptSink` → sidecar files, (b) UI's
      `RecordingController.transcriptEvents`.
    - Add §2.13 "TranscriptionProvider + TranscriptionDriver" interface
      reference (verbatim from this plan §4 Phase A's protocol shape).
    - Add §3.5 "TranscriptEvent" data shape.
    - Add §4.6 sequence diagram "Live transcription, normal stop".
    - Add §4.7 sequence diagram "Live transcription, transient
      reconnect".
    - Update §9.5 exit-code table with the new codes.
  - `docs/design/project-functions.md` — final pass: verify every FR
    that started in `PLANNED` is now `IMPLEMENTED` (per the convention).
    Update phase mapping per the as-shipped Phase letters.
  - `Issues - Pending Items.md` — final pass: register R-26..R-30 as
    resolved or as residual v2 items per their actual state. Add
    explicit v2 follow-ups: detach-mode transcription, separate
    transcript window, on-device provider, OpenAI Realtime as second
    provider, Deepgram as third provider, AssemblyAI as fourth provider.

- **Files NOT touched**:
  - `CLAUDE.md` "Tools" section — entries are unchanged (transcription
    is a feature of the existing tools, not a new tool, per
    refined-request §Process). Verify the entries still resolve.

- **Dependencies**: Phase G (UI behavior fully locked).

- **Parallelizable units within the phase**:
  - Unit P-H1: `docs/tools/macrec.md` updates. Independent; one coder.
  - Unit P-H2: `docs/tools/macrec-ui.md` updates. Independent; one
    coder.
  - Unit P-H3: `docs/design/configuration-guide.md` updates.
    Independent; one coder.
  - Unit P-H4: `docs/design/project-design.md` updates. Independent;
    one coder.
  - Unit P-H5: `docs/design/project-functions.md` status flip + Issues
    updates. Independent; one coder.

- **Acceptance criteria**:
  - **AC-LT-21** (`docs/tools/macrec.md` updated).
  - **AC-LT-22** (`docs/tools/macrec-ui.md` updated).
  - **AC-LT-23** (`docs/design/configuration-guide.md` updated).
  - **AC-LT-24** (`docs/design/project-functions.md` updated): full
    credit (Phase 0 had partial).
  - **AC-LT-25** (`Issues - Pending Items.md` updated): full credit.

- **Verification command**:
  - `grep -c '^### 2\.[0-9]' docs/design/configuration-guide.md` returns
    the expected count after the seven new entries.
  - `/tool-conventions audit macrec` passes.
  - `/tool-conventions audit macrec-ui` passes.

- **Risks + mitigation**:
  - **R-Phase H.1** — Documentation drifting from the as-built behavior
    (typical doc-rot). Mitigation: Phase H runs **after** Phase G is
    functionally complete and Phase 7 (Code Review) has signed off; the
    behavior is not subject to change during doc updates.

---

### Phase I — End-to-end smoke test against a real Gemini API key

- **Goal**: Manual user-driven verification that the integrated build
  works against the live Gemini Live API. Cannot be automated because
  it requires a real API key, network, and microphone speech.

- **Manual checklist** (run by the user, in order):
  1. **API key obtained**: Visit
     <https://aistudio.google.com/app/apikey>; create a key; export it:
     `export GOOGLE_API_KEY=...`.
  2. **CLI dry-run, None (regression)**:
     `swift run macrec start --output /tmp/test-none.m4a --max-duration 10`.
     Speak into the mic for 10 s. Verify: `/tmp/test-none.m4a` exists
     and plays; no `*.transcript.*` file is created (AC-LT-1).
  3. **CLI dry-run, Gemini Live with no key**:
     `unset GOOGLE_API_KEY; swift run macrec start --output /tmp/test.m4a --transcribe gemini-live`.
     Verify: exits 78 immediately, no audio file created (AC-LT-4).
  4. **CLI happy path, Gemini Live with key**:
     `export GOOGLE_API_KEY=...; swift run macrec start --output /tmp/test.m4a --transcribe gemini-live --max-duration 30`.
     Speak a known phrase ("the quick brown fox jumps over the lazy
     dog") slowly. Verify:
     - `/tmp/test.m4a` exists, plays, contains the spoken audio.
     - `/tmp/test.transcript.jsonl` exists, parses line-by-line as JSON.
     - At least one `final` event in the jsonl with text approximating
       the spoken phrase (allow 5-10 % word-error rate).
     - The header line at the top has correct counts.
   5. **CLI segment rotation**: Same as 4, but at the 15 s mark, send
      `kill -SIGUSR1 $(cat ~/.tool-agents/macrec/macrec.pid)` (or use
      the UI's manual split). Verify two audio files
      (`test.part01.m4a`, `test.part02.m4a`) and two transcript
      sidecars (`test.part01.transcript.jsonl`,
      `test.part02.transcript.jsonl`).
   6. **UI happy path**: Launch `macrec-ui`. Open the popover. Pick
      `Gemini Live` from the transcription picker. Verify the privacy
      disclosure fires; click Continue. Click Start. Speak. Verify the
      transcript panel shows partials (muted) and finals (committed)
      within ~2.5 s (NFR-18). Click Stop. Verify the post-stop
      disclosure lists both the audio file and the transcript sidecar.
   7. **UI Pause/Resume**: Same as 6, but click Pause at 10 s, speak
      silently, click Resume, speak more, Stop. Verify two segments.
   8. **UI Missing key**: In `~/.tool-agents/macrec-ui/.env`, comment
      out `GOOGLE_API_KEY`. Restart `macrec-ui`. Pick `Gemini Live`.
      Verify the red-dot badge on the picker. Click the badge —
      verify the help popover names the env var.
   9. **Long-session reconnect**: Run `macrec start --transcribe
      gemini-live --max-duration 1200` (20 minutes). Speak periodically.
      Verify the recording completes, the transcript jsonl spans the
      entire 20 minutes, and the post-stop log line reports
      reconnection counts (≥ 1, since the connection limit is ~10 min).
   10. **Network drop simulation**: Run `macrec start --transcribe
       gemini-live --max-duration 60`. Speak. At 20 s, disable Wi-Fi for
       10 s, then re-enable. Verify the recording continues unaffected;
       the transcript jsonl shows a brief gap; a non-fatal error event
       is logged; finals resume after reconnect (AC-LT-10).

- **Files to create**:
  - `test_scripts/e2e-transcription.sh` — automates steps 2-5 of the
    above for `GOOGLE_API_KEY`-equipped CI runs (skipped cleanly when
    the key is absent).
  - `test_scripts/e2e-transcription-noop.sh` — automates steps 1-2
    (None / regression). Runs unconditionally.

- **Dependencies**: Phase H (docs published).

- **Parallelizable units within the phase**: none — sequential manual
  checklist.

- **Acceptance criteria**:
  - All ten manual checklist items pass.
  - The user explicitly signs off (a one-line checkbox in
    `Issues - Pending Items.md` flips from open to closed).

- **Verification command**:
  - `bash test_scripts/e2e-transcription-noop.sh` exits 0
    (regression; no key required).
  - `GOOGLE_API_KEY=... bash test_scripts/e2e-transcription.sh` exits 0.

- **Risks + mitigation**:
  - **R-Phase I.1** — `inputAudioTranscription` empirically unreliable
    on Gemini 3.1 Flash Live (ESC-LT-1). Mitigation: if step 4 fails
    (no `final` event arrives within 30 s), escalate to the user with
    the documented fallback — switch the model id env var to
    `gemini-live-2.5-flash-native-audio` and re-run. If 2.5 also fails,
    escalate to OpenAI Realtime as v1's default provider.
  - **R-Phase I.2** — The user's network blocks `wss://generativelanguage.googleapis.com`.
    Mitigation: step 4 includes a `curl -v` connectivity check at the
    top; if it fails, the manual instructions point to the
    troubleshooting section in `docs/design/configuration-guide.md`.

---

## Section 5 — Cross-Cutting Concerns

### 5.1 Parallelization Map (visual)

```
Wave 0:  Phase 0
            │
Wave 1:  Phase A          Phase E
            │                │
Wave 2:  Phase B  Phase C    │
            │       │        │
Wave 3:    Phase D  ─────────┘
            │       │
Wave 4:        Phase F
                   │
Wave 5:   Phase G  (parts of G can start in Wave 2 against Phase A's fakes)
            │
Wave 6:  Phase H
            │
Wave 7:  Phase I  (manual)
```

### 5.2 Risk Register (top-5 + transverse)

| # | Risk | Likelihood | Impact | Mitigation | Owner phase |
|---|---|---|---|---|---|
| **R-Top1** | `inputAudioTranscription` reliability on Gemini 3.1 Flash Live (ESC-LT-1). The community-flagged unreliability on 2.5 has not been verified on 3.1. | Medium | High (blocks v1 if no final events arrive) | Phase I smoke test gates the launch. Documented fallback to `gemini-live-2.5-flash-native-audio` (same wire schema). If 2.5 also fails, fallback to OpenAI Realtime (single-file change behind the protocol). | Phase F + Phase I |
| **R-Top2** | `RecordingOptions.withOutput(_:)` not updated to copy new fields → silent options-loss on every pause/resume. Latent bug from codebase scan §5. | High (if forgotten) | High (transcription stops working at every segment rotation, no error) | Phase C unit test `RecordingOptionsTests.testWithOutputPreservesTranscriptionFields` is mandatory; reviewer must verify it passes. | Phase C |
| **R-Top3** | WebSocket reconnect race conditions (double `finish()`, lingering receive loops, leaked Tasks). | Medium | Medium (UI hangs, memory grows) | Phase E follows the research-doc patterns verbatim; race-condition hazards 1–8 from research §"Race Conditions and Leaked Tasks" are tested explicitly in `WebSocketSessionTests`. | Phase E |
| **R-Top4** | Audio downsampler `AVAudioConverter` filter state lost on chunk boundary → audible click in transcription stream → transcript quality degrades. | Low | Medium (transcripts noisier than expected) | `AudioDownsampler` is a single instance held for the session lifetime per the research doc; never recreated per chunk. Phase B's `AudioDownsamplerTests.testTwoConsecutiveChunks` validates phase continuity. | Phase B |
| **R-Top5** | API key leakage to logs (URL with `?key=` query param). | Medium | High (security) | Extend `LoggerFactory` with a `redact(_:)` helper in Phase F; route every URL log through it. Phase 7 reviewer enforces. | Phase F |
| R-Trans1 | NFR-19 memory ceiling violation in long sessions (8 MB cap). | Low | Low | Bounded queues at every layer; sidecar header rewrite uses fixed-offset; `transcriptEvents` UI array capped at 1000. Memory budget calculations in research-doc and this plan are well below 8 MB. | Phase B + Phase G |
| R-Trans2 | Tap closure accidentally `await`-ing → blocks `macrec.aligner.serial` → drops audio. | Low | High | Phase 7 code-review checklist line item: every line in the tap closure must be synchronous. `TranscriptionDriver.enqueue(_:)` is documented as `nonisolated` and synchronous. | Phase B |
| R-Trans3 | Test infra brittleness (Swift Testing on `executableTarget` requires the `MacrecUIKit` library refactor pattern from plan-002). | Low | Low | Phase G follows plan-002's existing pattern — UI tests live in `Tests/MacrecUITests/` linking `MacrecUIKit`. No new shared-infrastructure changes. | Phase G |
| R-Trans4 | Privacy disclosure suppresses the recording when the user clicks "Cancel" in the alert mid-Start-press. | Low | Medium (Start fails silently) | Phase G: Cancel resets the picker to `None` AND aborts the Start — emits a clear inline message in the popover ("Transcription cancelled — start again to record without transcription"). | Phase G |
| R-Trans5 | CI does not have a `GOOGLE_API_KEY` and the smoke test silently passes by skipping. | High | Low | Phase I smoke test prints a clear "SKIPPED — set GOOGLE_API_KEY to run" message; the CI report flags it as a manual-gate item. | Phase I |

### 5.3 Code-review Checklist Items (per Phase 7)

These additive items fold into the existing `plan-002` checklist:

- [ ] **CR-LT-1** Tap closures (`SCKitSystemAudioSource.transcriptionTap`,
  `AVMicrophoneSource.transcriptionTap`,
  `RecordingSession.transcriptionTap`) contain no `await`, no
  allocation > 1 KB, no I/O. Verify line-by-line.
- [ ] **CR-LT-2** `RecordingOptions.withOutput(_:)` copies all seven
  new transcription fields. Test asserts this.
- [ ] **CR-LT-3** Setup-message JSON encodes `responseModalities:
  ["AUDIO"]` (NOT `["TEXT"]`). Test asserts this.
- [ ] **CR-LT-4** `LoggerFactory.redact(_:)` strips `key=` query
  parameter; every URL log goes through it. Manually verify.
- [ ] **CR-LT-5** `MacrecError.transcriptionApiKeyMissing` has a
  remediation string naming both the env var (`GOOGLE_API_KEY`) and
  the file path (`~/.tool-agents/macrec/.env` for CLI;
  `~/.tool-agents/macrec-ui/.env` for UI).
- [ ] **CR-LT-6** `TranscriptionDriver.stop(drainTimeout:)` cancels
  the provider task on timeout (no leaked Task).
- [ ] **CR-LT-7** WebSocket close on user stop uses
  `.normalClosure` (1000), NOT abnormal closure (per research §"What
  NOT To Do" pt. 6).
- [ ] **CR-LT-8** No new SwiftPM dependency added (locked-stack
  invariant). Verify `Package.swift` diff.
- [ ] **CR-LT-9** `FakeTranscriptionProvider` is in
  `Sources/MacrecCore/Transcription/`, not `Tests/`, with a `public`
  modifier so both `MacrecCoreTests` and `MacrecUITests` can use it.
- [ ] **CR-LT-10** `--transcribe none` (default) with no other
  transcription flags produces zero behavior change vs the pre-plan-003
  build. Run `test_scripts/e2e-30s-mixed.sh` unchanged.

---

## Section 6 — Issues / Pending Items to Register in Phase 0

Pre-register the following in `Issues - Pending Items.md` before any
code is written:

- **R-26 — `inputAudioTranscription` empirical reliability on Gemini
  3.1 Flash Live**. Validate in Phase I smoke test. Documented fallback:
  `gemini-live-2.5-flash-native-audio`.
- **R-27 — Detach-mode transcription scope**. Excluded from v1 per
  OQ-LT-5; v2 follow-up.
- **R-28 — On-device transcription provider**. Out of scope per
  refined-request §Out of scope; v2 follow-up (`AppleSpeechTranscriptionProvider`
  via `SFSpeechRecognizer`).
- **R-29 — Separate transcript window**. Excluded by OQ-LT-3; logged
  as v2 enhancement.
- **R-30 — Provider expansion**. OpenAI Realtime, Deepgram,
  AssemblyAI all admit the v1 protocol; logged as v2 follow-ups.

---

## Section 7 — Acceptance Criteria Coverage Matrix

Each AC-LT-* from the refined request maps to the phase that satisfies
it. The matrix is the verification source-of-truth: Phase 9 (Test
Builders) and Phase 10 (Integration Verifier) use it to confirm nothing
falls through.

| AC ID | Description (short) | Phase | Verification artefact |
|---|---|---|---|
| AC-LT-1 | None is the default and a true no-op | A (partial) + B (full) | `e2e-transcription-noop.sh`; `TranscriptionTapIntegrationTests` |
| AC-LT-2 | Recording integrity unaffected by transcription presence | B | `TranscriptionTapIntegrationTests` (SHA comparison) |
| AC-LT-3 | Recording integrity unaffected by transcription failure | B | Same suite, hanging fake provider |
| AC-LT-4 | Recording integrity unaffected by missing API key (fail-fast) | C | `TranscriptionConfigResolverTests` |
| AC-LT-5 | Sidecar naming follows segmentation | D | `TranscriptSidecarNamerTests` |
| AC-LT-6 | Sidecar formats are valid | D | `TranscriptSidecarWriterTests` (golden files) |
| AC-LT-7 | Live UI panel shows partials, then commits finals | G | `TranscriptPanelTests` |
| AC-LT-8 | UI surfaces missing-key state | G | `TranscriptionMissingKeyBadgeTests` |
| AC-LT-9 | Privacy disclosure shown on first opt-in | G | `TranscriptionPrivacyAlertTests` |
| AC-LT-10 | Reconnect on transient failure | E (partial) + F (full) + I (live) | `WebSocketSessionTests`; `GeminiLiveProviderTests`; manual step 10 |
| AC-LT-11 | Bounded queue drops, never blocks | B | `TranscriptionDriverTests` (drop-counter) |
| AC-LT-12 | Source selection routes correctly | B (partial) + G (full) | `RecordingControllerTranscriptionTests` |
| AC-LT-13 | Clean shutdown drains finals | D | `TranscriptionDriverWithSinkTests` |
| AC-LT-14 | Cost metrics emitted | D + G | sidecar header assertion + post-stop disclosure |
| AC-LT-15 | `macrec start --help` lists all new flags | C | help-output regression test |
| AC-LT-16 | `--transcribe none` is the default; zero behavior change | A + B + C | `e2e-30s-mixed.sh` (existing) re-run unchanged |
| AC-LT-17 | Invalid provider name fails with `EX_USAGE` | A (partial) + C (full) | `TranscriptionConfigResolverTests` |
| AC-LT-18 | Live transcription picker present in popover | G | `TranscriptionPickerTests` |
| AC-LT-19 | Picker disabled while recording | G | Same suite |
| AC-LT-20 | Transcript panel survives Pause/Resume across segments | D (partial) + G (full) | `RecordingControllerTranscriptionTests` |
| AC-LT-21 | `docs/tools/macrec.md` updated | H | Phase H `/tool-conventions audit` |
| AC-LT-22 | `docs/tools/macrec-ui.md` updated | H | Same audit |
| AC-LT-23 | `docs/design/configuration-guide.md` updated | H | grep count of new sections |
| AC-LT-24 | `docs/design/project-functions.md` updated | 0 (partial) + H (full) | grep count of FR-45..FR-58 |
| AC-LT-25 | `Issues - Pending Items.md` updated | 0 (partial) + H (full) | grep for R-26..R-30 entries |

---

## Section 8 — Functional Requirements Update

The fourteen new functional requirements and five new non-functional
requirements are appended to `docs/design/project-functions.md` as
§1.5 "Added by plan-003 — Live transcription side-channel". The
verbatim entries follow (each gets `Status: PLANNED` and the phase
mapping below).

### FR-45 — Provider abstraction
**Phase**: A (plan-003).
`MacrecCore` MUST expose a `TranscriptionProvider` protocol that accepts
a stream of PCM frames (with sample-rate, channel-count, source-tag
metadata) and emits a stream of `TranscriptEvent` values. Concrete
providers in v1: `GeminiLiveTranscriptionProvider`,
`NoOpTranscriptionProvider`. Adding a new provider MUST require zero
changes to orchestration code (NFR-21).

### FR-46 — Non-blocking tap
**Phase**: B (plan-003).
The live PCM tap that feeds the transcription provider MUST NOT block,
slow, or starve the existing capture / aligner / recorder queues.
Implemented via a bounded `AsyncStream<TranscriptionPCMChunk>` with
`.bufferingNewest(64)`. Dropped frames MUST be counted and surfaced as
a metric.

### FR-47 — Source selection
**Phase**: B + C + G (plan-003).
The user MUST be able to choose which audio source feeds transcription:
`system`, `mic`, `mixed`, or `both`. Default: `mixed`. Selection is
independent of the recording's `--layout`.

### FR-48 — Provider selection (CLI)
**Phase**: C (plan-003).
`macrec start` MUST accept `--transcribe <none|gemini-live|...>`.
Default `none`. Selecting non-`none` with no API key configured MUST
fail fast with `MacrecError.transcriptionApiKeyMissing` (exit 78).
Selecting non-`none` with `--detach` MUST fail with
`transcriptionDetachUnsupported` (exit 64).

### FR-49 — Provider selection (UI)
**Phase**: G (plan-003).
The `macrec-ui` popover MUST include a "Live transcription" dropdown
with `None` (default) and one entry per registered provider. Missing-key
state MUST be visually flagged (red badge / tooltip). Start with
missing key MUST surface `transcriptionApiKeyMissing` inline without
crashing the recording.

### FR-50 — Transcript event model
**Phase**: A (plan-003).
`TranscriptEvent` MUST distinguish at minimum: `partial`, `final`,
`error`, `sessionEnded`.

### FR-51 — Transcript persistence
**Phase**: D (plan-003).
When transcription is enabled, a sidecar transcript file MUST be
written alongside the audio file using the same basename and
segmentation rules. Single segment: `recording-….transcript.<ext>`.
Multi-segment: `recording-….partNN.transcript.<ext>`. `--layout split`
with source `both`: two sidecars, one per layout source. Sidecar
formats v1: `jsonl` (default), `txt`, `srt`, `vtt`.

### FR-52 — Live transcript display in UI
**Phase**: G (plan-003).
The popover MUST render a live, scrollable transcript panel below the
level meters. Partial events appear in muted style and are replaced in
place; finals are committed in normal style. Auto-scroll to bottom
unless user has scrolled away. Closing the popover does not stop
transcription.

### FR-53 — Privacy disclosure
**Phase**: G (plan-003).
Selecting any non-`None` provider for the first time on a given launch
MUST surface a one-time confirmation dialog naming the third-party API.
"Don't show again" suppresses the dialog for subsequent launches; the
disclosure remains discoverable via tooltip on the picker.

### FR-54 — Persisted UI defaults
**Phase**: G (plan-003).
The selected provider, source, and sidecar format MUST persist across
launches in `UserDefaults` under `com.macrec.ui.transcribeProvider`,
`com.macrec.ui.transcribeSource`, `com.macrec.ui.transcriptFormat`.
Default on first launch: `None`, `mixed`, `jsonl`.

### FR-55 — API key configuration
**Phase**: C (plan-003).
Provider API keys MUST resolve through the same four-tier chain.
Canonical keys: `GOOGLE_API_KEY` (Gemini Live);
`MACREC_TRANSCRIBE_PROVIDER`, `MACREC_TRANSCRIBE_SOURCE`,
`MACREC_TRANSCRIPT_FORMAT`, `MACREC_TRANSCRIBE_MODEL`,
`MACREC_TRANSCRIBE_KEY_EXPIRES_AT`. No silent fallback when a key is
missing.

### FR-56 — Watchdog / reconnect
**Phase**: E + F (plan-003).
If the transcription provider connection drops mid-recording, the
subsystem MUST transparently reconnect at least once, log the gap, emit
a `TranscriptEvent.error(isFatal: false)`, and continue. Repeated
failures (3 within 60 s) escalate to "transcription paused for this
recording" — the recording itself never stops.

### FR-57 — Clean shutdown
**Phase**: D + F (plan-003).
On Stop / SIGINT / SIGTERM, the transcription session MUST drain
pending finals (5 s bounded), close the provider connection, flush the
sidecar file, and surface the final on-disk transcript path through
the existing post-stop disclosure panel.

### FR-58 — Cost / volume metrics
**Phase**: B + D + G (plan-003).
The subsystem MUST track: seconds streamed, partial count, final
count, dropped tap frames, wall-clock duration. Logged at `info` level
on stop. Written into the sidecar file's header (jsonl) and into the
post-stop UI disclosure.

### NFR-17 — Recording integrity isolation
**Phase**: B (plan-003).
A failure or hang in the transcription path MUST NOT affect the
on-disk recording. Verified by `TranscriptionTapIntegrationTests.testHangingFakeProviderProducesByteIdenticalAudio`.

### NFR-18 — Latency budget
**Phase**: I (plan-003).
Median time from spoken word to the corresponding *final* transcript
event MUST be under **2.5 s** under nominal network conditions. Median
time to *first partial* MUST be under **1.0 s**. Observability targets,
not hard SLOs.

### NFR-19 — Memory ceiling
**Phase**: B (plan-003).
The transcription tap's bounded queue MUST not exceed 8 MB of in-flight
PCM at any time, regardless of provider stall.

### NFR-20 — Privacy posture
**Phase**: F (plan-003).
Audio is transmitted to a third-party API, but no PII metadata is
transmitted. Payload: raw PCM + source label only.

### NFR-21 — Provider extensibility
**Phase**: A + Phase 7 review (plan-003).
Adding a new provider MUST require zero changes to `MacrecCore`
orchestration code. Verified by the code-review checklist.

---

## Section 9 — File Manifest Summary

A flat list of every file that this plan creates or modifies.

### Files to create (all under `Sources/MacrecCore/Transcription/` unless noted)

| File | Phase |
|---|---|
| `TranscriptionProvider.swift` | A |
| `TranscriptionPCMChunk.swift` | A |
| `TranscriptEvent.swift` | A |
| `TranscriptionAudioFormat.swift` | A |
| `TranscriptionOptions.swift` | A |
| `TranscriptionProviderId.swift` | A |
| `TranscriptionSource.swift` | A |
| `TranscriptFormat.swift` | A |
| `NoOpTranscriptionProvider.swift` | A |
| `FakeTranscriptionProvider.swift` | A |
| `AudioDownsampler.swift` | B |
| `AudioDownsamplerError.swift` | B |
| `TranscriptionDriver.swift` | B |
| `SyntheticAudioFixture.swift` | B (test infra) |
| `TranscriptSidecarWriter.swift` | D |
| `TranscriptSidecarNamer.swift` | D |
| `TranscriptHeader.swift` | D |
| `TranscriptSink.swift` | D |
| `WebSocketTransport.swift` | E |
| `LiveWebSocketTransport.swift` | E |
| `WebSocketSession.swift` | E |
| `WebSocketSessionTypes.swift` | E |
| `GeminiLiveTypes.swift` | F |
| `GeminiLiveTranscriptionProvider.swift` | F |
| `GeminiLiveProviderRegistry.swift` | F |
| `Sources/macrec-ui/Views/TranscriptionPicker.swift` | G |
| `Sources/macrec-ui/Views/TranscriptionSourcePicker.swift` | G |
| `Sources/macrec-ui/Views/TranscriptFormatPicker.swift` | G |
| `Sources/macrec-ui/Views/TranscriptionMissingKeyBadge.swift` | G |
| `Sources/macrec-ui/Views/TranscriptPanel.swift` | G |
| `Sources/macrec-ui/Views/TranscriptionPrivacyAlert.swift` | G |
| `test_scripts/e2e-transcription.sh` | I |
| `test_scripts/e2e-transcription-noop.sh` | I |

### Test files to create (all under `Tests/MacrecCoreTests/Transcription/` or `Tests/MacrecUITests/`)

| File | Phase |
|---|---|
| `Tests/MacrecCoreTests/Transcription/TranscriptionProviderProtocolTests.swift` | A |
| `Tests/MacrecCoreTests/Transcription/FakeTranscriptionProviderTests.swift` | A |
| `Tests/MacrecCoreTests/Transcription/TranscriptEventCodableTests.swift` | A |
| `Tests/MacrecCoreTests/MacrecErrorTests.swift` (extension) | A |
| `Tests/MacrecCoreTests/Transcription/AudioDownsamplerTests.swift` | B |
| `Tests/MacrecCoreTests/Transcription/TranscriptionDriverTests.swift` | B |
| `Tests/MacrecCoreTests/Transcription/TranscriptionTapIntegrationTests.swift` | B |
| `Tests/MacrecCoreTests/Transcription/TranscriptionConfigResolverTests.swift` | C |
| `Tests/MacrecCoreTests/RecordingOptionsTests.swift` (extension) | C |
| `Tests/MacrecCoreTests/Transcription/TranscriptSidecarNamerTests.swift` | D |
| `Tests/MacrecCoreTests/Transcription/TranscriptSidecarWriterTests.swift` | D |
| `Tests/MacrecCoreTests/Transcription/TranscriptionDriverWithSinkTests.swift` | D |
| `Tests/MacrecCoreTests/Transcription/WebSocketSessionTests.swift` | E |
| `Tests/MacrecCoreTests/Transcription/FakeWebSocketTransportTests.swift` | E |
| `Tests/MacrecCoreTests/Transcription/GeminiLiveTypesEncodingTests.swift` | F |
| `Tests/MacrecCoreTests/Transcription/GeminiLiveProviderTests.swift` | F |
| `Tests/MacrecCoreTests/Transcription/GeminiLiveLiveSmokeTest.swift` | F (gated on env var) |
| `Tests/MacrecUITests/TranscriptionPickerTests.swift` | G |
| `Tests/MacrecUITests/TranscriptionMissingKeyBadgeTests.swift` | G |
| `Tests/MacrecUITests/TranscriptPanelTests.swift` | G |
| `Tests/MacrecUITests/TranscriptionPrivacyAlertTests.swift` | G |
| `Tests/MacrecUITests/RecordingControllerTranscriptionTests.swift` | G |

### Files to modify

| File | Phase | Change |
|---|---|---|
| `Sources/MacrecCore/Errors/MacrecError.swift` | A | Add 5 new error cases |
| `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift` | B | Add `transcriptionTap` property |
| `Sources/MacrecCore/Capture/AVMicrophoneSource.swift` | B | Add `transcriptionTap` property |
| `Sources/MacrecCore/RecordingSession.swift` | B + C + D + F | Add `transcriptionTap`, `transcriptionDriver`, registry call, sidecar rotation |
| `Sources/MacrecCore/Config/RecordingOptions.swift` | C | Add 7 new stored properties + fix `withOutput(_:)` |
| `Sources/MacrecCore/Config/ConfigResolver.swift` | C | Add 7 new keys + resolution logic |
| `Sources/macrec/Commands/StartCommand.swift` | C | Add 5 new CLI flags |
| `Sources/MacrecUIKit/RecordingController.swift` | G | Add 5 transcription-related observed properties |
| `Sources/MacrecUIKit/SessionCoordinator.swift` | D + G | Add sidecar rotation hook + segment-marker event |
| `Sources/macrec-ui/RootView.swift` | G | Add pickers, panel, privacy alert |
| `Sources/macrec-ui/Views/SavedToDisclosure.swift` | G | List sidecar paths in post-stop disclosure |
| `docs/tools/macrec.md` | H | New flags, sidecar table, worked example |
| `docs/tools/macrec-ui.md` | H | New pickers, panel, privacy alert |
| `docs/design/configuration-guide.md` | H | §2.16..§2.22 |
| `docs/design/project-design.md` | H | New §1.4 + §2.13 + §3.5 + §4.6 + §4.7 + §9.5 update |
| `docs/design/project-functions.md` | 0 + H | FR-45..FR-58 + NFR-17..NFR-21 (PLANNED → IMPLEMENTED) |
| `Issues - Pending Items.md` | 0 + H | R-26..R-30 |

---

## Section 10 — Out-of-Plan Notes

- **Build system**: no `Package.swift` change is required (no new
  SwiftPM dependency, no new target). The new files compile under
  `MacrecCore` and `macrec-ui` automatically.
- **TCC permissions**: no new permission required. Document in
  `Issues - Pending Items.md` that if `macrec` is ever sandboxed, the
  `com.apple.security.network.client` entitlement must be added (R-31
  candidate).
- **CLAUDE.md "Tools" section**: unchanged. Live transcription is a
  feature of the existing `macrec` and `macrec-ui` tools, not a new
  tool. No `/tool-conventions scaffold` invocation is required.
- **Approved exception 001 (Swift)**: continues to apply. No
  TypeScript code is introduced.

---

> **End of plan-003-live-transcription.md.** Phase 5 (Designer) is the
> next gate; Phase 5 confirms the resolved OQs in §0.1 and answers the
> escalations in §0.2 before Phase 6 (parallel coders) is invoked.
