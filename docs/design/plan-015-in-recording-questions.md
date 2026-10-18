---
plan: 015
title: In-Recording Questions — Pattern C Popover Redesign
status: implementing
created: 2026-05-12
imported-to-master: 2026-05-13
source-branch: requirements
design-pack: plan-015-in-recording-questions/
---

# plan-015 — In-Recording Questions (Pattern C: Switch)

The full design package — requirements, wireframes, mockups, and the
exploration-archive interactive mock — lives in the sibling folder
[`plan-015-in-recording-questions/`](./plan-015-in-recording-questions/).
This file is the conventional `plan-XXX-*.md` index entry **plus** the
implementation roadmap (phases + per-phase task list).

## What this plan delivers

A redesign of the `macrec-ui` menu-bar popover and a companion
**Save Transcript** flow that lets the user ask questions about the live
recording while it is in progress, see streamed answers in the same popover,
and save the audio + transcript + Q&A artifacts to `~/Recordings/<folder>/`
when the recording stops.

The chosen UI direction is **Pattern C — Switch (segmented mode toggle)**
with three concrete layout commitments:

1. **Segmented mode toggle at the top** — toggles the popover body between
   **Transcription** (engine + language picker + live transcript pane —
   default) and **Asking** (Q&A input + streaming answer history). Both
   streams continue to accumulate in the background when the other mode is
   on screen.
2. **Mic + system-audio signal indicators at the bottom** in a status-bar
   layout, with animated bouncing bars while audio flows, so the recording
   state is always glance-able regardless of which mode the body is in.
3. **Stop → [ New Session ][ Save… ]** — the footer's primary red `Stop`
   button is replaced by a two-button pair after Stop. `Save…` opens an
   in-popover folder-name dialog (default `recording-YYYY-MM-DD-HH-MM`) and
   writes the audio, transcript sidecar, and Q&A sidecar to
   `~/Recordings/<folder-name>/`. `New Session` opens a 3-choice modal
   (Save-and-new / Discard-and-new / Cancel) that drives `clearSession()`.

## Design pack contents

| File                                                                 | Purpose                                                                                              |
|----------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| [`plan-015-in-recording-questions/requirements.md`](./plan-015-in-recording-questions/requirements.md)         | Authoritative requirements + acceptance criteria + view-navigation rationale (Patterns A/B/C/D table). |
| [`plan-015-in-recording-questions/wireframes.md`](./plan-015-in-recording-questions/wireframes.md)             | Per-state wireframes for the popover body, footer transitions, Save dialog states.                    |
| [`plan-015-in-recording-questions/mockups/current-state.html`](./plan-015-in-recording-questions/mockups/current-state.html) | Reference: today's popover (loads `../mockups/popover-redesign.html` via iframe).                    |
| [`plan-015-in-recording-questions/mockups/target-state.html`](./plan-015-in-recording-questions/mockups/target-state.html)   | Chosen target — Pattern C + bottom indicators + Save flow.                                            |
| [`plan-015-in-recording-questions/mock/index.html`](./plan-015-in-recording-questions/mock/index.html)         | Exploration archive — earlier Pattern D (Combined-Timeline) interactive mock, kept for context.       |

## Visual baseline

All new surfaces extend the popover-redesign primitives at
[`docs/design/mockups/popover-redesign.html`](./mockups/popover-redesign.html)
— same `.popover` frame, same CSS-variable token sets, same row primitives.
If a surface would introduce a control with no ancestor in the baseline, the
requirements doc says: stop and ask whether an existing primitive can be
repurposed.

---

## Implementation roadmap (phased)

The requirements doc enumerates 60+ FR-IRQ items. Delivering all of them in a
single pass is unrealistic and unsafe — every change to the popover risks the
recording-integrity invariant (NFR-IRQ-Audio-Non-Blocking). The work is
therefore phased so each phase ships a runnable, recording-safe build.

### Phase 1 — Pure UI shell of Pattern C *(this session)*

The visual restructure of the popover. No LLM, no real file writes, no global
hotkey, no floating overlay. The surface looks like the target mockup and
exercises all the new controls — Save and Q&A are stubbed.

| # | Task | FR-IRQ refs |
|---|------|-------------|
| 1.1 | Resize popover bounds to 480 default / 440-760 × 440-820 | FR-IRQ-59..61 |
| 1.2 | Top segmented control `Transcription / Asking` (⌘1, ⌘2) | FR-IRQ-43, FR-IRQ-47 |
| 1.3 | Engine & Language collapsed by default, summary-row + caret | FR-IRQ-44, FR-IRQ-44a |
| 1.4 | Asking-mode shell — empty state + input row pinned bottom (stub answers) | FR-IRQ-45 (UI only) |
| 1.5 | Bottom status bar — bouncing mic + sys bars + state pill + clock + action area | FR-IRQ-40..42, FR-IRQ-48 |
| 1.6 | New-Session modal + `clearSession()` with fade | FR-IRQ-55..58 |
| 1.7 | Save dialog stub — folder-name field + path preview + file list (no write) | FR-IRQ-49 (UI only) |
| 1.8 | Rewire `RootView` composition + smoke `swift build` | — |

**Phase 1 acceptance.** Open the menu-bar app. Default mode is Transcription
with the engine row collapsed and the live transcript pane filling the body.
The bottom status bar shows bouncing mic + sys bars while recording, a red
Stop button on the right. ⌘2 switches to Asking; the input row is at the
bottom. Press Stop → the right-side action becomes `[ New Session ][ Save… ]`.
Save opens the dialog with the right default folder name. New Session opens
the 3-choice modal; Discard runs `clearSession()` with the fade. The popover
is resizable in both axes within the new bounds.

### Phase 2 — Save flow → real folder write

Wire FR-IRQ-49..53 to an actual `~/Recordings/<folder>/` write:
`transcript.md`, `qa.md` (empty until Phase 4 lands), and the audio file
(symlink / copy of the in-flight `m4a` output). Atomic `.tmp` + rename
(FR-IRQ-52). Collision handling — Replace / Append-timestamp / Cancel
(FR-IRQ-32). Saved toast with Finder-reveal click.

### Phase 3 — `TranscriptExporter` module + CLI

Create `Sources/MacrecCore/Export/TranscriptExporter.swift`. Markdown layout
per FR-IRQ-29 (interleaved speech + Q&A blockquotes). Add
`macrec export --session <id> --folder <path>` (FR-IRQ-33, FR-IRQ-54).
Determinism guarantee (NFR-IRQ-Export-Determinism).

### Phase 4 — Q&A LLM integration

Add `QASessionHistory` model + `QAService` in `MacrecCore`. Wire the eight
standard providers via vendor-canonical env vars. Streaming answers into the
Asking pane. Privacy disclosure on first cloud invocation (FR-IRQ-18).
No-fallback on missing key (FR-IRQ-19). Q&A sidecar persistence on Stop
(FR-IRQ-14, FR-IRQ-15).

### Phase 5 — Global hotkey + floating overlay

Register `⌥⇧Space` (FR-IRQ-1, FR-IRQ-16). Build the frameless `NSWindow`-based
floating Ask overlay (FR-IRQ-3). Share `QASessionHistory` with the popover
(FR-IRQ-38).

### Phase 6 — Refinements + acceptance gate

Visual-continuity screenshot test (AC-IRQ-Pat-C-4). Latency budgets
(NFR-IRQ-Latency-First-Token, NFR-IRQ-Save-Latency). Recording-integrity
stress test — 10 questions back-to-back, `CaptureBuffer.dropCount` must
remain 0 (NFR-IRQ-Audio-Non-Blocking).

---

## Out of scope for this plan

Tracked in the requirements doc §"Out of scope for v1": voice push-to-talk,
slash-recipes, external KB connectors, multi-user / shared Q&A, cross-recording
Q&A, real-time speaking-coach nudges, auto-save on Stop, DOCX/PDF export.
