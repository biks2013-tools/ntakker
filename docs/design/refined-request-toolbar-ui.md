# Refined Request: Minimal macOS Toolbar UI for `macrec`

## Category
Development (native macOS UI add-on for the existing `macrec` Swift project)

## Goal & Background

The existing `macrec` tool (see `docs/tools/macrec.md`,
`docs/design/project-design.md`, `docs/design/project-functions.md`) is a
Swift command-line audio recorder for macOS 14+ that captures system audio
(via `ScreenCaptureKit`) and the microphone (via `AVFoundation`)
simultaneously. As of Phase L the CLI exposes `start`, `stop`,
`list-devices`, and `check-permissions`, with foreground and detached
modes, three output formats (`m4a` / `wav` / `caf`), and three track
layouts (`mixed` / `split` / `stereo-split`).

This request adds a **minimal native macOS toolbar UI** on top of the
existing engine so the user can drive a recording without remembering CLI
flags. The user wants:

- A button to **start** a recording.
- A way to **define the output file name**.
- A button to **pause** the recording.
- A button to **stop** the recording.
- A way to **split** the recording into smaller parts.
- An "et cetera" tail that implies sensible additional minimal controls
  (elapsed time, format/layout selection, permission status, etc.).

Two of those capabilities — **pause** and **split** — are explicitly
listed as deferred-to-v2 features in `project-functions.md` §4 and are not
present in `RecordingSession` today. Adding them is not a UI-only change;
it requires extending `MacrecCore`. This specification distinguishes UI
work from required core extensions.

The implementation language is **locked to Swift** by Exception 001 in the
project's `CLAUDE.md` and continues to apply here. SwiftUI and/or AppKit
are the platform-recommended path; downstream phases MUST NOT propose
TypeScript / Electron / Tauri / Web wrappers for this UI.

## Scope

### In scope (v1)

- A native macOS UI surface — form factor TBD (see OQ-UI-1) — that drives
  the existing `MacrecCore` recording engine.
- The four lifecycle controls explicitly listed by the user:
  - **Start** a recording.
  - **Pause / Resume** an in-progress recording.
  - **Stop** an in-progress recording.
  - **Split** the in-progress recording into a new file (manual split).
- A way to set the **output file name** before pressing Start, with a
  sensible auto-generated default.
- Surfacing the *currently mapped* CLI options that have a UI analogue
  (format, layout, mic device, output folder) — minimal set TBD by
  OQ-UI-6.
- A live **elapsed-time indicator** while recording.
- A **permission-status indicator** that surfaces the Screen Recording and
  Microphone TCC state, mirroring `macrec check-permissions`.
- New `MacrecCore` capabilities required to back the UI:
  - **Pause/Resume** at the recording-session level (mechanism TBD by
    OQ-CORE-1; see FR-30/31).
  - **Manual split** at the recording-session level (FR-32).
  - A **session-state observer** API (FR-33) so the UI can subscribe to
    state transitions (`idle → recording → paused → recording → split → stopped`)
    and surface them without polling.
- Reuse of the existing config-resolver, permission-gate, exit-code, and
  error-mapping infrastructure (FR-12..FR-14, FR-17, FR-18, FR-24).
- Documentation:
  - The new UI executable MUST be documented via the project's tool
    convention (see `CLAUDE.md` "Tools" section). Per the global
    convention this MUST be scaffolded by the
    `tool-doc-config-architect` subagent; see Constraints.
  - `project-functions.md` MUST be appended with the new FR-30..FR-NN
    entries (numbering continues from the highest existing FR-29).
  - `project-design.md` MUST gain a new section covering the UI
    architecture and the new core APIs.
  - `Issues - Pending Items.md` MUST be updated with any new risks
    surfaced.

### Out of scope (v1)

- Any UI for features not requested by the user: waveform display,
  scrubbing, post-recording playback, post-recording trim/edit, export to
  other formats, transcription preview, summarization, or LLM
  post-processing.
- Multi-window / multi-recording UX (running two simultaneous recordings
  from the same UI). v1 is single-recording.
- Time-based auto-split and size-based auto-split (manual split only in
  v1; see OQ-UI-3).
- Code signing, notarization, App Store distribution, Sparkle updater,
  Homebrew cask, `.dmg` packaging. v1 is a developer build (`swift build`
  or local Xcode build).
- Localization. v1 is English-only; copy strings MUST be wrapped in
  `String(localized:)` so v2 can localize without refactor, but no `.lproj`
  bundles ship in v1.
- Accessibility audit and VoiceOver-tuned labels beyond what SwiftUI
  provides by default. (A short pre-ship pass is in scope; full
  accessibility certification is not.)
- Modifying the existing `macrec` CLI surface in incompatible ways. The
  CLI MUST continue to function unchanged for users who do not adopt the
  UI.
- Cross-platform support, iOS, iPadOS, visionOS.

## Requirements

Numbering continues from the highest existing FR in
`docs/design/project-functions.md` (which ends at **FR-29**). All new FRs
are numbered **FR-30..FR-44** below; `MUST` denotes a hard requirement;
`SHOULD` denotes a strong preference that may be relaxed only with
explicit user approval recorded as a new exception.

### Functional requirements

#### FR-30 — Toolbar UI form factor
The UI MUST be a native macOS surface implemented in Swift (SwiftUI or
AppKit, implementer's choice unless OQ-UI-1 is locked otherwise). The
default form factor recommended in this spec is a **menu-bar status item
(`NSStatusItem`) backed by a popover panel** containing the controls,
because it is the closest match to the user's "minimal toolbar"
description and is always accessible without owning a window. The final
form factor is locked by **OQ-UI-1**.

#### FR-31 — Pause/Resume on `RecordingSession`
`MacrecCore.RecordingSession` MUST expose `pause()` and `resume()` APIs
that the UI calls from a Pause/Resume button. The semantics are locked by
**OQ-CORE-1**; the recommended default is **stop-and-stitch** (pause
finalizes the current segment file and resume opens a new one with an
incremented suffix), because:
  - It requires no new behavior in `SCStream`, `AVCaptureSession`, or any
    encoder; both sources are simply stopped and restarted.
  - It side-steps the `SCStream` 'cannot reuse a stopped stream'
    constraint already documented in FR-19 / project-design.md §1.
  - It composes cleanly with FR-32 (manual split is the same primitive
    invoked without an interleaving "paused" state).

The on-disk artefact of a pause/resume cycle under stop-and-stitch is two
files named per FR-34. Alternative semantics (soft pause; hard pause
single file) are scoped out unless OQ-CORE-1 is locked otherwise.

#### FR-32 — Manual split
`MacrecCore.RecordingSession` MUST expose a `split()` API that finalizes
the current output file and opens the next file in the sequence WITHOUT
stopping the SCStream / AVCaptureSession. The capture stack MUST stay
alive across the split; only the encoder and the output `URL` rotate. The
gap between consecutive segments MUST NOT exceed **250 ms** of audio
(verified by AC-UI-9). Naming follows FR-34.

#### FR-33 — Session state observer API
`MacrecCore.RecordingSession` MUST expose an observable
`SessionState` enum with at minimum the cases
`{ idle, starting, recording, pausing, paused, resuming, splitting, stopping, stopped, failed(MacrecError) }`,
and a publisher (`AsyncStream<SessionState>` or `@Published` /
`Combine.Publisher`, implementer's choice) that the UI subscribes to. UI
buttons MUST enable/disable based on state transitions exclusively
(no polling, no `Task.sleep` UI loops).

#### FR-34 — Segment file naming
When a single recording produces multiple files (because of pause/resume
under FR-31 stop-and-stitch, or because of manual split under FR-32), the
files MUST be named with a deterministic, sortable suffix derived from a
1-based segment counter:

- Single segment: `<basename>.<ext>` (no suffix; identical to today).
- Multiple segments:
  `<basename>.part01.<ext>`, `<basename>.part02.<ext>`, ...

If `--layout split` is in effect, both the `.mic.<ext>` and
`.system.<ext>` files MUST receive the same `.partNN` infix:
`<basename>.part01.mic.<ext>` / `<basename>.part01.system.<ext>`. The
infix MUST be inserted before the `.mic` / `.system` token, not after,
so a sort by filename groups by segment.

#### FR-35 — Output filename UX
The toolbar MUST expose a single text field for the output filename. The
field MUST be pre-populated with an auto-generated timestamped default
(format: `recording-YYYY-MM-DD-HHmmss.<ext>`, where `<ext>` reflects the
currently selected `--format`). The user MUST be able to edit the field
before Start; once recording begins the field MUST be locked
(non-editable). The UI MUST render the resolved absolute path
(folder + filename + extension) somewhere visible so the user can confirm
where the file will land. Final UX detail is locked by **OQ-UI-5**.

#### FR-36 — Output folder picker
The UI MUST expose a "Choose Folder…" affordance that opens
`NSOpenPanel` (folder-only, single selection). The chosen folder MUST
persist across launches via `UserDefaults` under the key
`com.macrec.ui.outputFolder`. Until the user picks one, the default MUST
be `~/Recordings/`; if that folder does not exist, the UI MUST create it
on first use. The persisted folder is **UI-only state**; it does NOT feed
into the four-tier env precedence chain that governs the CLI.

#### FR-37 — Permission status indicator
The UI MUST display the live state of the two TCC permissions
(Screen Recording, Microphone) using three visual states each:
**granted**, **denied**, **not-determined**. The component MUST poll on
a 2 s cadence ONLY while the popover/window is visible (no background
polling) and MUST refresh immediately when the app returns to the
foreground (`NSApplication.didBecomeActiveNotification`). Clicking a
`denied` indicator MUST open the corresponding System Settings deep link
already documented in `project-design.md §8`. The Start button MUST be
disabled whenever either permission is not `granted`, with a tooltip
explaining why.

#### FR-38 — Format and layout selection
The UI MUST expose two dropdowns / segmented controls:
- **Format**: `m4a` (default) | `wav` | `caf` — values per FR-4 / FR-17.
- **Layout**: `mixed` (default) | `split` | `stereo-split` — values per
  FR-5 / FR-17.

Selecting a format MUST update the file extension shown in the FR-35
filename field. Selections MUST persist across launches via
`UserDefaults`. Both controls MUST be disabled while a recording is
active (cannot change format/layout mid-recording).

#### FR-39 — Microphone device selection
The UI MUST expose a dropdown listing available input devices (the same
data that `macrec list-devices` returns; reuse the `AudioDeviceEnumerator`
component from `project-design.md §1.1`). The dropdown MUST default to
"System default" and MUST persist the user's choice across launches by
**UID** (not name) per FR-3 / OQ-8. The dropdown MUST refresh on
`AVCaptureDeviceWasConnectedNotification` /
`AVCaptureDeviceWasDisconnectedNotification`. Disabled while recording.

#### FR-40 — Elapsed-time indicator
While recording, the UI MUST display the elapsed wall-clock time of the
current segment **and** the cumulative elapsed time of the session
(across pauses and splits) in `HH:MM:SS` format, updated on a 1 Hz
timer that runs only while the window/popover is visible. While paused,
the segment timer MUST stop incrementing; the cumulative timer MUST also
stop incrementing under stop-and-stitch (since no audio is captured
during a pause).

#### FR-41 — Recording-state visual cue
The menu-bar status item icon (or, if a window form factor is chosen, the
window title-bar accessory) MUST visually distinguish the four states:
`idle` (neutral), `recording` (red dot), `paused` (yellow / hollow dot),
`failed` (red exclamation). The user MUST be able to glance at the menu
bar without opening any popover and know whether a recording is in
progress.

#### FR-42 — Process model
The UI MUST drive the recording engine **in-process** by linking
`MacrecCore` directly (the existing library target per NFR-9), NOT by
shelling out to the `macrec` CLI binary. Rationale: pause, split, level
meters, and the session-state observer (FR-31..FR-33, FR-43) all require
fine-grained synchronous coordination with `RecordingSession` that
subprocess IPC would complicate. The CLI continues to ship and operate
unchanged. Locked by **OQ-PROC-1**; default is in-process.

#### FR-43 — Per-source level meters (deferred to OQ-UI-6)
If level meters are in scope per OQ-UI-6, the UI MUST render a peak +
RMS meter per source (mic, system) updated on a 30 Hz cadence by tapping
the existing post-`AVAudioConverter` Float32/48 kHz/stereo stream in
`MacrecCore`. The tap MUST NOT block the capture queues (deliver via a
non-blocking ring buffer). If level meters are out of scope per OQ-UI-6,
this requirement is deferred to v2.

#### FR-44 — UI documentation and registration
The UI executable MUST be documented at `docs/tools/<ui-name>.md` in the
prescribed `<toolName><objective>...<command>...<info>...</toolName>`
XML-tagged format, the project's `CLAUDE.md` MUST list it under the
`## Tools` section with a short summary and a relative link to that
file, and `project-functions.md` MUST be updated to include FR-30..FR-44.
This file MUST be scaffolded via `/tool-conventions scaffold <ui-name>`
per the global convention (see Constraints) — never by hand.

### Non-functional requirements

These are appended to the existing NFR-1..NFR-10 in
`project-functions.md`.

#### NFR-11 — UI responsiveness
Every button click MUST update the visible UI state within **100 ms** of
the click (perceived immediate). Long operations (file finalization,
SCStream warmup) MUST run on a background actor / Task and surface
progress via the FR-33 state stream; the UI thread MUST never block on
audio I/O.

#### NFR-12 — Crash isolation
A crash in the recording engine MUST surface in the UI as a `failed`
session state with the underlying `MacrecError` displayed in a
non-intrusive banner / toast. The UI process MUST NOT be brought down by
a recoverable engine error. (Unrecoverable errors per FR-18 still exit
with the documented codes if the user invokes "Quit while recording".)

#### NFR-13 — Footprint
The UI process at idle (popover closed, no recording) MUST use less than
**80 MB** resident memory. While recording, it MUST stay within the
NFR-5 envelope (250 MB resident, 25 % of one core) — i.e. the UI MUST
not materially inflate the engine's footprint.

#### NFR-14 — Build constraint
The UI MUST build on the project's current developer host, which has
**Apple CommandLineTools but not full Xcode**. This implies:
  - SwiftPM-buildable preferred (`swift build`).
  - If a chosen form factor (e.g. notarizable `.app`) requires Xcode,
    OQ-DIST-1 MUST be locked toward the SwiftPM target with a documented
    plan to migrate to `.app` once Xcode is available.
  - No XCTest UI tests (per R-17 / project-functions §4) — UI tests, if
    any, MUST be runnable without the XCTest test runner stub.

#### NFR-15 — Architecture parity with CLI
The UI executable MUST ship as a universal binary (arm64 + x86_64) per
NFR-2 / OQ-4, matching the existing `macrec` target.

#### NFR-16 — Logging
UI logs MUST go through the existing `LoggerFactory` / swift-log
pipeline. Default UI log level is `info`; a hidden "Show debug log"
menu item MAY toggle to `debug`. Logs MUST go to a per-UI file at
`~/.tool-agents/<ui-name>/<ui-name>.log` (mode `0600`, append) when
running outside an Xcode debugger session, mirroring FR-29.

## Constraints

- **Language**: Swift (Exception 001 in `CLAUDE.md`). No TypeScript /
  Electron / Tauri / web-stack proposals.
- **Frameworks**: prefer Apple first-party (SwiftUI, AppKit, AVFoundation,
  Combine). Third-party SwiftPM dependencies are permitted only if there
  is no first-party equivalent, and only beyond the existing locked deps
  (swift-argument-parser 1.5.x, swift-log 1.5.x).
- **Build system**: Swift Package Manager preferred; if an `.app` bundle
  is required, the migration path is documented and deferred until Xcode
  is available on the dev host.
- **Platform**: macOS 14.0+ (NFR-1). No fallback to macOS 13 even though
  the engine technically supports it; the UI MAY use macOS-14-only
  SwiftUI APIs.
- **Reuse, do not fork**: the UI MUST link `MacrecCore` and reuse
  `ConfigResolver`, `PermissionGate`, `AudioDeviceEnumerator`,
  `RecordingSession`, `Recorder` implementations, and the `MacrecError`
  hierarchy. The UI MUST NOT reimplement permission probing, device
  enumeration, format/layout validation, or output-path validation.
- **No fallback config values**: if a required value is missing, raise a
  descriptive error (FR-14). The UI's `UserDefaults`-backed convenience
  state (output folder, last-used format, last-used mic device) is *UI
  state*, not configuration, and is not subject to the four-tier env
  chain.
- **No version-control operations** unless the user explicitly asks for
  them (project-wide convention).
- **Tool scaffolding via subagent**: per `CLAUDE.md`, the UI's
  `docs/tools/<ui-name>.md` and `~/.tool-agents/<ui-name>/`
  configuration folder MUST be scaffolded by the
  `tool-doc-config-architect` subagent invoked through
  `/tool-conventions scaffold <ui-name>`. Do NOT hand-author either.
- **CLI compatibility**: the existing `macrec` CLI MUST continue to
  build, run, and pass its existing acceptance criteria (AC-1..AC-20)
  unchanged. The UI is additive.

## Acceptance Criteria

Each criterion is a concrete, demonstrable check. The work is "done"
when all are satisfied. Criteria carry the `AC-UI-` prefix to keep them
distinguishable from the engine's existing `AC-1..AC-20`.

**AC-UI-1.** Running `swift build` (or the equivalent Xcode build, if
OQ-DIST-1 lands on `.app`) on macOS 14+ produces the UI executable with
no errors or warnings related to deprecated APIs.

**AC-UI-2.** Launching the UI on a fresh machine shows a permission
indicator surfacing "Screen Recording: not determined" and "Microphone:
not determined", and the Start button is disabled.

**AC-UI-3.** Clicking a `not-determined` permission indicator triggers
the system TCC prompt; clicking a `denied` indicator opens the correct
System Settings pane (Privacy & Security → Screen Recording, or
Privacy & Security → Microphone).

**AC-UI-4.** With both permissions granted, clicking **Start** produces a
recording at the resolved output path within 1 s of the click. The
status icon transitions to the `recording` visual within 100 ms
(NFR-11).

**AC-UI-5.** Clicking **Stop** finalizes the file. The on-disk file is
playable end-to-end in QuickTime Player; the duration matches the
elapsed-time indicator within ±0.5 s.

**AC-UI-6.** Clicking **Pause** while recording transitions the UI to
the `paused` visual within 100 ms; the segment file is finalized and
playable within 30 s (FR-20). Clicking **Resume** transitions back to
`recording` and a new segment file appears on disk with the next
`.partNN` suffix per FR-34.

**AC-UI-7.** Clicking **Split** while recording finalizes the current
segment and opens the next segment without stopping capture. Listening
to the two adjacent segment files reveals NO audible content gap larger
than 250 ms at the seam (FR-32).

**AC-UI-8.** Editing the filename field before Start produces an output
file at the entered path; the locked field after Start cannot be edited.

**AC-UI-9.** Picking a folder via the folder picker, quitting the UI,
relaunching it, and pressing Start writes the recording into the
remembered folder (FR-36 persistence).

**AC-UI-10.** Selecting `--layout split` from the layout dropdown and
recording produces two files (`<basename>.mic.<ext>` and
`<basename>.system.<ext>`) per existing FR-5; if Pause or Split is used,
the four files are named per FR-34 with `.partNN` infixes.

**AC-UI-11.** The mic dropdown lists at least the built-in microphone,
the same set returned by `macrec list-devices`. Disconnecting and
reconnecting an external USB mic causes the dropdown to refresh within
2 s (FR-39).

**AC-UI-12.** The elapsed-time indicator advances at exactly 1 Hz while
recording, freezes while paused, and resumes after Resume (FR-40).

**AC-UI-13.** Force-quitting the UI process while recording (Activity
Monitor → Force Quit, or `kill -9`) leaves a partial but playable file
on disk (the recovery guarantees in FR-21 still apply because the same
M4ARecorder is in use).

**AC-UI-14.** Existing CLI acceptance criteria AC-1..AC-20 still pass
after the UI changes are merged. (Regression gate.)

**AC-UI-15.** `docs/tools/<ui-name>.md`,
`~/.tool-agents/<ui-name>/.env`, and the `## Tools` entry in
`CLAUDE.md` exist, all produced by the
`tool-doc-config-architect` subagent (`/tool-conventions audit
<ui-name>` passes).

**AC-UI-16.** `docs/design/project-functions.md` contains FR-30..FR-44
in the prescribed format with `Status: PLANNED` (or further) and the
phase mapping appropriate to the implementation plan that follows this
spec.

**AC-UI-17.** `docs/design/project-design.md` gains a new section
covering the UI architecture, the new core APIs (`pause`, `resume`,
`split`, `SessionState`), and the segment-file naming scheme (FR-34).

**AC-UI-18.** `Issues - Pending Items.md` is updated with any new risks
or open items surfaced during UI implementation.

## Assumptions

- **A-UI-1.** The user's "minimal toolbar" is best served by a menu-bar
  status item with a popover panel, on the basis that menu-bar UIs are
  the standard macOS idiom for "always-accessible recording control"
  (Loom, Zoom, Slack-Huddle, Audio Hijack's Stream Deck integration all
  follow this pattern). Other form factors are recorded as OQ-UI-1 for
  the user to override.
- **A-UI-2.** Pause should be implemented as **stop-and-stitch** rather
  than soft-pause or hard-pause-single-file, because (a) it reuses the
  existing finalize / new-writer code path, (b) it sidesteps the
  `SCStream` 'cannot reuse a stopped stream' constraint already
  documented in FR-19, (c) it composes with manual split (same
  primitive), and (d) producing multiple files is a normal outcome
  the user already accepts via `--layout split`. Recorded as OQ-CORE-1.
- **A-UI-3.** Split is **manual-only** for v1. Time-based and size-based
  auto-split are pushed to v2 to keep the v1 toolbar minimal as the user
  requested. Recorded as OQ-UI-3.
- **A-UI-4.** Process model is **in-process** (UI links `MacrecCore`).
  Subprocess IPC adds latency and complicates pause/split/level-meters
  for no countervailing benefit, since the CLI and UI are co-developed
  by the same project. Recorded as OQ-PROC-1.
- **A-UI-5.** Output filename UX is **auto-named timestamp, editable in
  the toolbar before recording** (`recording-YYYY-MM-DD-HHmmss.<ext>`).
  This is the lowest-friction option that still gives the user full
  control. A post-recording "Save As" dialog is rejected because it
  delays finalization and risks data loss if the user cancels.
- **A-UI-6.** "Et cetera" features in scope for v1: elapsed-time indicator,
  format dropdown, layout dropdown, output folder picker, mic device
  picker, permission status indicator. Per-source level meters are
  flagged as OQ-UI-6 because they require a new tap point in
  `MacrecCore` and add 30 Hz UI work; they are recommended in but
  surfaced for explicit confirmation.
- **A-UI-7.** Distribution: ship v1 as a **new SwiftPM `executableTarget`
  named `macrec-ui`** in the same Swift package as `macrec`, sharing
  `MacrecCore`. This avoids the Xcode-only constraint (NFR-14) for v1
  while leaving a clean migration path to a notarizable `.app` once
  Xcode is available on the dev host. Recorded as OQ-DIST-1.
- **A-UI-8.** UI naming: the UI executable / tool-agent token is
  `macrec-ui` (`docs/tools/macrec-ui.md`,
  `~/.tool-agents/macrec-ui/`). This is recorded as OQ-NAME-1.
- **A-UI-9.** Single-recording UX: the UI permits exactly one active
  recording at a time. Attempting to Start while a recording is active
  is impossible because Start is disabled in non-`idle` states (FR-33).
- **A-UI-10.** No localization in v1; English-only copy (NFR
  out-of-scope clause). Strings are `String(localized:)`-wrapped to
  enable v2 localization.
- **A-UI-11.** No code signing / notarization in v1; the UI runs as an
  ad-hoc-signed SwiftPM executable. Existing R-2 (TCC ad-hoc-signing
  instability) applies and MUST be re-stated in
  `Issues - Pending Items.md` for the UI.

## Open Questions

These MUST be resolved by the user before implementation begins. Each has
a recommended default so design can proceed in parallel.

**OQ-UI-1 — Toolbar form factor.**
Choices: (a) menu-bar `NSStatusItem` with popover panel,
(b) floating always-on-top utility window, (c) menu-bar item that opens
a regular window, (d) regular app window with toolbar. *Recommended
default*: **(a) menu-bar status item with popover** (per A-UI-1).

**OQ-UI-2 — Pause semantics (= OQ-CORE-1).**
Choices: (a) stop-and-stitch (multi-file), (b) soft-pause single-file
(no audio between pause/resume), (c) hard-pause single-file (suspend
SCStream + AVCaptureSession), (d) defer pause to v2. *Recommended
default*: **(a) stop-and-stitch** (per A-UI-2). Significantly affects
core scope.

**OQ-UI-3 — Split modes.**
Choices: (a) manual only, (b) manual + time-based auto-split,
(c) manual + size-based auto-split, (d) all three. *Recommended
default*: **(a) manual only in v1**, others to v2.

**OQ-UI-4 — Process model (= OQ-PROC-1).**
Choices: (a) in-process linking `MacrecCore`, (b) subprocess shell-out
to `macrec` CLI, (c) hybrid. *Recommended default*: **(a) in-process**
(per A-UI-4).

**OQ-UI-5 — Output filename UX.**
Choices: (a) auto-named timestamp editable pre-record,
(b) pre-record text field only (no auto-fill),
(c) post-record save-as dialog,
(d) auto-named pre-record + optional Save-As on stop. *Recommended
default*: **(a)** (per A-UI-5).

**OQ-UI-6 — "Et cetera" feature set.**
Confirmation needed for the recommended set
(elapsed-time, format dropdown, layout dropdown, folder picker, mic
picker, permission indicator) and for the optional **per-source level
meters** (FR-43). *Recommended default*: **all six basics IN; level
meters IN if implementer time allows, otherwise deferred to v2.**

**OQ-UI-7 — Distribution / packaging (= OQ-DIST-1).**
Choices: (a) SwiftPM `executableTarget` `macrec-ui` in the same package,
(b) separate Xcode `.app` project (blocked on Xcode availability),
(c) embed into existing `macrec` binary as `macrec ui` subcommand,
(d) SwiftPM now, plan `.app` migration for v2. *Recommended default*:
**(a) or (d)** — both ship the same artefact; (d) just commits to a
v2 migration path explicitly.

**OQ-UI-8 — UI tool-agents token (= OQ-NAME-1).**
Choices: `macrec-ui`, `macrec-app`, `macrecui`, `recorder-ui`.
*Recommended default*: **`macrec-ui`** (mirrors CLI binary name with
the `-ui` suffix; clean and unambiguous).

**OQ-UI-9 — Auto-start / auto-foreground on launch.**
Should opening the UI automatically open the popover, or only sit in
the menu bar quietly? *Recommended default*: **quietly in the menu bar;
user clicks to open**. Standard macOS UX.

**OQ-UI-10 — Quit-while-recording behavior.**
What happens if the user picks "Quit" from the UI's menu while a
recording is active? Choices: (a) refuse with a confirm dialog and
keep recording, (b) finalize current file then quit, (c) save partial
and force-quit. *Recommended default*: **(b) finalize-then-quit, with
a confirmation dialog** for the user to back out.

**OQ-UI-11 — Visibility of layout=split outputs in the UI.**
When `--layout split` produces two files, the UI's "where is my
recording?" preview must show both. Should it list both, link to the
parent folder, or only show one with a "+1 file" badge? *Recommended
default*: **list both filenames in a tooltip / details disclosure;
clicking the disclosure reveals both rows**.

## References

- `docs/design/refined-request-recording-tool.md` — original CLI request,
  format precedent for this document.
- `docs/design/project-design.md` — current architecture; especially
  §1 Component Diagram, §1.2 Data-Flow, §8 Permission strings, §9.5 Exit
  codes, §14 Detach mode + `stop`. The new UI section should be
  inserted as a new §15 (or appropriate next number).
- `docs/design/project-functions.md` — FR-1..FR-29; this spec adds
  FR-30..FR-44.
- `docs/tools/macrec.md` — existing CLI documentation; `macrec-ui` will
  receive a sibling document scaffolded by the
  `tool-doc-config-architect` subagent.
- `Issues - Pending Items.md` — existing risks (R-1..R-19) that may
  apply to the UI as well, especially R-2 (ad-hoc TCC instability),
  R-13 (sleep behavior), R-17 (XCTest stub on CommandLineTools).
- `CLAUDE.md` — Exception 001 (Swift), tool-scaffolding mandate, no
  TypeScript expectation override.

## Decisions Locked (resolved Open Questions)

The following decisions were locked by the user on 2026-04-26 via the
team-workflow orchestrator's clarification step. They supersede the
recommended defaults in the Open Questions section above.

| OQ ID | Decision |
|-------|----------|
| OQ-UI-1 | **Menu-bar `NSStatusItem` with popover panel.** No regular app window. |
| OQ-UI-2 / OQ-CORE-1 | **Stop-and-stitch (multi-file)** for pause/resume. Pause closes the current file; resume starts a new one with an incremented suffix. |
| OQ-UI-3 | **Manual split only in v1.** Time-based and size-based auto-split deferred to v2. |
| OQ-UI-4 / OQ-PROC-1 | **In-process linking `MacrecCore`.** UI app embeds the engine library and drives `RecordingSession` directly. No subprocess shell-out. |
| OQ-UI-5 | **Auto-named timestamp, editable pre-record.** Field pre-fills `recording-YYYY-MM-DD-HH-mm.<ext>`; user can edit before pressing Start. No post-record save dialog. |
| OQ-UI-6 — core | **Elapsed-time indicator + format dropdown + layout dropdown + permission indicator.** All four IN. |
| OQ-UI-6 — optional | **Output folder picker + microphone device picker + per-source level meters.** All three IN. Level meters require a new pipeline tap point in `MacrecCore` (FR-43). |
| OQ-UI-7 / OQ-DIST-1 | **SwiftPM `executableTarget` `macrec-ui` in the same `Package.swift`.** Builds with `swift build` on CommandLineTools (no full Xcode required). |
| OQ-UI-8 / OQ-NAME-1 | **`macrec-ui`** as the tool-agents token, executable name, and documentation slug. |
| OQ-UI-9 | **Sit quietly in the menu bar on launch.** User clicks the status icon to open the popover. |
| OQ-UI-10 | **Confirm dialog → finalize current file → quit.** "Stop recording and quit?" alert; cancel keeps recording. |
| OQ-UI-11 | **Default applies** — when `--layout split` produces two files, list both filenames in a disclosure under the "saved to" row. |

These decisions are inputs to all downstream phases (codebase scan,
investigation, planning, design, implementation, testing). Any deviation
must be raised back to the user.

## Original Request

> I want you to create a minimal toolbar ui to allow the user to start
> recording, define the output file name and pause or stop the recording
> or split it in smaller parts, et cetera.
