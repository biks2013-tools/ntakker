# Investigation: Dual-Provider Live Transcription Mode (Apple on-device EN + Apple Cloud EL)

**Date:** 2026-05-01
**Refined request:** [`docs/design/refined-request-dual-transcription.md`](../design/refined-request-dual-transcription.md)
**Codebase scan:** [`docs/reference/codebase-scan-dual-transcription.md`](codebase-scan-dual-transcription.md)
**Reused investigation:** [`docs/reference/apple-cloud-stt-investigation-2026-05.md`](apple-cloud-stt-investigation-2026-05.md)

## Executive Summary

The dual-transcription feature is **technically feasible with low architectural risk**. Both
providers (`apple` SpeechAnalyzer and `apple-cloud` SFSpeechRecognizer) are already shipping
streaming sessions that conform to `StreamingTranscriptionSession`, accept identical
`[Float]` 16 kHz mono buffers downstream of `AudioDownsampler`, and have already been
proven to coexist in the runtime. None of the seven open questions in the refined request
require new platform research — they are design choices internal to `MacrecCore`/`macrec-ui`.

**Recommended architecture (one-line):** introduce a new `DualTranscriptionManager` actor
that mirrors the `TranscriptionManager` public surface, owns two
`StreamingTranscriptionPipeline` instances and two `AudioDownsampler` instances (one per
channel), fans out frames synchronously inside the actor, merges the two
`AsyncStream<TranscriptionEvent>` outputs into one chronological stream tagged by `model` /
`language` (no per-channel UI segregation needed at the data-model level), writes a single
sidecar via the existing writer, and surfaces a new `DualTranscriptionControls` SwiftUI
view that swaps in below a top-of-panel `Picker("Mode", selection:)` segmented control. Channel
isolation is achieved by per-channel `Task` lifecycles; failure of one channel is logged and
surfaced inline but does not terminate the other.

## Context

The user wants to capture Greek speech that is sprinkled with English code-switched words.
Apple SpeechAnalyzer (on-device, macOS 26) is strong on English but does not support `el-GR`
at launch; Apple Cloud `SFSpeechRecognizer` supports `el-GR` but is single-locale per
session and goes over the network. Running both providers in parallel against the same
audio stream is the proposed mitigation. The Single-mode UI and behaviour MUST remain
unchanged (verbatim user constraint).

The codebase scan identified 16 integration points (IP-1 through IP-16) and confirmed that
the existing capture pipeline already produces `[Float]` buffers consumed by
`StreamingTranscriptionPipeline.ingest`. The Apple Cloud investigation confirmed quotas
(1,000 req/hr/device, 60 s task cap auto-rotated at 55 s by `AppleCloudStreamingSession`),
permission model (`NSSpeechRecognitionUsageDescription` + TCC grant), and the run-mode
SIGABRT caveat that requires launching from the `.app` bundle.

This investigation answers the seven design questions raised in the prompt and recommends
concrete patterns the Phase-5 plan can adopt without further research.

---

## Q1 — Architectural Pattern for Parallel Provider Execution

### Option 1A — `DualTranscriptionManager` actor wrapping two pipelines (proposed in the codebase scan)

- **Description:** New `actor DualTranscriptionManager` lives in
  `Sources/MacrecCore/Transcription/DualTranscriptionManager.swift`. Mirrors the public
  surface of `TranscriptionManager` (`start()`, `ingest(_:from:)`, `ingestFrame(_:from:)`,
  `stop()`, `rotateSidecar`, `currentMetrics()`) so `RecordingSession` can dispatch to one
  or the other based on a single boolean / enum at construction. Internally holds two
  `StreamingTranscriptionPipeline` instances, two `AudioDownsampler` instances, and one
  shared `TranscriptSidecarWriter`.
- **Strengths:**
  - Zero changes to `StreamingTranscriptionPipeline` (NFR-1: Single-mode preservation
    guaranteed by construction — Single uses `TranscriptionManager`, Dual uses the new
    type, no shared mutable state).
  - Both pipelines retain their independent `nextSegmentIndex` and
    `indexForUtteranceId` maps — segments from the two providers never collide.
  - Failure semantics are easy: each pipeline already has its own drain `Task`; a thrown
    error in one does not propagate to the other (lines 175-184 of
    `StreamingTranscriptionPipeline`).
  - Mirrors the already-tested actor pattern used elsewhere in the codebase (`AppleCloudStreamingSession`, the existing pipeline).
- **Weaknesses:**
  - Public-surface duplication: every method on `TranscriptionManager` must have a peer
    on `DualTranscriptionManager`. If `TranscriptionManager` evolves, the dual variant must
    be kept in sync.
  - `RecordingSession` (the caller) needs a switch (`if dual { dualMgr } else { mgr }`) at
    every dispatch point unless wrapped behind a protocol.
- **Effort/Complexity:** Medium (one new actor, one new SwiftUI panel branch, one mode
  switch, ~600–900 LOC).
- **Risk:** Low. No platform unknowns; both providers are shipping; both event streams
  are already `AsyncStream<StreamingTranscriptionEvent>`.
- **Best suited when:** the dual mode is a first-class peer of single-mode and won't grow
  to N>2 channels in v1.

### Option 1B — Generic "session multiplexer" / N-way SessionGroup abstraction

- **Description:** Build a generic `TranscriptionSessionGroup<N>` (or
  `MultiplexedTranscriptionPipeline`) that takes an array of `(provider, options)` tuples
  and runs them all in parallel against the same audio. Single-mode is the N=1 case; dual
  is N=2; future "triple Greek + English + Spanish" mode is N=3. `TranscriptionManager`
  becomes a thin adapter over `TranscriptionSessionGroup<1>`.
- **Strengths:**
  - Forward-looking: cheap to extend to triple mode (OQ-6 in the refined request asked
    about this generality).
  - One code path, one set of tests; no duplicated public surface.
- **Weaknesses:**
  - Refactors existing single-mode plumbing → directly violates the hard constraint
    "Single mode UI and behaviour MUST NOT change" at the runtime level. Even if the
    user-visible behaviour is preserved, the regression surface is much larger and tests
    must prove byte-identical sidecar output (AC-1).
  - Generality the spec explicitly says is OUT OF SCOPE ("Adding a 'Dual' mode that
    combines providers other than `apple` + `apple-cloud`... is NOT a requirement").
  - More complex error semantics: the group has to define its own failure-isolation
    policy that today lives implicitly in `StreamingTranscriptionPipeline`.
- **Effort/Complexity:** High (significant refactor; new abstraction layer; rewrite
  tests; risks regression in single mode).
- **Risk:** Medium-High. The single-mode regression surface is the killer.
- **Best suited when:** the project knows it will need N>2 channels in the next 1–2 cycles.

### Option 1C — Composite session conforming to `StreamingTranscriptionSession` itself

- **Description:** A `CompositeStreamingSession` conforms to
  `StreamingTranscriptionSession`. Internally it owns two child sessions and exposes a
  merged `events: AsyncStream<StreamingTranscriptionEvent>`. The existing
  `StreamingTranscriptionPipeline` is unchanged — it sees one "session" that is actually
  two. Provider factory returns a `DualTranscriptionProvider` that returns the composite.
- **Strengths:**
  - Most code-light option: pipeline, manager, and `RecordingSession` are all unchanged.
  - Symmetric / elegant — composite pattern at the protocol boundary.
- **Weaknesses:**
  - **Loses per-channel isolation at the pipeline level.** The pipeline has one
    `nextSegmentIndex` and one `indexForUtteranceId: [UUID: Int]` (lines 59-60); two
    providers emitting unrelated UUIDs into one map is fine, but per-channel
    `rotateSidecar` is impossible — the sidecar writer is shared for both channels by
    design but the pipeline cannot rotate one without the other.
  - **Channel-A / Channel-B identification at the segment level only by `model` /
    `language` fields**, which is fine for the sidecar but awkward for per-channel
    metrics (FR-9 cost / latency UI per channel). The pipeline does not know it is
    handling two channels, so it cannot expose `metrics(channel: A)` /
    `metrics(channel: B)`.
  - **Failure isolation is hidden inside the composite** — if one child session throws
    inside `events`, the merged stream's behaviour depends on the merge implementation,
    and the pipeline's `attach(session:for:)` only spawns one drain Task per session.
    This is the core place where "one channel fails, the other continues" semantics
    could silently break.
  - The factory has to know how to build a "dual" provider, contradicting the cleaner
    factory-untouched approach in IP-12.
- **Effort/Complexity:** Low LOC, high subtle-correctness risk.
- **Risk:** Medium. Looks elegant, hides too much.
- **Best suited when:** the project would never need per-channel telemetry or per-channel
  sidecar rotation — neither is true here (FR-9 explicitly requires per-channel metrics).

### Recommendation for Q1

**Option 1A — `DualTranscriptionManager` actor.** Per-channel telemetry (FR-9), atomic
pause/resume/split (FR-11) coordinated across two pipelines, and the hard constraint that
single-mode runtime is unchanged (NFR-1) all argue for keeping the dual orchestration in a
distinct top-level type. Generalising to N>2 (Option 1B) is explicitly out of scope.
Option 1C buries the channel boundary too deep for the per-channel UI requirements.

The duplicated public surface is the price; it can be partially mitigated by extracting a
small `TranscriptionDispatcher` protocol that both `TranscriptionManager` and
`DualTranscriptionManager` conform to, so `RecordingSession` calls the protocol and the
choice happens at construction time.

---

## Q2 — Audio Fan-Out Strategy

The codebase scan (IP-4) already noted the key facts: `AudioDownsampler` is **not
thread-safe** (it carries an internal accumulator across `convert(_:)` calls), so each
channel needs its own instance. The capture graph delivers `AlignedFrame` values containing
`CMSampleBuffer`s; both providers consume `[Float]` 16 kHz mono.

### Option 2A — Two `AudioDownsampler` instances inside `DualTranscriptionManager`, synchronous fan-out

- Inside `ingestFrame(_:from:)` the actor calls
  `downsamplerA.convert(buf)` then `pipelineA.ingest(samplesA, from: tag)`,
  `downsamplerB.convert(buf)` then `pipelineB.ingest(samplesB, from: tag)`, sequentially.
- Both pipelines' `ingest` is fire-and-forget (the pipeline immediately delegates to the
  underlying session's `ingest([Float])` which is itself non-blocking — both Apple
  sessions buffer internally).
- **Pros:** simplest possible model; no extra Tasks; no extra memory beyond two `[Float]`
  arrays per frame; deterministic ordering; identical byte content guaranteed (same input
  buffer, two stateful downsamplers seeded identically).
- **Cons:** two downsamplings of the same input → roughly 2× downsampler CPU. Negligible
  in practice (downsampling 16-bit float arrays is microseconds per frame and dwarfed by
  STT inference cost).

### Option 2B — One shared `AudioDownsampler`, broadcast `[Float]` to both pipelines

- Downsample once, hand the same `[Float]` array to both `pipelineA.ingest` and
  `pipelineB.ingest`.
- **Pros:** halves downsampling CPU (still negligible). Guarantees byte-identical buffers
  to both channels.
- **Cons:** requires either making `AudioDownsampler` thread-safe (it isn't) or
  serialising all calls through the `DualTranscriptionManager` actor (which is fine — the
  manager is already an actor). The save is microseconds per frame; the cost is one less
  hot-spot to debug if the downsampler ever leaks state.

### Option 2C — `AsyncStream` / `AsyncChannel` per-channel queue with explicit backpressure

- The actor pushes into `AsyncStream<[Float]>.continuation` per channel (with
  `.bufferingNewest(N)`), and a per-channel consumer Task pulls and feeds `pipeline.ingest`.
- **Pros:** explicit backpressure point — if Channel B (cloud, network-bound) stalls, the
  bounded `bufferingNewest` policy drops oldest samples for B without backing up Channel A
  (NFR-3). Clear "lagging" indicator surface (queue depth).
- **Cons:** more moving parts and Tasks; the pipelines themselves already have internal
  buffering at the session layer (`AppleCloudStreamingSession` queues into its
  `SFSpeechAudioBufferRecognitionRequest`; `AppleSpeechSession` queues into
  `AnalyzerInput`). Adding a second buffer layer is potentially redundant.

### Recommendation for Q2

**Option 2A (per-channel `AudioDownsampler`) + a thin Option-2C-style guard for backpressure**.

Concretely:
- Two `AudioDownsampler` instances, one per channel — keeps the type contract (not
  thread-safe → one per consumer) and avoids any shared-state risk. The downsampling cost
  is irrelevant compared to STT.
- `ingestFrame` fans out **synchronously** inside the actor: downsample A → call
  `pipelineA.ingest`; downsample B → call `pipelineB.ingest`. Because both `ingest` calls
  are non-blocking (they enqueue to the session's internal buffer or queue), the actor
  does not stall the capture graph.
- For NFR-3 (slow consumer must not stall capture), rely on the **session-level
  buffering already in place**: `AppleCloudStreamingSession.ingest` (line 263-283) wraps
  Float32 into an `AVAudioPCMBuffer` and appends to the recognition request — Apple's
  request queue itself absorbs the backpressure. `AppleSpeechSession.ingest` similarly
  feeds the SpeechAnalyzer's `AsyncStream<AnalyzerInput>` which is created with
  `bufferingPolicy: .unbounded` (Phase-5 should verify and consider switching to
  `.bufferingNewest(N)` for the cloud channel specifically — this is one of the few
  Phase-5 calls that needs runtime confirmation).
- Surface a "lagging" indicator only if the per-session queue depth becomes observable
  (or measure inter-arrival latency of partials per channel — Phase-5 design call).

Memory implications: two `[Float]` allocations per frame (~1024 samples × 4 bytes ×
2 = 8 KB per ingest call), garbage-collected immediately after `ingest` returns. Steady
state per channel: one `AudioDownsampler` accumulator (small, bounded), one session-level
queue. **Well within the NFR-4 "≤2× single-mode steady-state memory" bound.**

---

## Q3 — Stream Merging Strategy

Two pipelines each produce `AsyncStream<TranscriptionEvent>`. The downstream consumers
(UI panel via `RecordingController.transcriptSegments`, sidecar writer) currently consume
ONE stream.

### Option 3A — `AsyncAlgorithms.merge`

- Use `swift-async-algorithms`'s `merge(_:_:)` to produce one
  `AsyncMerge2Sequence<AsyncStream, AsyncStream>` that yields events from both in arrival
  order.
- **Pros:** off-the-shelf, well-tested, one Task drains the merged stream, ordering is
  natural arrival order.
- **Cons:** introduces `swift-async-algorithms` as a Package.swift dependency if not
  already there. Termination semantics: `merge` finishes when **both** inputs finish — if
  one channel errors out and its stream completes, merge keeps running on the other,
  which is exactly what FR-4 / NFR-2 want. ✓
- **Channel tagging:** events from both streams must be distinguishable at the merge
  output. The existing `TranscriptionEvent` carries a `TranscriptSegment` which carries
  `model` and `language` — sufficient. **No new "channel" field is required at the event
  level.**

### Option 3B — Manual `AsyncThrowingStream` with two consumer Tasks

- `DualTranscriptionManager` creates one `AsyncStream<TranscriptionEvent>` for the
  outside world, plus two internal Tasks that each drain `pipelineA.events` /
  `pipelineB.events` and yield into the shared continuation.
- **Pros:** zero dependencies; full control over per-channel error handling (one Task
  catches errors and emits an `.error` event tagged with channel A or B without
  terminating the other Task or the merged stream).
- **Cons:** more code; ordering across the two streams depends on Task scheduling, but
  per-channel ordering inside each Task is preserved (which is what matters for partial /
  final pairing per channel).

### Option 3C — No merge: parallel rendering / two separate pipelines exposed to UI

- `RecordingController` exposes two segment arrays
  (`transcriptSegmentsChannelA: [TranscriptSegment]` and `...ChannelB`); the panel
  renders two separate lanes from two separate publishers; the sidecar writer subscribes
  to both via two drain Tasks.
- **Pros:** no merge primitive; the channel boundary is preserved end-to-end.
- **Cons:** larger UI delta (`RecordingController` grows two new published properties);
  the sidecar writer has to be safe under two concurrent producers (which it is — it's
  already an actor); the UI lane decision (OQ-5) is partially baked into the data model.

### Recommendation for Q3

**Option 3B — manual `AsyncStream` with two drain Tasks inside `DualTranscriptionManager`.**

Rationale:
- No new dependency on `swift-async-algorithms` (the project does not currently import
  it; adding a SwiftPM dependency for one merge call is over-investment).
- Explicit per-channel error handling — each drain Task can `do { for await ev in
  pipelineX.events { yield(ev) } } catch { yield(.error(channel: X, error)) }`. One
  channel's failure becomes a channel-tagged error event; the other Task and the merged
  stream keep running. This directly implements the failure-isolation requirement of FR-4
  and NFR-2.
- The existing `TranscriptionEvent.segmentFinalized(segment)` carries `segment.model` and
  `segment.language`, which together identify the channel. **No `channel: "A" | "B"`
  field is needed on `TranscriptionEvent`.** The dual manager can introduce a thin
  `DualChannel` enum internally (case A, case B) used only for routing per-channel
  metrics / errors / status, computed at event-emission time from `segment.model`.
- Pattern matches the existing codebase convention (`AsyncStream.makeStream` +
  `eventsContinuation` is used in every pipeline today — see codebase scan §3).

The drain Tasks live for the lifetime of the dual recording; on `stop()`, the manager
calls `pipelineA.stop()` and `pipelineB.stop()` (each cleanly finishes its `events`
stream), the drain Tasks fall out of their `for await` loops, and the merged stream's
continuation finishes.

---

## Q4 — UI Control Pattern for the Mode Switch

The popover is space-constrained; the user said "probably as a switch under live
transcription"; AC-1 requires Single-mode UI to remain visually unchanged when the switch
is on Single.

### Option 4A — Segmented `Picker("", selection:).pickerStyle(.segmented)` ["Single" | "Dual"] at the top of the Live Transcription panel

- Two-segment switch placed immediately above the existing Single-mode controls. When
  "Single" is selected (default), the existing controls render unchanged. When "Dual" is
  selected, those controls are replaced by `DualTranscriptionControls`.
- **Pros:** instantly discoverable; conventional macOS pattern for binary mode switches;
  smallest vertical footprint (one row, ~28 pt); zero ambiguity that it controls panel
  swapping.
- **Cons:** visually changes the *header* of the Live Transcription panel even in Single
  mode. The constraint is that the controls below remain identical, but a new control
  appears above them — strictly speaking this is a visual change, but the AC-1 spec
  language ("renders the panel identically...field labels, picker options, and defaults
  match exactly") refers to the field controls, not to the absence of a top-of-panel mode
  selector. Phase 5 should confirm with the user.

### Option 4B — `Toggle("Dual mode", isOn:)` below the existing Live Transcription panel

- A single "Dual mode" toggle placed below the existing controls. When OFF, panel
  behaves identically. When ON, the existing controls are hidden and `DualTranscriptionControls` is
  shown below the toggle.
- **Pros:** truly preserves the Single-mode panel pixel-for-pixel — the toggle simply
  appears as a footer; turning it off restores the exact original.
- **Cons:** less discoverable (toggle below is easy to miss); the mental model
  "toggle below dictates what is shown above" is unintuitive; on toggle-on the panel
  contents above the toggle disappear, which is jarring.

### Option 4C — Add a "Dual" entry to the existing `Transcribe` provider picker

- The provider picker becomes `apple | apple-cloud | gemini | ... | Dual (Apple + Apple
  Cloud)`. Selecting "Dual" swaps the panel contents below the picker.
- **Pros:** zero new top-level controls; reuses the existing Transcribe picker
  affordance.
- **Cons:** **violates the explicit hard constraint** that the Single-mode picker remain
  unchanged (AC-1: "field labels, picker options, and defaults match exactly"). Adding a
  9th option *is* a change to the picker. Also semantically odd — Dual is a mode, not a
  provider.

### Option 4D — Tabbed sub-panel with "Single" / "Dual" tabs

- Use SwiftUI `TabView` (or a custom 2-tab segmented header) inside the Live
  Transcription panel.
- **Pros:** clear visual separation; each tab can have its own scroll region.
- **Cons:** vertical-space-expensive (tab header + content padding); overkill for two
  modes; not idiomatic inside a menu-bar popover.

### Recommendation for Q4

**Option 4A — segmented `Picker` ["Single" | "Dual"] at the top of the Live Transcription
panel section**, with a clear `Text("Mode")` label or an inline section header.

Rationale:
- Most discoverable; smallest footprint (one row); idiomatic macOS pattern (segmented
  controls are the conventional "swap the panel below" mechanism, e.g., System Settings'
  Network panel).
- Preserves AC-1: the *field controls* below render unchanged in Single mode. The new
  segmented control is a Mode header, not a relabel of any existing field.
- Default value `"single"` (stored under the new `@AppStorage("com.macrec.ui.transcriptionMode")` key)
  means existing users see exactly the prior layout plus a small additional header row.

If the user pushes back on the new top-level row in Single mode being a visible change,
the fallback is Option 4B (toggle below). Phase 5 should call this out as a binary
user-confirmation question rather than re-investigate.

---

## Q5 — Sidecar Format for Dual Transcripts

The codebase scan (IP-6) already established that `TranscriptSegment` carries `model`
and `language` fields, which are sufficient to identify the channel. The remaining
question is how each sidecar format encodes that identification.

### JSONL — additive, no schema change required

Existing `Wire` struct (`JSONLTranscriptWriter.swift:122-143`) already serialises `model`
and `language`. A dual-channel JSONL is structurally identical to today's: each line is a
JSON object with `model: "apple" | "apple-cloud"` and `language: "en-US" | "el-GR"`. **No
schema extension needed.**

For consumer convenience, an optional `channel: "A" | "B"` field can be added; this is
redundant with `(model, language)` but easier to filter in tools like `jq`. Recommend
**adding `channel`** as an optional field — it is one line of code, costs nothing at
read-time, and removes the need for downstream consumers to know which provider maps to
which channel.

### TXT — line-prefix convention

Existing TXT writer outputs one segment per line with a timestamp prefix (Phase 5 should
verify the exact current format). Recommended convention:
```
[00:00:01.230] [EN] Hello world
[00:00:02.110] [EL] Καλημέρα
```
Prefix is `[<channel-label>]` where the label is the BCP-47 language family code
(`EN`, `EL`). Documented in `docs/tools/macrec.md`.

### SRT — speaker tag convention

SRT does not natively model "channel" or "voice"; the de-facto convention is a speaker
prefix on the cue text:
```
1
00:00:01,230 --> 00:00:02,110
EN: Hello world

2
00:00:02,110 --> 00:00:03,420
EL: Καλημέρα
```
Cues are emitted in arrival order across both channels. **Overlapping segments:** SRT
allows cue start times to overlap — most players handle this gracefully (SubRip itself
ignores overlap; mpv/VLC stack overlapping cues). For dual mode, A and B genuinely will
overlap (both speakers transcribing the same audio window). The writer emits cues in
arrival order without merging or de-overlapping.

### VTT — `<v EN>` / `<v EL>` voice tags

WebVTT has a first-class voice tag for exactly this:
```
WEBVTT

00:00:01.230 --> 00:00:02.110
<v EN>Hello world</v>

00:00:02.110 --> 00:00:03.420
<v EL>Καλημέρα</v>
```
This is the cleanest of the four formats. Same overlapping-cue handling as SRT.

### Decision: do we need a new `channel: "A" | "B"` field on `TranscriptSegment`?

**No, for v1.** `model` + `language` together uniquely identify the channel for the only
provider pair shipping in v1 (`apple` + `apple-cloud`). Adding `channel` as a hard field
would couple the data model to "Dual mode" specifically; if a future N-way mode is added,
"A | B" is no longer adequate.

For JSONL **only**, expose `channel` as an *optional* convenience field at write time
(computed from segment.model in `DualTranscriptionManager` when constructing the
sidecar-bound segment). This is purely an output-format convenience; the in-memory
`TranscriptSegment` schema is untouched.

### Recommendation for Q5

- JSONL: existing schema; add an *optional* convenience `channel` field at write time.
- TXT: line-prefix `[EN]` / `[EL]` (use BCP-47 primary language code uppercased).
- SRT: cue-text speaker prefix `EN:` / `EL:`.
- VTT: voice tag `<v EN>...</v>` (cleanest; native WebVTT feature).
- Overlapping cues are emitted in arrival order, no merge / no dedup. Document the
  convention in `docs/tools/macrec.md` and AC-5.

---

## Q6 — Cost / Latency / Privacy Implications

### Cost / quota

Channel B uses `apple-cloud` (`SFSpeechRecognizer` server path) on every dual recording.
The Apple Cloud quota is **1,000 requests/hour/device, 60 s of audio per task**, with
auto-rotation at 55 s already implemented in `AppleCloudStreamingSession:318-356`. A
single 1-hour dual recording therefore consumes ~66 cloud requests against the per-hour
budget — well below the 1,000-request ceiling.

Apple does not bill for `SFSpeechRecognizer` usage; cost is "free in $, capped in
quota." Per FR-9 the UI should still surface quota usage if available (the current
`apple-cloud` single-mode UI presumably already does — Phase 5 should confirm and
mirror).

### Latency

Channel A (SpeechAnalyzer on-device) typically delivers first partials in ~80–250 ms
(per the prior `apple-cloud-stt-investigation-2026-05.md` and plan-005 measurements).
Channel B (`SFSpeechRecognizer` server) is network-bound: typical first-partial latency
~300–700 ms in good conditions, longer under poor network. Phase 5 should display
per-channel latency badges (already a single-mode feature) updated independently per
channel.

Consequence: in the live transcript UI the EN lane will feel snappier than the EL lane.
This is expected and a user-visible characteristic of the dual mode.

### Privacy disclosure

Per IP-7 / IP-15 in the codebase scan, the `apple-cloud` privacy disclosure already
exists, is per-provider keyed under
`"com.local.macrec-ui.transcription.privacy.apple-cloud.acknowledged"`, and the existing
`appleCloudBodyText` accurately describes the privacy posture.

**Does dual mode need a new disclosure or addendum?** **No.** The disclosure is about the
fact that audio is sent to Apple's servers; that fact is true whether `apple-cloud` is the
sole provider (Single mode) or one of two channels (Dual mode). The disclosure body text
("Live transcription will use Apple's Speech Recognition cloud" + the existing detail
about quotas, rotation, Apple privacy policy) is provider-scoped, not mode-scoped. Reusing
it verbatim is correct.

**Trigger:** when the user flips the mode switch to "Dual" and clicks Start, the manager
checks the `apple-cloud.acknowledged` AppStorage flag. If unset, the existing
`PrivacyDisclosureSheet(selectedProvider: "apple-cloud", ...)` fires; once acknowledged,
the recording starts. If the user previously used `apple-cloud` in Single mode and
acknowledged then, no re-prompt (FR-8 / AC-6).

---

## Q7 — Failure Semantics

The refined request lists this as an open question: if one provider fails mid-recording
(e.g. Apple Cloud auth error, network drop), should the other continue?

### Default behaviour recommendation: **isolated failure, the other continues.**

Rationale:
- This is what the spec explicitly requires in FR-4 ("Failure of one channel MUST NOT
  terminate the other"), NFR-2 ("Channel isolation"), and AC-4 ("Channel isolation").
  The "open question" framing in the original prompt is conservatism on the implementer's
  part; the spec itself has already decided it.
- The user's primary use case is Greek-with-English-words. If the network drops mid-
  recording, the on-device English channel should continue to capture English fragments;
  the Greek channel surfaces an actionable error (e.g. "Apple Cloud unavailable —
  retrying" or "auth required") in its lane and either retries (transient errors) or
  stays errored (terminal errors) for the rest of the recording.
- The failure is visible per-channel in the UI (FR-9 per-channel status), per-channel in
  the sidecar (the failed channel's stream of `.segmentFinalized` events simply stops; no
  poison segment is written), and per-channel in the metrics.

### Implementation surface

The two drain Tasks in `DualTranscriptionManager` (per Q3 recommendation) each wrap their
`for await event in pipelineX.events` loop in a `do { ... } catch { ... }`. On catch:
- Log the channel-tagged error.
- Yield a `.error(channel: X, error)` event into the merged stream.
- Update `RecordingController.dualChannelErrors.channelX` (per IP-14) so the lane
  renders an inline error banner.
- Do NOT propagate to the other Task or to `recordingSession.stop()`.

### Edge case — both channels fail

If both channels fail (e.g. Speech Recognition TCC denied entirely), the recording
continues capturing audio (capture is independent of transcription); both lanes show
errors; the audio file is still produced; the sidecar is empty (or nearly so) but
present. This matches existing single-mode behaviour where a failed transcription does
not abort the recording (Phase 5 should verify this assumption against current Single
behaviour).

### Phase-5 design decision to surface

This investigation **picks the default confidently** ("isolated failure, the other
continues") because the spec has already required it. Phase 5 should not re-debate; it
should design the per-channel error UI surface and the retry policy for transient cloud
errors (e.g. exponential backoff for `kAFAssistantErrorDomain Code=2` / network drop).
Retry policy IS a Phase-5 design call — this investigation does not pre-pick a backoff
schedule.

---

## Comparison Matrix

| Criterion | Recommended (1A + 2A + 3B + 4A) | Alt: Generic SessionGroup (1B) | Alt: Composite Session (1C) |
|---|---|---|---|
| Single-mode preservation (NFR-1, AC-1) | ✓ Guaranteed (separate type) | ⚠ Refactor risk | ✓ But isolation buried |
| Per-channel telemetry (FR-9) | ✓ Native | ✓ Native | ✗ Needs surfacing |
| Channel isolation on failure (FR-4, NFR-2) | ✓ Per-channel Task | ✓ Native | ⚠ Implicit, easy to break |
| Future N>2 extensibility | ⚠ N=2 hardcoded | ✓ Generic | ⚠ N=2 in composite |
| Code surface added | Medium (~700 LOC) | High (refactor) | Low (~300 LOC) |
| Test surface | Medium (3 new test files) | High (rewrite) | Medium |
| Risk to in-flight code | Very low | Medium-high | Medium |
| Atomic pause/split (FR-11) | ✓ Manager fans both | ✓ Group fans all | ⚠ Pipeline-level coupling |

---

## Recommendation (consolidated)

**Adopt Option 1A (DualTranscriptionManager actor) + Option 2A (per-channel
AudioDownsampler, sync fan-out) + Option 3B (manual AsyncStream merge with two drain
Tasks) + Option 4A (segmented Mode picker at the top of the Live Transcription panel)**,
with the JSONL/TXT/SRT/VTT conventions from Q5, the existing `apple-cloud` privacy
disclosure reused verbatim per Q6, and the spec-mandated isolated-failure semantics
from Q7.

**Why this combination over alternatives:**
- It is the lowest-risk path to satisfy the hard constraint NFR-1 (Single mode unchanged
  byte-for-byte).
- Every component maps to existing codebase patterns (actor isolation, AsyncStream +
  continuation, per-pipeline drain Tasks) — there are no novel concurrency primitives.
- It satisfies all 11 functional requirements without touching the capture graph, the
  encoders, the daemon, or the existing `TranscriptionManager`.
- Future extensibility to N>2 is deferred to a future plan; the code does not preclude
  extracting a generic SessionGroup later if and when a third channel is requested.

**Conditions under which this recommendation would change:**
- If the user explicitly asks for triple-channel mode in v1.x: pivot to Option 1B
  (generic SessionGroup) and pay the refactor cost.
- If user-testing reveals the segmented Mode picker (Option 4A) violates the "looks
  unchanged" expectation: fall back to Option 4B (Toggle below).

**Caveats / prerequisites:**
- macOS-26 deployment target already in place (Exception 002).
- `apple-cloud` already shipping with TCC + run-mode caveat understood (NFR-7).
- `swift-async-algorithms` is **not** required (Option 3B chosen specifically to avoid
  this dependency).

---

## Technical Research Guidance

**Research needed: No (with one micro-question).**

The investigation found sufficient detail in the existing codebase scan
(`codebase-scan-dual-transcription.md`), the prior Apple Cloud STT investigation
(`apple-cloud-stt-investigation-2026-05.md`), and the existing plans (plan-005
SpeechAnalyzer streaming, plan-007 additional STT engines including Apple Cloud) for
confident Phase-5 planning. **Specifically:**

- `StreamingTranscriptionSession` protocol, `StreamingTranscriptionPipeline` actor,
  `AudioDownsampler` thread-safety, and the per-pipeline drain Task pattern are all
  documented in the codebase scan with file/line references.
- Apple Cloud quota, locale set, run-mode caveat, and TCC behaviour are
  authoritatively documented in the existing apple-cloud investigation; Phase 5 can
  cite that document directly without re-investigation.
- SwiftUI segmented `Picker` and `@AppStorage` patterns are already used throughout the
  existing UI (codebase scan §3, IP-9, IP-10) — no SwiftUI research needed.
- `AsyncStream.makeStream` + `eventsContinuation` fan-out pattern is the existing
  in-codebase convention — no async-stream research needed.

### Micro-question — verify only, no investigation needed

#### Topic 1: Backpressure policy of `AppleSpeechSession`'s internal `AnalyzerInput` stream

- **Why**: NFR-3 requires that one slow channel does not stall capture. The cloud
  channel's backpressure is naturally absorbed by Apple's request queue. The on-device
  channel's backpressure depends on whether `AppleSpeechSession`'s internal stream uses
  `bufferingPolicy: .unbounded` or a bounded policy. If unbounded, a misbehaving
  SpeechAnalyzer instance could grow memory unbounded.
- **Focus**: read `AppleSpeechSession`'s implementation in
  `Sources/MacrecCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift`
  (already on disk — this is a 30-second code-read, not research) and confirm/adjust the
  buffering policy. If unbounded, switch to `.bufferingNewest(N)` for safety in dual mode
  specifically.
- **Depth**: Overview (code read, not external research).
- **Relevance**: only matters for memory safety under sustained dual-mode use; does not
  block the v1 plan.

**Everything else is already known.** The Phase-5 plan can proceed directly from this
investigation.

---

## Implementation Considerations

Practical notes for the planner:

- **Protocol extraction (optional):** consider a minimal
  `protocol TranscriptionDispatcher` that both `TranscriptionManager` and
  `DualTranscriptionManager` conform to, so `RecordingSession` holds `any
  TranscriptionDispatcher` and the Single/Dual choice happens once at construction.
  Reduces conditional branches at every call site.

- **AppStorage keys to add (per IP-9):**
  - `"com.macrec.ui.transcriptionMode"` — `"single"` | `"dual"`, default `"single"`
  - `"com.macrec.ui.dual.channelALocale"` — default `"en-US"`
  - `"com.macrec.ui.dual.channelBLocale"` — default `"el-GR"`
  - `"com.macrec.ui.dual.source"` — default `"mixed"`
  - `"com.macrec.ui.dual.transcriptFormat"` — default `"jsonl"`

  Independent from Single-mode keys; round-trip through Single → Dual → Single must
  preserve Single-mode values intact (AC-2).

- **Channel-A locale picker** must source from `SpeechTranscriber.supportedLocales`
  (macOS 26 set, no Greek), NOT `SFSpeechRecognizer.supportedLocales()`. The existing
  `TranscriptionLanguagePicker` uses the latter — Dual mode needs a new constrained
  picker (or a `localeSet:` parameter).

- **Channel-B locale picker** must source from
  `SFSpeechRecognizer.supportedLocales()` (~57 locales), default `el-GR`, with
  validation that it differs from Channel A (per the refined request constraint that the
  two channels must use different providers/locales — though same-provider-different-
  locale is also disallowed by construction since Channel A is `apple` and Channel B is
  `apple-cloud` in v1).

- **CLI surface (OQ-3):** Phase 5 should pick Option A from the codebase scan IP-11
  (`--transcribe dual --transcribe-dual-locale-a en-US --transcribe-dual-locale-b el-GR`).
  Less ambiguous than reusing `--transcribe-language`/`--transcribe-language2`.

- **Sidecar rotation (FR-11 split):** call `pipelineA.rotateSidecar(...)` and
  `pipelineB.rotateSidecar(...)` from a single `DualTranscriptionManager.rotateSidecar`
  method, sharing the same target URL and format. Both pipelines write into the same
  sidecar file via the (single, shared) `TranscriptSidecarWriter` actor; after rotation,
  both pipelines write into the new sidecar.

- **Per-channel metrics on `RecordingController`:** add `dualMetrics: (channelA:
  TranscriptionMetrics, channelB: TranscriptionMetrics)?` and `dualChannelErrors:
  (channelA: String?, channelB: String?)?` per IP-14 recommendation.

- **Test files (AC-10):**
  - `Tests/MacrecCoreTests/Transcription/DualStreamingPipelineTests.swift`
  - `Tests/MacrecCoreTests/Transcription/DualChannelIsolationTests.swift`
  - `Tests/MacrecCoreTests/Transcription/Persistence/DualSidecarWriterTests.swift`

- **Pitfall — `nextSegmentIndex` collision:** each pipeline has its own
  `nextSegmentIndex`, so segments from Channel A and Channel B will share index numbers
  (both start at 0). The sidecar JSONL output should NOT use `nextSegmentIndex` as a
  globally-unique key in dual mode; rely on `segment.id` (UUID) which is already unique.

- **Pitfall — `indexForUtteranceId` map:** per-pipeline. Partial→final correlation works
  correctly inside each pipeline because the map is local. No cross-pipeline correlation
  is attempted (and shouldn't be — a partial in Channel A is unrelated to any segment in
  Channel B).

- **Suggested first step (Phase 5):** write the plan-008 design doc covering the actor
  signature, the merged-event contract, the AppStorage keys, the SwiftUI panel swap, the
  CLI flag spelling, and the three new test file specs. Then implement bottom-up
  (manager → pipeline → UI) so each layer can be unit-tested in isolation.

---

## References

| # | Source | Location | What was learned |
|---|---|---|---|
| 1 | Refined request | `docs/design/refined-request-dual-transcription.md` | Full FR/NFR/AC list, hard constraints, open questions |
| 2 | Codebase scan | `docs/reference/codebase-scan-dual-transcription.md` | 16 integration points (IP-1 through IP-16), file/line references for every touchpoint, recommended new artefact list |
| 3 | Apple Cloud STT investigation | `docs/reference/apple-cloud-stt-investigation-2026-05.md` | Authoritative for `apple-cloud` quota (1,000 req/hr), 60 s task cap, 55 s auto-rotation, locale set, TCC, privacy posture |
| 4 | plan-005 (Apple SpeechAnalyzer streaming) | `docs/design/plan-005-apple-speech-streaming.md` | Existing on-device streaming pipeline pattern, partial latency targets |
| 5 | plan-007 (additional STT engines) | `docs/design/plan-007-additional-stt-engines.md` | `apple-cloud` integration history, run-mode SIGABRT caveat, per-provider privacy disclosure mechanism |
| 6 | `Issues - Pending Items.md` → PLAN-007-DONE-14 | Project root | Run-mode caveat verbatim text, existing apple-cloud disclosure key |
| 7 | `StreamingTranscriptionPipeline.swift` | `Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift:50-257` | Actor pattern, drain-Task convention, per-pipeline `nextSegmentIndex` / `indexForUtteranceId`, fan-out shape |
| 8 | `AppleCloudStreamingSession` | `Sources/MacrecCore/Transcription/Providers/AppleCloudTranscriptionProvider.swift:186-481` | 55 s rotation, `requiresOnDeviceRecognition = false`, locale-pinned at construction, `isRunningFromAppBundle` gate |
| 9 | `TranscriptSegment` schema | `Sources/MacrecCore/Transcription/TranscriptSegment.swift:4-36` | `model` and `language` fields confirm no schema change needed for channel tagging |
| 10 | `JSONLTranscriptWriter` `Wire` struct | `Sources/MacrecCore/Transcription/Persistence/JSONLTranscriptWriter.swift:122-143` | Existing JSONL schema already serialises model + language |
| 11 | `PrivacyDisclosureSheet` | `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift:30-301` | Existing `apple-cloud` body text, per-provider acknowledged key |

## Original Request

See `docs/design/refined-request-dual-transcription.md` for the full refined specification.

Verbatim user prompt (preserved for traceability):

> A very common situation for the application is the speakers to talk in Greek and mix English words inside their speech. I'm thinking if we can create a special, transcription mode, based on the Apple capabilities, where we are transcribing through two different channels at the same time:
> 1. The first channel is English, using Apple's local SDK (the on-device SpeechAnalyzer, which is the existing "Apple" provider in the app), aimed to detect English words.
> 2. The second channel is Greek, using the Apple Cloud provider (the existing "Apple Cloud" provider in the app — cloud, streaming, supports Greek + 57 locales).
>
> I do NOT want to change the existing live transcription option. I want to introduce a NEW "dual" transcription option, probably as a switch under the Live Transcription panel.
>
> Depending on which switch is selected (single live transcription vs dual), the panel below the switch must dynamically swap to show the options that apply to the selected mode. Single mode must keep its current UI exactly as it is today; dual mode shows whatever options dual mode needs.
