# Project Functions — `ntakker-cli` macOS Dual-Source Audio Recording Tool

> Functional Requirements registry. Phase 4 deliverable; refined by every
> downstream phase. Updates to this document follow the convention in
> `CLAUDE.md`: every new functional requirement or feature description
> must be registered here.
>
> **Status legend:**
> - **PLANNED** — accepted for v1, implementation pending.
> - **IMPLEMENTED** — code shipped and tests pass.
> - **DEFERRED** — out of scope for v1, surfaced for v2 backlog.
>
> Source documents:
> - `docs/design/refined-request-recording-tool.md` (FR-1..FR-16, NFR-1..NFR-10, AC-1..AC-15, OQ-1..OQ-10)
> - `docs/design/plan-001-recording-tool.md` (FR-17..FR-24 added during planning)
> - `docs/reference/investigation-recording-tool.md` (technical decisions)
> - `docs/research/scstream-audio-only.md` (system-audio capture recipe)
> - `docs/research/avassetwriter-aac.md` (encoder recipe)

---

## 1. Functional requirements

### 1.1 Carried forward from the refined request

#### FR-1 — Simultaneous dual-source capture
**Status:** PLANNED.
The tool MUST capture system audio and microphone audio concurrently
from the moment the user issues `start` until the moment they issue
`stop` (signalled via SIGINT / SIGTERM in v1) or the optional
`--max-duration` cap is reached.

#### FR-2 — System audio source
**Status:** PLANNED. **Phase:** I.
System audio capture MUST be implemented via `ScreenCaptureKit`'s audio
capture path: `SCStream` configured with `capturesAudio = true` and an
`SCStreamConfiguration` whose audio settings reflect FR-7 / FR-8. The
tool MUST NOT require the user to install a virtual audio device
(BlackHole, Loopback, Soundflower, etc.).

#### FR-3 — Microphone source
**Status:** PLANNED. **Phase:** I.
Microphone capture MUST be implemented via `AVCaptureSession` +
`AVCaptureDeviceInput` + `AVCaptureAudioDataOutput`. The tool MUST
default to the system's current default input device and MUST allow
overriding it with `--mic-device <name|uid>`.

#### FR-4 — Output format
**Status:** PLANNED. **Phase:** G (m4a), H (wav, caf).
The tool MUST be able to write the recording in at least the following
formats, selectable by `--format`:
- `m4a` — AAC-LC inside an MPEG-4 container (default; FR-7 default).
- `wav` — 16-bit signed little-endian linear PCM, RIFF/WAVE container.
- `caf` — CoreAudio Format container, 24-bit big-endian linear PCM.

#### FR-5 — Track layout
**Status:** PLANNED. **Phase:** F (mixing/splitting), J (orchestration).
The tool MUST support the following track layouts, selectable by `--layout`:
- `mixed` (default) — mic + system audio summed into a single
  stereo track.
- `split` — two separate output files, named with deterministic suffixes
  `<basename>.mic.<ext>` and `<basename>.system.<ext>`.
- `stereo-split` — single stereo file with mic on the left channel and
  system audio on the right channel; reversible via `--mic-channel left|right`.

#### FR-6 — Recording lifecycle
**Status:** PLANNED. **Phase:** J, K.
The tool MUST expose:
- `start` — begin recording.
- `SIGINT` / `SIGTERM` MUST act as the canonical stop trigger in v1
  (per OQ-3); the file MUST be finalized cleanly so partial recordings
  are not lost.
- Optional `--max-duration <seconds>` flag on `start` that auto-stops
  at the cap.

The `stop` subcommand is **omitted from v1** by OQ-3.

#### FR-7 — Sample rate and bit depth
**Status:** PLANNED. **Phase:** G, H, J.
Internal processing MUST default to **48 kHz, Float32** for both
sources (Float32 is the canonical internal format; the on-disk bit
depth is determined by `--bit-depth`). The user MUST be able to
override the sample rate via `--sample-rate {44100|48000}` and the bit
depth via `--bit-depth {16|24}` (24-bit only meaningful for `wav` /
`caf` PCM outputs).

#### FR-8 — Encoder bitrate
**Status:** PLANNED. **Phase:** G.
When the output format is a lossy codec (e.g. AAC in `m4a`), the
encoder MUST default to **192 kbps**, overridable with `--bitrate <kbps>`.
Validation per FR-17.

#### FR-9 — Channel layout
**Status:** PLANNED. **Phase:** F, G.
Default channel layout MUST be **stereo** for both sources. If the
system or microphone hardware delivers mono, the `AVAudioConverter`
MUST upmix or duplicate to stereo cleanly.

#### FR-10 — Permission handling
**Status:** PLANNED. **Phase:** D, J, K.
Before opening any capture session, the tool MUST:
1. Check Screen Recording TCC permission. If `.notDetermined`, trigger
   `CGRequestScreenCaptureAccess()` and exit 75 (`EX_TEMPFAIL`) with a
   "please relaunch" message. If `.denied`, exit 77 (`EX_NOPERM`) with
   the System Settings deep link.
2. Check Microphone TCC permission. Same triage as above using
   `AVCaptureDevice.requestAccess(for: .audio)`.
3. Refuse to start recording if either permission is not `.authorized`.

#### FR-11 — Subcommand CLI surface
**Status:** PLANNED. **Phase:** K.
The CLI MUST expose:
- `start [options]` — begin a recording.
- `list-devices` — print available input audio devices (UID, name,
  channel count, sample rate, default marker).
- `check-permissions` — print the current state of Screen Recording and
  Microphone permissions without starting a recording.
- Global `--help` / `-h` and `--version` / `-V` flags.

#### FR-12 — Configuration precedence
**Status:** PLANNED. **Phase:** B.
Configuration values MUST be resolved in this order, lowest-to-highest
priority (higher overrides lower):
1. Shell environment (`ProcessInfo.processInfo.environment`).
2. `~/.tool-agents/ntakker-cli/.env`.
3. `./.env` in the current working directory.
4. CLI flags.

#### FR-13 — Per-user durable defaults bootstrap
**Status:** PLANNED. **Phase:** B.
On every invocation the tool MUST ensure `~/.tool-agents/ntakker-cli/`
exists with mode `0700`. If absent, it MUST create it and seed an
empty `.env` with mode `0600`.

#### FR-14 — No silent fallbacks
**Status:** PLANNED. **Phase:** B.
If a required configuration value is not provided through any source
in the precedence chain, the tool MUST raise a descriptive error
naming the missing variable and the sources that were checked. It MUST
NOT substitute a default unless that default is explicitly called out
(e.g. `--format` defaults to `m4a`).

#### FR-15 — Output path handling
**Status:** PLANNED. **Phase:** B, J.
The user MUST specify the output path via `--output <path>` (or
`OUTPUT_PATH` env var). If the path's parent directory does not exist,
the tool MUST raise an error rather than create it implicitly. If a
file already exists at the output path, the tool MUST refuse to
overwrite unless `--overwrite` is passed. For `--layout split`, both
the `.mic.<ext>` and `.system.<ext>` paths MUST be checked.

#### FR-16 — Tool documentation
**Status:** PLANNED. **Phase:** L.
The tool MUST be documented at `docs/tools/ntakker-cli.md` in the
prescribed `<toolName><objective>...<command>...<info>...</toolName>`
XML-tagged format, and the project's `CLAUDE.md` MUST list the tool
under its `## Tools` section with a short summary and a relative link
to that file (no full duplication).

### 1.2 Added during planning (Phase 4)

#### FR-17 — Configuration value validation
**Status:** PLANNED. **Phase:** B.
Every configuration value MUST be range-validated at parse time;
out-of-range or unrecognized values fail with exit code 64
(`EX_USAGE`) and a one-line stderr message naming the offending key
and the accepted set/range. Locked ranges:
- `sample-rate ∈ {44100, 48000}`
- `bit-depth ∈ {16, 24}`
- `bitrate ∈ [64, 320]` (kbps; only meaningful for AAC formats)
- `layout ∈ {mixed, split, stereo-split}`
- `format ∈ {m4a, wav, caf}`
- `mic-channel ∈ {left, right}` (only meaningful for `stereo-split`)
- `max-duration > 0`
- `log-level ∈ {quiet, info, debug}`

#### FR-18 — Documented exit-code table
**Status:** PLANNED. **Phase:** C.
Every error path MUST return one of the documented exit codes:
| Code | Meaning | Triggering condition |
|------|---------|----------------------|
| 0    | Success | Normal completion or SIGINT-finalized recording |
| 1    | Generic error | Catch-all for unexpected runtime failures |
| 2    | Partial output | `finishWriting` watchdog timeout (FR-20) |
| 64 (`EX_USAGE`) | Usage error | Invalid CLI flag, range violation (FR-17) |
| 66 (`EX_NOINPUT`) | I/O error | Output parent missing or output exists without `--overwrite` (FR-15) |
| 70 (`EX_SOFTWARE`) | Runtime failure | SCStream/AVCapture failed to start; SCStream silent-stop limit (FR-19) |
| 75 (`EX_TEMPFAIL`) | Retryable | Permission `.notDetermined` — relaunch after granting prompt |
| 77 (`EX_NOPERM`) | Permission denied | Permission `.denied` |
| 78 (`EX_CONFIG`) | Config error | Required value missing (FR-14); mic device not found |

#### FR-19 — Watchdog-driven SCStream restart
**Status:** PLANNED. **Phase:** I.
The system-audio source MUST monitor buffer-arrival staleness with a
5-second poll cadence and a 10-second staleness threshold. On stall,
it MUST cancel the current `SCStream`, instantiate a fresh one (never
reuse a stopped instance), and resume capture. If more than 3
restarts occur within any 60-second window, the source MUST surface
`NtakkerError.scStreamSilentStopExceeded(restartCount:)` and exit 70.
The delegate's `didStopWithError` callback MUST wrap all work in
`Task { ... }` to avoid the `swift_getErrorValue` `EXC_BAD_ACCESS`
framework crash.

#### FR-20 — Finalization timeout
**Status:** PLANNED. **Phase:** G, J.
Writer finalization (`finishWriting` for m4a; flush for wav/caf) MUST
abort and exit 2 with a stderr message naming the partial file path
if it does not complete within 30 seconds.

#### FR-21 — Crash-resilient AAC
**Status:** PLANNED. **Phase:** G.
The `m4a` writer MUST enable:
- `shouldOptimizeForNetworkUse = true` — moves the `moov` atom to the
  front so a partially-finalized file is playable.
- `movieFragmentInterval = CMTime(value: 2, timescale: 1)` — flushes
  independently decodable 2-second fragments so a hard-kill (`SIGKILL`)
  leaves a recoverable file.

#### FR-22 — Host-clock synchronization for AVCapture
**Status:** PLANNED. **Phase:** I.
The microphone `AVCaptureSession` MUST set
`synchronizationClock = CMClockGetHostTimeClock()` so its sample
buffer PTSs are directly comparable with SCStream's PTSs. This is
the primary mechanism by which the ±20 ms drift bound (NFR-4) is
maintained.

#### FR-23 — Per-source RMS heartbeat (debug)
**Status:** PLANNED. **Phase:** J. **Resolves OQ-9.**
When `--log-level debug` is active, the orchestrator MUST log each
source's RMS amplitude every 10 seconds at the `debug` level. This
makes a stuck/silent capture path distinguishable from legitimate
silence in post-mortem log review.

#### FR-24 — Output overwrite gate
**Status:** PLANNED. **Phase:** B, J.
Output-path validation MUST verify:
- The path's parent directory exists; if not, exit 66 (no implicit
  `mkdir -p`).
- If a file exists at the path AND `--overwrite` is false, exit 66.
- For `--layout split`, both `<basename>.mic.<ext>` and
  `<basename>.system.<ext>` are validated independently.

### 1.4 Added by plan-002 — Minimal toolbar UI (`ntakker`)

> The requirements below are appended on 2026-04-26 by Phase 4 (Planner)
> for the `ntakker` v1.1 add-on. Source: `docs/design/refined-request-toolbar-ui.md`
> (FR-30..FR-44, NFR-11..NFR-16, AC-UI-1..AC-UI-18, "Decisions Locked"
> table). All architectural choices are locked in that document and
> reaffirmed by `docs/reference/investigation-toolbar-ui.md`. Phase
> mapping reflects `docs/design/plan-002-toolbar-ui.md`. Section
> ordering: §1.1 → §1.2 → §1.3 (detach mode, FR-25..FR-29) → §1.4
> (toolbar UI, FR-30..FR-44 + NFR-11..NFR-16) — §1.4 is presented here
> for proximity to FR-1..FR-24, and §1.3 is preserved verbatim below
> for historical fidelity.

#### FR-30 — Toolbar UI form factor
**Status:** IMPLEMENTED (Phase C completed 2026-04-26). **Phase:** C (plan-002).
The UI MUST be a native macOS surface implemented in Swift. Locked form
factor: a menu-bar `NSStatusItem` backed by an `NSPopover` panel
containing an `NSHostingController<RootView>` inside a SwiftUI `App`
shell whose only declared scene is `Settings { EmptyView() }`. NOT
SwiftUI's `MenuBarExtra` (R-24).

#### FR-31 — Pause/Resume on `RecordingSession`
**Status:** IMPLEMENTED (Phase A + Phase D completed 2026-04-26). **Phase:** A (engine support — `SessionState` +
`stateStream`) + D (UI-side `SessionCoordinator` orchestration; plan-002).
The UI MUST expose Pause/Resume controls. Semantics are
**stop-and-stitch (multi-file)**: pause finalizes the current segment
file, resume opens a new one with an incremented `partNN` suffix per
FR-34. The orchestration of multiple sequential `RecordingSession`
instances lives in a UI-side actor; `RecordingSession` itself is NOT
modified for pause.

#### FR-32 — Manual split
**Status:** IMPLEMENTED (Phase A completed 2026-04-26). **Phase:** A (plan-002).
`NtakkerCore.RecordingSession` MUST expose `split(nextOutput:) async throws`
that finalizes the current output file and opens the next file in the
sequence WITHOUT stopping `SCStream` / `AVCaptureSession`. The capture
stack stays alive across the split; only the encoder and the output
`URL` rotate. Audible gap MUST be ≤ 250 ms (AC-UI-7). Naming follows
FR-34.

#### FR-33 — Session state observer API
**Status:** IMPLEMENTED (Phase A completed 2026-04-26). **Phase:** A (plan-002).
`NtakkerCore.RecordingSession` MUST expose a `SessionState` enum with
cases `{ idle, starting, recording, pausing, paused, resuming,
splitting, stopping, stopped, failed(NtakkerError) }` and an
`AsyncStream<SessionState>` publisher that the UI subscribes to. UI
buttons MUST enable/disable based on observed state transitions
exclusively (no polling).

#### FR-34 — Segment file naming
**Status:** IMPLEMENTED (Phase D completed 2026-04-26). **Phase:** D (plan-002, `SegmentNamer`).
When a single recording produces multiple files (pause/resume under
FR-31, or manual split under FR-32), files MUST be named with a
deterministic, sortable 1-based suffix:
- Single segment: `<basename>.<ext>` (no suffix).
- Multiple segments: `<basename>.partNN.<ext>` (zero-padded to two
  digits).
For `--layout split`, both the `.mic` and `.system` files MUST receive
the same `.partNN` infix BEFORE the `.mic` / `.system` token, so a
sort by filename groups by segment.

#### FR-35 — Output filename UX
**Status:** IMPLEMENTED (Phase E completed 2026-04-26). **Phase:** E (plan-002, `FilenameField`).
The UI MUST expose a single text field for the output filename,
pre-populated with `recording-YYYY-MM-DD-HHmmss.<ext>` (timestamp +
extension reflects current `--format`). Editable before Start; locked
during recording. The resolved absolute path (folder + filename +
extension) MUST be visibly rendered for confirmation.

#### FR-36 — Output folder picker
**Status:** IMPLEMENTED (Phase E completed 2026-04-26). **Phase:** E (plan-002, `FolderPicker`).
The UI MUST expose "Choose Folder…" via `NSOpenPanel` (folder-only,
single selection). Selection persists across launches in `UserDefaults`
under `com.ntakker-cli.ui.outputFolder`. Default `~/Recordings/`; created
on first use if missing. UI-only state (NOT subject to the four-tier
config chain).

#### FR-37 — Permission status indicator
**Status:** IMPLEMENTED (Phase E completed 2026-04-26). **Phase:** E (plan-002, `PermissionStatusView`).
The UI MUST display Screen Recording and Microphone TCC state with
three visual states each (granted / denied / not-determined). Polls
on a 2 s cadence ONLY while the popover is visible; refreshes on
`NSApplication.didBecomeActiveNotification`. `denied` opens the System
Settings deep link (project-design §8). Start button is disabled
unless both are `granted`.

#### FR-38 — Format and layout selection
**Status:** IMPLEMENTED (Phase E completed 2026-04-26). **Phase:** E (plan-002, `FormatPicker`, `LayoutPicker`).
The UI MUST expose two dropdowns (Format: `m4a`/`wav`/`caf`; Layout:
`mixed`/`split`/`stereo-split`). Format change updates the file
extension shown in FR-35's filename field. Both persist via
`UserDefaults` (`com.ntakker-cli.ui.format`, `com.ntakker-cli.ui.layout`).
Both disabled while recording.

#### FR-39 — Microphone device selection
**Status:** IMPLEMENTED (Phase E completed 2026-04-26). **Phase:** E (plan-002, `MicrophonePicker`).
The UI MUST expose a dropdown of input devices from
`AudioDeviceEnumerator.listInputs()`. Defaults to "System default".
Persists by `uid` in `UserDefaults` (`com.ntakker-cli.ui.micUID`). Refreshes
on `AVCaptureDeviceWasConnectedNotification` /
`AVCaptureDeviceWasDisconnectedNotification`. Disabled while recording.

#### FR-40 — Elapsed-time indicator
**Status:** IMPLEMENTED (Phase E completed 2026-04-26). **Phase:** E (plan-002, `ElapsedTimeView`).
The UI MUST display segment-elapsed and cumulative-elapsed times in
`HH:MM:SS`, updated at 1 Hz only while popover is visible. Both
freeze during pause (no audio captured under stop-and-stitch).

#### FR-41 — Recording-state visual cue
**Status:** IMPLEMENTED (Phases C+E completed 2026-04-26). **Phase:** C (plan-002, `StatusItemController` icon API) + E (visual state mapping).
The menu-bar status item icon MUST visually distinguish four states:
`idle` (neutral), `recording` (red dot), `paused` (yellow / hollow),
`failed` (red exclamation). Glanceable without opening the popover.

#### FR-42 — Process model
**Status:** IMPLEMENTED (Phase A + Phase D completed 2026-04-26). **Phase:** A + D (plan-002).
The UI MUST drive the recording engine **in-process** by linking
`NtakkerCore` directly. NOT subprocess shell-out to the `ntakker-cli` CLI.

#### FR-43 — Per-source level meters
**Status:** IMPLEMENTED (Phases A+D+E completed 2026-04-26). **Phase:** A (`levelTap` engine support) + D
(`LevelMeterTap`, `LevelMeterPublisher`) + E (`LevelMeterView`)
(plan-002).
The UI MUST render peak + RMS meters per source (mic, system) at 30 Hz
by tapping the post-converter Float32/48 kHz/stereo stream via a new
`levelTap` closure on each capture source. The tap MUST NOT block the
audio queues (vDSP on a pre-allocated `AVAudioPCMBuffer`; non-blocking
`AsyncStream` with `.bufferingNewest(2)`).

#### FR-44 — UI documentation and registration
**Status:** IMPLEMENTED (Phases 0+J completed 2026-04-26). **Phase:** 0 + J (plan-002).
The UI executable MUST be documented at `docs/tools/ntakker.md` in
the prescribed `<toolName>` XML format, the `## Tools` section in
`CLAUDE.md` MUST list it, and `project-functions.md` MUST contain
FR-30..FR-44. The doc file and the `~/.tool-agents/ntakker/`
folder MUST be scaffolded by `/tool-conventions scaffold ntakker`
(dispatches the `tool-doc-config-architect` subagent) — never hand-
authored.

#### NFR-11 — UI responsiveness
**Status:** IMPLEMENTED (Phases D+E completed 2026-04-26 — Phase K verification pending). **Phase:** D + E + K verification (plan-002).
Every button click MUST update the visible UI state within 100 ms.
Long operations (file finalization, SCStream warmup) run on a
background `Task` and surface progress via the FR-33 state stream;
the UI thread MUST never block on audio I/O.

#### NFR-12 — Crash isolation
**Status:** IMPLEMENTED (Phase G completed 2026-04-26 — `NtakkerError → banner` mapping landed). **Phase:** G (plan-002).
A recoverable engine error MUST surface as a `failed` session state
with the underlying `NtakkerError` displayed in a banner / toast. The
UI process MUST NOT be brought down by a recoverable engine error.

#### NFR-13 — Footprint
**Status:** PLANNED. **Phase:** K verification (plan-002).
The UI process at idle MUST use less than 80 MB resident memory.
While recording, combined UI + engine MUST stay within the NFR-5
envelope (250 MB resident, 25 % of one core).

#### NFR-14 — Build constraint
**Status:** IMPLEMENTED (Phase B completed 2026-04-26; verified by Phase A/C/D builds — `swift build` succeeds on Apple CommandLineTools). **Phase:** B + I (plan-002).
The UI MUST build on Apple CommandLineTools (no full Xcode required).
SwiftPM-buildable preferred. UI tests, if any, MUST be runnable
without the XCTest test runner stub (R-17 / R-22).

#### NFR-15 — Architecture parity with CLI
**Status:** IMPLEMENTED (Phase B completed 2026-04-26 — no arch restriction added to the `ntakker` target; universal-binary parity preserved). **Phase:** B (plan-002).
The UI executable MUST ship as a universal binary (arm64 + x86_64)
matching the existing `ntakker-cli` target.

#### NFR-16 — Logging
**Status:** IMPLEMENTED (Phase H completed 2026-04-26). **Phase:** H (plan-002).
UI logs MUST go through the existing `LoggerFactory` / swift-log
pipeline. Default level `.info`; a hidden "Show debug log" toggle
switches to `.debug`. Logs go to a per-UI file at
`~/.tool-agents/ntakker/ntakker.log` (mode `0600`, append) when
running outside an Xcode debugger session.

---

### 1.3 Added 2026-04-26 — Detach mode and `stop` subcommand (overrides OQ-3)

> The OQ-3 lock ("foreground only, no daemon, no PID file, no `stop`
> subcommand") is **overturned by user decision on 2026-04-26**. v1 now
> supports BOTH foreground (default) and detached background execution.
> Foreground mode behavior is unchanged from FR-1..FR-24; the new
> requirements below apply only to detached mode and the `stop`
> subcommand.

#### FR-25 — Detach mode
**Status:** PLANNED. **Phase:** K (CLI flag + daemonization), B (config
keys), J (PID file lifecycle hook).
When `--detach` is passed to `start`, the tool MUST double-fork, write
its PID to `~/.tool-agents/ntakker-cli/ntakker-cli.pid` (or the path resolved via
`--pid-file` / `NTAKKER_PID_FILE`), redirect stdout/stderr to
`~/.tool-agents/ntakker-cli/ntakker-cli.log` (mode `0600`, append), and the parent
process MUST exit 0 immediately while recording continues in the
detached child.

#### FR-26 — `stop` subcommand
**Status:** PLANNED. **Phase:** K.
The CLI MUST expose a `stop` subcommand that reads the PID file and
sends `SIGTERM` to the running process, waiting up to `--stop-timeout`
seconds (default 35) for clean shutdown. Behavior MUST distinguish
between (a) no PID file present, (b) PID file present but process gone
(stale), (c) process alive and stopped cleanly, (d) process alive but
did not exit within timeout. The `stop` subcommand does NOT require any
TCC permission.

#### FR-27 — PID file lifecycle
**Status:** PLANNED. **Phase:** J.
The detached process MUST remove its own PID file on every clean exit
path (`SIGINT`, `SIGTERM`, `--max-duration` cap, normal finalize). It
MUST NOT remove the PID file on crash; subsequent `stop` calls detect
and clean up stale files. The PID file is a single line containing the
decimal PID with no trailing whitespace, mode `0600`. Foreground mode
(no `--detach`) does NOT write a PID file.

#### FR-28 — Already-recording guard for detach mode
**Status:** PLANNED. **Phase:** K.
A `start --detach` invocation MUST refuse to start if the resolved PID
file is present and references a live process; it MUST exit with
`NtakkerError.alreadyRecording` and a descriptive stderr message naming
the conflicting PID. If the existing PID is stale (process no longer
alive), the new invocation MUST remove the stale PID file and continue
the start sequence. Foreground `start` (no `--detach`) is exempt from
this check (two foreground recordings to different output files are
allowed).

#### FR-29 — Detach log file
**Status:** PLANNED. **Phase:** K (redirect), B (path resolution).
In detach mode, all logs MUST go to `~/.tool-agents/ntakker-cli/ntakker-cli.log`
at mode `0600`, append-mode. The path is configurable via `--log-file`
and the env var `NTAKKER_LOG_FILE` (full precedence chain applies).
Foreground mode logs to stderr unchanged. v1 does NOT rotate the log
file — the user manages its size.

---

### 1.5 Added 2026-04-26 — Live transcription side-channel (plan-003, REST-rewritten by plan-004)

> The requirements below were appended on 2026-04-26 by Phase 4 (Planner)
> for the live-transcription v1.2 add-on. Source: `docs/design/refined-request-live-transcription.md`
> (FR-45..FR-58, NFR-17..NFR-21, AC-LT-1..AC-LT-25, OQ-LT-1..OQ-LT-7).
> Architectural choices were originally locked in `docs/reference/investigation-live-transcription.md`
> and `docs/research/gemini-live-wire-schema.md`, `docs/research/audio-downsample-conversion.md`,
> and `docs/research/websocket-asyncstream-pattern.md` against a Gemini Live WebSocket
> pipeline. **Plan-004 (`docs/design/plan-004-rest-batch-transcription.md`) supersedes that
> pipeline with a notch-style REST-batch architecture using Gemini's `generateContent`
> endpoint.** The wording of FR-45..FR-58 / NFR-17..NFR-21 below has been refreshed to
> match plan-004 semantics; the original plan-003 wording is preserved in
> `docs/design/plan-003-live-transcription.md` as a historical record. Phase mapping
> below reflects plan-004's Phases A..J.

#### FR-45 — Opt-in transcription side-channel via `--transcribe`
**Status:** PLANNED (Phase G — plan-004). **Phase:** G (plan-004 — wiring in `RecordingSession` + `ConfigResolver` + `NtakkerError`). **Acceptance:** AC-LT-1, AC-LT-2, AC-LT-3, AC-LT-4.
`ntakker-cli` MUST expose an opt-in transcription side-channel selectable via
`--transcribe <none|gemini>` (env: `NTAKKER_TRANSCRIBE`). Default `none`
(no network connections opened, no API keys read, no sidecar files
written). When non-`none`, each buffered audio chunk drives **one REST
per-chunk request** to the configured provider's HTTP endpoint
(Gemini's `generateContent`); there is no persistent socket. Recording
integrity is preserved by isolation: any transcription failure is
non-fatal to the recording (NFR-17). The `gemini-live` value is accepted
as a deprecated alias for `gemini` for one release with a `.notice`
log line.

#### FR-46 — Provider abstraction supports multiple backends
**Status:** PLANNED (Phase C — plan-004). **Phase:** C (plan-004 — `TranscriptionProvider` protocol + conformers). **Acceptance:** AC-LT-3, AC-LT-11, NFR-21.
`NtakkerCore` MUST expose a `TranscriptionProvider` protocol with the
batch-call signature
`func transcribe(samples: [Float], source: SourceTag, options: TranscriptionOptions) async throws -> String`.
Concrete v1 conformers: `NoOpTranscriptionProvider`,
`FakeTranscriptionProvider` (test double), `GeminiRESTTranscriptionProvider`.
The protocol MUST be designed so an additional provider (OpenAI,
Deepgram, AssemblyAI, etc.) can be added without touching call sites
(NFR-21). All conformers must be `Sendable` and safe for concurrent
calls (the manager keeps up to two in-flight calls per source under load).

#### FR-47 — Audio downsampled to 16 kHz mono PCM16 before provider call
**Status:** PLANNED (Phase A — plan-004). **Phase:** A (plan-004 — pure value types incl. `AudioWAVEncoder`; reuses the existing `AudioDownsampler`). **Acceptance:** AC-LT-3.
Captured audio (48 kHz Float32 stereo from `ScreenCaptureKit` /
`AVFoundation`) MUST be downsampled to **16 kHz mono Float32** before
being handed to a provider. The Gemini provider further encodes the
buffered `[Float]` into PCM16 little-endian and wraps it in a 44-byte
WAV header (`audio/wav` MIME) for the REST body. The downsampling
helper is shared across providers so each provider receives the same
input shape regardless of source layout (`mic`, `system`, `mixed`).

#### FR-48 — Per-chunk buffering window of 2.5 s before flush
**Status:** PLANNED (Phase B — plan-004). **Phase:** B (plan-004 — `SourceBuffer` actor). **Acceptance:** AC-LT-2, AC-LT-3, NFR-18, NFR-19.
Per-source `[Float]` ring buffers MUST accumulate ~2.5 s of 16 kHz
mono samples before being drained and submitted to the provider as one
REST request. Flushing is driven by a single `processLoop` Task that
wakes every 0.8 × `chunkSeconds` (≈ 2.0 s). A drain below the
`minSamples` floor (~400 ms / 6 400 samples — Gemini consistently
returns empty text below this) is held in the buffer for the next
tick. On final stop, residual samples are flushed regardless of the
floor with `final: true`. The buffer is bounded: if the accumulator
exceeds `2 × chunkSamples`, the oldest half is dropped and a
`bufferOverflowCount` metric increments (lossy-under-backpressure
contract; recording is never blocked).

#### FR-49 — Energy gate suppresses near-silent chunks (peak < 0.01)
**Status:** PLANNED (Phase A — plan-004). **Phase:** A (plan-004 — `TranscriptSanitizer` pure function). **Acceptance:** AC-LT-3, NFR-19.
After draining a buffer the manager MUST compute the peak absolute
sample value (`TranscriptSanitizer.peak`) and skip the provider call
when peak < `silenceThreshold` (0.01, ≈ −40 dBFS). This prevents
billing and latency for near-silent audio (long pauses between
sentences, silent meeting backgrounds, etc.) while still allowing
quiet speech through. The skipped chunk is dropped — there is no
buffer-and-retry — so the next 2.5 s window starts fresh.

#### FR-50 — Hallucination filter suppresses known-noise tokens
**Status:** PLANNED (Phase A — plan-004). **Phase:** A (plan-004 — `TranscriptSanitizer.clean`). **Acceptance:** AC-LT-3.
After a provider returns text the manager MUST run it through a
hallucination filter (`TranscriptSanitizer.clean`) that trims
whitespace, strips leading punctuation, requires at least one letter
or digit, lowercases the result, and matches against a known
hallucination set (verbatim from notch — e.g. `"thank you"`,
`"thanks"`, `"thanks for watching"`, etc., the canonical short
phrases that streaming and batch ASR systems emit on silent or
non-speech input). A match returns `""`, which suppresses the segment
end-to-end (no event emitted, no sidecar line written).

#### FR-51 — Same-source segments coalesce within 12 s and not at sentence end
**Status:** PLANNED (Phase A — plan-004). **Phase:** A (plan-004 — `SegmentCoalescer` pure function). **Acceptance:** AC-LT-3, AC-LT-7.
A `SegmentCoalescer` MUST extend the most-recent `TranscriptSegment`
in place when the new chunk has the same `source` tag, the gap from
the prior `lastUpdated` to the new chunk is ≤ 12 s, and the prior
segment's text does not end with a sentence-final punctuation mark
(`.!?…`). Otherwise, a new segment is appended. Coalescer output is
expressed via two events on the events stream:
`.segmentAppended(idx, segment)` (new line) and
`.segmentUpdated(idx, segment)` (rewrite of an existing line in
place). Different-source segments never coalesce (preserves the
per-source labelling that `--transcribe-source both` requires).

#### FR-52 — Inline transcript panel shows growing-segment updates in place
**Status:** PLANNED (Phase H — plan-004). **Phase:** H (plan-004 — UI integration). **Acceptance:** AC-LT-7, AC-LT-20.
The `ntakker` popover MUST render a live, scrollable transcript
panel below the level meters (fixed max-height ~120 pt). The panel
appends a new line on `.segmentAppended` and rewrites the
most-recently-appended line in place on `.segmentUpdated` (replacing
the previous text in place when the segment grows, mirroring the
in-place rewrite the on-disk sidecar performs). There is no
"partial vs final" UI distinction in this architecture — segments
just grow. Auto-scroll to the bottom unless the user has scrolled
away (in which case a "Jump to live" affordance appears). Closing the
popover does not stop transcription, only its rendering; on reopen
the most recent N segments are visible.

#### FR-53 — Privacy disclosure tooltip shown on first transcribe start
**Status:** PLANNED (Phase H — plan-004). **Phase:** H (plan-004 — UI integration). **Acceptance:** AC-LT-9, AC-LT-25, NFR-20.
Selecting any non-`None` provider for the first time on a given launch
MUST surface a one-time confirmation dialog explaining that the
captured audio will be sent to a third-party API ("Audio is being
sent to Google" for the Gemini provider). A "Don't show again"
affordance suppresses the dialog for subsequent launches; the
disclosure remains discoverable via tooltip on the picker. The CLI
mode emits the same disclosure once to stderr (and to the detach
log file when `--detach`).

#### FR-54 — Sidecar formats `jsonl` / `txt` / `srt` / `vtt` with `*.transcript.<ext>` infix
**Status:** PLANNED (Phase F — plan-004). **Phase:** F (plan-004 — sidecar writers, including the path fix). **Acceptance:** AC-LT-5, AC-LT-6.
When transcription is enabled, a sidecar transcript file MUST be
written alongside the audio file using the same basename plus the
mandatory `.transcript.` infix (closes R-LT-1 spec-side):
- Single segment, mixed / stereo-split layout: `recording-….m4a` →
  `recording-….transcript.<ext>`.
- Multi-segment (`partNN`): `recording-….part01.m4a` →
  `recording-….part01.transcript.<ext>`.
- `--layout split` with `--transcribe-source both`: two sidecars,
  `recording-….system.transcript.<ext>` AND
  `recording-….mic.transcript.<ext>`.
- `--layout split` with `--transcribe-source mixed|system|mic`: one
  sidecar (`recording-….transcript.<ext>` or, for `system` / `mic`,
  the source-suffixed variant).
Sidecar formats supported in v1: `jsonl` (default — one JSON object
per coalesced segment, line rewritten in place when the segment
extends), `txt` (one line per finished segment), `srt`, `vtt`.

#### FR-55 — Sidecar rotates on `split(nextOutput:)`
**Status:** PLANNED (Phase G — plan-004). **Phase:** G (plan-004 — `RecordingSession.split` calls `manager.rotateSidecar(toAudioURL:)`; sidecar writer surface added in Phase F). **Acceptance:** AC-LT-5, AC-LT-20.
When `RecordingSession.split(nextOutput:)` rotates the audio recorder
to a new `partNN` file, the transcription side-channel MUST also
rotate: close the current sidecar writer(s), open fresh ones at the
new path derived from `nextOutput` via `SidecarPathBuilder`, and
reset the `SegmentCoalescer` so the first segment of the new part is
appended (not coalesced into the previous part's tail). Closes R-LT-5
spec-side. Pause/Resume continues to be handled by the existing
`SessionCoordinator.pause/resume` stop-and-restart path (which builds
a fresh sidecar via `setUpTranscriptionPipelineIfNeeded`).

#### FR-56 — `--transcribe-source both` produces per-source labels in a single sidecar
**Status:** PLANNED (Phases E + F — plan-004). **Phase:** E (TranscriptionManager fans out into per-source `SourceBuffer`s) + F (sidecar writer carries the `source` field on each segment line). **Acceptance:** AC-LT-7, AC-LT-12.
With `--transcribe-source both` (and a non-`split` recording layout),
the `TranscriptionManager` MUST instantiate one `SourceBuffer` per
source (`mic` and `system`), submit independent REST chunks per
source, and emit segments tagged with the originating `SourceTag`. A
single sidecar file is written; each segment line carries
`"source": "mic"` or `"source": "system"`. The split-layout case
(two audio files) gets two sidecars per FR-54. Closes LT-PEND-2
spec-side: `both` is a real per-source fan-out, not a fallback to
`mixed`.

#### FR-57 — Stop drains in-flight provider calls within 5 s
**Status:** PLANNED (Phase E — plan-004). **Phase:** E (plan-004 — `TranscriptionManager.stop`). **Acceptance:** AC-LT-13.
On Stop / SIGINT / SIGTERM, the `TranscriptionManager` MUST: (1) flush
each `SourceBuffer` with `final: true` so any residue ≥ `minSamples`
is sent, (2) await in-flight provider tasks up to a 5 s drain
deadline (cancel any still pending after that), (3) finish the events
stream so subscribers can complete, and (4) close the sidecar
writers. The final on-disk transcript path is surfaced through the
existing post-stop disclosure that already lists audio files.

#### FR-58 — Per-session metrics emitted: chunks sent, billable seconds, error count, last RTT
**Status:** PLANNED (Phases E + H — plan-004). **Phase:** E (manager emits `TranscriptionMetrics`) + H (UI surfaces them in the post-stop summary). **Acceptance:** AC-LT-14.
The transcription subsystem MUST track and emit (at `info` level on
stop, in the post-stop UI summary, and in the JSONL sidecar header
update at finalization):
- Number of REST chunks sent to the provider.
- Total billable audio seconds (sum of chunk durations actually
  submitted, after silence-gating).
- Number of provider errors (`transcriptionProviderFailed` count).
- Last observed RTT (wall-clock seconds for the most recent provider
  round-trip).
- Number of buffer overflow drops (`bufferOverflowCount`).
The first-token / first-partial latency metric from plan-003 is
removed (no streaming, no first-token concept). RTT is the analogous
observable for the REST architecture.

#### Apple Speech Streaming (plan-005)

| FR | Description | Status |
|---|---|---|
| FR-AS-1 | New provider id `apple` for `--transcribe`; on-device streaming via `SpeechAnalyzer` (macOS 26+). | PLANNED (Phase D — plan-005) |
| FR-AS-2 | `NTAKKER_TRANSCRIBE` default flips from `none` to `apple`. | PLANNED (Phase G — plan-005) |
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

#### Additional Cloud STT Engines (plan-007)

The following functional requirements add Azure OpenAI
`gpt-4o-mini-transcribe` (batch REST) and ElevenLabs `scribe_v2`
(batch REST) as additional `TranscriptionProvider` conformers
alongside the existing `NoOp`, `Fake`, `GeminiREST`, `AppleSpeech`,
and `WhisperKit` providers. Both are batch-only in v1; their
streaming variants (Azure `/realtime`, ElevenLabs
`scribe_v2_realtime`) are deferred to plan-007. Apple SpeechAnalyzer
remains the default. See `docs/design/plan-007-additional-stt-engines.md`
for the implementation plan and
`docs/design/configuration-guide.md` §LT-Az / §LT-EL for the new
env vars.

##### Azure OpenAI `gpt-4o-mini-transcribe`

| FR | Description | Status |
|---|---|---|
| FR-AZ-1  | New provider id `azure` for `--transcribe`; batch REST via `AzureOpenAITranscriptionProvider`. URL pattern: `POST {AZURE_OPENAI_ENDPOINT}/openai/deployments/{AZURE_OPENAI_DEPLOYMENT}/audio/transcriptions?api-version={AZURE_OPENAI_API_VERSION}`. | PLANNED (Phase A — plan-007) |
| FR-AZ-2  | Authentication via `api-key: {AZURE_OPENAI_API_KEY}` header (NO `Bearer` prefix). Microsoft Entra ID auth deferred to v2. | PLANNED (Phase A — plan-007) |
| FR-AZ-3  | `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT` are required env vars when `--transcribe azure` is active; missing → `NtakkerError.transcriptionApiKeyMissing(provider:"azure")` (exit 78) or `transcriptionConfigConflict` (exit 64). No fallback values. | PLANNED (Phase A — plan-007) |
| FR-AZ-4  | `AZURE_OPENAI_API_VERSION` is an optional env var with documented starter `2025-03-01-preview` (per plan-007 §13 Az-1). | PLANNED (Phase A — plan-007) |
| FR-AZ-5  | Multipart body: `file` (16 kHz mono Int16 WAV from `AudioWAVEncoder`, ≤ 25 MB), `model` (set to deployment name — required by Azure), `response_format=json`, optional `language` (ISO-639-1 stripped of BCP-47 region), optional `prompt`. | PLANNED (Phase A — plan-007) |
| FR-AZ-6  | Pre-flight 25 MB chunk size check; oversized chunks throw `transcriptionProviderUnavailable` with the 25 MB explanation. | PLANNED (Phase A — plan-007) |
| FR-AZ-7  | Response decoding: `json` format only (`{"text":"..."}`); `verbose_json`, `srt`, `vtt` are NOT supported by `gpt-4o-mini-transcribe` and are NOT requested. | PLANNED (Phase A — plan-007) |
| FR-AZ-8  | Error mapping: HTTP 401 → `transcriptionApiKeyMissing`; 403 → `transcriptionPermissionDenied`; 404 (`DeploymentNotFound`) → `transcriptionConfigConflict` with deployment name; 413 → `transcriptionProviderUnavailable` (25 MB); 429 → retry up to 3× honouring `Retry-After`; 500/503 → retry up to 3× with exponential backoff + ±20% jitter. | PLANNED (Phase A — plan-007) |
| FR-AZ-9  | `openStreamingSession(...)` throws `transcriptionConfigConflict` (batch-only in v1; streaming deferred to plan-007). `supportedModes = [.batch]`. | PLANNED (Phase A — plan-007) |
| FR-AZ-10 | Cost calculation: `audioSecondsBilled / 60 × $0.003` USD; surfaced via existing `TranscriptionMetrics` channel (FR-58). | PLANNED (Phase A — plan-007) |
| FR-AZ-11 | Diagnostic response headers logged at `info`: `apim-request-id`, `x-request-id`, `x-ms-region`, `x-ratelimit-remaining-requests`, `x-ratelimit-remaining-tokens`. | PLANNED (Phase A — plan-007) |
| FR-AZ-12 | `AZURE_OPENAI_API_KEY_EXPIRES_AT` companion env var per CLAUDE.md `<configuration-guide>` rule; warning surfaced ~7 days before expiry. | PLANNED (Phase A — plan-007) |

##### Azure OpenAI Realtime (`gpt-4o-mini-transcribe` over WebSocket — Phase A2, added 2026-04-29)

| FR | Description | Status |
|---|---|---|
| FR-AZ-13 | New provider type `AzureOpenAIRealtimeTranscriptionProvider` (`final class`, `Sendable`, conforms to `TranscriptionProvider`), id `"azure-openai-realtime"`, displayName `"Azure OpenAI Realtime"`, `supportedModes = [.streaming]`. `transcribe(...)` throws `transcriptionConfigConflict`; `openStreamingSession(...)` returns an `AzureOpenAIRealtimeSession`. | PLANNED (Phase A2 — plan-007) |
| FR-AZ-14 | WebSocket connection over `URLSessionWebSocketTask` to `wss://{resource}.openai.azure.com/openai/realtime?api-version=2025-04-01-preview&intent=transcription` (with optional `&deployment={name}` per `AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL`). Auth via `api-key:` header on the upgrade request (no `Bearer` prefix). | PLANNED (Phase A2 — plan-007) |
| FR-AZ-15 | Audio framed as PCM16 little-endian mono **24 kHz** (research §6); chunk = 100 ms = 4,800 bytes raw → 6,400 chars base64; wrapped inside `input_audio_buffer.append` JSON text frames (NOT binary frames). | PLANNED (Phase A2 — plan-007) |
| FR-AZ-16 | 16→24 kHz `AVAudioConverter`-based resample inside the provider (`AudioResampler16to24`); high-quality mode pinned (`sampleRateConverterQuality = .max`); regression test asserts no aliasing > -60 dBFS above source Nyquist. | PLANNED (Phase A2 — plan-007) |
| FR-AZ-17 | Session-update Codable (`RealtimeWireTypes.SessionConfig` and `InputAudioTranscriptionConfig`) **OMITS the `model` field by design** (RT-1 Azure server bug); regression test (`RealtimeWireTypesTests.modelFieldOmitted`) asserts the encoded JSON never contains the substring `"model"`. | PLANNED (Phase A2 — plan-007) |
| FR-AZ-18 | VAD configuration via four optional env vars: `AZURE_OPENAI_REALTIME_VAD_THRESHOLD` (default 0.5), `…VAD_PREFIX_PADDING_MS` (default 300), `…VAD_SILENCE_MS` (default 200), `AZURE_OPENAI_REALTIME_NOISE_REDUCTION` (`near_field` \| `far_field` \| `none`, default `near_field`). Invalid values throw `transcriptionConfigConflict` at provider construction. | PLANNED (Phase A2 — plan-007) |
| FR-AZ-19 | Delta events (`conversation.item.input_audio_transcription.delta`) are surfaced as `StreamingTranscriptionEvent.partial` on the session's `events: AsyncStream<StreamingTranscriptionEvent>`; final transcripts (`…completed`) as `.final`; per-item failures (`…failed`) as `.error`; rate-limit / session errors as `.error`. UI consumes the same channel as Apple SpeechAnalyzer / Gemini Live. | PLANNED (Phase A2 — plan-007) |
| FR-AZ-20 | WebSocket close 1006 (and 1001 / 1011) triggers reconnect-with-replay: the provider holds the last 5 s of audio in `AudioRingBuffer<Int16>` (capacity 120,000 = 5 s × 24 kHz), reconnects with a new `URLSessionWebSocketTask`, re-sends `transcription_session.update`, and replays the buffered audio in 100 ms chunks. Capped at 3 attempts within 30 s; surfaces `AzureOpenAIRealtimeError.reconnectExhausted` if exceeded. Dedupe-by-overlap protects against double-final from the replay window (RT-RISK-3). | PLANNED (Phase A2 — plan-007) |
| FR-AZ-21 | Pre-emptive reconnect at 58 minutes to avoid the Azure 60-minute hard session cap (RT-4). The provider waits for the next `input_audio_buffer.committed` (or `speech_stopped`) event before reconnecting (capped at 90 s wait) so an in-flight utterance is not interrupted (RT-RISK-4). | PLANNED (Phase A2 — plan-007) |
| FR-AZ-22 | Realtime cost calculation: per-minute model `audioMinutes × $0.003` USD where `audioMinutes = audioSamplesCommitted / (24000 × 60)`. `audioSamplesCommitted` increments on `input_audio_buffer.committed` events (so cost reflects what Azure actually charges). Surfaced via the existing `TranscriptionMetrics.estimatedCostUSD` channel. | PLANNED (Phase A2 — plan-007) |
| FR-AZ-23 | New CLI mode `--transcribe azure-openai-realtime`. New `TranscriptionProviderId.azureOpenAIRealtime = "azure-openai-realtime"` enum case. `TranscriptionProviderFactory.build(_:)` gains a new case branch; missing required env (`AZURE_OPENAI_API_KEY` / `_ENDPOINT` / `_DEPLOYMENT`) throws `transcriptionApiKeyMissing` (exit 78) or `transcriptionConfigConflict` (exit 64). | PLANNED (Phase A2 — plan-007) |
| FR-AZ-24 | New picker entry "Azure OpenAI Realtime (cloud, streaming)" in `TranscriptionPicker.swift` (the existing batch entry is relabelled to "Azure OpenAI (cloud, batch)" for disambiguation). The inline key-entry section additionally shows the resolved VAD config (read-only) when the active provider is `azure-openai-realtime`. | PLANNED (Phase A2 — plan-007) |
| FR-AZ-25 | Privacy disclosure variant for realtime streaming: a new `bodyText(for: "azure-openai-realtime")` string emphasising that audio is *streamed* live and is NOT retained per Azure data privacy, plus the 60-min session cap. Per-provider acknowledgement persistence key `com.local.ntakker.transcription.privacy.azure-openai-realtime.acknowledged` is independent of the batch Azure key. | PLANNED (Phase A2 — plan-007) |

##### ElevenLabs `scribe_v2`

| FR | Description | Status |
|---|---|---|
| FR-EL-1  | New provider id `elevenlabs` for `--transcribe`; batch REST via `ElevenLabsTranscriptionProvider`. URL: `POST https://api.elevenlabs.io/v1/speech-to-text`. | PLANNED (Phase B — plan-007) |
| FR-EL-2  | Authentication via `xi-api-key: {ELEVENLABS_API_KEY}` header. | PLANNED (Phase B — plan-007) |
| FR-EL-3  | `ELEVENLABS_API_KEY` is the only required env var; missing → `NtakkerError.transcriptionApiKeyMissing(provider:"elevenlabs")` (exit 78). No fallback. | PLANNED (Phase B — plan-007) |
| FR-EL-4  | Optional env vars resolved through the four-tier chain: `ELEVENLABS_MODEL_ID` (default `scribe_v2`), `ELEVENLABS_LANGUAGE_CODE` (auto-detect when unset), `ELEVENLABS_DIARIZE` (default `false`), `ELEVENLABS_TAG_AUDIO_EVENTS` (default `true`), `ELEVENLABS_NUM_SPEAKERS` (1..32, hint when known), `ELEVENLABS_FILE_FORMAT` (default `pcm_s16le_16` low-latency fast-path), `ELEVENLABS_ENTITY_DETECTION` (OFF by default per plan-007 §13 EL-2 — opt-in carries +30% cost surcharge). | PLANNED (Phase B — plan-007) |
| FR-EL-5  | Multipart body: `model_id`, `file_format=pcm_s16le_16` (always-on with `AudioWAVEncoder` output per plan-007 §13 EL-3), `file` (16 kHz mono Int16 WAV), optional `language_code`, `diarize`, `num_speakers`, `tag_audio_events`, `timestamps_granularity`, `entity_detection`. | PLANNED (Phase B — plan-007) |
| FR-EL-6  | Pre-flight checks: chunks > 3 GB throw `transcriptionProviderUnavailable`; chunks > 4.5 hr throw `transcriptionProviderUnavailable`; chunks < 100 ms short-circuit to empty string (no network call). | PLANNED (Phase B — plan-007) |
| FR-EL-7  | Response decoding: `text`, `language_code`, `language_probability`, `words[]` (with `start`, `end`, `type`, optional `speaker_id` when diarize=true). Multi-channel and webhook variants are NOT requested in v1. | PLANNED (Phase B — plan-007) |
| FR-EL-8  | Error mapping: HTTP 401 → `transcriptionApiKeyMissing`; 402 (`insufficient_credits`) → `transcriptionProviderUnavailable`; 403 → `transcriptionProviderUnavailable` (plan gate); 413 → 3 GB explanation; 422 (`audio_too_long`) → 4.5 hr explanation; 422 (`invalid_parameters`) → `transcriptionConfigConflict`; 429 (`rate_limit_exceeded` / `system_busy`) → exponential backoff (no `Retry-After` header) up to 3 attempts; 429 (`concurrent_limit_exceeded`) surfaces immediately (no retry); 500/503 → retry up to 3×. | PLANNED (Phase B — plan-007) |
| FR-EL-9  | `openStreamingSession(...)` throws `transcriptionConfigConflict` pointing to plan-007 (`scribe_v2_realtime` deferred). `supportedModes = [.batch]`. | PLANNED (Phase B — plan-007) |
| FR-EL-10 | Cost calculation: `audioSecondsBilled / 3600 × $0.22` USD base; +30% when `entity_detection` enabled. Surfaced via existing `TranscriptionMetrics` channel. | PLANNED (Phase B — plan-007) |
| FR-EL-11 | Diagnostic response headers logged at `info`: `current-concurrent-requests`, `maximum-concurrent-requests`. | PLANNED (Phase B — plan-007) |
| FR-EL-12 | SRT/VTT generated from `words[].start/end` via existing in-tree writers; ElevenLabs `additional_formats` API field NOT requested in v1 (per plan-007 §13 EL-1). | PLANNED (Phase B — plan-007) |
| FR-EL-13 | `ELEVENLABS_API_KEY_EXPIRES_AT` companion env var per CLAUDE.md `<configuration-guide>` rule. | PLANNED (Phase B — plan-007) |

##### Cross-cutting (Phase 0 + Phase C + Phase D — plan-007)

| FR | Description | Status |
|---|---|---|
| FR-XS-1  | Pre-existing drift fix: `TranscriptionProviderId` enum gains `case whisperkit` so `NTAKKER_TRANSCRIBE=whisperkit` no longer throws `invalidConfigValue` at parse time. | PLANNED (Phase 0 — plan-007) |
| FR-XS-2  | `ControlBar.startTapped()` API-key resolution generalised to dispatch on the active provider id (`gemini` → `GOOGLE_API_KEY`, `azure` → `AZURE_OPENAI_API_KEY`, `elevenlabs` → `ELEVENLABS_API_KEY`); fixes the latent hardcoded `GOOGLE_API_KEY` bug. | PLANNED (Phase 0 — plan-007) |
| FR-XS-3  | `PrivacyDisclosureSheet` gains provider-specific body text and per-provider acknowledgement persistence keys (`com.local.ntakker.transcription.privacy.{providerId}.acknowledged`); migration propagates the legacy single-boolean to the Gemini-specific key. | PLANNED (Phase 0 — plan-007) |
| FR-XS-4  | New reusable `ProviderKeyField` SwiftUI component replaces `GeminiKeyField`; consumed by Gemini, Azure, and ElevenLabs key-entry surfaces. | PLANNED (Phase 0 — plan-007) |
| FR-XS-5  | New shared `MultipartFormDataBuilder` value type under `Sources/NtakkerCore/Transcription/Net/` consumed by both new providers; pure Foundation, no SPM dep. | PLANNED (Phase 0 — plan-007) |
| FR-XS-6  | `TranscriptionPicker` gains "Azure OpenAI (cloud)" and "ElevenLabs Scribe v2 (cloud)" entries in the existing flat list (per plan-007 §13 UI-1). | PLANNED (Phase C — plan-007) |
| FR-XS-7  | Configuration guide gains §LT-Az (5 Azure env vars) and §LT-EL (8 ElevenLabs env vars) with purpose, how to obtain, options, defaults, expiration tracking. | PLANNED (Phase D — plan-007) |
| FR-XS-8  | `docs/tools/ntakker-cli.md` and `docs/tools/ntakker.md` updated to list `azure` and `elevenlabs` as valid `--transcribe` modes / picker entries; new privacy-disclosure copy documented. | PLANNED (Phase D — plan-007) |

#### AC-LT-1..AC-LT-25 — Acceptance criteria mapping (REST-batch verification)

The full AC-LT-* statements are defined in
`docs/design/refined-request-live-transcription.md` §AC-LT. The table
below maps each criterion to the verifying test artefact in the
plan-004 architecture (per plan-004 §8.7). Items whose original
formulation was tied to WebSocket-specific behaviour (close codes,
session-resumption tokens, sliding-window context limits) are
explicitly superseded.

| AC | Verification mechanism (plan-004) |
|---|---|
| AC-LT-1 (None is the default and a true no-op) | `test_scripts/e2e-transcription-noop.sh` — asserts no `*.transcript.*` file appears in the output folder when `--transcribe` is absent or `none`. |
| AC-LT-2 (sidecar exists with `--transcribe gemini`) | `test_scripts/e2e-transcription-gemini.sh` — asserts a `*.transcript.jsonl` sidecar with ≥ 2 segments. |
| AC-LT-3 (recording integrity unaffected by transcription) | Audio-file assertions in both e2e scripts above + `RecordingIntegrityIsolationTests` (hanging `FakeTranscriptionProvider` injection asserts byte-identical audio file). |
| AC-LT-4 (no audio file when key missing) | `test_scripts/e2e-transcription-key-missing.sh` — exit 78, no audio file, no sidecar. |
| AC-LT-5 (sidecar filename `.transcript.` infix per segmentation) | `SidecarPathBuilderTests` (every layout / source / partNN combination) + e2e file glob assertion. |
| AC-LT-6 (sidecar formats valid: jsonl / txt / srt / vtt) | Per-format unit tests in `Tests/NtakkerCoreTests/Transcription/Persistence/*WriterTests.swift` with golden fixtures. |
| AC-LT-7 (live UI panel shows growing-segment updates in place) | `RecordingControllerTranscriptTests` — `.segmentAppended` adds a line, `.segmentUpdated` rewrites the most-recent line in place. |
| AC-LT-8 (UI surfaces missing-key state) | UI test on `TranscriptionMissingKeyBadge` (red badge + tooltip when `transcriptionMissingKey == true`). |
| AC-LT-9 (privacy disclosure on first opt-in) | UI test on `TranscriptionPrivacyAlert` + `@AppStorage("…transcribePrivacyAccepted")`. |
| AC-LT-10 — superseded by plan-004. | Plan-003's AC-LT-10 specified WebSocket reconnect-on-transient-failure; the REST architecture has no persistent socket so this criterion no longer applies. The closest analogue is the per-chunk non-fatal failure posture in NFR-21 (verified via `URLProtocol`-stub provider unit tests for 4xx / 5xx / transport error → `transcriptionProviderFailed`, recording continues). |
| AC-LT-11 (bounded queue drops, never blocks) | `SourceBufferOverflowTests` — `> 2 × chunkSamples` triggers `bufferOverflowCount` and drops oldest half; downstream pipeline is never blocked. |
| AC-LT-12 (source selection routes correctly) | `TranscriptionManagerSourceRoutingTests` (`mic` / `system` / `mixed` / `both`) + `e2e-transcription-gemini.sh` source-flag variants. |
| AC-LT-13 (clean shutdown drains finals) | `TranscriptionManagerLifecycleTests` — `start → ingest N synthetic frames → stop` produces expected event count within 5 s drain bound. |
| AC-LT-14 (cost / volume metrics emitted) | `TranscriptionMetricsTests` (chunks sent, billable seconds, error count, last RTT, overflow count) + UI test on the post-stop summary line. |
| AC-LT-15 (`ntakker-cli start --help` lists all new flags) | `StartCommandHelpTests` — snapshot of `--help` output includes `--transcribe`, `--transcribe-source`, `--transcript-format`, `--transcribe-model`, `--transcribe-language`, `--transcribe-key-expires-at`. |
| AC-LT-16 (`--transcribe none` is the default; zero behaviour change) | `e2e-transcription-noop.sh` + the existing AC-1..AC-20 / AC-UI-1..AC-UI-18 e2e suite (which run unchanged when `--transcribe` is absent). |
| AC-LT-17 (invalid provider name → exit 64) | `ConfigResolverTranscriptionTests` — `--transcribe foobar` raises `transcriptionInvalidConfigValue`, exit 64. |
| AC-LT-18 (live transcription picker present in popover) | UI test on `TranscriptionPicker` + DisclosureGroup; persisted defaults loaded from `@AppStorage`. |
| AC-LT-19 (picker disabled while recording) | UI test using the same `isLocked` computed pattern as `FormatPicker`. |
| AC-LT-20 (transcript panel survives Pause/Resume / Split across segments) | `e2e-transcription-gemini.sh` split variant — sidecar rotates per `partNN`; coalescer reset asserted via JSONL line count per part. |
| AC-LT-21 (`docs/tools/ntakker-cli.md` updated) | Manual review at plan-004 Phase J.5. |
| AC-LT-22 (`docs/tools/ntakker.md` updated) | Manual review at plan-004 Phase J.6. |
| AC-LT-23 (`docs/design/configuration-guide.md` updated) | Manual review at plan-004 Phase 0.5. |
| AC-LT-24 (`docs/design/project-functions.md` updated) | This section is the deliverable — verified at plan-004 Phase 0.7. |
| AC-LT-25 (privacy disclosure shown on first start) | UI test (covered by AC-LT-9 mechanism). |

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

Three plan-003 AC-LT items keyed to WebSocket-specific behaviour
(close codes, session-resumption tokens, sliding-window context
limits) were already superseded by removal in the migration from
plan-003 to plan-004 — the closing of `Sources/NtakkerCore/Transcription/Networking/`
removes the surfaces these AC items asserted on. AC-LT-10 is the
single explicit "AC-N — superseded by plan-004" line above; the
other two surfaces were never named as standalone AC numbers in
the refined request and need no separate disposition line here.

---

### 1.6 Added 2026-04-29 — Soniox real-time streaming provider (plan-006)

> The requirements below are appended on 2026-04-29 by Phase 4
> (Planner) for the Soniox cloud-streaming provider add-on. Source:
> `docs/design/refined-request-soniox-streaming.md` (FR-SX-1..FR-SX-18,
> NFR-SX-1..NFR-SX-7, AC-SX-1..AC-SX-18, A-SX-1..A-SX-10,
> OQ-SX-1..OQ-SX-12). Architectural choices are locked in
> `docs/reference/investigation-soniox-streaming.md` and
> `docs/research/soniox-wire-schema.md`. Phase mapping below reflects
> `docs/design/plan-006-soniox-streaming.md` Phases 0 / A / B / C / D / H / I.
> Soniox is **additive**: the Apple Speech default (`--transcribe apple`)
> is preserved; Gemini REST and WhisperKit are preserved; Soniox
> becomes the fifth allowed value for `--transcribe`
> (`none | apple | gemini | whisperkit | soniox`).

#### FR-SX-1 — Provider id `soniox` accepted by `--transcribe`
**Status:** PLANNED (Phase B — plan-006). **Phase:** B (plan-006 —
`TranscriptionProviderId.soniox` enum case + `ConfigResolver`
validation). **Acceptance:** AC-SX-1, AC-SX-17.
The `--transcribe` CLI flag and `NTAKKER_TRANSCRIBE` env var MUST
accept the literal value `soniox` in addition to the existing
`none | apple | gemini | whisperkit` set. Invalid values continue to
fail with exit 64 (`EX_USAGE`) per AC-LT-17.

#### FR-SX-2 — `SonioxStreamingTranscriptionProvider` conformer
**Status:** PLANNED (Phase D — plan-006). **Phase:** D (plan-006 —
provider + session). **Acceptance:** AC-SX-7.
A new type `SonioxStreamingTranscriptionProvider` MUST be added under
`Sources/NtakkerCore/Transcription/Providers/` conforming to the
existing `TranscriptionProvider` protocol (FR-46), declaring
`supportedModes = [.streaming]`. The provider MUST be `Sendable`
and safe for concurrent calls from `TranscriptionManager`. The
streaming session is hosted in
`Sources/NtakkerCore/Transcription/Live/Soniox/SonioxStreamingSession.swift`
and owns one `URLSessionWebSocketTask` per source.

#### FR-SX-3 — Soniox API key resolution via the four-tier chain
**Status:** PLANNED (Phase B — plan-006). **Phase:** B (plan-006 —
`ConfigResolver` + `Keys.sonioxApiKey`). **Acceptance:** AC-SX-5.
The provider MUST read its API key through the existing
`ConfigResolver` four-tier chain (shell env → `~/.tool-agents/ntakker-cli/.env`
→ local `./.env` → CLI flag). The vendor-canonical env var name
`SONIOX_API_KEY` MUST be used (confirmed by Soniox docs). NO
`--soniox-api-key` CLI flag is exposed (parity with `GOOGLE_API_KEY`
per NFR-20). If the key is absent at session start AND
`--transcribe soniox` is selected, the resolver MUST raise
`NtakkerError.transcriptionApiKeyMissing(provider:envVar:sources:)`
(exit 78, `EX_CONFIG`); no audio file is created (AC-LT-4 parity).

#### FR-SX-4 — No fallback for the API key
**Status:** PLANNED (Phase B — plan-006). **Phase:** B. **Acceptance:** AC-SX-5.
Per CLAUDE.md "no fallback solutions for configuration settings",
a missing API key MUST raise an exception. The provider MUST NOT
fall back to any default endpoint, demo key, or anonymous mode.

#### FR-SX-5 — API-key expiration companion variable
**Status:** PLANNED (Phase B — plan-006). **Phase:** B. **Acceptance:** AC-SX-16.
The shared `NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT` (defined in plan-004
for the Gemini key) MUST be honoured for Soniox keys: if set and in
the past, log a `.warning` at start; recording is NOT blocked. A
new Soniox-scoped variant `NTAKKER_SONIOX_KEY_EXPIRES_AT` MAY be
added with provider-scoped > shared resolution precedence (per
OQ-SX-12 default) so users with multiple cloud-provider keys with
divergent expiry dates can disambiguate.

#### FR-SX-6 — Optional model id override
**Status:** PLANNED (Phase D — plan-006). **Phase:** D. **Acceptance:** (covered by AC-SX-1 / AC-SX-2 / AC-SX-3 implicitly via successful default-model recognition.)
The existing `--transcribe-model` flag and `NTAKKER_TRANSCRIBE_MODEL`
env var MUST be accepted by the Soniox provider. The provider MUST
ship with a pinned default model id `stt-rt-v4` (locked by
investigation OQ-SX-4). Unknown model ids MUST be allowed through
(with an `info` log line) so users can opt into newer models without
a code change.

#### FR-SX-7 — Optional region / endpoint override
**Status:** PLANNED (Phases B + H — plan-006). **Phase:** B (resolver +
options field) + H (CLI flag). **Acceptance:** (covered by
ConfigResolverTranscriptionTests endpoint case.)
A new optional config var `NTAKKER_SONIOX_ENDPOINT` (CLI flag
`--soniox-endpoint <url>`) MUST be accepted to point the provider at
a non-default Soniox endpoint (regional variants
`wss://stt-rt.eu.soniox.com/transcribe-websocket` and
`wss://stt-rt.jp.soniox.com/transcribe-websocket`, dedicated
endpoints, or future self-hosted). Default:
`wss://stt-rt.soniox.com/transcribe-websocket`. The flag MUST follow
the same four-tier resolution chain as every other config value.

#### FR-SX-8 — Audio format adaptation
**Status:** PLANNED (Phase D — plan-006). **Phase:** D (in-provider
Float32 → Int16 LE conversion).
The provider MUST accept the project's internal Float32 mono 16 kHz
buffers (the same shape every other provider gets via
`AudioDownsampler`) and convert them to raw PCM16 little-endian at
16 kHz mono inside the provider conformer. Soniox's WebSocket
endpoint accepts `pcm_s16le` natively, so the conversion is a
straightforward `withUnsafeBufferPointer` packing. The existing
`AudioDownsampler` is reused without modification; no
`AudioWAVEncoder` is needed for Soniox.

#### FR-SX-9 — Language strategy: Greek + English primary
**Status:** PLANNED (Phase C + Phase D — plan-006). **Phase:** C
(`SonioxLanguageHintMapper`) + D (provider applies default).
**Acceptance:** AC-SX-2, AC-SX-3, AC-SX-4.
The provider MUST default to `language_hints: ["el", "en"]` with
`language_hints_strict: false` and `enable_language_identification:
true` when the user does NOT pass `--transcribe-language`. Soniox's
`language_hints` is a native ISO 639-1 array; the provider MUST
parse the user's BCP-47 input, strip region tags (`el-GR` → `el`,
`en-US` → `en`, `en-GB` → `en`), deduplicate preserving order, and
forward as the hint list. Comma-separated multi-language hints
(parity with the `apple` provider) are honoured natively (resolves
OQ-SX-7).

#### FR-SX-10 — Per-segment language tagging
**Status:** PLANNED (Phase C + Phase D — plan-006). **Phase:** C
(`SonioxTokenAggregator`) + D (provider populates segment).
**Acceptance:** AC-SX-2, AC-SX-3, AC-SX-4.
Each segment emitted by Soniox MUST be tagged with its detected
ISO 639-1 language code on the `language` field of the sidecar
record (parity with the `apple` provider's FR-AS-4 / FR-AS-6). For
TXT / SRT / VTT writers, when ≥ 2 distinct languages appear in a
session the cue body MUST be prefixed with `[lang]` (parity with
FR-AS-6).

#### FR-SX-11 — Sidecar parity
**Status:** PLANNED (Phase D — plan-006; reuses existing sidecar
pipeline). **Phase:** D (provider sets `model: "soniox"` on each
segment).
Soniox sidecar files MUST follow the existing sidecar conventions:
`*.transcript.<ext>` infix (FR-54), `partNN` rotation on
`split(nextOutput:)` (FR-55), per-source labelling in
`--transcribe-source both` (FR-56), and the standard set of formats
(`jsonl`, `txt`, `srt`, `vtt`). The `model` field on each segment
line MUST equal `"soniox"`.

#### FR-SX-12 — Detach mode supported
**Status:** PLANNED (inherits plan-005 lift; no plan-006 work).
**Acceptance:** AC-SX-10.
`ntakker-cli start --detach --transcribe soniox` MUST work end-to-end
(parity with plan-005 FR-AS-10).

#### FR-SX-13 — Pause / Resume / Split parity
**Status:** PLANNED (Phase D — plan-006). **Phase:** D
(`SonioxStreamingSession.pause / resume / finish`). **Acceptance:**
AC-SX-11.
Pause/Resume MUST produce a clean utterance boundary by sending the
Soniox `{"type":"finalize"}` control message on Pause and waiting
for the `<fin>` marker. `split(nextOutput:)` MUST close the current
WebSocket cleanly (empty TEXT frame `""`, await `finished` up to
2 s) and open a fresh WebSocket for the next sidecar (Soniox does
not support session resumption).

#### FR-SX-14 — Stop drains in-flight provider work within 5 s
**Status:** PLANNED (Phase D — plan-006). **Phase:** D
(`SonioxStreamingSession.finish`). **Acceptance:** AC-SX-12.
Parity with FR-57. On Stop / SIGINT / SIGTERM, the Soniox provider's
session(s) MUST be closed cleanly (empty-frame close + await
`finished`) within the 5 s drain deadline, with cancellation of any
still-pending work after that.

#### FR-SX-15 — Per-session metrics
**Status:** PLANNED (Phase D — plan-006). **Phase:** D. **Acceptance:**
AC-SX-13.
The provider MUST report into the existing `TranscriptionMetrics`
aggregate (FR-58): chunks (binary frames) sent, messages (chunks +
control messages) sent, billable seconds (sum of final-token
durations), error count, last RTT, first-partial latency P95,
endpoint latency P95.

#### FR-SX-16 — Privacy disclosure on first opt-in
**Status:** PLANNED (Phase H — plan-006). **Phase:** H
(`PrivacyDisclosureSheet`). **Acceptance:** AC-SX-9.
Selecting Soniox in the UI picker for the first time on a given
launch MUST surface the same one-time confirmation dialog the
Gemini provider uses, with body text adapted to name Soniox as the
destination ("Audio is being sent to Soniox (soniox.com) for
transcription. Set the org-level data retention preferences in the
Soniox console at console.soniox.com."). Parity with FR-53 / AC-LT-9
/ AC-LT-25 / NFR-20.

#### FR-SX-17 — UI picker option
**Status:** PLANNED (Phase H — plan-006). **Phase:** H
(`TranscriptionPicker`). **Acceptance:** AC-SX-8.
The `ntakker` popover's live-transcription provider picker MUST
list `Soniox (cloud, streaming)` as a fifth option in the order
`None`, `Apple`, `Gemini`, `WhisperKit`, `Soniox` (per OQ-SX-8
default; user may override). Persisted via the existing
`@AppStorage("com.ntakker-cli.ui.transcribeProvider")` key. Disabled
while recording (parity with AC-LT-19).

#### FR-SX-18 — `--help` and documentation surfaces updated
**Status:** PLANNED (Phases 0 + H + I — plan-006). **Phase:** 0 +
H + I. **Acceptance:** AC-SX-14.
`ntakker-cli start --help` output MUST list `soniox` in the allowed set
for `--transcribe`, and the surrounding doc files (`docs/tools/ntakker-cli.md`,
`docs/tools/ntakker.md`, `docs/design/configuration-guide.md`,
`docs/design/project-functions.md`, `docs/design/project-design.md`,
and the new `docs/design/plan-006-soniox-streaming.md`) MUST be
updated to name Soniox, its env vars, model id, endpoint flag,
language strategy, and sidecar behaviour.

#### Soniox AC mapping (plan-006)

| AC | Description | Verification mechanism (plan-006) |
|---|---|---|
| AC-SX-1 | `--transcribe soniox` produces a sidecar with ≥ 2 segments and `model:"soniox"`, exit 0. | `test_scripts/e2e-transcription-soniox.sh` (real key) |
| AC-SX-2 | Greek e2e: ≥ 5 keyword hits in concatenated text; first matched segment `language` starts with `el`. | `test_scripts/e2e-transcription-soniox-greek.sh` (real key) |
| AC-SX-3 | English e2e: ≥ 5 keyword hits; first matched segment `language` starts with `en`. | `test_scripts/e2e-transcription-soniox-english.sh` (real key) |
| AC-SX-4 | Bilingual single-recording: ≥ 1 `el`-tagged + ≥ 1 `en`-tagged segment. | `test_scripts/e2e-transcription-soniox-bilingual.sh` (real key) |
| AC-SX-5 | Missing `SONIOX_API_KEY` + `--transcribe soniox` exits 78; no audio file; no sidecar; stderr names `SONIOX_API_KEY`. | `test_scripts/e2e-transcription-soniox-key-missing.sh` (always runs) |
| AC-SX-6 | Recording integrity isolated from Soniox failures (audio file byte-identical to control with `--transcribe none`). | `RecordingIntegrityIsolationTests` with `SonioxAlwaysFailingFake` injection |
| AC-SX-7 | Provider conforms to existing `TranscriptionProvider` protocol; `swift build` clean. | `swift build --product ntakker-cli && swift build --product ntakker` |
| AC-SX-8 | UI picker lists `Soniox` as the 5th entry. | `TranscriptionPickerSnapshotTests` + `TranscriptionPickerSelectionTests` |
| AC-SX-9 | Privacy disclosure shown on first Soniox start; "Don't show again" suppresses subsequent shows. | `PrivacyDisclosureSheetTests` (UI test) |
| AC-SX-10 | Detach + Soniox produces sidecar; exit 0. | `test_scripts/e2e-transcription-soniox-detach.sh` (real key) |
| AC-SX-11 | Pause/Resume + manual `split()` rotates sidecar atomically; each `partNN` audio has matching `partNN.transcript.jsonl`. | `test_scripts/e2e-transcription-soniox-split.sh` (real key) |
| AC-SX-12 | Stop drains within 5 s wall-clock. | `SonioxStreamingTranscriptionProviderTests` (stop-drain test with `MockClock`) |
| AC-SX-13 | Per-session metrics emitted on stop (chunksSent, billableSeconds, errorCount, lastRTT non-nil). | `SonioxStreamingTranscriptionProviderTests` (metrics test) |
| AC-SX-14 | Help text and docs updated (5 doc files name Soniox + env vars). | `StartCommandHelpTests` + manual review of `docs/tools/ntakker-cli.md`, `docs/tools/ntakker.md`, `docs/design/configuration-guide.md`, `docs/design/project-functions.md`, `docs/design/project-design.md` |
| AC-SX-15 | No new SPM dependency unless documented. | `git diff --stat Package.swift` is empty |
| AC-SX-16 | Past `NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT` (or Soniox-scoped variant) logs `.warning`; recording NOT blocked. | `ConfigResolverTranscriptionTests` (past-expiry test) |
| AC-SX-17 | `--transcribe foobar` and `--transcribe soniox-streaming` both exit 64 with remediation listing the five accepted values. | `ConfigResolverTranscriptionTests` (close-but-wrong test) |
| AC-SX-18 | Latency observability: P50/P95 first-partial + end-of-utterance-to-final logged at session stop; warn on exceed. | `SonioxStreamingTranscriptionProviderTests` (latency observability test) |

---

### Added by plan-007 — Additional STT engines (Azure OpenAI batch + realtime + ElevenLabs)

#### FR-AZ-1 — Azure OpenAI batch (REST) provider
**Status:** IMPLEMENTED (Phase A1 — plan-007). **Phase:** A1.
`NTAKKER_TRANSCRIBE=azure` activates a Foundation-only REST batch
provider that POSTs each chunk (16 kHz mono Int16 WAV) to
`{AZURE_OPENAI_ENDPOINT}/openai/deployments/{deployment}/audio/transcriptions?api-version=...`
with `api-key: {AZURE_OPENAI_API_KEY}` and `model={deployment}`.
Decodes the `{ "text": "..." }` envelope. `supportedModes = [.batch]`.

#### FR-AZ-2 — Azure OpenAI realtime (WebSocket) provider
**Status:** IMPLEMENTED (Phase A2 — plan-007). **Phase:** A2.
`NTAKKER_TRANSCRIBE=azure-openai-realtime` activates a Foundation
`URLSessionWebSocketTask`-based provider streaming 100 ms PCM16 24 kHz
mono base64-wrapped JSON envelopes to
`wss://{AZURE_OPENAI_ENDPOINT-host}/openai/realtime?api-version=2025-04-01-preview&intent=transcription`.
Surfaces volatile partials (`StreamingTranscriptionEvent.partial`)
and stable finals (`.final`). `supportedModes = [.streaming]`.

#### FR-AZ-3 — Azure realtime reconnect-with-replay
**Status:** IMPLEMENTED (Phase A2 §A2.7 — plan-007). **Phase:** A2.
WebSocket close codes 1006 / 1001 / 1011 trigger a transparent
reconnect attempt with a 5 s replay of the trailing audio buffer.
Up to 3 attempts within a 30 s window; exhaustion surfaces
`AzureOpenAIRealtimeError.reconnectExhausted`. Code 1008 (auth
policy violation) surfaces immediately without retry.

#### FR-AZ-4 — Azure realtime 60-min session boundary
**Status:** IMPLEMENTED (Phase A2 §A2.8 — plan-007). **Phase:** A2.
The provider pre-emptively reconnects at 58 min so the 60-min
Azure cap never severs an in-flight recording. Long recordings
continue uninterrupted.

#### FR-AZ-5 — Azure RT-1 model-field-rejection guard
**Status:** IMPLEMENTED (Phase A2 §A2.5 — plan-007). **Phase:** A2.
`RealtimeWireTypes.SessionConfig` and `InputAudioTranscriptionConfig`
have NO `model` property at all so the encoded `transcription_session.update`
JSON cannot carry the field that triggers Azure's known
`server_error`. Codable round-trip test
(`RealtimeWireTypesTests.modelFieldOmitted`) asserts the substring
`"model"` is absent from the encoded payload.

#### FR-AZ-6 — Azure configuration variables
**Status:** IMPLEMENTED (Phase A1 + A2 §5 — plan-007). **Phase:**
Phase 0 (resolver) + Phase A1/A2 (factory). `AZURE_OPENAI_API_KEY`,
`AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT` are required
when either Azure provider is active; `AZURE_OPENAI_API_VERSION`
defaults to `2025-04-01-preview` (documented starter); the four
realtime VAD/noise/include/url knobs are optional with documented
protocol defaults. Missing required → `transcriptionApiKeyMissing`
(exit 78) or `transcriptionConfigConflict` (exit 64) at config-load.

#### FR-EL-1 — ElevenLabs Scribe v2 provider
**Status:** IMPLEMENTED (Phase B — plan-007). **Phase:** B.
`NTAKKER_TRANSCRIBE=elevenlabs` activates a Foundation REST batch
provider POSTing each chunk to
`https://api.elevenlabs.io/v1/speech-to-text` with `xi-api-key`.
Decodes `{ language_code, language_probability, text, words[] }`.
`supportedModes = [.batch]`.

#### FR-EL-2 — ElevenLabs configuration variables
**Status:** IMPLEMENTED (Phase B §5 — plan-007). **Phase:** Phase
0 (resolver) + Phase B (factory). `ELEVENLABS_API_KEY` required;
optional `ELEVENLABS_MODEL_ID` (default `scribe_v2`),
`ELEVENLABS_LANGUAGE_CODE`, `ELEVENLABS_DIARIZE` (default false),
`ELEVENLABS_TAG_AUDIO_EVENTS` (default true),
`ELEVENLABS_NUM_SPEAKERS` (1..32), `ELEVENLABS_FILE_FORMAT`
(default `pcm_s16le_16` per Open Decision EL-3),
`ELEVENLABS_ENTITY_DETECTION` (default unset / off per Open
Decision EL-2 — +30% surcharge when set).

#### FR-EL-3 — ElevenLabs concurrent-limit immediate-surface
**Status:** IMPLEMENTED (Phase B §B.3 — plan-007). **Phase:** B.
HTTP 429 with `detail.status == "concurrent_limit_exceeded"`
surfaces immediately as
`NtakkerError.transcriptionProviderUnavailable` — no retry — so the
user sees the cap and can choose to upgrade or reduce
`--transcribe-source` parallelism. Other 429 (`rate_limit_exceeded`,
`system_busy`) and 500 / 503 are retried with exponential backoff
(1, 2, 4 s ± 20% jitter) up to 3 attempts.

#### FR-EL-4 — ElevenLabs sub-100 ms short-circuit
**Status:** IMPLEMENTED (Phase B §B.3 — plan-007). **Phase:** B.
Audio chunks shorter than 100 ms (the ElevenLabs minimum) return
the empty string without making a network call, so silence-only
chunks at the start of a recording do not waste a request.

#### FR-007-UI — Per-provider key-entry sections (plan-007 Task 0.4)
**Status:** IMPLEMENTED (Phase 0.4 + Phase C — plan-007). **Phase:**
Phase 0 (`ProviderKeyField`) + Phase C (RootView wiring).
The menu-bar UI renders an inline `ProviderKeyField` row when the
active provider is `azure`, `azure-openai-realtime`, or `elevenlabs`.
The Azure variants additionally render read-only summary lines for
the resolved endpoint / deployment / api-version (and, for the
realtime variant, VAD threshold / silence / noise-reduction).

#### FR-007-PRIV — Per-provider privacy-disclosure acknowledgement (plan-007 Task 0.3)
**Status:** IMPLEMENTED (Phase 0.3 + Phase C — plan-007). **Phase:**
Phase 0 (PrivacyDisclosureSheet) + Phase C (RootView).
Acknowledgement is now stored under
`com.local.ntakker.transcription.privacy.{providerId}.acknowledged`
so users opt in once per data-residency posture; the legacy single
boolean and the plan-006 Soniox-specific flag are migrated forward
on first run after upgrade.

### Added by plan-008 — UI redesign + light/dark/system theming

#### FR-UI-APPEARANCE — Appearance mode picker
**Status:** PLANNED.
The ntakker menu-bar app MUST surface a 3-options appearance picker
(System / Light / Dark) in two locations: the popover header metadata
strip and the Settings dialog under a new "General" tab. Both controls
bind to the same persisted preference. The selected appearance MUST be
applied to the entire ntakker app (popover + Settings window + any
auxiliary windows/sheets) via `.preferredColorScheme(_:)` on the root
SwiftUI scene, and additionally via an `AppearanceHostingRoot` wrapper
that wraps the popover's `RootView` before it is mounted in
`NSHostingController` (because the popover is hosted outside the
SwiftUI scene tree on macOS 26).

The preference MUST persist across app launches via
`@AppStorage("com.ntakker-cli.ui.appearance")` on `UserDefaults.standard`,
with raw values `"system"` / `"light"` / `"dark"` and default `"system"`.
The persisted value MUST be readable via
`defaults read com.local.ntakker com.ntakker-cli.ui.appearance`.

Scope of effect: whole app (popover + Settings window + any auxiliary
sheets). The default value `"system"` is a documented user-facing UX
default (not a silent substitution for missing required configuration),
and is therefore allowed under the project's no-fallback-configuration
rule.

#### FR-UI-TRANSCRIPTION-GATE — Live Transcription section header toggle
**Status:** PLANNED.
The "Live Transcription" section in the popover MUST expose a
`Toggle.toggleStyle(.switch)` in its section header that gates whether
the transcription pipeline runs at recording start. The toggle persists
via `@AppStorage("com.ntakker-cli.ui.transcriptionEnabled")` (Bool, default
`true`). When OFF, `ControlBar.startTapped()` composes
`RecordingOptions` as if `transcribeProvider == "none"` regardless of
the persisted `transcribeProvider` value (which is preserved unchanged
so re-enabling the toggle restores the user's last engine selection).

### Added 2026-05-01 by plan-010 — Dual-provider live transcription mode (Apple on-device EN + Apple Cloud EL)

> Source: `docs/design/refined-request-dual-transcription.md` (FR-1..FR-11).
> Phase plan: `docs/design/plan-010-dual-transcription.md` (Phases A..J).
> Investigation: `docs/reference/investigation-dual-transcription.md`.
> Codebase scan: `docs/reference/codebase-scan-dual-transcription.md` (IP-1..IP-16).

#### FR-DUAL-1 — Mode switch in Live Transcription panel
**Status:** PLANNED. **Phase:** plan-010 §A, §E.
The Live Transcription panel in `ntakker` MUST expose a binary mode
control with values `"Single"` (default, pre-existing behaviour) and
`"Dual"`. The control MUST be located inside / immediately above the
Live Transcription panel so that the panel below it can swap based on
selection. Persisted via
`@AppStorage("com.ntakker-cli.ui.transcriptionMode")` with default
`"single"`. The exact control type (segmented picker vs toggle vs other)
is OQ-1 and resolved by the Phase 5 designer.

#### FR-DUAL-2 — Single mode preservation (NFR-1 hard constraint)
**Status:** PLANNED. **Phase:** plan-010 §C, §D, §E, §G.
When the mode control is set to `"Single"`, the panel MUST render the
EXISTING Live Transcription controls (provider picker labelled
`Transcribe`, audio Source picker, Transcript Format picker, Language
picker) with the EXACT current layout, defaults, labels, and behaviour.
No regressions, no relabels, no reorderings. The single-mode runtime
path, sidecar output, and JSONL byte-level format MUST remain identical
to today's behaviour. Verified by `SingleModeRegressionTests` and
`SingleModeSidecarRegressionTests` byte-equivalence assertions.

#### FR-DUAL-3 — Dual mode controls
**Status:** PLANNED. **Phase:** plan-010 §F.
When the mode control is set to `"Dual"`, the panel MUST render a
Dual-specific control set that includes at minimum:
- Audio Source picker (Mixed / Microphone / System) — same options as
  Single mode, persisted under `com.ntakker-cli.ui.dual.source` (default
  `"mixed"`).
- Channel A read-out: provider = `Apple (on-device)`, with a locale
  picker constrained to English variants and other locales supported
  by `SpeechTranscriber.supportedLocales` (macOS 26 on-device set,
  excludes Greek). Persisted under `com.ntakker-cli.ui.dual.channelALocale`,
  default `"en-US"`.
- Channel B read-out: provider = `Apple Cloud`, with a locale picker
  constrained to `SFSpeechRecognizer.supportedLocales()` (~57 locales).
  Persisted under `com.ntakker-cli.ui.dual.channelBLocale`, default
  `"el-GR"`.
- Sidecar Transcript Format picker (jsonl / txt / srt / vtt),
  persisted under `com.ntakker-cli.ui.dual.transcriptFormat`, default
  `"jsonl"`.
- Optional per-channel enable toggles (OQ-2, Phase 5 design call).

#### FR-DUAL-4 — Parallel execution with channel isolation
**Status:** PLANNED. **Phase:** plan-010 §B.
Selecting Dual and starting a recording MUST start BOTH transcription
sessions concurrently against the same captured audio. Failure of one
channel MUST NOT terminate the other; the failing channel surfaces an
inline error in its lane while the other continues. Implemented via
`DualTranscriptionManager` actor holding two
`StreamingTranscriptionPipeline` instances with per-channel drain
`Task`s wrapped in independent `do { ... } catch { ... }` blocks
(channel-tagged failure events do not propagate across channels nor
to the audio recorder).

#### FR-DUAL-5 — Audio fan-out
**Status:** PLANNED. **Phase:** plan-010 §B.
The capture pipeline MUST deliver identical audio frames to both
sessions with no measurable drift between channels. Implementation:
two `AudioDownsampler` instances (the type is not thread-safe;
investigator §Q2 Option 2A), synchronous fan-out inside the
`DualTranscriptionManager` actor — `downsamplerA.convert` then
`pipelineA.ingest`, `downsamplerB.convert` then `pipelineB.ingest`.
Both `ingest` calls are non-blocking (each session has its own internal
queue), so sequential fan-out does not stall capture (NFR-3 satisfied).

#### FR-DUAL-6 — Live transcript UI lanes
**Status:** PLANNED. **Phase:** plan-010 §G.
The live transcript area MUST render two visually distinct lanes
(e.g. labelled `"EN — Apple"` and `"EL — Apple Cloud"`), each showing
partial and final segments from its channel as they arrive, in
chronological order within the lane. The lane partition is computed
at render time from `segment.model` (`"apple"` → Channel A,
`"apple-cloud"` → Channel B). The exact layout (side-by-side, stacked,
or single chronological feed with channel chips) is OQ-5 and resolved
by Phase 5 designer.

#### FR-DUAL-7 — Sidecar output with channel tagging
**Status:** PLANNED. **Phase:** plan-010 §D.
When the recording stops, the system MUST write a sidecar transcript
file alongside the audio file that contains BOTH channels' segments,
each tagged with channel label, locale, segment start/end timestamps,
and `isFinal` flag. The format MUST be the user-selected one from
FR-DUAL-3:
- **JSONL**: existing schema (no breaking change). `model` and
  `language` fields already distinguish channels. Writer additionally
  emits an OPTIONAL convenience `channel: "A" | "B"` field in dual
  mode only (omitted in single mode → byte-identical output preserved).
- **TXT**: line-prefix `[<channel-label>]` (e.g. `[EN]`, `[EL]`) using
  uppercased BCP-47 primary language code.
- **SRT**: cue speaker prefix `EN: ` / `EL: `; overlapping cue start
  times are allowed (de-facto SRT convention; players stack cues).
- **VTT**: WebVTT voice tags `<v EN>...</v>` / `<v EL>...</v>`.
The exact SRT/VTT convention is OQ-4; investigator's defaults above
are adopted unless the Phase 5 designer overrules.

#### FR-DUAL-8 — Privacy disclosure trigger
**Status:** PLANNED. **Phase:** plan-010 §J.
The first time the user enables Dual mode (or selects `apple-cloud`
indirectly through Dual) without previously accepting the
`apple-cloud` privacy disclosure, the existing disclosure sheet
(`PrivacyDisclosureSheet(selectedProvider: "apple-cloud", ...)`) MUST
appear and the user must accept before the recording can start. The
existing acknowledged key
`"com.local.ntakker.transcription.privacy.apple-cloud.acknowledged"`
is reused — a user who has already accepted the apple-cloud disclosure
under single-mode is NOT re-prompted in Dual mode. The existing
`appleCloudBodyText` copy is sufficient (no new disclosure text is
needed).

#### FR-DUAL-9 — Per-channel telemetry
**Status:** PLANNED. **Phase:** plan-010 §I.
The UI MUST display per-channel latency (e.g. partial-arrival lag) and,
for the cloud channel, an incremental cost or quota indicator,
mirroring the Single-mode display. Implementation: new
`DualChannelMetrics` struct (per-channel `TranscriptionMetrics`),
new `dualMetrics: DualChannelMetrics?` published property on
`RecordingController`, new `DualTranscriptionMetricsView` rendering
two metric rows (one per channel). The apple-cloud quota indicator
ships in v1 if observable from `AppleCloudStreamingSession`; deferred
to a v2 follow-up otherwise.

#### FR-DUAL-10 — CLI parity
**Status:** PLANNED. **Phase:** plan-010 §H.
The `ntakker-cli` CLI MUST expose Dual mode through a flag set
(investigator default: `--transcribe-dual` boolean +
`--transcribe-dual-locale-a <bcp47>` +
`--transcribe-dual-locale-b <bcp47>` +
`--transcribe-dual-source <src>` +
`--transcribe-dual-format <fmt>`, with parallel
`NTAKKER_TRANSCRIBE_DUAL_*` env-var names). The exact spelling is OQ-3
and resolved by Phase 5 designer. The CLI behaviour MUST be
functionally equivalent to the UI Dual mode (same audio fan-out, same
sidecar output) — verified by `dual_cli_parity_smoke.sh`.

#### FR-DUAL-11 — Atomic stop / pause / split semantics
**Status:** PLANNED. **Phase:** plan-010 §B, §C.
Pause, resume, stop, and split actions MUST be applied to BOTH
channels atomically — i.e. pausing pauses both, splitting
(`rotateSidecar`) starts a new sidecar segment for both. Pause is
achieved at the capture-graph level (existing single-mode mechanism):
both channels naturally go quiet when `ingestFrame` is not called.
Stop calls `pipelineA.stop()` and `pipelineB.stop()` concurrently
(`async let`) with a 5 s drain timeout per channel (matches FR-57
existing single-mode behaviour). Split calls `rotateSidecar` on both
pipelines with the same target URL/format. Whether per-channel disable
is also supported (without leaving Dual mode) is OQ-2 (Phase 5 design
call).

### Added 2026-05-02 by plan-011 — Convo-Coach LLM Coaching CLI

> Source: `docs/design/refined-request-convo-coach.md`
> (FR-CC-1..FR-CC-15). Implemented as a TypeScript CLI under
> `tools/convo-coach/` (separate from the Swift recording-tool).
> Status: PLANNED unless otherwise noted. Plan: `plan-011-convo-coach.md`.

#### FR-CC-1 — Project location & language
**Status:** PLANNED. **Phase:** plan-011 §U1.
`convo-coach` MUST be implemented in TypeScript (strict) under
`tools/convo-coach/`, mirroring the structural conventions of
`tools/dual-transcript-merger/` (ESM, Node ≥20, `bin` mapping,
`prepare`/`postbuild` scripts that emit and chmod `dist/cli.js`). The
Swift exception (CLAUDE.md Exception 001) does NOT apply here. Package
and binary name: `convo-coach`.

#### FR-CC-2 — Installation
**Status:** PLANNED. **Phase:** plan-011 §U1.
Installable via `cd tools/convo-coach && npm install && npm link` —
after which `convo-coach --help` works from any directory. The
`prepare` script MUST run `tsc` and `chmod +x dist/cli.js`.

#### FR-CC-3 — Transcript input modes
**Status:** PLANNED. **Phases:** plan-011 §U3, §U5.
Three input modes with precedence highest → lowest: (1) stdin when
`process.stdin.isTTY === false`; (2) explicit `--transcript <path>`;
(3) auto-detect newest `*.transcript.{jsonl,txt,srt,vtt}` in
`NTAKKER_RECORDINGS_DIR` (a `convo-coach`-owned env var with default
`~/Recordings`). When stdin and `--transcript` are both supplied,
stdin wins and a stderr warning is emitted.

#### FR-CC-4 — Sidecar format support
**Status:** PLANNED. **Phase:** plan-011 §U4.
Parser MUST handle single-channel JSONL, dual-channel JSONL
(`channel:"A"|"B"` per plan-010 DT-7), plain TXT
(`[HH:MM:SS.mmm] [LANG?] text`), SRT, and VTT. Malformed lines/cues
are skipped with a single summary warning (count), not one warning
per line.

#### FR-CC-5 — Conversation-window filtering
**Status:** PLANNED. **Phase:** plan-011 §U4.
`--last <duration>` (`30s | 5m | 1h | 1h30m | 90s`; strict regex,
malformed → exit 64) and `--since <timestamp>` (wall-clock
`HH:MM:SS[.mmm]` local TZ; ISO-8601; relative `+MM:SS` / `+HH:MM:SS`).
When both flags are set, the later boundary wins. Absent → full
transcript. "Now" for finite files = max segment end; for stdin =
wall-clock at trigger time.

#### FR-CC-6 — Stdin streaming semantics
**Status:** PLANNED. **Phase:** plan-011 §U5.
When stdin is piped, the tool reads line-by-line into a window-aware
ring buffer. LLM requests trigger on Enter from `/dev/tty` (default).
If `/dev/tty` is unavailable, fall back to `--debounce <duration>`
silence trigger (default `15s`); `--debounce 0` disables the timer
(only EOF triggers). Each trigger produces ONE distinct timestamped
sidecar.

#### FR-CC-7 — LLM providers
**Status:** PLANNED. **Phase:** plan-011 §U6.
Eight standard providers wired out of the box, matching the
`tool-doc-config-architect` mandate:
`openai | anthropic | gemini | azure-openai | azure-ai-inference |
ollama | litellm | mlx`. Implementation via the Vercel AI SDK
(`ai@^6` + `@ai-sdk/openai`, `@ai-sdk/anthropic`, `@ai-sdk/google`,
`@ai-sdk/azure`, `@ai-sdk/openai-compatible`).

#### FR-CC-8 — Provider/model selection
**Status:** PLANNED. **Phases:** plan-011 §U3, §U6.
`--provider <name>` (env `CONVO_COACH_PROVIDER`) and `--model <id>`
(env `CONVO_COACH_MODEL`). Per-provider defaults: `gpt-4o-mini`,
`claude-haiku-4-5-20251001`, `gemini-2.5-flash`,
`${AZURE_OPENAI_DEPLOYMENT}`, `claude-haiku-4-5`, `llama3.1:8b`. No
default for `litellm` and `mlx` — `--model` is required (raise
`MISSING_CONFIG` if absent).

#### FR-CC-9 — Configuration resolution chain
**Status:** PLANNED. **Phase:** plan-011 §U2.
Four-tier chain identical to `ntakker-cli` and `dual-transcript-merger`:
`process.env` (lowest) → `~/.tool-agents/convo-coach/.env` →
`<cwd>/.env` → CLI flags (highest). Folder mode `0700` enforced on
first invocation. The `.env` file is seeded at mode `0600` by the
`/tool-conventions scaffold convo-coach` command, NOT by the
runtime.

#### FR-CC-10 — No-fallback rule
**Status:** PLANNED. **Phases:** plan-011 §U2, §U6.
Missing required configuration (provider key, endpoint, deployment,
model when required, recordings dir for auto-detect) MUST raise
`ConvoCoachError('MISSING_CONFIG', …)` with the env-var name AND the
four resolution tiers inspected; exit 78. Default model IDs and the
`NTAKKER_RECORDINGS_DIR` default `~/Recordings` are documented model
metadata / directory locations, NOT credential fallbacks.

#### FR-CC-11 — Output behaviour
**Status:** PLANNED. **Phase:** plan-011 §U7.
Tokens stream to `stdout` via direct `process.stdout.write` (no
console buffering) AND are simultaneously appended to
`<basename>.advice-<YYYYMMDD-HHMMSS>.md` next to the source
transcript. Sidecar markdown carries a YAML front-matter block
(provider, model, source, window, segments, dropped, channelLabels,
ttftMs, elapsedMs, input/output/total tokens). Collision suffix `-<n>`.
On stream-error the sidecar is preserved with a `# ERROR` footer.

#### FR-CC-12 — Prompt construction
**Status:** PLANNED. **Phase:** plan-011 §U8.
A built-in default system prompt frames the LLM as a real-time
conversational coach (3–5 concrete next-utterance suggestions). The
user message contains the windowed transcript formatted as
`[HH:MM:SS.mmm] [<channel-or-source>] text`. Channel labels (`A` →
`Speaker-A (on-device, primary)`, `B` → `Speaker-B (cloud)`) are
explained in the message's legend. `--system-prompt <path>` overrides
the default; `--language <bcp-47>` adds a response-language hint.

#### FR-CC-13 — Token-budget handling
**Status:** PLANNED. **Phase:** plan-011 §U9.
Default strategy `truncate-start` drops oldest segments until the
prompt fits the model's context window; `--on-overflow
{truncate-start | truncate-end | error}` switches the strategy.
Per-model context-window sizes live in
`src/llm/model-context-windows.ts`; unknown models fall back to a
conservative 8 192-token assumption with a warning. Token estimation:
`js-tiktoken` for OpenAI-family models, 4-chars-per-token heuristic
elsewhere. Dropped count is recorded as `droppedSegments: <n>` in the
sidecar front-matter.

#### FR-CC-14 — Logging & exit codes
**Status:** PLANNED. **Phases:** plan-011 §U2, §U3.
Log levels `quiet | info | debug` via `--log-level` (env
`CONVO_COACH_LOG_LEVEL`); logs go to stderr. Exit codes: `0`
(success), `1` (generic), `64` (`EX_USAGE` — bad CLI / malformed
window), `66` (`EX_NOINPUT` — transcript not found / unparseable),
`70` (`EX_SOFTWARE` — provider failure), `78` (`EX_CONFIG` —
missing required config). API keys MUST NEVER be logged at any
level.

#### FR-CC-15 — CLAUDE.md "Tools" section entry
**Status:** PLANNED. **Phase:** plan-011 §U10.
After implementation completes and `docs/tools/convo-coach.md` is
in place (scaffolded by `/tool-conventions scaffold convo-coach`),
the project `CLAUDE.md` MUST gain a concise `### convo-coach` entry
under `## Tools` pointing at `docs/tools/convo-coach.md` plus the
install snippet (`cd tools/convo-coach && npm install && npm link`).

#### FR-WIN-1 — Pop the ntakker UI out into its own window
**Status:** IMPLEMENTED (2026-10-17, user request).
- A header button in the popover ("Pop out into a window") shows the full ntakker UI in a regular titled, resizable, minimisable window, so the user can keep it open while working in other apps.
- Recording, transcript, Ask and settings state carry over, because they live in the shared `RecordingController` and `@AppStorage`.
- The window remembers its position and size between pop-outs.
- **Closing the window** returns ntakker to its menu-bar icon (popover closed).
- **Clicking the menu-bar icon while the window is open** docks the UI back: the window closes and the popover opens under the icon. The window's header button ("Return to the menu bar") does the same.
- Level meters keep running while the window is shown.

#### FR-STU-1..10 — ntakker-studio, the recordings explorer
**Status:** IMPLEMENTED (2026-10-17, plan-024, user request; see `docs/refined_requests/refined-request-001-ntakker-studio.md`). A separate Dock app next to ntakker (`com.giorgosmarinos.ntakker-studio`).
- **FR-STU-1 Library.** Lists every recording under a library folder (the studio's own setting; first launch adopts ntakker's recording folder; otherwise the user must choose one), grouped by month. A recording is the audio and transcripts sharing a stem; each `.partNN` is its own entry.
- **FR-STU-2 Player.** Plays the recording; a split recording plays mic and system together. Speeds 0.75–2×. Space and ←/→ when no text field has focus.
- **FR-STU-3 Transcript study.** All transcripts of the recording on one timeline with time, speaker and source; the line being played is highlighted and followed; text and speaker filters; several transcripts can be shown at once.
- **FR-STU-4 Jump to moment.** Clicking a line (or its time) seeks the player to where the line was spoken. A per-recording offset corrects live-transcript timing.
- **FR-STU-5 Cut.** Ranges selected on the waveform or from lines are removed in a new copy (audio in the same format, transcripts re-timed, lines mostly inside a cut dropped). The originals are never modified. Cut preview skips the ranges during playback.
- **FR-STU-6 Ask.** Questions over the whole transcript through ntakker's Ask provider; answers cite `[mm:ss]` moments that are clickable; saved to `<stem>.studio-qa.md`.
- **FR-STU-7 Minutes.** Summary, topics, decisions, action items and open questions with timecodes, optionally in a chosen language; saved to `<stem>.minutes.md`.
- **FR-STU-8 Speakers.** Rename diarized speakers per recording (`<stem>.studio.json`); names are used everywhere in the studio.
- **FR-STU-9 Edit text.** Fix a line's text; saved back to the JSONL, with a one-time `.orig` backup.
- **FR-STU-10 Re-transcribe and search.** Re-transcribe a recording with a batch provider (parakeet, whisperkit, gemini, azure, elevenlabs) into a new exact-timed transcript. Search every transcript in the library (case- and accent-insensitive, all words) and open a result at its moment.

---

## 2. Non-functional requirements

Carried forward from the refined request without modification:

- **NFR-1 — Target OS.** macOS 13.0 minimum; **macOS 14.0+ in v1** (OQ-1
  default).
- **NFR-2 — Architectures.** Apple Silicon (arm64) required; x86_64
  shipped as part of a universal binary (OQ-4 default).
- **NFR-3 — Performance — no dropped frames.** A 60-minute recording
  under normal desktop load MUST complete without dropping audio
  buffers; drops, if any, MUST be detected and reported.
- **NFR-4 — A/V sync between sources.** Mic and system streams MUST be
  aligned within ±20 ms across the entire recording. Enforced by
  FR-22 + the `HostClockAligner` + the silence-fill mechanism.
- **NFR-5 — Resource footprint.** < 250 MB resident, < 25 % of one
  CPU core in steady-state.
- **NFR-6 — Privacy & security.** Never transmits audio over the
  network; never writes outside `--output` (and a temp directory if
  needed); cleans up temp files on stop or signal.
- **NFR-7 — Error handling.** Documented exit code (FR-18); stderr
  one-line summary; remediation guidance; no PII in error messages.
- **NFR-8 — Logging.** `--log-level {quiet|info|debug}`, default
  `info`. Logs to stderr; stdout reserved for future piped output
  (OQ-5 deferred).
- **NFR-9 — Code organization.** Swift Package with executable target
  (`ntakker-cli`) + library target (`NtakkerCore`) + test target
  (`NtakkerCoreTests`).
- **NFR-10 — Tests.** Unit tests cover configuration precedence
  (FR-12), CLI argument parsing, permission state detection,
  output-path validation. E2E tests are manual (TCC unavailable in
  CI).

### Added 2026-04-26 by plan-003, REST-rewritten 2026-04-28 by plan-004 — Live transcription side-channel

- **NFR-17 — Recording integrity isolation.** Transcription failures
  (provider 4xx/5xx, transport error, decode error, sidecar I/O error,
  hung provider Task) MUST NOT stop, slow, or corrupt the on-disk
  recording. Verified by an integration test that injects a hanging
  `FakeTranscriptionProvider` and asserts the audio file is byte-for-byte
  identical to a control recording without transcription enabled.
  All transcription-runtime errors are logged + surfaced as a UI amber
  banner but never propagate to the recorder pipeline.
- **NFR-18 — Transcription pipeline memory bounded — per-source buffer
  ≤ 320 KB peak.** Each `SourceBuffer` accumulates at most
  `2 × chunkSamples` Float32 samples before the actor's bounded-drop
  policy kicks in: 2 × 2.5 s × 16 000 samples × 4 bytes = 320 KB per
  source. With at most two sources active (`--transcribe-source both`)
  the per-process worst-case is 640 KB of in-flight transcription PCM.
  This replaces the streaming pipeline's 8 MB ceiling from plan-003 —
  the REST architecture has no per-WebSocket queue.
- **NFR-19 — End-to-end latency from utterance end to transcript line
  ≤ 5 s P95.** Latency budget = 2.5 s buffer flush window + 2.0 s
  provider RTT (Gemini REST `generateContent` typical) + 0.5 s
  pipeline overhead (downsample, sanitize, coalesce, sidecar write).
  Replaces plan-003's first-token / first-partial NFR (no streaming,
  no first-token concept). Observability target, not a hard SLO —
  exceeding it logs a warning but never stops the recording.
- **NFR-20 — API key never logged or written to disk except as
  configured key file.** `GOOGLE_API_KEY` MUST appear only inside the
  resolver's in-memory `RecordingOptions.transcriptionApiKey` field
  (and the user-controlled source: `~/.tool-agents/ntakker-cli/.env` mode
  `0600`, `~/.tool-agents/ntakker/.env` mode `0600`, local `./.env`,
  or shell environment). It MUST NOT appear in any log line, in the
  sidecar header, in the post-stop UI summary, or in any error
  message. No `--google-api-key` CLI flag exists (avoids leakage into
  shell history and `ps` output). Audio bytes and the source label
  are the only data transmitted; no PII metadata (filename, mic
  device name, host name, user name) is included in the request.
- **NFR-21 — Retry policy: per-chunk failures non-fatal; no automatic
  retry of failed REST calls in v1.** A failed `transcribe(samples:…)`
  call MUST emit `transcriptionProviderFailed(detail:)` (non-fatal),
  increment the error metric, and move on — the next 2.5 s chunk is
  attempted independently. There is **no automatic retry of the
  failed chunk** in v1 (idempotency of `generateContent` is unclear
  and retry costs money). Recording continues uninterrupted; the
  sidecar continues with a missed-chunk gap line. Replaces plan-003's
  WebSocket session-resumption / exponential-backoff NFR which has no
  REST analogue. Provider extensibility (new conformer = new file +
  single registration line, zero changes to `NtakkerCore` orchestration
  code) is a separate property of the protocol design — see FR-46.

#### Apple Speech Streaming NFRs (plan-005)

| NFR | Description | Status |
|---|---|---|
| NFR-AS-1 | First-partial latency ≤ 500 ms P95 (mic → first partial event) on Apple Silicon. | PLANNED (Phase D — plan-005) |
| NFR-AS-2 | Final latency ≤ 1 s P95 (end-of-speech → final event). | PLANNED (Phase D — plan-005) |
| NFR-AS-3 | CPU footprint per active recognizer ≤ 10 % on M-series at light load. With `--transcribe-source both` + 2 locales (4 active recognizers) total transcription CPU ≤ 40 %. | PLANNED (Phase D — plan-005) |

#### Soniox Streaming NFRs (plan-006)

| NFR | Description | Status |
|---|---|---|
| NFR-SX-1 | Recording integrity isolation — any failure inside the Soniox provider (network, auth, rate limit, hung session, malformed message) MUST be non-fatal to the recording pipeline; the audio file is byte-identical to the `--transcribe none` control. Verified by `RecordingIntegrityIsolationTests` with a `SonioxAlwaysFailingFake` injection. | PLANNED (Phase D — plan-006; verification in Phase I — plan-006) |
| NFR-SX-2 | End-to-end latency targets — ≤ 1.5 s P95 utterance-end → final segment on disk; ≤ 500 ms P95 first-partial. Observability target only (warn on exceed; never blocks the recording). | PLANNED (Phase D — plan-006) |
| NFR-SX-3 | API key never logged or written to disk except as the configured key file. Parity with NFR-20: `SONIOX_API_KEY` only in the resolver's in-memory `transcriptionApiKey` field and the user-controlled source files. No `--soniox-api-key` CLI flag. | PLANNED (Phase B + Phase H — plan-006; verified by code review) |
| NFR-SX-4 | No PII metadata in requests — only audio bytes and the source label (`mic` / `system`); `client_reference_id = ntakker-cli-<recordingId>-<source>` (no filename, no hostname, no username). Parity with NFR-20. | PLANNED (Phase D — plan-006) |
| NFR-SX-5 | Bounded retry posture — per-chunk / per-message failures non-fatal (parity with NFR-21). On Soniox 503 (mid-session reconnect signal) reconnect once; on other errors emit `.warning` and continue. v1 does NOT add automatic retry of failed chunks. | PLANNED (Phase D — plan-006) |
| NFR-SX-6 | Provider footprint — within the per-process transcription memory bound of NFR-18 (≤ 320 KB per active source for in-flight PCM); the streaming session's own buffers (`URLSessionWebSocketTask` defaults + `bufferingNewest(128)` events stream) are additional and bounded. | PLANNED (Phase D — plan-006) |
| NFR-SX-7 | No new third-party SPM dependency — strong preference for `URLSessionWebSocketTask` (Foundation, no dep). Hand-rolled per investigation OQ-SX-11 (no Swift SDK exists). Verified at AC-SX-15 (`Package.swift` diff empty). | PLANNED (verified at Phase I — plan-006) |

#### Dual-Provider Transcription NFRs (plan-010)

| NFR | Description | Status |
|---|---|---|
| NFR-DUAL-1 | No regression to Single mode — runtime path, UI layout, defaults, and on-disk artefacts MUST be byte-identical to today's behaviour for any previously valid Single-mode invocation. Verified by `SingleModeRegressionTests` (JSONL byte-equivalence) + `SingleModeSidecarRegressionTests` (txt/srt/vtt byte-equivalence) + manual visual diff of the Live Transcription panel before/after merge. | PLANNED (Phase C, D, E — plan-010) |
| NFR-DUAL-2 | Channel isolation — a crash, exception, or quota error in one channel MUST NOT propagate to the other. Each channel has its own `Task` lifecycle and error surface inside `DualTranscriptionManager`. Verified by `DualChannelIsolationTests` injecting a failing `FakeTranscriptionProvider` for one channel and asserting the other continues to emit `segmentFinalized` events. | PLANNED (Phase B — plan-010) |
| NFR-DUAL-3 | Audio backpressure — the audio fan-out MUST NOT block the capture pipeline if one consumer (e.g. the cloud channel under network pressure) falls behind. Both `pipeline.ingest` calls inside `DualTranscriptionManager.ingestFrame` are non-blocking; each session's internal queue absorbs the backpressure. A "lagging" indicator (Phase 5 design call) surfaces when per-channel queue depth or partial inter-arrival latency exceeds a threshold. | PLANNED (Phase B, I — plan-010) |
| NFR-DUAL-4 | Memory footprint — two concurrent sessions MUST NOT raise steady-state memory above ~2× a single Single-mode session (sanity bound, no fixed numeric SLA). Two `AudioDownsampler` accumulators (small, bounded) + two session-level queues; verified by manual long-run test (60 min Dual recording) tracking RSS via `top -pid <pid>`. | PLANNED (Phase B; manual verification in Phase 10 — plan-010) |
| NFR-DUAL-5 | macOS-26 compatibility — Dual mode MUST work under the project's existing deployment target (macOS 26, per project CLAUDE.md Exception 002). It does not need to be back-ported to macOS 14/15. | PLANNED (Phase A — plan-010; trivially satisfied by existing project target) |
| NFR-DUAL-6 | Permissions — Dual mode requires both the on-device SpeechAnalyzer prerequisites (already in place) AND the `NSSpeechRecognitionUsageDescription` + Speech Recognition TCC grant that `apple-cloud` already needs. The system MUST surface a clear actionable error (not a crash) if either is missing — verified by `DualChannelIsolationTests` that simulate TCC denial. | PLANNED (Phase B, F, J — plan-010) |
| NFR-DUAL-7 | Run-mode caveat — the known `apple-cloud` constraint that ad-hoc-signed raw-binary launches of `ntakker` cannot call `SFSpeechRecognizer.requestAuthorization` without SIGABRT applies to Dual mode unchanged (the user must run from `dist/ntakker.app`). The Dual-mode error path reuses the existing actionable error text via `AppleCloudTranscriptionProvider.openStreamingSession`'s `isRunningFromAppBundle()` gate. No new mitigation is required. | PLANNED (Phase B — plan-010; reuses existing apple-cloud surface) |

---

## 3. Open questions (status snapshot)

| OQ    | Question                                                  | Locked default                          | Status |
|-------|-----------------------------------------------------------|-----------------------------------------|--------|
| OQ-1  | Min macOS target                                           | macOS 14.0+                             | LOCKED, pending Phase 5 confirmation |
| OQ-2  | CLI binary name                                            | `ntakker-cli`                                | LOCKED |
| OQ-3  | Foreground vs daemon                                       | Foreground (default) + `--detach` background mode + `stop` subcommand | OVERRIDDEN 2026-04-26 (see FR-25..FR-29) |
| OQ-4  | Architecture                                               | Universal binary                        | LOCKED |
| OQ-5  | stdout streaming                                           | Not in v1                               | LOCKED, DEFERRED |
| OQ-6  | Default layout                                             | `mixed`                                 | LOCKED |
| OQ-7  | Default format                                             | `m4a`                                   | LOCKED |
| OQ-8  | Mic device selection                                       | Either name or UID; UID wins; warn on multi-match | LOCKED |
| OQ-9  | System silence behavior                                    | RMS heartbeat every 10 s @ debug (FR-23) | LOCKED |
| OQ-10 | Required vs defaultable config                             | Required: `--output` only                | LOCKED |
| OQ-LT-1 | Exact Gemini model id ("Gemini 3.1 Live")               | `gemini-3.1-flash-live-preview` (with `models/` prefix). Fallback: `gemini-live-2.5-flash-native-audio` | LOCKED by plan-003 §0.1 |
| OQ-LT-2 | Default transcription source: `mixed` vs `both`         | `mixed` default; `both` exposed as a UI option | LOCKED by plan-003 §0.1 |
| OQ-LT-3 | Inline transcript panel vs separate window              | Inline panel (max-height ~120 pt). Separate window logged as v2 | LOCKED by plan-003 §0.1 |
| OQ-LT-4 | Streaming transport: WebSocket vs gRPC                  | `URLSessionWebSocketTask` (Foundation, no dep) | LOCKED by plan-003 §0.1 |
| OQ-LT-5 | Detach-mode transcription scope                         | EXCLUDED from v1; `--detach --transcribe` exits 64 | LOCKED by plan-003 §0.1 |
| OQ-LT-6 | Maximum session length on Gemini Live                   | Mitigated by `contextWindowCompression` + `sessionResumption`; brief gap at reconnects accepted | LOCKED by plan-003 §0.1 |
| OQ-LT-7 | `--max-duration` propagates to transcription session    | YES, one-way only. Transcription stops when recording stops | LOCKED by plan-003 §0.1 |
| ESC-LT-1 | Empirical reliability of `inputAudioTranscription` on Gemini 3.1 | Phase I smoke test gates launch; documented fallback to 2.5 model | ESCALATED to user (plan-003 §0.2) |
| ESC-LT-2 | WebSocket `maxAttempts` parameter                       | Recommended `8` (~110 s worst-case)     | ESCALATED to user (plan-003 §0.2) |
| OQ-SX-1 | `TranscriptionProvider` protocol extension needed for Soniox? | KEEP existing protocol; `SonioxStreamingSession` bridges internally | LOCKED by plan-006 §0 (RESOLVED) |
| OQ-SX-2 | Vendor-canonical Soniox API key env var name | `SONIOX_API_KEY` (confirmed by Soniox docs Get-API-key page) | LOCKED by investigation (RESOLVED) |
| OQ-SX-3 | Diarization / language-id ON by default? | LID ON, endpoint detection ON, diarization **ON** by default since plan-012 (overridable via `NTAKKER_SONIOX_DIARIZE`) | RESOLVED by plan-012 Phase A (2026-05-02) |
| OQ-SX-4 | Default Soniox model id | `stt-rt-v4` (active, multilingual, native Greek + English) | LOCKED by investigation (RESOLVED) |
| OQ-SX-5 | Cost / billing for e2e validation | $0.12/hr streaming; user must confirm trial credit at console.soniox.com | DOCUMENTED, USER ACTION |
| OQ-SX-6 | Latency target | ≤ 1.5 s P95 utterance-end → final on disk; ≤ 500 ms P95 first-partial | RECOMMENDED by plan-006 §0 (NEEDS USER CONFIRMATION) |
| OQ-SX-7 | `--transcribe-language` comma-list semantics | Comma list honoured natively (Soniox `language_hints` is array); BCP-47 stripped → ISO 639-1 | LOCKED by investigation (RESOLVED) |
| OQ-SX-8 | UI picker order | Append after Gemini → `None | Apple | Gemini | WhisperKit | Soniox` | RECOMMENDED by plan-006 §0 (NEEDS USER CONFIRMATION) |
| OQ-SX-9 | Default `--transcribe-source` for Soniox | `mixed` (project default) | RECOMMENDED by plan-006 §0 (NEEDS USER CONFIRMATION) |
| OQ-SX-10 | Data-retention disclosure | Document org-level setting in configuration-guide; no per-request opt-out in v1 | RECOMMENDED by plan-006 §0 (NEEDS USER CONFIRMATION) |
| OQ-SX-11 | Hand-rolled WS vs Soniox SDK | Hand-rolled (no Swift SDK exists at github.com/soniox) | LOCKED by investigation (RESOLVED) |
| OQ-SX-12 | Per-provider expiry env var split | Add `NTAKKER_SONIOX_KEY_EXPIRES_AT` with provider-scoped > shared resolution; keep `NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT` as fallback | RECOMMENDED by plan-006 §0 (NEEDS USER CONFIRMATION) |
| OQ-DUAL-1 | Mode-switch control type | Segmented `Picker("Mode")` ["Single" \| "Dual"] at top of Live Transcription panel (investigator §Q4 Option 4A) | RECOMMENDED by plan-010 §1; NEEDS PHASE 5 DESIGNER |
| OQ-DUAL-2 | Per-channel disable in Dual mode | Atomic-only (no per-channel disable) for v1; designer may overrule | OPEN — PHASE 5 DESIGNER |
| OQ-DUAL-3 | CLI flag spelling for Dual mode | `--transcribe-dual` boolean + `--transcribe-dual-locale-{a,b}` + `--transcribe-dual-source` + `--transcribe-dual-format` (investigator §IP-11 Option A) | RECOMMENDED by plan-010 §H; NEEDS PHASE 5 DESIGNER |
| OQ-DUAL-4 | SRT/VTT channel-labelling convention | VTT `<v EN>...</v>` voice tags; SRT `EN: ` / `EL: ` cue prefixes; overlapping cue start times allowed (investigator §Q5) | RECOMMENDED by plan-010 §D; NEEDS PHASE 5 DESIGNER |
| OQ-DUAL-5 | Dual-lane UI layout | Side-by-side / stacked / single chronological feed with channel chips; designer picks per popover-width readability | OPEN — PHASE 5 DESIGNER |
| OQ-DUAL-6 | Generic vs specific orchestrator | Specific (`apple` + `apple-cloud` only) for v1; generic N>2 explicitly out of scope per refined request | RECOMMENDED by plan-010 §1; NEEDS PHASE 5 DESIGNER |

Six research-doc follow-ups (SCStream OI-1, OI-2, OI-3 +
AVAssetWriter 7.1, 7.2, 7.4) are tracked in `Issues - Pending Items.md`
with the disposition "validate during Phase 10".

---

## 4. Deferred (v2) features

- Per-application source filtering (e.g. record only Zoom).
- Pause / resume during a recording.
- File rotation (split one session into chunked files).
- Real-time effects, AGC, noise suppression, level metering UI.
- Streaming output to stdout (`--output -`) — OQ-5 v2.
- Log-file rotation in detach mode — v1 ships with no rotation; the
  user manages `~/.tool-agents/ntakker-cli/ntakker-cli.log` size manually
  (FR-29 known limitation).
- Menu-bar UI sharing the `NtakkerCore` library — explicitly enabled
  by NFR-9's library-target requirement.
- ProcessTap-based system audio capture (`AudioHardwareCreateProcessTap`,
  macOS 14.4+) as an alternative to SCStream. The Phase-E
  `SystemAudioSource` protocol is the abstraction seam.
- FLAC, MP3, Opus output codecs.
- Cross-platform (Linux, Windows) — explicitly out of scope.

### Added by plan-003 — Live transcription v2 candidates

- On-device transcription (Apple `SFSpeechRecognizer`, WhisperKit) as a
  network-free provider — refined-request §Out of scope; tracked as v2.
- Detach-mode transcription (sidecar-only output without a UI to render
  partials) — OQ-LT-5 v2.
- Separate transcript window (NSWindow on demand) for long meetings —
  OQ-LT-3 v2.
- Additional providers: OpenAI Realtime (`gpt-realtime`), Deepgram
  Streaming (`nova-3`), AssemblyAI Universal-Streaming. All admit the
  v1 `TranscriptionProvider` protocol per NFR-21.
- Translation (target-language selection) — refined-request §Out of
  scope; v2.
- Speaker diarization beyond `system`/`mic` source labels — v2.
- In-app transcript editor / merge-and-re-export — v2.
- Re-transcription of finished recordings (offline batch) — v2.
- Per-recording cost dashboard / multi-recording aggregator — v2.
- `com.apple.security.network.client` entitlement when `ntakker-cli` is
  later sandboxed — v2 prerequisite.

### Added by plan-006 — Soniox v2 candidates

- Soniox speaker diarization (`enable_speaker_diarization`) — IMPLEMENTED
  in plan-012 Phase A (2026-05-02). Default-on, overridable via
  `NTAKKER_SONIOX_DIARIZE` env / `--soniox-diarize` CLI / Settings →
  Soniox UI toggle. Speaker labels propagated through
  `TranscriptSegment.speaker` and rendered in all four sidecar formats
  (JSONL raw `spk:N`; TXT/SRT/VTT via `SpeakerSidecarLabel`).
- Soniox translation (`translation: {type, target_language}`) — refined-request
  §Out of scope; v2.
- Soniox custom vocabulary / context biasing (`context.terms`,
  `context.text`, `context.general`) — refined-request §Out of scope; v2.
- Automatic mid-recording reconnect on Soniox's 5-hour session boundary —
  Risk 9.5 in plan-006; v2.
- Per-recording data-retention opt-out for Soniox — vendor does not
  expose this in WebSocket config schema as of 2026-04-29; revisit if
  vendor adds it; OQ-SX-10 v2.
- Soniox async REST batch path via `stt-async-v4` — only streaming in v1;
  v2.
- Adoption of an official Soniox Swift SDK if/when one is published at
  `github.com/soniox/soniox-swift` — OQ-SX-11 v2.

### Added by plan-008 — UI redesign v2 candidates

- API-key expiration-date chip (Q-02 deferred from plan-008). The
  popover's API-key sub-row in v1.6 renders only "Configured" /
  "Not configured" status. A future plan introduces a new persisted
  field per provider (`com.ntakker-cli.ui.apiKeyExpiry.<provider>`) plus
  a date-entry control inside the `Replace…` flow so the chip can
  surface red/amber/green expiration status.
- Cleanup of orphaned `@AppStorage` keys
  `com.ntakker-cli.ui.transcriptionExpanded` and
  `com.ntakker-cli.ui.recordingSettingsExpanded` (no longer read after
  plan-008 P4; retained in `UserDefaults` for back-compat).
- Removal of deprecated view files no longer composed by `RootView`
  after plan-008 (`FilenameField.swift`, `FolderPicker.swift`,
  `SonioxKeyField.swift`, `GeminiKeyField.swift`, `ProviderKeyField.swift`).

### Added by plan-012 — Source-split transcription

**FR-SS-1** — `--transcribe-source both` runs two parallel
transcription drivers (one per `SourceTag` — `.system` and
`.microphone`) and emits two sidecar files
(`*.system.transcript.<ext>` + `*.microphone.transcript.<ext>`).
Both drivers are instances of the SAME provider id; each owns its
own provider instance, sidecar writer, downsampler, and metrics
struct. `TranscriptionMetrics` from both children is field-wise
merged (counters summed, lastRttMs max'd) by
`SourceSplitTranscriptionManager.currentMetrics()`. Plan-012 Phase
C.

**FR-SS-2** — The live transcript panel renders two stacked
auto-scrolling lanes (`System audio` / `Microphone`) when
single-mode + `transcribeSource == .both`. Dual-mode
(`--transcribe dual`) is unaffected.

**FR-SS-3** — When `--transcribe-source both` is selected with
provider == `elevenlabs`, `ntakker-cli` logs a warning at session start
about the Free/Starter tier concurrent-request cap (8). The recording
proceeds; users on those tiers may surface `concurrent_limit_exceeded`
(HTTP 429).

### Added by plan-012 — Parakeet TDT V3 multilingual provider

**FR-PK-1** — `ntakker-cli` supports a Parakeet TDT V3 multilingual
on-device transcription provider (`parakeet`) backed by FluidAudio
v0.8.x. No API key required. Batch-only — `openStreamingSession`
throws `transcriptionConfigConflict`. Supports ~25 European
languages including Greek, Polish, Turkish. ~600 MB lazy first-launch
download to Application Support. Plan-012 Phase B.

**FR-PK-2** — Parakeet model id is configurable via
`NTAKKER_PARAKEET_MODEL` / `--parakeet-model` with the standard
WhisperKit-style precedence (Parakeet-specific override > shared
`NTAKKER_TRANSCRIBE_MODEL` > provider default). FluidAudio v0.8.x
clamps internally to `AsrModelVersion.v3`; the env var is kept for
parity and forward-compat.

**FR-PK-3** — `NTAKKER_PARAKEET_LANGUAGE` / `--parakeet-language`
accepts a bare ISO-639-1 code. Informational only in v1 because
FluidAudio v0.8.x has no per-call language hint API; the multilingual
TDT V3 model auto-detects per chunk.


### Added by plan-013 (revised) — Microphone acoustic echo cancellation

**FR-AEC-1** — By default, `ntakker-cli` and `ntakker` cancel the
speaker-to-microphone acoustic bleed in software. When
`RecordingOptions.micAEC == true`, `RecordingSession.run()`
constructs a `SoftwareAECProcessor` and wires it between the
existing capture sources and the aligner: the mic source's
buffers are routed through `processor.processMic(_:)` instead of
directly to the aligner; the system source is teed (still feeds
the aligner verbatim AND additionally feeds
`processor.feedReference(_:)`). The processor runs a per-channel
NLMS adaptive filter (default 4096 taps ≈ 85 ms @ 48 kHz, μ = 0.1,
regularised) using `Accelerate` SIMD primitives, subtracting the
estimated speaker→air→mic echo from the mic signal before it
flows downstream. plan-013 §3 / §3.1.

**FR-AEC-1a** — The original plan-013 design used Apple's
`AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)` (a
`VPMicrophoneSource` mic-source conformer). That path is NOT
viable in this codebase: the underlying `AUVoiceProcessingIO`
audio unit cannot coexist with `SCStream` system-audio capture
(both compete for unobstructed access to the system OUTPUT
device). `VPMicrophoneSource` was deleted; the user-facing
surface (flag / env / toggle) is unchanged but now routes
through the software processor. plan-013 §0.

**FR-AEC-2** — The behaviour is controlled by a stored boolean
`RecordingOptions.micAEC` (default `true`), resolved via the
standard four-tier chain (shell env / `~/.tool-agents/ntakker-cli/.env` /
local `.env` / CLI flag). The env-var name is `NTAKKER_MIC_AEC`;
the CLI flag is `--mic-aec on|off` on `ntakker-cli start`. The
ntakker popover exposes a "Mic echo cancellation" toggle in
the General section (persisted under
`@AppStorage("com.ntakker-cli.ui.micAEC")`). Both `parseBool` and
`parseOptionalBool` accept `on` / `off` alongside
`true` / `false` / `1` / `0` / `yes` / `no`. plan-013 §4.

**FR-AEC-3** — When `micAEC == false`, the AEC processor is not
constructed; mic and system buffers go directly to the aligner
exactly as they did pre-plan-013. The session-start log emits
`mic source = AVMicrophoneSource (AEC processor=on)` or
`mic source = AVMicrophoneSource (AEC processor=off)` so the
choice is observable in stderr / detach logs. plan-013 §5 / §6.

**FR-AEC-4** — `NtakkerError.micAECUnavailable(underlying:)`
(exit 70 / `EX_SOFTWARE`) is retained for any future
processor-level setup error path; the software AEC has no
device-level initialisation that can fail at start (its NLMS
state is in-memory only), so currently no code path raises it
during normal operation. The ntakker surface maps the error
into a "Mic echo cancellation unavailable" banner with a
`.retry` action.
