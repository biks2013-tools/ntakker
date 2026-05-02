# Refined Request: Dual-Provider Live Transcription Mode (Apple On-Device English + Apple Cloud Greek)

## Category
Development (feature addition — `MacrecCore` transcription pipeline + `macrec-ui` Live Transcription panel; potential CLI surface in `macrec`).

## Objective
Introduce a NEW **"Dual" live-transcription mode** to `recording-tool` that runs two
already-shipped Apple providers in parallel against the same captured audio
stream — the on-device `apple` provider configured for English (strong on
English code-switched words) and the `apple-cloud` provider configured for
Greek (`el-GR`, the only Apple path that supports Greek today) — and surfaces a
unified, dual-channel live transcript in the UI plus a sidecar transcript file.
The existing Single-provider Live Transcription mode must remain available
unchanged; the user toggles between Single and Dual via a new switch under the
Live Transcription panel, and the panel below the switch dynamically swaps to
show only the controls relevant to the selected mode.

## Scope

### In scope
- A new operating mode of the existing live-transcription subsystem: **Dual**,
  in addition to the existing **Single** mode.
- A new UI switch (segmented picker / toggle / equivalent) inside the Live
  Transcription popover/panel of `macrec-ui` to choose between Single and Dual.
- A panel-swap behaviour: when the switch is in "Single", show the existing
  Live Transcription controls EXACTLY as they are today; when the switch is in
  "Dual", show a Dual-mode control set instead.
- A Dual-mode runtime that:
  - Tees the same captured audio source (microphone / system / mixed —
    selectable in Dual mode) to TWO concurrent transcription sessions.
  - Channel A: `apple` provider, locale forced to an English variant
    (`en-US` default, user-selectable from English variants supported by
    `SpeechAnalyzer`).
  - Channel B: `apple-cloud` provider, locale forced to `el-GR` by default
    (user-selectable from `apple-cloud` supported locales, but constrained so
    Channel A and Channel B are always different locales / different
    providers).
- A unified live-transcript view (in the macrec-ui Live Transcript panel) that
  visually distinguishes the two channels (label + colour or column) and
  surfaces partials and finals from each independently.
- Sidecar transcript file output for Dual mode (format-agnostic at the spec
  level — see acceptance criteria for the format requirements). The sidecar
  must preserve the channel/locale labelling so a downstream merger or human
  reviewer can reconstruct which channel produced which segment.
- Privacy / disclosure handling: because Channel B uses `apple-cloud`, the
  existing one-time privacy disclosure sheet for cloud providers must continue
  to fire when Dual is selected for the first time (or when the user toggles
  from Single→Dual without ever having accepted the `apple-cloud` disclosure).
- Cost / latency / status indicators per channel in the UI (mirroring how the
  Single-mode panel surfaces these today), so the user can see each channel's
  latency and the cloud channel's incremental cost independently.
- CLI surface: extend `macrec` so the same Dual mode is reachable from the
  command line (consistent with how every other transcription option is
  reachable from both binaries). The exact flag shape is a Phase-5 design
  question (see Open Questions).
- Documentation: update `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`, the
  Tools section of project `CLAUDE.md`, `docs/design/project-design.md`, and
  `docs/design/project-functions.MD`.
- Tests: add coverage in `test_scripts/` for (a) the dual-session orchestrator
  (audio tee, parallel session lifecycles, error isolation) and (b) the
  sidecar writer with a two-channel input.

### Out of scope
- **Modifying the Single-mode UI or its runtime behaviour.** Single mode must
  remain pixel- and behaviour-identical to today. (HARD CONSTRAINT — see
  Constraints.)
- Adding any new transcription providers. The two providers used by Dual mode
  (`apple` and `apple-cloud`) are already implemented and shipping (per
  PLAN-007-DONE-14 in `Issues - Pending Items.md`).
- Cross-channel deduplication / merging into a single linear transcript stream
  via NLP. The two channels remain visually and structurally separate in v1.
  (A later enhancement may add a merge pass; out of scope here.)
- Changing the audio capture pipeline (`ScreenCaptureKit` system-audio +
  `AVFoundation` microphone). Dual mode consumes the existing capture output
  via a tee/fan-out, it does not re-architect capture.
- Adding a "Dual" mode that combines providers other than `apple` +
  `apple-cloud` (e.g. Soniox + Gemini). Generalising the dual mechanism to
  arbitrary provider pairs is a possible future extension but is NOT a
  requirement for this work.
- More than two simultaneous channels (no triple/N-way mode).
- Translation between the two channels.

## Requirements

### Functional requirements

1. **FR-1 — Mode switch.** The Live Transcription panel in `macrec-ui` MUST
   expose a binary mode control with values "Single" (default, pre-existing
   behaviour) and "Dual". The control MUST be located inside / immediately
   above the Live Transcription panel so that the panel below it can swap
   based on selection.

2. **FR-2 — Single mode preservation.** When the mode control is set to
   "Single", the panel MUST render the EXISTING Live Transcription controls
   (provider picker labelled `Transcribe`, audio Source picker, Transcript
   Format picker, Language picker) with the EXACT current layout, defaults,
   labels, and behaviour. No regressions, no relabels, no reorderings.

3. **FR-3 — Dual mode controls.** When the mode control is set to "Dual",
   the panel MUST render a Dual-specific control set that includes at minimum:
   - Audio Source picker (Mixed / Microphone / System) — same options as
     Single mode.
   - Channel A read-out: provider = `Apple (on-device)`, with a locale picker
     constrained to English variants supported by `apple`. Default: `en-US`.
   - Channel B read-out: provider = `Apple Cloud`, with a locale picker
     constrained to `apple-cloud` supported locales (the `SFSpeechRecognizer`
     supportedLocales set). Default: `el-GR`.
   - Sidecar Transcript Format picker (the same set offered in Single mode:
     `jsonl`, `txt`, `srt`, `vtt`).
   - Any per-channel toggles needed to disable/enable a single channel
     temporarily (Phase-5 design call — see Open Questions).

4. **FR-4 — Parallel execution.** Selecting Dual and starting a recording
   MUST start BOTH transcription sessions concurrently against the same
   captured audio. Failure of one channel MUST NOT terminate the other; the
   failing channel surfaces an inline error in its lane while the other
   continues.

5. **FR-5 — Audio fan-out.** The capture pipeline MUST deliver identical
   audio frames to both sessions with no measurable drift between channels
   (channel A and channel B should see the same wall-clock-aligned audio).

6. **FR-6 — Live transcript UI.** The live transcript area MUST render two
   visually distinct lanes (e.g. labelled "EN — Apple" and "EL — Apple
   Cloud"), each showing partial and final segments from its channel as
   they arrive, in chronological order within the lane.

7. **FR-7 — Sidecar output.** When the recording stops, the system MUST
   write a sidecar transcript file alongside the audio file that contains
   BOTH channels' segments, each tagged with channel label, locale, segment
   start/end timestamps, and `isFinal` flag. The format MUST be the
   user-selected one from FR-3. (For `jsonl`, channel + locale are first-class
   fields per record. For `srt`/`vtt`, channel + locale appear in the cue
   speaker tag or note line. For `txt`, segments are line-prefixed with
   the channel label.)

8. **FR-8 — Privacy disclosure.** The first time the user enables Dual mode
   (or selects `apple-cloud` indirectly through Dual) without previously
   accepting the `apple-cloud` privacy disclosure, the existing disclosure
   sheet MUST appear and the user must accept before the recording can start.

9. **FR-9 — Per-channel telemetry.** The UI MUST display per-channel
   latency (e.g. partial-arrival lag) and, for the cloud channel, an
   incremental cost or quota indicator, mirroring the Single-mode display.

10. **FR-10 — CLI parity.** The `macrec` CLI MUST expose Dual mode through
    a flag (e.g. `--transcribe dual` plus `--transcribe-dual-en-locale` and
    `--transcribe-dual-el-locale`, or an equivalent design — see Open
    Questions). The CLI behaviour MUST be functionally equivalent to the
    UI Dual mode (same audio fan-out, same sidecar output).

11. **FR-11 — Stop / pause / split semantics.** Pause, resume, stop, and
    split actions MUST be applied to BOTH channels atomically — i.e. pausing
    pauses both, splitting starts a new sidecar segment for both.

### Non-functional requirements

12. **NFR-1 — No regression to Single mode.** The Single-mode runtime path,
    UI layout, defaults, and on-disk artefacts MUST be byte-identical to
    today's behaviour for any previously valid Single-mode invocation.

13. **NFR-2 — Channel isolation.** A crash, exception, or quota error in
    one channel MUST NOT propagate to the other. Each channel has its own
    `Task` lifecycle and error surface.

14. **NFR-3 — Audio backpressure.** The audio fan-out MUST NOT block the
    capture pipeline if one consumer (e.g. the cloud channel under network
    pressure) falls behind. Slow channels are isolated via bounded buffers
    and surface a "lagging" indicator rather than stalling capture.

15. **NFR-4 — Memory footprint.** Two concurrent sessions must not raise
    steady-state memory usage above ~2× a single Single-mode session
    (sanity check, no fixed numeric SLA — just no leaks, no unbounded
    buffer growth across long recordings).

16. **NFR-5 — macOS-26 compatibility.** Dual mode MUST work under the
    project's existing deployment target (macOS 26, per project CLAUDE.md
    Exception 002). It does not need to be back-ported to macOS 14/15.

17. **NFR-6 — Permissions.** Dual mode requires both the on-device
    SpeechAnalyzer prerequisites (already in place) AND the
    `NSSpeechRecognitionUsageDescription` + Speech Recognition TCC grant
    that `apple-cloud` already needs. The system MUST surface a clear
    actionable error (not a crash) if either is missing.

18. **NFR-7 — Run-mode caveat.** The known `apple-cloud` constraint —
    that ad-hoc-signed raw-binary launches of `macrec-ui` cannot call
    `SFSpeechRecognizer.requestAuthorization` without SIGABRT, so the
    user must run from the `dist/macrec-ui.app` bundle — applies to Dual
    mode unchanged. The Dual-mode error path must reuse the existing
    actionable error text.

## Constraints

### Project / convention constraints
- Implementation language: **Swift** (project Exception 001).
- Deployment target: **macOS 26** (project Exception 002).
- Project layout: changes land in `Sources/MacrecCore/Transcription/` and
  `Sources/macrec-ui/Views/Transcription/` (and `Sources/macrec/` for the CLI
  surface). No restructuring of these subsystems beyond what is required.
- All plan files MUST be saved as `docs/design/plan-xxx-<slug>.md`.
- Project design doc and project functions doc MUST be updated.
- `Issues - Pending Items.md` MUST be updated as work proceeds (and at
  completion the entry moves to the Completed section).
- No new fallback for missing config — if a Dual-mode locale is not provided,
  raise a clear error (project rule: never invent default fallbacks for
  required configuration). Defaults explicitly listed in this spec
  (`en-US` for Channel A, `el-GR` for Channel B) ARE allowed defaults
  because they are spec-defined, not silent fallbacks.

### Hard product constraints
- **Single mode UI and behaviour MUST NOT change.** This is a verbatim
  restatement of the user's directive: "I do NOT want to change the existing
  live transcription option." Any PR that alters Single-mode rendering,
  defaults, or output is non-conformant.

### Technical constraints
- Channel B (`apple-cloud`) is subject to Apple's documented quotas:
  1,000 requests/hour/device and ~60 s of audio per recognition task. The
  existing `AppleCloudStreamingSession` already auto-rotates tasks at 55 s
  — Dual mode MUST inherit this behaviour unmodified.
- Channel A (`apple` / SpeechAnalyzer) requires the macOS-26 on-device
  English asset, which is in the SpeechAnalyzer launch set. No download
  prompt is anticipated for `en-US`.
- Audio sample rate / format: the dual fan-out must produce buffers in the
  format each provider expects. Format conversion (if any) must happen
  per-channel, downstream of the tee.

## Acceptance Criteria

Each criterion is testable and must pass before the work is considered done.

1. **AC-1 (Single preserved).** With the new code merged, opening the Live
   Transcription panel in `macrec-ui` and leaving the new mode switch on
   "Single" renders the panel identically to a build from immediately before
   this work (visual diff acceptable as evidence; field labels, picker
   options, and defaults match exactly). Equivalent CLI invocations (e.g.
   `macrec --transcribe apple --language en-US ...`) produce byte-identical
   sidecar output to the pre-change build.

2. **AC-2 (Switch swaps panel).** Toggling the mode switch from "Single" to
   "Dual" swaps the panel content to the Dual control set with no app
   restart and no recording in progress required. Toggling back restores the
   Single control set with previously entered Single-mode values intact
   (do not lose state on round-trip).

3. **AC-3 (Dual starts both channels).** Starting a recording in Dual mode
   with default locales (Channel A=`en-US`, Channel B=`el-GR`) produces:
   - Two active transcription sessions visible in logs / status.
   - Live partials appearing in BOTH lanes within the latency budget each
     provider already has in Single mode.

4. **AC-4 (Channel isolation).** Forcing Channel B to error (e.g. by
   disabling network mid-recording, or by selecting an unsupported locale
   for `apple-cloud`) leaves Channel A continuing to produce transcripts
   and the recording itself unaffected. The Channel-B lane shows an
   actionable error state.

5. **AC-5 (Sidecar output).** A Dual-mode recording produces a single
   sidecar transcript file in the user-selected format, containing entries
   from both channels with channel + locale + timestamps + `isFinal`. For
   `jsonl`, the file is line-by-line valid JSON with stable field names
   (documented in `docs/tools/macrec.md`).

6. **AC-6 (Privacy disclosure).** A user who has never accepted the
   `apple-cloud` disclosure sees the disclosure sheet exactly once when
   they first switch to Dual and attempt to start a recording. After
   acceptance, subsequent Dual recordings do not re-prompt.

7. **AC-7 (Pause/resume/split atomic).** Pause, resume, and split actions
   issued during a Dual recording apply to both channels atomically — no
   case where one channel keeps streaming while the other is paused.

8. **AC-8 (CLI parity).** A `macrec` invocation in Dual mode produces
   functionally equivalent output (same channel labelling, same sidecar
   schema) to the UI Dual mode for the same audio source and locales.

9. **AC-9 (Permissions error path).** Running Dual on a machine that has
   not granted Speech Recognition TCC produces a clear error in the lane
   for Channel B (and the existing actionable message), not a crash, and
   does not prevent Channel A from recording.

10. **AC-10 (Tests pass).** New tests under `test_scripts/` cover:
    - Audio fan-out delivers identical buffers to both channels.
    - Channel A and Channel B lifecycles are independent (one error
      doesn't terminate the other).
    - Sidecar writer correctly serialises a two-channel input in each of
      the four sidecar formats.

11. **AC-11 (Documentation updated).** `docs/tools/macrec.md`,
    `docs/tools/macrec-ui.md`, project `CLAUDE.md` Tools section
    descriptions, `docs/design/project-design.md`, and
    `docs/design/project-functions.MD` are updated to describe Dual mode.
    `Issues - Pending Items.md` reflects the work and final status.

## Assumptions

- **A-1 (Existing investigation reused).** The reference document at
  `docs/reference/apple-cloud-stt-investigation-2026-05.md` accurately
  describes the `apple-cloud` provider's capabilities, locale set,
  quotas, and permission model. Downstream phases SHOULD treat it as
  authoritative for the cloud channel's behaviour rather than re-investigate.
  Basis: explicitly flagged by the requester as the existing investigation
  to leverage.

- **A-2 (Capture pipeline tee is feasible).** The current `MacrecCore`
  capture path can have an additional consumer attached (a fan-out / tee)
  without re-architecting capture. Basis: capture is already producing
  buffers for one transcription session AND for the audio file writer, so
  multi-consumer dispatch is already a property of the pipeline.
  Implementation phase will confirm with code inspection.

- **A-3 (Default locales).** `en-US` for Channel A and `el-GR` for Channel
  B are the defaults, since the user's stated use case is "Greek with
  English words sprinkled in". Users may change them in the Dual control
  set. Basis: the user's explicit description of the target use case.

- **A-4 (No translation / no merge).** The two channels remain visually
  separate; the v1 deliverable does not attempt to merge English words
  detected by Channel A into the Greek transcript stream of Channel B.
  Basis: spec scope decision, surfaced to the user as Out of Scope.

- **A-5 (Same sidecar formats).** Dual mode supports the same four
  sidecar formats as Single mode (`jsonl`, `txt`, `srt`, `vtt`). The
  schema extensions for channel/locale tagging are additive in `jsonl`,
  encoded via speaker/note conventions in `srt`/`vtt`, and via line
  prefixes in `txt`. Basis: minimises new format work; matches existing
  user expectations.

- **A-6 (Run-mode caveat unchanged).** The `apple-cloud` SIGABRT-on-raw-
  binary caveat documented in PLAN-007-DONE-14 still applies to Dual
  mode and does not require a new mitigation in this work. Basis: same
  underlying provider, same OS behaviour.

## Open Questions

These remain unresolved and MUST be answered (or explicitly punted) during
the design phase (Phase 5). They are not blockers for the spec itself.

- **OQ-1 — Switch control type.** The user said "probably as a switch under
  live transcription". Phase 5 should propose between (a) a `SegmentedControl`
  ["Single", "Dual"], (b) a `Toggle` "Dual mode", or (c) a third location/style
  (e.g. a sub-section header). Pick the option that best preserves the
  existing Single layout per the hard constraint.

- **OQ-2 — Per-channel disable.** Should Dual mode allow temporarily
  disabling one channel without leaving Dual mode (e.g. to mute Channel A
  during a section that is purely Greek)? If yes, add a per-channel
  enable toggle to the Dual panel.

- **OQ-3 — CLI flag shape.** Pick the precise flag spelling for the CLI
  Dual surface (e.g. `--transcribe dual --dual-locale-a en-US
  --dual-locale-b el-GR` vs `--transcribe-dual` boolean + reuse of
  existing locale flags). Must be consistent with existing
  `macrec --transcribe ...` ergonomics.

- **OQ-4 — Sidecar channel labelling for `srt`/`vtt`.** SRT/VTT do not
  natively model "channel". Phase 5 should pick a convention (e.g. WebVTT
  `<v EN>` / `<v EL>` voice tags, or two separate cue blocks tagged with
  speaker prefixes). Document the choice.

- **OQ-5 — Display of the unified live transcript.** Phase 5 should
  decide between (a) two stacked lanes, (b) two side-by-side columns,
  (c) a single chronological feed with a coloured channel chip per
  segment. Driven by readability under the existing macrec-ui popover
  width.

- **OQ-6 — Future extension hook.** Should the Dual orchestrator be
  designed generically (any pair of providers + any pair of locales) or
  specifically (`apple` + `apple-cloud` only)? Generic is more code now
  but cheaper to extend later. Pick one in Phase 5 and document the
  reasoning.

## Reference Material

- `docs/reference/apple-cloud-stt-investigation-2026-05.md` — authoritative
  Apple-cloud STT investigation (verdict, API surface, TCC, quotas, locale
  set). Reuse rather than re-investigate the cloud channel's capabilities.
- `Issues - Pending Items.md` → PLAN-007-DONE-14 — record of the
  `apple-cloud` provider implementation, including the run-mode SIGABRT
  caveat that still applies.
- Existing plans: `plan-003` (live transcription), `plan-005` (Apple
  SpeechAnalyzer streaming), `plan-006` (Soniox), `plan-007` (additional
  STT engines including Apple Cloud).
- Tools docs: `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`.

## Original Request

> A very common situation for the application is the speakers to talk in Greek and mix English words inside their speech. I'm thinking if we can create a special, transcription mode, based on the Apple capabilities, where we are transcribing through two different channels at the same time:
>
> 1. The first channel is English, using Apple's local SDK (the on-device SpeechAnalyzer, which is the existing "Apple" provider in the app), aimed to detect English words.
> 2. The second channel is Greek, using the Apple Cloud provider (the existing "Apple Cloud" provider in the app — cloud, streaming, supports Greek + 57 locales).
>
> I do NOT want to change the existing live transcription option. I want to introduce a NEW "dual" transcription option, probably as a switch under the Live Transcription panel.
>
> Depending on which switch is selected (single live transcription vs dual), the panel below the switch must dynamically swap to show the options that apply to the selected mode. Single mode must keep its current UI exactly as it is today; dual mode shows whatever options dual mode needs.
>
> The user wants me to investigate whether this is feasible, recommend an approach, and then implement it through the full development workflow.
>
> CLARIFICATIONS GATHERED:
> - "Claude Apple API" was a misnomer. The user meant "Apple Cloud" — an existing transcription provider already integrated in the app (per the Live Transcription panel screenshot shared by the user, labelled "Apple Cloud (cloud, streaming, Greek + 57 locales)" and per the recent commit "apple cloud added").
> - Both providers needed for the dual mode are ALREADY implemented and shipping in the app — this work is about RUNNING TWO PROVIDERS IN PARALLEL on the same audio stream (one for English locale, one for Greek locale) and presenting both transcripts in a unified panel, NOT about adding new providers.
> - The existing Live Transcription panel currently has fields: Transcribe (provider picker), Source (audio source picker — Mixed/Microphone/System), Transcript format (jsonl/txt/srt/vtt), Language (locale picker). When the new "dual" mode is selected, the panel should swap to a different set of controls appropriate for dual operation.
> - Goal: capture Greek speech that is sprinkled with English words (a common code-switching pattern), and produce a transcript that correctly transcribes both languages — Apple's local SpeechAnalyzer is strong on English, Apple Cloud is strong on Greek + 57 other locales.
