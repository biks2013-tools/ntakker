# Project Functions — `macrec` macOS Dual-Source Audio Recording Tool

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
2. `~/.tool-agents/macrec/.env`.
3. `./.env` in the current working directory.
4. CLI flags.

#### FR-13 — Per-user durable defaults bootstrap
**Status:** PLANNED. **Phase:** B.
On every invocation the tool MUST ensure `~/.tool-agents/macrec/`
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
The tool MUST be documented at `docs/tools/macrec.md` in the
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
`MacrecError.scStreamSilentStopExceeded(restartCount:)` and exit 70.
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

### 1.4 Added by plan-002 — Minimal toolbar UI (`macrec-ui`)

> The requirements below are appended on 2026-04-26 by Phase 4 (Planner)
> for the `macrec-ui` v1.1 add-on. Source: `docs/design/refined-request-toolbar-ui.md`
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
`MacrecCore.RecordingSession` MUST expose `split(nextOutput:) async throws`
that finalizes the current output file and opens the next file in the
sequence WITHOUT stopping `SCStream` / `AVCaptureSession`. The capture
stack stays alive across the split; only the encoder and the output
`URL` rotate. Audible gap MUST be ≤ 250 ms (AC-UI-7). Naming follows
FR-34.

#### FR-33 — Session state observer API
**Status:** IMPLEMENTED (Phase A completed 2026-04-26). **Phase:** A (plan-002).
`MacrecCore.RecordingSession` MUST expose a `SessionState` enum with
cases `{ idle, starting, recording, pausing, paused, resuming,
splitting, stopping, stopped, failed(MacrecError) }` and an
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
under `com.macrec.ui.outputFolder`. Default `~/Recordings/`; created
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
`UserDefaults` (`com.macrec.ui.format`, `com.macrec.ui.layout`).
Both disabled while recording.

#### FR-39 — Microphone device selection
**Status:** IMPLEMENTED (Phase E completed 2026-04-26). **Phase:** E (plan-002, `MicrophonePicker`).
The UI MUST expose a dropdown of input devices from
`AudioDeviceEnumerator.listInputs()`. Defaults to "System default".
Persists by `uid` in `UserDefaults` (`com.macrec.ui.micUID`). Refreshes
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
`MacrecCore` directly. NOT subprocess shell-out to the `macrec` CLI.

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
The UI executable MUST be documented at `docs/tools/macrec-ui.md` in
the prescribed `<toolName>` XML format, the `## Tools` section in
`CLAUDE.md` MUST list it, and `project-functions.md` MUST contain
FR-30..FR-44. The doc file and the `~/.tool-agents/macrec-ui/`
folder MUST be scaffolded by `/tool-conventions scaffold macrec-ui`
(dispatches the `tool-doc-config-architect` subagent) — never hand-
authored.

#### NFR-11 — UI responsiveness
**Status:** IMPLEMENTED (Phases D+E completed 2026-04-26 — Phase K verification pending). **Phase:** D + E + K verification (plan-002).
Every button click MUST update the visible UI state within 100 ms.
Long operations (file finalization, SCStream warmup) run on a
background `Task` and surface progress via the FR-33 state stream;
the UI thread MUST never block on audio I/O.

#### NFR-12 — Crash isolation
**Status:** IMPLEMENTED (Phase G completed 2026-04-26 — `MacrecError → banner` mapping landed). **Phase:** G (plan-002).
A recoverable engine error MUST surface as a `failed` session state
with the underlying `MacrecError` displayed in a banner / toast. The
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
**Status:** IMPLEMENTED (Phase B completed 2026-04-26 — no arch restriction added to the `macrec-ui` target; universal-binary parity preserved). **Phase:** B (plan-002).
The UI executable MUST ship as a universal binary (arm64 + x86_64)
matching the existing `macrec` target.

#### NFR-16 — Logging
**Status:** IMPLEMENTED (Phase H completed 2026-04-26). **Phase:** H (plan-002).
UI logs MUST go through the existing `LoggerFactory` / swift-log
pipeline. Default level `.info`; a hidden "Show debug log" toggle
switches to `.debug`. Logs go to a per-UI file at
`~/.tool-agents/macrec-ui/macrec-ui.log` (mode `0600`, append) when
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
its PID to `~/.tool-agents/macrec/macrec.pid` (or the path resolved via
`--pid-file` / `MACREC_PID_FILE`), redirect stdout/stderr to
`~/.tool-agents/macrec/macrec.log` (mode `0600`, append), and the parent
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
`MacrecError.alreadyRecording` and a descriptive stderr message naming
the conflicting PID. If the existing PID is stale (process no longer
alive), the new invocation MUST remove the stale PID file and continue
the start sequence. Foreground `start` (no `--detach`) is exempt from
this check (two foreground recordings to different output files are
allowed).

#### FR-29 — Detach log file
**Status:** PLANNED. **Phase:** K (redirect), B (path resolution).
In detach mode, all logs MUST go to `~/.tool-agents/macrec/macrec.log`
at mode `0600`, append-mode. The path is configurable via `--log-file`
and the env var `MACREC_LOG_FILE` (full precedence chain applies).
Foreground mode logs to stderr unchanged. v1 does NOT rotate the log
file — the user manages its size.

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
  (`macrec`) + library target (`MacrecCore`) + test target
  (`MacrecCoreTests`).
- **NFR-10 — Tests.** Unit tests cover configuration precedence
  (FR-12), CLI argument parsing, permission state detection,
  output-path validation. E2E tests are manual (TCC unavailable in
  CI).

---

## 3. Open questions (status snapshot)

| OQ    | Question                                                  | Locked default                          | Status |
|-------|-----------------------------------------------------------|-----------------------------------------|--------|
| OQ-1  | Min macOS target                                           | macOS 14.0+                             | LOCKED, pending Phase 5 confirmation |
| OQ-2  | CLI binary name                                            | `macrec`                                | LOCKED |
| OQ-3  | Foreground vs daemon                                       | Foreground (default) + `--detach` background mode + `stop` subcommand | OVERRIDDEN 2026-04-26 (see FR-25..FR-29) |
| OQ-4  | Architecture                                               | Universal binary                        | LOCKED |
| OQ-5  | stdout streaming                                           | Not in v1                               | LOCKED, DEFERRED |
| OQ-6  | Default layout                                             | `mixed`                                 | LOCKED |
| OQ-7  | Default format                                             | `m4a`                                   | LOCKED |
| OQ-8  | Mic device selection                                       | Either name or UID; UID wins; warn on multi-match | LOCKED |
| OQ-9  | System silence behavior                                    | RMS heartbeat every 10 s @ debug (FR-23) | LOCKED |
| OQ-10 | Required vs defaultable config                             | Required: `--output` only                | LOCKED |

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
  user manages `~/.tool-agents/macrec/macrec.log` size manually
  (FR-29 known limitation).
- Menu-bar UI sharing the `MacrecCore` library — explicitly enabled
  by NFR-9's library-target requirement.
- ProcessTap-based system audio capture (`AudioHardwareCreateProcessTap`,
  macOS 14.4+) as an alternative to SCStream. The Phase-E
  `SystemAudioSource` protocol is the abstraction seam.
- FLAC, MP3, Opus output codecs.
- Cross-platform (Linux, Windows) — explicitly out of scope.
