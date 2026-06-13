# Investigation: macOS Dual-Source Audio Recorder (Swift)

## Executive Summary

This investigation evaluates concrete implementation strategies for the
Swift-locked macOS CLI defined in
`docs/design/refined-request-recording-tool.md`. The refined spec already
commits to `ScreenCaptureKit` + `AVFoundation` for capture; this document
resolves every secondary technical decision needed before planning can begin.

**Headline recommendations:**

| Topic | Recommendation |
|---|---|
| System-audio capture | `ScreenCaptureKit` `SCStream` in audio-only configuration (target macOS 14.0+) |
| Microphone capture | `AVCaptureSession` + `AVCaptureAudioDataOutput` (uniform `CMSampleBuffer` pipeline with SCStream) |
| Device enumeration | Core Audio HAL (`kAudioHardwarePropertyDevices`) for canonical UID + name; cross-reference `AVCaptureDevice` so `--mic-device` accepts either |
| Mixing & encoding | Pull all `CMSampleBuffer`s into a small in-process ring-buffered pipeline that converts via `AVAudioConverter` to a canonical Float32 / 48 kHz / stereo internal format, then writes via `AVAssetWriter` (m4a/AAC) or `AVAudioFile` (wav/caf PCM) |
| A/V sync | Use `CMClock.hostTimeClock` as common base; SCStream already uses it; force AVCaptureSession's audio output onto the same clock via `AVCaptureSession.synchronizationClock = CMClockGetHostTimeClock()`; drift-correct with PTS deltas + silence insertion |
| CLI parser | `apple/swift-argument-parser` (1.5.0+) — `AsyncParsableCommand` with subcommands |
| TCC permissions | `CGPreflightScreenCaptureAccess` + `CGRequestScreenCaptureAccess` for screen recording; `AVCaptureDevice.requestAccess(for: .audio)` for mic; one-shot prompt + relaunch UX (CLI cannot reliably observe permission flips in-process) |
| Config / env loader | Hand-rolled minimalist `.env` parser inside the project (~80 lines, zero deps) — third-party `.env` packages mutate `ProcessInfo.environment` which fights our 4-source precedence chain |
| Logging | `swift-log` with a custom stderr `LogHandler`; map `--log-level {quiet|info|debug}` onto `.warning` / `.info` / `.debug` |
| Testing | Protocol-injected capture providers; XCTest for unit tests; `test_scripts/` shell harness for E2E manual runs |
| Project layout | Single SPM package, executable target (`macrec`) + library target (`MacrecCore`) + test target (`MacrecCoreTests`) |

**Total third-party SPM dependencies: 2** (`swift-argument-parser`,
`swift-log`). All audio capture, mixing, and encoding stays on first-party
Apple frameworks.

---

## Context

- **What is being investigated**: implementation approaches for a Swift CLI
  that records system audio and microphone audio concurrently and writes
  them to disk.
- **Driving requirements**: the refined-request file lists FR-1..FR-16 and
  NFR-1..NFR-10. Critical constraints that shape this investigation:
  - **Swift only** (Exception 001 in `CLAUDE.md`).
  - **No virtual audio devices** (no BlackHole, Loopback, etc.).
  - **macOS 13.0 floor**, **macOS 14.0+ recommended** (OQ-1).
  - **A/V drift ≤ ±20 ms over 60 minutes** (NFR-4).
  - **Configuration precedence**: shell env → `~/.tool-agents/<tool>/.env`
    → local `.env` → CLI flags, with **no fallback for required values**.
  - **Library target mandatory** (NFR-9) so a future menu-bar UI can reuse
    capture/mixing/encoding/permission logic without refactor.
- **Refined request**:
  `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/docs/design/refined-request-recording-tool.md`.

---

## 1. System Audio Capture Path

### Options surveyed

#### Option A — `ScreenCaptureKit` `SCStream` audio-only configuration
- Set `SCStreamConfiguration.capturesAudio = true`,
  `excludesCurrentProcessAudio = true`, `sampleRate = 48000`,
  `channelCount = 2`. There is **no documented "audio only" flag**; the
  community workaround is to set
  `minimumFrameInterval = CMTime(value: 1, timescale: 1)` (1 fps) — or even
  `0.1 fps` — to suppress video processing cost while keeping the audio
  callback alive. The frame-output callback can simply discard incoming
  video buffers.
- `SCContentFilter` for the entire system submix is constructed via
  `SCShareableContent.current.displays.first` → `SCContentFilter(display:
  excludingApplications: [], exceptingWindows: [])`. We do not actually use
  the captured screen pixels; the filter is required because `SCStream`
  always demands one.
- macOS 13.0: audio capture is available but no first-class audio-only
  mode exists. macOS 14.0+: cleaner config; SCStream's audio buffer
  delivery is more stable in long sessions. macOS 15.0+: a
  `MicrophoneCaptureEnabled` flag was added on `SCStreamConfiguration`,
  but it does not solve the system-audio "no video" gap and is irrelevant
  for our use case (we capture the mic ourselves).
- Known issues observed in the wild:
  - Reports of `EXC_BAD_ACCESS` in long captures and `SCStreamErrorDomain
    -3805` on macOS 15 in some bindings (mostly PyObjC). Native Swift
    appears stable.
  - "Silent stop after ~10–15 minutes" reports for `captureMicrophone =
    true` combined paths — we sidestep this by capturing the mic
    independently via AVCaptureSession.

#### Option B — Core Audio process taps (`AudioHardwareCreateProcessTap`, macOS 14.4+)
- Released in macOS 14.4 (publicly documented). Pure audio API — no
  video pipeline overhead. Workflow:
  1. Build a `CATapDescription` (system-wide or per-PID).
  2. `AudioHardwareCreateProcessTap` → tap `AudioObjectID`.
  3. Read `kAudioTapPropertyFormat` to obtain its `AudioStreamBasicDescription`.
  4. Build a private aggregate device that includes the tap as a sub-tap
     via `AudioHardwareCreateAggregateDevice` with
     `kAudioAggregateDeviceTapListKey`.
  5. `AudioDeviceCreateIOProcIDWithBlock` to receive PCM in a real-time
     callback.
  6. Wrap each callback's `AudioBufferList` into an `AVAudioPCMBuffer` and
     pipe to `AVAudioFile` or `AVAssetWriter`.
- TCC: requires `NSAudioCaptureUsageDescription` in Info.plist — a
  problem for non-bundled CLIs. The reference project (insidegui/AudioCap)
  is a SwiftUI `.app` bundle.
- Known caveats:
  - Documentation bug (sample code uses wrong `AudioObjectID` when
    setting `kAudioAggregateDevicePropertyTapList`; FB17411663).
  - Real-time IOProc constraints — no allocation, no locking, no
    Objective-C runtime calls.
  - PID filtering fails if the targeted process is not currently
    producing audio.
  - Level attenuation reports on multi-output devices (4-pair devices
    show ~−12 dB attenuation vs. true stereo devices).
- **Pro**: no fake video pipeline; lower overhead.
- **Con**: requires macOS 14.4 floor (vs. 14.0); sparsely documented;
  requires real-time-safe code; the TCC story for plain-binary CLIs is
  unsettled.

#### Option C — Hybrid (SCStream now, ProcessTap later)
Encapsulate the system-audio source behind a protocol so v1 ships on
`SCStream` and a v2 swap to `AudioHardwareCreateProcessTap` is a
contained change.

### Comparison

| Criterion | A — SCStream | B — ProcessTap | C — Hybrid abstraction |
|---|---|---|---|
| macOS floor | 13.0 (14.0+ cleaner) | 14.4+ | 13.0 (with v2 path = 14.4+) |
| First-party docs maturity | High | Medium (terse) | High |
| Audio-only purity | Workaround required | Native | Both |
| TCC for plain CLIs | Established (Screen Recording prompt works) | Unknown for non-bundled (`NSAudioCaptureUsageDescription`) | Inherits A initially |
| Long-run stability evidence | Several reports of bugs but native Swift seems OK; widely deployed | Newer; AudioCap & AudioTee in field | Same as A |
| Real-time-safety pitfalls | Lower — ScreenCaptureKit handles it | Higher — IOProc must be RT-safe | Same as A initially |
| Per-process filtering future | `SCContentFilter` already supports excludingApplications | Native PID filter via `CATapDescription` | Both |
| Implementation effort | Medium | Medium-High | Medium + small abstraction overhead |

### Recommendation — System audio

**Option A (SCStream) for v1**, behind a `SystemAudioSource` protocol so
the future ProcessTap implementation slots in without breaking callers.
This satisfies OQ-1's recommended **macOS 14.0+** target, keeps us on
proven, well-documented APIs, and aligns with the spec's explicit
direction in FR-2.

Concretely for the SCStreamConfiguration:

```
let cfg = SCStreamConfiguration()
cfg.capturesAudio = true
cfg.excludesCurrentProcessAudio = true
cfg.sampleRate = 48_000
cfg.channelCount = 2
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)   // 1 fps placeholder
cfg.queueDepth = 6                                          // small ring
cfg.width = 2; cfg.height = 2                               // tiny frame, ignored
```

`SCContentFilter`: pick the main display, exclude no apps. Discard video
samples in `stream(_:didOutputSampleBuffer:of:)` when `type == .screen`;
forward only `type == .audio`.

**Why not B for v1**: macOS 14.4 floor versus 14.0 is a real cost (one
fewer minor version of headroom for users), the API is sparsely
documented, and the TCC story for plain executable CLIs hasn't been
validated by community examples. Re-evaluate for v2 if SCStream stability
becomes a problem on long recordings or per-process filtering becomes a
requirement.

---

## 2. Microphone Capture Path

### Options surveyed

#### Option A — `AVCaptureSession` + `AVCaptureAudioDataOutput`
- Native `CMSampleBuffer` delivery — same buffer type as SCStream.
- `AVCaptureDevice` selection works reliably with built-in mic, USB
  mics, and Bluetooth devices.
- Synchronization clock is exposed:
  `AVCaptureSession.synchronizationClock` (read-write on macOS 12+) —
  set to `CMClockGetHostTimeClock()` to share SCStream's clock domain.
- Built-in gap handling via PTS — see Nonstrict's well-known walkthrough.

#### Option B — `AVAudioEngine` + `inputNode.installTap(...)`
- Delivers `AVAudioPCMBuffer`, NOT `CMSampleBuffer` — every sample must
  then be converted before it can share the AVAssetWriter pipeline with
  the SCStream audio.
- On macOS, the input node is bound to the system default device; you
  cannot easily switch to a non-default mic without going down to Core
  Audio HAL.
- Reported reliability issues with Bluetooth devices (taps don't fire on
  some headsets).
- Sample-rate is determined by the device hardware (e.g. AirPods 24 kHz)
  and switches if the device changes mid-session.

#### Option C — Core Audio HAL directly (`AudioObject*`, `AudioDeviceCreateIOProc`)
- Maximum control. Highest code volume. Real-time-safety constraints.
- Useful only if Option A proves insufficient for some specific device
  (no evidence it will).

### Comparison

| Criterion | A — AVCaptureSession | B — AVAudioEngine | C — Core Audio HAL |
|---|---|---|---|
| Buffer type | `CMSampleBuffer` (matches SCStream) | `AVAudioPCMBuffer` (needs conversion) | Raw `AudioBufferList` |
| Mic device override (`--mic-device`) | First-class via `AVCaptureDevice` | Awkward on macOS — default device only | Possible but verbose |
| Bluetooth & USB reliability | High | Mixed reports | High but more code |
| Sync clock control | `synchronizationClock` settable | Implicit to engine clock | Manual |
| Gap handling | `CMSampleBuffer` PTS makes this easy | Possible but less idiomatic | Manual |
| Code size | Smallest | Small for fixed-default-device case | Largest |

### Device enumeration for `list-devices`

The user's mental model for "input devices" is **System Settings →
Sound → Input**, which is a Core Audio listing — names from
`kAudioDevicePropertyDeviceNameCFString` and UIDs from
`kAudioDevicePropertyDeviceUID`. `AVCaptureDevice.devices(for: .audio)`
on macOS reports a subset and uses `localizedName` which sometimes
diverges from the System Settings label. **Use the Core Audio HAL
enumeration for `list-devices`**, then resolve `--mic-device <name|uid>`
into an `AVCaptureDevice` via `AVCaptureDevice(uniqueID:)` (the UID is
identical between the two namespaces).

### Recommendation — Microphone

**Option A (AVCaptureSession)** for capture, **Core Audio HAL** for
device enumeration. This gives one uniform `CMSampleBuffer` pipeline for
both sources, the smallest amount of capture code, the most reliable
device-selection UX, and a settable synchronization clock that we will
use to align with SCStream's host clock.

Sketch:

```
let session = AVCaptureSession()
session.synchronizationClock = CMClockGetHostTimeClock()
let device  = try resolveMicDevice(option: --mic-device)
let input   = try AVCaptureDeviceInput(device: device)
let output  = AVCaptureAudioDataOutput()
output.setSampleBufferDelegate(self, queue: micQueue)
session.addInput(input); session.addOutput(output)
session.startRunning()
```

---

## 3. Mixing & Encoding Pipeline

### Internal canonical format (recommendation)

Converge **both sources** onto a single internal format and operate on
that format throughout the pipeline:

- **Sample rate**: 48 000 Hz (matches SCStream native; matches default
  `--sample-rate`).
- **Channel count**: 2 (stereo).
- **Sample format**: Float32, non-interleaved.
- **Time base**: `CMClock.hostTimeClock`.

Justification:
- SCStream natively delivers Float32 at 48 kHz.
- `AVAudioConverter` produces Float32 cleanest; downcasting to Int16
  happens at the writer boundary only.
- Mono mics get upmixed to stereo in the converter (FR-9).
- Avoiding repeated format flips inside the graph eliminates an entire
  class of bugs.

### Mixing options (for `mixed` layout)

| Approach | Pros | Cons |
|---|---|---|
| **A. AVAudioEngine graph** with two `AVAudioPlayerNode`s feeding `mainMixerNode` feeding a tap that writes to file | Concise. Apple-blessed mixing semantics. Channel routing built-in via channel maps. | Requires bridging `CMSampleBuffer` → `AVAudioPCMBuffer` to feed `scheduleBuffer` on a player node — more glue than expected for a streaming source |
| **B. Manual sum on `AVAudioPCMBuffer`s** in CPU code, then write | Total control. Trivial gain matching, mute-on-silence, clipping detection. ~50 lines. | We re-implement what `mixerNode` already does — but the surface area is small (sum two stereo Float32 buffers of equal length). |
| **C. Two `AVAssetWriterInput`s** + a CoreMedia mixing tap | Avoids a custom mixer. | "Mixing tap" on AVAssetWriter is for editing pipelines, not live capture; awkward in this context. |

### `split` layout
Two independent pipelines: each source gets its own
`AVAssetWriter`/`AVAudioFile` with the same canonical internal format.
File names follow FR-5: `<basename>.mic.<ext>` and
`<basename>.system.<ext>`.

### `stereo-split` layout
After resampling both sources to mono Float32, build a single stereo
`AVAudioPCMBuffer` per output frame: copy mic into channel L (or R per
`--mic-channel`), system into the opposite channel. No mixer needed,
no `AVAudioMixerNode` — straight buffer assembly.

### Encoding (writer choice)

| Output format | Recommended writer | Why |
|---|---|---|
| `m4a` (AAC-LC, default) | `AVAssetWriter` + `AVAssetWriterInput` (AAC) | Honors `AVEncoderBitRateKey` (FR-8: 192 kbps default). `AVAudioFile` ignores bit-rate hints for compressed formats. |
| `wav` (16-/24-bit PCM) | `AVAudioFile` (WAVE) | Simplest API; PCM has no encoder knobs to tune. |
| `caf` (AAC by default; PCM possible) | `AVAudioFile` for PCM-CAF, `AVAssetWriter` for AAC-CAF | Same logic as above. |

Use `AVAudioConverter` (single long-lived instance per source!) for the
mic-source resample-and-upmix step. Critical pitfall noted in research:
**do not recreate the converter per buffer** — AAC encoders need 2112
priming frames; recreating drops them and produces silence runs.

### Recommendation — Mixing & Encoding

- **Internal format**: Float32 / 48 kHz / stereo, host-clock timestamps.
- **Mixing**: **Option B** (manual sum on `AVAudioPCMBuffer`) for
  `mixed`, channel-pinning for `stereo-split`, two independent writers
  for `split`. AVAudioEngine's mixer adds glue cost without proportional
  benefit when both inputs are already Float32 and time-aligned.
- **Encoder**: `AVAssetWriter` for AAC m4a/caf,  `AVAudioFile` for
  PCM wav/caf.
- **Resampler**: one `AVAudioConverter` per source, lifetime-bound to
  the recording session, configured at first-buffer arrival.

ASCII architecture sketch:

```
                ┌───────────────────────────────────────────────────────┐
                │              Capture & Encode Pipeline                │
                │                                                       │
  SCStream  ───►│ SystemSource ─► RingBuf ─► (Float32/48k/stereo)       │
  (host clk)    │                                ▼                      │
                │                            ┌── Aligner ──┐  (PTS-     │
  AVCapture ───►│ MicSource ───► RingBuf ──► │             │   matched, │
  Session       │  (host clk via  AVAudio    │             │   silence- │
  (forced       │   syncClock)    Converter  │             │   filled)  │
  host clk)     │                            └─────┬───────┘            │
                │                                  ▼                    │
                │                       ┌──────── Mixer ────────┐       │
                │                       │  layout=mixed: sum L+R│       │
                │                       │  layout=split:  passthru│      │
                │                       │  layout=stereo-split:  │      │
                │                       │       L=mic, R=system  │      │
                │                       └──────────┬─────────────┘      │
                │                                  ▼                    │
                │                  ┌─────────── Writer ──────────┐      │
                │                  │  m4a → AVAssetWriter (AAC)  │      │
                │                  │  wav/caf → AVAudioFile (PCM)│      │
                │                  │  caf-AAC → AVAssetWriter    │      │
                │                  └──────────┬──────────────────┘      │
                │                             ▼                         │
                │                        on-disk file(s)                │
                └───────────────────────────────────────────────────────┘
```

---

## 4. A/V Sync Between Mic and System Streams

### The problem
SCStream stamps `CMSampleBuffer.presentationTimeStamp` from the **host
time clock** (`CMClock.hostTimeClock`). AVCaptureSession by default
stamps with the **audio device's clock** (a hardware clock). The two
clocks drift relative to each other (typical hardware oscillators drift
a few ppm to ~50 ppm), which over 60 minutes can exceed the ±20 ms NFR.

### Options

#### A — Force AVCaptureSession onto the host clock
`AVCaptureSession.synchronizationClock = CMClockGetHostTimeClock()`
(macOS 12.0+). Output PTS values are then derived from the host clock
and directly comparable with SCStream PTSs. **No drift correction
needed.**

#### B — Capture initial offset, retime in software
Record `(systemHostTime, micHostTime)` at the first sample of each
stream, compute `offset`, retime mic samples via
`CMSampleBufferCreateCopyWithNewTiming`. Works on older macOS where
`synchronizationClock` is unavailable (we don't need it — our floor is
14.0).

#### C — `CMSyncGetRelativeTime`
Translate between two `CMClock` instances on the fly. Useful if we
choose Option B and want an exact offset every buffer; overkill if we
take Option A.

#### D — Drift correction at the aligner
Independent of A/B/C: track `expectedNextPTS` per source; if a buffer
arrives early/late by more than one sample, insert silence or drop
samples to maintain alignment. Always required for capture-gap
robustness.

### Realistic accuracy ceiling
With Option A + Option D combined, the residual drift over 60 minutes
is bounded by host-clock granularity (sub-millisecond) plus
buffer-boundary quantization (≤ one buffer = typically 10 ms at
default queue depth). **±10 ms is comfortably reachable**; ±20 ms is
the spec target.

### Recommendation — A/V sync

**Option A + Option D**: set
`AVCaptureSession.synchronizationClock = CMClockGetHostTimeClock()` so
both streams share the host clock; pair with a small drift-correcting
aligner that tracks `nextExpectedAudioTime` per source and inserts
silence when gaps exceed one sample. Keep Option B as a documented
fallback in code comments for any future macOS-13 build.

---

## 5. CLI Argument Parser Library

### Options
- **`apple/swift-argument-parser`** — de facto standard. Latest minor
  observed in research is **1.5.0** (1.4.0 added subcommand aliases;
  1.5.0 added grouped-help-display sections and silenced Swift-6 strict-
  concurrency warnings). Apache-2.0 license.
- Hand-rolled — viable for a 5-arg tool, but our CLI has ≥ 4
  subcommands and ~12 flags. Not worth it.

### Recommendation — CLI parser

**`apple/swift-argument-parser`, pinned to `from: "1.5.0"`**. Use
`AsyncParsableCommand` for the root and for `start` (so the recording
loop can `await stream.startCapture()` directly), `ParsableCommand` for
synchronous subcommands (`list-devices`, `check-permissions`).

Subcommand layout:

```
macrec
├── start              (AsyncParsableCommand; default subcommand)
├── list-devices       (ParsableCommand)
├── check-permissions  (ParsableCommand)
└── (stop omitted in v1 per OQ-3 — SIGINT/SIGTERM handling)
```

`@OptionGroup` on shared flags (`--log-level`, `--output`, `--format`,
etc.) keeps DRYness. Env-var binding is **not** built-in to
swift-argument-parser; we wire it through our own resolver (see §7) and
pass the resolved values to the parser via `transform:` closures or by
reading from the resolver inside `run()`.

---

## 6. TCC Permission Detection & Prompting

### Screen recording

| API | Behavior | Available since |
|---|---|---|
| `CGPreflightScreenCaptureAccess()` | Returns Bool. Pure check; never triggers a prompt. | macOS 11.0 |
| `CGRequestScreenCaptureAccess()` | Returns Bool immediately; if state is "not determined", spawns the system prompt asynchronously (in a separate process). Does **not** wait. | macOS 11.0 |

Caveats discovered:
- `CGPreflightScreenCaptureAccess` has been reported as deprecated /
  unstable on macOS 15.x (Sequoia) — but no replacement exists; Apple's
  official path forward is "just call SCShareableContent and let it
  fail." We will keep using preflight for `check-permissions` and treat
  errors as "not determined".
- A known macOS quirk: once you call `CGRequestScreenCaptureAccess()`
  in a process and TCC state changes, the **same process keeps reading
  the old answer**. The user must relaunch the binary to see the new
  state. Our CLI will exit after the prompt with a clear "please
  relaunch" message.
- For plain executables (not .app bundles), macOS 26.x (Tahoe) reportedly
  no longer lists the binary in System Settings → Screen Recording even
  though permission is granted under the hood. This is a platform issue
  we cannot fix; we will document it as a known limitation.

### Microphone

| API | Behavior |
|---|---|
| `AVCaptureDevice.authorizationStatus(for: .audio)` | Returns `.notDetermined`/`.restricted`/`.denied`/`.authorized`. |
| `AVCaptureDevice.requestAccess(for: .audio)` { granted in ... } | Async; triggers prompt if `.notDetermined`. |

### CLI-context concern: does the prompt need a UI thread?
Both prompts come from a separate `tccd` UI process; the requesting
process does not need to be a GUI app. A pure CLI invoked from a
terminal works fine — the prompt appears, the user clicks, the prompt
goes away. The first invocation typically does not race with a still-
booting RunLoop because we explicitly spin a `RunLoop` while waiting
for `requestAccess` callback completion, then exit.

### Recommendation — TCC

**One-shot prompt + relaunch UX**. The `check-permissions` subcommand
prints current state for both permissions. The `start` subcommand:

1. Pre-checks both permissions.
2. If either is `.notDetermined`: triggers the appropriate request,
   prints "Please grant the prompt that appears, then re-run `macrec
   start`." and exits with code 75 (`EX_TEMPFAIL`).
3. If either is `.denied`: prints the System Settings deep link
   (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
   for screen recording;
   `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`
   for mic) and exits with code 77 (`EX_NOPERM`).
4. Only proceeds to record when both states are `.authorized`.

This avoids the chicken-and-egg of `CGPreflightScreenCaptureAccess`,
gives the user a deterministic 2-step UX, and works for plain CLI
binaries.

---

## 7. Configuration / Env-Loading Library

### Options

#### A — Hand-rolled loader (zero dependencies)
~80 lines: parse `KEY=VALUE` lines from each `.env`, build an in-memory
`[String: String]` per source, merge in precedence order, expose a
single `ConfigResolver.value(for:)` API.

#### B — `thebarndog/swift-dotenv`
Most popular Swift `.env` package as of 2025. **Mutates
`ProcessInfo.processInfo.environment`** when `Dotenv.configure()` is
called — which collapses our 4 sources into one and breaks the
documented precedence. Working around that requires using SwiftDotenv
purely as a parser (read its `Dotenv.values` map, do not call
`configure()`), which removes most of its value.

#### C — `swiftpackages/DotEnv`
Same root issue: writes loaded values into the environment.

#### D — `SwiftOnTheServer/SwiftDotEnv`
Older (Swift 4 era), inactive maintenance.

### Recommendation — Config loader

**Option A — hand-rolled**. The 4-source precedence chain mandated by
`CLAUDE.md` plus the no-fallback rule plus the bootstrap of
`~/.tool-agents/<tool>/` (mode `0700`) plus `--overwrite` etc. is project-
specific and not what off-the-shelf `.env` parsers solve. Building it
in-tree gives us:

- Exact control over the precedence merge.
- Trivial unit-testability with synthetic env dictionaries (NFR-10).
- Zero risk of a third-party package mutating `ProcessInfo`.
- Roughly 80 lines of code; no real maintenance burden.

The loader will be a `ConfigResolver` type living in the library target;
the executable target consumes it through dependency injection so tests
can supply a fake one.

---

## 8. Logging

### Options
- **`os.Logger`**: Apple-blessed, integrates with Console.app, persists
  to unified log; awkward for traditional Unix CLIs because output goes
  to the unified log buffer rather than stderr.
- **`apple/swift-log`**: Apache-2.0, 7 levels (`trace`/`debug`/`info`/
  `notice`/`warning`/`error`/`critical`), pluggable `LogHandler`s.
  Includes `StreamLogHandler.standardError` out of the box.
- **Plain `FileHandle.standardError.write(_:)`**: zero-dep, fine for
  the smallest tools but no level filtering, no metadata, no formatter.

### Recommendation — Logging

**`apple/swift-log` with `StreamLogHandler.standardError`** as the
bootstrap:

```
LoggingSystem.bootstrap { label in
    var h = StreamLogHandler.standardError(label: label)
    h.logLevel = .info
    return h
}
```

Map CLI flags:

| Flag | swift-log level |
|---|---|
| `--log-level quiet` | `.warning` |
| `--log-level info` (default) | `.info` |
| `--log-level debug` | `.debug` |

This satisfies NFR-8 (logs to stderr; stdout reserved for future
piped-output support per OQ-5).

---

## 9. Testing Strategy

### Constraints
- `SCStream` and `AVCaptureSession` are notoriously hard to mock — they
  hit real OS resources, have private state, and require TCC consent.
- `test_scripts/` already exists in the conventions for manual scripts.

### Strategy

1. **Protocol-based dependency injection** for every capture or system
   resource. Concretely, define:
   - `protocol SystemAudioSource: AnyObject { var pcmStream:
     AsyncStream<AudioSample> { get } ; func start() async throws ; func stop() async }`
   - `protocol MicrophoneAudioSource: AnyObject { ... }` (same shape)
   - `protocol PermissionGate { func screenRecordingStatus() ->
     PermissionState ; func microphoneStatus() -> PermissionState ; ... }`
   - `protocol Clock { var now: CMTime { get } }`
   - `protocol FileSystem { ... }`
2. Real implementations (`SCKitSystemAudioSource`,
   `AVCaptureMicSource`, `TCCPermissionGate`, `HostClock`,
   `RealFileSystem`) live in the library target.
3. Test target (`MacrecCoreTests`) provides
   - `FixtureSystemAudioSource` that replays a pre-recorded `.caf` of
     synthetic test tones with known PTS sequence.
   - `FixtureMicSource` likewise.
   - `StubPermissionGate(state:)`.
   - `MockClock(virtualTime:)`.
4. Unit tests cover (per NFR-10):
   - Configuration precedence resolution (table-driven).
   - CLI argument parsing (use ArgumentParser's
     `parseAsRoot(_:)` to feed argv arrays).
   - Permission state detection.
   - Output-path validation (`--overwrite` semantics, parent-missing
     errors, FR-15).
   - Aligner: feed two synthetic streams with deliberate drift and
     gaps; assert silence-fill behavior and PTS continuity.
   - Mixer: assert byte-exact output for known input pairs.
5. **E2E tests** live in `test_scripts/` as bash invocations of the
   built binary. CI cannot grant TCC; these are run manually before
   release. Acceptance criteria AC-4 through AC-12 in the refined-
   request file map onto a checklist there.

### Recommendation — Testing

Adopt the protocol-injection pattern above; **XCTest** (default for SPM)
for unit tests; manual `test_scripts/` for E2E. No mocking framework
needed (`Mockingbird`/`Cuckoo` etc. add complexity disproportionate to
the small protocol surface).

---

## 10. Project Layout

NFR-9 mandates a library target. Concrete layout:

```
recording-tool/
├── Package.swift
├── Sources/
│   ├── macrec/                          # executable target (thin)
│   │   ├── main.swift                   # @main RootCommand
│   │   ├── Commands/
│   │   │   ├── StartCommand.swift
│   │   │   ├── ListDevicesCommand.swift
│   │   │   └── CheckPermissionsCommand.swift
│   │   └── CLISupport/
│   │       └── ExitCodes.swift
│   └── MacrecCore/                      # library target (the meat)
│       ├── Capture/
│       │   ├── SystemAudioSource.swift           (protocol)
│       │   ├── SCKitSystemAudioSource.swift      (impl)
│       │   ├── MicrophoneAudioSource.swift       (protocol)
│       │   └── AVCaptureMicSource.swift          (impl)
│       ├── Devices/
│       │   └── AudioDeviceEnumerator.swift       (Core Audio HAL)
│       ├── Pipeline/
│       │   ├── SampleAligner.swift
│       │   ├── FormatConverter.swift
│       │   └── Mixer.swift
│       ├── Encoding/
│       │   ├── Recorder.swift                    (protocol)
│       │   ├── M4ARecorder.swift                 (AVAssetWriter)
│       │   ├── WavRecorder.swift                 (AVAudioFile)
│       │   └── CafRecorder.swift
│       ├── Permissions/
│       │   ├── PermissionGate.swift              (protocol)
│       │   └── TCCPermissionGate.swift           (impl)
│       ├── Config/
│       │   ├── ConfigResolver.swift
│       │   ├── EnvParser.swift
│       │   └── ToolAgentsBootstrap.swift         (~/.tool-agents/macrec/)
│       ├── Logging/
│       │   └── LoggerFactory.swift               (swift-log bootstrap)
│       └── RecordingSession.swift                (orchestrator)
├── Tests/
│   └── MacrecCoreTests/
│       ├── ConfigResolverTests.swift
│       ├── EnvParserTests.swift
│       ├── ArgumentParsingTests.swift
│       ├── SampleAlignerTests.swift
│       ├── MixerTests.swift
│       ├── OutputPathValidationTests.swift
│       ├── PermissionGateTests.swift
│       └── Fixtures/
│           ├── FixtureSystemAudioSource.swift
│           ├── FixtureMicSource.swift
│           └── StubPermissionGate.swift
├── test_scripts/                        # manual / E2E
│   ├── 01-acceptance-30s.sh
│   ├── 02-layout-split.sh
│   ├── 03-layout-stereo-split.sh
│   ├── 04-sigint-finalization.sh
│   └── 05-60min-drift-test.sh
├── docs/
│   ├── design/
│   ├── reference/
│   └── tools/
│       └── macrec.md
├── prompts/
└── Issues - Pending Items.md
```

`Package.swift` skeleton:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macrec",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macrec", targets: ["macrec"]),
        .library(name: "MacrecCore", targets: ["MacrecCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser",
                 from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log",
                 from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "macrec",
            dependencies: [
                "MacrecCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "MacrecCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "MacrecCoreTests",
            dependencies: ["MacrecCore"],
            resources: [.copy("Fixtures/test-tone-48k-stereo.caf")]
        ),
    ]
)
```

---

## Comparison Matrix (Cross-Topic Roll-up)

| Topic | Recommended | Rejected primary alternative | Tipping factor |
|---|---|---|---|
| System audio | SCStream | CoreAudio process taps | macOS-14.0 floor (vs 14.4); doc maturity; spec already names SCStream |
| Microphone | AVCaptureSession | AVAudioEngine | Uniform `CMSampleBuffer`; settable sync clock; reliable Bluetooth |
| Mixing | Manual buffer sum | AVAudioEngine mixer | Both inputs already canonicalised → mixer adds glue with no payoff |
| AAC encoder | AVAssetWriter | AVAudioFile | AVAudioFile ignores `AVEncoderBitRateKey` for compressed |
| PCM encoder | AVAudioFile | AVAssetWriter | Smaller, no mediaType ceremony |
| Sync | host-clock everywhere | offset-then-retime | `synchronizationClock` is settable on macOS 12+ |
| Parser | swift-argument-parser | hand-rolled | Standard, type-safe, async support |
| Permission UX | check → prompt → exit-and-relaunch | poll-in-loop | `CGPreflightScreenCaptureAccess` returns stale value in same proc |
| Config | hand-rolled `.env` | swift-dotenv | Off-the-shelf parsers mutate `ProcessInfo`, breaking precedence |
| Logging | swift-log + stderr handler | os.Logger | Output destination control; level mapping fits CLI conventions |
| Tests | protocol DI + XCTest | mocking framework | Small surface; no extra dep needed |

---

## Recommendation Summary

Build on **macOS 14.0+** (OQ-1 default). Use **SCStream** for system
audio with a 1-fps screen-discard pattern, **AVCaptureSession** for the
mic with `synchronizationClock` pinned to the host clock, and a
**Float32 / 48 kHz / stereo** internal canonical format. **Manually
sum** for `mixed` layout, write via **AVAssetWriter** for AAC m4a/caf
and **AVAudioFile** for PCM wav. Use **swift-argument-parser** for the
CLI and **swift-log** for stderr-bound levelled logging. Roll the
`.env` parser by hand (~80 lines) so the 4-source precedence chain is
honored. Test via protocol-injected fakes in **XCTest**; keep E2E in
`test_scripts/`. Lay the code out as **executable target +
`MacrecCore` library target + test target** so the library can back a
future menu-bar UI without refactor.

This approach satisfies every functional and non-functional requirement
in the refined spec, adds **only two third-party dependencies** (both
Apple-maintained), and keeps the door open to swap to **CoreAudio
process taps** in a future v2 if SCStream stability or per-process
filtering ever require it.

---

## Technical Research Guidance

The investigation surfaced enough detail to start planning, but **two
implementation areas warrant a focused, deeper-dive technical research
pass before code is written** because the available references are
either terse (Apple), scattered (community blogs), or the relevant
edge-case behavior was not directly verified in this round.

**Research needed**: Yes

### Topic 1 — SCStream audio-only configuration and long-run stability

- **Why**: SCStream has no first-class "audio only" mode. The community
  workaround of low-fps + tiny frame size + discarding video buffers is
  ubiquitous but the exact `SCStreamConfiguration` knob settings that
  yield the lowest CPU/memory overhead AND maximum audio reliability for
  60-minute sessions (NFR-3, NFR-5, AC-11) need to be locked down before
  implementation. The investigation also surfaced reports of
  `EXC_BAD_ACCESS` and silent-stop bugs that may or may not affect
  native Swift on macOS 14.0+.
- **Focus**:
  - Optimal values for `minimumFrameInterval`, `width`/`height`,
    `queueDepth`, `pixelFormat`, `showsCursor` for an audio-only
    workload.
  - Best `SCContentFilter` shape — display-based vs. excludingApplications-
    based — for the "entire system submix" use case, including how the
    filter behaves when display configuration changes mid-recording.
  - Empirical long-run behavior on macOS 14.0 / 14.6 / 15.x: does the
    silent-stop bug manifest in the audio-only configuration? Are there
    confirmed mitigations?
  - Behavior of `excludesCurrentProcessAudio = true` interaction with
    other AVFoundation activity in the same process (since we ALSO run
    AVCaptureSession for the mic).
  - First-buffer latency: how long after `startCapture()` before the
    first audio buffer arrives? This bounds how much pre-roll we must
    buffer to avoid clipping the start.
- **Depth**: **Moderate** — code-level reading of `SCStream` headers,
  the AudioCap and AudioTee projects, and recent dev forum threads;
  ideally a small spike to measure actual long-run behavior. Not
  exhaustive.
- **Relevance**: directly drives the `SCKitSystemAudioSource`
  implementation in `MacrecCore/Capture/`.

### Topic 2 — AVAssetWriter AAC priming, sample alignment, and live finalization

- **Why**: The investigation surfaced AAC-encoder priming behavior
  (2112 frame silence pad), the `kCMSampleBufferAttachmentKey_TrimDurationAtStart`
  attachment, and the requirement to call `assetWriter.startSession(at:)`
  with a sourceTime that matches the first buffer's PTS. The interaction
  of these with our `synchronizationClock = CMClockGetHostTimeClock()`
  setup AND with our sample aligner's silence-fill behavior is subtle
  and easy to get wrong. Failures here manifest as AC-7 / AC-12
  failures (truncated atoms, drift accumulation).
- **Focus**:
  - Exact recipe for `assetWriter.startSession(atSourceTime:)`,
    `endSession(atSourceTime:)`, `markAsFinished()`,
    `finishWriting(completionHandler:)` ordering for guaranteed
    playable output on SIGINT (AC-7).
  - How to author the first sample buffer of an AAC m4a so QuickTime
    plays it from t=0 without the priming pad pollution.
  - Handling of `requiresFrameReassembly`/audio-buffer-rate mismatches
    when feeding `AVAssetWriterInput.append(_:)` from our aligner.
  - Whether `AVAssetWriter` tolerates silence-fill buffers that are
    synthesized in-process vs. requiring genuine capture buffers.
- **Depth**: **Moderate** — verify against Apple sample code,
  Nonstrict's blog, NextLevel's `CMSampleBuffer` extensions, and a
  small spike that records, SIGINTs at second 5, and re-opens the file.
- **Relevance**: drives `MacrecCore/Encoding/M4ARecorder.swift` and
  `MacrecCore/RecordingSession.swift`.

Topics that **do NOT** need further research:
- Microphone capture (AVCaptureSession) — well-understood, plenty of
  references.
- swift-argument-parser usage — first-party Apple framework, official
  docs are sufficient.
- `CGRequestScreenCaptureAccess` semantics — investigation already
  surfaced the relaunch-after-prompt UX answer.
- swift-log bootstrap — minimal API.
- `.env` parser — we own the shape; nothing to research.
- Project layout — standard SPM pattern.

---

## Implementation Considerations

- **First commit checklist**:
  1. `swift package init --type executable`, then split into the
     executable + library + test layout shown above.
  2. Add the two SPM deps; verify `swift build` succeeds on macOS 14.
  3. Implement `ToolAgentsBootstrap` first (creates
     `~/.tool-agents/macrec/` at `0700`, seeds `.env` at `0600`) so
     subsequent runs of any subcommand satisfy AC-10.
  4. Implement `ConfigResolver` next; unit-test the precedence
     thoroughly — AC-9 hangs on this.
  5. Implement `CheckPermissionsCommand` and `ListDevicesCommand`
     before tackling capture — they are mostly read-only and exercise
     the TCC and Core Audio HAL bindings that the capture path will
     also use.
  6. Stand up `RecordingSession` with the protocol-injected fake
     sources first; only then drop in the real SCStream and AVCapture
     implementations.
- **Pitfalls to watch**:
  - **AAC encoder priming silence**: do not recreate
    `AVAudioConverter` per buffer. One per source per session.
  - **CMSampleBuffer ownership and CFRetain semantics**: store retained
    copies in ring buffers, not raw pointers.
  - **TCC code-signing instability**: ad-hoc-signed dev builds re-prompt
    on every rebuild. Document this for the developer experience; no
    runtime fix.
  - **SIGINT handling**: install signal handlers that *post* to a
    `DispatchSourceSignal` rather than do work in the signal handler
    itself; finalize the writer on a normal queue.
  - **Don't over-buffer**: keep `queueDepth` and ring buffers small
    (~200 ms) — NFR-5 caps memory at 250 MB and we are nowhere near
    that, but more buffering = more latency on stop.
- **First small spike** (suggested, not required): a 50-line program
  that opens an SCStream in audio-only configuration and dumps PTS
  values for 60 s. Confirms the fps/queue knobs and gives us a baseline
  for the aligner.
- **Code-signing for AC-2 testing**: developers running this locally
  will need to grant the prompt at least once per ad-hoc-signed build
  unless they sign with a Developer ID (out of scope for v1 per spec).

---

## Consolidated SPM Dependencies

| # | Package | Version | License | Why we need it |
|---|---|---|---|---|
| 1 | `apple/swift-argument-parser` | `from: "1.5.0"` | Apache-2.0 | CLI subcommands, flags, help generation. Standard Apple-maintained library. |
| 2 | `apple/swift-log` | `from: "1.5.0"` | Apache-2.0 | Levelled logging to stderr. Maps `--log-level {quiet|info|debug}` cleanly. |

That's it. Everything else uses first-party Apple frameworks
(`ScreenCaptureKit`, `AVFoundation`, `CoreAudio`, `AudioToolbox`,
`CoreMedia`, `Foundation`).

---

## Risks & Open Issues

Items the refined-request spec did NOT cover that surfaced during this
investigation:

1. **macOS 26.x (Tahoe) UI listing for plain executables.** Plain CLI
   binaries reportedly no longer appear under System Settings → Screen
   Recording even after permission is granted. We should document this
   as a known limitation and recommend users wrap the CLI in a `.app`
   bundle if they need to manage the permission via the Settings UI. No
   acceptance criterion currently fails because of this — recording
   itself still works — but UX may be confusing.

2. **TCC ad-hoc-signing instability for developers.** Every `swift
   build` produces a different code-directory hash, which can
   invalidate previously-granted TCC permissions. Anyone iterating on
   the tool will re-grant the prompt repeatedly. This is a developer-
   experience footgun, not a user-facing one — consider documenting
   `tccutil reset ScreenCapture` and `tccutil reset Microphone` in
   `docs/tools/macrec.md` troubleshooting section.

3. **Bluetooth output devices and SCStream submix.** Assumption A-4 in
   the spec asserts that the audio output route does not affect
   SCStream's ability to capture the system submix. Community reports
   confirm this for nearly all configurations, but at least one edge
   case has been reported with certain Bluetooth headsets where the
   submix is muted while the headset is connected. This is a platform
   limitation, not a tool defect, but the spec should explicitly
   document it as a known issue (it does — assumption A-4 acknowledges
   this).

4. **Silent stop bug.** `SCStream` and Apple's built-in screen
   recording have been reported to silently stop after 10–15 minutes
   in some configurations. We have not confirmed whether this affects
   audio-only SCStream usage. **NFR-3 + AC-11 require 60-minute
   recordings**, so this is a real risk. **Mitigation**: implement
   continuous heartbeat logging (per OQ-9, RMS every 10 s at debug
   level) so a silent stop is detectable; consider auto-restart of the
   SCStream on a timer if Topic 1 research confirms the bug exists in
   our configuration.

5. **Process-tap level attenuation on multi-output devices.** Reported
   by AudioCap users — this affects the alternative path (Option B in
   §1) we are NOT taking, so it is informational only. Re-evaluate if
   we ever switch.

6. **No CI for E2E.** TCC cannot be granted in headless CI, so
   AC-4..AC-12 must be manual. This is acknowledged in NFR-10. We
   should script the manual procedure in `test_scripts/` so it is at
   least repeatable.

7. **Unspecified output device for "system audio".** When the user
   has multiple output devices configured (built-in + AirPods +
   Multi-Output Device), what does "the system submix" mean? SCStream
   captures the *active default output route*'s submix. If the user
   changes the output mid-recording, behavior is undefined. The spec
   should clarify; for v1 we will document "captures the submix of the
   default output device at start time; changing output devices during
   recording is unsupported."

8. **Encoding bit-rate range validation.** FR-8 says
   "overridable with `--bitrate <kbps>`" but does not specify allowed
   range. AAC-LC sensible range is roughly 64–320 kbps; we should
   validate and reject values outside this in argument parsing.

---

## References

| # | Source | URL | What was learned |
|---|---|---|---|
| 1 | Apple Developer — `SCStreamConfiguration.capturesAudio` | https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio | Setting required to enable SCStream audio output. |
| 2 | Apple Developer Forums — "Is it possible to get only audio from ScreenCaptureKit?" | https://developer.apple.com/forums/thread/718279 | No native audio-only mode; community workaround uses low fps + tiny frame size. |
| 3 | Apple Developer — Capturing system audio with Core Audio taps | https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps | Official ProcessTap docs (terse). |
| 4 | insidegui/AudioCap | https://github.com/insidegui/AudioCap | Reference implementation of `AudioHardwareCreateProcessTap` for macOS 14.4+. |
| 5 | makeusabrew/audiotee | https://github.com/makeusabrew/audiotee | Swift CLI using process taps; concrete model for our v2 path. |
| 6 | Strongly Typed — AudioTee write-up | https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos | Practitioner notes on process taps and TCC probing. |
| 7 | Nonstrict — Recording to disk with ScreenCaptureKit | https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit/ | Canonical write-up on `SCStream` + `AVAssetWriter` + `CMClock.hostTimeClock`. |
| 8 | Nonstrict — Handling audio capture gaps on macOS | https://nonstrict.eu/blog/2024/handling-audio-capture-gaps-on-macos/ | `nextExpectedAudioTime` pattern for our SampleAligner. |
| 9 | NextLevel — `NextLevel+CMSampleBuffer.swift` | https://github.com/NextLevel/NextLevel/blob/main/Sources/NextLevel%2BCMSampleBuffer.swift | Retiming CMSampleBuffer utilities. |
| 10 | apple/swift-argument-parser | https://github.com/apple/swift-argument-parser | CLI parser; subcommand docs; latest 1.5.0. |
| 11 | swift-argument-parser Documentation | https://apple.github.io/swift-argument-parser/documentation/argumentparser/ | API reference. |
| 12 | apple/swift-log | https://github.com/apple/swift-log | Levelled logging primitives. |
| 13 | Swift.org — Log Levels | https://www.swift.org/documentation/server/guides/libraries/log-levels.html | Recommended use of trace/debug/info/notice/warning. |
| 14 | NSHipster — Swift Logging | https://nshipster.com/swift-log/ | swift-log idioms and stderr handler. |
| 15 | Apple Developer Forums — `CGRequestScreenCaptureAccess` semantics | https://developer.apple.com/forums/thread/732726 | Same-process stale-state caveat → relaunch UX. |
| 16 | Apple Developer Forums — Screen recording TCC overrides | https://developer.apple.com/forums/thread/760483 | macOS 26.x (Tahoe) plain-binary listing regression. |
| 17 | karaggeorge/mac-screen-capture-permissions | https://github.com/karaggeorge/mac-screen-capture-permissions | Reference for preflight + request flow. |
| 18 | karaggeorge/macos-audio-devices | https://github.com/karaggeorge/macos-audio-devices | Reference for Core Audio HAL device enumeration. |
| 19 | Apple Developer — `AVAudioConverter` | https://developer.apple.com/documentation/avfaudio/avaudioconverter | Float32 → AAC conversion path. |
| 20 | Apple Developer Forums — AVAudioConverter conversion | https://developer.apple.com/forums/thread/67106 | Long-lived converter pitfall (2112 priming frames). |
| 21 | Apple Developer Forums — bit rate with AVAudioFile | https://developer.apple.com/forums/thread/112203 | Justifies AVAssetWriter for compressed encoding. |
| 22 | thebarndog/swift-dotenv | https://github.com/thebarndog/swift-dotenv | Surveyed; rejected because it mutates `ProcessInfo.environment`. |
| 23 | Apple Developer Forums — observe `AVCaptureDevice.DiscoverySession` | https://developer.apple.com/forums/thread/766106 | Device-change monitoring on macOS. |
| 24 | Masilotti — Better unit testing with Swift | https://masilotti.com/better-swift-unit-testing/ | Protocol-DI pattern for system frameworks. |
| 25 | Apple Developer — Swift Package Manager `Package` | https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html | Library + executable target layout. |

---

## Original Request

The user's original request and refined spec are preserved at:

`/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/docs/design/refined-request-recording-tool.md`

Key constraints traced into this investigation:
- Swift only (Exception 001).
- macOS 13.0 floor, 14.0+ recommended.
- ScreenCaptureKit + AVFoundation locked for capture.
- ±20 ms drift over 60 minutes (NFR-4).
- 4-source config precedence chain with no fallbacks.
- Library target mandatory for future menu-bar UI reuse.

---

**Research needed: Yes** (two focused topics flagged in the Technical
Research Guidance section above; both are moderate-depth.)
