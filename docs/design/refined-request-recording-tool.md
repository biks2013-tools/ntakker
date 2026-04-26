# Refined Request: macOS Dual-Source Audio Recording Tool

## Category
Development (native macOS CLI tool, Swift)

## Goal & Background
Build a macOS-native command-line tool that simultaneously captures two audio
streams on a MacBook and writes them to disk as a recording:

1. **System audio** — every audible signal that would otherwise be played
   through the Mac's speakers/headphones, regardless of which application
   produced it. This includes media apps (Music, Spotify, Safari/Chrome video
   playback, QuickTime, VLC, etc.) and communication apps (Zoom, Microsoft
   Teams, FaceTime, Slack, Google Meet in browser, Discord, etc.).
2. **Microphone audio** — the local user's voice as captured by the MacBook's
   built-in microphone (or another selectable input device).

The motivating use case is single-user, local recording (e.g. capturing a
meeting where the user wants both their own voice and the remote participants'
voices in one usable file, or recording a podcast/voiceover over a media
backing track). The tool is a building block: downstream phases of this
project may consume the recordings for transcription, analysis, etc., but
those concerns are out of scope for this request.

The implementation language is **locked to Swift** by user-approved
**Exception 001** in the project's `CLAUDE.md`. Downstream phases must not
re-litigate this choice.

## Category
Development

## Scope

### In scope
- A native macOS Swift command-line tool, distributed as a Swift Package
  Manager project, that produces a single executable binary.
- Simultaneous capture of:
  - System audio (all processes, system-wide submix) via `ScreenCaptureKit`.
  - Microphone audio via `AVFoundation` (`AVCaptureSession` /
    `AVAudioEngine`).
- On-disk persistence of the captured audio into a configurable output file.
- Configurable output format, track layout, sample rate, channel layout, and
  encoder bitrate (with sensible defaults — see Requirements).
- Recording lifecycle controls: `start`, `stop`, optional max-duration cap.
- Permission discovery and user-facing guidance: detect whether the tool has
  been granted **Screen Recording** and **Microphone** TCC permissions,
  trigger the system prompts when missing, and print actionable instructions
  if a permission is denied.
- Standard project conventions:
  - Configuration precedence chain (shell env → `~/.tool-agents/<tool>/.env`
    → local `.env` → CLI flags).
  - On-startup creation of `~/.tool-agents/<tool>/` (mode `0700`) and a
    seeded `.env` (mode `0600`) if missing.
  - No fallback values for missing required config — raise descriptive errors.
  - Tool documentation under `docs/tools/<tool-name>.md` in the prescribed
    XML-tagged format, plus a reference entry in the project's `CLAUDE.md`
    "Tools" section.
  - `Issues - Pending Items.md` maintained at project root.
  - `docs/design/project-design.md` and `docs/design/project-functions.md`
    populated as the design solidifies.

### Out of scope (v1)
- Graphical user interface (menu-bar app, status-bar UI, Dock app). v1 is CLI
  only; a menu-bar UI is explicitly deferred to a future iteration.
- Pause / resume during a recording.
- File rotation (splitting one session across multiple chunked files).
- Per-application source filtering (recording only Zoom, excluding Spotify,
  etc.). v1 captures the full system submix.
- Real-time effects, noise suppression, automatic gain control, level
  metering UI, waveform display.
- Real-time streaming of the captured audio over the network.
- Transcription, speaker diarization, summarization, or any LLM-based
  post-processing.
- Cross-platform support (Linux, Windows, iOS). macOS only.
- Distribution concerns: code signing, notarization, Sparkle-style updates,
  Homebrew tap, `.pkg` installer. Local `swift build` is sufficient for v1.
- Recording from external audio interfaces or virtual audio devices
  (BlackHole, Loopback, Aggregate Devices). The tool will use the OS-level
  default input device unless explicitly told otherwise via flag.
- Capturing audio that the user routes to a Bluetooth headset where the OS
  does not expose the submix (this is a platform limitation, documented as
  a known constraint).

## Requirements

Each requirement is numbered, atomic, and verifiable. `MUST` denotes a hard
requirement; `SHOULD` denotes a strong preference that may be relaxed only
with explicit user approval recorded as a new exception.

### Functional requirements

**FR-1 — Simultaneous dual-source capture.** The tool MUST capture system
audio and microphone audio concurrently from the moment the user issues
`start` until the moment they issue `stop` (or the optional max-duration cap
is reached).

**FR-2 — System audio source.** System audio capture MUST be implemented via
`ScreenCaptureKit`'s audio capture path (`SCStream` configured with
`capturesAudio = true` and an `SCStreamConfiguration` whose audio settings
reflect FR-7 / FR-8). The tool MUST NOT require the user to install a virtual
audio device (BlackHole, Loopback, Soundflower, etc.).

**FR-3 — Microphone source.** Microphone capture MUST be implemented via
Apple's first-party APIs (`AVCaptureSession` with `AVCaptureDeviceInput`, or
`AVAudioEngine`'s input node). The tool MUST default to the system's current
default input device and MUST allow overriding it with `--mic-device <name>`.

**FR-4 — Output format.** The tool MUST be able to write the recording in
**at least** the following formats, selectable by `--format`:
  - `m4a` — AAC-LC inside an MPEG-4 container (default).
  - `wav` — 16-bit signed little-endian linear PCM, RIFF/WAVE container.
  - `caf` — CoreAudio Format container (codec selectable; AAC by default).

**FR-5 — Track layout.** The tool MUST support the following track layouts,
selectable by `--layout`:
  - `mixed` (default) — mic + system audio summed into a single
    stereo/mono track.
  - `split` — two separate output files, one per source, with deterministic
    suffixes `<basename>.mic.<ext>` and `<basename>.system.<ext>`.
  - `stereo-split` — a single stereo file with mic on the left channel and
    system audio on the right channel (or the reverse, configurable via
    `--mic-channel left|right`).

**FR-6 — Recording lifecycle.** The tool MUST expose:
  - `start` — begin recording.
  - `stop` — finalize the file(s) and exit cleanly. `stop` MUST also be
    triggered by `SIGINT` (Ctrl-C) and `SIGTERM` so partial recordings are
    not lost.
  - Optional `--max-duration <seconds>` flag on `start` that auto-stops at
    the cap.

**FR-7 — Sample rate and bit depth.** Internal processing MUST default to
**48 kHz, 16-bit signed PCM** for both sources. The user MUST be able to
override sample rate via `--sample-rate {44100|48000}` and bit depth via
`--bit-depth {16|24}` (24-bit only meaningful for `wav`/`caf` PCM outputs).

**FR-8 — Encoder bitrate.** When the output format is a lossy codec (e.g.
AAC in `m4a`), the encoder MUST default to **192 kbps**, overridable with
`--bitrate <kbps>`.

**FR-9 — Channel layout.** Default channel layout MUST be **stereo** for
both sources. If the system or microphone hardware is mono, the tool MUST
upmix or duplicate cleanly without distortion.

**FR-10 — Permission handling.** Before opening any capture session, the
tool MUST:
  1. Check Screen Recording TCC permission (required for `ScreenCaptureKit`
     audio capture). If missing, the tool MUST trigger the system prompt
     **and** print clear instructions pointing the user to **System
     Settings → Privacy & Security → Screen Recording**.
  2. Check Microphone TCC permission. If missing, trigger the system prompt
     and provide equivalent guidance pointing at **System Settings →
     Privacy & Security → Microphone**.
  3. Refuse to start recording (with a non-zero exit code and a descriptive
     error) if either permission is denied.

**FR-11 — Subcommand CLI surface.** The CLI MUST expose, at minimum, the
following subcommands:
  - `start [options]` — begin a recording.
  - `stop` — stop a running recording started by the same process tree
    (or, if v1 is single-process foreground only, this is implicit on
    SIGINT/SIGTERM and `stop` may be omitted; see Open Question OQ-3).
  - `list-devices` — print available input audio devices (name, UID,
    sample-rate range), useful for selecting `--mic-device`.
  - `check-permissions` — print the current state of Screen Recording and
    Microphone permissions without starting a recording.
  - `--help` / `-h` and `--version` / `-V` available globally.

**FR-12 — Configuration precedence.** Configuration values MUST be resolved
in this order, lowest-to-highest priority (higher overrides lower):
  1. Shell environment (`ProcessInfo.processInfo.environment`).
  2. `~/.tool-agents/<tool-name>/.env`.
  3. `./.env` in the current working directory.
  4. CLI flags.

**FR-13 — Per-user durable defaults bootstrap.** On every invocation the
tool MUST ensure `~/.tool-agents/<tool-name>/` exists with mode `0700`. If
absent, it MUST create it and seed an empty `.env` with mode `0600`.

**FR-14 — No silent fallbacks.** If a required configuration value is not
provided through any source in the precedence chain, the tool MUST raise a
descriptive error naming the missing variable and the sources that were
checked. It MUST NOT substitute a default unless that default is explicitly
called out in this document (e.g. format = `m4a`, sample rate = 48 kHz).

**FR-15 — Output path handling.** The user MUST specify the output path via
`--output <path>` (or env var). If the path's parent directory does not
exist, the tool MUST raise an error rather than create it implicitly. If a
file already exists at the output path, the tool MUST refuse to overwrite
unless `--overwrite` is passed.

**FR-16 — Tool documentation.** The tool MUST be documented at
`docs/tools/<tool-name>.md` in the prescribed `<toolName><objective>...
<command>...<info>...</toolName>` XML-tagged format, and the project's
`CLAUDE.md` MUST list the tool under its "Tools" section with a short
summary and a relative link to that file.

### Non-functional requirements

**NFR-1 — Target OS.** The tool MUST build and run on macOS 13.0+ as a
minimum (required by `ScreenCaptureKit` audio capture). The recommended
target is **macOS 14.0+** (Sonoma) so the implementation can use the
audio-only `SCStream` configuration path; this choice is surfaced as
Open Question OQ-1.

**NFR-2 — Architectures.** The binary MUST run natively on Apple Silicon
(arm64). x86_64 (Intel) compatibility is desirable but not required for v1
(Open Question OQ-4).

**NFR-3 — Performance — no dropped frames.** Under normal desktop load on
the user's machine, the tool MUST sustain a 60-minute continuous recording
without dropping audio buffers. Drops, if any, MUST be detected and
reported with a non-zero exit code at end of session.

**NFR-4 — Performance — A/V sync between sources.** The mic and system
streams MUST be aligned to within ±20 ms across the entire recording.
Implementation note (informational, not prescriptive): both `SCStream` and
`AVCaptureSession` deliver `CMSampleBuffer`s with `CMTime` presentation
timestamps; the implementation should use these timestamps as the source
of truth for alignment rather than wall-clock timing.

**NFR-5 — Resource footprint.** The tool SHOULD use less than 250 MB of
resident memory and less than 25% of one CPU core during a steady-state
recording of stereo 48 kHz audio.

**NFR-6 — Privacy & security.**
  - The tool MUST never transmit captured audio over the network.
  - The tool MUST never write audio to any path outside the user-specified
    `--output` location (and a temp directory if buffering is needed).
  - The tool MUST clean up temporary files on `stop`, `SIGINT`, `SIGTERM`,
    and uncaught error exits.
  - The recording session MUST be visible in the macOS menu bar / Control
    Center (this is automatic with `ScreenCaptureKit` and microphone use,
    and the tool MUST NOT attempt to suppress that indicator).

**NFR-7 — Error handling.** All user-facing errors MUST:
  - Exit with a documented non-zero exit code.
  - Print a one-line summary to `stderr`.
  - Print actionable remediation guidance (which permission to grant,
    which flag to pass, etc.).
  - Never include private user data (audio samples, mic device serials,
    etc.) in error messages.

**NFR-8 — Logging.** The tool MUST support `--log-level
{quiet|info|debug}`, default `info`. Logs go to `stderr`; the recording
itself is the only thing on `stdout` only if explicitly piped (see OQ-5).

**NFR-9 — Code organization.** The codebase MUST be a Swift Package
(`Package.swift`) with at minimum:
  - An executable target for the CLI.
  - A library target encapsulating capture, mixing, encoding, and
    permission logic, so the same library can later back a menu-bar UI
    without refactor.
  - A test target.

**NFR-10 — Tests.** A test_scripts folder MUST hold any
manual/integration test scripts. Automated unit tests MUST cover at
minimum: configuration precedence resolution, CLI argument parsing,
permission state detection (mockable), and output-path validation. End-
to-end recording tests are acknowledged as difficult to automate in CI
and may be manual.

## Constraints

- **Language is locked to Swift** by Exception 001 in the project's
  `CLAUDE.md` (approved 2026-04-26). Downstream phases MUST NOT propose
  TypeScript, Node FFI, Python, Rust, etc.
- **Build system**: Swift Package Manager (`swift build`, `swift run`,
  `swift test`). No CocoaPods, no Carthage, no Xcode-only project files.
- **Frameworks**: prefer first-party Apple frameworks (`ScreenCaptureKit`,
  `AVFoundation`, `CoreAudio`, `AudioToolbox`, `Foundation`,
  `ArgumentParser` from swift-argument-parser). Third-party Swift
  dependencies are permitted only if there is no first-party equivalent
  and they are added through SPM.
- **Platform**: macOS 13.0 minimum, macOS 14.0+ recommended (see OQ-1).
- **TCC permissions**: Screen Recording and Microphone are mandatory and
  cannot be silently bypassed; this is a platform constraint.
- **No virtual audio devices**: the tool MUST work out of the box on a
  stock macOS install with no kernel/driver components.
- **No version control operations** unless the user explicitly asks for
  them (project-wide convention).
- **No fallback config values** (project-wide convention).

## Acceptance Criteria

Each criterion is a concrete, demonstrable check. The work is "done" when
all are satisfied.

**AC-1.** Running `swift build` from a clean checkout on macOS 14+
produces a functional executable with no errors or warnings related to
deprecated APIs.

**AC-2.** Running `<binary> check-permissions` on a fresh machine prints
the current Screen Recording and Microphone TCC states (granted / denied
/ not-determined) and exits 0 if both are granted, non-zero otherwise.

**AC-3.** Running `<binary> list-devices` prints at least the built-in
microphone with its name and UID, in a parseable single-record-per-line
format.

**AC-4.** Running
`<binary> start --output ~/recordings/test.m4a --max-duration 30` while
audio is playing through the speakers and the user is speaking produces,
within ~30 seconds, a single `.m4a` file at the specified path that:
  - Opens cleanly in QuickTime Player and Music.app.
  - Contains audible mic content AND audible system content (verified by
    listening).
  - Has a duration within ±0.5 s of the requested 30 s cap.
  - Reports stereo, 48 kHz, AAC-LC ~192 kbps in `afinfo`.

**AC-5.** Running the same command with `--layout split` produces two
files (`test.mic.m4a` and `test.system.m4a`) of approximately equal
duration, each containing only its respective source.

**AC-6.** Running with `--layout stereo-split` produces a single stereo
file where the mic is fully on one channel and the system audio fully on
the other (verified by inspecting channel waveforms in Audacity or
equivalent).

**AC-7.** Sending `SIGINT` (Ctrl-C) to a running recording finalizes the
file properly: it is playable end-to-end with no truncated atom/header
errors.

**AC-8.** Denying Screen Recording permission and running `start` causes
the tool to exit non-zero with a clear stderr message naming the
permission and the exact System Settings path; no partial output file is
created.

**AC-9.** Setting `OUTPUT_PATH` in `./.env` and running
`<binary> start` (no `--output` flag) uses the `.env` value. Setting the
same variable in the shell and in `~/.tool-agents/<tool>/.env` and
passing `--output` on the CLI confirms the documented precedence
(CLI > local `.env` > user `.env` > shell env).

**AC-10.** Removing `~/.tool-agents/<tool>/` and running any subcommand
recreates the directory at mode `0700` and seeds a `.env` at mode
`0600`.

**AC-11.** A 60-minute recording produces a file whose audio duration is
within ±1 s of 60 minutes and contains no audible discontinuities (manual
listen on three random 30-second windows).

**AC-12.** Mic-vs-system A/V sync drift across a 60-minute recording is
within ±20 ms (measured by playing a clap that hits both the mic and
the system playback simultaneously at the start and end of the
recording).

**AC-13.** The tool's documentation file exists at
`docs/tools/<tool-name>.md` in the prescribed XML-tagged format, and the
project's `CLAUDE.md` "Tools" section references it.

**AC-14.** `docs/design/project-design.md` and
`docs/design/project-functions.md` exist and reflect the implementation.

**AC-15.** `Issues - Pending Items.md` exists at project root with the
documented format (pending items first, ordered by criticality;
completed items below).

**AC-16.** Running `macrec start --detach --output /tmp/test.m4a` returns
the shell prompt within 1 s, creates a PID file at
`~/.tool-agents/macrec/macrec.pid` containing a live PID, and produces a
recording when stopped.

**AC-17.** Running `macrec stop` against a live detached process sends
SIGTERM, the process exits cleanly within the default `--stop-timeout`
(35 s), the output file is finalized, and the PID file is removed.

**AC-18.** Running `macrec stop` with no PID file present exits with
`MacrecError.noActiveRecording` and a clear stderr message; no PID file
is created.

**AC-19.** Running `macrec stop` with a stale PID file (PID no longer
alive) cleans up the file and exits with `MacrecError.staleRecording`
(documented behavior: exit code = 75 (`EX_TEMPFAIL`); see Section 14 of
project-design.md for the rationale — staleness is a transient
"start a new recording" condition rather than a hard failure).

**AC-20.** Attempting `macrec start --detach` while another detached
recording is running exits with `MacrecError.alreadyRecording` and does
not disturb the running recording.

## Assumptions

- **A-1.** The user is on macOS 14+ (their `Darwin 25.4.0` is consistent
  with macOS 15). Hard minimum is macOS 13.0 to make `ScreenCaptureKit`
  audio capture available.
- **A-2.** The MacBook is Apple Silicon (arm64). Intel support is "nice
  to have" but not gated.
- **A-3.** The user is willing to grant Screen Recording and Microphone
  permissions to this tool exactly once, via the standard TCC prompts.
- **A-4.** The default audio output route (built-in speakers, AirPods,
  USB DAC, etc.) does not affect the ability of `ScreenCaptureKit` to
  capture the system submix. (This holds for all known macOS 13+
  configurations; documented as a known limitation if a specific Bluetooth
  routing edge case is encountered.)
- **A-5.** Single-user, single-machine, local recording use case — no
  multi-tenant, multi-user, or remote concerns.
- **A-6.** Recordings are stored unencrypted on the local filesystem;
  whole-disk FileVault is considered the user's responsibility.
- **A-7.** "Mixed" layout means a simple sum (with optional gain matching);
  no ducking, no AGC, no noise gate, no echo cancellation.
- **A-8.** The CLI is foreground-only in v1: `start` blocks until `stop`
  is received via SIGINT/SIGTERM or the `--max-duration` cap fires. There
  is no background daemon and no inter-process `stop` command in v1; this
  simplifies state management and removes the need for a PID file or
  socket. (See OQ-3 — confirm or override.)
- **A-9.** Output container/codec choices (`m4a`/AAC, `wav`/PCM,
  `caf`/AAC) cover the user's needs. FLAC, MP3, Opus, etc. are not
  required for v1.

## Open Questions

These are surfaced for the user to confirm or override at the start of the
design phase. Each has a recommended default so the design can proceed
without blocking.

**OQ-1 — Minimum macOS target: 13.0 vs. 14.0+?** macOS 13 is the floor
for `ScreenCaptureKit` audio capture; macOS 14 (Sonoma) adds richer
audio-only `SCStream` configuration paths and the `SCContentSharingPicker`
flow. *Recommended default*: **macOS 14.0+** for cleaner APIs, since the
user is on macOS 15.

**OQ-2 — CLI binary name.** The project is "recording-tool" but a tool
needs a concrete invocable command. Candidates:
  - `macrec` — short, mnemonic, macOS-flavored. **Recommended default.**
  - `audiorec` — explicit but generic.
  - `recorder` — friendly but collides with many existing utilities.
  - `dualrec` — emphasizes the two-source nature.

**OQ-3 — Single-process foreground vs. background daemon for `stop`.**
*Recommended default*: **single-process foreground** in v1 (`stop` is
implicit via SIGINT/SIGTERM, and the `stop` subcommand is omitted from
v1). Adding a daemon mode with a PID file is a v2 enhancement.

> **2026-04-26 update — overridden by user.** v1 supports BOTH foreground (default) and detached background execution via `--detach` + `stop`. See FR-25..FR-29 and the design's Section 14.

**OQ-4 — Intel (x86_64) support.** *Recommended default*: build
**universal binary** (arm64 + x86_64) since SPM makes this nearly free,
unless a dependency forces arm64-only.

**OQ-5 — Output to stdout.** Should `--output -` stream the encoded
bytes to stdout (useful for piping into ffmpeg or sox)? *Recommended
default*: **not in v1**. v1 always writes to a file path.

**OQ-6 — Track layout default.** `mixed` vs. `split` vs.
`stereo-split` as the default when `--layout` is omitted. *Recommended
default*: **`mixed`** (one file, instantly playable). Power users opt
into `split` or `stereo-split`.

**OQ-7 — Output format default.** *Recommended default*: **`m4a`**
(AAC, ~192 kbps stereo, ~1.5 MB/min). `wav` is available for users who
need lossless.

**OQ-8 — Mic device selection by name vs. UID.** Names are user-friendly
but not unique; UIDs are stable but ugly. *Recommended default*: accept
**either** in `--mic-device`; resolve names case-insensitively and warn
if multiple devices match.

**OQ-9 — Behavior when system audio submix is silent.** If nothing is
playing, the system stream is legitimately silent, but so is a stream
where capture has silently failed. *Recommended default*: log a `debug`-
level note every 10 s noting the system stream's RMS level so the user
can confirm the path is alive when reviewing debug logs.

**OQ-10 — Required vs. optional config values.** Per project convention,
no fallback values are allowed for *required* settings. Which values are
*required* (no default permissible) and which are *defaultable*?
*Recommended split*:
  - **Required (no default, must be supplied):** `--output` /
    `OUTPUT_PATH`.
  - **Defaultable (defaults documented in this spec):** `--format`
    (`m4a`), `--layout` (`mixed`), `--sample-rate` (48000),
    `--bit-depth` (16), `--bitrate` (192), `--mic-device` (system
    default), `--log-level` (`info`).

## Suggested CLI Binary Name

**`macrec`** — short, memorable, unambiguously macOS-flavored, no known
conflicts on a stock macOS install. Used throughout this document as a
placeholder pending OQ-2 resolution. The tool-name token used for
`docs/tools/<tool-name>.md` and `~/.tool-agents/<tool-name>/` will follow
the same name (i.e. `docs/tools/macrec.md` and
`~/.tool-agents/macrec/`).

## Glossary

Terms used consistently throughout this and downstream documents:

- **System audio** — the audio that macOS would play through the current
  output device, summed across all running processes. Equivalent to
  "what's coming out of the speakers." Captured here via
  `ScreenCaptureKit`.
- **Process audio** — audio belonging to one specific running process
  (e.g. only Zoom). v1 does NOT capture process audio individually; this
  is a v2 enhancement (`SCStream` exposes per-process include/exclude
  filtering).
- **Microphone audio / mic audio** — the local capture from the input
  device (built-in mic by default, or whatever
  `--mic-device` selects).
- **Submix** — a pre-mixed combination of multiple sources into a single
  stream. The "system audio" stream is itself a submix of all process
  outputs, performed by macOS before the tool sees it.
- **Mixed layout** — mic and system audio summed into a single output
  stream (mono or stereo).
- **Split layout** — mic and system audio written to two separate
  output files.
- **Stereo-split layout** — mic on one channel and system audio on the
  other within a single stereo file.
- **TCC** — *Transparency, Consent, and Control*: macOS's per-app
  permission system that gates Screen Recording, Microphone, Camera, etc.
- **`SCStream`** — `ScreenCaptureKit`'s streaming session type, used
  here in audio-only configuration.
- **`AVCaptureSession`** — `AVFoundation`'s capture-session type, used
  here for microphone input.
- **`CMSampleBuffer` / `CMTime`** — Core Media types delivered by both
  capture APIs; their `CMTime` presentation timestamps are the canonical
  source for cross-source A/V alignment.
- **TCC prompt** — the system-modal dialog macOS shows the first time an
  app touches a protected resource.
- **Universal binary** — a single Mach-O containing both arm64 and
  x86_64 slices, runnable on Apple Silicon and Intel.

## Original Request

> I want a tool to record audio from my MacBook, including:
> 1. The audio playing on my MacBook through media applications (Music,
>    Spotify, browser playing video/audio, etc.) and through communication
>    applications (Zoom, Teams, FaceTime, Slack, etc.) — i.e. "system
>    audio" / "what is playing on the speakers".
> 2. The MacBook's built-in microphone.
>
> Both sources must be capturable simultaneously. Implementation language
> is Swift (this is an explicit, user-approved exception to the project's
> "TypeScript only" rule, recorded in the project CLAUDE.md as Exception
> 001 — DO NOT propose changing the language).
