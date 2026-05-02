# Refined request — STT enhancements (Parakeet, Soniox diarization, source-split display)

> **Document type:** Design spec (output of the brainstorming pass).
> **Date:** 2026-05-02.
> **Scope:** macOS audio recorder (`macrec` CLI + `macrec-ui` menu-bar app).
> **Follow-up artifact:** `docs/design/plan-012-stt-enhancements.md` (to be produced by the `superpowers:writing-plans` skill).

---

## 1. Summary

This spec covers three independent but related STT enhancements to `macrec` / `macrec-ui`:

1. **Parakeet TDT V3 multilingual STT** is added as a new on-device transcription provider (`parakeet`), wired through the existing `TranscriptionProvider` factory and surfaced in the menu-bar app's provider picker. Integration is via the [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) Swift package, mirroring the architectural shape of the existing `whisperkit` provider (batch-only `actor`, lazy model load, ~600 MB first-launch download).
2. **Soniox speaker diarization** is enabled by default (the `enable_speaker_diarization` field is flipped from `false` to `true` in `SonioxConfigBuilder.defaults`) with a settings toggle that lets the user turn it back off without rebuilding. Speaker tags propagate through the segment shape and into all four sidecar formats (JSONL, TXT, SRT, VTT).
3. **Source-separated transcription** lifts the documented v1 `--transcribe-source both` limitation: when `both` is selected, the engine runs **two** transcription drivers in parallel — one for system audio, one for the microphone — producing two sidecar files (`.system.transcript.<ext>` + `.mic.transcript.<ext>`) and a new two-lane `LiveTranscriptPanel` layout that displays system and mic streams in independent, auto-scrolling lanes.

Each feature can ship in any order; they share zero state. They are bundled into a single spec because they all touch the transcription stack and we want one coherent doc for an implementation plan to derive from.

---

## 2. Out of scope

- **Parakeet in dual-mode.** Dual-mode (`--transcribe dual`) stays pinned to `apple` (Channel A) + `apple-cloud` (Channel B). Adding Parakeet as a dual-mode channel option is deferred.
- **Source-split inside dual-mode.** Combining `--transcribe dual` with per-source separation would produce a four-lane UI (Channel-A-system, A-mic, B-system, B-mic). That is not asked for and is out of scope.
- **Per-source provider selection.** When `--transcribe-source both` is used, both parallel drivers use the SAME provider id. Letting the system lane use Parakeet while the mic lane uses Soniox is deferred.
- **Draggable divider in the source-split UI.** Initial cut is fixed 50/50; a draggable divider is a follow-up issue.

---

## 3. Feature 1 — Parakeet TDT V3 multilingual provider

### 3.1 Provider definition

| Property            | Value                                                            |
|---------------------|------------------------------------------------------------------|
| `id`                | `parakeet`                                                       |
| `supportedModes`    | `[.batch]` (FluidAudio's pipeline is chunk-at-a-time)            |
| API key required    | No (on-device)                                                   |
| Default model id    | `parakeet-tdt-0.6b-v3` (multilingual; ~25 European languages)    |
| First-launch cost   | ~600 MB model download by FluidAudio (cached under Application Support) |
| Streaming surface   | Throws `MacrecError.transcriptionConfigConflict` (loud failure, mirrors `whisperkit`) |

### 3.2 SPM dependency

Add `https://github.com/FluidInference/FluidAudio` as a Swift Package Manager dependency on `MacrecCore` in `Package.swift`. Pin to a tagged release verified at implementation time. (FluidAudio is actively maintained and ships native-Swift CoreML wrappers around `parakeet-tdt-0.6b-v3`.)

### 3.3 Source files

- **New:** `Sources/MacrecCore/Transcription/Providers/ParakeetTranscriptionProvider.swift` — `actor` with the same lazy-load + dedup pattern as `WhisperKitTranscriptionProvider` (single load task, multiple concurrent first-callers `await` the same task, model reused for the lifetime of the recording session).
- **Modified:** `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift` — add `case "parakeet":` arm; add optional `parakeetModel: String?`, `parakeetLanguage: String?` fields to `TranscriptionProviderFactoryInput`.
- **Modified:** `Sources/MacrecCore/Config/ConfigResolver.swift` (or equivalent) — resolve `MACREC_PARAKEET_MODEL` and `MACREC_PARAKEET_LANGUAGE` through the four-tier env chain; admit `parakeet` to the allowed-providers list.
- **New:** `Sources/macrec-ui/Settings/Sections/ParakeetSettingsView.swift` — model id field + language hint field; persisted under `com.macrec.ui.parakeetModel` / `com.macrec.ui.parakeetLanguage`. No API key section. Mirrors `WhisperKitSettingsView`'s shape.
- **Modified:** `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift` — add `Text("Parakeet (on-device, multilingual)").tag("parakeet")`. `requiredKeyEnvVar` returns `nil` for `parakeet`.

### 3.4 Model resolution precedence

Precedence chain (highest first), exactly mirroring WhisperKit:

1. Parakeet-specific override `MACREC_PARAKEET_MODEL` (CLI: `--parakeet-model`).
2. Shared `MACREC_TRANSCRIBE_MODEL` (CLI: `--transcribe-model`).
3. Provider default: `parakeet-tdt-0.6b-v3`.

Language-hint resolution: bare ISO-639-1 from `MACREC_PARAKEET_LANGUAGE`, falling back to the truncated first BCP-47 entry in `--transcribe-language`, falling back to FluidAudio's auto-detect.

### 3.5 Documentation updates

- `docs/tools/macrec.md` — new row in the providers table (`parakeet | On-device multilingual… | _(none)_`) and a new `### Parakeet (on-device, multilingual)` subsection covering install, model size, supported language list, and first-launch latency.
- `docs/design/configuration-guide.md` — entries for `MACREC_PARAKEET_MODEL`, `MACREC_PARAKEET_LANGUAGE`.
- `CLAUDE.md` (project) — Tools section's `macrec` entry adds Parakeet to the listed providers.
- `docs/design/project-functions.md` — register the new functional capability under the next available FR-id.

### 3.6 Tests

- `ParakeetTranscriptionProviderTests` — happy-path transcription against a fixture wav, `samples.count < threshold` returns `""`, streaming surface throws.
- `TranscriptionProviderFactoryTests` — factory builds a `ParakeetTranscriptionProvider` for `providerId == "parakeet"`; respects the model resolution chain.
- `ConfigResolverParakeetTests` — `MACREC_PARAKEET_MODEL` four-tier resolution.

---

## 4. Feature 2 — Soniox speaker diarization

### 4.1 Wire-format change

`SonioxConfigBuilder.defaults` flips the default value of `enableSpeakerDiarization` from `false` to `true`. The field is already plumbed through `SonioxConfigMessage` (Codable key `enable_speaker_diarization`) and through the optional `SonioxToken.speaker` field (already declared but unused). No protocol-level change.

### 4.2 Config & precedence

Four-tier resolution as usual:

| Source                           | Key                                                |
|----------------------------------|-----------------------------------------------------|
| Shell env                        | `MACREC_SONIOX_DIARIZE` (`true` \| `false`)        |
| `~/.tool-agents/macrec/.env`     | `MACREC_SONIOX_DIARIZE=…`                          |
| `./.env`                         | `MACREC_SONIOX_DIARIZE=…`                          |
| CLI flag                         | `--soniox-diarize <bool>` on `macrec start`        |
| AppStorage (UI)                  | `com.macrec.ui.sonioxDiarize` (default `true`)     |

Default value is `true` at every layer when nothing is set. The `TranscriptionProviderFactoryInput` gains a new `sonioxDiarize: Bool?` field; `TranscriptionProviderFactory.build` passes it into a new `SonioxStreamingTranscriptionProvider(apiKey:model:diarize:logger:)` initializer.

### 4.3 Speaker propagation through the pipeline

- `SonioxToken.speaker` (existing nullable field) starts being populated by the server when diarization is on.
- `SonioxTokenAggregator` is updated to:
  - **Boundary rule:** when an incoming token's `speaker` differs from the active in-flight partial's `speaker`, finalise the current partial and start a new one. Each emitted segment carries exactly one speaker.
  - **Carry-through:** the active token's `speaker` is copied onto the emitted `TranscriptSegment`.
- `TranscriptSegment` (in `Sources/MacrecCore/Transcription/TranscriptSegment.swift`) gains a new optional field:
  ```swift
  public let speaker: String?
  ```
  Defaults to `nil`. Codable synthesis omits the field entirely when `nil`, so all existing JSONL fixtures and snapshot tests for non-Soniox providers stay byte-equivalent.

### 4.4 Sidecar format updates

| Format | Change when `speaker != nil` | Backward compat |
|--------|--------------------------------|-----------------|
| JSONL  | New optional key `"speaker":"<s>"` appended after `language` | Tests for non-diarized output are byte-identical |
| TXT    | Prefix the existing line content with `[<S>]` after the timestamp (e.g. `[00:00:01.230] [S1] hello`) | Single-source/non-diarized output unchanged |
| SRT    | Prefix the cue text with `<S>: ` (e.g. `S1: hello`) | Cue numbering unchanged |
| VTT    | Wrap cue text in a voice tag `<v S1>hello</v>` | Header unchanged |

A canonical helper `SpeakerSidecarLabel.label(for: speaker)` produces the textual representation (`S1`, `S2`, …) so the four formats agree on labelling and changes only land in one place.

### 4.5 UI surfaces

- **New:** `Sources/macrec-ui/Settings/Sections/SonioxSettingsView.swift` — mirrors `ElevenLabsSettingsView`. Contains a `Toggle("Diarize speakers", isOn: $sonioxDiarize)` with help text explaining the trade-off (extra column, marginally higher latency in some cases). Persisted under `com.macrec.ui.sonioxDiarize`.
- **Modified:** `Sources/macrec-ui/Settings/SettingsRootView.swift` — register the new section so it appears in the settings sidebar.
- **Modified:** `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift` — `segmentView` adds a small monospace chip rendering `segment.speaker` (e.g. `S1`) next to the existing language chip. Only rendered when non-`nil`.

### 4.6 Tests

- `SonioxConfigBuilderTests` — assert default is `true`; assert `false` override is honoured.
- `SonioxTokenAggregatorTests` — feed two tokens with different `speaker` values and assert two distinct segments are emitted, each carrying its own speaker.
- `TranscriptSegmentJSONLSnapshotTests` — extended fixtures for diarized & non-diarized paths (proves JSONL byte-equivalence for the non-diarized arm).
- `SonioxDiarizationFactoryTests` — `TranscriptionProviderFactoryInput.sonioxDiarize` four-tier resolution + factory wiring.

### 4.7 Documentation updates

- `docs/tools/macrec.md` — Soniox section: "Defaults" table flips the `Speaker diarization` row to `ON (overridable via MACREC_SONIOX_DIARIZE / --soniox-diarize)`, and a new "Speaker diarization" subsection covers the segment shape, sidecar format updates, and the per-format examples.
- `docs/design/configuration-guide.md` — entry for `MACREC_SONIOX_DIARIZE`.

---

## 5. Feature 3 — Source-separated transcription

### 5.1 Engine — lifting the `--transcribe-source both` v1 limitation

Today, `TranscriptionDispatcher` collapses `both` to `mixed` and produces a single segment stream tagged `.mixed`. The change replaces that collapse with a true dual-driver setup:

- When `RecordingOptions.transcribeSource == .both`, the dispatcher (or a new `DualSourceTranscriptionDispatcher` collaborator) instantiates **two** providers of the same id — one for system, one for mic.
- Each provider gets:
  - Its own `SourceBuffer` fed exclusively from the matching `SourceTag`.
  - Its own `Logger` labelled with `track=system` / `track=mic` so log lines stay disambiguable.
  - Its own per-track metrics struct (`TranscriptionMetrics` becomes per-track when `both` is active; aggregated metrics still surface for the post-stop summary).
- Emitted `TranscriptSegment`s are tagged with their actual `SourceTag` (`.system` or `.mic`) — never `.mixed` in this mode.

### 5.2 Provider-side compatibility audit

Each provider must support being instantiated twice in the same process. Status per provider:

| Provider           | Two-instance posture | Action |
|--------------------|----------------------|--------|
| `apple`            | `SpeechAnalyzer` instances are documented as independent. Validated by the existing dual-mode pipeline (which already runs Channel A + Channel B with the same family of APIs). | New unit test `AppleSpeechParallelInstancesTest` to lock the contract. If it fails on a future macOS update, the dispatcher falls back to round-robin sharing (deferred follow-up, NOT a blocker for this design). |
| `apple-cloud`      | Already runs two parallel `SFSpeechRecognizer` tasks in dual-mode. | No change. |
| `gemini`           | Independent per-chunk REST POSTs, no shared session state. | No change. |
| `whisperkit`       | Two independent `WhisperKit` actors, each with their own loaded pipeline. Memory cost is doubled (~1.2 GB) — documented in the user-facing docs. | No change. |
| `parakeet`         | Same shape as `whisperkit`. | No change. |
| `soniox`           | Two independent WebSocket connections. | No change (Soniox doesn't cap concurrent connections per-key on the standard tier). |
| `azure`            | Independent REST POSTs. | No change. |
| `azure-openai-realtime` | Two independent WebSocket sessions; each counted against the 60-min session boundary independently. | No change. |
| `elevenlabs`       | Concurrent-request quota cap (Free/Starter: 8). Two parallel POSTs leave headroom on free tier; a warning is logged at session start when `provider == elevenlabs && source == .both` so the user is aware. | Add a `Logger.warning` at dispatcher init. |

### 5.3 Sidecar files

`--transcribe-source both` produces TWO sidecar files. Naming reuses the existing `split` layout convention already documented in `docs/tools/macrec.md` line 599:

- `<basename>.system.transcript.<ext>` — only system-tagged segments.
- `<basename>.mic.transcript.<ext>` — only mic-tagged segments.

When `--layout split` is also active, sidecar files sit next to their matching audio file:

- `recording-….mic.m4a` ↔ `recording-….mic.transcript.<ext>`
- `recording-….system.m4a` ↔ `recording-….system.transcript.<ext>`

The v1-limitation paragraph at `docs/tools/macrec.md` lines 603–607 (`> v1 limitation — --transcribe-source both …`) is removed by this change.

### 5.4 UI — `LiveTranscriptPanel` three-way branch

The panel's `body` gains a third branch on top of the existing single/dual switch:

```swift
// pseudocode
switch (transcriptionMode, transcribeSource) {
case (.dual, _):                  DualLiveTranscriptView()        // unchanged
case (.single, .both):            SourceSplitTranscriptView()     // NEW
case (.single, _):                singleBody                      // unchanged (DT-INV)
}
```

`transcribeSource` is read from the existing AppStorage key `com.macrec.ui.transcribeSource` so the panel re-renders reactively when the user changes the source picker.

### 5.5 New view — `SourceSplitTranscriptView`

- **Path:** `Sources/macrec-ui/Views/Transcription/SourceSplitTranscriptView.swift`.
- **Composition:** vertical `VStack` of two `SourceLane(source:)` views with a fixed 50/50 height split.
- **`SourceLane`:** extracted from the existing `singleBody` so chrome, header, scroll behaviour, and language/speaker chips are shared. Each lane filters `recordingController.transcriptSegments` by `segment.source == .system` or `.mic` and runs its own `ScrollViewReader` with auto-scroll on segment count + `lastUpdated` changes.
- **Lane headers:** `System audio` and `Microphone`, styled like the existing dual-mode lane headers (`DualLiveTranscriptLane`).
- **DT-INV preservation:** when `transcribeSource != .both`, the existing `singleBody` renders byte-for-byte unchanged. A regression test asserts this.

### 5.6 Tests

- **`SourceSplitTranscriptViewTests` (snapshot)** — assert two distinct lanes when `source == .both` and segments include both `.system` and `.mic` tags; lanes filter correctly with no cross-contamination.
- **`LiveTranscriptPanelSingleModeTests` (extended)** — assert byte-equivalent rendering when `source ∈ {system, mic, mixed}` (DT-INV preservation across the three single-mode subcases).
- **`DualSourceTranscriptionDispatcherTests`** — feed interleaved system+mic audio, assert two segment streams with correct source tags, no cross-contamination.
- **`SourceSplitSidecarNamingTests`** — assert sidecar paths derive correctly for the four combinations of `{layout=mixed, layout=split} × source=both`.

### 5.7 Documentation updates

- `docs/tools/macrec.md`:
  - Remove the v1-limitation paragraph (lines 603–607).
  - Update the sidecar-naming table row for `--layout split + --transcribe-source both` to reflect that this mode is now fully supported.
  - Add a new "Source-split mode" subsection covering the two-sidecar output, the two-lane UI, and the per-provider compatibility notes from §5.2.
- `docs/design/project-functions.md` — register the lifted limitation under the next available FR-id (and close the v2-follow-up tracker in `Issues - Pending Items.md`).

---

## 6. Cross-cutting touch points

### 6.1 Dependencies

- New SPM dep: `FluidInference/FluidAudio` (added to `MacrecCore` target).
- No new external services or licenses beyond what each existing provider already requires.

### 6.2 Configuration variables added

| Variable                       | Default   | Layer(s)                                     |
|--------------------------------|-----------|----------------------------------------------|
| `MACREC_PARAKEET_MODEL`        | `parakeet-tdt-0.6b-v3` | env / .env / CLI (`--parakeet-model`) |
| `MACREC_PARAKEET_LANGUAGE`     | _(auto)_  | env / .env / CLI (`--parakeet-language`)     |
| `MACREC_SONIOX_DIARIZE`        | `true`    | env / .env / CLI (`--soniox-diarize`)        |
| `com.macrec.ui.parakeetModel`  | `parakeet-tdt-0.6b-v3` | AppStorage (UI settings)         |
| `com.macrec.ui.parakeetLanguage` | _(empty)_ | AppStorage (UI settings)                   |
| `com.macrec.ui.sonioxDiarize`  | `true`    | AppStorage (UI settings)                     |

All three env vars resolve through the canonical four-tier chain. None replaces any existing variable; all are additive.

### 6.3 Files added

```
Sources/MacrecCore/Transcription/Providers/ParakeetTranscriptionProvider.swift
Sources/MacrecCore/Transcription/SpeakerSidecarLabel.swift
Sources/macrec-ui/Settings/Sections/ParakeetSettingsView.swift
Sources/macrec-ui/Settings/Sections/SonioxSettingsView.swift
Sources/macrec-ui/Views/Transcription/SourceSplitTranscriptView.swift
Sources/macrec-ui/Views/Transcription/SourceLane.swift          (extracted from LiveTranscriptPanel)
Tests/MacrecCoreTests/ParakeetTranscriptionProviderTests.swift
Tests/MacrecCoreTests/SonioxTokenAggregatorDiarizationTests.swift
Tests/MacrecCoreTests/DualSourceTranscriptionDispatcherTests.swift
Tests/MacrecCoreTests/SourceSplitSidecarNamingTests.swift
Tests/MacrecUIKitTests/SourceSplitTranscriptViewTests.swift
Tests/MacrecUIKitTests/AppleSpeechParallelInstancesTest.swift
docs/design/refined-request-stt-enhancements.md      (this file)
docs/design/plan-012-stt-enhancements.md             (produced by writing-plans)
```

### 6.4 Files modified (incomplete list — implementation plan will enumerate)

```
Package.swift
Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift
Sources/MacrecCore/Transcription/TranscriptSegment.swift
Sources/MacrecCore/Transcription/TranscriptionDispatcher.swift
Sources/MacrecCore/Transcription/Live/Soniox/SonioxConfigBuilder.swift
Sources/MacrecCore/Transcription/Live/Soniox/SonioxConfigMessage.swift
Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift
Sources/MacrecCore/Transcription/Live/Soniox/SonioxStreamingTranscriptionProvider.swift
Sources/MacrecCore/Transcription/Persistence/<jsonl|txt|srt|vtt writers>
Sources/MacrecCore/Config/ConfigResolver.swift
Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift
Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift
Sources/macrec-ui/Settings/SettingsRootView.swift
docs/tools/macrec.md
docs/design/configuration-guide.md
docs/design/project-functions.md
docs/design/project-design.md
CLAUDE.md
Issues - Pending Items.md
```

---

## 7. Acceptance criteria (per feature)

### 7.1 Parakeet

- AC-PK-1: `macrec start --transcribe parakeet --output …` produces an audio file AND a `.transcript.<ext>` sidecar populated by Parakeet.
- AC-PK-2: First-launch downloads the ~600 MB model and logs `info` lines around the download phase; subsequent launches reuse the cached model.
- AC-PK-3: `MACREC_PARAKEET_MODEL` overrides the default; `MACREC_TRANSCRIBE_MODEL` is honoured as a lower-precedence fallback.
- AC-PK-4: `parakeet` appears in the `TranscriptionPicker` dropdown; selecting it does NOT show the missing-API-key affordance.
- AC-PK-5: `openStreamingSession(...)` throws `transcriptionConfigConflict` (loud failure on the streaming surface).

### 7.2 Soniox diarization

- AC-SD-1: `macrec start --transcribe soniox …` (no diarization-related flags) produces JSONL segments containing a `speaker` field.
- AC-SD-2: Setting `MACREC_SONIOX_DIARIZE=false` (or `--soniox-diarize false`) suppresses the `speaker` field from the outgoing config message AND from emitted segments.
- AC-SD-3: The new `SonioxSettingsView` toggle controls the AppStorage key `com.macrec.ui.sonioxDiarize`; the menu-bar app starts new recordings with the toggle's current value.
- AC-SD-4: A two-speaker conversation produces at least two distinct segments where `speaker` differs across consecutive segments at speaker-change boundaries.
- AC-SD-5: All four sidecar formats (JSONL, TXT, SRT, VTT) carry the speaker label when present, in the format documented in §4.4.
- AC-SD-6: Non-Soniox provider sidecars are byte-equivalent to today (no `speaker` key, no `[S?]` prefix).

### 7.3 Source-split

- AC-SS-1: `macrec start --transcribe-source both …` produces TWO sidecar files (`.system.transcript.<ext>` + `.mic.transcript.<ext>`).
- AC-SS-2: Each sidecar contains ONLY segments tagged with the matching `SourceTag` — no cross-contamination.
- AC-SS-3: The `LiveTranscriptPanel` renders the new two-lane `SourceSplitTranscriptView` when `transcribeSource == .both` and `transcriptionMode == .single`.
- AC-SS-4: The `LiveTranscriptPanel` renders the existing single-lane `singleBody` byte-equivalently when `transcribeSource ∈ {system, mic, mixed}` (DT-INV preservation).
- AC-SS-5: Dual-mode (`--transcribe dual`) is unaffected — `DualLiveTranscriptView` continues to render unchanged.
- AC-SS-6: The v1-limitation paragraph in `docs/tools/macrec.md` is removed.
- AC-SS-7: When `provider == elevenlabs && source == .both`, a `Logger.warning` line at session start mentions the concurrent-request quota.

---

## 8. Risks & open questions (carry-forward)

- **R-STT-1 (Parakeet model size):** the ~600 MB first-launch download blocks transcription on the first recording. Documented in user-facing docs; no progress indicator in the popover for v1 (matches WhisperKit's posture). Tracked as a follow-up if user feedback warrants it.
- **R-STT-2 (Two-instance Apple Speech contract):** assumed independent based on Apple docs and dual-mode evidence. `AppleSpeechParallelInstancesTest` locks the contract; if it fails on a future macOS update we degrade gracefully (round-robin sharing) but this is deferred work.
- **R-STT-3 (WhisperKit/Parakeet doubled memory in `both` mode):** ~1.2 GB total when both lanes load the multilingual model. Documented; expected to be acceptable on the target user's machine (32 GB RAM) but flagged for users on lower-spec Macs.
- **R-STT-4 (ElevenLabs concurrent-request cap on Free/Starter):** `both` mode doubles parallel POSTs. We log a warning rather than block; users on those tiers may see HTTP 429s. Documented in `configuration-guide.md` §LT-EL.
- **OQ-STT-1:** Does FluidAudio expose a per-chunk language hint we should plumb? To be confirmed at implementation time; if not, `MACREC_PARAKEET_LANGUAGE` becomes informational only and we log a notice.

---

## 9. Sequencing

The three features are independent; an implementation plan can choose to ship them in any order or in parallel slices. Recommended order based on risk profile:

1. **Soniox diarization** — smallest blast radius, well-understood surface change, immediate user value.
2. **Parakeet provider** — additive, isolated to its own files; verifies the FluidAudio dependency in production before the source-split work depends on Parakeet behaving correctly under two-instance load.
3. **Source-split** — largest blast radius (touches dispatcher, sidecar writer, live panel). Benefits from Parakeet being already validated as a single-instance provider before being asked to run two-instance.

---

## 10. References

- `docs/tools/macrec.md` (current behaviour and v1 limitations).
- `docs/design/project-design.md` §LT-1 .. §LT-10, §SX-3 (transcription architecture, Soniox wire schema).
- `docs/design/refined-request-soniox-streaming.md` (Soniox v1 scope; this spec extends it).
- `docs/design/refined-request-additional-stt-engines.md` (provider-extensibility patterns).
- `docs/design/refined-request-dual-transcription.md` (dual-channel UI patterns reused in §5.5).
- `Sources/MacrecCore/Transcription/Providers/WhisperKitTranscriptionProvider.swift` (architectural template for §3.3).
- FluidAudio Swift package: `https://github.com/FluidInference/FluidAudio`.
- Parakeet TDT V3 model card: `https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3`.
