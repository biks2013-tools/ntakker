# Project Design — `macrec` macOS Dual-Source Audio Recording Tool

> Phase 5 (Designer) deliverable. Authoritative technical design consumed by
> Phase 6 (parallel Coders), Phase 7 (Code Reviewer), Phase 8 (Dependency
> Validator), Phase 9 (Test Builders), Phase 10 (Integration Verifier).
>
> **Source documents (locked inputs):**
> 1. `docs/design/refined-request-recording-tool.md` — FR-1..FR-16, NFR-1..NFR-10, AC-1..AC-20, OQ-1..OQ-10 (OQ-3 overridden 2026-04-26)
> 2. `docs/design/project-functions.md` — FR-17..FR-29 (FR-25..FR-29 added 2026-04-26 per OQ-3 override)
> 3. `docs/design/plan-001-recording-tool.md` — 12-phase plan, parallelization map, risk register (Phase K and risk register expanded 2026-04-26)
> 4. `docs/reference/investigation-recording-tool.md` — architectural sketch
> 5. `docs/research/scstream-audio-only.md` — SCStream knobs and watchdog
> 6. `docs/research/avassetwriter-aac.md` — AVAssetWriter recipe and SIGINT-safe finalization
> 7. `CLAUDE.md` — project conventions
>
> **Locked stack — DO NOT re-litigate:** Swift 5.9, macOS 14.0+, universal
> binary, foreground (default) + detached background mode (`--detach` +
> `stop` subcommand; OQ-3 override 2026-04-26 — see §14), internal
> pipeline format Float32/48 kHz/stereo, SCStream for system audio,
> AVCaptureSession for mic, AVAssetWriter for `.m4a`, AVAudioFile for
> `.wav`/`.caf`, swift-argument-parser 1.5.x and swift-log 1.5.x as the
> only third-party SPM deps.

---

## Section 1 — System Architecture

### 1.1 Component Diagram

```
                                  macrec process
   ┌──────────────────────────────────────────────────────────────────────────┐
   │                                                                          │
   │   main.swift  ──►  ToolAgentsBootstrap  ──►  LoggerFactory               │
   │      │                 (FR-13, AC-10)              │                     │
   │      │                                             │                     │
   │      ▼                                             ▼                     │
   │   RootCommand (swift-argument-parser AsyncParsableCommand)               │
   │   ├── StartCommand            ──┐                                        │
   │   ├── ListDevicesCommand      ──┤   each subcommand  ──►  MacrecCore     │
   │   └── CheckPermissionsCommand ──┘                                        │
   │                                                                          │
   │ ── MacrecCore library ─────────────────────────────────────────────────  │
   │                                                                          │
   │   Config:                  Permissions:                Devices:          │
   │   ┌──────────────────┐    ┌─────────────────────┐    ┌────────────────┐  │
   │   │ DotEnvParser     │    │ PermissionGate      │    │ AudioDevice-   │  │
   │   │ ConfigResolver   │    │  ├─ ScreenRecording │    │  Enumerator    │  │
   │   │ RecordingOptions │    │  └─ Microphone      │    │  (CoreAudio    │  │
   │   └────────┬─────────┘    └──────────┬──────────┘    │   HAL)         │  │
   │            │                         │               └────────┬───────┘  │
   │            │                         │                        │          │
   │            └─────────────┬───────────┴────────────────────────┘          │
   │                          ▼                                               │
   │               ┌────────────────────────┐                                 │
   │               │  RecordingSession      │ ◄── SignalHandler (SIGINT/TERM) │
   │               │  (orchestrator)        │ ◄── max-duration timer          │
   │               └─┬──────────┬───────────┘                                 │
   │                 │          │                                             │
   │ Capture:        ▼          ▼                                             │
   │  ┌──────────────────┐  ┌───────────────────┐                             │
   │  │ SystemAudioSource│  │ MicrophoneSource  │   (protocols)               │
   │  │  ├─ SCKitSystem- │  │  ├─ AVMicrophone- │                             │
   │  │  │  AudioSource  │  │  │  Source        │                             │
   │  │  └─ FakeAudio-   │  │  └─ FakeAudio-    │   (test fakes)              │
   │  │     Source       │  │     Source        │                             │
   │  └─────────┬────────┘  └─────────┬─────────┘                             │
   │            │                     │                                       │
   │            ▼                     ▼                                       │
   │   ┌────────────────────────────────────────┐                             │
   │   │  AVAudioConverter (one per source,     │                             │
   │   │  long-lived) → Float32/48 kHz/stereo   │                             │
   │   └─────────┬───────────────────────────┬──┘                             │
   │             │                           │                                │
   │             ▼                           ▼                                │
   │   Aligning:                                                              │
   │   ┌─────────────────────────────────────────┐    ┌──────────────────┐    │
   │   │  HostClockAligner                       │ ◄──┤ SilenceBuffer-   │    │
   │   │  (per-source ring buffer; nextExpected- │    │ Factory          │    │
   │   │  AudioTime; pair drain in lockstep)     │    └──────────────────┘    │
   │   └────────────────────┬────────────────────┘                            │
   │                        ▼                                                 │
   │   Mixing:                                                                │
   │   ┌─────────────────────────────────────────┐                            │
   │   │  layout=mixed         → BufferSummer    │                            │
   │   │  layout=stereo-split  → channel pin     │                            │
   │   │  layout=split         → passthrough x2  │                            │
   │   └────────────────────┬────────────────────┘                            │
   │                        ▼                                                 │
   │   Encoding:                                                              │
   │   ┌─────────────────────────────────────────┐                            │
   │   │  Recorder (protocol)                    │                            │
   │   │   ├─ M4ARecorder  (AVAssetWriter, AAC)  │                            │
   │   │   ├─ WAVRecorder  (AVAudioFile, PCM)    │                            │
   │   │   └─ CAFRecorder  (AVAudioFile, PCM)    │                            │
   │   └────────────────────┬────────────────────┘                            │
   │                        ▼                                                 │
   │              on-disk output file(s)                                      │
   │                                                                          │
   │   Cross-cutting:                                                         │
   │     - MacrecError (typed; LocalizedError)                                │
   │     - LoggerFactory + Logger instances per subsystem (swift-log)         │
   └──────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Data-Flow Diagram (CMSampleBuffer journey)

```
   ScreenCaptureKit                       AVCaptureSession
   (replayd XPC)                          (CoreAudio HAL → mic)
   PTS = host clock                       PTS = host clock (forced via
   Format = Float32 / 48k / stereo         synchronizationClock)
        │                                   │   Format = device-native
        │                                   │   (e.g. 24 kHz / mono Int16
        │                                   │   for AirPods)
        ▼                                   ▼
   stream(_:didOutputSampleBuffer:of:)   captureOutput(_:didOutput:from:
   in SCKitSystemAudioSource               connection:) in AVMicrophoneSource
   (queue: macrec.capture.system)          (queue: macrec.capture.mic)
        │  emits CaptureBuffer envelope    │  emits CaptureBuffer envelope
        │  (.system source tag)            │  (.microphone source tag)
        ▼                                   ▼
   ┌─────────────────────────────┐  ┌─────────────────────────────┐
   │ AVAudioConverter (system)   │  │ AVAudioConverter (mic)      │
   │ (no-op resample if already  │  │ Resample to 48 kHz, upmix   │
   │  Float32/48 kHz/stereo,     │  │ to stereo, convert to       │
   │  but instance still owned)  │  │ Float32 non-interleaved     │
   └──────────────┬──────────────┘  └──────────────┬──────────────┘
                  │                                │
                  ▼                                ▼
         (each side enqueues its CaptureBuffer onto its
          per-source ring buffer inside the aligner;
          capture callback returns immediately — no blocking)
                  │                                │
                  └────────────┬───────────────────┘
                               ▼
                  ┌──────────────────────────────┐
                  │ HostClockAligner             │
                  │ (queue: macrec.aligner)      │
                  │  - Compute gap = pts -       │
                  │    nextExpectedAudioTime[s]  │
                  │  - If gap > 1 sample, ask    │
                  │    SilenceBufferFactory for  │
                  │    a fill buffer             │
                  │  - Drain pairs in lockstep   │
                  │  - Emits AlignedFrame{s, m}  │
                  └──────────────┬───────────────┘
                                 │ (mixed / stereo-split)
        ┌────────────────────────┼─────────────────────────┐
        │                        │                         │
        ▼ split                  ▼ stereo-split            ▼ mixed
   ┌─────────────┐       ┌──────────────────┐       ┌──────────────────┐
   │ pass mic    │       │ Pin mic → L,     │       │ BufferSummer:    │
   │ frame to    │       │ system → R       │       │ Float32 per-     │
   │ mic writer  │       │ (flip per        │       │ sample sum,      │
   │ pass system │       │  --mic-channel)  │       │ clamp [-1,+1]    │
   │ frame to    │       │ → single buffer  │       │ → single buffer  │
   │ system wtr  │       └────────┬─────────┘       └────────┬─────────┘
   └──┬───────┬──┘                │                          │
      │       │                   │                          │
      ▼       ▼                   ▼                          ▼
   ┌──────┐ ┌──────┐         ┌──────────┐               ┌──────────┐
   │ Rec. │ │ Rec. │         │ Recorder │               │ Recorder │
   │ mic  │ │ sys  │         └────┬─────┘               └────┬─────┘
   └──┬───┘ └──┬───┘              │                          │
      ▼        ▼                  ▼                          ▼
   queue: macrec.recorder.{mic|system|main}   (one serial DispatchQueue per
                                                Recorder; honors
                                                isReadyForMoreMediaData)
        │
        ▼
   AVAssetWriterInput.append(_:)  /  AVAudioFile.write(from:)
        │
        ▼
   <output>.m4a / .wav / .caf  (or split: <basename>.{mic,system}.<ext>)
```

### 1.3 Threading Model

| Queue label                       | Type              | QoS               | Owned by                         | Purpose                                                           |
|-----------------------------------|-------------------|-------------------|----------------------------------|-------------------------------------------------------------------|
| `macrec.capture.system`           | serial Dispatch   | `.userInteractive`| `SCKitSystemAudioSource`         | Receives `SCStream` audio buffers; drops `.screen` buffers        |
| `macrec.capture.system.video`     | serial Dispatch   | `.utility`        | `SCKitSystemAudioSource`         | Receives & discards `.screen` SCStream output (kept tiny)         |
| `macrec.capture.mic`              | serial Dispatch   | `.userInteractive`| `AVMicrophoneSource`             | `AVCaptureAudioDataOutput` delegate queue                         |
| `macrec.aligner`                  | serial Dispatch   | `.userInitiated`  | `HostClockAligner`               | Drains per-source ring buffers in lockstep                        |
| `macrec.recorder.main`            | serial Dispatch   | `.userInitiated`  | M4A/WAV/CAF Recorder (mixed/SS)  | Wraps every `append`, `markAsFinished`, `endSession`              |
| `macrec.recorder.mic`             | serial Dispatch   | `.userInitiated`  | Recorder for split.mic           | As above (split layout only)                                      |
| `macrec.recorder.system`          | serial Dispatch   | `.userInitiated`  | Recorder for split.system        | As above (split layout only)                                      |
| `macrec.signals`                  | serial Dispatch   | `.userInteractive`| `SignalHandler`                  | `DispatchSourceSignal` for SIGINT/SIGTERM                         |
| `macrec.session`                  | serial Dispatch   | `.userInitiated`  | `RecordingSession`               | Orchestrator state machine; idempotent `stop()` guard             |
| `macrec.watchdog.scstream`        | Swift Task        | `.utility`        | `SCKitSystemAudioSource`         | Polls `lastBufferArrival`; restarts SCStream on stall (FR-19)     |
| `macrec.heartbeat`                | repeating Timer   | `.utility`        | `RecordingSession`               | RMS heartbeat every 10 s when log level is `debug` (FR-23)        |

**Concurrency rules:**
- Capture-source delegate methods MUST return in O(1) audio-pipeline cost — they perform conversion via the long-lived `AVAudioConverter` and enqueue onto the aligner's ring buffer; they MUST NOT call `Recorder.append` directly.
- The aligner queue is the only queue that calls `Recorder.append`. Recorder implementations re-dispatch onto their own writer queue.
- `RecordingSession.stop()` is the only method that may be invoked from any queue (signal handler, max-duration timer, programmatic). It hops to `macrec.session` and drains in serial order.
- All `CMSampleBuffer` references are passed by value (`CMSampleBuffer` is a Core Foundation type with retain semantics); never store raw pointers from the dataBuffer outside the lifetime of the enclosing buffer.
- All `Sendable` violations (e.g. closures capturing class-bound state across queue hops) are explicitly annotated `@unchecked Sendable` with a comment naming the protecting queue.

---

## Section 2 — Module Interfaces

This section gives the exact Swift surface the Phase-6 coders will type. All
file paths are absolute under `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/`.

### 2.1 `MacrecError`

**File:** `Sources/MacrecCore/Errors/MacrecError.swift`

```swift
import Foundation

public enum MacrecError: Error, LocalizedError, CustomStringConvertible {
    // Configuration
    case missingRequiredConfig(key: String, sourcesChecked: [String])
    case invalidConfigValue(key: String, value: String, expected: String)
    case dotEnvParseError(path: String, line: Int, reason: String)

    // Output path
    case outputParentMissing(URL)
    case outputAlreadyExists(URL)

    // Permissions
    case screenRecordingPermissionDenied
    case screenRecordingPermissionNotDetermined
    case microphonePermissionDenied
    case microphonePermissionNotDetermined
    case microphonePermissionRestricted

    // Devices
    case noInputDevicesAvailable
    case micDeviceNotFound(String)

    // Capture
    case scStreamFailedToStart(underlying: Error)
    case scStreamSilentStopExceeded(restartCount: Int)
    case avCaptureFailedToStart(underlying: Error)

    // Encoding
    case writerFailedToStart(underlying: Error)
    case writerFinalizationTimeout(URL)
    case finishWritingFailed(underlying: Error)

    // Detach mode and `stop` subcommand (added 2026-04-26 per FR-25..FR-29)
    case noActiveRecording(pidFilePath: String)
    case staleRecording(pid: Int32, pidFilePath: String)
    case stopTimeout(pid: Int32, seconds: Int)
    case alreadyRecording(pid: Int32, pidFilePath: String)
    case pidFileWriteFailed(path: String, reason: String)

    // Generic
    case ioError(String)
    case unknown(String)

    public var exitCode: Int32 {
        switch self {
        case .missingRequiredConfig, .micDeviceNotFound,
             .alreadyRecording, .noActiveRecording:                     return 78  // EX_CONFIG
        case .invalidConfigValue, .dotEnvParseError:                    return 64  // EX_USAGE
        case .outputParentMissing, .outputAlreadyExists,
             .pidFileWriteFailed:                                       return 66  // EX_NOINPUT
        case .screenRecordingPermissionNotDetermined,
             .microphonePermissionNotDetermined,
             .staleRecording:                                           return 75  // EX_TEMPFAIL
        case .screenRecordingPermissionDenied,
             .microphonePermissionDenied,
             .microphonePermissionRestricted:                           return 77  // EX_NOPERM
        case .noInputDevicesAvailable,
             .scStreamFailedToStart,
             .scStreamSilentStopExceeded,
             .avCaptureFailedToStart,
             .writerFailedToStart,
             .stopTimeout:                                              return 70  // EX_SOFTWARE
        case .writerFinalizationTimeout:                                return 2
        case .finishWritingFailed, .ioError, .unknown:                  return 1
        }
    }

    /// Short, single-line stderr summary. Must NOT contain audio samples,
    /// device serial numbers, or any user PII (NFR-7).
    public var description: String { /* ... locked strings, see below ... */ }

    /// Multi-line user-facing remediation guidance.
    public var remediation: String { /* ... locked strings, see below ... */ }

    public var errorDescription: String? { description }
}
```

**Locked stderr strings (Phase 9 will assert these verbatim):**

| Case                                          | `description`                                                                                       | `remediation` (one-liner)                                                                                                       |
|-----------------------------------------------|----------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| `missingRequiredConfig(key, sourcesChecked)`  | `"missing required config: <key> (checked: <sourcesChecked.joined(\", \")>)"`                       | `"Set --<flag> on the command line, or define <KEY> in ./.env, ~/.tool-agents/macrec/.env, or your shell environment."`         |
| `invalidConfigValue(key, value, expected)`    | `"invalid value for <key>: '<value>' (expected: <expected>)"`                                       | `"See 'macrec start --help' for the accepted values."`                                                                          |
| `dotEnvParseError(path, line, reason)`        | `"failed to parse .env at <path>:<line>: <reason>"`                                                 | `"Fix the syntax in <path> (KEY=VALUE per line; # for comments; quoted values supported)."`                                     |
| `outputParentMissing(url)`                    | `"output parent directory does not exist: <url.deletingLastPathComponent().path>"`                  | `"Create the parent directory (e.g. mkdir -p) before running macrec start."`                                                    |
| `outputAlreadyExists(url)`                    | `"output file already exists: <url.path>"`                                                          | `"Pass --overwrite to replace it, or choose a different --output path."`                                                        |
| `screenRecordingPermissionDenied`             | `"Screen Recording permission denied"`                                                              | `"Open System Settings > Privacy & Security > Screen Recording and enable macrec, then re-run."`                                |
| `screenRecordingPermissionNotDetermined`      | `"Screen Recording permission not yet granted; system prompt has been triggered"`                   | `"Approve the prompt that just appeared, then re-run macrec start. (Same-process state cannot be re-read; relaunch is required.)"` |
| `microphonePermissionDenied`                  | `"Microphone permission denied"`                                                                    | `"Open System Settings > Privacy & Security > Microphone and enable macrec, then re-run."`                                      |
| `microphonePermissionNotDetermined`           | `"Microphone permission not yet granted; system prompt has been triggered"`                         | `"Approve the prompt that just appeared, then re-run macrec start."`                                                            |
| `microphonePermissionRestricted`              | `"Microphone access is restricted by an MDM profile or parental control"`                           | `"Contact your administrator; the tool cannot record audio under this restriction."`                                            |
| `noInputDevicesAvailable`                     | `"no input audio devices found on this system"`                                                     | `"Connect a microphone or enable the built-in microphone in System Settings > Sound."`                                          |
| `micDeviceNotFound(identifier)`               | `"microphone device not found: '<identifier>'"`                                                     | `"Run 'macrec list-devices' to see the available UIDs and names."`                                                              |
| `scStreamFailedToStart(underlying)`           | `"system audio capture failed to start: <underlying.localizedDescription>"`                         | `"Confirm Screen Recording permission is granted; try 'tccutil reset ScreenCapture' and re-grant."`                             |
| `scStreamSilentStopExceeded(restartCount)`    | `"system audio capture silently stopped <restartCount> times in 60s; aborting"`                     | `"Restart the Mac, or rerun the recording. If the problem persists, please file an issue with the debug log."`                  |
| `avCaptureFailedToStart(underlying)`          | `"microphone capture failed to start: <underlying.localizedDescription>"`                           | `"Confirm Microphone permission and that the selected device is available (see 'macrec list-devices')."`                        |
| `writerFailedToStart(underlying)`             | `"output writer failed to initialize: <underlying.localizedDescription>"`                           | `"Verify the output path is writable and the parent directory exists."`                                                         |
| `writerFinalizationTimeout(url)`              | `"finishWriting timed out after 30s; partial output at <url.path>"`                                 | `"The file may still be playable in VLC/ffmpeg thanks to fragmentation; re-run with shorter recordings if this recurs."`        |
| `finishWritingFailed(underlying)`             | `"writer finalization failed: <underlying.localizedDescription>"`                                   | `"The output file is likely incomplete. Re-run the recording."`                                                                 |
| `ioError(msg)`                                | `"I/O error: <msg>"`                                                                                | `"Check disk space and write permissions on the output directory."`                                                             |
| `unknown(msg)`                                | `"unexpected error: <msg>"`                                                                         | `"Re-run with --log-level debug and report the log to the project maintainer."`                                                 |
| `noActiveRecording(pidFilePath)`              | `"No active macrec recording found (PID file at <pidFilePath> does not exist)."`                    | `"Start a recording with 'macrec start --detach' first."`                                                                       |
| `staleRecording(pid, pidFilePath)`            | `"Stale PID file at <pidFilePath> referenced PID <pid> which is no longer running. The file has been removed."` | `"You can start a new recording with 'macrec start --detach'."`                                                                 |
| `stopTimeout(pid, seconds)`                   | `"macrec process <pid> did not exit within <seconds>s of SIGTERM. The process may still be finalizing or hung."` | `"Inspect 'ps -p <pid>'. If it is still finalizing, wait. If it is hung, escalate to 'kill -KILL <pid>' (will lose the recording)." |
| `alreadyRecording(pid, pidFilePath)`          | `"Another macrec recording is already running (PID <pid>, PID file <pidFilePath>)."`                | `"Run 'macrec stop' first or pass '--pid-file <path>' to use a different file."`                                                |
| `pidFileWriteFailed(path, reason)`            | `"Failed to write PID file at <path>: <reason>."`                                                   | `"Check that the parent directory exists and is writable; try passing '--pid-file <path>' to a writable location."`             |

**Exit-code rationale for the new cases:**
- `noActiveRecording` → 78 (`EX_CONFIG`): the user has misconfigured —
  asked to stop without having started anything reachable via the
  resolved PID-file path.
- `staleRecording` → 75 (`EX_TEMPFAIL`): informational — the file has
  been cleaned up, the user can immediately try again. Chosen over
  exit 0 because the user's intent ("stop the running recording") was
  not actually fulfilled — there was nothing to stop.
- `stopTimeout` → 70 (`EX_SOFTWARE`): runtime failure — the daemon
  did not respond to SIGTERM within the bounded window.
- `alreadyRecording` → 78 (`EX_CONFIG`): the user is trying to start
  a second daemon over an existing one — a configuration / workflow
  error. The running recording is left untouched.
- `pidFileWriteFailed` → 66 (`EX_NOINPUT`): I/O error on the PID
  file's parent directory.

**Lifecycle / ownership:** Pure value type. Created at the throw site, propagated up
the call stack. Never retained.

**Concurrency rules:** Trivially `Sendable` (enum of `Sendable` payloads except
`underlying: Error`, which is opaque — annotated `@unchecked Sendable` only if a
Swift 6 strict-concurrency build complains).

---

### 2.2 `ToolAgentsBootstrap`

**File:** `Sources/MacrecCore/Bootstrap/ToolAgentsBootstrap.swift`

```swift
import Foundation

public enum ToolAgentsBootstrap {
    /// Ensures `~/.tool-agents/<toolName>/` exists at mode 0700 and contains
    /// a `.env` file at mode 0600. Idempotent. Re-chmods on every invocation
    /// (FR-13, AC-10).
    ///
    /// - Parameter toolName: e.g. "macrec".
    /// - Returns: The directory URL.
    /// - Throws: `MacrecError.ioError` on filesystem failure.
    public static func ensureToolFolder(toolName: String) throws -> URL

    /// Path to the per-user `.env` for this tool.
    public static func userEnvPath(toolName: String) -> URL

    /// Path to the local `.env` (CWD).
    public static func localEnvPath() -> URL
}
```

**Lifecycle:** Stateless (`enum`). Called exactly once from `main.swift`
before any subcommand dispatches (per Phase K plan).

**Concurrency:** Thread-safe (filesystem ops are atomic for our needs;
called only from main thread on startup).

**Errors thrown:** `MacrecError.ioError(String)`.

---

### 2.3 `DotEnvParser`

**File:** `Sources/MacrecCore/Config/DotEnvParser.swift`

```swift
import Foundation

public enum DotEnvParser {
    /// Parses a `.env`-format string into key→value pairs.
    ///
    /// Accepted syntax:
    ///   KEY=VALUE                     (whitespace around `=` trimmed)
    ///   KEY="value with spaces"       (one matched pair of " or ' stripped)
    ///   KEY=value containing #hash    (NOT a comment when no leading whitespace)
    ///   # comment line                (skipped)
    ///   <blank line>                  (skipped)
    ///
    /// Behavior:
    ///   - Duplicate keys: last write wins.
    ///   - Lines without `=`: silently skipped (debug log entry).
    ///   - No `$VAR` interpolation in v1.
    ///   - No multi-line values; line endings split on `\n` and `\r\n`.
    ///
    /// - Throws: `MacrecError.dotEnvParseError(path:line:reason:)` for
    ///   syntactically broken quoted values (unmatched quote, etc.).
    public static func parse(_ source: String, path: String) throws -> [String: String]

    /// Convenience: reads a file at `url` and parses it. Returns empty
    /// dictionary if the file does not exist (NOT an error).
    public static func parseFile(at url: URL) throws -> [String: String]
}
```

**Lifecycle:** Stateless.

**Errors thrown:** `MacrecError.dotEnvParseError`, `MacrecError.ioError`.

---

### 2.4 `ConfigResolver` + `RecordingOptions`

**File (resolver):** `Sources/MacrecCore/Config/ConfigResolver.swift`
**File (options):** `Sources/MacrecCore/Config/RecordingOptions.swift`

```swift
import Foundation

public enum OutputFormat: String, CaseIterable, Sendable {
    case m4a, wav, caf
}

public enum TrackLayout: String, CaseIterable, Sendable {
    case mixed
    case split
    case stereoSplit = "stereo-split"
}

public enum StereoChannel: String, CaseIterable, Sendable {
    case left, right
}

public enum LogLevel: String, CaseIterable, Sendable {
    case quiet, info, debug
}

/// Run mode (added 2026-04-26 per OQ-3 override / FR-25).
/// `.foreground` — runs in the invoking shell; logs to stderr; no PID file.
/// `.detached`   — double-forks; logs to log file; writes PID file.
public enum RunMode: String, CaseIterable, Sendable {
    case foreground, detached
}

public struct RecordingOptions: Sendable {
    public let outputPath: URL
    public let format: OutputFormat
    public let layout: TrackLayout
    public let sampleRate: Int           // 44100 | 48000
    public let bitDepth: Int             // 16 | 24 (PCM only; ignored for AAC)
    public let bitrate: Int              // 64...320 kbps (AAC only)
    public let micDevice: String?        // nil = system default
    public let micChannel: StereoChannel // .left | .right (stereo-split only)
    public let maxDuration: TimeInterval?
    public let overwrite: Bool
    public let logLevel: LogLevel
    // Run model (FR-25/FR-27/FR-29) — populated by StartCommand,
    // consumed by RecordingSession's PID file hook.
    public let runMode: RunMode          // .foreground (default) | .detached
    public let pidFilePath: URL          // honored only when runMode == .detached
    public let logFilePath: URL          // honored only when runMode == .detached
}

public final class ConfigResolver {
    /// Constructor. The four `[String: String]` arguments are the four
    /// configuration sources, lowest-to-highest priority.
    public init(
        shellEnv: [String: String],
        userEnv: [String: String],
        localEnv: [String: String],
        cliFlags: [String: String]
    )

    /// Returns the highest-priority value for `key`, or nil if unset
    /// in every source. The merge order is:
    ///   cliFlags > localEnv > userEnv > shellEnv
    public func resolve(_ key: String) -> String?

    /// Like `resolve`, but throws `MacrecError.missingRequiredConfig` if
    /// every source returns nil.
    public func requireString(_ key: String) throws -> String

    /// Builds the final, validated `RecordingOptions`. Performs:
    ///   - Required-key check (only `OUTPUT_PATH` is required).
    ///   - Enum parsing (`format`, `layout`, `mic-channel`, `log-level`).
    ///   - Range validation (FR-17).
    ///   - `~` expansion in the output path.
    ///   - `--overwrite` boolean parsing (`"true"`, `"1"`, `"yes"` all true).
    /// - Throws: `MacrecError.missingRequiredConfig` or
    ///   `MacrecError.invalidConfigValue`.
    public func buildRecordingOptions() throws -> RecordingOptions
}
```

**Lifecycle:** Created once per CLI invocation, owned by the relevant
`StartCommand` instance, dies when `run()` returns.

**Concurrency:** Built and consumed on the main thread; `Sendable` after
`buildRecordingOptions()` returns its result.

**Errors thrown:** `MacrecError.missingRequiredConfig`,
`MacrecError.invalidConfigValue`.

---

### 2.5 `LoggerFactory`

**File:** `Sources/MacrecCore/Logging/LoggerFactory.swift`

```swift
import Foundation
import Logging

public enum LoggerFactory {
    /// Bootstraps `swift-log` with a stderr handler at the requested level.
    /// Idempotent — safe to call multiple times in tests.
    /// Map: .quiet → .warning, .info → .info, .debug → .debug
    public static func bootstrap(level: LogLevel)

    /// Returns a logger for the given subsystem.
    /// Subsystem strings are listed in §6 (Logging contract).
    public static func make(subsystem: String) -> Logger
}
```

**Subsystem strings (locked, see §6):**
`macrec.cli`, `macrec.bootstrap`, `macrec.config`, `macrec.permissions`,
`macrec.devices`, `macrec.capture.system`, `macrec.capture.mic`,
`macrec.aligner`, `macrec.mixer`, `macrec.recorder.m4a`,
`macrec.recorder.wav`, `macrec.recorder.caf`, `macrec.session`,
`macrec.signal`.

---

### 2.6 Permissions

**Files:**
- `Sources/MacrecCore/Permissions/PermissionGate.swift` (protocol + Live impl)
- `Sources/MacrecCore/Permissions/ScreenRecordingPermission.swift`
- `Sources/MacrecCore/Permissions/MicrophonePermission.swift`

```swift
import Foundation

public enum PermissionState: String, Sendable {
    case authorized, denied, notDetermined, restricted
}

public protocol PermissionGate: AnyObject, Sendable {
    func screenRecordingStatus() -> PermissionState
    func microphoneStatus() -> PermissionState

    /// Triggers the screen-recording prompt if state is .notDetermined.
    /// Returns immediately; same-process state is unreliable, so callers
    /// must exit and ask the user to relaunch.
    func requestScreenRecording() -> Bool

    /// Async micro-permission request; completion fires after the user
    /// dismisses the prompt.
    func requestMicrophone() async -> Bool
}

/// Production gate composing the two concrete permission helpers.
public final class LivePermissionGate: PermissionGate {
    public init()
    // ...
}

public enum ScreenRecordingPermission {
    public static func current() -> PermissionState     // CGPreflightScreenCaptureAccess()
    public static func request() -> Bool                 // CGRequestScreenCaptureAccess()
}

public enum MicrophonePermission {
    public static func current() -> PermissionState
    public static func request() async -> Bool
}
```

**Test fake (lives in `Tests/MacrecCoreTests/Fakes/StubPermissionGate.swift`):**

```swift
import MacrecCore

final class StubPermissionGate: PermissionGate {
    var screenState: PermissionState = .authorized
    var micState: PermissionState = .authorized
    func screenRecordingStatus() -> PermissionState { screenState }
    func microphoneStatus() -> PermissionState { micState }
    func requestScreenRecording() -> Bool { screenState == .authorized }
    func requestMicrophone() async -> Bool { micState == .authorized }
}
```

---

### 2.7 `AudioDeviceEnumerator`

**File:** `Sources/MacrecCore/Devices/AudioDeviceEnumerator.swift`

```swift
import Foundation

public struct AudioInputDevice: Sendable, Equatable {
    public let uid: String
    public let name: String
    public let sampleRateHz: Double
    public let channelCount: Int
    public let isDefault: Bool
}

public protocol AudioDeviceEnumerating: AnyObject, Sendable {
    func listInputDevices() throws -> [AudioInputDevice]
    func resolve(_ identifier: String) throws -> AudioInputDevice
}

public final class AudioDeviceEnumerator: AudioDeviceEnumerating {
    public init()

    /// Lists all input-capable devices via Core Audio HAL
    /// (`kAudioHardwarePropertyDevices` + scope=Input filter).
    /// Throws `MacrecError.noInputDevicesAvailable` if the list is empty.
    public func listInputDevices() throws -> [AudioInputDevice]

    /// Resolves `--mic-device` argument. Algorithm (OQ-8):
    ///   1. UID match (case-sensitive). UID always wins.
    ///   2. Name match (case-insensitive). Multiple matches → log warning,
    ///      pick the first by ascending AudioObjectID.
    ///   3. None → throw `MacrecError.micDeviceNotFound(identifier)`.
    public func resolve(_ identifier: String) throws -> AudioInputDevice
}
```

**Test fake (`FakeAudioDeviceEnumerator`):** Holds a `[AudioInputDevice]`
constructed in tests; honors the same resolution rules.

---

### 2.8 Capture sources

**Files:**
- `Sources/MacrecCore/Capture/SystemAudioSource.swift` (protocol)
- `Sources/MacrecCore/Capture/MicrophoneSource.swift` (protocol)
- `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift`
- `Sources/MacrecCore/Capture/AVMicrophoneSource.swift`
- `Sources/MacrecCore/Capture/FakeAudioSource.swift`

```swift
import CoreMedia

public enum CaptureSourceTag: Sendable {
    case system
    case microphone
}

/// Envelope around a CMSampleBuffer that carries source attribution.
/// Used by the aligner to route per-source.
public struct CaptureBuffer: @unchecked Sendable {
    public let source: CaptureSourceTag
    public let buffer: CMSampleBuffer       // retain semantics: opaque CF type
    public init(source: CaptureSourceTag, buffer: CMSampleBuffer)
}

public protocol AudioSource: AnyObject {
    /// The Core Media format description of the buffers this source emits
    /// AFTER the per-source AVAudioConverter. Always Float32/48k/stereo
    /// non-interleaved when the source is wired into the pipeline.
    var formatDescription: CMAudioFormatDescription? { get }

    /// Set by the orchestrator before `start()`. Called on the source's
    /// own delivery queue; the closure must enqueue and return promptly.
    var onSampleBuffer: ((CaptureBuffer) -> Void)? { get set }

    func start() async throws
    func stop() async
}

public protocol SystemAudioSource: AudioSource { }
public protocol MicrophoneSource: AudioSource { }
```

#### 2.8.1 `SCKitSystemAudioSource`

```swift
import ScreenCaptureKit
import CoreMedia
import AVFoundation
import Logging

public final class SCKitSystemAudioSource: NSObject,
                                            SystemAudioSource,
                                            SCStreamOutput,
                                            SCStreamDelegate {
    public init(sampleRate: Int = 48_000,
                channelCount: Int = 2,
                logger: Logger,
                clock: CMClock = CMClockGetHostTimeClock())

    public var formatDescription: CMAudioFormatDescription? { get }
    public var onSampleBuffer: ((CaptureBuffer) -> Void)?

    public func start() async throws    // throws .scStreamFailedToStart
    public func stop() async

    // SCStreamOutput
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sb: CMSampleBuffer,
                       of type: SCStreamOutputType)

    // SCStreamDelegate
    public func stream(_ stream: SCStream, didStopWithError error: Error)
}
```

**Internal contract:** see §7 for the exact `SCStreamConfiguration` literal
and watchdog parameters. Conforms to FR-19 (5 s poll, 10 s threshold,
3-restarts-in-60 s fatal cap). All work in `didStopWithError` is wrapped in
`Task { ... }` to dodge the `swift_getErrorValue` `EXC_BAD_ACCESS` framework
bug (per `docs/research/scstream-audio-only.md` §3).

**Errors thrown:** `MacrecError.scStreamFailedToStart`,
`MacrecError.scStreamSilentStopExceeded`.

#### 2.8.2 `AVMicrophoneSource`

```swift
import AVFoundation
import CoreMedia
import Logging

public final class AVMicrophoneSource: NSObject,
                                        MicrophoneSource,
                                        AVCaptureAudioDataOutputSampleBufferDelegate {
    public init(deviceIdentifier: String?,
                deviceEnumerator: AudioDeviceEnumerating,
                targetSampleRate: Int = 48_000,
                targetChannelCount: Int = 2,
                logger: Logger)

    public var formatDescription: CMAudioFormatDescription? { get }
    public var onSampleBuffer: ((CaptureBuffer) -> Void)?

    public func start() async throws  // throws .avCaptureFailedToStart, .micDeviceNotFound
    public func stop() async

    // AVCaptureAudioDataOutputSampleBufferDelegate
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection)
}
```

**Internal contract:** Sets
`session.synchronizationClock = CMClockGetHostTimeClock()` (FR-22) before
adding inputs. Owns one long-lived `AVAudioConverter` (created lazily on
first buffer once the device's native format is known). Uses
`output.audioSettings = [:]` so the device delivers its native format and
the converter normalizes to Float32/48k/stereo.

#### 2.8.3 `FakeAudioSource`

```swift
import CoreMedia

public final class FakeAudioSource: AudioSource {
    public init(tag: CaptureSourceTag,
                frequencyHz: Double,
                channelCount: Int = 2,
                sampleRate: Double = 48_000,
                bufferDurationMs: Double = 20,
                hostClock: CMClock = CMClockGetHostTimeClock())

    public var formatDescription: CMAudioFormatDescription? { get }
    public var onSampleBuffer: ((CaptureBuffer) -> Void)?

    public func start() async throws
    public func stop() async

    // Convenience factories used by RecordingSessionTests:
    public static func makeSystem440Hz(logger: Logger? = nil) -> FakeAudioSource
    public static func makeMic880Hz(logger: Logger? = nil) -> FakeAudioSource
}

extension FakeAudioSource: SystemAudioSource { }
extension FakeAudioSource: MicrophoneSource  { }
```

Generates non-interleaved Float32 sine waves on a `DispatchQueue`. PTSs are
derived from the captured `CMClock.hostTimeClock.time` at `start()` plus
cumulative buffer durations.

---

### 2.9 Aligning + Mixing

**Files:**
- `Sources/MacrecCore/Aligning/HostClockAligner.swift`
- `Sources/MacrecCore/Aligning/SilenceBufferFactory.swift`
- `Sources/MacrecCore/Mixing/BufferSummer.swift`

```swift
import CoreMedia
import AVFoundation
import Logging

/// One time-aligned pair of buffers covering the same wall-clock interval.
/// The aligner emits one of these per output tick. For `split` layout the
/// aligner is bypassed; sources go directly to per-source recorders.
public struct AlignedFrame: @unchecked Sendable {
    public let pts: CMTime
    public let duration: CMTime
    public let systemBuffer: CMSampleBuffer    // gap-filled if necessary
    public let micBuffer: CMSampleBuffer       // gap-filled if necessary
}

public final class HostClockAligner {
    public init(formatDescription: CMAudioFormatDescription,
                sampleRate: Double = 48_000,
                logger: Logger,
                ringCapacity: Int = 10)         // ~200 ms of 20 ms buffers

    /// Set by the orchestrator before any `accept` call.
    public var onAlignedFrame: ((AlignedFrame) -> Void)?

    /// Capture-source callbacks call this. Returns immediately; actual
    /// alignment runs on `macrec.aligner` queue.
    public func accept(_ capture: CaptureBuffer)

    /// Drain remaining buffered data on stop. Synchronous wrt the aligner
    /// queue; safe to call from `RecordingSession.stop()` after sources
    /// have been stopped.
    public func drain()
}

public enum SilenceBufferFactory {
    public static func makeSilence(
        startPTS: CMTime,
        duration: CMTime,
        formatDescription: CMAudioFormatDescription,
        sampleRate: Double = 48_000
    ) throws -> CMSampleBuffer
}

public enum BufferSummer {
    /// Pointwise float add of two non-interleaved Float32 stereo buffers
    /// of identical frame count. Output is clamped to [-1.0, +1.0].
    /// Per A-7: no AGC, no ducking, no echo cancellation.
    public static func sum(
        _ a: AVAudioPCMBuffer,
        _ b: AVAudioPCMBuffer,
        gainA: Float = 1.0,
        gainB: Float = 1.0
    ) throws -> AVAudioPCMBuffer

    /// CMSampleBuffer-level convenience used by RecordingSession.
    public static func sum(
        _ a: CMSampleBuffer,
        _ b: CMSampleBuffer,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer
}
```

**Aligner algorithm (verbatim recipe from `docs/research/scstream-audio-only.md`
§4.3 + the Nonstrict gap-handling reference):**

1. Capture queue calls `accept(_:)` → enqueue onto per-source ring buffer
   on the `macrec.aligner` serial queue.
2. On each enqueue, attempt `tryDrain()`:
   - For each source S in {system, mic}:
     - Let `ptsS = head(S).pts`. Compute `gapS = ptsS - nextExpectedAudioTime[S]`.
     - If `gapS > 1 sample period`, prepend a synthetic silence buffer of
       duration `gapS` via `SilenceBufferFactory`. Update
       `nextExpectedAudioTime[S] = ptsS`.
   - If both heads have data covering an overlapping time slice ≥ one
     buffer width, slice each side to that interval, emit
     `AlignedFrame(pts:, duration:, systemBuffer:, micBuffer:)`, advance
     `nextExpectedAudioTime[S] = pts + duration` for each source, drop
     consumed bytes from the heads.
3. PTS normalization at ingress: every incoming buffer's timing info is
   converted to timescale `48_000` (per Phase F risk register R-1 / `docs/design/plan-001-recording-tool.md` §6).

**`drain()` semantics:** Stop accepting new captures (latch a `stopped` flag).
Slice and emit any remaining matched portion. Drop residual non-matched
data (by definition, if only one side has data left after sources have
stopped, no aligned pair exists).

---

### 2.10 Recorders

**Files:**
- `Sources/MacrecCore/Encoding/Recorder.swift` (protocol)
- `Sources/MacrecCore/Encoding/M4ARecorder.swift`
- `Sources/MacrecCore/Encoding/WAVRecorder.swift`
- `Sources/MacrecCore/Encoding/CAFRecorder.swift`

> **R-18 resolution (Phase 7 Code Reviewer, 2026-04-26)**: the Phase G
> implementation adopted an `async throws` lifecycle and consumes
> `AlignedFrame` (the post-aligner envelope, owning per-side
> `CMSampleBuffer`s plus host-clock PTS / duration) instead of a raw
> `CMSampleBuffer`. The signature below is the authoritative shape;
> the original closure-based draft is retained for traceability in the
> commit history. The change keeps watchdog semantics (FR-20, 30 s
> finalize timeout) intact while integrating cleanly with
> `RecordingSession`'s async lifecycle (no
> `withCheckedThrowingContinuation` shim at every call site).

```swift
import CoreMedia
import Foundation

public protocol Recorder: AnyObject, Sendable {
    /// Open the underlying writer and begin a session. Captures the
    /// session-start time internally as
    /// `CMClockGetTime(CMClockGetHostTimeClock())`. Throws
    /// `MacrecError.writerFailedToStart` on any pre-flight or open
    /// failure.
    func start() async throws

    /// Append one aligned frame (per-side `CMSampleBuffer`s plus host-
    /// clock PTS / duration). Recorders honor the configured
    /// `TrackLayout` themselves:
    ///   * `.mixed`        — sum mic + system into a single stereo track.
    ///   * `.stereoSplit`  — produce a stereo track where the mic
    ///                       occupies the configured channel and the
    ///                       system audio the other.
    ///   * `.split`        — write mic and system to separate sibling
    ///                       files (`<basename>.mic.<ext>` and
    ///                       `<basename>.system.<ext>`, FR-5).
    /// Implementations enqueue work onto their private writer queue and
    /// honor `isReadyForMoreMediaData` for AVAssetWriter-backed writers.
    func append(_ frame: AlignedFrame) throws

    /// Finalize and close the writer. Idempotent — repeated calls are
    /// no-ops. Awaits up to `timeout` for `finishWriting` to complete.
    /// On timeout: throws `MacrecError.writerFinalizationTimeout` and
    /// leaves the partial file on disk. On AVAssetWriter failure:
    /// throws `MacrecError.finishWritingFailed`.
    func finalize(timeout: TimeInterval) async throws
}

public final class M4ARecorder: Recorder {
    public init(options: RecordingOptions, logger: Logger? = nil)
    // ...
}

public final class WAVRecorder: Recorder {
    public init(options: RecordingOptions, logger: Logger? = nil)
    // ...
}

public final class CAFRecorder: Recorder {
    public init(options: RecordingOptions, logger: Logger? = nil)
    // ...
}
```

**File:** `Sources/MacrecCore/Encoding/CMSampleBufferAudioConversion.swift`

```swift
import AVFoundation
import CoreMedia

internal enum CMSampleBufferAudioConversion {
    /// Convert a CMSampleBuffer of non-interleaved Float32 PCM to an
    /// AVAudioPCMBuffer of the same format. Used by WAVRecorder /
    /// CAFRecorder before calling AVAudioFile.write(from:).
    static func toPCMBuffer(_ buffer: CMSampleBuffer,
                            format: AVAudioFormat) throws -> AVAudioPCMBuffer

    /// Inverse: build a CMSampleBuffer from an AVAudioPCMBuffer with the
    /// given presentation time. Used by BufferSummer.
    static func toSampleBuffer(_ pcm: AVAudioPCMBuffer,
                               presentationTime: CMTime,
                               formatDescription: CMAudioFormatDescription)
        throws -> CMSampleBuffer
}
```

---

### 2.11 `RecordingSession`

**Files:**
- `Sources/MacrecCore/RecordingSession.swift`
- `Sources/MacrecCore/SignalHandler.swift`

```swift
import CoreMedia
import Foundation
import Logging

public enum StopReason: Sendable {
    case signal(Int32)
    case maxDuration
    case programmatic
    case error(MacrecError)
}

public final class RecordingSession {
    public init(
        options: RecordingOptions,
        systemSource: SystemAudioSource,
        micSource: MicrophoneSource,
        permissions: PermissionGate,
        logger: Logger
    )

    /// Validates permissions (FR-10) and output path (FR-15, FR-24);
    /// captures sessionStart = CMClock.hostTimeClock.time; builds aligner
    /// + recorder(s) per layout; wires sources; calls
    /// systemSource.start() and micSource.start(); installs max-duration
    /// timer if set. Does NOT install signal handlers — the orchestrator
    /// (main.swift) does that.
    /// - Throws: any MacrecError surfaced by permissions, output path,
    ///   capture, or recorder initialization.
    public func start() async throws

    /// Idempotent. Stops sources, drains aligner, finalizes recorder(s).
    /// Calls completion exactly once. Honors finalization timeout (FR-20).
    public func stop(reason: StopReason,
                     completion: @escaping (Result<[URL], MacrecError>) -> Void)
}

public final class SignalHandler {
    public init()

    /// Installs SIGINT and SIGTERM handlers. Calls `stopAction` with the
    /// signal number on the first signal received; ignores subsequent
    /// signals (so a double Ctrl-C does not race the finalization).
    /// Pattern verbatim from `docs/research/avassetwriter-aac.md` §1.4 / §5.1.
    public func install(stopAction: @escaping (Int32) -> Void)
}
```

**`RecordingSession.start()` algorithm:**

1. **Permissions (FR-10):**
   - If `permissions.screenRecordingStatus() != .authorized`:
     - `.notDetermined` → `_ = permissions.requestScreenRecording()`; throw
       `screenRecordingPermissionNotDetermined`.
     - `.denied` / `.restricted` → throw `screenRecordingPermissionDenied`.
   - Same triage for microphone.
2. **Output path (FR-15, FR-24):** Per layout, validate one or two paths.
   - Parent dir must exist (no implicit `mkdir -p`); else throw
     `outputParentMissing`.
   - File must not exist OR `options.overwrite == true`; else throw
     `outputAlreadyExists`. If `overwrite == true` and file exists,
     `try FileManager.default.removeItem(at:)`.
3. **Capture sessionStart:** `let sessionStart = CMClock.hostTimeClock.time`.
4. **Build recorders:**
   - `mixed` / `stereo-split`: one Recorder at `options.outputPath`.
   - `split`: two recorders at
     `<basename>.mic.<ext>` and `<basename>.system.<ext>`.
5. **Build aligner:** `HostClockAligner` (skipped for `split` layout; see §1.2).
6. **Wire callbacks:**
   - For `split`: source's `onSampleBuffer` → per-source Recorder.append.
   - For `mixed`: source's `onSampleBuffer` → aligner.accept; aligner's
     `onAlignedFrame` → BufferSummer.sum → Recorder.append.
   - For `stereo-split`: aligner.onAlignedFrame → channel-pin to single
     stereo buffer → Recorder.append.
7. **Start writers:** `try recorder.start(at: sessionStart)` for each.
8. **Start sources:** `try await systemSource.start()`; `try await micSource.start()`.
9. **Max-duration timer:** if `options.maxDuration != nil`, schedule a
   `DispatchSourceTimer` on a `.utility` queue that calls
   `self.stop(reason: .maxDuration, completion: ...)`.
10. **RMS heartbeat (FR-23):** if `options.logLevel == .debug`, schedule a
    repeating `DispatchSourceTimer` (10 s interval) that computes per-source
    RMS over the last drained `AlignedFrame` and logs at `.debug` level on
    `macrec.session`.

**`RecordingSession.stop(reason:completion:)` algorithm:**

1. Idempotency guard: `let firstStop = isStopping.cas(false, true)`.
2. Cancel timers (max-duration, heartbeat).
3. `await systemSource.stop()`; `await micSource.stop()`.
4. `aligner.drain()` (if present).
5. For each recorder, call `recorder.finalize(at: CMClock.hostTimeClock.time,
   timeout: 30) { result in ... }`. Collect results in a `DispatchGroup`.
6. When all recorders complete (or any one fails), invoke `completion`
   with `.success([urls])` or `.failure(firstError)`.

---

### 2.12 CLI Commands

**Files:**
- `Sources/macrec/main.swift`
- `Sources/macrec/Commands/RootCommand.swift`
- `Sources/macrec/Commands/StartCommand.swift`
- `Sources/macrec/Commands/ListDevicesCommand.swift`
- `Sources/macrec/Commands/CheckPermissionsCommand.swift`

```swift
// main.swift
import ArgumentParser
import MacrecCore

@main
struct MacrecMain {
    static func main() async {
        // FR-13: every invocation, every subcommand.
        do {
            _ = try ToolAgentsBootstrap.ensureToolFolder(toolName: "macrec")
        } catch {
            fputs("macrec: bootstrap failed: \(error)\n", stderr)
            exit(1)
        }
        // Logger bootstrap is delegated to each subcommand once log-level
        // has been resolved.
        await RootCommand.main()
    }
}
```

```swift
// RootCommand.swift
import ArgumentParser

public struct RootCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "macrec",
        abstract: "Simultaneously record macOS system audio and microphone audio.",
        version: "0.1.0",
        subcommands: [
            StartCommand.self,
            ListDevicesCommand.self,
            CheckPermissionsCommand.self,
        ],
        defaultSubcommand: nil
    )
    public init() {}
}
```

```swift
// StartCommand.swift
import ArgumentParser
import MacrecCore

public struct StartCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Begin a recording. Stop with Ctrl-C (SIGINT) or SIGTERM."
    )

    @Option(name: .shortAndLong, help: "Output file path (required).")
    var output: String?

    @Option(help: "Output format (m4a | wav | caf). Default: m4a.")
    var format: String?

    @Option(help: "Track layout (mixed | split | stereo-split). Default: mixed.")
    var layout: String?

    @Option(name: .customLong("sample-rate"),
            help: "Sample rate in Hz (44100 | 48000). Default: 48000.")
    var sampleRate: Int?

    @Option(name: .customLong("bit-depth"),
            help: "Bit depth (16 | 24, PCM only). Default: 16.")
    var bitDepth: Int?

    @Option(help: "AAC bitrate in kbps (64-320). Default: 192.")
    var bitrate: Int?

    @Option(name: .customLong("mic-device"),
            help: "Microphone device name or UID. Default: system default.")
    var micDevice: String?

    @Option(name: .customLong("mic-channel"),
            help: "Stereo-split mic channel (left | right). Default: left.")
    var micChannel: String?

    @Option(name: .customLong("max-duration"),
            help: "Auto-stop after N seconds. Default: run until SIGINT.")
    var maxDuration: Double?

    @Flag(help: "Overwrite an existing output file.")
    var overwrite: Bool = false

    @Option(name: .customLong("log-level"),
            help: "Log verbosity (quiet | info | debug). Default: info.")
    var logLevel: String?

    public init() {}

    public mutating func run() async throws {
        // Implementation:
        //   1. Build ConfigResolver from ProcessInfo.environment + the
        //      two .env files + the parsed flags (above).
        //   2. resolver.buildRecordingOptions() → RecordingOptions.
        //      (Reject `--output -` here per OQ-5.)
        //   3. LoggerFactory.bootstrap(level: options.logLevel).
        //   4. Build LivePermissionGate, SCKitSystemAudioSource,
        //      AVMicrophoneSource, RecordingSession.
        //   5. SignalHandler.install { signal in session.stop(...) }.
        //   6. try await session.start().
        //   7. Wait on a CheckedContinuation that the stop completion
        //      resolves with the result. exit(0) on success; exit
        //      with MacrecError.exitCode on failure.
    }
}
```

```swift
// ListDevicesCommand.swift
public struct ListDevicesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list-devices",
        abstract: "List input audio devices."
    )
    public init() {}
    public func run() throws {
        // Calls AudioDeviceEnumerator.listInputDevices().
        // Output format (one line per device, tab-separated):
        //   <uid>\t<name>\t<channelCount>ch\t<sampleRateHz>Hz[ (default)]
    }
}
```

```swift
// CheckPermissionsCommand.swift
public struct CheckPermissionsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "check-permissions",
        abstract: "Print Screen Recording and Microphone permission state."
    )
    public init() {}
    public func run() throws {
        // Prints two lines, e.g.:
        //   ScreenRecording: authorized
        //   Microphone:      denied
        // Exit code: 0 if both authorized; else the highest-priority
        // matching MacrecError.exitCode (notDetermined → 75; denied → 77).
    }
}
```

---

## Section 3 — Data Shapes

### 3.1 `RecordingOptions` (resolved)

| Field         | Type               | Default       | Source key      | Required |
|---------------|--------------------|---------------|-----------------|----------|
| `outputPath`  | `URL`              | _none_        | `OUTPUT_PATH`   | **yes**  |
| `format`      | `OutputFormat`     | `.m4a`        | `FORMAT`        | no       |
| `layout`      | `TrackLayout`      | `.mixed`      | `LAYOUT`        | no       |
| `sampleRate`  | `Int`              | `48000`       | `SAMPLE_RATE`   | no       |
| `bitDepth`    | `Int`              | `16`          | `BIT_DEPTH`     | no       |
| `bitrate`     | `Int`              | `192`         | `BITRATE`       | no       |
| `micDevice`   | `String?`          | `nil`         | `MIC_DEVICE`    | no       |
| `micChannel`  | `StereoChannel`    | `.left`       | `MIC_CHANNEL`   | no       |
| `maxDuration` | `TimeInterval?`    | `nil`         | `MAX_DURATION`  | no       |
| `overwrite`   | `Bool`             | `false`       | `OVERWRITE`     | no       |
| `logLevel`    | `LogLevel`         | `.info`       | `LOG_LEVEL`     | no       |
| `runMode`     | `RunMode`          | `.foreground` | `DETACH` (Bool→enum) | no       |
| `pidFilePath` | `URL`              | `~/.tool-agents/macrec/macrec.pid` | `MACREC_PID_FILE` | no |
| `logFilePath` | `URL`              | `~/.tool-agents/macrec/macrec.log` | `MACREC_LOG_FILE` | no |

### 3.2 `AudioInputDevice`

```swift
public struct AudioInputDevice: Sendable, Equatable {
    public let uid: String           // kAudioDevicePropertyDeviceUID
    public let name: String          // kAudioDevicePropertyDeviceNameCFString
    public let sampleRateHz: Double  // kAudioDevicePropertyNominalSampleRate
    public let channelCount: Int     // sum of mNumberChannels in input streamConfig
    public let isDefault: Bool       // matches kAudioHardwarePropertyDefaultInputDevice
}
```

### 3.3 `AlignedFrame`

```swift
public struct AlignedFrame: @unchecked Sendable {
    public let pts: CMTime              // identical for both sub-buffers
    public let duration: CMTime         // identical for both sub-buffers
    public let systemBuffer: CMSampleBuffer   // gap-filled if the system
                                              // source stalled this slice
    public let micBuffer: CMSampleBuffer      // gap-filled if the mic
                                              // source stalled this slice
}
```

The sub-buffers are CMSampleBuffer references (CF retain semantics). The
`AlignedFrame` is consumed by exactly one downstream component
(BufferSummer or channel-pin step) and not retained beyond that call.

### 3.4 `CaptureBuffer`

```swift
public struct CaptureBuffer: @unchecked Sendable {
    public let source: CaptureSourceTag      // .system or .microphone
    public let buffer: CMSampleBuffer        // already converted to
                                             // Float32/48k/stereo by the
                                             // per-source AVAudioConverter
}
```

---

## Section 4 — Sequence Diagrams

### 4.1 Cold start, normal stop (SIGINT)

```
user        macrec(main)        ToolAgents      RootCommand   StartCommand   RecordingSession   SystemSrc   MicSrc   Recorder
 │              │                  │                │             │                │              │           │         │
 │ macrec start │                  │                │             │                │              │           │         │
 │   --output …│                  │                │             │                │              │           │         │
 │─────────────▶│                  │                │             │                │              │           │         │
 │              │ ensureToolFolder │                │             │                │              │           │         │
 │              │─────────────────▶│ (creates 0700/0600)          │                │              │           │         │
 │              │                  │                │             │                │              │           │         │
 │              │ RootCommand.main │                │             │                │              │           │         │
 │              │──────────────────────────────────▶│ dispatch    │                │              │           │         │
 │              │                  │                │────────────▶│ run()          │              │           │         │
 │              │                  │                │             │ buildOptions   │              │           │         │
 │              │                  │                │             │ bootstrap log  │              │           │         │
 │              │                  │                │             │ make session   │              │           │         │
 │              │                  │                │             │───────────────▶│ start()      │           │         │
 │              │                  │                │             │                │ check perms  │           │         │
 │              │                  │                │             │                │ validate path│           │         │
 │              │                  │                │             │                │ build rec.   │           │         │
 │              │                  │                │             │                │ wire cb.     │           │         │
 │              │                  │                │             │                │──start────  ▶│           │         │
 │              │                  │                │             │                │──start────────────────▶  │         │
 │              │                  │                │             │                │──recorder.start───────────────────▶│
 │              │                  │                │             │                │              │           │         │
 │              │                  │                │             │                │ install signals (main)   │         │
 │              │                  │                │             │ await stop ────│              │           │         │
 │              │                  │                │             │                │              │           │         │
 │  audio plays │                  │                │             │                │ buffers ▶ aligner ▶ rec  │         │
 │              │                  │                │             │                │              │           │         │
 │ Ctrl-C ─SIGINT▶                 │                │             │                │              │           │         │
 │              │                  │                │             │ SignalHandler  │              │           │         │
 │              │                  │                │             │   ───stop(.signal(SIGINT))───▶│           │         │
 │              │                  │                │             │                │ ──stop()──── ▶│           │         │
 │              │                  │                │             │                │ ──stop()────────────────▶│         │
 │              │                  │                │             │                │ aligner.drain()           │         │
 │              │                  │                │             │                │ ──finalize(timeout:30)────────────▶│
 │              │                  │                │             │                │              │           │ writeMoov│
 │              │                  │                │             │                │              │           │ done◀───│
 │              │                  │                │             │ ◀──completion(.success([url]))             │         │
 │              │                  │                │             │ exit(0)        │              │           │         │
```

### 4.2 Permission denied — early exit

```
user      macrec       PermissionGate   StartCommand
 │          │               │                │
 │ start... │               │                │
 │─────────▶│               │                │
 │          │ run()         │                │
 │          │──────────────▶│ screenStatus() │
 │          │               │ ── .denied     │
 │          │ throw .screenRecordingPermissionDenied
 │          │ stderr: "Screen Recording permission denied"
 │          │ stderr: "Open System Settings > … and enable macrec, then re-run."
 │          │ exit(77)      │                │
```

For `.notDetermined` the gate calls `requestScreenRecording()` (which spawns
the system prompt asynchronously) and exits 75 with the relaunch message.
**No partial output file is created** because path validation happens
AFTER permission validation in `RecordingSession.start()`.

### 4.3 SCStream silent-stop watchdog firing

```
SCStream   audioQueue   Watchdog Task   SCKitSource     Aligner   Recorder
   │           │            │                │            │          │
buffer ───────▶│            │                │            │          │
   │           │ lastBufferArrival = .now    │            │          │
   │           │ aligner.accept(buf) ───────────────────▶ │          │
   │           │            │                │            │          │
   ╳ (silent stop, no callback, no error) ───┤            │          │
   │           │            │                │            │          │
   │           │            │ poll every 5 s │            │          │
   │           │            │ staleness > 10s│            │          │
   │           │            │───────────────▶│ restartStream()       │
   │           │            │                │ try? await stream?.stopCapture()
   │           │            │                │ stream = nil          │
   │           │            │                │ rebuild filter+cfg    │
   │           │            │                │ stream = SCStream(...)│
   │           │            │                │ addStreamOutput(.audio,.screen)
   │           │            │                │ lastBufferArrival = .now
   │           │            │                │ try await stream.startCapture()
   │ (new buffers arrive) ──┐                │            │          │
   │           │ aligner.accept(buf) ───────────────────▶ │          │
   │           │            │                │            │          │
   │           │            │ if restartCount > 3 in 60 s:│          │
   │           │            │   throw .scStreamSilentStopExceeded(restartCount)
   │           │            │   → propagated to RecordingSession,
   │           │            │     which calls stop(.error(...)) and
   │           │            │     exits 70.
```

The aligner is **agnostic** to the restart: the new SCStream's first
buffer arrives with a PTS that is later than the last seen system PTS, so
the aligner's gap-fill logic synthesizes silence for the missing interval.
The `AVAssetWriter.startSession` is **not** called again; only one session
per writer per recording (`docs/research/avassetwriter-aac.md` §2.4).

### 4.4 Max-duration cap reached

```
DispatchSourceTimer    RecordingSession    Sources    Aligner    Recorder
       │                     │                │          │          │
 (fires at maxDuration) ────▶│ stop(.maxDuration, …)     │          │
                             │ idempotency guard         │          │
                             │ ── stop() ───────────────▶│          │
                             │ aligner.drain()           │          │
                             │ ── finalize(timeout:30) ─────────────▶│
                             │                                       │ writeMoov + finishWriting
                             │ ◀── completion(.success([url]))
                             │ exit(0)
```

### 4.5 `finishWriting` exceeds 30 s timeout

```
RecordingSession   M4ARecorder    AVAssetWriter   Watchdog (DispatchWorkItem)
       │                │              │                  │
 finalize(timeout:30) ─▶│ markAsFinished
                        │ endSession(at: end)
                        │ finishWriting { … }
                        │ schedule watchdog @ +30s
                        │ ◀── (still encoding/copying mdat)
                        │              │                  │
                        │              │   30s elapsed ──▶│ fires
                        │              │                  │ stderr: "macrec: finishWriting timed out — exiting with partial file"
                        │              │                  │ stderr: "macrec: Output file at <url> may be incomplete."
                        │ ◀── completion(.failure(.writerFinalizationTimeout(url)))
       │ ◀── propagation
       │ exit(2)
```

What is left on disk:
- The randomized **temp file** in the output directory holds raw mdat data.
  With `movieFragmentInterval = CMTime(value: 2, timescale: 1)` set, the
  temp file is a **valid fragmented MP4**: VLC and `ffmpeg -c copy` can
  recover it (`docs/research/avassetwriter-aac.md` §5.3, §7.3).
- The user-specified output path may not exist or may be incomplete.
- The tool exits 2 (`MacrecError.writerFinalizationTimeout` →
  `EX_USAGE`-class catch-all per the FR-18 table).

---

## Section 5 — Configuration Precedence — Concrete Behavior

### 5.1 `ConfigResolver.buildRecordingOptions()` algorithm

```
Input: shellEnv, userEnv, localEnv, cliFlags  (each [String: String])

1. For each (cliKey, envKey) mapping in §5.2:
     v = cliFlags[cliKey] ?? localEnv[envKey] ?? userEnv[envKey] ?? shellEnv[envKey]
     store in `merged[envKey]`.

2. Required keys (only OUTPUT_PATH per OQ-10):
     guard let outputRaw = merged["OUTPUT_PATH"] else {
         throw .missingRequiredConfig(
             key: "OUTPUT_PATH",
             sourcesChecked: ["--output", "./.env", "~/.tool-agents/macrec/.env", "shell"]
         )
     }
     // Reject "-" per OQ-5 (stdout streaming deferred to v2).
     guard outputRaw != "-" else {
         throw .invalidConfigValue(
             key: "OUTPUT_PATH",
             value: "-",
             expected: "a writable file path (stdout streaming is not supported in v1)"
         )
     }
     let outputPath = expandTilde(outputRaw)   // ~/foo → /Users/<u>/foo

3. Defaultable keys: parse with type-specific helpers (§5.3). Range
   validation per FR-17. Each violation throws .invalidConfigValue with
   the offending key, the bad value, and the expected set/range.

4. Return RecordingOptions(...).
```

### 5.2 Mapping table — CLI flag ↔ env var ↔ default

| CLI flag         | Env var       | Default                | Required | Validator    |
|------------------|---------------|------------------------|----------|--------------|
| `--output`       | `OUTPUT_PATH` | _required_             | **yes**  | non-empty path; not "-" |
| `--format`       | `FORMAT`      | `m4a`                  | no       | enum: m4a, wav, caf |
| `--layout`       | `LAYOUT`      | `mixed`                | no       | enum: mixed, split, stereo-split |
| `--sample-rate`  | `SAMPLE_RATE` | `48000`                | no       | enum: 44100, 48000 |
| `--bit-depth`    | `BIT_DEPTH`   | `16`                   | no       | enum: 16, 24 |
| `--bitrate`      | `BITRATE`     | `192`                  | no       | range: [64, 320] |
| `--mic-device`   | `MIC_DEVICE`  | _system default input_ | no       | non-empty string |
| `--mic-channel`  | `MIC_CHANNEL` | `left`                 | no       | enum: left, right |
| `--max-duration` | `MAX_DURATION`| _none_                 | no       | TimeInterval > 0 |
| `--overwrite`    | `OVERWRITE`   | `false`                | no       | bool: true/1/yes vs false/0/no |
| `--log-level`    | `LOG_LEVEL`   | `info`                 | no       | enum: quiet, info, debug |

### 5.3 `.env` parser accepted syntax

| Syntax                          | Behavior                                                    |
|---------------------------------|-------------------------------------------------------------|
| `KEY=VALUE`                      | Parsed; whitespace around `=` trimmed.                      |
| `KEY=`                           | Parsed as `KEY → ""`.                                       |
| `KEY="value with spaces"`        | One matched pair of `"` stripped.                           |
| `KEY='value with spaces'`        | One matched pair of `'` stripped.                           |
| `KEY=value containing #hash`     | Hash is part of the value (no leading whitespace before `#`).|
| `# comment`                      | Skipped.                                                    |
| `   # indented comment`          | Skipped.                                                    |
| Blank line                       | Skipped.                                                    |
| Duplicate key                    | Last write wins.                                            |
| Line without `=`                 | Silently skipped (debug log entry).                         |
| `KEY="unterminated`              | Throws `.dotEnvParseError(path:line:reason:"unmatched quote")`. |
| `$VAR` interpolation             | Not supported in v1 — `$VAR` becomes a literal value.       |
| Multi-line values                | Not supported in v1.                                        |

### 5.4 Required-value missing — error contract

When `requireString("OUTPUT_PATH")` returns nil after exhausting all four
sources, the resolver MUST throw:

```swift
throw MacrecError.missingRequiredConfig(
    key: "OUTPUT_PATH",
    sourcesChecked: ["--output", "./.env", "~/.tool-agents/macrec/.env", "shell"]
)
```

The CLI prints (to stderr) and exits 78:

```
macrec: missing required config: OUTPUT_PATH (checked: --output, ./.env, ~/.tool-agents/macrec/.env, shell)
hint: Set --output on the command line, or define OUTPUT_PATH in ./.env, ~/.tool-agents/macrec/.env, or your shell environment.
```

---

## Section 6 — Logging Contract

### 6.1 Default log format

`StreamLogHandler.standardError(label:)` produces lines of the form:

```
2026-04-26T13:45:01+0300 info macrec.session : recording started; output=/Users/me/test.m4a layout=mixed format=m4a
```

Format components: ISO8601 timestamp with timezone, level, label
(subsystem), `:`, free-form message. Metadata key=value pairs are appended
when supplied via `logger.info("...", metadata: [...])`.

### 6.2 Subsystem strings

| Subsystem                     | Owner                              |
|-------------------------------|------------------------------------|
| `macrec.cli`                  | `RootCommand`, subcommands         |
| `macrec.bootstrap`            | `ToolAgentsBootstrap`              |
| `macrec.config`               | `ConfigResolver`, `DotEnvParser`   |
| `macrec.permissions`          | `PermissionGate` & helpers         |
| `macrec.devices`              | `AudioDeviceEnumerator`            |
| `macrec.capture.system`       | `SCKitSystemAudioSource`           |
| `macrec.capture.system.watchdog` | `SCKitSystemAudioSource` watchdog Task |
| `macrec.capture.mic`          | `AVMicrophoneSource`               |
| `macrec.aligner`              | `HostClockAligner`                 |
| `macrec.mixer`                | `BufferSummer`                     |
| `macrec.recorder.m4a`         | `M4ARecorder`                      |
| `macrec.recorder.wav`         | `WAVRecorder`                      |
| `macrec.recorder.caf`         | `CAFRecorder`                      |
| `macrec.session`              | `RecordingSession`                 |
| `macrec.signal`               | `SignalHandler`                    |

### 6.3 Event → level mapping

| Event                                                                        | Level     | Subsystem                    |
|------------------------------------------------------------------------------|-----------|------------------------------|
| Recording started                                                            | `.info`   | `macrec.session`             |
| Recording stopped (reason)                                                   | `.info`   | `macrec.session`             |
| Output file finalized successfully                                           | `.info`   | `macrec.session`             |
| Per-source RMS heartbeat (FR-23, every 10 s)                                 | `.debug`  | `macrec.session`             |
| Permission state on startup                                                  | `.debug`  | `macrec.permissions`         |
| First audio buffer arrived (per source)                                      | `.debug`  | `macrec.capture.{system,mic}`|
| SCStream silent-stop detected, restarting                                    | `.warning`| `macrec.capture.system.watchdog` |
| SCStream restart count exceeded                                              | `.error`  | `macrec.capture.system.watchdog` |
| `isReadyForMoreMediaData == false` → buffer dropped                          | `.warning`| `macrec.recorder.m4a`        |
| `finishWriting` completed                                                    | `.info`   | `macrec.recorder.{m4a,wav,caf}` |
| `finishWriting` timeout fired                                                | `.error`  | `macrec.recorder.m4a`        |
| Aligner emitted a synthesized silence-fill buffer                            | `.debug`  | `macrec.aligner`             |
| Aligner detected gap > 100 ms                                                | `.warning`| `macrec.aligner`             |
| `.env` parse error                                                           | `.error`  | `macrec.config`              |
| Multiple mic devices match by name (OQ-8)                                    | `.warning`| `macrec.devices`             |

### 6.4 No-PII rule (NFR-7)

Log messages MUST NOT contain raw audio sample bytes, device serial
numbers, MAC addresses, or absolute home-directory paths beyond the
specific user-provided `--output` path. RMS heartbeat values are
aggregate amplitudes (a single Float per source per 10 s), which do
NOT constitute PII.

---

## Section 7 — File Outputs — Coder Recipes

### 7.1 `SCStreamConfiguration` literal (verbatim, `docs/research/scstream-audio-only.md` §1, §2)

```swift
import ScreenCaptureKit
import CoreMedia

func makeAudioOnlyConfiguration(sampleRate: Int = 48_000,
                                channelCount: Int = 2) -> SCStreamConfiguration {
    let cfg = SCStreamConfiguration()

    // Audio knobs
    cfg.capturesAudio              = true
    cfg.excludesCurrentProcessAudio = true
    cfg.sampleRate                 = sampleRate    // 48_000 by spec; FR-7 default
    cfg.channelCount               = channelCount  // 2 by spec; FR-9 default

    // Video suppression — values per `docs/research/scstream-audio-only.md` §2.1
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
    cfg.width                = 2
    cfg.height               = 2
    cfg.queueDepth           = 5
    cfg.showsCursor          = false
    // Leave pixelFormat at default (kCVPixelFormatType_32BGRA).

    // Do NOT set captureMicrophone or microphoneCaptureDeviceID
    // (macOS 15+ only, and we capture mic via AVCaptureSession).
    return cfg
}
```

### 7.2 `SCContentFilter` literal

```swift
func makeSystemAudioFilter() async throws -> SCContentFilter {
    let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true
    )
    guard let display = content.displays.first else {
        throw MacrecError.scStreamFailedToStart(
            underlying: NSError(domain: "macrec", code: -1,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "no SCDisplay available"])
        )
    }
    return SCContentFilter(
        display: display,
        excludingApplications: [],
        exceptingWindows: []
    )
}
```

### 7.3 Watchdog parameters (FR-19)

| Constant                  | Value         | Rationale (research doc §3 / §8 OI-3)              |
|---------------------------|---------------|----------------------------------------------------|
| `pollInterval`            | 5 s           | Balances detection latency against cost.           |
| `stalenessThreshold`      | 10 s          | Two missed polls.                                  |
| `restartWindow`           | 60 s          | Sliding window for restart-count cap.              |
| `maxRestartsInWindow`     | 3             | Heuristic; revisit during Phase 10.                |

### 7.4 `M4ARecorder.outputSettings` (verbatim, `docs/research/avassetwriter-aac.md` §1.1)

```swift
import AVFoundation

var channelLayout = AudioChannelLayout()
memset(&channelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo

let outputSettings: [String: Any] = [
    AVFormatIDKey:          Int(kAudioFormatMPEG4AAC),
    AVSampleRateKey:        sampleRate,                // options.sampleRate
    AVNumberOfChannelsKey:  2,
    AVEncoderBitRateKey:    bitrateKbps * 1_000,       // options.bitrate * 1000
    AVChannelLayoutKey:     Data(bytes: &channelLayout,
                                 count: MemoryLayout<AudioChannelLayout>.size)
]

let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
writer.shouldOptimizeForNetworkUse = true                       // FR-21
writer.movieFragmentInterval = CMTime(value: 2, timescale: 1)   // FR-21

let audioInput = AVAssetWriterInput(mediaType: .audio,
                                    outputSettings: outputSettings)
audioInput.expectsMediaDataInRealTime = true
writer.add(audioInput)

guard writer.startWriting() else {
    throw MacrecError.writerFailedToStart(underlying: writer.error
        ?? NSError(domain: "M4ARecorder", code: -1))
}
writer.startSession(atSourceTime: sessionStart)   // sessionStart = host-clock at RecordingSession.start()
```

### 7.5 `WAVRecorder.outputSettings` (verbatim, `docs/research/avassetwriter-aac.md` §1.2)

```swift
let settings: [String: Any] = [
    AVFormatIDKey:               kAudioFormatLinearPCM,
    AVSampleRateKey:             Double(sampleRate),         // 48_000.0
    AVNumberOfChannelsKey:       2,
    AVLinearPCMBitDepthKey:      bitDepth,                   // 16 or 24
    AVLinearPCMIsFloatKey:       false,
    AVLinearPCMIsBigEndianKey:   false,                      // WAV = little-endian
    AVLinearPCMIsNonInterleaved: false                       // WAV = interleaved
]
let file = try AVAudioFile(forWriting: outputURL,
                           settings: settings,
                           commonFormat: .pcmFormatFloat32,
                           interleaved: false)
```

### 7.6 `CAFRecorder.outputSettings` (verbatim, `docs/research/avassetwriter-aac.md` §1.3)

```swift
let settings: [String: Any] = [
    AVFormatIDKey:               kAudioFormatLinearPCM,
    AVSampleRateKey:             Double(sampleRate),         // 48_000.0
    AVNumberOfChannelsKey:       2,
    AVLinearPCMBitDepthKey:      bitDepth,                   // 24 by default
    AVLinearPCMIsFloatKey:       false,
    AVLinearPCMIsBigEndianKey:   true,                       // CAF = big-endian
    AVLinearPCMIsNonInterleaved: false
]
let file = try AVAudioFile(forWriting: outputURL,
                           settings: settings,
                           commonFormat: .pcmFormatFloat32,
                           interleaved: false)
```

### 7.7 `M4ARecorder.finalize` watchdog (FR-20)

```swift
public func finalize(at sessionEnd: CMTime,
                     timeout: TimeInterval,
                     completion: @escaping (Result<URL, MacrecError>) -> Void) {
    writerQueue.async { [self] in
        guard !isStopping else { return }
        isStopping = true

        guard let writer = self.writer, let input = self.input,
              writer.status == .writing else {
            completion(.success(self.outputURL))
            return
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: sessionEnd)

        let watchdog = DispatchWorkItem { [outputURL] in
            self.logger.error("finishWriting timeout for \(outputURL.path)")
            completion(.failure(.writerFinalizationTimeout(outputURL)))
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: watchdog
        )

        writer.finishWriting { [weak self] in
            watchdog.cancel()
            guard let self else { return }
            if let err = writer.error {
                completion(.failure(.finishWritingFailed(underlying: err)))
            } else {
                completion(.success(self.outputURL))
            }
        }
    }
}
```

---

## Section 8 — Permission Flow on First Run

### 8.1 Decision tree — Screen Recording

```
ScreenRecordingPermission.current()
   │
   ├── .authorized      → proceed
   │
   ├── .notDetermined   → ScreenRecordingPermission.request()
   │                      │
   │                      └── stderr: "Screen Recording permission not yet granted; system prompt has been triggered"
   │                          stderr: "hint: Approve the prompt that just appeared, then re-run macrec start. (Same-process state cannot be re-read; relaunch is required.)"
   │                          exit(75)   // EX_TEMPFAIL
   │
   ├── .denied          → stderr: "Screen Recording permission denied"
   │                      stderr: "hint: Open System Settings > Privacy & Security > Screen Recording and enable macrec, then re-run."
   │                      exit(77)       // EX_NOPERM
   │
   └── .restricted      → (treated as .denied — same stderr, same exit code)
```

### 8.2 Decision tree — Microphone

Identical shape, with strings substituting "Microphone" for "Screen
Recording" and the System Settings path
"System Settings > Privacy & Security > Microphone".

`.notDetermined` invokes `await MicrophonePermission.request()` instead of
the Cg-level call.

### 8.3 Test fixtures

`Tests/MacrecCoreTests/PermissionDetectionTests.swift` runs against
`StubPermissionGate` and asserts the four-by-four matrix of
(screen state × mic state) produces the expected `MacrecError` case and
exit code.

### 8.4 `stop` subcommand permission requirements (added 2026-04-26)

The `stop` subcommand performs **no TCC-protected operations**. It only:
1. Reads the PID file (filesystem read on a path inside the user's home).
2. Calls `kill(pid, 0)` to probe liveness.
3. Calls `kill(pid, SIGTERM)` to request shutdown.
4. Polls `kill(pid, 0)` to detect exit.

None of these operations touch the screen-recording or microphone TCC
namespaces. `StopCommand` therefore SKIPS the `PermissionGate` checks
entirely — it is safe to invoke from a context (e.g. SSH session, cron
job) where TCC prompts cannot be displayed.

`ListDevicesCommand` and `CheckPermissionsCommand` are unaffected by
the 2026-04-26 detach-mode update — they remain foreground-only and
do not interact with the PID file.

---

## Section 9 — CLI Surface

### 9.1 `macrec --help`

```
OVERVIEW: Simultaneously record macOS system audio and microphone audio.

USAGE: macrec <subcommand>

SUBCOMMANDS:
  start                   Begin a recording. Stop with Ctrl-C (SIGINT), SIGTERM,
                          or 'macrec stop' (when started with --detach).
  stop                    Stop a detached recording started with 'macrec start --detach'.
  list-devices            List input audio devices.
  check-permissions       Print Screen Recording and Microphone permission state.

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.

  See 'macrec <subcommand> --help' for subcommand-specific options.
```

### 9.2 `macrec start --help`

```
OVERVIEW: Begin a recording. Stop with Ctrl-C (SIGINT) or SIGTERM (foreground),
or with 'macrec stop' (when started with --detach).

USAGE: macrec start [<options>]

OPTIONS:
  -o, --output <output>   Output file path (required).
  --format <format>       Output format (m4a | wav | caf). Default: m4a.
  --layout <layout>       Track layout (mixed | split | stereo-split). Default: mixed.
  --sample-rate <sample-rate>
                          Sample rate in Hz (44100 | 48000). Default: 48000.
  --bit-depth <bit-depth> Bit depth (16 | 24, PCM only). Default: 16.
  --bitrate <bitrate>     AAC bitrate in kbps (64-320). Default: 192.
  --mic-device <mic-device>
                          Microphone device name or UID. Default: system default.
  --mic-channel <mic-channel>
                          Stereo-split mic channel (left | right). Default: left.
  --max-duration <max-duration>
                          Auto-stop after N seconds. Default: run until SIGINT.
  --overwrite             Overwrite an existing output file.
  --log-level <log-level> Log verbosity (quiet | info | debug). Default: info.
  --detach                Run the recording in the background (double-fork daemon).
                          The shell prompt returns immediately; PID is written
                          to --pid-file. Stop with 'macrec stop'. (FR-25)
  --pid-file <pid-file>   PID file path for --detach mode.
                          Default: ~/.tool-agents/macrec/macrec.pid.
                          Env: MACREC_PID_FILE. (FR-25/FR-27/FR-28)
  --log-file <log-file>   Log file path for --detach mode (mode 0600, append).
                          Default: ~/.tool-agents/macrec/macrec.log.
                          Env: MACREC_LOG_FILE. (FR-29)
  -h, --help              Show help information.
```

### 9.2a `macrec stop --help` _(added 2026-04-26 — FR-26)_

```
OVERVIEW: Stop a detached recording started with 'macrec start --detach'.

USAGE: macrec stop [<options>]

OPTIONS:
  --pid-file <pid-file>   PID file path of the detached recording.
                          Default: ~/.tool-agents/macrec/macrec.pid.
                          Env: MACREC_PID_FILE.
  --stop-timeout <stop-timeout>
                          Seconds to wait for the recording process to exit
                          cleanly after SIGTERM. Default: 35.
                          Env: MACREC_STOP_TIMEOUT.
  -h, --help              Show help information.

EXIT CODES:
  0   The recording was stopped cleanly and the file was finalized.
  70  The process did not exit within --stop-timeout (MacrecError.stopTimeout).
  75  The PID file referenced a stale PID; the file has been cleaned up
      (MacrecError.staleRecording).
  78  No PID file was found (MacrecError.noActiveRecording).
```

### 9.3 `macrec list-devices --help`

```
OVERVIEW: List input audio devices.

USAGE: macrec list-devices

OPTIONS:
  -h, --help              Show help information.
```

### 9.4 `macrec check-permissions --help`

```
OVERVIEW: Print Screen Recording and Microphone permission state.

USAGE: macrec check-permissions

OPTIONS:
  -h, --help              Show help information.
```

### 9.5 Exit-code table (final, locked)

| Code | Symbolic         | `MacrecError` cases producing it                                                                                                                                | Meaning                                  |
|------|------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------|
| 0    | _success_        | _normal completion or SIGINT-finalized recording or clean `stop`_                                                                                              | success                                  |
| 1    | _generic_        | `unknown`, `ioError`, `finishWritingFailed`                                                                                                                    | generic / unexpected runtime failure     |
| 2    | _partial output_ | `writerFinalizationTimeout`                                                                                                                                    | finalization timed out (file may be partial) |
| 64   | `EX_USAGE`       | `invalidConfigValue`, `dotEnvParseError`                                                                                                                       | usage error / invalid argument           |
| 66   | `EX_NOINPUT`     | `outputParentMissing`, `outputAlreadyExists`, `pidFileWriteFailed`                                                                                              | I/O / output path / PID file write error |
| 70   | `EX_SOFTWARE`    | `noInputDevicesAvailable`, `scStreamFailedToStart`, `scStreamSilentStopExceeded`, `avCaptureFailedToStart`, `writerFailedToStart`, `stopTimeout`                | runtime failure                          |
| 75   | `EX_TEMPFAIL`    | `screenRecordingPermissionNotDetermined`, `microphonePermissionNotDetermined`, `staleRecording`                                                                | retryable (re-run after granting prompt or after a fresh `start`) |
| 77   | `EX_NOPERM`      | `screenRecordingPermissionDenied`, `microphonePermissionDenied`, `microphonePermissionRestricted`                                                              | permission denied                        |
| 78   | `EX_CONFIG`      | `missingRequiredConfig`, `micDeviceNotFound`, `alreadyRecording`, `noActiveRecording`                                                                          | configuration / workflow error           |

---

## Section 10 — Test Design

### 10.1 Protocol-injected fake-source strategy

`SystemAudioSource`, `MicrophoneSource`, `PermissionGate`, and
`AudioDeviceEnumerating` are all protocols. Production code (`StartCommand`)
constructs the live concrete types; test code (`MacrecCoreTests`) constructs
fakes:

- `FakeAudioSource` (lives in `MacrecCore`, used by both fakes and tests).
- `StubPermissionGate` (lives in `Tests/MacrecCoreTests/Fakes/`).
- `FakeAudioDeviceEnumerator` (lives in `Tests/MacrecCoreTests/Fakes/`).

`RecordingSession` tests construct the orchestrator with two
`FakeAudioSource` instances at known frequencies (440 Hz mic, 880 Hz
system) and assert the encoded output's duration, file existence, and
(for `stereo-split`) per-channel RMS.

### 10.2 Unit-testable vs. E2E-only behaviors

| Behavior                                                  | Unit test? | Notes                                                        |
|-----------------------------------------------------------|------------|--------------------------------------------------------------|
| Configuration precedence (FR-12, AC-9)                    | yes        | Table-driven `ConfigResolverTests`.                          |
| Tool-folder bootstrap (FR-13, AC-10)                      | yes        | `ToolAgentsBootstrapTests` with temp HOME.                   |
| `.env` parser syntax                                       | yes        | `DotEnvParserTests`.                                         |
| `RecordingOptions` validation (FR-17)                     | yes        | `RecordingOptionsTests`.                                     |
| `MacrecError` exit-code mapping (FR-18)                   | yes        | `MacrecErrorTests`.                                          |
| Permission state branching                                | yes        | `PermissionDetectionTests` with `StubPermissionGate`.        |
| Device enumeration HAL bindings (live)                    | manual     | Cannot mock Core Audio HAL in CI; smoke-tested via `list-devices`. |
| FakeAudioSource buffer cadence                            | yes        | `FakeAudioSourceTests`.                                      |
| Aligner gap-fill, drift bound, monotonic PTS              | yes        | `HostClockAlignerTests`.                                     |
| `SilenceBufferFactory` zero bytes, valid timing           | yes        | `SilenceBufferFactoryTests`.                                 |
| `BufferSummer` byte-exact sum                             | yes        | `BufferSummerTests`.                                         |
| `M4ARecorder` round-trip with FakeAudioSource             | yes        | `M4ARecorderTests` (writes a real file).                     |
| `WAVRecorder` / `CAFRecorder` round-trip                  | yes        | `WAVRecorderTests`, `CAFRecorderTests`.                      |
| `RecordingSession` end-to-end with fake sources           | yes        | `RecordingSessionTests`.                                     |
| SCStream live capture                                     | E2E        | `test_scripts/e2e-30s-mixed.sh`.                             |
| AVCapture live mic                                         | E2E        | Same script.                                                 |
| TCC permissions in production                             | E2E        | Cannot grant in CI.                                          |
| 60-minute stability + drift                               | E2E        | `test_scripts/e2e-60min-stability.sh`.                       |
| SIGINT finalization (real signal)                         | E2E        | `test_scripts/e2e-sigint-finalize.sh`.                       |
| `--layout split` / `--layout stereo-split` real audio      | E2E        | dedicated scripts.                                           |
| `--max-duration` cap                                       | unit + E2E | RecordingSessionTests covers the timer; E2E confirms wall-clock duration. |

### 10.3 `test_scripts/` outline (Phase L will author them)

Five shell scripts, each a thin wrapper around `swift run macrec`:

| Script                                  | Purpose                                  | Expected `afinfo` (key lines)                                            |
|-----------------------------------------|------------------------------------------|--------------------------------------------------------------------------|
| `e2e-30s-mixed.sh`                      | AC-4 — 30 s mixed recording              | `2 ch, 48000 Hz, 'aac '`, `bit rate: 192000`, `estimated duration: ~30 s`, `optimized` |
| `e2e-60min-stability.sh`                | AC-11, AC-12, NFR-3                       | `estimated duration: ~3600 s ±1 s`, no priming inflation                 |
| `e2e-sigint-finalize.sh`                | AC-7 — SIGINT-finalized file is playable | `optimized`, `estimated duration` matches wall-clock-at-SIGINT           |
| `e2e-layout-split.sh`                   | AC-5 — two output files                  | both files: AAC stereo, similar `estimated duration`                     |
| `e2e-layout-stereo-split.sh`            | AC-6 — channel pinning                   | `Channel layout: Stereo (L R)`; visual inspection in Audacity            |

Each script `set -e`'s, runs the binary, executes `afinfo` against the
output, and `grep`s the expected lines.

---

## Section 11 — Implementation-Unit Independence Map for Phase 6

> One coder briefing per phase. Each briefing lists owned files, upstream
> dependencies (with section refs), MUST-implement vs. MAY-defer, and
> owned tests.

### 11.1 Phase A — SPM scaffold (sequential, single coder)

**Owned files:**
- `Package.swift` (verbatim from `docs/design/plan-001-recording-tool.md` §A).
- `.gitignore` (verbatim from same).
- `Issues - Pending Items.md` (skeleton: header + Pending and Completed sections, both empty).
- All source-file stubs under `Sources/macrec/` and `Sources/MacrecCore/` (each `import Foundation` + a single `// MARK: TODO(plan-001 §<phase>)`).
- All test-file stubs under `Tests/MacrecCoreTests/` (each an empty `XCTestCase` subclass).
- `Sources/MacrecCore/Resources/.gitkeep`.

**Dependencies:** none.

**MUST:** `swift build`, `swift test`, `swift run macrec --help` all succeed.
**MAY DEFER:** _(nothing — this is a build gate)_

**Owned tests:** none yet (the test target compiles).

---

### 11.2 Phase B — Bootstrap + Config (Wave 2; runs in parallel with C, D, E)

**Owned files (finalize):**
- `Sources/MacrecCore/Bootstrap/ToolAgentsBootstrap.swift` (§2.2)
- `Sources/MacrecCore/Config/DotEnvParser.swift` (§2.3)
- `Sources/MacrecCore/Config/ConfigResolver.swift` (§2.4)
- `Sources/MacrecCore/Config/RecordingOptions.swift` (§2.4)

**Upstream dependencies:**
- `MacrecError` (§2.1) — Phase C is delivering; cross-coordinate via the
  protocol contract: only the cases `missingRequiredConfig`,
  `invalidConfigValue`, `dotEnvParseError`, `ioError` are needed by Phase B.

**MUST:**
- Implement the four-source precedence merge (§5.1).
- Implement the `.env` syntax in §5.3.
- Validate every value per FR-17 (§3.1 / §5.2).
- Bootstrap creates dir at 0700 and seeds `.env` at 0600 (FR-13).
- Re-chmod on every invocation.

**MAY DEFER:**
- `$VAR` interpolation in `.env`. Mark with
  `// MARK: TODO(plan-001 §B - v2 — env-var interpolation)`.

**Owned tests:**
- `Tests/MacrecCoreTests/ToolAgentsBootstrapTests.swift`
- `Tests/MacrecCoreTests/DotEnvParserTests.swift`
- `Tests/MacrecCoreTests/ConfigResolverTests.swift`
- `Tests/MacrecCoreTests/RecordingOptionsTests.swift`

---

### 11.3 Phase C — Logging + Errors (Wave 2)

**Owned files (finalize):**
- `Sources/MacrecCore/Logging/LoggerFactory.swift` (§2.5)
- `Sources/MacrecCore/Errors/MacrecError.swift` (§2.1)

**Upstream dependencies:** none beyond Foundation + swift-log.

**MUST:**
- All `MacrecError` cases listed in §2.1.
- Locked `description` and `remediation` strings (Phase 9 will assert verbatim).
- Exit-code mapping per §9.5 / FR-18.
- `LoggerFactory.bootstrap` is idempotent.
- All subsystem strings in §6.2 are reachable as constants in
  `LoggerFactory` (e.g. `LoggerFactory.Subsystem.captureSystem = "macrec.capture.system"`).

**MAY DEFER:** _(nothing)_

**Owned tests:** `Tests/MacrecCoreTests/MacrecErrorTests.swift` —
exit-code mapping, no-PII assertion (description must not contain
substrings from a banned list: `mNumberChannels`, `kAudio`, fixture sample
hex, etc.).

---

### 11.4 Phase D — Permissions + Devices (Wave 2)

**Owned files (finalize):**
- `Sources/MacrecCore/Permissions/PermissionGate.swift` (§2.6)
- `Sources/MacrecCore/Permissions/ScreenRecordingPermission.swift` (§2.6)
- `Sources/MacrecCore/Permissions/MicrophonePermission.swift` (§2.6)
- `Sources/MacrecCore/Devices/AudioDeviceEnumerator.swift` (§2.7)

**Upstream dependencies:** `MacrecError` (Phase C — needs
`micDeviceNotFound`, `noInputDevicesAvailable`).

**MUST:**
- All four `PermissionState` values exposed.
- `ScreenRecordingPermission.current()` uses `CGPreflightScreenCaptureAccess`.
- `MicrophonePermission` uses `AVCaptureDevice.authorizationStatus`/`requestAccess`.
- `AudioDeviceEnumerator` uses Core Audio HAL (no AVCaptureDevice listing).
- `resolve` follows OQ-8 algorithm (UID first, name fallback case-insensitive,
  warn on multi-match, throw `micDeviceNotFound`).

**MAY DEFER:**
- Live HAL tests (cannot run in CI). Mark with `// MARK: TODO(plan-001 §10 manual)`.

**Owned tests:**
- `Tests/MacrecCoreTests/PermissionDetectionTests.swift` (against `StubPermissionGate`).
- `Tests/MacrecCoreTests/AudioDeviceEnumeratorTests.swift` (against `FakeAudioDeviceEnumerator`).

---

### 11.5 Phase E — Capture protocols + fakes (Wave 2)

**Owned files (finalize):**
- `Sources/MacrecCore/Capture/SystemAudioSource.swift` (protocol; §2.8)
- `Sources/MacrecCore/Capture/MicrophoneSource.swift` (protocol; §2.8)
- `Sources/MacrecCore/Capture/FakeAudioSource.swift` (§2.8.3)

**Upstream dependencies:** none beyond CoreMedia.

**MUST:**
- The `AudioSource` protocol with the exact signatures in §2.8.
- `CaptureBuffer` envelope.
- `FakeAudioSource` produces non-interleaved Float32 sine waves with
  monotonically increasing PTSs derived from `CMClock.hostTimeClock`.
- Convenience factories `makeSystem440Hz()`, `makeMic880Hz()`.

**MAY DEFER:** _(nothing)_

**Owned tests:** `Tests/MacrecCoreTests/FakeAudioSourceTests.swift`.

---

### 11.6 Phase F — Aligner + Silence + Mixer (Wave 3a, after B/C/E)

**Owned files (finalize):**
- `Sources/MacrecCore/Aligning/HostClockAligner.swift` (§2.9)
- `Sources/MacrecCore/Aligning/SilenceBufferFactory.swift` (§2.9)
- `Sources/MacrecCore/Mixing/BufferSummer.swift` (§2.9)

**Upstream dependencies:** Phase C (`MacrecError`), Phase E (`CaptureBuffer`).

**MUST:**
- Aligner algorithm in §2.9 (per-source `nextExpectedAudioTime`,
  ring buffer cap = 10 buffers ≈ 200 ms, lockstep drain, monotonic PTS).
- Internal timestamp normalization to timescale `48_000` at ingress (R-1).
- Silence factory verbatim per `docs/research/avassetwriter-aac.md` §4.3.
- BufferSummer pointwise float add with clamp to `[-1, +1]`.

**MAY DEFER:**
- vDSP-accelerated sum. Note with `// MARK: TODO(plan-001 §F - perf)`.

**Owned tests:**
- `Tests/MacrecCoreTests/HostClockAlignerTests.swift` (drift bound, gap fill, monotonic PTS).
- `Tests/MacrecCoreTests/SilenceBufferFactoryTests.swift`.
- `Tests/MacrecCoreTests/BufferSummerTests.swift`.

---

### 11.7 Phase G — Recorder protocol + M4ARecorder (Wave 3b, after F)

**Owned files (finalize):**
- `Sources/MacrecCore/Encoding/Recorder.swift` (§2.10)
- `Sources/MacrecCore/Encoding/M4ARecorder.swift` (§2.10, recipe §7.4)

**Upstream dependencies:** Phase C (`MacrecError`), Phase F
(`SilenceBufferFactory` for synthetic test buffers).

**MUST:**
- `Recorder` protocol per §2.10.
- `M4ARecorder` uses the verbatim outputSettings in §7.4.
- `shouldOptimizeForNetworkUse = true` (FR-21).
- `movieFragmentInterval = CMTime(value: 2, timescale: 1)` (FR-21).
- `expectsMediaDataInRealTime = true`.
- `start(at:)` calls `startWriting` then `startSession(atSourceTime:)`.
- `append` honors `isReadyForMoreMediaData`; drops + warns on back-pressure.
- `finalize` runs the 30 s watchdog (§7.7); on timeout returns
  `.failure(.writerFinalizationTimeout(url))` (FR-20).

**MAY DEFER:**
- `overallDurationHint` for `--max-duration` runs. Mark with
  `// MARK: TODO(plan-001 §G - perf)`.

**Owned tests:** `Tests/MacrecCoreTests/M4ARecorderTests.swift` (round
trip 5 s of 440 Hz; metadata assertions; white-box check that
`shouldOptimizeForNetworkUse` and `movieFragmentInterval` were set).

---

### 11.8 Phase H — WAV + CAF Recorders (Wave 3b, after F; parallel with G)

**Owned files (finalize):**
- `Sources/MacrecCore/Encoding/WAVRecorder.swift` (recipe §7.5)
- `Sources/MacrecCore/Encoding/CAFRecorder.swift` (recipe §7.6)
- `Sources/MacrecCore/Encoding/CMSampleBufferAudioConversion.swift` (§2.10)

**Upstream dependencies:** Phase C, Phase F, Phase G (Recorder protocol).

**MUST:**
- Settings dicts constructed manually (do NOT pass `buffer.format.settings`).
- `start(at:)` is a no-op (record `sessionStart` for log diagnostics only).
- `append` converts CMSampleBuffer → AVAudioPCMBuffer via
  `CMSampleBufferAudioConversion.toPCMBuffer` and calls
  `AVAudioFile.write(from:)`.
- `finalize` nil-outs the file handle and synchronously calls
  `completion(.success(url))`. No watchdog needed (PCM writes are sync).

**MAY DEFER:** _(nothing)_

**Owned tests:**
- `Tests/MacrecCoreTests/WAVRecorderTests.swift`
- `Tests/MacrecCoreTests/CAFRecorderTests.swift`

---

### 11.9 Phase I — Real capture sources (Wave 4, parallel with J)

**Owned files (finalize):**
- `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift` (§2.8.1)
- `Sources/MacrecCore/Capture/AVMicrophoneSource.swift` (§2.8.2)

**Upstream dependencies:** Phases C, D, E.

**MUST:**
- `SCStreamConfiguration` per §7.1.
- `SCContentFilter` per §7.2.
- Watchdog with parameters from §7.3 (FR-19).
- `didStopWithError` wraps work in `Task { ... }` (FR-19).
- `.notDetermined` `SCStreamError` matched by raw domain string + code only.
- `AVCaptureSession.synchronizationClock = CMClockGetHostTimeClock()` (FR-22).
- One long-lived `AVAudioConverter` per source (avoid 2112-frame priming reset).

**MAY DEFER:**
- `NSWorkspace.willSleepNotification` integration (research OI-7). Mark
  in `Issues - Pending Items.md`.

**Owned tests:**
- `Tests/MacrecCoreTests/SCKitSystemAudioSourceCompilationTest.swift` (compile-only).
- `Tests/MacrecCoreTests/AVMicrophoneSourceCompilationTest.swift` (compile-only).

---

### 11.10 Phase J — RecordingSession orchestrator (Wave 4)

**Owned files (finalize):**
- `Sources/MacrecCore/RecordingSession.swift` (§2.11)
- `Sources/MacrecCore/SignalHandler.swift` (§2.11)

**Upstream dependencies:** B, C, D, E, F, G, H.

**MUST:**
- `start()` algorithm in §2.11 (permissions → output validation →
  sessionStart capture → recorders → aligner → wire → start sources →
  start recorders → max-duration timer → heartbeat).
- `stop(reason:completion:)` algorithm (idempotent, drains aligner,
  finalizes recorders, collects in DispatchGroup, exits with first error).
- `SignalHandler.install` follows §1.4 of the avassetwriter research doc:
  `Darwin.signal(SIGINT, SIG_IGN)` first, then `DispatchSourceSignal`.
- RMS heartbeat (FR-23) at debug level only.
- **PID file lifecycle hook (FR-25/FR-27 — added 2026-04-26)**: when
  `RecordingOptions.runMode == .detached`, call
  `PidFile.write(getpid(), to: options.pidFilePath)` IMMEDIATELY after
  `recorder.start(at:)` completes (step 9 in §2.11) and BEFORE the
  first capture buffer is enqueued. On every clean exit path
  (`SIGINT`, `SIGTERM`, `--max-duration` cap, finalize-success), best-
  effort `PidFile.remove(options.pidFilePath)` in the completion
  handler. Crashes leave the file as a stale marker that the next
  `stop` call cleans up. See §14.1 / §14.7.

**MAY DEFER:**
- FFT-based frequency assertion in `RecordingSessionTests` (downgrade to
  duration + non-zero size if FFT proves brittle).

**Owned tests:** `Tests/MacrecCoreTests/RecordingSessionTests.swift` —
mixed/split/stereo-split layouts, signal-driven stop, max-duration,
**PID file lifecycle in detached mode (write on start, remove on each
clean exit path)**.

---

### 11.11 Phase K — CLI shell (Wave 5) — _expanded 2026-04-26 per OQ-3 override_

**Owned files (finalize):**
- `Sources/macrec/main.swift`
- `Sources/macrec/Commands/RootCommand.swift`
- `Sources/macrec/Commands/StartCommand.swift`
- `Sources/macrec/Commands/StopCommand.swift` _(NEW — FR-26)_
- `Sources/macrec/Commands/ListDevicesCommand.swift`
- `Sources/macrec/Commands/CheckPermissionsCommand.swift`
- `Sources/macrec/Daemonization/Daemonizer.swift` _(NEW — FR-25)_
- `Sources/macrec/Daemonization/PidFile.swift` _(NEW — FR-25/FR-27/FR-28)_

**Upstream dependencies:** Phases B (config keys for `--detach`,
`--pid-file`, `--log-file`, `--stop-timeout`), C (the 5 new
`MacrecError` cases), D, J (PID-file write/remove hook in
RecordingSession).

**MUST:**
- `--help` text per §9.1 / §9.2 / §9.2a / §9.3 / §9.4 (regression-tested verbatim).
- `--output -` rejected with `MacrecError.invalidConfigValue` (OQ-5).
- `main.swift` calls `ToolAgentsBootstrap.ensureToolFolder(toolName: "macrec")`
  BEFORE dispatching to `RootCommand` (FR-13).
- Exit codes per §9.5 (including the 5 new mappings).
- **FR-25 — Daemonizer.detach()**: classic POSIX double-fork sequence
  (see §14.2). Use `Darwin.fork`, `Darwin.setsid`, `Darwin._exit`,
  `Darwin.chdir`, `Darwin.umask`, `Darwin.dup2`, `Darwin.close`.
  The intermediate parent MUST `_exit(0)` (NOT `exit(0)` — see §14.2).
- **FR-26 — StopCommand**: implement the four-case decision tree from
  §14.3. Poll `kill(pid, 0)` every 100 ms; respect `--stop-timeout`.
- **FR-27 — PID file lifecycle hook in RecordingSession**: collaborate
  with Phase J — `RecordingSession.start()` writes the PID file when
  `runMode == .detached`; `RecordingSession.stop()` removes it on
  every clean exit path. (J owns the hook; K owns the
  `PidFile.write/read/remove/isAlive` helpers.)
- **FR-28 — Already-recording guard**: only enforced in detach mode;
  foreground `start` is exempt. Stale PID files are auto-cleaned.
- **FR-29 — Detach log file**: open with `O_WRONLY | O_CREAT | O_APPEND`,
  mode `0600`. Re-bootstrap `LoggerFactory` AFTER the
  `dup2(logFd, STDERR_FILENO)` so the swift-log handler sees the new
  fd.
- **`stop` subcommand has NO TCC permission preflight** (see §8.4).

**MAY DEFER:**
- Log-file rotation in detach mode (FR-29 known limitation; v2).

**Owned tests:**
- `Tests/MacrecCoreTests/CLIArgumentParsingTests.swift` — extend with
  the new flags (`--detach`, `--pid-file`, `--log-file`,
  `--stop-timeout`).
- `Tests/MacrecCoreTests/StopCommandTests.swift` — simulate the four
  `stop` cases against an injectable `ProcessSignaler` fake (no real
  `kill` syscall in unit tests).
- `Tests/MacrecCoreTests/PidFileTests.swift` — round-trip
  write/read/remove; assert mode `0600`; assert atomic-rename
  semantics; assert stale detection.

**Special note on Daemonizer testing:** the double-fork itself cannot
be unit-tested without forking the test process; coverage falls to
`test_scripts/e2e-detach-stop.sh` and
`test_scripts/e2e-detach-orphan-check.sh` (Phase L). The unit-test
surface for Phase K targets `PidFile` and `StopCommand`'s decision
tree only.

---

### 11.12 Phase L — Documentation (Wave 6, terminal)

**Owned files (finalize):**
- `docs/tools/macrec.md` (FR-16 XML format)
- `CLAUDE.md` (append `macrec` entry under existing `## Tools` section ONLY)
- `docs/design/configuration-guide.md`
- `Issues - Pending Items.md` (populate with risks R-1..R-13 from plan-001 §6 and OI-1..OI-7 from research docs)
- `test_scripts/e2e-30s-mixed.sh`
- `test_scripts/e2e-60min-stability.sh`
- `test_scripts/e2e-sigint-finalize.sh`
- `test_scripts/e2e-layout-split.sh`
- `test_scripts/e2e-layout-stereo-split.sh`

**Upstream dependencies:** all of A–K.

**MUST:**
- All required docs satisfy the `<configuration-guide>` rules in CLAUDE.md.
- The CLAUDE.md edit is **strictly additive** — append a single bullet under
  the existing `## Tools` section. Do not modify the
  `<structure-and-conventions>` block or `Exception 001`.

**MAY DEFER:** _(nothing — terminal phase)_

**Owned tests:** _(none — docs are validated by Phase 10 manual checks)_.

---

## Section 12 — Architectural Decision Records

| ADR  | Decision                                                                              | One-line rationale                                                                                                                          | Driver                                          |
|------|---------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------|
| 001  | Implementation language = Swift                                                        | User-approved Exception 001; native macOS frameworks are Swift/Obj-C only                                                                    | `CLAUDE.md` Exception 001                       |
| 002  | macOS 14.0+ minimum                                                                    | Cleaner SCStream audio-only config; user is on macOS 15+                                                                                      | OQ-1; `docs/reference/investigation-recording-tool.md` §1 |
| 003  | Swift Package Manager + library target                                                 | NFR-9 mandates a library so a future menu-bar UI reuses the engine                                                                            | NFR-9                                           |
| 004  | System audio = SCStream audio-only; `width=2, height=2`, `minimumFrameInterval = CMTime(1, .max)` | Production-validated by Azayaka; lowest CPU footprint for audio-only path                                                                  | `docs/research/scstream-audio-only.md` §1, §2.1 |
| 005  | Microphone = AVCaptureSession with `synchronizationClock = CMClockGetHostTimeClock()`  | Settable sync clock + uniform CMSampleBuffer pipeline + reliable Bluetooth & USB device support                                              | `docs/reference/investigation-recording-tool.md` §2; FR-22 |
| 006  | Internal canonical format = Float32 / 48 kHz / stereo non-interleaved                  | SCStream native format; AVAudioConverter cleanest target; mixing by pointwise float add is trivial                                           | `docs/reference/investigation-recording-tool.md` §3 |
| 007  | `m4a` writer = AVAssetWriter (NOT AVAudioFile)                                         | AVAudioFile ignores `AVEncoderBitRateKey` for compressed formats                                                                              | `docs/research/avassetwriter-aac.md` §1.1 / §6.1 |
| 008  | `wav` / `caf` writer = AVAudioFile                                                     | Simpler API; no encoder knobs; correct PCM behavior                                                                                            | `docs/research/avassetwriter-aac.md` §6.2 / §6.3 |
| 009  | Mixing = manual buffer sum (BufferSummer); no AVAudioEngine mixer                      | Both inputs are already canonical Float32; AVAudioEngine adds glue + the speaker-feedback footgun                                            | `docs/reference/investigation-recording-tool.md` §3 |
| 010  | One AVAudioConverter per source per session, long-lived                                | Recreating it drops 2112 priming frames and produces silence runs                                                                             | `docs/reference/investigation-recording-tool.md` §3 |
| 011  | Aligner = host-clock + drift correction + silence fill (`HostClockAligner`)             | Two-clock domain unified by FR-22; gaps inevitable per Nonstrict §15                                                                          | NFR-4; `docs/research/scstream-audio-only.md` §15 |
| 012  | SCStream watchdog: 5 s poll, 10 s threshold, 3-restart-in-60 s fatal                   | `replayd` silent-stop bug confirmed in research; matches Azayaka heuristic                                                                    | FR-19; `docs/research/scstream-audio-only.md` §3 |
| 013  | `didStopWithError` wraps work in `Task { ... }`                                         | Avoids `swift_getErrorValue` `EXC_BAD_ACCESS` framework bug                                                                                   | `docs/research/scstream-audio-only.md` §3       |
| 014  | M4A: `shouldOptimizeForNetworkUse = true` + `movieFragmentInterval = CMTime(2, 1)`     | Belt-and-suspenders crash recovery: moov-at-front for clean stop; fragments for hard kill                                                   | FR-21; `docs/research/avassetwriter-aac.md` §5.3 |
| 015  | `startSession(atSourceTime: CMClock.hostTimeClock.time)` (uptime PTS)                   | Avoids per-buffer retiming allocations; QuickTime shows non-zero start offset but duration & sync are correct                                 | `docs/research/avassetwriter-aac.md` §2.3       |
| 016  | `finishWriting` 30 s watchdog → exit 2 with partial-file message                       | Bounded finalization time; prevents indefinite hang on degenerate IO                                                                          | FR-20; `docs/research/avassetwriter-aac.md` §5.3 |
| 017  | ~~Foreground-only v1 (no daemon, no PID file, no `stop` subcommand)~~ **OVERRIDDEN 2026-04-26** | Originally ruled foreground-only for state-model simplicity. User overrode: v1 supports BOTH foreground (default) and detached background mode via `--detach` + `stop` subcommand. See ADRs 029-031, FR-25..FR-29, §14. | OQ-3 (override) |
| 029  | Detached background mode via classic POSIX double-fork (NOT `posix_spawn` / `launchctl bootstrap`) | `posix_spawn` requires re-exec'ing the binary and re-resolving every flag/env/TCC state; `launchctl bootstrap` requires a `.plist` agent (wrong UX for an ad-hoc CLI tool). Classic double-fork keeps every framework reference live in-process. | FR-25; OQ-3 override |
| 030  | PID file at `~/.tool-agents/macrec/macrec.pid` (mode 0600, single-line decimal PID)    | Reuses the per-tool durable-defaults folder (FR-13); mode 0600 prevents other users from reading the PID; single-line decimal is the simplest reliable format.                                                | FR-25, FR-27                                    |
| 031  | `staleRecording` exits 75 (`EX_TEMPFAIL`), not 0                                        | The user's intent ("stop the running recording") was not actually fulfilled (there was nothing alive to stop). 75 signals "retryable / informational" — the file has been cleaned up and a fresh `start --detach` will succeed.                                                                              | FR-26; design §14.3                              |
| 018  | SignalHandler = `Darwin.signal(SIGINT, SIG_IGN)` + `DispatchSourceSignal`               | Standard macOS Swift pattern; signal-safe                                                                                                     | `docs/research/avassetwriter-aac.md` §1.4 / §5.1 |
| 019  | CLI parser = swift-argument-parser ≥ 1.5.0                                             | First-party Apple lib; `AsyncParsableCommand` matches our async lifecycle                                                                     | `docs/reference/investigation-recording-tool.md` §5 |
| 020  | Logging = swift-log + `StreamLogHandler.standardError`                                  | Levelled output to stderr; pluggable; Apache-2.0                                                                                              | `docs/reference/investigation-recording-tool.md` §8 |
| 021  | Config = hand-rolled `.env` parser + 4-source resolver                                 | Off-the-shelf packages mutate `ProcessInfo`, breaking the documented precedence                                                              | `docs/reference/investigation-recording-tool.md` §7; FR-12 |
| 022  | No fallbacks for required config; `OUTPUT_PATH` is the only required value              | Project convention (`CLAUDE.md`); user-friendly defaults for every other setting                                                              | OQ-10; FR-14                                    |
| 023  | Device enumeration = Core Audio HAL (not AVCaptureDevice listing)                      | Matches user's mental model from System Settings → Sound; UID is stable across both namespaces                                                | `docs/reference/investigation-recording-tool.md` §2 |
| 024  | Permissions = preflight + request + relaunch UX                                        | Same-process state read returns stale value; relaunch is the only reliable path                                                              | FR-10; `docs/research/scstream-audio-only.md` §6 |
| 025  | Test strategy = protocol-injected fakes + XCTest; E2E in `test_scripts/`                | TCC + live frameworks unmockable in CI; manual procedure repeatable by humans                                                                | NFR-10                                          |
| 026  | Aligner internal timestamps normalized to timescale 48 000 at ingress                  | Mixed-timescale CMTime arithmetic is the most common bug class                                                                                | plan-001 §F R-1                                 |
| 027  | RMS heartbeat every 10 s at `.debug` level when `--log-level debug`                     | Distinguishes silent-capture-failure from legitimate silence                                                                                  | FR-23 / OQ-9                                    |
| 028  | Encoder back-pressure = drop + warn (do NOT queue)                                      | Unbounded queue = unbounded memory; live capture at 192 kbps should never back-pressure on Apple Silicon                                      | `docs/research/avassetwriter-aac.md` §4.6       |

---

## Section 13 — Open Questions Remaining for the User

> Each question carries a recommended locked default (already adopted in
> the design above). The orchestrator should present these to the user via
> `AskUserQuestion` BEFORE Phase 6 begins so any override can be folded
> into the plan with minimal rework. Wording is preserved verbatim where
> the upstream docs supply it.

### 13.1 Refined-request OQs

**OQ-1 — Minimum macOS target: 13.0 vs. 14.0+?**
*Locked default:* **macOS 14.0+**.
*Confirm or override?*

**OQ-2 — CLI binary name (`macrec` / `audiorec` / `recorder` / `dualrec`)?**
*Locked default:* **`macrec`**.
*Confirm or override?*

**OQ-3 — Single-process foreground vs. background daemon for `stop`?**
*Locked default:* ~~Foreground only; SIGINT/SIGTERM stop. No `stop` subcommand in v1.~~
*Resolution (2026-04-26 — user override):* v1 supports **BOTH** foreground (default) and detached background execution via `--detach` and `stop`. See FR-25..FR-29 in `project-functions.md` and §14 below. ADR 017 is superseded by ADRs 029-031.

**OQ-4 — Intel (x86_64) support — universal binary or arm64-only?**
*Locked default:* **Universal binary (arm64 + x86_64)**.
*Confirm or override?*

**OQ-5 — Output to stdout (`--output -`)?**
*Locked default:* **Not in v1; the parser rejects `--output -` with `EX_USAGE`**.
*Confirm or override?*

**OQ-6 — Default track layout when `--layout` is omitted?**
*Locked default:* **`mixed`**.
*Confirm or override?*

**OQ-7 — Default output format when `--format` is omitted?**
*Locked default:* **`m4a` (AAC-LC, 192 kbps, 48 kHz stereo)**.
*Confirm or override?*

**OQ-8 — Mic device selection by name vs. UID?**
*Locked default:* **Either name or UID; UID match wins; name match is case-insensitive; warn on multiple name matches and pick the first by ascending AudioObjectID.**
*Confirm or override?*

**OQ-9 — Behavior when system audio submix is silent?**
*Locked default:* **Per-source RMS heartbeat every 10 s at `--log-level debug` (FR-23).**
*Confirm or override?*

**OQ-10 — Required vs. optional config values?**
*Locked default:* **Required (no default): `--output` / `OUTPUT_PATH`. Defaultable: every other setting per FR-7..FR-9 / §3.1.**
*Confirm or override?*

### 13.2 Research follow-ups (`docs/research/scstream-audio-only.md` §8)

**OI-1 — Minimum reliable `width`/`height` for `SCStreamConfiguration`?**
*Locked default:* **`2`/`2`** (Azayaka-validated).
*Confirm or override (fall back to `32`/`32` if Phase 10 finds init failures)?*

**OI-2 — `CMTimeScale.max` vs. `CMTime(value: 1, timescale: 1)` for `minimumFrameInterval`?**
*Locked default:* **`CMTime(value: 1, timescale: CMTimeScale.max)`** (cleaner; no video frames).
*Confirm or override (fall back to 1 fps if Phase 10 finds audio-callback regressions)?*

**OI-3 — Watchdog restart cap "3 in 60 s"?**
*Locked default:* **3 restarts within 60 s = fatal**.
*Confirm or override (revisit after field testing)?*

### 13.3 Research follow-ups (`docs/research/avassetwriter-aac.md` §7)

**7.1 — Priming with `.zero` session start vs. host-clock session start?**
*Locked default:* **Host-clock session start** (avoids per-buffer retiming allocations); QuickTime shows non-zero start offset but duration & sync are correct.
*Confirm or override (any future downstream phase that needs t=0 timeline)?*

**7.2 — `movieFragmentInterval` × `shouldOptimizeForNetworkUse` interaction?**
*Locked default:* **Both enabled**. Phase 10 verifies via `afinfo` and `mp4info`.
*Confirm or override (drop fragmentation if interaction is found broken)?*

**7.4 — `finishWriting` duration for a 60-minute file?**
*Locked default:* **30 s watchdog timeout**. Phase 10 measures actual duration in `e2e-60min-stability.sh` and tunes if needed.
*Confirm or override?*

---

## Section 14 — Detach mode and `stop` subcommand

> **Added 2026-04-26 — overrides OQ-3 / ADR 017.** v1 ships with BOTH
> foreground (default) and detached background execution. This section
> is the authoritative reference for the run-model state machine, the
> double-fork sequence, the PID file format, and the `stop`
> decision tree.

### 14.1 Decision tree — `start --detach`

```
start --detach --output <out>
   │
   ▼
[1] Resolve pidFilePath via the standard 4-source precedence chain
    (default: ~/.tool-agents/macrec/macrec.pid)
   │
   ▼
[2] PidFile.read(pidFilePath)
       │
       ├── nil (ENOENT)              → continue to [3]
       │
       ├── pid present
       │     │
       │     ├── PidFile.isAlive(pid) == .alive
       │     │      → throw MacrecError.alreadyRecording(pid, pidFilePath)
       │     │      → exit 78 (EX_CONFIG); the running daemon is untouched
       │     │
       │     ├── PidFile.isAlive(pid) == .stale
       │     │      → log warning "removing stale PID file (PID <pid>)"
       │     │      → PidFile.remove(pidFilePath)
       │     │      → continue to [3]
       │     │
       │     └── PidFile.isAlive(pid) == .unknown (EPERM)
       │            → treat as alive; throw alreadyRecording (conservative
       │               default — better to refuse than to clobber)
       │
       └── parse error (malformed file)
             → log warning "removing malformed PID file"
             → PidFile.remove(pidFilePath); continue to [3]
   │
   ▼
[3] Open log file (O_WRONLY | O_CREAT | O_APPEND, mode 0600).
    On failure → MacrecError.ioError; exit 1
   │
   ▼
[4] Daemonizer.detach(logFilePath):  (see §14.2)
      fork → setsid → fork → chdir("/") → umask(0)
      → close(stdin), dup2(logFd, stdout), dup2(logFd, stderr)
   │
   ▼ (only the grandchild reaches here; parents have _exit(0))
   │
[5] Re-bootstrap LoggerFactory (so swift-log picks up the new fd-2)
   │
   ▼
[6] Run the same RecordingSession.start() pipeline as foreground mode,
    EXCEPT runMode == .detached, so:
      - PidFile.write(getpid(), to: pidFilePath) IMMEDIATELY after step 9
        of RecordingSession.start (after recorder.start, before first
        capture buffer).
      - On every clean exit (SIGINT, SIGTERM, max-duration, finalize),
        PidFile.remove(pidFilePath). Crash → file is left as stale.
```

### 14.2 Double-fork sequence (concrete pseudo-Swift)

```swift
import Darwin
import Foundation

enum Daemonizer {
    /// Performs the classic POSIX double-fork. Returns ONLY in the
    /// grandchild process. Parent and intermediate parent _exit(0).
    /// On failure, throws BEFORE the first fork.
    ///
    /// Justification for double-fork (vs. posix_spawn or launchctl):
    ///   - posix_spawn requires re-exec'ing the binary, which forces
    ///     re-resolving every CLI flag, env var, and TCC state.
    ///     We'd need an --internal-detached-child hidden flag and a
    ///     full-pipeline re-bootstrap. Brittle.
    ///   - launchctl bootstrap requires a .plist agent. Wrong UX
    ///     for an ad-hoc CLI tool; drops us into LaunchAgent
    ///     lifecycle and out-of-process logging that conflicts
    ///     with FR-29.
    ///   - Classic double-fork is in-process, keeps every Swift
    ///     framework reference live, and matches user expectations.
    static func detach(logFilePath: URL) throws {
        // Open the log fd BEFORE forking — easier to error-handle.
        let logFd = open(logFilePath.path,
                         O_WRONLY | O_CREAT | O_APPEND,
                         0o600)
        guard logFd >= 0 else {
            throw MacrecError.ioError(
                "Failed to open log file \\(logFilePath.path): \\(String(cString: strerror(errno)))"
            )
        }

        // First fork: detach from the invoking shell.
        let pid1 = fork()
        if pid1 < 0 {
            close(logFd)
            throw MacrecError.ioError("first fork() failed: \\(String(cString: strerror(errno)))")
        }
        if pid1 > 0 {
            // Parent — return to the user's shell prompt immediately.
            close(logFd)
            _exit(0)  // _exit, NOT exit — skip atexit handlers
        }

        // Child 1: become a session leader (no controlling terminal).
        if setsid() < 0 {
            close(logFd)
            _exit(1)
        }

        // Second fork: ensure we cannot reacquire a controlling terminal.
        let pid2 = fork()
        if pid2 < 0 {
            close(logFd)
            _exit(1)
        }
        if pid2 > 0 {
            // Intermediate parent — _exit immediately.
            close(logFd)
            _exit(0)
        }

        // Grandchild: this is the daemon.
        chdir("/")           // don't pin the user's CWD
        umask(0)             // permissive umask; PidFile.write will
                             // explicitly chmod 0600.

        // Redirect standard streams.
        // stdin → /dev/null (close + open).
        close(STDIN_FILENO)
        let nullFd = open("/dev/null", O_RDONLY)
        if nullFd != STDIN_FILENO {
            dup2(nullFd, STDIN_FILENO)
            close(nullFd)
        }
        // stdout → log file
        dup2(logFd, STDOUT_FILENO)
        // stderr → log file (same fd; swift-log will write here)
        dup2(logFd, STDERR_FILENO)
        close(logFd)

        // Returns here ONLY in the grandchild.
    }
}
```

**Why `_exit(0)` and not `exit(0)`?**
`exit()` runs every registered `atexit` handler. The Swift runtime and
Foundation register handlers that flush logging, run deinitializers,
and (in some configurations) call `objc_terminate()`. Running these in
the parent forks would (a) flush log output to the parent's
inherited-but-soon-to-be-redirected stderr, polluting the user's
terminal, and (b) double-run any deinitializer that has live state
captured by the soon-to-be-grandchild. `_exit()` skips all of that and
goes straight to the kernel `exit(2)` syscall. This is the standard
Stevens APUE §13.3 rule for daemonization.

### 14.3 Decision tree — `stop`

```
stop --pid-file <path> --stop-timeout <seconds>
   │
   ▼
[1] Resolve pidFilePath, stopTimeout via the 4-source chain
   │
   ▼
[2] PidFile.read(pidFilePath)
       │
       ├── nil (ENOENT)
       │     → throw MacrecError.noActiveRecording(pidFilePath)
       │     → exit 78 (EX_CONFIG)
       │     stderr: "No active macrec recording found
       │              (PID file at <path> does not exist)."
       │     hint:   "Start a recording with 'macrec start --detach' first."
       │
       ├── parse error (malformed file)
       │     → PidFile.remove(pidFilePath)
       │     → throw MacrecError.staleRecording(pid: 0, pidFilePath)
       │     → exit 75 (EX_TEMPFAIL)
       │
       └── pid present → continue to [3]
   │
   ▼
[3] PidFile.isAlive(pid)
       │
       ├── .stale (kill(pid, 0) → ESRCH)
       │     → PidFile.remove(pidFilePath)
       │     → throw MacrecError.staleRecording(pid, pidFilePath)
       │     → exit 75 (EX_TEMPFAIL)
       │     stderr: "Stale PID file at <path> referenced PID <pid>
       │              which is no longer running. The file has been removed."
       │
       ├── .alive
       │     → continue to [4]
       │
       └── .unknown (kill(pid, 0) → EPERM)
             → log warning "PID <pid> exists but we don't own it; trying SIGTERM"
             → continue to [4]
   │
   ▼
[4] kill(pid, SIGTERM)
       │
       ├── success      → continue to [5]
       │
       └── EPERM/EINVAL → throw MacrecError.unknown("kill failed: ...")
                         → exit 1
   │
   ▼
[5] Poll kill(pid, 0) every 100 ms for up to stopTimeout seconds
       │
       ├── ESRCH within timeout
       │     → process exited cleanly
       │     → check PidFile.read(pidFilePath):
       │            ├── nil → daemon cleaned up correctly. exit 0.
       │            └── pid present → log warning
       │                "daemon did not clean up its own PID file";
       │                PidFile.remove(pidFilePath); exit 0.
       │
       └── timeout fires
             → throw MacrecError.stopTimeout(pid, seconds: stopTimeout)
             → exit 70 (EX_SOFTWARE)
             stderr: "macrec process <pid> did not exit within <seconds>s
                     of SIGTERM. The process may still be finalizing or hung."
```

### 14.4 PID file format

- **Path (default):** `~/.tool-agents/macrec/macrec.pid`. Overridable
  via `--pid-file <path>` and env var `MACREC_PID_FILE`.
- **Mode:** `0600` (owner read/write only). Enforced by `PidFile.write`.
- **Content:** a single line containing the decimal PID, no leading
  zeros, no trailing whitespace, no trailing newline (Unix convention
  varies; we pick "no newline" so `cat ~/.tool-agents/macrec/macrec.pid`
  shows on the same line as the prompt — easier for ad-hoc inspection).
- **Write strategy:** atomic via `<path>.tmp` + `rename` to avoid a
  partial-PID-file race if the daemon is killed mid-write.

### 14.5 Log file rotation policy

**v1 ships with NO rotation.** The log file
(`~/.tool-agents/macrec/macrec.log` by default) grows monotonically.
The user is responsible for managing its size — typical workflows:

```sh
# Inspect:
tail -f ~/.tool-agents/macrec/macrec.log
# Truncate (while no recording is active):
: > ~/.tool-agents/macrec/macrec.log
# Archive:
mv ~/.tool-agents/macrec/macrec.log ~/macrec-$(date +%F).log
```

This is documented as a **known limitation in FR-29** and tracked in
`Issues - Pending Items.md` for v2 consideration. Rationale: a
recording-tool log file gains ~10 KB/minute at info level — 600 MB
over 1000 hours of recording, well within "user can manage manually"
territory.

### 14.6 Sequence diagrams

#### 14.6 (a) — `start --detach` happy path

```
User shell                  parent          intermediate     grandchild        kernel/SCStream
    │                         │                  │                │                   │
    │  macrec start --detach  │                  │                │                   │
    │ ─────────────────────►  │                  │                │                   │
    │                         │ open log fd      │                │                   │
    │                         │ check PID file   │                │                   │
    │                         │   (none → ok)    │                │                   │
    │                         │ fork() ─────────►│                │                   │
    │                         │ _exit(0)         │ setsid()       │                   │
    │ ◄─ shell prompt back ───│ (parent gone)    │ fork() ───────►│                   │
    │  (target: < 1 s)        │                  │ _exit(0)       │ chdir/umask/dup2  │
    │                         │                  │ (mid gone)     │ re-bootstrap log  │
    │                         │                  │                │ RecordingSession  │
    │                         │                  │                │   .start()        │
    │                         │                  │                │ PidFile.write(    │
    │                         │                  │                │   getpid())       │
    │                         │                  │                │ first capture     │
    │                         │                  │                │ buffer flows      │
    │                         │                  │                │ ─────────────────►│
    │                         │                  │                │                   │
```

#### 14.6 (b) — `start --detach` blocked by live PID

```
User shell                  parent
    │                         │
    │  macrec start --detach  │
    │ ─────────────────────►  │
    │                         │ check PID file
    │                         │   (PID 12345 → kill(0) succeeds → alive)
    │                         │ throw MacrecError.alreadyRecording(12345, ...)
    │                         │ stderr: "Another macrec recording is already
    │                         │          running (PID 12345, ...)"
    │ ◄─── exit 78 ───────────│
    │                         │ (the running daemon at PID 12345 is undisturbed)
```

#### 14.6 (c) — `stop` happy path

```
User shell        stop process       kernel/daemon (PID 12345)
    │                  │                       │
    │ macrec stop      │                       │
    │ ───────────────► │                       │
    │                  │ read PID file (12345) │
    │                  │ kill(12345, 0) → 0    │
    │                  │ kill(12345, SIGTERM)  │ ─►
    │                  │                       │ SignalHandler fires
    │                  │                       │ RecordingSession.stop(.signal(SIGTERM))
    │                  │ poll kill(0) every    │ recorder.finalize(...)
    │                  │ 100 ms                │ PidFile.remove(...)
    │                  │ ...                   │ process exits
    │                  │ kill(0) → ESRCH       │
    │                  │ check PID file (gone) │
    │                  │ exit 0                │
    │ ◄ shell prompt ──│                       │
```

#### 14.6 (d) — `stop` against stale PID

```
User shell        stop process       kernel
    │                  │                  │
    │ macrec stop      │                  │
    │ ───────────────► │                  │
    │                  │ read PID file (12345)
    │                  │ kill(12345, 0) → ESRCH
    │                  │ PidFile.remove(...)
    │                  │ throw MacrecError.staleRecording(12345, ...)
    │                  │ stderr: "Stale PID file ... referenced PID 12345
    │                  │          which is no longer running. The file
    │                  │          has been removed."
    │ ◄ exit 75 ──────│
```

#### 14.6 (e) — `stop` timeout

```
User shell        stop process       daemon (PID 12345; hung)
    │                  │                       │
    │ macrec stop      │                       │
    │ ───────────────► │                       │
    │                  │ read PID file (12345) │
    │                  │ kill(12345, 0) → 0    │
    │                  │ kill(12345, SIGTERM)  │ ─►  (ignored / busy)
    │                  │ poll for 35 s (default)
    │                  │ kill(0) keeps         │
    │                  │   returning 0         │
    │                  │ throw MacrecError.stopTimeout(12345, 35)
    │                  │ stderr: "macrec process 12345 did not exit
    │                  │          within 35s of SIGTERM. ..."
    │ ◄ exit 70 ──────│
    │                  │                       │
    │ (user can escalate to kill -KILL 12345  │
    │  manually; will lose the recording)     │
```

### 14.7 Foreground vs. detach behavior parity

The recording pipeline (sources → aligner → mixer → recorder) is
**identical** between foreground and detached modes. Only the run-mode
shell differs:

| Aspect                          | Foreground               | Detached (`--detach`)                          |
|---------------------------------|--------------------------|------------------------------------------------|
| Process tree                    | `shell → macrec`         | `shell → orphan → setsid → orphan → daemon`   |
| stdout                          | inherited from shell     | redirected to log file                         |
| stderr                          | inherited from shell     | redirected to log file                         |
| stdin                           | inherited from shell     | redirected from `/dev/null`                    |
| PID file                        | NOT written              | written at `pidFilePath`                       |
| `stop` subcommand applicable?   | no (use Ctrl-C / SIGTERM)| yes                                            |
| Two concurrent recordings?      | yes (different `--output`) | no — second `start --detach` fails FR-28      |
| TCC permissions required?       | screen + mic             | screen + mic (same as foreground)              |
| `RecordingSession` finalization | identical                | identical                                      |
| `--max-duration` cap            | identical                | identical                                      |

---

## Design changes since plan-001

This section catalogs every place this design departs from
`docs/design/plan-001-recording-tool.md` or extends it in ways the plan
should mirror.

### Deviations and extensions

1. **Capture envelope `CaptureBuffer`.** plan-001 had every source emit a
   bare `CMSampleBuffer` via `onSampleBuffer: ((CMSampleBuffer) -> Void)?`.
   This design wraps it in a `CaptureBuffer` envelope that carries a
   `CaptureSourceTag` so the aligner does not need a parallel callback per
   source. Rationale: simpler closure plumbing in `RecordingSession.start()`
   and one queue per source. **Plan should be amended** in Phase E §2 to
   describe `CaptureBuffer`.

2. **`AlignedFrame` type.** plan-001 §F describes the aligner emitting
   "time-aligned pairs" without a concrete type. This design names them
   `AlignedFrame { pts, duration, systemBuffer, micBuffer }` and routes
   them through `BufferSummer` / channel-pin / split passthrough.
   **Plan-001 §F is consistent** with this; just a naming-and-shape
   tightening.

3. **PermissionGate composes the two helpers.** plan-001 §D names
   `LivePermissionGate` and `StubPermissionGate`. This design adds the
   protocol method `requestMicrophone() async -> Bool` (async because
   `AVCaptureDevice.requestAccess(for: .audio)` is async). **Plan should
   be amended** to spell this signature out.

4. **`FakeAudioSource` conforms to BOTH `SystemAudioSource` AND
   `MicrophoneSource`.** plan-001 §E says this implicitly but doesn't
   state it. Both production sources share the same `AudioSource` base, so
   the fake is the natural double-conformance. **Plan should be amended.**

5. **Subsystem strings (§6.2).** plan-001 §C did not enumerate them;
   this design pins them so loggers can be set up consistently across
   modules. **Plan should be amended** to reference §6.2 of this design.

6. **Locked stderr strings (§2.1 table).** plan-001 listed exit codes per
   error case but not the user-facing strings. This design pins them
   so Phase 9 can assert verbatim. **Plan should be amended** to reference
   the §2.1 table.

7. **`SignalHandler` signature: `(Int32) -> Void`.** plan-001 §J said
   `stopAction: () -> Void`; this design passes the signal number through
   so the orchestrator can log which signal was received. Cosmetic; **plan
   does not need amending** (interface still backward-compatible).

8. **Threading model (§1.3 table).** plan-001 implied this but did not
   enumerate the queues. The table here is the authoritative reference.
   **Plan should be amended** to reference §1.3 of this design.

9. **`CMSampleBufferAudioConversion` lives under `Encoding/`.** plan-001
   §H placed this file there; this design confirms the location and adds
   a second function (`toSampleBuffer`) that `BufferSummer` needs. **Plan
   should be amended** to mention the second function.

### Recommended amendments to `plan-001-recording-tool.md`

The orchestrator should propose to the user (do NOT edit the plan in
this phase) the following minor amendments to plan-001:

> **Phase E — Capture protocols + fakes:**
> - Add: "Capture sources emit a `CaptureBuffer { source: CaptureSourceTag, buffer: CMSampleBuffer }` envelope so the aligner can route per-source without a parallel callback per source."
> - Add: "`FakeAudioSource` conforms to BOTH `SystemAudioSource` AND `MicrophoneSource`."
>
> **Phase D — Permissions + Devices:**
> - Add: "`PermissionGate.requestMicrophone() async -> Bool` is async because `AVCaptureDevice.requestAccess(for: .audio)` is async."
>
> **Phase C — Logging + Errors:**
> - Add cross-reference: "User-facing error strings are pinned in §2.1 of `docs/design/project-design.md`. Phase 9 asserts them verbatim."
> - Add cross-reference: "Subsystem strings are pinned in §6.2 of `docs/design/project-design.md`."
>
> **Phase F — Aligner + Mixer:**
> - Add cross-reference: "Aligner emits `AlignedFrame { pts, duration, systemBuffer, micBuffer }`. Type and algorithm pinned in §2.9 + §1.2 of project-design."
> - Add cross-reference: "Threading queues pinned in §1.3 of project-design."
>
> **Phase H — WAV + CAF Recorders:**
> - Add: "`CMSampleBufferAudioConversion.swift` exposes both `toPCMBuffer` (used by WAVRecorder/CAFRecorder) and `toSampleBuffer` (used by BufferSummer)."

No amendments needed for the Files-to-modify matrix, the parallelization
map, or the risk register — all entries match this design.

---

## Section 15 — `macrec-ui` Toolbar UI Architecture (added 2026-04-26 — plan-002)

> **Authoritative source documents** for this section:
> 1. `docs/design/refined-request-toolbar-ui.md` — refined spec
>    (FR-30..FR-44, NFR-11..NFR-16, AC-UI-1..AC-UI-18, "Decisions Locked").
> 2. `docs/reference/investigation-toolbar-ui.md` — implementation-level
>    "how" for each locked decision (Topics 1–7).
> 3. `docs/reference/codebase-scan-toolbar-ui.md` — exact file:line
>    integration points with the engine.
> 4. `docs/design/plan-002-toolbar-ui.md` — phase-by-phase plan with the
>    Wave 1..7 parallelization map this section anchors against.
>
> The CLI (`macrec`) sections §1..§14 above remain unchanged. This
> section is strictly additive: a new SwiftPM `executableTarget` named
> `macrec-ui` reuses every existing `MacrecCore` component and adds four
> small engine extensions (`SessionState` + `stateStream`, `split()`,
> `levelTap`, `PermissionGating` protocol) listed in §15.4 below.

### 15.1 System Architecture & Component Diagram

`macrec-ui` is an in-process menu-bar accessory app: an AppKit
`NSStatusItem` + `NSPopover` shell hosts a SwiftUI body via
`NSHostingController<RootView>`, drives a `@MainActor @Observable
RecordingController` view model, which delegates pause/resume/split
orchestration to a non-MainActor `actor SessionCoordinator`, which in
turn instantiates and runs `RecordingSession` from `MacrecCore`. No
subprocess shell-out, no IPC — the engine is linked directly per ADR
032 (locked OQ-PROC-1).

```
                             ┌─────────────────────────────────────────┐
                             │  macOS — User clicks status-bar icon    │
                             └─────────────────────────────────────────┘
                                              │
                                              ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  Process: .build/debug/macrec-ui     (CFBundleIdentifier=com.local.macrec-ui)    │
│  Activation policy: .accessory   LSUIElement=true   (no Dock icon, no app menu)  │
│                                                                                  │
│  ┌─────────────────────────────┐                                                 │
│  │  @main MacrecUIApp : App    │  (SwiftUI App scope)                            │
│  │   Settings { EmptyView() }  │  ← only declared scene; placeholder             │
│  │  @NSApplicationDelegate     │                                                 │
│  │   Adaptor AppDelegate       │                                                 │
│  └────────────┬────────────────┘                                                 │
│               │ owns                                                             │
│               ▼                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │  AppDelegate                                                             │   │
│  │   ├─ NSApp.setActivationPolicy(.accessory)                               │   │
│  │   ├─ LoggerFactory.bootstrap(.info)                                      │   │
│  │   ├─ ToolAgentsBootstrap.ensure(toolName:"macrec-ui") + log redirect     │   │
│  │   ├─ statusItem: NSStatusItem (strong-retained)                          │   │
│  │   ├─ statusItemController: StatusItemController                          │   │
│  │   ├─ popoverController: PopoverController                                │   │
│  │   ├─ recordingController: RecordingController  (long-lived parent)       │   │
│  │   └─ applicationShouldTerminate(_:) → confirm-then-finalize-then-quit    │   │
│  └────────────┬─────────────────────────────────────────────┬───────────────┘   │
│               │                                             │                   │
│               │ click action                                │ environment       │
│               ▼                                             ▼                   │
│  ┌─────────────────────────────┐         ┌──────────────────────────────────┐   │
│  │  StatusItemController       │         │  PopoverController               │   │
│  │   ├─ NSStatusItem.button    │         │   ├─ NSPopover (.transient)      │   │
│  │   │   .image (template)     │         │   │   .contentViewController =   │   │
│  │   │      ↓ setIcon(state:)  │         │   │     NSHostingController<     │   │
│  │   │   • idle      → circle  │         │   │       RootView>(             │   │
│  │   │   • recording → record  │         │   │       rootView: RootView())  │   │
│  │   │   • paused    → pause   │         │   └─  toggle / close  /          │   │
│  │   │   • failed    → ! tri.  │         │       setBehavior(.semitrans-    │   │
│  │   └─ click → popover.toggle │         │       ient) when NSOpenPanel up  │   │
│  └─────────────────────────────┘         └─────────────┬────────────────────┘   │
│                                                        │ hosts                   │
│                                                        ▼                         │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │  SwiftUI body (Sources/macrec-ui/Views/)                                   │ │
│  │  RootView                                                                  │ │
│  │   ├─ ErrorBanner (top, NFR-12)                                             │ │
│  │   ├─ FilenameField           (FR-35)   PermissionStatusView (FR-37)        │ │
│  │   ├─ FormatPicker / LayoutPicker (FR-38)                                   │ │
│  │   ├─ FolderPicker (FR-36)            MicrophonePicker (FR-39)              │ │
│  │   ├─ ControlBar  Start | Pause | Resume | Stop | Split  (FR-31, FR-32)     │ │
│  │   ├─ ElapsedTimeView (FR-40)         LevelMeterView × 2 (FR-43)            │ │
│  │   └─ SavedToDisclosure (FR-34, OQ-UI-11)                                   │ │
│  │  every view reads recordingController via @Environment(\.recording-        │ │
│  │   Controller)                                                              │ │
│  └────────────────────────────────┬───────────────────────────────────────────┘ │
│                                   │ writes (button taps)   reads (@Observable) │
│                                   ▼                                             │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │  @MainActor @Observable final class RecordingController                    │ │
│  │   state: SessionState         levels: [Source: LevelSample]                │ │
│  │   segmentElapsed: Duration    totalElapsed: Duration                       │ │
│  │   permissionSnapshot: PermissionGate.Snapshot?                             │ │
│  │   completedSegments: [URL]    latestErrorMessage: String?                  │ │
│  │   basename / format / folder / layout / micUID  (UI-state inputs)          │ │
│  │   private runTask, stateTask, levelsTask, elapsedTask                      │ │
│  │   private coordinator: SessionCoordinator?                                 │ │
│  │   func start(...) | requestStop() | pause() | resume() | split()           │ │
│  └────────────────────────────────┬───────────────────────────────────────────┘ │
│                                   │ awaits across actor hop                    │
│                                   ▼                                             │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │  actor SessionCoordinator                                                  │ │
│  │   basename, folder, baseOptions, segmentCounter (1-based)                  │ │
│  │   current: RecordingSession?    currentRunTask: Task<Void, Error>?         │ │
│  │   stateStream: AsyncStream<SessionState>  (synthetic for .pausing /        │ │
│  │     .paused / .resuming and forwarded for engine-emitted states)           │ │
│  │   start() | pause() | resume() | split() | stop()                          │ │
│  └────────────────────────────────┬───────────────────────────────────────────┘ │
│                                   │ instantiates / drives                      │
│                                   ▼                                             │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │  MacrecCore.RecordingSession  (existing engine; minor extensions in §15.4) │ │
│  │   stateStream: AsyncStream<SessionState>           ← NEW (FR-33)           │ │
│  │   func split(nextOutput: URL) async throws         ← NEW (FR-32)           │ │
│  │   serialQueue + OSAllocatedUnfairLock<Recorder?>   ← swap point for split  │ │
│  │   permissionGate: any PermissionGating  (injected) ← unblocks ISSUE-02     │ │
│  │   ┌──────────────────────────┐ ┌──────────────────────────┐                │ │
│  │   │ SCKitSystemAudioSource   │ │ AVMicrophoneSource       │                │ │
│  │   │  onSampleBuffer  (engine)│ │  onSampleBuffer (engine) │                │ │
│  │   │  levelTap  ← NEW (FR-43) │ │  levelTap  ← NEW (FR-43) │                │ │
│  │   └────────────┬─────────────┘ └─────────────┬────────────┘                │ │
│  └────────────────┼───────────────────────────────┼───────────────────────────┘ │
│                   │ CaptureBuffer (post-tap, audio queues)                       │
│                   ▼                                                              │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │  LevelMeterPublisher  (Sources/macrec-ui/)                                 │ │
│  │   ├─ LevelMeterTap (mic)     ─ vDSP_rmsqv + vDSP_maxmgv on a               │ │
│  │   │     pre-allocated AVAudioPCMBuffer; coalesce to 30 Hz                  │ │
│  │   ├─ LevelMeterTap (system)  ─ same shape                                  │ │
│  │   └─ merged AsyncStream<LevelSample>(.bufferingNewest(2))                  │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**Read-paths between layers** (every arrow above is a Swift call,
nothing crosses a process boundary):

- **AppKit → SwiftUI**: `NSHostingController<RootView>(rootView:)`.
- **SwiftUI views → controller**: `@Environment(\.recordingController)`.
- **Controller → coordinator**: `await coordinator.<method>()`.
- **Coordinator → engine**: `try await session.run()` + `session.requestStop()`
  + `try await session.split(nextOutput:)`.
- **Engine → controller**: `for await s in session.stateStream { ... }` +
  per-source `levelTap` closures into `LevelMeterPublisher`.
- **Controller → SwiftUI views**: `@Observable`-tracked property reads
  trigger only the views that read those specific properties (per-property
  fine-grained tracking — Topic 2 motivation for `@Observable`).

### 15.2 Module Organization

The `macrec-ui` source layout is below. Per investigation Topic 1
gotchas, the AppKit shell is intentionally minimal (~80 LOC across
three files) and the bulk of UI code lives in SwiftUI views and pure
domain types.

```
Sources/macrec-ui/
  MacrecUIApp.swift          # @main; SwiftUI App with Settings{EmptyView()};
                             # @NSApplicationDelegateAdaptor(AppDelegate.self)
  App/
    AppDelegate.swift          # NSApplicationDelegate; activation policy;
                               # owns statusItem, popover, controllers;
                               # applicationShouldTerminate(_:) flow (§15.10)
    StatusItemController.swift # NSStatusItem + setIcon(for:SessionState)
    PopoverController.swift    # NSPopover + NSHostingController<RootView>;
                               # toggle / close; .transient ↔ .semitransient
    QuitFlow.swift             # confirm-then-finalize-then-quit helper
                               # (Phase F deliverable; see §15.10)
  Domain/
    RecordingController.swift  # @MainActor @Observable view model
    SessionCoordinator.swift   # actor; stop-and-stitch state machine
    FilenameGenerator.swift    # default basename generator (FR-35)
    SegmentNamer.swift         # partNN URL computation (FR-34)
    LevelMeterTap.swift        # vDSP peak/RMS on pre-allocated PCM buffer
    LevelMeterPublisher.swift  # merges per-source streams to one
    LevelSample.swift          # Sendable value type for level samples
    UIErrorPresenter.swift     # MacrecError → user-visible string + action
    UILoggingMenu.swift        # hidden "Show debug log" toggle (NFR-16)
  Views/
    RecordingControllerKey.swift # SwiftUI EnvironmentKey
    RootView.swift               # top-level popover composition
    FilenameField.swift          # FR-35
    FormatPicker.swift           # FR-38 (m4a / wav / caf)
    LayoutPicker.swift           # FR-38 (mixed / split / stereo-split)
    FolderPicker.swift           # FR-36 (NSOpenPanel)
    MicrophonePicker.swift       # FR-39 (AudioDeviceEnumerator)
    PermissionStatusView.swift   # FR-37
    ElapsedTimeView.swift        # FR-40 (mm:ss × 2)
    ControlBar.swift             # Start / Pause / Resume / Stop / Split
    LevelMeterView.swift         # FR-43 (peak + RMS bar × 2)
    SavedToDisclosure.swift      # FR-34, OQ-UI-11
    ErrorBanner.swift            # NFR-12 banner

Resources/MacrecUI-Info.plist  # separate from CLI's Info.plist
                               # CFBundleIdentifier=com.local.macrec-ui
                               # LSUIElement=true; same TCC usage strings

Tests/MacrecUITests/
  FilenameGeneratorTests.swift
  SegmentNamerTests.swift
  SessionCoordinatorTests.swift
  RecordingControllerTests.swift
```

> **AMB-3 resolution**: `FilenameGenerator` lives in `Sources/macrec-ui/`,
> NOT in `Sources/MacrecCore/`. The CLI does not auto-fill output names
> (it errors on missing `--output`). Keeping the helper UI-scoped means
> the engine API surface is not bloated by a UI-only concern. Confirmed
> per investigation Topic 6 Option 6A and codebase-scan §4.3.
>
> **AMB-3 follow-up — `MacrecUIKit` library target**: To make Swift
> Testing on an `executableTarget` work cleanly (Swift Testing cannot
> import an `executableTarget` directly), Phase D adds a small
> `MacrecUIKit` library target in `Package.swift` containing every file
> under `Domain/` and `Views/`. The `macrec-ui` `executableTarget` then
> reduces to `MacrecUIApp.swift`, `AppDelegate.swift`, and the three
> `App/` shell files; `MacrecUITests` imports `MacrecUIKit`. This is
> a SwiftPM mechanical refactor, not a design change — the runtime
> graph is unchanged.

### 15.3 Engine Extensions (additive to `MacrecCore`)

These are the four (and a half) new APIs the UI requires. None of them
break any existing CLI behavior; the CLI does not subscribe to the
state stream, does not call `split()`, does not install `levelTap`s,
and uses the default-`nil` `permissionGate` injection point.

#### 15.3.1 `SessionState` enum + `stateStream` (FR-33)

```swift
public enum SessionState: Sendable, Equatable {
    case idle
    case starting
    case recording
    case pausing       // synthesized by SessionCoordinator (not engine)
    case paused        // synthesized by SessionCoordinator
    case resuming      // synthesized by SessionCoordinator
    case splitting     // emitted by RecordingSession.split() (AMB-1: discrete)
    case stopping
    case stopped
    case failed(MacrecError)
}
```

> **AMB-1 resolution**: `splitting` is a discrete enum case (not a
> transient flag on `recording`). Justifications: (a) keeps the FR-33
> enum exhaustive and matches the spec verbatim; (b) the UI may render
> it identically to `recording` if it chooses, but the state machine
> remains observable; (c) tests can assert `[.splitting, .recording]`
> after `split()` deterministically.

`RecordingSession` gets two new fields and emits at every transition:

```swift
public final class RecordingSession: @unchecked Sendable {
    // existing fields ...
    private let stateContinuation: AsyncStream<SessionState>.Continuation
    public  let stateStream: AsyncStream<SessionState>
    // ...
}
```

`AsyncStream` constructed via `AsyncStream.makeStream(of: SessionState.self,
bufferingPolicy: .bufferingNewest(8))` in `init`. Buffer size of 8 is
generous — the stream rarely outruns its consumer, and a slow consumer
(UI lag) keeps only the most recent transitions.

**State-transition emission points** (cross-referenced to existing
`RecordingSession.swift` lines per codebase-scan §4.1):

| Where in engine | Emitted state |
|-----------------|---------------|
| Top of `run()` (line 231) | `.starting` |
| After sources/recorder wired and `_running = true` (line 349) | `.recording` |
| `split(nextOutput:)` entry | `.splitting` |
| `split(nextOutput:)` after swap settles | `.recording` |
| `requestStop()` body (line 218) | `.stopping` |
| `resolveRunLoop` cleanup, success path (line 513) | `.stopped` |
| `resolveRunLoop` cleanup, error path | `.failed(error)` |
| End of `resolveRunLoop` (very last line, after the above) | `stateContinuation.finish()` |

> **R-28 (toolbar) mitigation**: `stateContinuation.finish()` MUST be
> called from `resolveRunLoop` exit. Otherwise the consumer `Task` in
> `RecordingController.stateTask` leaks. Phase 7 Code Reviewer audits
> this.

**State-machine diagram (engine-only — coordinator-synthesized states
in §15.5)**:

```
              ┌──────────┐  init / await run()
              │   idle   │ ─────────────────────────►  starting
              └──────────┘
                                   │ sources + recorder up; _running=true
                                   ▼
       ┌──────────────────────► recording ◄─────────────────────────┐
       │                            │                                │
       │                            │ split(nextOutput:)             │
       │                            ▼                                │
       │                       splitting ──── swap settles ──────────┘
       │                            │
       │                            │ requestStop() / SIGINT / SIGTERM
       │                            ▼
       │                        stopping
       │                            │
       │                            │  resolveRunLoop cleanup
       │                            ▼
       │              ┌─────────────┴─────────────┐
       │              ▼                           ▼
       │           stopped                   failed(MacrecError)
       │              │                           │
       └──────────────┴─── (terminal; stateContinuation.finish())
```

#### 15.3.2 `RecordingSession.split(nextOutput:)` (FR-32, AC-UI-7)

The split primitive is the heart of FR-32. It rotates the output
encoder while keeping `SCStream` and `AVCaptureSession` alive — the
audible-gap budget is **≤ 250 ms** (AC-UI-7), and the design achieves
**≤ ~52 ms** per investigation Topic 4.

**Algorithm** (locked per investigation Topic 4 Option 4A):

```
Inputs : nextOutput: URL  (must be writable; pre-validated)
State  : self._recorderLock : OSAllocatedUnfairLock<Recorder?>
Pre    : current state is .recording

1. Emit .splitting on stateStream.

2. Pre-flight new recorder OFF the serial queue:
     let newOptions  = options.withOutput(nextOutput)
     let newRecorder = try makeRecorder(options: newOptions, logger:)
     try await newRecorder.start()
   makeRecorder pre-validates the output path and overwrite policy
   (codebase-scan §4.1, "makeRecorder factory"). If start() throws,
   abort the split, emit .failed(error), DO NOT touch _recorder, the
   old recorder continues unchanged.

3. Atomic swap on serialQueue.sync(execute:):
     let oldRecorder = self._recorderLock.withLock { current in
         let prev = current
         current = newRecorder
         return prev!
     }
   The lock is read on every aligned-frame callback (§15.3.3) so the
   swap is observable atomically — frame N goes to old, frame N+1 to
   new. No frame is dropped or duplicated.

4. aligner.onAlignedFrame closure does NOT need to be re-pointed
   (per investigation Topic 4 gotcha). The closure reads
   _recorderLock.withLock { $0?.append(frame) } each call.

5. Finalize old recorder OFF the serial queue:
     try await oldRecorder.finalize(timeout: 5)
   This is async because m4a finalize writes the moov atom and can
   take seconds (FR-20 30 s ceiling reused).

6. Emit .recording on stateStream.

Post   : capture is uninterrupted; old file is on disk and playable;
         new file is open and accepting frames; audible seam ≤ ~52 ms.
```

**Seam-gap upper bound** (per investigation Topic 4):

| Component | Duration |
|-----------|----------|
| Lock acquire + swap reference | < 1 ms |
| Aligner-frame interval (one frame may be in-flight at swap) | ~10 ms |
| AAC priming gap on first frame of new m4a (zero for wav/caf) | ~42 ms |
| **Total worst-case (m4a)** | **~52 ms** |
| **Total worst-case (wav / caf)** | **~10 ms** |
| **Headroom against AC-UI-7 250 ms ceiling** | **≥ 198 ms** |

> **AMB-2 resolution**: `_recorderLock` is `OSAllocatedUnfairLock<Recorder?>`
> (macOS 13+, `Sendable`-friendly successor to `os_unfair_lock_s`).
> Justifications: (a) macOS 14+ project minimum so the API is
> available; (b) the `Sendable` story is cleaner than the unmanaged
> `os_unfair_lock_s`; (c) `withLock` provides scoped exclusive access
> with no manual `lock()` / `unlock()` pairing. `RecordingSession.swift`
> replaces the existing `_recorder: Recorder?` storage with this
> lock-guarded reference; the existing `serialQueue` continues to
> serialize state transitions and the lock additionally guarantees
> safe reads from the audio-thread aligner callback.

#### 15.3.3 `levelTap` closure on each capture source (FR-43)

```swift
// SCKitSystemAudioSource.swift
public var levelTap: ((CaptureBuffer) -> Void)?

// In handleAudioBuffer, AFTER calling onSampleBuffer:
levelTap?(buffer)

// AVMicrophoneSource.swift — same shape
public var levelTap: ((CaptureBuffer) -> Void)?
```

**Threading guarantee**: `levelTap` is invoked on the same
`userInteractive` capture queue that delivers `onSampleBuffer`
(`macrec.capture.system` and `macrec.capture.mic`). It MUST NOT touch
SwiftUI state directly. The UI installs taps that route into a
`LevelMeterPublisher` (§15.6), which yields onto an `AsyncStream` whose
consumer (`RecordingController.levelsTask`) is `@MainActor`-isolated.

**Wiring point** (cross-reference codebase-scan §4.1, "Audio pipeline
tap point"): `RecordingSession` exposes the two sources via existing
references (or via `Sources/MacrecCore/RecordingSession.swift` adding
small accessors `var systemAudioSource: any SystemAudioSource { get }`
and `var microphoneSource: any MicrophoneSource { get }` if not
already public). The UI writes `session.systemAudioSource.levelTap = {
publisher.ingest($0, source: .system) }` immediately after
constructing the session and before `await session.run()`.

#### 15.3.4 `PermissionGating` protocol (resolves ISSUE-02)

The existing `PermissionGate` class becomes a conformer of a new
protocol:

```swift
public protocol PermissionGating: Sendable {
    func snapshot() async -> PermissionGate.Snapshot
    func requireBothOrThrow() async throws
}

public final class PermissionGate: PermissionGating { /* existing impl */ }
```

`RecordingSession.init` accepts the protocol with a default value:

```swift
public init(
    options: RecordingOptions,
    logger: Logger? = nil,
    systemSource: (any SystemAudioSource)? = nil,
    micSource: (any MicrophoneSource)? = nil,
    permissionGate: (any PermissionGating)? = nil   // NEW
) {
    self.permissionGate = permissionGate ?? PermissionGate(logger: logger ?? ...)
    // ...existing init body...
}
```

Default-`nil` preserves existing CLI call-sites unchanged. Tests
inject a `StubPermissionGating` that always returns `.bothAuthorized`,
unblocking ISSUE-02 (codebase-scan §5).

#### 15.3.5 `RecordingOptions.withOutput(_:)` helper (used by `split()`)

```swift
extension RecordingOptions {
    /// Returns a copy with `output` replaced and all other fields preserved.
    /// Used by RecordingSession.split(nextOutput:) and by SessionCoordinator
    /// to produce per-segment options.
    func withOutput(_ url: URL) -> RecordingOptions { ... }
}
```

Pure value-type derivation; lives in `Sources/MacrecCore/Config/RecordingOptions.swift`.

### 15.4 `RecordingController` view model (UI domain layer)

`RecordingController` is the single owner of all UI-visible state. It
is `@MainActor`-isolated so every observable property mutation
happens on the main thread, which removes any need for
`DispatchQueue.main.async` ceremony in call sites.

```swift
@MainActor
@Observable
public final class RecordingController {
    // ─── observed state (read by SwiftUI views) ───
    public private(set) var state: SessionState = .idle
    public private(set) var levels: [CaptureBuffer.Source: LevelSample] = [:]
    public private(set) var segmentElapsed: Duration = .zero
    public private(set) var totalElapsed: Duration = .zero
    public private(set) var permissionSnapshot: PermissionGate.Snapshot?
    public private(set) var completedSegments: [URL] = []
    public private(set) var latestErrorMessage: String?

    // ─── user inputs (driven by views) ───
    public var basename: String = FilenameGenerator.defaultBasename(now: .now)
    public var format: OutputFormat = .m4a
    public var layout: TrackLayout = .mixed
    public var folder: URL = RecordingController.defaultFolder
    public var micUID: String? = nil

    // ─── private workers ───
    private var coordinator: SessionCoordinator?
    private var stateTask: Task<Void, Never>?
    private var levelsTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private let logger: Logger

    // ─── lifecycle ───
    public func start() { /* build options; create coordinator; spawn tasks */ }
    public func requestStop() { Task { try? await coordinator?.stop() } }
    public func pause()   { Task { try? await coordinator?.pause() } }
    public func resume()  { Task { try? await coordinator?.resume() } }
    public func split()   { Task { try? await coordinator?.split() } }
    public func cancelAll() { /* stop tasks, called on app terminate */ }
}
```

**Threading discipline** (per investigation Topic 2 gotchas):

- All writes to observed properties happen inside `@MainActor`-
  isolated code paths (the controller is `@MainActor`).
- The `for await s in coordinator.stateStream { self.state = s }` loop
  runs inside an unstructured `Task { ... }` started from a
  `@MainActor` method, which inherits the actor — no manual
  `Task { @MainActor in ... }` annotation needed.
- The `levelsTask` consumes the merged `AsyncStream<LevelSample>` from
  `LevelMeterPublisher` and writes `self.levels[sample.source] = sample`.
- `elapsedTask` runs a 1 Hz `Timer.publish(every: 1, on: .main, in:
  .common)`-equivalent (`AsyncTimerSequence` works) only while
  `state == .recording`; ticks update `segmentElapsed` and
  `totalElapsed`.
- **Stop is `requestStop()`, never `runTask?.cancel()`** — investigation
  Topic 2 explicitly forbids cancelling the run task because that
  interrupts `await session.run()` mid-finalize. Only on app shutdown
  (`cancelAll()`) is `cancel()` permitted, and even then only after
  `.stopped` has been observed.

### 15.5 `SessionCoordinator` actor — Stop-and-Stitch State Machine

`SessionCoordinator` is the heart of the pause/resume orchestration
layer. It synthesizes `.pausing → .paused → .resuming` between
sequential `RecordingSession` instances (per locked OQ-UI-2
stop-and-stitch decision) and forwards engine-emitted states for the
active session. It is an `actor` (AMB-4) so the segment counter and
session reference are serialized without any locks.

```swift
public actor SessionCoordinator {
    private let basename: String       // "recording-2026-04-26-103015"
    private let folder: URL
    private let baseOptions: RecordingOptions   // format / layout / mic / etc.
    private var segmentCounter: Int = 0
    private var current: RecordingSession?
    private var currentRunTask: Task<Void, Error>?
    private var totalSegments: Int = 1          // updated for FR-34 naming
    private let stateContinuation: AsyncStream<SessionState>.Continuation
    public  let stateStream: AsyncStream<SessionState>

    public func start() async throws { ... }
    public func pause() async throws { ... }
    public func resume() async throws { ... }
    public func split() async throws { ... }
    public func stop() async throws  { ... }
}
```

**State-transition table** (formal contract for Phase D coder + Phase
9 Test Builder):

| Coordinator state | Input | Side-effects | Next state | Emits on stateStream |
|-------------------|-------|--------------|------------|----------------------|
| `idle` | `start()` | segmentCounter←1; build session(seg=1); spawn runTask; forward session.stateStream | `recording(seg:1)` | `.starting` then forward `.recording` |
| `recording(seg:N)` | `pause()` | session.requestStop(); await runTask | `paused(seg:N, lastFile:URL)` | synth `.pausing` → forward engine `.stopping`/`.stopped` → synth `.paused` |
| `paused(seg:N, ...)` | `resume()` | segmentCounter←N+1; totalSegments←N+1; build session(seg=N+1) using SegmentNamer.url(seg=N+1, total=N+1); spawn runTask | `recording(seg:N+1)` | synth `.resuming` → forward `.starting` → forward `.recording` |
| `recording(seg:N)` | `split()` | totalSegments←N+1; await session.split(nextOutput: SegmentNamer.url(...,seg=N+1, total=N+1)); segmentCounter←N+1 | `recording(seg:N+1)` | forward `.splitting` → forward `.recording` |
| `recording(seg:N)` | `stop()` | session.requestStop(); await runTask | `stopped` | forward `.stopping` → forward `.stopped` |
| `paused(...)` | `stop()` | (session already stopped) | `stopped` | synth `.stopped` |
| any | engine emits `.failed(e)` | preserve last segment file; clear current | `failed` | forward `.failed(e)` |
| `idle / stopped / failed` | `pause / resume / split` | NO-OP (logged, ignored) | unchanged | none |

> **Multi-file FR-34 naming**: When `totalSegments == 1` (no pause was
> ever pressed and no split ever happened), the only output file gets
> the bare `<basename>.<ext>` name. As soon as `totalSegments` becomes
> 2 (first pause OR first split), the coordinator MUST rename the
> already-finalized segment 1 file from `<basename>.<ext>` to
> `<basename>.part01.<ext>` (or for split layout, both `.mic.<ext>`
> and `.system.<ext>` get the `.part01` infix inserted). This rename
> is performed by `SessionCoordinator` immediately after a successful
> `pause()` or `split()` returns the second segment. `SegmentNamer`
> exposes both the pre-rename single-file shape and the multi-file
> indexed shape so the coordinator can compute both URLs cleanly.

**Lifecycle wiring** (entry sequence at construction):

1. `RecordingController.start()` constructs `SessionCoordinator` with
   the user-edited `basename`, the resolved `folder`, and a
   `baseOptions: RecordingOptions` derived from the UI's format /
   layout / mic / micChannel selections.
2. `coordinator.start()` increments `segmentCounter` to 1, calls
   `SegmentNamer.url(basename:, ext:, layout:, segmentNumber: 1,
   totalSegments: 1)` to compute the first output URL (no `.partNN`
   infix initially), constructs `RecordingSession(options:
   baseOptions.withOutput(url), ...)`, sets `levelTap` on each source
   to route into the `LevelMeterPublisher`, spawns
   `currentRunTask = Task { try await current!.run() }`, and starts
   forwarding `session.stateStream` into `stateStream`.
3. `RecordingController.stateTask` consumes
   `coordinator.stateStream` and writes `self.state = ...`.

**Pause flow** (the locked stop-and-stitch primitive):

```
     ┌─────────────────────┐
     │ coordinator.pause() │
     └──────────┬──────────┘
                │ synth .pausing
                ▼
     ┌────────────────────────┐
     │ session.requestStop()  │ ← engine emits .stopping then .stopped
     └──────────┬─────────────┘
                │ await currentRunTask?.value  (file finalize completes)
                ▼
     ┌─────────────────────────────────┐
     │ append lastFile to              │
     │ controller.completedSegments    │ ← UI's SavedToDisclosure refreshes
     │ rename seg1 if totalSegments=2  │
     └──────────┬──────────────────────┘
                │ synth .paused
                ▼
            (parked; user can press Resume or Stop)
```

**Resume latency note** (R-29 / investigation Topic 3): each resume
incurs ~200–500 ms of SCStream cold-start. v1 imposes no resume-latency
SLO; if observed cold-start consistently exceeds 1 s (Phase K AC-UI-6
measurement), a v1.1 follow-up may pre-warm a parked SCStream during
`.paused`. Out of v1 scope.

### 15.6 Filename Generation (FR-34, FR-35)

`FilenameGenerator` produces the default basename. `SegmentNamer`
inserts `partNN` infixes per the FR-34 multi-file rules.

```swift
public struct FilenameGenerator {
    public static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")  // gotcha: avoid
                                                       // non-Gregorian surprises
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    /// Default basename only — no extension, no folder, no partNN infix.
    /// e.g. "recording-2026-04-26-103015"
    public static func defaultBasename(now: Date = .now) -> String {
        "recording-\(formatter.string(from: now))"
    }
}

public enum SegmentNamer {
    /// FR-34 URL computation.
    /// - totalSegments == 1: <folder>/<basename>.<ext>           (no infix)
    /// - totalSegments  > 1: <folder>/<basename>.partNN.<ext>
    /// For .layout = .split or .stereoSplit, returns TWO URLs (mic, system)
    /// with the partNN infix BEFORE the .mic/.system token.
    public static func urls(
        folder: URL,
        basename: String,
        ext: String,
        layout: TrackLayout,
        segmentNumber: Int,
        totalSegments: Int
    ) -> [URL] { ... }

    /// Convenience: returns the FIRST URL (the "primary" output passed to
    /// RecordingOptions.output). The recorder produces both files for split
    /// layouts internally; the primary URL is sufficient for makeRecorder.
    public static func url(...) -> URL { urls(...).first! }
}
```

**Algorithm** (pure / date-injectable for testability):

```
1. Default basename:
   basename ← "recording-" + formatter.string(from: now)
   where formatter is yyyy-MM-dd-HHmmss with en_US_POSIX locale and
   the user's current time zone.

2. URL with extension only (single-segment, no pause/split):
   folder / "<basename>.<ext>"

3. URL with partNN infix (multi-segment):
   folder / "<basename>.partNN.<ext>"
   where NN is segmentNumber zero-padded to 2 digits (FR-34 verbatim).

4. URL for split layout, multi-segment:
   folder / "<basename>.partNN.mic.<ext>"
   folder / "<basename>.partNN.system.<ext>"
   The .partNN infix appears BEFORE the .mic / .system token (FR-34
   sort-by-filename groups by segment).

5. Collision avoidance (defensive — this should be rare given the
   timestamp basename):
   If FileManager.default.fileExists(at: url), append "-N" suffix
   to basename (where N starts at 2) until the URL is unique.
   Applies to single-segment URLs only — multi-segment URLs are
   generated from the unique basename so they inherit uniqueness.
```

**Test surface** (Phase D):

| Test | Input | Expected |
|------|-------|----------|
| `defaultBasename` golden | fixed `Date(timeIntervalSince1970: 1745654400)` (2026-04-26 10:00:00 UTC) | `"recording-2026-04-26-100000"` (UTC) or local equivalent |
| `urls` single-segment, mixed | folder, basename, "m4a", .mixed, 1, 1 | `[<folder>/<basename>.m4a]` |
| `urls` single-segment, split | folder, basename, "wav", .split, 1, 1 | `[<basename>.mic.wav, <basename>.system.wav]` |
| `urls` part-2, mixed | folder, basename, "m4a", .mixed, 2, 2 | `[<basename>.part02.m4a]` |
| `urls` part-3, split | folder, basename, "wav", .split, 3, 4 | `[<basename>.part03.mic.wav, <basename>.part03.system.wav]` |

### 15.7 Level-Meter Pipeline (FR-43)

The level-meter pipeline is a single-writer, non-blocking publisher
that delivers smooth 30 Hz peak/RMS samples to SwiftUI without ever
allocating on the audio thread.

**Tap point**: `levelTap` closure on each `SCKitSystemAudioSource` and
`AVMicrophoneSource` (§15.3.3). The closure receives a
`CaptureBuffer` (existing struct;
`Sources/MacrecCore/Capture/CaptureBuffer.swift`) carrying `source: .mic | .system`
and the raw `CMSampleBuffer` with host-clock PTS.

**`LevelMeterTap`** (per-source; one for mic, one for system):

```swift
public final class LevelMeterTap: @unchecked Sendable {
    private let source: CaptureBuffer.Source
    private let pcmBuffer: AVAudioPCMBuffer       // pre-allocated, 4096 samples,
                                                  // Float32 stereo non-interleaved
    private let lastEmitLock = OSAllocatedUnfairLock<ContinuousClock.Instant>(
        initialState: ContinuousClock.now
    )
    private let continuation: AsyncStream<LevelSample>.Continuation
    public  let stream: AsyncStream<LevelSample>

    public init(source: CaptureBuffer.Source, format: AVAudioFormat) {
        self.source = source
        self.pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: 4096)!
        let (s, c) = AsyncStream.makeStream(of: LevelSample.self,
                                            bufferingPolicy: .bufferingNewest(2))
        self.stream = s; self.continuation = c
    }

    public func ingest(_ buffer: CaptureBuffer) {
        // 1. Coalesce: emit only every ~33 ms (30 Hz cap).
        let now = ContinuousClock.now
        let shouldEmit = lastEmitLock.withLock { last -> Bool in
            if now - last < .milliseconds(33) { return false }
            last = now; return true
        }
        guard shouldEmit else { return }

        // 2. Convert CMSampleBuffer → reused AVAudioPCMBuffer (no alloc).
        // 3. vDSP_maxmgv → peak; vDSP_rmsqv → rms.
        // 4. dB conversion: 20 * log10(value), clamped at -80 dB floor.
        // 5. Yield onto the stream.
        let sample = LevelSample(source: source,
                                 peakDb: peak,
                                 rmsDb:  rms,
                                 timestamp: now)
        continuation.yield(sample)
    }

    deinit { continuation.finish() }
}
```

**`LevelMeterPublisher`** (façade owning both taps, merging streams):

```swift
public final class LevelMeterPublisher {
    private let micTap:    LevelMeterTap
    private let systemTap: LevelMeterTap
    public  let stream: AsyncStream<LevelSample>   // merged

    public init(micFormat: AVAudioFormat, systemFormat: AVAudioFormat) { ... }

    /// Wired from RecordingController.start():
    ///   session.systemAudioSource.levelTap = { publisher.systemTap.ingest($0) }
    ///   session.microphoneSource.levelTap   = { publisher.micTap.ingest($0) }
    public func handleSystem(_ buf: CaptureBuffer) { systemTap.ingest(buf) }
    public func handleMic(_ buf: CaptureBuffer)    { micTap.ingest(buf) }
}
```

**Properties (per investigation Topic 5)**:

- **Allocation**: zero on the audio thread. The `AVAudioPCMBuffer` is
  pre-allocated at 4096 samples × stereo Float32 (~64 KB per source ×
  2 sources = 128 KB total).
- **Coalescing**: 30 Hz cap via `OSAllocatedUnfairLock<ContinuousClock.Instant>`.
  Buffers arriving more often than 33 ms apart are dropped (level
  meters do not need every buffer).
- **Back-pressure**: `AsyncStream` constructed with
  `.bufferingPolicy: .bufferingNewest(2)` so a slow consumer (UI lag)
  cannot back up audio-thread memory.
- **Per-source isolation**: separate `AVAudioPCMBuffer` per source
  (sharing one would race).
- **dB floor**: `20 * log10(0)` is `-inf`; clamped to `-80 dB`.
- **stereo-split layout**: meters still report per-source (mic vs
  system), not per-channel — agreed by FR-43.

**Consumer side (`RecordingController.levelsTask`)**:

```swift
private func observeLevels() {
    levelsTask = Task { @MainActor in
        for await sample in levelMeterPublisher.stream {
            self.levels[sample.source] = sample
        }
    }
}
```

`LevelMeterView` reads `recordingController.levels[.mic]` and
`recordingController.levels[.system]` and applies
`.animation(.linear(duration: 0.05))` for visual smoothing
(investigation Topic 5).

### 15.8 Permission-Status Panel (FR-37)

Per FR-37, the panel polls `PermissionGate.snapshot()` on a 2-second
cadence ONLY while the popover is visible. Two reasons: (a)
battery-friendly — no work when the user isn't looking; (b)
correctness — TCC state cannot change while the user is in our
popover, only via System Settings, which is a foreground app
transition we already detect.

**Polling lifecycle** (Phase E `PermissionStatusView`):

```
View .task { ... }                     ← starts when popover opens
  │
  ▼
while !Task.isCancelled {
    let snap = await permissionGate.snapshot()
    recordingController.permissionSnapshot = snap
    try? await Task.sleep(for: .seconds(2))
}
                                       ← cancelled when popover closes

NotificationCenter (NSApplication.didBecomeActiveNotification)
  │
  ▼
Task { await permissionGate.snapshot() }   ← immediate refresh
```

**Visual contract**:

| State | Visual | On click |
|-------|--------|----------|
| `granted` | Green dot + checkmark | (no-op) |
| `denied` | Red dot + "Open Settings…" affordance | Opens `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` (or `Privacy_Microphone`) — exact deep links pinned in §8 above |
| `notDetermined` | Yellow dot + "Grant…" affordance | Calls `ScreenRecordingPermission.request()` (or `MicrophonePermission.request()`); on macOS this triggers the system TCC prompt the first time, no-op afterwards |

**Start-button gating** (`ControlBar`): Start is enabled iff
`recordingController.permissionSnapshot?.bothAuthorized == true` AND
`state == .idle`. Tooltip on disabled-due-to-permission state:
"Screen Recording and Microphone permissions are required."

### 15.9 `Package.swift` Diff (Phase B)

The new build slot is a single `executableTarget` plus a separate
`Resources/MacrecUI-Info.plist`. After AMB-3 resolution (Phase D), a
`MacrecUIKit` library target is also added so `MacrecUITests` can
import the UI domain layer; the executable target then contains only
the AppKit shell.

```swift
// Package.swift  (unified diff against the current state)

let package = Package(
    name: "macrec",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macrec",    targets: ["macrec"]),
        .library   (name: "MacrecCore", targets: ["MacrecCore"]),
+       .executable(name: "macrec-ui", targets: ["macrec-ui"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log",             from: "1.5.0"),
    ],
    targets: [
        .target(name: "MacrecCore", dependencies: [
            .product(name: "Logging",        package: "swift-log"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "macrec", dependencies: [
            "MacrecCore",
            .product(name: "Logging",        package: "swift-log"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                          "-Xlinker", "__info_plist",
                          "-Xlinker", "Resources/Info.plist"])
        ]),
+       .target(name: "MacrecUIKit",
+               dependencies: [
+                   "MacrecCore",
+                   .product(name: "Logging", package: "swift-log"),
+               ],
+               path: "Sources/MacrecUIKit"),
+       .executableTarget(name: "macrec-ui",
+               dependencies: [
+                   "MacrecCore",
+                   "MacrecUIKit",
+                   .product(name: "Logging", package: "swift-log"),
+               ],
+               path: "Sources/macrec-ui",
+               linkerSettings: [
+                   .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
+                                 "-Xlinker", "__info_plist",
+                                 "-Xlinker", "Resources/MacrecUI-Info.plist"])
+               ]),
        .testTarget(name: "MacrecCoreTests", dependencies: ["MacrecCore"]),
+       .testTarget(name: "MacrecUITests",
+                   dependencies: ["MacrecUIKit"],
+                   path: "Tests/MacrecUITests"),
    ]
)
```

> **Note on the AMB-3 split**: the plan §6.1 file manifest lists every
> Domain/ and Views/ file under `Sources/macrec-ui/`. After Phase D's
> `MacrecUIKit` introduction, those files physically move to
> `Sources/MacrecUIKit/` (subfolders preserved). `MacrecUIApp.swift`,
> `AppDelegate.swift`, `StatusItemController.swift`, and
> `PopoverController.swift` remain in `Sources/macrec-ui/` (they
> reference AppKit and `@main`, which an `executableTarget` requires).
> The executable target depends on `MacrecUIKit`. This is a SwiftPM
> mechanical re-shape; the runtime architecture in §15.1 is unchanged.

**`Resources/MacrecUI-Info.plist`** (verbatim from investigation Topic 7):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>            <string>com.local.macrec-ui</string>
    <key>CFBundleName</key>                  <string>macrec-ui</string>
    <key>CFBundleDisplayName</key>           <string>macrec-ui</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>0.1.0</string>
    <key>CFBundleExecutable</key>            <string>macrec-ui</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>macrec-ui records the microphone alongside system audio. Audio is
written only to the file path you choose. Nothing is sent over the network.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>macrec-ui uses the Screen Recording permission to capture system
audio (the audio output of all running applications) via ScreenCaptureKit.
No video frames are saved; only audio is recorded.</string>
    <key>NSScreenCaptureDescription</key>
    <string>macrec-ui uses the Screen Recording permission to capture system
audio (the audio output of all running applications) via ScreenCaptureKit.
No video frames are saved; only audio is recorded.</string>
</dict>
</plist>
```

> **TCC identity drift (R-23)**: `com.local.macrec-ui` ≠
> `com.local.macrec`. Granting Screen Recording to the CLI does NOT
> grant it to the UI; users will be prompted again on first UI run.
> Documented in `Issues - Pending Items.md` and `docs/tools/macrec-ui.md`
> per FR-44.

**Universal-binary build** (NFR-15): unchanged from existing CLI
guidance — `swift build -c release --arch arm64 --arch x86_64` for
both products. The `macrec-ui` target inherits the same
`platforms: [.macOS(.v14)]` constraint.

### 15.10 Error-Handling Strategy (NFR-12)

The UI MUST NOT introduce a parallel error type. Every engine-thrown
error is `MacrecError` (existing 26 cases, `Sources/MacrecCore/Errors/MacrecError.swift`).
The UI translates each case to a user-visible string via a single
helper:

```swift
enum UIErrorPresenter {
    struct Presentation {
        let title: String
        let message: String
        let recovery: RecoveryAction?
    }
    enum RecoveryAction {
        case openScreenRecordingSettings
        case openMicrophoneSettings
        case retry
        case dismiss
    }

    static func present(_ error: MacrecError) -> Presentation {
        // dispatch on the case; pull description + remediation from
        // the error itself (Sources/MacrecCore/Errors/MacrecError.swift),
        // then attach a recovery action where applicable.
    }
}
```

**Surfacing path**:

```
RecordingSession run() throws MacrecError
  │
  ▼
session.stateStream emits .failed(error)
  │
  ▼
SessionCoordinator forwards .failed(error)
  │
  ▼
RecordingController.stateTask receives .failed(error)
  │   self.state = .failed(error)
  │   let p = UIErrorPresenter.present(error)
  │   self.latestErrorMessage = "\(p.title): \(p.message)"
  │   logger.error("session failed: \(error)")
  │   schedule auto-clear after 8 s
  ▼
SwiftUI ErrorBanner observes recordingController.latestErrorMessage
  │
  ▼
User sees a non-modal banner at the top of the popover; clicking it
either dismisses (`.dismiss`) or invokes the recovery action.
```

**NFR-12 invariant**: a recoverable engine error MUST NOT bring down
the UI process. The `.failed` state is observable and recoverable
(user clicks Start again to begin a new session). Unrecoverable
exceptions (e.g., an actor crash from misuse) are not in scope —
those would propagate via Swift's normal trapping mechanism, and
v1 accepts the resulting process crash because no in-process
supervision strategy is feasible without significant complexity.

**Mapping table** (for Phase G coder + Phase 9 Test Builder):

| `MacrecError` case (selected) | Presentation title | Recovery action |
|-------------------------------|--------------------|-----------------|
| `.screenRecordingPermissionDenied` | "Screen Recording permission denied" | `openScreenRecordingSettings` |
| `.microphonePermissionDenied`      | "Microphone permission denied"      | `openMicrophoneSettings`     |
| `.scStreamFailedToStart(reason:)`  | "Failed to start system-audio capture" | `retry` |
| `.recorderFinalizeTimeout(...)`    | "File finalize took too long; partial file saved" | `dismiss` |
| `.outputPathInvalid(...)`          | "Output path is invalid"            | `dismiss` (user fixes path) |
| `.missingRequiredConfig(...)`      | "Required configuration missing"    | `dismiss` |
| (all others)                       | error.description                    | `dismiss` |

All errors are also logged at `.error` level via
`logger.error("...")` per NFR-16.

### 15.11 Quit-While-Recording Flow (OQ-UI-10)

Quit semantics are locked: confirm dialog → finalize current file →
quit. The flow must integrate with AppKit's
`applicationShouldTerminate(_:)` because macOS routes quit requests
(Cmd-Q via menu, `NSApp.terminate`, login-out, system-shutdown)
through that delegate method.

**Algorithm** (Phase F):

```
applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply
  │
  ▼
let active : Bool = recordingController.state ∈ {
    .recording, .pausing, .paused, .resuming, .splitting }

if !active {
    return .terminateNow            ← idle/stopped/failed: quit immediately
}

let alert = NSAlert(...)
  alert.messageText      = "Stop recording and quit?"
  alert.informativeText  = "The current file will be finalized and saved."
  alert.addButton(withTitle: "Cancel")          // .alertFirstButtonReturn (1000)
  alert.addButton(withTitle: "Stop & Quit")     // .alertSecondButtonReturn (1001)
let response = alert.runModal()

if response == .alertFirstButtonReturn {
    return .terminateCancel         ← user backs out; recording continues
}

// User chose "Stop & Quit":
recordingController.requestStop()   ← coordinator.stop() under the hood

Task { @MainActor in
    // Wait for terminal state.
    for await s in recordingController.stateChangeStream {
        if s == .stopped || (case .failed = s) {
            NSApp.reply(toApplicationShouldTerminate: true)
            break
        }
    }
}

return .terminateLater              ← AppKit defers quit until reply()
```

**`NSAlert` modality + popover**: the alert is presented as a
window-modal sheet on the popover or as a stand-alone modal if the
popover is closed. Per Topic 1 gotcha, `popover.behavior` should be
switched to `.semitransient` for the duration of the alert and
restored to `.transient` after, to prevent the popover from dismissing
underneath the alert.

**Quit menu item**: per `LSUIElement=true`, there is no app menu in
the menu bar. The "Quit" affordance is a button at the bottom of the
popover (or an item in the status-item right-click context menu)
that calls `NSApp.terminate(nil)`, which routes through
`applicationShouldTerminate(_:)` above.

**`stateChangeStream`**: a small helper on `RecordingController` that
exposes the same data as `state` but as an `AsyncStream<SessionState>`
so the quit handler can `for await` for the terminal transition without
spinning. Implemented as a thin `AsyncStream`-emitting wrapper around
the controller's existing state observation.

### 15.12 Threading & Concurrency Model

The toolbar UI introduces three concurrent contexts; each has a clear
contract enforced at compile time by Swift Concurrency annotations.

| Context | Isolation | Responsibilities | Forbidden |
|---------|-----------|------------------|-----------|
| `MacrecUIApp`, `RootView` and all `Views/` | `@MainActor` (default in macOS 14+ SwiftUI) | Render observed state; emit user actions via `recordingController.<method>()` | Direct mutation of engine state; blocking calls |
| `RecordingController` | `@MainActor @Observable` | Owns observed state; drives Tasks; routes user actions to coordinator | Direct creation of `RecordingSession` (delegates to coordinator); cancel runTask except on `cancelAll()` |
| `SessionCoordinator` | `actor` (cooperative thread pool) | Segment counter, current session reference, multi-segment orchestration; emit synthetic `.pausing` / `.paused` / `.resuming` | Touching SwiftUI state; reading observed properties on the controller |
| `RecordingSession` (existing) | `@unchecked Sendable` + private `serialQueue` | State transitions; engine lifecycle; emit `stateStream`; perform `split()` swap on `serialQueue` | (unchanged from §1) |
| Capture queues (`macrec.capture.system`, `macrec.capture.mic`) | `userInteractive` `DispatchQueue` (engine-internal) | Deliver `CaptureBuffer` to `onSampleBuffer` AND `levelTap` | Touching UI state directly — must route through `LevelMeterPublisher`'s `AsyncStream` |
| Aligner queue (`macrec.aligner.serial`) | private `DispatchQueue` (engine-internal) | Read `_recorder` via `OSAllocatedUnfairLock`; call `recorder.append(frame)` | (unchanged from §1) |

**Crossing rules**:

- AppKit shell (`AppDelegate` etc.) is implicitly main-thread (AppKit
  contract). The shell stores `RecordingController` and passes it
  into SwiftUI via `.environment`; calls onto the controller from the
  shell are direct method calls (already `@MainActor`).
- `RecordingController → SessionCoordinator`: every call is
  `await`-prefixed; no shared state between the actors.
- `SessionCoordinator → RecordingSession`: same — `await session.run()`
  / `session.requestStop()` / `await session.split(nextOutput:)`. Note
  that `requestStop()` is non-async (existing API) and posts to the
  engine's `serialQueue` internally.
- **`levelTap` callbacks fire on the engine's capture queues**. They
  MUST NOT touch SwiftUI / `RecordingController` / `SessionCoordinator`
  state directly. They call `LevelMeterPublisher.handle{System,Mic}(_:)`
  which yields onto the `AsyncStream`, whose consumer is
  `@MainActor`-isolated.

### 15.13 Logging (NFR-16)

UI logs go through the existing `LoggerFactory` / `swift-log`
pipeline (engine logs are unchanged):

- `LoggerFactory.bootstrap(level: .info)` in `AppDelegate.applicationDidFinishLaunching`,
  early — before any other component logs.
- Each UI component receives a `Logger` from `LoggerFactory.make("macrec.ui.<subsystem>")`:
  - `macrec.ui.app` (AppDelegate)
  - `macrec.ui.controller` (RecordingController)
  - `macrec.ui.session` (SessionCoordinator)
  - `macrec.ui.permissions` (PermissionStatusView's Task)
  - `macrec.ui.devices` (MicrophonePicker)
- **Per-UI log file** (NFR-16): `~/.tool-agents/macrec-ui/macrec-ui.log`
  (mode `0600`, append). Created via `ToolAgentsBootstrap.ensure(toolName:
  "macrec-ui")` (existing helper, reused as-is). When running outside
  an Xcode debugger session (detected by `isatty(STDERR_FILENO) == 0`
  OR `_PATH_DEVNULL` heuristic), the AppDelegate `dup2`s the log
  file descriptor onto `STDERR_FILENO` so swift-log's
  `StreamLogHandler.standardError` lands in the file. Same pattern
  as `Daemonizer` minus the double-fork (the UI is a foreground
  accessory app).
- **Hidden debug toggle**: `UILoggingMenu` adds "Show debug log" /
  "Hide debug log" items to the status-item context menu. Toggling
  re-bootstraps `LoggerFactory.bootstrap(level: .debug)` (the
  function is documented idempotent in §6.1 above).
- **OSLog backend**: as v1 ships with `swift-log`'s default
  `StreamLogHandler.standardError`, logs land in the file (and
  appear in Console.app via `tail -f`). A future v1.x may swap in an
  `OSLogHandler` for native Console.app integration; out of v1 scope.

### 15.14 Parallel-Implementation Units (cross-reference plan-002 Wave map)

The plan-002 §3 phasing already defines a Wave 1..7 dispatch map for
Phase 6 (parallel coders). This design confirms which sub-tasks are
genuinely independent (no shared file, no shared symbol authored by
both agents) and which require strict sequencing.

| Wave | Phase(s) | Independent units | Shared boundary owners |
|------|----------|-------------------|------------------------|
| **Wave 1** | A + B | A and B touch disjoint files. Within A: (i) `SessionState.swift`, (ii) `levelTap` on SCKitSystemAudioSource, (iii) `levelTap` on AVMicrophoneSource, (iv) `PermissionGating` extraction — all four can be assigned to four agents. The fifth job — `RecordingSession.swift` (state stream + split + lock refactor + permission injection) — is tightly coupled and goes to ONE agent. | Phase A's `RecordingSession.swift` is the bottleneck within Wave 1. |
| **Wave 2** | C | `MacrecUIApp` + `AppDelegate` + `StatusItemController` + `PopoverController` + placeholder `RootView` — tightly coupled (each is wired by `AppDelegate`). ONE agent. | n/a — single-coder phase. |
| **Wave 3** | D | (i) `FilenameGenerator`, (ii) `SegmentNamer`, (iii) `LevelSample`, (iv) `LevelMeterTap` — four agents. (v) `RecordingController` + `SessionCoordinator` — ONE agent (tight coupling). (vi) `LevelMeterPublisher` — depends on `LevelMeterTap`; same agent as (iv) is cleanest. | `Package.swift` edit (add `MacrecUIKit` lib target) is owned by the (v) agent so the test target compiles. |
| **Wave 4** | E + H + J | E sub-views — up to TEN agents (one per file under `Views/`). H — ONE agent (touches AppDelegate + adds two new files; non-overlapping with C/F edits). J — ONE agent (docs only). | E's `RootView` integration is owned by an eleventh agent that pulls all sub-views together. |
| **Wave 5** | F + G | F (Quit-while-recording) and G (Error mapping) touch different files; two agents in parallel. | n/a — cross-file boundary respected. |
| **Wave 6** | I | Verification audit; ONE agent. | n/a |
| **Wave 7** | K | Manual smoke test; ONE developer. | n/a |

**Maximum theoretical parallel agents**: 11 (Wave 4: ten view files +
H + J = twelve, but `RootView` integration must wait for the ten so
practical max is around 11 concurrent).

### 15.15 Interface Contracts Across Wave Boundaries

For each wave-spanning interface, this table fixes the exact symbol
signature one wave produces and the next wave consumes. Phase 6
coders are dispatched against these contracts; an agent MUST NOT
deviate without a Phase 5 amendment.

#### Wave 1 → Wave 2 (Phase A → Phase C)

| Producer (Wave 1, Phase A) | Consumer (Wave 2, Phase C) | Symbol | File |
|----------------------------|----------------------------|--------|------|
| A | C | `enum SessionState: Sendable, Equatable` (cases per §15.3.1) | `Sources/MacrecCore/SessionState.swift` |
| A | C | `RecordingSession.stateStream: AsyncStream<SessionState> { get }` | `Sources/MacrecCore/RecordingSession.swift` |
| A | C (indirectly, via D) | `RecordingSession.split(nextOutput: URL) async throws` | `Sources/MacrecCore/RecordingSession.swift` |
| A | C, D | `protocol PermissionGating: Sendable { func snapshot() async -> PermissionGate.Snapshot; func requireBothOrThrow() async throws }` | `Sources/MacrecCore/Permissions/PermissionGate.swift` |
| A | D | `SCKitSystemAudioSource.levelTap: ((CaptureBuffer) -> Void)?` | `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift` |
| A | D | `AVMicrophoneSource.levelTap: ((CaptureBuffer) -> Void)?` | `Sources/MacrecCore/Capture/AVMicrophoneSource.swift` |

#### Wave 2 → Wave 3 (Phase C → Phase D)

| Producer (Wave 2) | Consumer (Wave 3) | Symbol | File |
|-------------------|-------------------|--------|------|
| C | D | `final class AppDelegate: NSObject, NSApplicationDelegate` (must hold `var recordingController: RecordingController!`) | `Sources/macrec-ui/AppDelegate.swift` |
| C | D | `final class StatusItemController { func setIcon(for state: SessionState) }` | `Sources/macrec-ui/StatusItemController.swift` |
| C | D | `final class PopoverController { func toggle(relativeTo:); func close(); func setBehavior(_:) }` | `Sources/macrec-ui/PopoverController.swift` |
| C | D | `struct RootView: View` (placeholder; replaced by E) | `Sources/macrec-ui/RootView.swift` |

#### Wave 3 → Wave 4 (Phase D → Phase E)

| Producer (Wave 3) | Consumer (Wave 4) | Symbol | File |
|-------------------|-------------------|--------|------|
| D | E | `@MainActor @Observable final class RecordingController` with the public surface listed in §15.4 | `Sources/MacrecUIKit/Domain/RecordingController.swift` |
| D | E | `actor SessionCoordinator` (transition table §15.5) | `Sources/MacrecUIKit/Domain/SessionCoordinator.swift` |
| D | E | `struct FilenameGenerator { static func defaultBasename(now: Date) -> String }` | `Sources/MacrecUIKit/Domain/FilenameGenerator.swift` |
| D | E | `enum SegmentNamer { static func urls(...) -> [URL]; static func url(...) -> URL }` | `Sources/MacrecUIKit/Domain/SegmentNamer.swift` |
| D | E | `struct LevelSample: Sendable { source; peakDb; rmsDb; timestamp }` | `Sources/MacrecUIKit/Domain/LevelSample.swift` |
| D | E | `final class LevelMeterPublisher { var stream: AsyncStream<LevelSample> }` | `Sources/MacrecUIKit/Domain/LevelMeterPublisher.swift` |
| D | E | `EnvironmentValues.recordingController` (EnvironmentKey wired in `RecordingControllerKey.swift`) | `Sources/MacrecUIKit/Views/RecordingControllerKey.swift` |

#### Wave 4 → Wave 5 (Phase E → Phases F, G)

| Producer (Wave 4) | Consumer (Wave 5) | Symbol | File |
|-------------------|-------------------|--------|------|
| E | F | `RootView` body composition (Quit button hook + popover behavior toggling) | `Sources/MacrecUIKit/Views/RootView.swift` |
| E | G | `RootView` body slot for `ErrorBanner` (top of stack) | `Sources/MacrecUIKit/Views/RootView.swift` |
| D (carry-forward) | G | `RecordingController.latestErrorMessage: String?` | `Sources/MacrecUIKit/Domain/RecordingController.swift` |

> All Wave-4 view files are independent of each other given the
> Wave-3 contracts above. The Wave-4 → Wave-5 boundary is a
> single-file boundary (`RootView.swift`) — F and G both edit it,
> but at different positions (F adds a Quit button, G adds an
> `ErrorBanner` at the top). To prevent merge conflicts, F and G
> are dispatched sequentially within Wave 5 (F first, then G; or G
> first, then F — order is interchangeable as long as they do not
> run concurrently against the same file).

### 15.16 Architectural Decision Records — toolbar UI extension

The following ADRs are **appended** to the table in Section 12 above.
They lock the seven topic-level decisions made by the investigation
(Topics 1–7) and the four UI-architecture macro-locks from refined-
spec "Decisions Locked".

| ADR  | Decision | One-line rationale | Driver |
|------|----------|--------------------|--------|
| 032  | UI shell = AppKit `NSStatusItem` + `NSPopover` + `NSHostingController<RootView>` (NOT SwiftUI `MenuBarExtra`) | `MenuBarExtra` has four open Apple Feedback issues that block FR-41 dynamic icon, programmatic dismiss, and `interactiveDismissDisabled`; `NSStatusItem` pattern is the 2025 community recommendation | Investigation Topic 1; FR-41; OQ-UI-1 lock |
| 033  | Process model = in-process linking of `MacrecCore` (no subprocess shell-out to `macrec` CLI) | Pause, split, level meters, and `SessionState` stream all need fine-grained sync coordination that subprocess IPC would complicate | OQ-UI-4 / OQ-PROC-1 lock; FR-42 |
| 034  | Pause semantics = stop-and-stitch (multi-file via `partNN` suffix); orchestration in UI-side `SessionCoordinator` actor | Engine surface stays single-segment (no engine refactor); composes cleanly with manual split (same primitive); side-steps `SCStream` "cannot reuse a stopped stream" constraint | OQ-UI-2 / OQ-CORE-1 lock; FR-31, FR-34; investigation Topic 3 |
| 035  | Manual split = single-recorder atomic swap on `RecordingSession.serialQueue`, `_recorder` guarded by `OSAllocatedUnfairLock<Recorder?>` | One recorder live at a time → minimum memory; reference-swap on a serial queue is well-understood; ≤ ~52 ms audible seam vs. 250 ms ceiling | Investigation Topic 4; FR-32; AC-UI-7 |
| 036  | View-model pattern = `@MainActor @Observable RecordingController` owning unstructured `Task`s + `AsyncStream<SessionState>` | Per-property fine-grained tracking outperforms `ObservableObject` for high-frequency level-meter updates; smallest engine change (only adds `stateStream` continuation) | Investigation Topic 2; FR-33 |
| 037  | Level meters = `levelTap` closure on each capture source + vDSP peak/RMS on pre-allocated `AVAudioPCMBuffer` + 30 Hz coalesced `AsyncStream<LevelSample>` | Non-allocating audio path; codebase-scan §4.3 explicitly recommends this placement; 30 Hz is sufficient for visual smoothness | Investigation Topic 5; FR-43 |
| 038  | Filename auto-generation = standalone `FilenameGenerator` struct in `Sources/macrec-ui/` (NOT in `MacrecCore`) | Engine API surface stays free of UI-only concerns; CLI requires `--output` explicitly; ~15 LOC, trivial test surface | Investigation Topic 6; codebase-scan §4.3; AMB-3 |
| 039  | Info.plist embedding = `-sectcreate __TEXT __info_plist Resources/MacrecUI-Info.plist` linker flag (separate plist from CLI) | Reuses proven CLI mechanism; SwiftPM `resources:` rejects `Info.plist`; works on CommandLineTools only (NFR-14) | Investigation Topic 7; NFR-14, NFR-15 |
| 040  | `_recorder` lock = `OSAllocatedUnfairLock<Recorder?>` (NOT classic `os_unfair_lock_s`) | macOS 14+ project minimum makes the API available; `Sendable`-friendly; scoped `withLock` API | Investigation Topic 4 §"Implementation considerations"; AMB-2 |
| 041  | `SessionCoordinator` placement = `Sources/MacrecUIKit/Domain/` (UI module, NOT `MacrecCore`) | Only touches `RecordingSession` via `await` — no audio-callback bridging; no engine consumer | Investigation Topic 3; AMB-4 |
| 042  | `splitting` is a discrete `SessionState` case (NOT a transient flag on `recording`) | Keeps FR-33 enum exhaustive; UI may render identically to `recording`; tests assert deterministic sequence | Refined-spec FR-33; AMB-1 |

### 15.17 Acceptance-Criteria Coverage from this Design

Cross-reference of each AC-UI-* to the design section that satisfies it:

| AC | Design section that satisfies it |
|----|----------------------------------|
| AC-UI-1 (`swift build` clean) | §15.9 (Package.swift diff; no deprecated APIs) |
| AC-UI-2 (first-launch "not determined") | §15.8 (PermissionStatusView polling lifecycle) |
| AC-UI-3 (click prompt / open Settings) | §15.8 (deep-link table) |
| AC-UI-4 (Start ≤ 1 s; icon ≤ 100 ms) | §15.1 (architecture diagram), §15.4 (RecordingController.start), §15.3.1 (engine `.recording` emit) |
| AC-UI-5 (Stop produces playable file ±0.5 s) | §15.5 (coordinator.stop), §15.3.1 (`.stopped` emit), §15.4 (segment append) |
| AC-UI-6 (Pause/Resume produces partNN files) | §15.5 (state-transition table), §15.6 (FR-34 naming) |
| AC-UI-7 (split seam ≤ 250 ms) | §15.3.2 (algorithm + ~52 ms upper bound) |
| AC-UI-8 (filename field locks) | §15.4 (UI inputs disabled while non-`.idle`) |
| AC-UI-9 (folder picker persists) | §15.4 (RecordingController.folder via `@AppStorage`) |
| AC-UI-10 (split layout × pause = four files) | §15.6 (SegmentNamer.urls multi-segment split shape) |
| AC-UI-11 (mic dropdown refresh ≤ 2 s) | §15.2 (MicrophonePicker on AVCaptureDeviceWasConnectedNotification) |
| AC-UI-12 (elapsed at 1 Hz; freezes on pause) | §15.4 (`elapsedTask` only while `.recording`) |
| AC-UI-13 (force-quit leaves playable partial) | §15.3.1 + reuses existing FR-21 m4a fragment-interval flush |
| AC-UI-14 (CLI AC-1..AC-20 still pass) | §15.3 (additive engine extensions; existing call-sites unchanged) |
| AC-UI-15 (docs/tools/macrec-ui.md + .env + ## Tools) | Plan-002 Phase 0 / J (NOT this design — orchestrator dispatches `/tool-conventions scaffold`) |
| AC-UI-16 (project-functions.md FR-30..FR-44) | Plan-002 Phase 0 / J |
| **AC-UI-17 (project-design.md UI section)** | **THIS SECTION** |
| AC-UI-18 (Issues - Pending Items.md updated) | Plan-002 Phase 0 / J / K |

### 15.18 Consistency Pass — Locked Decisions Confirmed Against this Design

| Locked decision (refined-spec table) | Reflected in design at |
|---|---|
| OQ-UI-1: NSStatusItem + NSPopover | §15.1, §15.2, ADR 032 |
| OQ-UI-2 / OQ-CORE-1: stop-and-stitch | §15.5, ADR 034 |
| OQ-UI-3: manual split only | §15.3.2, ADR 035 |
| OQ-UI-4 / OQ-PROC-1: in-process | §15.1, ADR 033 |
| OQ-UI-5: auto-named timestamp, editable pre-record | §15.6 (FilenameGenerator), §15.4 (basename input locked while non-`.idle`) |
| OQ-UI-6 — core: elapsed + format + layout + permissions | §15.2 (Views/ list), §15.4, §15.8 |
| OQ-UI-6 — optional: folder + mic + level meters | §15.2 (Views/ list), §15.7 |
| OQ-UI-7 / OQ-DIST-1: SwiftPM executableTarget in same Package.swift | §15.9 |
| OQ-UI-8 / OQ-NAME-1: `macrec-ui` | §15.2, §15.9 (CFBundleIdentifier=com.local.macrec-ui) |
| OQ-UI-9: sit quietly in menu bar | §15.1 (`Settings { EmptyView() }`), §15.10 (no auto-open) |
| OQ-UI-10: confirm → finalize → quit | §15.11 |
| OQ-UI-11: split-layout disclosure | §15.2 (SavedToDisclosure) |

All twelve locked decisions are anchored in this design.

---

## Live Transcription Subsystem (Plan-003)

> **Superseded sections.** §LT-10 / §LT-10.1 / §LT-10.2 (WebSocket
> session lifecycle), §LT-10.1 + §LT-12 (reconnect state machine),
> §LT-5.5 step 8 (detach cross-check), §LT-0 row D-LT-2 (30 ms wire
> chunking), and §LT-7.2 / §LT-9.1 (header/footer rewrite) are
> superseded by plan-004 (REST batch architecture).
> See `docs/design/plan-004-rest-batch-transcription.md`.

> **Added 2026-04-26 (Phase 5 — Designer)**. Owns the technical design for the
> opt-in, model-pluggable live transcription side-channel introduced by
> `plan-003-live-transcription.md`. Builds directly on:
>
> 1. `docs/design/refined-request-live-transcription.md` (FR-45..FR-58, NFR-17..NFR-21, AC-LT-1..AC-LT-25, A-LT-1..A-LT-10).
> 2. `docs/design/plan-003-live-transcription.md` (Phases 0..I, file manifest, AC coverage matrix, parallelization map, locks in §2.3).
> 3. `docs/reference/investigation-live-transcription.md` (Option-1 recommendation: Gemini Live via direct `URLSessionWebSocketTask`).
> 4. `docs/research/gemini-live-wire-schema.md` (CRITICAL: `responseModalities: ["AUDIO"]` + `inputAudioTranscription: {}` — `["TEXT"]` is rejected on `gemini-3.1-flash-live-preview`).
> 5. `docs/research/audio-downsample-conversion.md` (drop-in `AudioDownsampler`).
> 6. `docs/research/websocket-asyncstream-pattern.md` (`WebSocketSession` actor, reconnection state machine).
> 7. `docs/reference/codebase-scan-live-transcription.md` (integration points and the `withOutput(_:)` latent bug).
>
> This section is **strictly additive**. With `--transcribe none` (the default)
> every existing AC-1..AC-20 (plan-001) and AC-UI-1..AC-UI-18 (plan-002) MUST
> continue to pass; nothing in §§1–15 changes.

### LT-0. Discrepancies Surfaced Against Plan-003

These are flagged at the top so the user can decide whether to revise the plan
or change the design. The design proceeds on the recorded resolution; if the
resolution is wrong, only the affected sub-section needs revisiting.

| # | Discrepancy | Source | Resolution adopted by this design |
|---|---|---|---|
| **D-LT-1** | Plan-003 §4 Phase A says `TranscriptionPCMChunk` carries `pcmData: Data` (already-downsampled bytes), and §0.3 says the bounded stream is `AsyncStream<TranscriptionPCMChunk>`. The investigation §Recommendation pt. 9 says `AsyncStream<TranscriptionPCMChunk>` with `bufferingNewest(64)` ≈ 60 KB → **the chunk is post-downsampler PCM16-16k bytes**. | Plan-003 §0.3, §4 Phase A; Investigation pt. 9 | **Adopt: bounded stream carries POST-downsampler `TranscriptionPCMChunk` (PCM16-16k-mono `Data`).** The downsampler runs synchronously inside the tap producer, before the bounded yield. Rationale: smaller payload (~3 200 B per 100 ms vs. ~38 400 B for Float32-stereo-48k), simpler provider contract (every provider gets the same shape), aligns with NFR-19 budget calculation in plan-003. **Consequence**: no separate `AsyncStream<AlignedFrame>` exists. The tap closure copies bytes off the `AlignedFrame`, the producer Task runs the downsampler, and the bounded stream is `AsyncStream<TranscriptionPCMChunk>`. See §LT-6. |
| **D-LT-2** | Plan-003 §4 Phase F describes splitting each ~100 ms downsampled chunk into ~3 × 30 ms chunks before WebSocket send, but §0.3 says the bounded stream's element is "the chunk". | Plan-003 §0.3, §4 Phase F | **Adopt: the bounded stream's element is the 100 ms chunk** (one yield per `AlignedFrame`); the **provider** (Gemini) is responsible for splitting on send. Rationale: keeps the bounded stream's chunk count == aligner-window count (deterministic for tests), and concentrates Gemini-specific cadence concerns inside `GeminiLiveTranscriptionProvider`. Other providers (OpenAI Realtime needs 24 kHz; Deepgram accepts arbitrary cadence) can choose their own send cadence without renegotiating the upstream contract. |
| **D-LT-3** | Refined request prototypes the protocol as `start(audio:) async throws -> AsyncStream<TranscriptEvent>` + `stop()`. Plan-003 §4 Phase A and investigation pt. 10 use a single `run(audio:options:) -> AsyncStream<TranscriptEvent>` whose lifetime is the calling Task's lifetime — cancellation = stop. | Refined-request §Provider abstraction example; Plan-003; Investigation pt. 10 | **Adopt: single `run(audio:options:) -> AsyncStream<TranscriptEvent>`** (plan/investigation shape). The original `start()`/`stop()` from the user's prompt is preserved as a logical contract: starting a recording starts the run task; stopping it cancels the task. The protocol's `Sendable` conformance and the test-fakes' determinism are easier with a single function. The user's prompt-prescribed shape is documented as an alternative in this section so the designer can revisit if requested, but the implementation follows the plan. |
| **D-LT-4** | Plan-003 §4 Phase F says the API key flows in via the WebSocket URL query parameter (`?key=...`); the user's prompt for this design said "shell env → `~/.tool-agents/macrec/.env` → local `.env` → CLI flags (highest priority)". | Plan-003 §4 Phase F (URL); Codebase scan §3 (resolver chain) | **Adopt both** — they are different layers. **Resolution** of the value uses the four-tier chain (codebase scan §3, design §LT-5). **Wire transport** of the resolved value uses the URL query parameter per Gemini's API-key client convention (§LT-9). The two are independent. |
| **D-LT-5** | The user's prompt for this design defined the `TranscriptionProvider` shape with `providerId: TranscriptionProviderId` (typed enum). Plan-003 §4 Phase A defines `providerId: String` (verbatim from investigation pt. 10). | Plan-003 §4 Phase A; Investigation pt. 10 | **Adopt: `providerId: String`** (plan/investigation shape) on the protocol. The typed `TranscriptionProviderId` enum exists separately and is used at parse / configuration time (`TranscriptionProviderId.parse(_:)`). The protocol's string-typed `providerId` lets future external providers (a hypothetical user-supplied dynamic loader) ship without modifying the enum. The matching enum is the canonical one for resolved configuration. |
| **D-LT-6** | The user's prompt requests a `TranscriptionError` type. Plan-003 §4 Phase A puts the error category inside `MacrecError` and uses `String` reasons inside `TranscriptEvent.error`. | Plan-003 §4 Phase A; Codebase scan §4.5 | **Adopt: no separate `TranscriptionError` type.** The CLI / configuration-time errors live on `MacrecError` (matches the project's no-fallback / locked-exit-code contract). Provider-runtime errors flow through `TranscriptEvent.error(reason: String, isFatal: Bool)` per plan-003. Adding a parallel error enum would diverge from the existing locked-stack. |
| **D-LT-7** | The user's prompt mentions exit codes "consult the codebase scan §5". The locked exit-code table is in **§9.5** of this very design (codebase scan §4.5 references it). | Project-design §9.5; Codebase scan §4.5 | **Adopt: §9.5 of this document is authoritative.** The new `MacrecError` cases map to the existing `EX_CONFIG` (78), `EX_USAGE` (64), `EX_SOFTWARE` (70) buckets — no new exit code numbers are introduced. See §LT-4. |
| **D-LT-8** | Plan-003 §4 Phase F escalation ESC-LT-2 sets `maxAttempts = 8`; the research-doc default is 12. | Plan-003 §0.2 ESC-LT-2 | **Adopt: `maxAttempts = 8`** per ESC-LT-2 default. Codified in `WebSocketSessionTypes.swift`. |
| **D-LT-9** | The user's prompt for this design says the bounded stream may be either `AsyncStream<AlignedFrame>` OR `AsyncStream<Data>` after downsampling — "pick one and document why". | Design prompt | **Adopt: `AsyncStream<TranscriptionPCMChunk>` post-downsampler.** Per D-LT-1 above. |

If any of D-LT-1..D-LT-9 are wrong, the corresponding sub-section in this
design is the only thing that needs to change; the rest of the architecture is
independent.

### LT-1. Component Diagram (Runtime Topology)

The transcription subsystem is a **read-only side-channel** off the existing
audio pipeline. Every arrow is labeled (lossless ↔ lossy, sync ↔ async). The
recorder pipeline (§§1.1, 2.11) is **completely unchanged** — its only
contribution is exposing taps that the new `TranscriptionDriver` reads.

```
                                  RECORDER (unchanged from §1.1, lossless to disk)
 ┌─────────────────────────┐
 │ SCKitSystemAudioSource  │──sync,lossless──┐
 │   transcriptionTap      │                 │
 └─────────────────────────┘                 │
 ┌─────────────────────────┐                 ▼
 │ AVMicrophoneSource      │──sync,lossless──┤  BufferSummer ──► HostClockAligner ──► Recorder ──► .m4a/.wav/.caf
 │   transcriptionTap      │                 │  (mixed mode)         │                      (existing — UNCHANGED)
 └─────────────────────────┘                 │                       │
                                             │                       │ AlignedFrame
                                             │                       │ (every 100 ms)
                                             │                       │
   ┌─────────────────────────────────────────┴───────────────────────┴───────────────┐
   │ TAP DECISION (RecordingOptions.transcriptionSource)                              │
   │  .system  → SCKit.transcriptionTap   (CaptureBuffer)                             │
   │  .mic     → AVMic.transcriptionTap   (CaptureBuffer)                             │
   │  .mixed   → RecordingSession.transcriptionTap (AlignedFrame ── BufferSummer'd)   │
   │  .both    → both per-source taps run in parallel; two driver instances           │
   └─────────────────────────┬────────────────────────────────────────────────────────┘
                             │
                             │  (1) sync closure on macrec.aligner.serial
                             │      (or macrec.capture.system / .mic for per-source taps)
                             │      MUST NOT await; copies frame ref + tag, returns
                             ▼
                   ┌────────────────────────────────────────┐
                   │ TranscriptionDriver (actor)            │
                   │                                        │
                   │   tap producer Task (one per driver):  │
                   │     1. extract Float32 PCM from frame  │
                   │     2. run AudioDownsampler            │   ◄── lossless (per-frame)
                   │        Float32-48k-stereo →            │
                   │        PCM16-16k-mono Data             │
                   │     3. yield TranscriptionPCMChunk     │   ── lossy if consumer slow:
                   │        into bounded stream             │      bufferingNewest(64)
                   │                                        │      drops oldest at cap
                   └─────────────────┬──────────────────────┘
                                     │ AsyncStream<TranscriptionPCMChunk>
                                     │ bufferingNewest(N=64)  ── drops counted as droppedFrameCount
                                     ▼
                   ┌────────────────────────────────────────┐
                   │ TranscriptionProvider (protocol)       │
                   │                                        │
                   │   v1 concrete: GeminiLiveTranscription │
                   │   - WebSocketSession actor             │
                   │   - 100→30 ms chunk split + base64     │
                   │   - reconnection state machine         │
                   │     (maxAttempts=8, NWPathMonitor)     │
                   │   - sliding window + sessionResumption │
                   └─────────────────┬──────────────────────┘
                                     │ AsyncStream<TranscriptEvent>
                                     │ bufferingNewest(32)  (events; ~5 KB cap)
                                     ▼
                   ┌────────────────────────────────────────┐
                   │ TranscriptionDriver demultiplex        │
                   │   updates metrics                      │
                   │   yields onto eventContinuation        │
                   └─────┬──────────────────────────┬───────┘
                         │                          │
              (a) sync,best-effort         (b) async,best-effort
                         ▼                          ▼
        ┌──────────────────────────────┐   ┌──────────────────────────┐
        │ TranscriptSidecarWriter      │   │ RecordingController      │
        │ (actor, jsonl/srt/vtt/txt)   │   │ (UI: @MainActor          │
        │  -> .transcript.jsonl etc.   │   │  @Observable)            │
        │  rotates with split()        │   │  -> TranscriptPanel      │
        │  errors LOGGED, not raised   │   │  -> metrics display      │
        └──────────────────────────────┘   └──────────────────────────┘
                         │                          │
                         │ persistence              │ best-effort UI
                         │ (best-effort)            │ (drops on slow consumer
                         │ errors do NOT            │  via bufferingNewest;
                         │ fail recording)          │  no recording impact)
                         ▼                          ▼
              recording-….transcript.jsonl     menu-bar popover
```

**Arrow legend**:

- **lossless / sync**: tap closure path from source → `transcriptionTap?` invocation. The tap MUST not block, but it cannot drop a frame that arrives — every frame the pipeline produces is offered to the tap exactly once. (FR-46, NFR-17.)
- **lossy / async**: the bounded `AsyncStream<TranscriptionPCMChunk>` between the tap producer and the provider. `.bufferingNewest(64)` drops the oldest queued chunk if the consumer (provider's WebSocket) stalls. Drops are counted but cause **zero recording impact**. (FR-46, AC-LT-11.)
- **lossy / async (events)**: the `AsyncStream<TranscriptEvent>` between the provider and the driver / UI. `.bufferingNewest(32)` drops the oldest pending event if the UI stalls. Sidecar consumes from a separate cloned stream so disk persistence is not affected by UI stalls.
- **best-effort persistence**: `TranscriptSidecarWriter` errors are logged and counted; they do NOT propagate up as recording errors. The audio file remains the primary artefact. (FR-57, NFR-17.)

**Synchronous → asynchronous boundary**: The tap closure (`(AlignedFrame) -> Void` or `(CaptureBuffer) -> Void`) IS the sync/async boundary. Inside it: a single `nonisolated` call to `TranscriptionDriver.enqueueRaw(_:)`, which itself only `continuation.yield(rawFrameWrapper)` into a **second** internal stream owned by the producer Task; that Task does the downsample asynchronously and yields the resulting `TranscriptionPCMChunk` into the bounded outward stream. The closure itself never `await`s and never allocates beyond a small wrapper struct. (See §LT-6 for the contract details.)

**`RecordingOptions.transcriptionSource` decision point**: Driven at `RecordingSession.start()` time. For `.system` / `.mic`, the driver subscribes only to the corresponding per-source tap (`SCKitSystemAudioSource.transcriptionTap` / `AVMicrophoneSource.transcriptionTap`). For `.mixed`, the driver subscribes to `RecordingSession.transcriptionTap` (the post-aligner, post-summer tap). For `.both`, **two driver instances** are created (one bound to system tap, one bound to mic tap), each writing to its own sidecar with the source label. The decision point is wired in `RecordingSession.init` — once chosen, it does not change for the life of the recording.

### LT-2. Module Organization

All transcription code lives under one of three locations. The placement is
deliberate; each rule has a rationale tied to dependency direction or test
reach.

#### LT-2.1 `Sources/MacrecCore/Transcription/`

The protocol layer, transport actor, downsampler, driver, sidecar writer, and
all three providers (NoOp, Fake, Gemini). Lives in `MacrecCore` because:

- The CLI (`macrec`) needs the same code as the UI (`macrec-ui`).
- `MacrecUIKit` cannot depend on `Tests/`, so `FakeTranscriptionProvider` MUST live in production code (CR-LT-9 in plan-003 §5.3).
- No SwiftUI / AppKit references exist here; the module stays pure-domain.

**Files (verbatim from plan-003 §9 file manifest, all new):**

| File | Role | Phase |
|---|---|---|
| `TranscriptionProvider.swift` | Provider protocol contract (§LT-3.1). | A |
| `TranscriptionPCMChunk.swift` | Sendable value type carrying post-downsample PCM16-16k bytes + source tag + host time. | A |
| `TranscriptEvent.swift` | Sendable enum: `partial`, `final`, `error`, `sessionEnded`, `providerStateChange` (§LT-3.2). | A |
| `TranscriptionAudioFormat.swift` | Sendable struct `(sampleRate, bitDepth, channelCount, byteOrder)`. Used by providers to advertise their required input format. | A |
| `TranscriptionOptions.swift` | Sendable struct passed into `provider.run(...)` — provider id, source, format, apiKey, modelId, keyExpiresAt. | A |
| `TranscriptionProviderId.swift` | Sendable enum (`none`, `geminiLive`, `openaiRealtime`/placeholder, `deepgram`/placeholder, `assemblyAI`/placeholder) + `parse(_:)`. | A |
| `TranscriptionSource.swift` | Sendable enum (`system`, `microphone`, `mixed`, `both`) + `parse(_:)`. | A |
| `TranscriptFormat.swift` | Sendable enum (`jsonl`, `txt`, `srt`, `vtt`) + `parse(_:)`. | A |
| `SourceTag.swift` (alias of existing `CaptureSourceTag`) | Re-export for clarity in the transcription namespace; the existing enum at `Capture/CaptureBuffer.swift:21` is reused unchanged. | A (no new file needed if the existing enum is already `public`) |
| `SessionEndReason.swift` | Sendable enum: `normalClose`, `userStopped`, `maxDurationReached`, `unrecoverableError(_:)`, `providerSessionExhausted`. | A |
| `NoOpTranscriptionProvider.swift` | True no-op: receives audio, immediately finishes the events stream. Used when `.transcriptionProvider == .none`. | A |
| `FakeTranscriptionProvider.swift` | **Lives in production code (not Tests/)**, marked `public`, accepts an injected script of `TranscriptScriptStep`s; deterministic. Plan-003 §4 Phase A R-Phase A.2. | A |
| `AudioDownsampler.swift` | Verbatim drop-in from `docs/research/audio-downsample-conversion.md` §"Drop-In AudioDownsampler Swift Class". Float32-48k-stereo → PCM16-16k-mono via `AVAudioConverter`. | B |
| `AudioDownsamplerError.swift` | Error enum (per project's one-symbol-per-file convention in `Errors/`). | B |
| `TranscriptionDriver.swift` | `actor TranscriptionDriver`. Owns the downsampler instance, the bounded stream's continuation, the provider Task, the metrics, and the optional `TranscriptSink`. (§LT-6.) | B |
| `SyntheticAudioFixture.swift` | Test infra (still in `Sources/` to be reachable by the UI test target). Produces `AVAudioPCMBuffer` fixtures — silence, 1 kHz sine, speech-like burst. | B |
| `TranscriptHeader.swift` | Sendable Codable struct for jsonl header (`schema`, `provider`, `model`, `audioPath`, counts). | D |
| `TranscriptSink.swift` | Protocol abstracting sidecar consumption (`consume(_:)`, `finalize()`). | D |
| `TranscriptSidecarNamer.swift` | Pure helper: derives sidecar URL from audio URL + format + optional layout source tag. | D |
| `TranscriptSidecarWriter.swift` | `actor TranscriptSidecarWriter`. Implements `TranscriptSink`. jsonl is open-truncate-write; srt/vtt buffer in memory until `finalize()`. (§LT-9.) | D |
| `WebSocketTransport.swift` | Protocol abstracting `URLSessionWebSocketTask` for testability (research §"WebSocketTransport Protocol"). | E |
| `LiveWebSocketTransport.swift` | `final class … : WebSocketTransport, @unchecked Sendable`. Wraps a real `URLSessionWebSocketTask`. | E |
| `WebSocketSession.swift` | `actor WebSocketSession`. Runs receive-loop, heartbeat, reconnection state machine, `NWPathMonitor`. Public `events: AsyncStream<ServerEvent>`. (§LT-8.) | E |
| `WebSocketSessionTypes.swift` | `ServerEvent`, `WebSocketState`, `WebSocketSessionError`, `WebSocketSessionConfig` (with `maxAttempts = 8`). | E |
| `GeminiLiveTypes.swift` | All Codable types from `docs/research/gemini-live-wire-schema.md` §10 verbatim. | F |
| `GeminiLiveTranscriptionProvider.swift` | Concrete `TranscriptionProvider`. (§LT-10.) | F |
| `TranscriptionProviderFactory.swift` (renamed from plan-003's `GeminiLiveProviderRegistry.swift` — see naming note below) | Factory `make(_:options) -> any TranscriptionProvider`. | F |

**Naming note**: plan-003 §4 Phase F uses the file name `GeminiLiveProviderRegistry.swift`. Per project convention (one-symbol-per-file, the file name matches the public type name), the file is renamed in this design to `TranscriptionProviderFactory.swift` since the actual public symbol is `enum TranscriptionProviderFactory`. This is a non-substantive rename surfaced here for the implementation phase.

#### LT-2.2 `Sources/MacrecUIKit/`

UI domain layer (already exists, plan-002). Extended with:

- **`RecordingController.swift` modifications** — add `transcriptEvents`, `currentPartial`, `transcriptionState`, `transcriptionMissingKey`, `transcriptionMetrics` `@Observable` properties; subscribe to the `TranscriptionDriver.events` stream during `start()`.
- **`SessionCoordinator.swift` modifications** — wire sidecar rotation hook on segment-completion; emit a separator-marker event into `transcriptEvents` so the UI panel renders the segment boundary.

No new files in `MacrecUIKit/` for v1 — the controller and coordinator extensions are in-place edits. Rationale: the UI **state** belongs to the controller; new observable properties are additive to the existing `@Observable` class.

#### LT-2.3 `Sources/macrec-ui/Views/`

SwiftUI views for the popover. New files (plan-003 §9):

| File | Role |
|---|---|
| `TranscriptionPicker.swift` | Mirror of `FormatPicker.swift` (codebase scan §4.3). Drives `@AppStorage("com.macrec.ui.transcribeProvider")`. Shows `TranscriptionMissingKeyBadge` overlay when the resolved key is `nil`. |
| `TranscriptionSourcePicker.swift` | Same shape; `@AppStorage("com.macrec.ui.transcribeSource")`. Visible only when `provider != .none`. |
| `TranscriptFormatPicker.swift` | Same shape; `@AppStorage("com.macrec.ui.transcriptFormat")`. Visible only when `provider != .none`. |
| `TranscriptionMissingKeyBadge.swift` | Tiny SwiftUI view: red dot + tap-to-show popover naming the env var and `~/.tool-agents/macrec-ui/.env` path. |
| `TranscriptPanel.swift` | `ScrollView` rendering finals (normal style) + the live partial (muted style). Auto-scroll-to-bottom unless user has scrolled up; "Jump to live" overlay button. Fixed max-height 120 pt. |
| `TranscriptionPrivacyAlert.swift` | `.alert(...)` modifier, fired when user picks non-`None` provider AND `@AppStorage("com.macrec.ui.transcribePrivacyAccepted") == false`. |

Modifications:

- **`RootView.swift`** — adds the three pickers (collapsed under a `DisclosureGroup` "Live transcription"), the panel below level meters, and the privacy alert modifier.
- **`Views/SavedToDisclosure.swift`** — extended to list each transcript sidecar path alongside the audio path on the post-stop disclosure (FR-57).

#### LT-2.4 Why this layout

- **`MacrecCore/Transcription/`** is the single namespace any non-UI consumer imports. The CLI's `StartCommand` only needs `TranscriptionProviderId.parse(_:)` from this namespace; everything else flows through `RecordingOptions`.
- **`MacrecUIKit/`** sees the driver's `events` stream as an `AsyncStream<TranscriptEvent>` and never reaches into the provider directly.
- **`Sources/macrec-ui/Views/`** sees only `RecordingController`'s `@Observable` properties — strict layering.

This maps cleanly onto the existing module map (codebase scan §2): no new package targets, no new SwiftPM dependencies, and the existing `Package.swift` is untouched (plan-003 §10).

### LT-3. Protocol Design

#### LT-3.1 `TranscriptionProvider`

```swift
// Sources/MacrecCore/Transcription/TranscriptionProvider.swift

import Foundation

/// A streaming audio-in / text-out service abstraction.
///
/// Concrete providers in v1: `NoOpTranscriptionProvider` (true no-op),
/// `FakeTranscriptionProvider` (deterministic, test-driven),
/// `GeminiLiveTranscriptionProvider` (Google Gemini 3.1 Flash Live).
///
/// **Lifecycle**: A single call to `run(audio:options:)` is the entire session.
/// Cancellation of the calling Task is the stop signal; the provider's
/// `AsyncStream<TranscriptEvent>` finishes after a clean shutdown.
///
/// **Reconnection**: Transparent across reconnects — the returned events
/// stream stays open through transient WebSocket drops; only a fatal /
/// session-ended condition finishes the stream. (See `TranscriptEvent.providerStateChange`.)
public protocol TranscriptionProvider: Sendable {

    /// Wire-protocol identifier (e.g. `"gemini-live"`, `"noop"`).
    /// String-typed for forward compatibility — see D-LT-5.
    var providerId: String { get }

    /// Human-readable label used by the UI picker.
    var displayName: String { get }

    /// The env-var name the resolver looks up for this provider's API key.
    /// `nil` for providers that need no key (NoOp, Fake).
    var requiredApiKey: String? { get }

    /// The audio format this provider expects on the wire.
    /// Drives the `TranscriptionDriver`'s downsampler configuration.
    var requiredAudioFormat: TranscriptionAudioFormat { get }

    /// Run a session.
    ///
    /// - Parameters:
    ///   - audio: A bounded `AsyncStream` of post-downsampler PCM chunks
    ///            (already in `requiredAudioFormat`). Provider must consume
    ///            promptly; backpressure here is mitigated upstream by
    ///            `bufferingNewest(64)` and never blocks the recorder.
    ///   - options: Resolved transcription configuration (api key, model id,
    ///              source tag for labeling, etc.).
    /// - Returns: An `AsyncStream<TranscriptEvent>` that finishes when the
    ///            session ends (clean stop, fatal error, or task cancellation).
    func run(
        audio: AsyncStream<TranscriptionPCMChunk>,
        options: TranscriptionOptions
    ) -> AsyncStream<TranscriptEvent>
}
```

Notes on the shape:

- Single `run(...)` instead of `start(...)` + `stop()`. **D-LT-3 records the rationale**. The user-prompt's `start/stop` shape is logically equivalent: starting a recording starts the run task; stopping it cancels the task. `Sendable` conformance and test-fakes' determinism are easier with a single function.
- `providerId: String` (not `TranscriptionProviderId` enum) — **D-LT-5 records the rationale**. The matching enum exists separately and is used at parse / configuration time.
- The audio stream is `AsyncStream<TranscriptionPCMChunk>` (post-downsampler) per D-LT-1 / D-LT-9.
- Cancellation is the stop signal. The provider must observe `Task.isCancelled` and respond by closing its WebSocket with `.normalClosure` (1000) and finishing the events stream.

#### LT-3.2 `TranscriptEvent` and supporting types

```swift
// Sources/MacrecCore/Transcription/TranscriptEvent.swift

import Foundation

/// One event emitted by a `TranscriptionProvider` during a session.
public enum TranscriptEvent: Sendable, Codable, Equatable {

    /// Interim hypothesis. May be replaced by a subsequent partial or
    /// committed by a `final`.
    case partial(text: String,
                 source: SourceTag,
                 timestamp: TimeInterval)

    /// Committed transcript segment. `startedAt` and `endedAt` are session-relative
    /// seconds (driver-clock domain). `confidence` is provider-supplied if available.
    case final(text: String,
               source: SourceTag,
               startedAt: TimeInterval,
               endedAt: TimeInterval,
               confidence: Double?)

    /// Provider state change for UI affordances. `connected == false` while
    /// the provider is reconnecting. The events stream STAYS OPEN across
    /// transient disconnects — this event is the only signal the consumer
    /// has of a brief gap.
    case providerStateChange(connected: Bool, retryAttempt: Int)

    /// Non-recording-fatal provider error (network blip, idle timeout,
    /// non-fatal close code). When `isFatal == true`, the events stream
    /// will finish shortly after this event.
    case error(reason: String, isFatal: Bool)

    /// Session ended. After this event, the events stream finishes. The
    /// recording is unaffected.
    case sessionEnded(reason: SessionEndReason)
}

/// Why a session ended. Surfaces in the post-stop disclosure.
public enum SessionEndReason: String, Sendable, Codable, Equatable {
    case normalClose
    case userStopped
    case maxDurationReached
    case providerSessionExhausted   // Reconnect attempts exhausted (3 fails / 60 s)
    case unrecoverableError
}

/// Transcription source label used to mark which audio stream a given
/// transcript came from (so the UI / sidecar can render it correctly).
/// This is an alias of the existing `CaptureSourceTag` for the
/// transcription namespace; do NOT introduce a parallel enum.
public typealias SourceTag = CaptureSourceTag
```

```swift
// Sources/MacrecCore/Transcription/TranscriptionPCMChunk.swift

import Foundation

/// One chunk of post-downsampler PCM data, ready for the provider's wire.
///
/// All chunks within a session share the same `sampleRate` / `channelCount`
/// (the provider's `requiredAudioFormat`). `pcmData` is interleaved
/// little-endian PCM16 in v1 (the only format any v1 provider requires).
public struct TranscriptionPCMChunk: Sendable, Equatable {
    public let pcmData: Data
    public let sampleRate: Int
    public let channelCount: Int
    public let source: SourceTag
    public let hostTime: UInt64       // mach_absolute_time at chunk start
    public let durationSeconds: Double // chunk duration (~0.1 s for aligner-driven flow)
}
```

```swift
// Sources/MacrecCore/Transcription/TranscriptionAudioFormat.swift

import Foundation

public struct TranscriptionAudioFormat: Sendable, Equatable {
    public let sampleRate: Int      // 16000 for Gemini Live
    public let bitDepth: Int        // 16
    public let channelCount: Int    // 1
    public let byteOrder: ByteOrder // .little

    public enum ByteOrder: Sendable, Equatable { case little, big }

    public static let pcm16le16k1ch = TranscriptionAudioFormat(
        sampleRate: 16000, bitDepth: 16, channelCount: 1, byteOrder: .little
    )
}
```

```swift
// Sources/MacrecCore/Transcription/TranscriptionOptions.swift

import Foundation

public struct TranscriptionOptions: Sendable, Equatable {
    public let provider: TranscriptionProviderId
    public let source: TranscriptionSource
    public let format: TranscriptFormat
    public let apiKey: String?            // nil for NoOp / Fake; non-nil for Gemini (resolver enforces)
    public let modelId: String?           // nil = use provider's pinned default
    public let keyExpiresAt: Date?        // optional ISO-8601 expiry warning
}
```

```swift
// Sources/MacrecCore/Transcription/TranscriptionProviderId.swift

public enum TranscriptionProviderId: String, Sendable, Equatable, CaseIterable, Codable {
    case none = "none"
    case geminiLive = "gemini-live"
    case openaiRealtime = "openai-realtime"   // placeholder for v2
    case deepgram = "deepgram"                // placeholder for v2
    case assemblyAI = "assembly-ai"           // placeholder for v2

    /// Throws `MacrecError.transcriptionInvalidProvider` on bad input.
    public static func parse(_ raw: String) throws -> Self {
        guard let id = Self(rawValue: raw) else {
            throw MacrecError.transcriptionInvalidProvider(
                raw: raw,
                registered: Self.allCases.map(\.rawValue)
            )
        }
        return id
    }
}
```

(Same shape — not repeated — for `TranscriptionSource` and `TranscriptFormat`.)

#### LT-3.3 `FakeTranscriptionProvider` shape

`FakeTranscriptionProvider` lives in `Sources/MacrecCore/Transcription/`
(NOT under `Tests/`) so the UI test target can use it without circular
dependencies. It is deterministic: an injected script of
`TranscriptScriptStep` values drives the events stream.

```swift
public enum TranscriptScriptStep: Sendable {
    case partial(text: String, after: Duration)
    case final(text: String, after: Duration, confidence: Double? = nil)
    case error(reason: String, after: Duration, isFatal: Bool)
    case providerStateChange(connected: Bool, retryAttempt: Int, after: Duration)
    case disconnect(after: Duration)   // Simulates a transient drop (state machine reconnect).
    case hang(after: Duration)         // Simulates a stalled provider (drives bounded-queue drop tests).
}

public final class FakeTranscriptionProvider: TranscriptionProvider {
    public let providerId = "fake"
    public let displayName = "Fake (test-only)"
    public let requiredApiKey: String? = nil
    public let requiredAudioFormat = TranscriptionAudioFormat.pcm16le16k1ch

    private let script: [TranscriptScriptStep]
    /// Atomic counter incremented on every consumed audio chunk. Tests assert.
    public let consumedChunkCount = AtomicInt(0)

    public init(script: [TranscriptScriptStep]) { self.script = script }

    public func run(
        audio: AsyncStream<TranscriptionPCMChunk>,
        options: TranscriptionOptions
    ) -> AsyncStream<TranscriptEvent> { /* … emits scripted events on a separate Task … */ }
}
```

The fake satisfies the protocol with no networking, no `await` outside the
emit Task, and no source-of-truth ambiguity — the script is the single point
of behavioral control.

### LT-4. Error Model

The transcription subsystem extends `MacrecError` (per the locked-stack
policy in §2.1 and §9.5 of this design). **No new exit codes are introduced**;
each new case maps onto the existing buckets.

| New `MacrecError` case | Exit code (existing bucket) | When raised |
|---|---|---|
| `transcriptionApiKeyMissing(provider: String, key: String, sourcesChecked: [String])` | **78** (`EX_CONFIG`, joins the `missingRequiredConfig` bucket) | Resolver can't find the API key for a non-`None` provider in any of the four chain tiers. Raised inside `ConfigResolver.resolve(...)` BEFORE `RecordingSession` is constructed. AC-LT-4. |
| `transcriptionInvalidProvider(raw: String, registered: [String])` | **64** (`EX_USAGE`, joins the `invalidConfigValue` bucket) | `TranscriptionProviderId.parse(_:)` rejects an unrecognized provider name (CLI flag or env var). AC-LT-17. |
| `transcriptionInvalidSource(raw: String, registered: [String])` | **64** (`EX_USAGE`, joins the `invalidConfigValue` bucket) | `TranscriptionSource.parse(_:)` rejects an unrecognized source name. Plan-003 R-Phase C.2. |
| `transcriptionInvalidFormat(raw: String, registered: [String])` | **64** (`EX_USAGE`) | `TranscriptFormat.parse(_:)` rejects an unrecognized sidecar format. |
| `transcriptionDetachUnsupported` | **64** (`EX_USAGE`) | `--detach` combined with `--transcribe <provider != none>`. Per OQ-LT-5: detach-mode transcription is excluded from v1. |
| `transcriptionConfigConflict(reason: String)` | **64** (`EX_USAGE`) | Generic configuration-conflict bucket. v1 example: `--transcribe gemini-live --transcribe-source mic --mic none` (asks to transcribe a microphone that's been disabled). The reason string is human-readable. |
| `transcriptionProviderUnavailable(provider: String, reason: String)` | **70** (`EX_SOFTWARE`, joins the runtime-failure bucket) | Reserved — used when a future provider's configuration is fundamentally broken at session-start time (e.g. invalid endpoint, malformed model id passed to a strict provider). For Gemini in v1, this is mostly unused (key-missing is `transcriptionApiKeyMissing`; runtime errors flow through `TranscriptEvent.error`). |
| `transcriptionSessionFailed(provider: String, reason: String)` | **non-fatal** — `MacrecError.exitCode` returns the **existing exit code path** based on whether the recording itself succeeded. The transcription failure is logged but does NOT stop the recording. NFR-17. |

**Cross-check against §9.5 (locked exit-code table)**: every code 64 / 70 /
78 is already in the table. The new cases are appended to the existing rows
with no new column / row. The §9.5 row text will be updated by Phase H to
list the new symbols, but the structure of the table and the locked codes
themselves do NOT change.

**`description` and `remediation` strings**: per `MacrecError`'s file-header
contract (codebase scan §4.5), every new case carries:

- `transcriptionApiKeyMissing`: description names the provider and the env-var; remediation cites both `~/.tool-agents/macrec/.env` (for CLI) and `~/.tool-agents/macrec-ui/.env` (for UI), per CR-LT-5.
- `transcriptionInvalidProvider`/`Source`/`Format`: description includes the rejected raw value and the comma-separated list of registered values.
- `transcriptionDetachUnsupported`: description states the constraint explicitly; remediation says "remove `--detach` or set `--transcribe none`".
- `transcriptionConfigConflict`: description echoes the `reason:` field; remediation suggests the closest valid configuration.

### LT-5. Configuration Surface

The new env-var keys, CLI flags, and `RecordingOptions` properties.

#### LT-5.1 Resolution chain (unchanged from §5.1, restated for the new keys)

The four-tier resolution order in `ConfigResolver.resolve(cliOverrides:)`:

```
shellEnv  →  ~/.tool-agents/<tool>/.env  →  ./.env  →  CLI flags
(lowest)                                                     (highest)
```

Every new key resolves through this exact same `value(_:)` closure
(`ConfigResolver.swift:88`). No fallback is allowed — a non-`None` provider
without a key throws `MacrecError.transcriptionApiKeyMissing` (§LT-4).

#### LT-5.2 New env-var keys

| Env var | Type | Default | Resolves into | Notes |
|---|---|---|---|---|
| `MACREC_TRANSCRIBE` | `none \| gemini-live` | `none` | `RecordingOptions.transcriptionProvider` | The on/off switch for the entire feature. |
| `MACREC_TRANSCRIBE_SOURCE` | `system \| mic \| mixed \| both` | `mixed` | `RecordingOptions.transcriptionSource` | Independent of `--layout`. |
| `MACREC_TRANSCRIBE_FORMAT` | `jsonl \| txt \| srt \| vtt` | `jsonl` | `RecordingOptions.transcriptionFormat` | Sidecar format only. |
| `MACREC_TRANSCRIBE_OUTPUT` | path string | nil (auto-derived) | `RecordingOptions.transcriptionOutputPath` | Override the sidecar location. By default, derived from the audio output URL by `TranscriptSidecarNamer` (§LT-9). |
| `MACREC_TRANSCRIBE_MODEL` | provider-specific | nil (use provider's pinned default) | `RecordingOptions.transcriptionModelId` | E.g. `gemini-3.1-flash-live-preview` (default for `geminiLive`); user can override to `gemini-live-2.5-flash-native-audio` if 3.1 fails empirically (ESC-LT-1). |
| `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` | ISO-8601 date string | nil | `RecordingOptions.transcriptionKeyExpiresAt` | Optional. If past, log a warning at start; do not block. Per CLAUDE.md configuration-guide rule for expiring credentials. |
| `GOOGLE_API_KEY` | API key | nil | `RecordingOptions.transcriptionApiKey` | **Vendor-canonical name** per CLAUDE.md tool-conventions. Resolved only when `provider == .geminiLive`. |

**Naming rationale**: the user-prompt-suggested names were `MACREC_TRANSCRIBE`,
`MACREC_TRANSCRIBE_SOURCE`, `MACREC_TRANSCRIBE_FORMAT`, with
`MACREC_TRANSCRIBE_KEY_EXPIRES_AT`. Plan-003 §4 Phase C uses
`MACREC_TRANSCRIBE_PROVIDER` and `MACREC_TRANSCRIPT_FORMAT`
(and `MACREC_TRANSCRIPT_OUTPUT`). **This design adopts the user-prompt's
shorter `MACREC_TRANSCRIBE*` family** for consistency (`MACREC_TRANSCRIBE`,
`MACREC_TRANSCRIBE_SOURCE`, `MACREC_TRANSCRIBE_FORMAT`,
`MACREC_TRANSCRIBE_OUTPUT`, `MACREC_TRANSCRIBE_MODEL`,
`MACREC_TRANSCRIBE_KEY_EXPIRES_AT`). Plan-003 §4 Phase C is updated by Phase
H docs to use the same names. This is a non-substantive rename surfaced here
for the implementation phase. (Recorded as a discrepancy resolution.)

#### LT-5.3 New CLI flags

Flags on `macrec start`:

```
--transcribe <none|gemini-live>
--transcribe-source <system|mic|mixed|both>
--transcribe-format <jsonl|txt|srt|vtt>
--transcribe-output <path>
--transcribe-model <model-id>
--transcribe-key-expires-at <iso-8601>
```

Each flag corresponds to one env-var key in §LT-5.2 (highest-priority tier of
the chain). `--help` text is emitted by `ArgumentParser` from each `@Option`'s
`help:` string.

#### LT-5.4 New `RecordingOptions` stored properties

```swift
let transcriptionProvider: TranscriptionProviderId    // default: .none
let transcriptionSource: TranscriptionSource          // default: .mixed
let transcriptionFormat: TranscriptFormat             // default: .jsonl
let transcriptionApiKey: String?                      // nil unless provider needs one and resolver found it
let transcriptionModelId: String?                     // nil = use provider's pinned default
let transcriptionOutputPath: URL?                     // nil = derive from audio output basename
let transcriptionKeyExpiresAt: Date?                  // nil = no expiry warning
```

**Critical**: `RecordingOptions.withOutput(_:)` (`RecordingOptions.swift:185`)
must be updated to copy the seven new fields (codebase scan §5; plan-003
R-Top2). Without this fix, every pause/resume rotation silently loses
transcription options. This is a CR-LT-2 code-review checklist item.

#### LT-5.5 Resolver behavior

In `ConfigResolver.resolve(cliOverrides:)` the new logic is:

1. Resolve `transcribe` → `RecordingOptions.transcriptionProvider` (default `.none`).
2. **If provider == `.none`**: skip steps 3–7. The recording is identical to
   pre-plan-003 (AC-LT-16).
3. Resolve `transcribe-source` (default `.mixed`).
4. Resolve `transcribe-format` (default `.jsonl`).
5. Resolve `transcribe-model` (default nil; provider supplies its own).
6. Resolve the provider-specific API key (Gemini: `GOOGLE_API_KEY`).
   **If nil → throw `MacrecError.transcriptionApiKeyMissing`**.
7. Resolve `transcribe-key-expires-at` (optional). If past, emit a warning
   log line; do not block.
8. Cross-check: if `--detach` is true AND provider != `.none`, throw
   `MacrecError.transcriptionDetachUnsupported`.
9. Cross-check: if `transcribe-source == .mic` AND `mic == none` (no mic
   selected), throw `MacrecError.transcriptionConfigConflict(reason: ...)`.

Each cross-check is an explicit early-exit before `RecordingSession` is
constructed (AC-LT-4 — no audio file is created when configuration is
invalid).

### LT-6. Audio Tap Contract

The audio tap is the most safety-critical surface in the design — a wrong
move here breaks NFR-17 (recording integrity isolation). The contract below
is binding and CR-LT-1 enforces it at code-review time.

#### LT-6.1 Where the tap is installed

Three new tap properties are added (codebase scan §4.1):

```swift
// SCKitSystemAudioSource.swift  (alongside existing levelTap on line 178)
public var transcriptionTap: ((CaptureBuffer) -> Void)?

// AVMicrophoneSource.swift  (mirror)
public var transcriptionTap: ((CaptureBuffer) -> Void)?

// RecordingSession.swift  (post-aligner; alongside existing levelTap concept)
public var transcriptionTap: ((AlignedFrame) -> Void)?
```

The first two fire on `macrec.capture.system` / `macrec.capture.mic`
respectively, immediately AFTER the existing `levelTap` (sources: line
339-345 in SCKit; analogous in AVMic). The third fires on
`macrec.aligner.serial`, immediately AFTER the recorder's write call (so a
crash in the tap can never starve the recorder).

#### LT-6.2 Tap closure signature and constraints

```swift
public typealias TranscriptionTapAligned = @Sendable (AlignedFrame) -> Void
public typealias TranscriptionTapSource  = @Sendable (CaptureBuffer)  -> Void
```

**Binding rules**, enforced by code review (CR-LT-1):

1. **Synchronous.** No `await`, no `async let`, no `Task.sleep`, no `try await`.
2. **No allocation > 1 KB.** Wrapping the buffer in a small `Sendable` struct is fine; deep-copying a 38 400 B PCM buffer is NOT — the producer Task does that.
3. **No I/O.** No file handles, no network, no `Logger.log` (logging is async-deferred).
4. **No actor hops that suspend.** The closure may call `nonisolated` functions on the `TranscriptionDriver`, but they must themselves be synchronous. (See §LT-6.3.)
5. **Idempotent under repeated install/uninstall.** The capture sources mutate `transcriptionTap` from `nil` to a closure once at `RecordingSession.start` and back to `nil` once at `RecordingSession.requestStop`. No intermediate replacement.

#### LT-6.3 The producer Task — sync ↔ async boundary

The driver exposes one `nonisolated` synchronous method that the tap closure
calls:

```swift
extension TranscriptionDriver {
    /// Synchronous, non-blocking. Posts the raw frame onto an internal stream
    /// for the producer Task to downsample asynchronously.
    /// SAFE TO CALL FROM ANY QUEUE.
    nonisolated public func enqueueRawAligned(_ frame: AlignedFrame) {
        rawContinuation.yield(.aligned(frame))
        // No await, no actor hop. Returns in O(1).
    }

    nonisolated public func enqueueRawSource(_ buffer: CaptureBuffer) {
        rawContinuation.yield(.source(buffer))
    }
}
```

`rawContinuation` writes into a **separate** internal `AsyncStream<RawTapInput>`
held by the producer Task. The producer Task is the only consumer of this
stream; it runs the `AudioDownsampler` synchronously per frame and yields the
result onto the bounded outward `AsyncStream<TranscriptionPCMChunk>`. The two
streams have different lifecycles:

- **Inner raw stream**: unbounded buffer for ~one frame at a time (the producer drains immediately). If the producer ever stalls (downsampler crash), the unbounded buffer grows; this is the only place where unbounded growth would matter. Mitigated by setting the inner stream's policy to `bufferingNewest(8)` — at 8 × 100 ms × 38 400 B ≈ 300 KB worst case before drops, and the producer never realistically stalls (the downsampler is < 1 ms per frame per `audio-downsample-conversion.md` §"Performance Notes").
- **Outer bounded stream**: `bufferingNewest(64)` per investigation pt. 9. At PCM16-mono-16k post-downsample, 64 × 100 ms × 3 200 B ≈ 200 KB. **Three orders of magnitude under NFR-19's 8 MB ceiling.**

#### LT-6.4 Buffer size N — concrete rationale

| Stream | Element | Capacity | Memory footprint at cap | Source |
|---|---|---|---|---|
| Inner raw stream (driver-internal) | `RawTapInput` (frame ref) | `bufferingNewest(8)` | ~300 KB worst case (Float32-stereo-48k × 8) | This design (§LT-6.3) |
| Outer bounded stream (driver → provider) | `TranscriptionPCMChunk` | `bufferingNewest(64)` | ~200 KB worst case (PCM16-mono-16k × 64) | Investigation pt. 9; plan-003 §0.3, §2.3 |
| Provider events (provider → driver) | `TranscriptEvent` | `bufferingNewest(32)` | ~5 KB worst case | Plan-003 §0.3 |
| UI panel events (driver → controller) | `TranscriptEvent` | `bufferingNewest(64)` | ~10 KB worst case | This design (UI is the slowest consumer; doubled vs provider events to give MainActor breathing room) |
| `transcriptEvents` array on controller | `TranscriptEvent` | 1000 entries (drop oldest) | ~150 KB | Plan-003 §4 Phase G |

Total worst-case memory across all transcription buffers: ≈ 700 KB —
**~1 % of NFR-19's 8 MB ceiling**. The cap holds with comfortable margin
even under a hostile fake provider (AC-LT-11).

#### LT-6.5 Tap removal contract

| Trigger | Tap behavior |
|---|---|
| Recording stops cleanly (`requestStop()`) | Tap properties set to `nil` AFTER the driver finishes draining. The tap closure stops being invoked the instant `nil` is assigned (the dispatch queue serializes both reads and writes). |
| Transcription disabled mid-recording (UI toggle, future v2 feature) | NOT supported in v1. The provider picker is locked while `state` is recording (AC-LT-19). Plan-003 §6 R-29. |
| Recorder errors out (writer fail, scstream silent stop) | Driver receives a `RecordingSession` error signal; cancels the provider Task; closes the sidecar; tap is uninstalled in `requestStop()`'s teardown path. The recording-level error is the one surfaced to the user. NFR-17. |
| Pause/resume rotation | Tap STAYS installed (codebase scan §4.1; plan-003 §4 Phase D). The driver's `rotateSidecar(toAudioURL:)` rotates the sidecar but does not touch the tap. |
| `RecordingSession.deinit` | Tap closures hold a weak reference to the driver to prevent retain cycles. If the session is deallocated, the closures become no-ops. |

### LT-7. Sidecar File Naming and Format

#### LT-7.1 Naming rules (FR-51)

| Audio output | `--transcribe-source` | Sidecar(s) |
|---|---|---|
| `recording-2026-04-26-22-30-00.m4a` | `system` / `mic` / `mixed` | `recording-2026-04-26-22-30-00.transcript.<ext>` |
| `recording-2026-04-26-22-30-00.part01.m4a` | `system` / `mic` / `mixed` | `recording-2026-04-26-22-30-00.part01.transcript.<ext>` |
| `recording-2026-04-26-22-30-00.part02.m4a` | … | `recording-2026-04-26-22-30-00.part02.transcript.<ext>` |
| `recording-2026-04-26-22-30-00.system.m4a` + `.mic.m4a` (split-layout) | `mixed` | one sidecar (`…transcript.<ext>` next to the basename); reflects the post-summer transcription stream |
| `recording-2026-04-26-22-30-00.system.m4a` + `.mic.m4a` (split-layout) | `system` | one sidecar `recording-….system.transcript.<ext>` |
| `recording-2026-04-26-22-30-00.system.m4a` + `.mic.m4a` (split-layout) | `mic` | one sidecar `recording-….mic.transcript.<ext>` |
| `recording-2026-04-26-22-30-00.system.m4a` + `.mic.m4a` (split-layout) | `both` | two sidecars: `recording-….system.transcript.<ext>` AND `recording-….mic.transcript.<ext>` |

`<ext>` is one of `jsonl`, `txt`, `srt`, `vtt`.

`TranscriptSidecarNamer.sidecarURL(forAudio:layoutSourceTag:format:)` is the
single source of truth and is unit-tested exhaustively (plan-003 §4 Phase D).

#### LT-7.2 JSONL line schema (default)

Each sidecar starts with a header line:

```jsonc
{
  "schema": "macrec.transcript.v1",
  "provider": "gemini-live",
  "model": "gemini-3.1-flash-live-preview",
  "audioPath": "/Users/.../recording-2026-04-26-22-30-00.m4a",
  "startedAt": "2026-04-26T22:30:00.000Z",
  "endedAt": null,
  "secondsStreamed": 0.0,
  "partialCount": 0,
  "finalCount": 0,
  "droppedFrames": 0
}
```

The header line is **rewritten in place** (truncate-then-write at offset 0)
on every metric update and at session end. To keep subsequent appends from
having to recompute offsets, the encoded header is **padded to a fixed
512-byte boundary** (whitespace inside the JSON, trailing space before the
`\n`). Documented in `TranscriptSidecarWriter.swift`. (Plan-003 R-Phase D.2.)

Each subsequent line is one JSON object per `TranscriptEvent`:

```jsonc
{ "t": "partial",  "ts": 12.345,                 "text": "hello wo",     "source": "mixed" }
{ "t": "partial",  "ts": 12.892,                 "text": "hello world",  "source": "mixed" }
{ "t": "final",    "ts": 12.345, "endTs": 13.456,"text": "hello world.", "source": "mixed", "conf": 0.93 }
{ "t": "state",    "ts": 30.000, "connected": false, "retryAttempt": 1 }
{ "t": "state",    "ts": 31.420, "connected": true,  "retryAttempt": 1 }
{ "t": "error",    "ts": 30.000, "reason": "transient network drop", "isFatal": false }
{ "t": "ended",    "ts": 60.000, "reason": "userStopped" }
```

| Field | Type | Allowed values |
|---|---|---|
| `t` | string | `"partial"`, `"final"`, `"state"`, `"error"`, `"ended"` |
| `ts` | number | session-relative seconds, double precision |
| `endTs` | number | only on `"final"` |
| `text` | string | only on `"partial"` and `"final"` |
| `source` | string | `"system"`, `"mic"`, `"mixed"` (only on `partial`/`final`) |
| `conf` | number\|null | only on `"final"` |
| `connected` | bool | only on `"state"` |
| `retryAttempt` | int | only on `"state"` |
| `reason` | string | only on `"error"` and `"ended"` |
| `isFatal` | bool | only on `"error"` |

The schema is versioned via the header's `schema: "macrec.transcript.v1"`
field. Future v2 changes (e.g. speaker-id) increment to `v2`.

#### LT-7.3 SRT format

Standard SubRip cue numbering, `hh:mm:ss,fff` timestamps. Only emit on
`.final` events; partials are dropped. Cues are buffered in memory; the file
is written on `finalize()` (since SRT requires complete cue ordering and
sequence numbering).

```
1
00:00:12,345 --> 00:00:13,456
hello world.

2
00:00:14,000 --> 00:00:15,200
the quick brown fox.
```

Golden-file fixtures (`Tests/MacrecCoreTests/Fixtures/expected.srt`) lock the
exact format.

#### LT-7.4 VTT format

WebVTT header + cues with `.` (not `,`) decimal separator; otherwise same as
SRT. Only `.final` events; in-memory until `finalize()`.

```
WEBVTT

00:00:12.345 --> 00:00:13.456
hello world.

00:00:14.000 --> 00:00:15.200
the quick brown fox.
```

Golden-file fixture lives next to the SRT one.

#### LT-7.5 TXT format

Append-only, one line per `.final` event, no metadata. Partials and other
event types are dropped entirely.

```
hello world.
the quick brown fox.
```

### LT-8. UI Design (`macrec-ui`)

#### LT-8.1 Popover layout

The popover is rendered by `RootView.swift`. The new layout (codebase scan §4.3):

```
┌──────────────────────────────────────────┐
│  Macrec — [recording timer + state]      │
│ ────────────────────────────────────────  │
│  Output folder:  [FolderPicker]          │
│  Filename basename: [TextField]          │
│  Format:        [FormatPicker]           │
│  Layout:        [LayoutPicker]           │
│  Microphone:    [MicrophonePicker]       │
│ ────────────────────────────────────────  │
│  ▶ Live transcription (DisclosureGroup)  │  ← NEW (LT-2.3)
│      Provider:  [TranscriptionPicker]    │      collapsed by default when provider == .none
│      Source:    [TranscriptionSource…]   │      visible only when provider != .none
│      Format:    [TranscriptFormatPicker] │      visible only when provider != .none
│ ────────────────────────────────────────  │
│  Levels:    [LevelMeterView]             │
│ ────────────────────────────────────────  │
│  [TranscriptPanel]   (visible when       │  ← NEW (LT-2.3)
│   provider != .none, max-height 120 pt)  │
│  └── [JumpToLive overlay]                │
│ ────────────────────────────────────────  │
│  [ControlBar: Start / Pause / Stop]      │
│ ────────────────────────────────────────  │
│  [SavedToDisclosure]                     │  ← post-stop; also lists transcript files
│ ────────────────────────────────────────  │
│  [TranscriptionMetrics]                  │  ← post-stop only; tooltip mode below
└──────────────────────────────────────────┘
```

**Position rationale**:

- Pickers go inside a `DisclosureGroup` so the popover doesn't grow vertically when the feature is disabled (default).
- Within the disclosure: provider first (drives visibility of the other two), then source (functional ordering), then format (output-only).
- The transcript panel goes **below the level meters** (FR-52), so the visual flow is "what's happening now" → "what's being said now".
- The transcript panel is hidden entirely when `provider == .none` — preserving the existing v1 visual budget for users who don't transcribe.

#### LT-8.2 Privacy disclosure (FR-53, AC-LT-9)

Triggered by:
```swift
@AppStorage("com.macrec.ui.transcribePrivacyAccepted") var accepted = false
```

When the user picks any non-`None` provider AND `accepted == false`, an
`.alert(...)` modifier presents:

> **Live transcription sends audio to a third-party API**
>
> If you enable live transcription, the audio captured during this recording
> will be streamed to a third-party API (`<provider name>`) for transcription.
> The transcript is also written to a sidecar file next to your recording.
>
> No filename, microphone name, host name, or user name is sent — only the
> raw audio bytes and a `system`/`mic`/`mixed` label.
>
> [Cancel]   [I understand — Continue]

- **Cancel**: resets the picker to `None`. No flag flip.
- **Continue**: sets `accepted = true`. Subsequent sessions skip the alert.

The disclosure remains discoverable via the picker's tooltip (`?` info icon
next to the provider name): "About third-party transcription…" — shows the
same body text in a popover, with a button "Reset disclosure" that flips the
flag back to `false`.

#### LT-8.3 No-key state (AC-LT-8)

`RecordingController.transcriptionMissingKey: Bool` is `true` when:
```
options.transcriptionProvider != .none
AND options.transcriptionApiKey == nil
```

When `true`, `TranscriptionPicker` overlays a `TranscriptionMissingKeyBadge`
(red dot in the corner of the picker control). Clicking the badge opens an
inline help popover:

> **API key not configured**
>
> To use Gemini Live, set `GOOGLE_API_KEY` in:
>   `~/.tool-agents/macrec-ui/.env`
>
> [Copy path]   [Open ~/.tool-agents/macrec-ui/.env]

The picker itself is **not** disabled when the key is missing — that would
hide a fixable misconfiguration. Pressing Start with the missing-key state
surfaces the same `transcriptionApiKeyMissing` error inline (in the
existing `ErrorBanner`, codebase scan §4.9), without crashing the recording.

#### LT-8.4 Cost / latency display (FR-58, AC-LT-14)

Two surfaces:

1. **Inline tooltip on the panel header** during recording — updates every
   1 s — shows: `streamed: 12.3 s · 4 finals · 11 partials · 0 dropped`.
2. **`SavedToDisclosure`** post-stop — adds a "Transcription summary" sub-row:
   `42 finals · 119 partials · 0 dropped · 380 s streamed · 1 reconnect(s)`.

Refresh rate: 1 Hz during recording (driven by a tiny `TimerPublisher` that
fires every second on the main run loop). No refresh needed post-stop —
the value is final.

#### LT-8.5 View-model bindings

| `@Published`/`@Observable` property on `RecordingController` | Drives |
|---|---|
| `transcriptionState: TranscriptionState` (`.idle`/`.active`/`.paused`/`.error(message)`) | `TranscriptPanel` background tint; `ErrorBanner` content. |
| `transcriptEvents: [TranscriptEvent]` (capped at 1000 finals; controller dedupes/promotes partials) | `TranscriptPanel`'s scroll content. |
| `currentPartial: String?` | `TranscriptPanel`'s muted-style trailing line. |
| `transcriptionMissingKey: Bool` | `TranscriptionMissingKeyBadge` visibility. |
| `transcriptionMetrics: TranscriptHeader?` | Inline tooltip during; `SavedToDisclosure` row post-stop. |
| `transcriptionState == .paused` (via state-change events) | Panel header shows a "Reconnecting…" pill. |

The controller subscribes to the driver's `events: AsyncStream<TranscriptEvent>`
in the `start(...)` flow. Each event:

- `.partial(text, ...)` → `currentPartial = text`. (No append to events list.)
- `.final(text, ...)` → `currentPartial = nil`; append the event to `transcriptEvents`. Drop-oldest when at cap.
- `.providerStateChange(connected: false, ...)` → `transcriptionState = .paused`.
- `.providerStateChange(connected: true, ...)` → `transcriptionState = .active`.
- `.error(reason, isFatal: false)` → log; do not change `transcriptionState`.
- `.error(reason, isFatal: true)` → `transcriptionState = .error(reason)`. Show in `ErrorBanner`.
- `.sessionEnded(reason)` → `transcriptionState = .idle`; populate `transcriptionMetrics`.

### LT-9. Persistence Layer (`TranscriptSidecarWriter`)

#### LT-9.1 Shape

```swift
public actor TranscriptSidecarWriter: TranscriptSink {

    public init(audioOutputURL: URL,
                format: TranscriptFormat,
                headerMetadata: TranscriptHeader) throws {
        // Derives sidecar URL via TranscriptSidecarNamer.
        // Opens FileHandle for r+w (truncate+write for jsonl, write for srt/vtt/txt).
        // Throws on non-writable path. NO FALLBACK.
    }

    public func consume(_ event: TranscriptEvent) async {
        // Appends per format. Errors logged at .warning; never raised.
        // Updates in-memory metrics for the next header rewrite.
    }

    public func rotateSidecar(toAudioURL nextAudioURL: URL) async throws {
        // 1. finalize() the current handle (flush, close, srt/vtt write).
        // 2. Re-derive the next sidecar URL via TranscriptSidecarNamer.
        // 3. Open the next handle with a freshly-stamped TranscriptHeader.
    }

    public func finalize() async throws {
        // Flush. For srt/vtt: write the buffered cues. Close the handle.
        // For jsonl: rewrite the header one last time with final counts.
    }

    public func metricsSnapshot() async -> TranscriptHeader {
        // Used by the controller's post-stop summary row.
    }
}
```

#### LT-9.2 Threading

Actor-isolated, so all method calls serialize through the actor's executor.
The `consume(_:)` method is `async` but the call site (the driver) `await`s
it — back-pressure here is bounded by the upstream
`bufferingNewest(32)` events stream. If the writer ever stalls, events are
dropped at the upstream cap, NOT at the writer (the writer never blocks the
driver's read loop).

`consume(_:)` errors (e.g. disk full mid-write) are logged at `.warning` and
the writer transitions to a `.broken` state — no further `consume(_:)` calls
do anything. The driver continues to consume the events stream, still
re-emits to the UI, and the recording is unaffected. (Best-effort
persistence; NFR-17.)

#### LT-9.3 Behavior on segment rotation

Driven by `RecordingSession.split(nextOutput:)` (line 573) and by
`SessionCoordinator`'s pause/resume flow (`MacrecUIKit/SessionCoordinator.swift:266` /
`:294`). The driver's `rotateSidecar(toAudioURL:)` finalizes the current
sidecar and opens the next. Atomicity: the existing sidecar is guaranteed
to be flushed and closed before the new one is opened — no overlap, no
data loss across the rotation point.

In the UI, a synthetic separator `TranscriptEvent` is appended to the
controller's `transcriptEvents` array at rotation time, rendered as a
horizontal-rule separator with the next part's index — AC-LT-20.

### LT-10. WebSocket Layer & Gemini Provider

#### LT-10.1 `WebSocketSession` actor (Phase E)

`Sources/MacrecCore/Transcription/WebSocketSession.swift` is a verbatim drop-in
from `docs/research/websocket-asyncstream-pattern.md` §"Complete Implementation".
Public surface:

```swift
public actor WebSocketSession {
    public init(url: URL, config: WebSocketSessionConfig, transportFactory: …)
    public var events: AsyncStream<ServerEvent> { get }   // open across reconnects
    public func start() async
    public func send(_ message: URLSessionWebSocketTask.Message) async throws
    public func cancel() async   // graceful close with .normalClosure
}
```

`config.maxAttempts = 8` per ESC-LT-2 / D-LT-8. Heartbeat 15 s. NWPathMonitor
restarts the backoff timer on connectivity-restored. The `events` stream is
created **once** at actor init and stays open across every transient
reconnect — only fatal exhaustion finishes it.

Hazards 1-8 from research §"Race Conditions and Leaked Tasks" are handled
inside the actor's implementation; tests in `WebSocketSessionTests` cover
each one (plan-003 §4 Phase E).

#### LT-10.2 `GeminiLiveTranscriptionProvider` (Phase F)

```swift
public final class GeminiLiveTranscriptionProvider: TranscriptionProvider {
    public let providerId = "gemini-live"
    public let displayName = "Gemini Live"
    public let requiredApiKey: String? = "GOOGLE_API_KEY"
    public let requiredAudioFormat = TranscriptionAudioFormat.pcm16le16k1ch

    public init(apiKey: String,
                modelId: String = "gemini-3.1-flash-live-preview",
                webSocketSessionFactory: @escaping (URL, WebSocketSessionConfig) -> WebSocketSession =
                    WebSocketSession.makeLive(url:config:))

    public func run(audio: AsyncStream<TranscriptionPCMChunk>,
                    options: TranscriptionOptions) -> AsyncStream<TranscriptEvent>
}
```

`run(...)` body (verbatim contract from plan-003 §4 Phase F + research
§gemini-live-wire-schema §3 / §11):

1. Build the wss URL: `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=$apiKey`. The key must be redacted in any log line that includes the URL (CR-LT-4).
2. Open the `WebSocketSession`.
3. **Send the setup message** with EXACTLY:
   - `model: "models/gemini-3.1-flash-live-preview"` (or `options.modelId`)
   - `generationConfig.responseModalities: ["AUDIO"]`  (NOT `["TEXT"]` — D-LT-? in plan-003 §0.3; CR-LT-3)
   - `inputAudioTranscription: {}`
   - `systemInstruction.parts[0].text: "You are a transcription engine. Output only the verbatim transcription of the user's speech. Do not respond, do not greet, do not summarize, do not interpret."`
   - `contextWindowCompression: { slidingWindow: {} }`  (lifts the 15-min context cap)
   - `sessionResumption: {}`  (lifts the 10-min connection cap)
4. **Wait for `setupComplete`** before sending any audio. Audio sent before
   setup-complete is undefined behavior (R-Phase F.5).
5. **Send-loop Task**: `for await chunk in audio` → split each 100 ms chunk
   into ~3 × 30 ms sub-chunks → base64-encode → wrap in
   `BidiGenerateContentRealtimeInput.audio` → send via `session.send(...)`.
6. **Receive-loop Task**: `for await event in session.events` → demultiplex
   the JSON envelope. For each `serverContent.inputTranscription.text`
   fragment, append to `pendingFragments` and emit
   `TranscriptEvent.partial(text: pendingFragments.joined())`. On
   `serverContent.turnComplete == true || generationComplete == true`,
   emit `TranscriptEvent.final(...)` with the joined buffer; clear it.
   **Discard `modelTurn.parts[].inlineData`** (the AUDIO-modality bytes —
   we asked for AUDIO only because the API rejects pure TEXT, but we don't
   use the bytes; CR-LT-3).
7. On `goAway` event: proactively close the session; the
   `WebSocketSession` reconnection state machine will resume with the
   stored `sessionResumption.handle`.
8. On session-state changes: forward `WebSocketState.connecting(attempt:)`
   transitions as `TranscriptEvent.providerStateChange(...)` events.
9. On `Task.isCancelled`: `await session.cancel()` (clean
   `.normalClosure`); finish the events stream; return.

`TranscriptionProviderFactory.make(_:)` (formerly
`GeminiLiveProviderRegistry`) wraps the provider construction so callers
don't see the concrete type:

```swift
public enum TranscriptionProviderFactory {
    public static func make(_ options: TranscriptionOptions) -> any TranscriptionProvider {
        switch options.provider {
        case .none: return NoOpTranscriptionProvider()
        case .geminiLive:
            // The resolver guarantees apiKey != nil here; defensive guard is unreachable.
            guard let key = options.apiKey else { return NoOpTranscriptionProvider() }
            return GeminiLiveTranscriptionProvider(
                apiKey: key,
                modelId: options.modelId ?? "gemini-3.1-flash-live-preview"
            )
        case .openaiRealtime, .deepgram, .assemblyAI:
            // v2 placeholders.
            return NoOpTranscriptionProvider()
        }
    }
}
```

### LT-11. Threading & Isolation Strategy

| Component | Owner / executor | Key constraints |
|---|---|---|
| `SCKitSystemAudioSource.transcriptionTap?(_:)` invocation | `macrec.capture.system` (existing serial DispatchQueue) | Closure must be sync, must not block, must not allocate > 1 KB. Mutated only via property setter from the recorder's start path on the main thread. |
| `AVMicrophoneSource.transcriptionTap?(_:)` invocation | `macrec.capture.mic` | Same as above. |
| `RecordingSession.transcriptionTap?(_:)` invocation | `macrec.aligner.serial` | Same as above. |
| `TranscriptionDriver` | `actor` — own executor | Public API is `async`. The two `enqueueRaw*(_:)` methods are `nonisolated`, synchronous, safe-to-call-from-any-queue. |
| Inner raw-input stream (driver-internal) producer Task | `Task { [weak self] in ... }` spawned by the driver during `start(...)`; runs on cooperative thread pool | Drains the inner stream synchronously; runs `AudioDownsampler` (synchronous, ~1 ms/frame); yields onto the bounded outward stream. |
| `AudioDownsampler` | Held by the driver; not an actor (it's stateful but always called from the producer Task) | Single-threaded by construction. **Filter state preserved across chunks** (R-Top4). |
| Outward bounded `AsyncStream<TranscriptionPCMChunk>` | Created by driver at `start(...)`; consumed by provider's `run(...)` Task | `bufferingNewest(64)`. Drops counted via the driver's metric; NO recording impact. |
| `TranscriptionProvider.run(audio:options:)` | Task spawned by the driver; cancelled at stop | Provider implementation must not rely on actor isolation. Cancellation = stop. |
| `WebSocketSession` | `actor` — own executor | Hazards 1-8 in research §"Race Conditions" mitigated by the actor's serial executor + careful child Task management. |
| `WebSocketSession.events` `AsyncStream<ServerEvent>` | Open at actor init; finishes only on fatal exhaustion or user cancel | Stays open across transient reconnects (research §"AsyncStream Lifetime Across Reconnections"). |
| `TranscriptSidecarWriter` | `actor` — own executor | All `consume(_:)` calls serialized. Errors logged, never raised to the driver. |
| `RecordingController` (UI) | `@MainActor @Observable` | Subscribes to `driver.events` via a `Task { @MainActor in for await … }` loop spawned in `start()`. All UI mutations on main. |
| `SessionCoordinator` | `actor` (existing) — own executor | Fires the `rotateSidecar(toAudioURL:)` call on the driver via `await` during pause/resume. |

**Sendable conformance**: every value type crossing actor boundaries is
`Sendable`. The protocol itself is `Sendable`. Closures stored on capture
sources are `@Sendable`. The `@unchecked Sendable` on
`LiveWebSocketTransport` (research §3) is documented at the declaration
site (CR-LT-? — covered by the existing review).

**Critical**: the producer Task that drains the tap → downsampler →
provider input runs on a **single, dedicated child Task** spawned by the
driver in `start(provider:options:)`. It does NOT run on
`macrec.aligner.serial`. The synchronous tap closure does no work beyond
yielding the raw frame ref onto the inner stream — guaranteeing the
aligner's queue is never blocked by transcription work.

### LT-12. Failure Modes and Recovery

| Failure | Detection | Driver behavior | Recording impact | UI surface |
|---|---|---|---|---|
| Network blip mid-recording (transient drop) | `WebSocketSession` reconnection state machine; `URLError.notConnectedToInternet`. | Session stays in `.reconnecting`; events stream STAYS OPEN. Provider emits `.providerStateChange(connected: false, retryAttempt: N)`. | **None** (NFR-17). | Panel header shows "Reconnecting… (attempt N)". |
| Reconnect succeeds | `WebSocketSession` enters `.connected`. | Provider re-sends setup with stored `sessionResumption.handle`; resumes audio send. Emits `.providerStateChange(connected: true, retryAttempt: N)`. Audio between drop and resume is dropped at the bounded queue (counted in `droppedFrameCount`). | **None.** | Panel header returns to normal; transcript continues. |
| Reconnect exhausts (3 fails / 60 s OR `maxAttempts == 8` reached) | `WebSocketSession` enters `.paused`. | Provider emits `.error(reason: "transcription paused — exhausted reconnects", isFatal: false)` then `.sessionEnded(reason: .providerSessionExhausted)`. The events stream finishes. Driver closes the sidecar's session-end record; recording continues. | **None.** | `transcriptionState = .error("paused for this recording")`; panel shows "Transcription stopped — recording continues." |
| API key invalid (server sends 1008 close) | Receive loop catches close code 1008; `WebSocketSession` enters `.failed(.authentication)`. | Provider emits `.error(reason: "authentication failed", isFatal: true)` then `.sessionEnded(reason: .unrecoverableError)`. | **None.** | `ErrorBanner` shows "Transcription auth failed — set GOOGLE_API_KEY"; recording continues to completion. |
| Audio backpressure (UI consumer stalled) | Bounded events stream's `bufferingNewest(64)` drops oldest event. | No driver action; the dropped event is lost to the UI. The sidecar consumes from a **separate** stream and is unaffected. | **None.** | UI may briefly miss a partial; the next final still arrives. |
| User toggles transcription off mid-recording | Not supported in v1 (picker locked while recording, AC-LT-19). | n/a | n/a | n/a |
| Recorder errors out (writer fail, scstream silent stop) | `RecordingSession` raises `MacrecError.writerFailedToStart` (or similar). | The teardown path cancels the provider's Task; the driver `await`s the events stream's natural finish (with a 5 s timeout); `finalize()`s the sidecar; uninstalls the tap. The transcription error is **secondary** — only the recording error is surfaced. | **Recording error surfaces.** | `ErrorBanner` shows the recording error; transcript panel becomes inactive. |
| Disk full mid-write | Writer's `consume(_:)` catches `Errno.ENOSPC`. | Writer transitions to `.broken`; logs `.warning`; subsequent events are still emitted to the UI but not persisted. | **None.** | No specific UI event; the error is logged. (Optional: add a one-shot toast in v2.) |
| Provider task crashes (Swift fatal error) | Task's structured concurrency surfaces the crash. | The driver's `await` on the task throws or returns; the events stream finishes. The driver re-emits `.error(isFatal: true)` to the controller. | **None.** | `ErrorBanner` shows "Transcription crashed"; recording continues. |

The unifying principle: **NFR-17 holds in every failure mode**. The
recording is the primary artefact; transcription is a side-channel; every
failure path eventually yields control back to the recording's normal stop
flow.

### LT-13. Test Architecture

The design enables the test suite by ensuring each major component has:

- A **substitution point** for tests (factory or initializer injection).
- A **deterministic alternative** that requires no network, no TCC, and no audio device.

| Component | Substitution | Deterministic alt | Lives in |
|---|---|---|---|
| `TranscriptionProvider` | Constructor injection on `TranscriptionDriver`; provider is never constructed inside the driver. | `FakeTranscriptionProvider(script:)` | `Sources/MacrecCore/Transcription/` (NOT Tests/) |
| `WebSocketTransport` | Factory parameter on `WebSocketSession.init` (research §3 + plan-003 §4 Phase E) | `FakeWebSocketTransport` | `Tests/MacrecCoreTests/Transcription/` (test-only is OK here — only `WebSocketSessionTests` need it) |
| `AudioDownsampler` | Direct construction; tests build `AVAudioPCMBuffer` from sine-wave generators (`SyntheticAudioFixture`). | n/a (the downsampler IS the SUT) | `Sources/MacrecCore/Transcription/AudioDownsampler.swift`; fixture is `SyntheticAudioFixture.swift` |
| `TranscriptSidecarWriter` | Constructor takes `outputPath: URL`; tests pass a temp directory URL. | n/a | `Sources/MacrecCore/Transcription/` |
| `TranscriptSink` (protocol) | Protocol injection on the driver | In-memory `TranscriptSink` impl in tests | mixed |
| `RecordingSession.transcriptionProvider` | New optional initializer parameter (plan-003 §4 Phase C); tests inject `FakeTranscriptionProvider`. | (uses the fake) | n/a |
| `RecordingController.driver` | Injectable via `RecordingController` initializer (existing pattern from plan-002) | (uses the fake driver) | n/a |
| `GeminiLiveTranscriptionProvider` | Constructor takes a `webSocketSessionFactory:` closure; tests pass a closure that returns a `WebSocketSession` whose transport is the fake. | (mocked session) | n/a |
| Real-network smoke test | Gated on `GOOGLE_API_KEY` env var presence; `@Suite(.disabled(if: ...))` | (skipped when no key) | `GeminiLiveLiveSmokeTest.swift` |

Per the existing project test convention (codebase scan §3 / §4.7), tests
that need TCC grants run as shell scripts in `test_scripts/`; tests that
inject fakes run under `swift test`. The transcription suite follows the
same dichotomy — every unit / integration test under `swift test` uses
fakes; the live smoke test is a shell-driven, env-var-gated path.

### LT-14. Implementation Order Rationale

The plan-003 parallelization map (§5.1) is restated here in design terms.
Each phase corresponds to a specific contract being locked.

```
Phase 0   ─► Functional registry (FR-45..FR-58, NFR-17..NFR-21) is the contract everyone reads.
   │
   ├──── Phase A ────┐    Protocol contract + value types + NoOp + Fake.
   │                 │    ⇒ Every other phase can compile + test against the protocol.
   │                 │    ⇒ Independent of E (different file set, different concerns).
   │
   ├──── Phase E ────┤    WebSocket transport + reconnection state machine.
   │                 │    ⇒ Provider-agnostic. Reusable by every future provider.
   │                 │    ⇒ Independent of A.
   │                 │
   ├──── Phase B ────┤    Audio tap installation + downsampler + driver.
   │   (after A)     │    ⇒ Validates AC-LT-2/3/11 against fakes BEFORE any network code lands.
   │                 │
   ├──── Phase C ────┤    Configuration plumbing + RecordingOptions.withOutput fix.
   │   (after A)     │    ⇒ Independent of B (different file set; can run in parallel).
   │                 │    ⇒ Plugs the latent bug from codebase scan §5 (R-Top2).
   │                 │
   ├──── Phase D ────┤    Sidecar persistence (writer, namer, formats, rotation).
   │   (after A+C)   │    ⇒ Validates AC-LT-5/6/13/14 — disk side of the side-channel.
   │                 │
   ├──── Phase F ────┤    Concrete Gemini provider on top of E.
   │   (after A+E)   │    ⇒ The only network code in the project until this point.
   │                 │    ⇒ Validates the wire schema against golden strings.
   │                 │
   ├──── Phase G ────┤    UI integration in macrec-ui.
   │   (after D+F)   │    ⇒ But most of G can start in Wave 2 against the fakes from A.
   │                 │
   ├──── Phase H ────┤    Documentation update.
   │   (after G)     │    ⇒ Mechanical updates after behavior is locked.
   │
   └──── Phase I ─── Manual smoke test against a real Gemini key.
```

Dependency direction matches interface direction: each phase's tests use
only the interfaces of phases that have already merged. This is the
**single most important architectural property** for parallel coders to
respect — Phase G coders pulling in `GeminiLiveTranscriptionProvider` (Phase
F) directly would defeat the protocol abstraction; instead, they pull in
`FakeTranscriptionProvider` (Phase A) and only switch in Phase I (manual
smoke).

### LT-15. Out of Scope and v2 Deferrals

Explicitly NOT designed in this section (logged for `Issues - Pending Items.md`):

- **Detach-mode transcription.** v1 disallows `--detach --transcribe gemini-live` (returns exit 64). Daemonised recorders have no foreground context to render partials. v2 may add sidecar-only detach transcription. (R-27.)
- **On-device / offline transcription.** Apple `SFSpeechRecognizer`, WhisperKit. Out of scope per refined-request §Out of scope. (R-28.)
- **Retroactive transcription.** Re-transcribing a finished `.m4a` — out of scope. (Refined-request §Out of scope.)
- **Translation.** Audio-in / text-out in a different language — out of scope.
- **Speaker diarization beyond `system`/`mic` tags.** Speaker-A / Speaker-B inside the system audio submix is a v2 problem. (R-28-adjacent.)
- **Separate transcript window.** Inline panel only in v1 (OQ-LT-3 / R-29).
- **Provider expansion (OpenAI Realtime, Deepgram, AssemblyAI).** The protocol admits all three; v1 ships only Gemini. (R-30.)
- **Cost / billing dashboards across recordings.** v1 surfaces per-recording metrics only. (FR-58.)
- **In-app transcript editing.** No editor; users can edit the sidecar files manually. (Refined-request §Out of scope.)
- **`com.apple.security.network.client` entitlement.** Not needed unless `macrec` is later sandboxed. Logged as R-31 candidate. (Plan-003 §10.)

### LT-16. Cross-Check

#### LT-16.1 AC-LT-* coverage (every refined-request criterion)

| AC | Component(s) addressing it | Section(s) |
|---|---|---|
| AC-LT-1 (None is a true no-op) | `NoOpTranscriptionProvider`; `RecordingOptions.transcriptionProvider == .none` short-circuits resolver | LT-3.1, LT-5.5 |
| AC-LT-2 (recording integrity unaffected by transcription presence) | Tap closure synchronous; bounded queue; separate Task for downsample | LT-6.2, LT-6.3, LT-11 |
| AC-LT-3 (recording integrity unaffected by transcription failure) | Hanging fake → bounded-queue drops; provider crash → driver isolation | LT-6.4, LT-12 |
| AC-LT-4 (recording integrity unaffected by missing API key — fail-fast) | `ConfigResolver.resolve` throws BEFORE `RecordingSession` is constructed | LT-4, LT-5.5 |
| AC-LT-5 (sidecar naming follows segmentation) | `TranscriptSidecarNamer.sidecarURL(...)` exhaustive cases | LT-7.1 |
| AC-LT-6 (sidecar formats are valid) | jsonl / srt / vtt / txt formats locked + golden fixtures | LT-7.2..LT-7.5 |
| AC-LT-7 (live UI panel shows partials, then commits finals) | `TranscriptPanel` + controller's `currentPartial` / `transcriptEvents` mutation | LT-8.1, LT-8.5 |
| AC-LT-8 (UI surfaces missing-key state) | `TranscriptionMissingKeyBadge` + `transcriptionMissingKey: Bool` | LT-8.3 |
| AC-LT-9 (privacy disclosure on first opt-in) | `TranscriptionPrivacyAlert` + `@AppStorage("…transcribePrivacyAccepted")` | LT-8.2 |
| AC-LT-10 (reconnect on transient failure) | `WebSocketSession` reconnection state machine | LT-10.1, LT-12 |
| AC-LT-11 (bounded queue drops, never blocks) | `bufferingNewest(64)` with documented drop counter | LT-6.4 |
| AC-LT-12 (source selection routes correctly) | Tap-decision-point in `RecordingSession.start` | LT-1, LT-6.1 |
| AC-LT-13 (clean shutdown drains finals) | Driver's `stop(drainTimeout:)` 5 s bound + writer's `finalize()` | LT-9.1, LT-12 |
| AC-LT-14 (cost metrics emitted) | `TranscriptHeader` + post-stop UI surface | LT-7.2, LT-8.4 |
| AC-LT-15 (`macrec start --help` lists all new flags) | `@Option` declarations in `StartCommand` | LT-5.3 |
| AC-LT-16 (`--transcribe none` is the default; zero behavior change) | Default `.none` short-circuit; pre-existing AC-1..AC-20 unchanged | LT-5.4, LT-5.5 |
| AC-LT-17 (invalid provider name → exit 64) | `TranscriptionProviderId.parse` throws `transcriptionInvalidProvider` | LT-3.2, LT-4 |
| AC-LT-18 (live transcription picker present in popover) | `TranscriptionPicker` + DisclosureGroup | LT-8.1 |
| AC-LT-19 (picker disabled while recording) | Same `isLocked` computed pattern as `FormatPicker` | LT-8.1 |
| AC-LT-20 (transcript panel survives Pause/Resume across segments) | Sidecar rotation + synthetic separator event | LT-8.5, LT-9.3 |
| AC-LT-21 (`docs/tools/macrec.md` updated) | Phase H | (out of design scope; Phase H deliverable) |
| AC-LT-22 (`docs/tools/macrec-ui.md` updated) | Phase H | same |
| AC-LT-23 (`docs/design/configuration-guide.md` updated) | Phase H | same |
| AC-LT-24 (`docs/design/project-functions.md` updated) | Phase 0 + Phase H | same |
| AC-LT-25 (`Issues - Pending Items.md` updated) | Phase 0 + Phase H | same |

**No AC-LT-* is unaddressed.**

#### LT-16.2 Plan-003 file manifest cross-check

Every file in plan-003 §9 (file manifest) appears in §LT-2 of this design
with its purpose and signature. The **only difference** is one rename:

- `GeminiLiveProviderRegistry.swift` → `TranscriptionProviderFactory.swift` (per project convention; LT-2.1 naming note).

No new files are introduced by this design that are not in plan-003 §9.

#### LT-16.3 FR / NFR cross-check

Every FR-45..FR-58 and NFR-17..NFR-21 from `project-functions.md` (added by
plan-003 Phase 0) is traceable to a section of this design:

| FR/NFR | Component / section |
|---|---|
| FR-45 (provider abstraction) | LT-3.1 |
| FR-46 (non-blocking tap) | LT-6 |
| FR-47 (source selection) | LT-1, LT-5.4, LT-6.1 |
| FR-48 (provider selection CLI) | LT-5.3, LT-5.5 |
| FR-49 (provider selection UI) | LT-8.1, LT-8.3 |
| FR-50 (transcript event model) | LT-3.2 |
| FR-51 (transcript persistence) | LT-7, LT-9 |
| FR-52 (live transcript display) | LT-8.1, LT-8.5 |
| FR-53 (privacy disclosure) | LT-8.2 |
| FR-54 (persisted UI defaults) | LT-8.1 (`@AppStorage` keys) |
| FR-55 (API key configuration) | LT-5 |
| FR-56 (watchdog / reconnect) | LT-10.1, LT-12 |
| FR-57 (clean shutdown) | LT-9.1, LT-12 |
| FR-58 (cost / volume metrics) | LT-7.2, LT-8.4, LT-9.1 |
| NFR-17 (recording integrity isolation) | LT-1, LT-6, LT-11, LT-12 |
| NFR-18 (latency budget) | LT-10.2 (chunk cadence + reconnect speed) |
| NFR-19 (memory ceiling) | LT-6.4 (table) |
| NFR-20 (privacy posture) | LT-10.2 (only PCM + source label sent) |
| NFR-21 (provider extensibility) | LT-3.1 (protocol-only orchestration), LT-10.2 (factory) |

**No FR or NFR is unaddressed.**

### LT-17. Architectural Decisions Recorded (with rationale)

| ADR-LT-# | Decision | Rationale |
|---|---|---|
| **ADR-LT-1** | Bounded stream's element is **post-downsampler** `TranscriptionPCMChunk`, not `AlignedFrame`. | Smaller payload (~3 200 B vs ~38 400 B per chunk); uniform contract for all providers; lines up with NFR-19 budget. (D-LT-1.) |
| **ADR-LT-2** | The provider, not the driver, splits 100 ms chunks into ~30 ms wire chunks. | Different providers want different cadences (Gemini 30 ms, Deepgram arbitrary, OpenAI Realtime 24 kHz). Concentrates provider-specific concerns inside the provider. (D-LT-2.) |
| **ADR-LT-3** | Single `run(audio:options:)` instead of `start()` + `stop()`. | Cancellation = stop; simpler to make Sendable; matches plan-003 §4 Phase A. (D-LT-3.) |
| **ADR-LT-4** | `providerId: String` on the protocol, separate `TranscriptionProviderId` enum for parsing. | Forward compatibility: future external providers ship without modifying the enum. (D-LT-5.) |
| **ADR-LT-5** | No separate `TranscriptionError` type; runtime errors flow through `TranscriptEvent.error(reason:isFatal:)`, configuration errors flow through `MacrecError`. | Avoids parallel error hierarchies; preserves locked exit-code table. (D-LT-6.) |
| **ADR-LT-6** | All new `MacrecError` cases reuse existing exit codes 64/70/78. | §9.5 is the locked table; no new codes are introduced; the buckets fit cleanly. (D-LT-7, LT-4.) |
| **ADR-LT-7** | Env var family is `MACREC_TRANSCRIBE*` (shorter, consistent with the user-prompt naming). | Cleanest naming convention; plan-003 §4 Phase C will be re-aligned by Phase H docs. (LT-5.2 naming rationale.) |
| **ADR-LT-8** | `FakeTranscriptionProvider` is in `Sources/MacrecCore/Transcription/`, NOT `Tests/`. | The UI test target cannot import test code from MacrecCoreTests. (Plan-003 §4 Phase A R-Phase A.2; CR-LT-9.) |
| **ADR-LT-9** | The driver wraps the tap with TWO streams (inner unbounded raw → producer Task → outer bounded post-downsampler). | The synchronous tap closure must not block the aligner's queue; downsampling runs on the producer Task; the bounded outward stream isolates the consumer. (LT-6.3.) |
| **ADR-LT-10** | The `events` `AsyncStream<TranscriptEvent>` STAYS OPEN across transient reconnects; `providerStateChange` carries the connectivity signal. | Matches `WebSocketSession.events` lifetime contract from research §"AsyncStream Lifetime Across Reconnections". Consumer never has to recreate its subscription. (LT-3.2, LT-10.1.) |
| **ADR-LT-11** | jsonl is the default sidecar format with a 512-byte-padded header that's rewritten on flush. | Richest information density; metrics in the header are kept current without offset bookkeeping; subsequent appends never need to re-seek. (LT-7.2; plan-003 R-Phase D.2.) |
| **ADR-LT-12** | `TranscriptionProviderFactory` is the file name (renamed from plan-003's `GeminiLiveProviderRegistry`). | One-symbol-per-file convention; the public type is `TranscriptionProviderFactory`. (LT-2.1.) |
| **ADR-LT-13** | The picker stays enabled (not disabled) when the API key is missing; pressing Start surfaces the error inline. | Disabling the picker hides a fixable misconfiguration; surfacing the error inline matches the no-fallback / informative-failure project posture. (LT-8.3.) |
| **ADR-LT-14** | Live-transcription pickers go inside a `DisclosureGroup` collapsed by default. | Preserves the existing popover's vertical budget for users who don't transcribe. (LT-8.1.) |
| **ADR-LT-15** | The driver's bounded outward stream has `bufferingNewest(64)`; the inner raw stream has `bufferingNewest(8)`; the events stream has `bufferingNewest(32)`; the UI panel cap has `bufferingNewest(64)` on the controller subscriber side and a 1000-entry array cap. | Concrete numbers chosen from research-doc and plan-003 §0.3 reconciliation; total worst-case ~700 KB << NFR-19's 8 MB ceiling. (LT-6.4.) |

---

> **End of Live Transcription Subsystem (Plan-003) section.** This section
> is the binding technical design for Phases 6 (Coders) and onward; Phase 7
> (Code Review) uses §LT-3.1, §LT-4, §LT-5, §LT-6, §LT-11 as the
> conformance source-of-truth alongside `plan-003-live-transcription.md`'s
> §5.3 checklist.

---

## §AS — Apple Speech Streaming Subsystem (plan-005)

> **Added 2026-04-28 (plan-005 Phase 0 / Task 0.7).** This section anchors
> the on-device, low-latency live-transcription provider introduced by
> `plan-005-apple-speech-streaming.md`. It runs alongside (and is the new
> default for) the REST-batch architecture established by §LT / plan-004.

**AS-1 Architecture.** On-device streaming via `SpeechAnalyzer` (macOS 26+).
One `AppleSpeechSession` per source tag; N parallel `SpeechAnalyzer`
instances per session (one per locale).

**AS-2 Pipeline-mode selection.** TranscriptionManager picks
`StreamingTranscriptionPipeline` when
`provider.supportedModes.contains(.streaming)` (apple); else
`BatchTranscriptionPipeline` (gemini, noop, fake).

**AS-3 Reconciliation.** Per-utterance: collect finals from all parallel
analyzers within 150 ms window, pick highest confidence, tag winner's
locale.

**AS-4 Sidecar policy.** Streaming policy persists only on
`.segmentFinalized` events. Batch policy (plan-004) unchanged.

**AS-5 TCC.** Speech-permission preflight in
`setUpTranscriptionPipelineIfNeeded` for apple provider.

See plan-005-apple-speech-streaming.md §3–§7 for full contracts.


---

## Plan-007 Design — Additional STT Engines (Azure OpenAI + ElevenLabs)

> **Added 2026-04-29.** Technical design that complements
> `docs/design/plan-007-additional-stt-engines.md` (the WHAT) by specifying
> the HOW: module boundaries, Swift type signatures, error mapping,
> sequence diagrams, and back-compat impact on the existing
> `TranscriptionProvider` contract introduced by plan-005 §4.1.
>
> **Mandatory inputs read for this design pass**:
> - `docs/design/refined-request-additional-stt-engines.md`
> - `docs/design/plan-007-additional-stt-engines.md`
> - `docs/reference/codebase-scan-additional-stt-engines.md`
> - `docs/reference/investigation-additional-stt-engines.md`
> - `docs/research/azure-openai-gpt-4o-mini-transcribe-wire-schema.md`
> - `docs/research/elevenlabs-stt-wire-schema.md`
> - The actual codebase: `Sources/MacrecCore/Transcription/TranscriptionProvider.swift`,
>   `…/StreamingTranscriptionSession.swift`, `…/TranscriptionOptions.swift`,
>   `…/Providers/GeminiRESTTranscriptionProvider.swift`,
>   `…/Providers/TranscriptionProviderFactory.swift`,
>   `…/AudioWAVEncoder.swift`, `Sources/MacrecCore/Errors/MacrecError.swift`,
>   `Sources/MacrecCore/Config/RecordingOptions.swift`,
>   `Sources/MacrecCore/Config/ConfigResolver.swift`,
>   `Sources/MacrecCore/Transcription/TranscriptEvent.swift` (TranscriptionMetrics).
>
> **Approved exceptions honoured**: Exception 001 (Swift, not TypeScript),
> Exception 002 (macOS 26 deployment target).
>
> **Project rules honoured**: no fallback values for required configuration;
> no new SwiftPM dependencies (Foundation `URLSession` + in-tree multipart
> helper only); vendor-canonical env-var names (`AZURE_OPENAI_*`,
> `ELEVENLABS_API_KEY`) per CLAUDE.md eight-standard-providers list;
> expiration-companion env vars per CLAUDE.md `<configuration-guide>`.

### §07D-1 Architecture overview

#### §07D-1.1 Where the new modules slot in

The two new providers live alongside the four existing concrete
conformers under `Sources/MacrecCore/Transcription/Providers/`. Each new
provider receives its own subfolder so its wire-format Codable types,
typed error enum, config struct, and provider implementation stay
colocated:

```
Sources/MacrecCore/Transcription/
├── Providers/
│   ├── AppleSpeechTranscriptionProvider.swift          (existing — plan-005)
│   ├── GeminiRESTTranscriptionProvider.swift           (existing — plan-004)
│   ├── WhisperKitTranscriptionProvider.swift           (existing — plan-004 ext.)
│   ├── TranscriptionProviderFactory.swift              (existing — extended; +2 cases)
│   │
│   ├── Azure/                                          (NEW — Phase A)
│   │   ├── AzureOpenAIConfig.swift
│   │   ├── AzureOpenAIWireTypes.swift                  (Codable req/response/error envelope)
│   │   ├── AzureOpenAISTTError.swift
│   │   └── AzureOpenAITranscriptionProvider.swift
│   │
│   └── ElevenLabs/                                     (NEW — Phase B)
│       ├── ElevenLabsConfig.swift
│       ├── ElevenLabsWireTypes.swift                   (Codable req/response/error envelope)
│       ├── ElevenLabsSTTError.swift
│       └── ElevenLabsTranscriptionProvider.swift
│
├── Net/                                                (NEW — Phase 0)
│   └── MultipartFormDataBuilder.swift                  (shared multipart body builder)
│
├── NoOpTranscriptionProvider.swift                     (existing, unchanged)
├── FakeTranscriptionProvider.swift                     (existing, unchanged)
├── TranscriptionProvider.swift                         (existing, UNCHANGED — protocol untouched)
├── StreamingTranscriptionSession.swift                 (existing, unchanged)
├── TranscriptionOptions.swift                          (existing, UNCHANGED)
├── TranscriptionManager.swift                          (existing, unchanged)
├── AudioWAVEncoder.swift                               (existing, unchanged — non-throwing)
└── …
```

#### §07D-1.2 Component diagram

```mermaid
flowchart TD
  CLI[Sources/macrec/Commands/StartCommand.swift\n--transcribe {none,apple,gemini,whisperkit,azure,elevenlabs}]
  UI[Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift\nflat picker; +Azure +ElevenLabs entries]
  Resolver[ConfigResolver.resolve\n4-tier env chain\nAZURE_OPENAI_* / ELEVENLABS_*]
  Options[RecordingOptions\n+azureOpenAI{Endpoint,Deployment,ApiVersion,ApiKeyExpiresAt}\n+elevenLabs{...}]
  Factory[TranscriptionProviderFactory.build\nswitch normalized id\n+ case azure / case elevenlabs]
  Proto((TranscriptionProvider protocol\nSendable; transcribe + openStreamingSession))

  subgraph Providers
    NoOp[NoOpTranscriptionProvider\nsupportedModes = none/both]
    Fake[FakeTranscriptionProvider\nsupportedModes = both]
    Gem[GeminiRESTTranscriptionProvider\nsupportedModes = batch]
    Apple[AppleSpeechTranscriptionProvider\nsupportedModes = streaming]
    WK[WhisperKitTranscriptionProvider\nsupportedModes = batch]
    AZ[AzureOpenAITranscriptionProvider\nsupportedModes = batch  -- NEW]
    EL[ElevenLabsTranscriptionProvider\nsupportedModes = batch  -- NEW]
  end

  Net[Transcription/Net/MultipartFormDataBuilder\nshared value-type body builder]
  WAV[AudioWAVEncoder\n16 kHz mono Int16 WAV]

  Sidecar[TranscriptSidecarWriter\nSidecarPolicy.batch\njsonl/srt/vtt/txt]

  CLI --> Resolver
  UI --> Resolver
  Resolver --> Options
  Options --> Factory
  Factory --> Proto
  Proto -.-> NoOp
  Proto -.-> Fake
  Proto -.-> Gem
  Proto -.-> Apple
  Proto -.-> WK
  Proto -.-> AZ
  Proto -.-> EL
  AZ --> WAV
  EL --> WAV
  AZ --> Net
  EL --> Net
  AZ --> Sidecar
  EL --> Sidecar
  Gem --> Sidecar
```

`MultipartFormDataBuilder` is the **only** shared concern between the two
new providers; everything else (URL templating, auth header, request body
field set, response decoding, error envelope shape, retry policy) is
deliberately isolated per-provider.

### §07D-2 Module / file map

| File path (under `Sources/MacrecCore/`) | Public types exported | One-sentence purpose |
|---|---|---|
| `Transcription/Net/MultipartFormDataBuilder.swift` | `public struct MultipartFormDataBuilder: Sendable` | Pure-Foundation `multipart/form-data` body builder shared by Azure + ElevenLabs (and any future REST provider). Value type; in-memory body only — large-file streaming variant is a future extension. |
| `Transcription/Providers/Azure/AzureOpenAIConfig.swift` | `public struct AzureOpenAIConfig: Sendable, Equatable` | Resolved Azure-OpenAI configuration captured at provider construction (endpoint URL, deployment name, api-version, api-key, optional expiry). Construction throws `MacrecError.transcriptionConfigConflict` on validation failure. |
| `Transcription/Providers/Azure/AzureOpenAIWireTypes.swift` | `public enum AzureOpenAIWire { struct TranscriptionResponse; struct ErrorEnvelope; struct APIMErrorEnvelope }` | All Codable wire types for the Azure-OpenAI `audio/transcriptions` endpoint (response body + the two error envelope shapes the gateway can return). |
| `Transcription/Providers/Azure/AzureOpenAISTTError.swift` | `public enum AzureOpenAISTTError: Error, Sendable, LocalizedError` | Internal typed error enum for the Azure provider. Mapped to `MacrecError` at the provider's call boundary so `MacrecError` does not need new cases. |
| `Transcription/Providers/Azure/AzureOpenAITranscriptionProvider.swift` | `public struct AzureOpenAITranscriptionProvider: TranscriptionProvider` | The Azure-OpenAI batch provider. Conforms to existing `TranscriptionProvider` unchanged. |
| `Transcription/Providers/ElevenLabs/ElevenLabsConfig.swift` | `public struct ElevenLabsConfig: Sendable, Equatable; public enum ElevenLabsFileFormat: String` | Resolved ElevenLabs configuration captured at provider construction (api-key, model id, optional language code, diarize, etc.). |
| `Transcription/Providers/ElevenLabs/ElevenLabsWireTypes.swift` | `public enum ElevenLabsWire { struct TranscriptionResponse; struct Word; struct DetailEnvelope }` | All Codable wire types for ElevenLabs `/v1/speech-to-text` (response body + FastAPI-style `{detail: {status, message}}` error envelope). |
| `Transcription/Providers/ElevenLabs/ElevenLabsSTTError.swift` | `public enum ElevenLabsSTTError: Error, Sendable, LocalizedError` | Internal typed error enum for the ElevenLabs provider. |
| `Transcription/Providers/ElevenLabs/ElevenLabsTranscriptionProvider.swift` | `public struct ElevenLabsTranscriptionProvider: TranscriptionProvider` | The ElevenLabs batch provider. Conforms to existing `TranscriptionProvider` unchanged. |

**Factory-registration changes**:

| File | Symbol | Change |
|---|---|---|
| `Transcription/Providers/TranscriptionProviderFactory.swift` | `TranscriptionProviderFactoryInput` | Add three optional fields: `azureOpenAIEndpoint: String?`, `azureOpenAIDeployment: String?`, `azureOpenAIApiVersion: String?`. All `nil`-defaulted; existing call sites compile unchanged. |
| `Transcription/Providers/TranscriptionProviderFactory.swift` | `TranscriptionProviderFactory.build(_:)` | Add two `case` branches before `default`: `case "azure":` and `case "elevenlabs":`. Update `default` error message to enumerate the six allowed values. |
| `Config/RecordingOptions.swift` | `enum TranscriptionProviderId` | Add three cases: `case whisperkit` (drift fix), `case azure`, `case elevenlabs`. |
| `Config/RecordingOptions.swift` | `struct RecordingOptions` | Add five new optional stored properties (`azureOpenAIEndpoint`, `azureOpenAIDeployment`, `azureOpenAIApiVersion`, `azureOpenAIApiKeyExpiresAt`, `elevenLabsApiKeyExpiresAt`); update `init(...)` defaults; extend `withOutput(_:)` to forward each. |
| `Config/ConfigResolver.swift` | `enum Keys` | Add `azureOpenAIApiKey`, `azureOpenAIEndpoint`, `azureOpenAIDeployment`, `azureOpenAIApiVersion`, `azureOpenAIApiKeyExpiresAt`, `elevenLabsApiKey`, `elevenLabsApiKeyExpiresAt` (+ optional ElevenLabs tuning keys per plan-007 §5.1). |
| `Config/ConfigResolver.swift` | `resolve(cliOverrides:)` (lines 345-354 switch) | Extend the `transcriptionApiKey` switch to handle `.azure`, `.elevenlabs`, `.whisperkit`. |

### §07D-3 Type contracts (Swift signatures)

All signatures below are **verified** against the actual code in this
worktree. Where plan-007 disagrees with the actual code, the actual code
wins and the discrepancy is called out in §07D-9 / the closing report.

#### §07D-3.1 `MultipartFormDataBuilder`

```swift
// Sources/MacrecCore/Transcription/Net/MultipartFormDataBuilder.swift
import Foundation

/// In-memory builder for `multipart/form-data` request bodies.
///
/// Value-type semantics: callers mutate a local copy, then call
/// `build()` to obtain the final `(contentType, body)` pair.
/// Allocation cost per request is dominated by the audio payload itself,
/// so a value type is the right shape; an actor would force needless
/// suspension points around what is otherwise a straight `Data`
/// accumulator.
///
/// **In-memory only** — entire body is materialised in `Data`. Adequate
/// for the Azure 25 MB ceiling and for the typical macrec 2.5 s WAV
/// chunk (~80 KB). For larger ElevenLabs uploads (> ~50 MB), see
/// §07D-7 for the documented streaming-upload threshold and the
/// future `URLRequest.httpBodyStream` extension path.
public struct MultipartFormDataBuilder: Sendable {

    /// The randomly-generated boundary that separates parts.
    public let boundary: String

    /// Computed `Content-Type` header value (`multipart/form-data; boundary=<boundary>`).
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    private var body: Data = Data()
    private var finalised: Bool = false

    public init(boundary: String = "MacrecBoundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// Append a text form field.
    public mutating func appendField(name: String, value: String)

    /// Append a file form field. `data` is the raw bytes; `filename` and
    /// `contentType` are used only for the part headers — the server
    /// uses the raw bytes regardless.
    public mutating func appendFile(
        name: String,
        filename: String,
        data: Data,
        contentType: String
    )

    /// Returns the final body bytes and the matching `Content-Type`
    /// header value. Idempotent — safe to call multiple times; the first
    /// call appends the closing boundary `--<boundary>--\r\n`.
    public mutating func build() -> (body: Data, contentType: String)
}
```

The builder uses CRLF (`\r\n`) line terminators per RFC 7578, encodes
headers in ASCII, and writes the file payload verbatim (no transfer
encoding, no base64).

#### §07D-3.2 `AzureOpenAIConfig`

```swift
// Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAIConfig.swift
import Foundation

public struct AzureOpenAIConfig: Sendable, Equatable {

    /// Base endpoint URL, e.g. `https://my-resource.openai.azure.com`.
    /// Trailing slash is tolerated and stripped during URL composition.
    public let endpoint: URL

    /// User-chosen deployment name (NOT the model name). The server
    /// also requires this value as the `model` multipart field —
    /// Azure's OpenAI-compatibility quirk.
    public let deployment: String

    /// `api-version` query-string value, e.g. `"2025-03-01-preview"`.
    public let apiVersion: String

    /// Resolved API key (sent via the `api-key` request header — NOT a
    /// `Bearer` prefix; raw key only).
    public let apiKey: String

    /// Optional ISO-8601 expiry timestamp captured from
    /// `AZURE_OPENAI_API_KEY_EXPIRES_AT`. Drives the "key expires in N
    /// days" startup warning when within ~7 days.
    public let apiKeyExpiresAt: Date?

    /// Construct and validate. Throws `MacrecError.transcriptionConfigConflict`
    /// when fields fail validation (empty deployment, non-https endpoint,
    /// malformed apiVersion). Empty-key validation belongs to the
    /// factory (which already throws `transcriptionApiKeyMissing`).
    ///
    /// **No fallbacks**: this initializer treats every field as a
    /// required input. The factory is the sole caller that resolves
    /// optional defaults (e.g. the documented `apiVersion` starter).
    public init(
        endpoint: URL,
        deployment: String,
        apiVersion: String,
        apiKey: String,
        apiKeyExpiresAt: Date? = nil
    ) throws

    /// Companion factory consumed only by tests; production code routes
    /// through `TranscriptionProviderFactory` which calls
    /// `init(endpoint:deployment:apiVersion:apiKey:apiKeyExpiresAt:)` above.
    public static func fromEnvironment(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AzureOpenAIConfig
}
```

`fromEnvironment(env:)` is a convenience for tests and for the
documentation guide examples; it throws `MacrecError.transcriptionApiKeyMissing(provider: "azure")`
or `MacrecError.transcriptionConfigConflict(reason:)` for missing
required env vars (`AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`,
`AZURE_OPENAI_DEPLOYMENT`). The production path resolves these in
`ConfigResolver` and constructs the config in the factory; this
initializer is *not* the production entry point.

#### §07D-3.3 `ElevenLabsConfig`

```swift
// Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsConfig.swift
import Foundation

public enum ElevenLabsFileFormat: String, Sendable, Equatable, CaseIterable {
    /// Low-latency fast-path: matches the bytes that `AudioWAVEncoder`
    /// always produces (16 kHz mono Int16 WAV).
    case pcmS16le16 = "pcm_s16le_16"

    /// Any other supported format (m4a, mp3, ogg, etc.). Use when the
    /// upstream encoder is not `AudioWAVEncoder`.
    case other = "other"
}

public struct ElevenLabsConfig: Sendable, Equatable {

    /// Resolved API key (sent via the `xi-api-key` request header).
    public let apiKey: String

    /// Vendor model id. Default `"scribe_v2"`. Older accounts may use
    /// `"scribe_v1"` — both are accepted; values outside the known
    /// list log a warning but pass through.
    public let modelId: String

    /// Optional ISO-639-1 (`"en"`, `"el"`) or ISO-639-3 (`"eng"`,
    /// `"ell"`) hint. `nil` lets the model auto-detect.
    public let languageCode: String?

    /// When `true`, request `diarize=true` so the response carries
    /// `speaker_id` per word.
    public let diarize: Bool

    /// When `true`, request `tag_audio_events=true` so the response
    /// includes `(laughter)`, `(music)`, etc.
    public let tagAudioEvents: Bool

    /// Optional speaker-count hint in `1..32`. `nil` lets the model
    /// pick.
    public let numSpeakers: Int?

    /// File-format hint. Defaults to `.pcmS16le16` because
    /// `AudioWAVEncoder` is the only producer of the bytes we send
    /// (see §13 EL-3 in plan-007).
    public let fileFormat: ElevenLabsFileFormat

    /// Optional entity-detection mode (`"all"`, `"pii"`, `"phi"`,
    /// `"pci"`). Carries a +30 % surcharge per the wire-schema
    /// research §3.6. `nil` means OFF (v1 default per §13 EL-2).
    public let entityDetection: String?

    /// Optional timestamps granularity (`"word"` | `"character"`).
    /// `nil` means use the server default (currently word-level).
    public let timestampsGranularity: String?

    /// Optional ISO-8601 expiry timestamp captured from
    /// `ELEVENLABS_API_KEY_EXPIRES_AT`.
    public let apiKeyExpiresAt: Date?

    /// Construct and validate. Throws
    /// `MacrecError.transcriptionConfigConflict` when `numSpeakers`
    /// is out of `1..32` range or `entityDetection` is not in the
    /// vendor enum (§3.6 of the wire-schema research). Empty-key
    /// validation belongs to the factory.
    public init(
        apiKey: String,
        modelId: String = "scribe_v2",
        languageCode: String? = nil,
        diarize: Bool = false,
        tagAudioEvents: Bool = true,
        numSpeakers: Int? = nil,
        fileFormat: ElevenLabsFileFormat = .pcmS16le16,
        entityDetection: String? = nil,
        timestampsGranularity: String? = nil,
        apiKeyExpiresAt: Date? = nil
    ) throws

    public static func fromEnvironment(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ElevenLabsConfig
}
```

#### §07D-3.4 `AzureOpenAIWireTypes`

```swift
// Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAIWireTypes.swift
import Foundation

public enum AzureOpenAIWire {

    /// Successful `response_format=json` body. The model also supports
    /// `verbose_json`, `srt`, `vtt`, `text` — but `gpt-4o-mini-transcribe`
    /// only accepts `json` / `text` (research §4.3-§4.4). v1 requests
    /// `json`, so this minimal struct is sufficient.
    public struct TranscriptionResponse: Decodable, Sendable, Equatable {
        public let text: String
    }

    /// Standard OpenAI / Azure OpenAI error envelope. Produced when the
    /// model's own gateway rejects the request (auth, validation, rate
    /// limit, model error).
    public struct ErrorEnvelope: Decodable, Sendable, Equatable {
        public let error: ErrorBody

        public struct ErrorBody: Decodable, Sendable, Equatable {
            public let message: String?
            public let type: String?
            public let code: String?
            public let param: String?
        }
    }

    /// APIM (Azure API Management) error envelope. Produced when the
    /// front-door rejects the request before reaching the model
    /// (deployment-not-found 404, throttle 429 from APIM, regional
    /// outage 503). Distinct from `ErrorEnvelope`.
    public struct APIMErrorEnvelope: Decodable, Sendable, Equatable {
        public let statusCode: Int?
        public let message: String?
    }
}
```

#### §07D-3.5 `ElevenLabsWireTypes`

```swift
// Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsWireTypes.swift
import Foundation

public enum ElevenLabsWire {

    /// Successful single-channel response (`use_multi_channel=false`).
    /// `language_code` and `language_probability` are optional in the
    /// observed wire shape so the decoder tolerates servers that omit
    /// them. The multi-channel response shape is intentionally NOT
    /// modelled — v1 never sets `use_multi_channel`.
    public struct TranscriptionResponse: Decodable, Sendable, Equatable {
        public let text: String
        public let words: [Word]?
        public let languageCode: String?
        public let languageProbability: Double?

        enum CodingKeys: String, CodingKey {
            case text, words
            case languageCode = "language_code"
            case languageProbability = "language_probability"
        }
    }

    public struct Word: Decodable, Sendable, Equatable {
        public let text: String
        public let start: Double
        public let end: Double
        public let type: String          // "word" | "spacing" | "audio_event"
        public let speakerId: String?    // present when diarize=true

        enum CodingKeys: String, CodingKey {
            case text, start, end, type
            case speakerId = "speaker_id"
        }
    }

    /// FastAPI-style error envelope: `{"detail": {"status": "...", "message": "..."}}`.
    /// Sometimes `detail` is a bare string for transport-level failures
    /// outside FastAPI's validator — the decoder tolerates both shapes
    /// through a manual `init(from:)`.
    public struct DetailEnvelope: Decodable, Sendable, Equatable {
        public let status: String?
        public let message: String?

        public init(status: String?, message: String?) { … }
        public init(from decoder: Decoder) throws { … }   // tolerates bare-string `detail`
    }
}
```

#### §07D-3.6 `AzureOpenAISTTError`

```swift
// Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAISTTError.swift
import Foundation

/// Internal typed error for the Azure-OpenAI provider. Mapped to
/// `MacrecError` at the provider's call boundary by
/// `AzureOpenAITranscriptionProvider.mapToMacrecError(_:)` so the
/// top-level `MacrecError` enum does not gain provider-specific cases.
public enum AzureOpenAISTTError: Error, Sendable, LocalizedError, Equatable {
    case invalidApiKey                              // HTTP 401
    case permissionDenied                           // HTTP 403
    case deploymentNotFound(deployment: String)     // HTTP 404 / DeploymentNotFound
    case fileTooLarge(byteCount: Int)               // HTTP 413 / file_too_large
    case unsupportedAudioFormat(detail: String)     // HTTP 415 / invalid_audio
    case invalidRequest(message: String)            // other HTTP 400
    case rateLimited(retryAfterSec: Double?)        // HTTP 429
    case networkTimeout                             // HTTP 408 or URLError.timedOut
    case serverError(statusCode: Int)               // HTTP 500/503
    case networkError(underlying: Error)            // any other URLError
    case unexpectedResponse(statusCode: Int, bodyPrefix: String)
    case decodeFailure(underlying: Error)

    public var errorDescription: String? { … }
}
```

#### §07D-3.7 `ElevenLabsSTTError`

```swift
// Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsSTTError.swift
import Foundation

public enum ElevenLabsSTTError: Error, Sendable, LocalizedError, Equatable {
    case invalidApiKey                              // HTTP 401
    case insufficientCredits                        // HTTP 402
    case planFeatureGate(feature: String)           // HTTP 403
    case fileTooLarge(byteCount: Int)               // HTTP 413 (> 3 GB)
    case audioTooLong(durationSec: Double)          // HTTP 422 / audio_too_long
    case audioTooShort                              // pre-flight; never raised
    case unsupportedFormat(detail: String)          // HTTP 400/422
    case invalidParameter(field: String, message: String)  // HTTP 422
    case rateLimited(retryAfterSec: Double?)        // HTTP 429 / rate_limit_exceeded
    case concurrentLimitExceeded                    // HTTP 429 / concurrent_limit_exceeded
    case serverError(statusCode: Int)               // HTTP 500/503
    case networkFailure(underlying: Error)
    case decodingFailure(underlying: Error)

    public var errorDescription: String? { … }
}
```

#### §07D-3.8 `AzureOpenAITranscriptionProvider`

```swift
// Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAITranscriptionProvider.swift
import Foundation
import Logging

/// Azure-OpenAI batch transcription provider. Stateless across calls;
/// one `URLSession.data(for:)` per `transcribe` invocation.
public struct AzureOpenAITranscriptionProvider: TranscriptionProvider, Sendable {

    public let id = "azure"
    public let displayName = "Azure OpenAI"
    public let supportedModes: Set<TranscriptionMode> = [.batch]

    private let config: AzureOpenAIConfig
    private let urlSession: URLSession
    private let logger: Logger
    private let clock: any TranscriptionClock          // injectable for tests; default = system clock

    public init(
        config: AzureOpenAIConfig,
        urlSession: URLSession = .shared,
        logger: Logger = LoggerFactory.make("macrec.transcription.azure"),
        clock: any TranscriptionClock = SystemTranscriptionClock()
    )

    // MARK: TranscriptionProvider conformance

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession
    // throws MacrecError.transcriptionConfigConflict — batch-only provider

    // MARK: Internal helpers (private)

    private func buildURL() throws -> URL
    // Composes:
    //   <endpoint>/openai/deployments/<deployment>/audio/transcriptions?api-version=<apiVersion>

    private func buildMultipartBody(
        wav: Data,
        options: TranscriptionOptions
    ) -> (body: Data, contentType: String)
    // Fields: file (audio.wav), model (=deployment), response_format (json),
    //         language (BCP-47 first hint, region-stripped, optional),
    //         prompt (options.customSystemInstruction, optional)

    private func performRequestWithRetries(
        request: URLRequest,
        body: Data
    ) async throws -> (Data, HTTPURLResponse)
    // Retry loop: max 3 attempts; honour Retry-After on 429;
    // exponential backoff with ±20 % jitter on 408/429/500/503 +
    // URLError.timedOut / URLError.networkConnectionLost.

    private func mapHTTPError(
        statusCode: Int,
        body: Data,
        retryAfter: Double?
    ) -> AzureOpenAISTTError
    // Decodes both ErrorEnvelope and APIMErrorEnvelope shapes to pick
    // the right typed case.

    private func decodeResponse(_ data: Data) throws -> AzureOpenAIWire.TranscriptionResponse

    private func mapToMacrecError(_ azureErr: AzureOpenAISTTError) -> MacrecError
    // The single boundary where AzureOpenAISTTError -> MacrecError
    // happens, per the §07D-6 mapping table.

    /// Optional cost reporter; called by the manager via §07D-8 hooks.
    public func costFor(durationSeconds: Double) -> Double {
        durationSeconds * AzureOpenAIPricing.usdPerSecond
    }
}
```

#### §07D-3.9 `ElevenLabsTranscriptionProvider`

```swift
// Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsTranscriptionProvider.swift
import Foundation
import Logging

public struct ElevenLabsTranscriptionProvider: TranscriptionProvider, Sendable {

    public let id = "elevenlabs"
    public let displayName = "ElevenLabs Scribe v2"
    public let supportedModes: Set<TranscriptionMode> = [.batch]

    /// Hardcoded — the `/v1/speech-to-text` endpoint is the only batch
    /// surface ElevenLabs ships and the host is account-agnostic.
    private static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    /// Streaming-upload threshold — bodies above this size use
    /// `URLRequest.httpBodyStream` instead of in-memory `httpBody`.
    /// See §07D-7 for the rationale and the v1 value.
    public static let streamingUploadThresholdBytes: Int = 50 * 1024 * 1024

    private let config: ElevenLabsConfig
    private let urlSession: URLSession
    private let logger: Logger
    private let clock: any TranscriptionClock

    public init(
        config: ElevenLabsConfig,
        urlSession: URLSession = .shared,
        logger: Logger = LoggerFactory.make("macrec.transcription.elevenlabs"),
        clock: any TranscriptionClock = SystemTranscriptionClock()
    )

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession
    // throws MacrecError.transcriptionConfigConflict — batch-only in v1

    private func buildMultipartBody(
        wav: Data,
        options: TranscriptionOptions
    ) -> (body: Data, contentType: String)
    // Fields per wire-schema research §3:
    //   model_id, file_format, file (audio.wav),
    //   language_code (config or options.languageHints.first, optional),
    //   diarize (only when true), num_speakers (when set),
    //   tag_audio_events, timestamps_granularity (when set),
    //   entity_detection (when set)

    private func performRequestWithRetries(
        request: URLRequest,
        body: Data
    ) async throws -> (Data, HTTPURLResponse)
    // Retry loop: max 3 attempts; backoff 1s/2s/4s with ±20 % jitter
    // (ElevenLabs does NOT return Retry-After per research §8). Retry
    // on 429 rate_limit_exceeded / system_busy, 500, 503. NEVER retry
    // on 429 concurrent_limit_exceeded — surface immediately.

    private func mapHTTPError(
        statusCode: Int,
        body: Data
    ) -> ElevenLabsSTTError

    private func decodeResponse(_ data: Data) throws -> ElevenLabsWire.TranscriptionResponse

    private func mapToMacrecError(_ err: ElevenLabsSTTError) -> MacrecError

    public func costFor(durationSeconds: Double) -> Double {
        var usd = (durationSeconds / 3600.0) * ElevenLabsPricing.usdPerHourBase
        if config.entityDetection != nil { usd *= 1.30 }
        return usd
    }
}
```

#### §07D-3.10 Pricing constants (shared per-engine modules)

```swift
// Embedded inside each provider module to keep magic numbers out of the
// transcribe(...) body. Public so tests and the cost-summary surface
// can reference them without re-deriving.

public enum AzureOpenAIPricing {
    /// $0.003 per minute (research §A.6); divided to per-second for arithmetic.
    public static let usdPerMinute: Double = 0.003
    public static let usdPerSecond: Double = usdPerMinute / 60.0
}

public enum ElevenLabsPricing {
    /// $0.22 per audio hour for both `scribe_v1` and `scribe_v2` batch tiers.
    public static let usdPerHourBase: Double = 0.22
    /// Multiplier applied when `entity_detection` is set.
    public static let entityDetectionSurchargeMultiplier: Double = 1.30
}
```

#### §07D-3.11 `TranscriptionClock` injectable

```swift
// Sources/MacrecCore/Transcription/Net/TranscriptionClock.swift
// (Optional — included only if not already present elsewhere.)

public protocol TranscriptionClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemTranscriptionClock: TranscriptionClock, Sendable {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
```

The injectable clock is needed because retry tests cannot wait real
seconds. Existing providers can keep using `Task.sleep(...)` directly;
this abstraction is opt-in per new provider.

### §07D-4 Configuration model

#### §07D-4.1 Azure OpenAI

| Env var | Required? | Type | Default | How obtained | Expiration tracking | Config-guide section |
|---|---|---|---|---|---|---|
| `AZURE_OPENAI_API_KEY` | YES — throws `MacrecError.transcriptionApiKeyMissing(provider: "azure")` (exit 78) when active provider is `"azure"` and value is missing/empty. | `String` | none — no fallback. | Azure portal → Resource → Keys & Endpoint. | `AZURE_OPENAI_API_KEY_EXPIRES_AT`. | `configuration-guide.md` §LT-Az.1 |
| `AZURE_OPENAI_ENDPOINT` | YES — throws `MacrecError.transcriptionConfigConflict(reason:)` (exit 64) when missing. | `URL` (`https://…`) | none. | Azure portal → Resource → Keys & Endpoint (the "Endpoint" field; format `https://<resource-name>.openai.azure.com`). | n/a | §LT-Az.2 |
| `AZURE_OPENAI_DEPLOYMENT` | YES — throws `MacrecError.transcriptionConfigConflict(reason:)` (exit 64) when missing. | `String` | none. | Azure Foundry → Models + endpoints → user's deployment name. | n/a | §LT-Az.3 |
| `AZURE_OPENAI_API_VERSION` | NO (documented-default-in-config-guide-only — see §07D-13 Open Question OQ-D-2). | `String` (e.g. `"2025-03-01-preview"`) | `"2025-03-01-preview"` (resolved by the factory; documented as a starter pin in `configuration-guide.md` §LT-Az.4). | Microsoft "What's New for Azure OpenAI" page. | n/a | §LT-Az.4 |
| `AZURE_OPENAI_API_KEY_EXPIRES_AT` | NO. | ISO-8601 `Date` | none. | User-supplied; surfaces a "key expires in N days" warning at startup. | (this *is* the expiration tracker) | §LT-Az.5 |

#### §07D-4.2 ElevenLabs

| Env var | Required? | Type | Default | How obtained | Expiration tracking | Config-guide section |
|---|---|---|---|---|---|---|
| `ELEVENLABS_API_KEY` | YES — throws `MacrecError.transcriptionApiKeyMissing(provider: "elevenlabs")` (exit 78). | `String` | none. | `https://elevenlabs.io/app/settings/api-keys`. | `ELEVENLABS_API_KEY_EXPIRES_AT`. | §LT-EL.1 |
| `ELEVENLABS_MODEL_ID` | NO. | `String` | `"scribe_v2"` (provider-side default; `scribe_v1` accepted). | Vendor catalogue. | n/a | §LT-EL.2 |
| `ELEVENLABS_LANGUAGE_CODE` | NO. | `String` (ISO-639-1 / ISO-639-3) | unset (auto-detect). | User-supplied. | n/a | §LT-EL.3 |
| `ELEVENLABS_DIARIZE` | NO. | `Bool` | `false`. | User-supplied. | n/a | §LT-EL.4 |
| `ELEVENLABS_TAG_AUDIO_EVENTS` | NO. | `Bool` | `true`. | User-supplied. | n/a | §LT-EL.5 |
| `ELEVENLABS_NUM_SPEAKERS` | NO. | `Int` (1..32) | unset. | User-supplied. | n/a | §LT-EL.6 |
| `ELEVENLABS_FILE_FORMAT` | NO. | `pcm_s16le_16` \| `other` | `pcm_s16le_16` (matches `AudioWAVEncoder` output). | n/a | n/a | §LT-EL.7 |
| `ELEVENLABS_ENTITY_DETECTION` | NO. | `String` (`all` \| `pii` \| `phi` \| `pci` \| `none`) | unset (off). | User-supplied. **+30 % surcharge when set.** | n/a | §LT-EL.8 |
| `ELEVENLABS_API_KEY_EXPIRES_AT` | NO. | ISO-8601 `Date` | none. | User-supplied. | (this *is* the expiration tracker) | §LT-EL.9 |

**No fallback discipline** — the only "default" applied at the
*resolver* layer is `AZURE_OPENAI_API_VERSION` (Open Question OQ-D-2;
treated as a documented starter, not a silent default). Every other
required field that is absent throws at factory-build time. The optional
fields with defaults all use **provider-side** defaults (the field is
`nil` at the resolver layer; the provider's `init` substitutes a
documented, hardcoded vendor-default value), which is the project's
existing pattern (mirrors how `GeminiRESTTranscriptionProvider` defaults
`modelId` to `defaultModelId` when `MACREC_TRANSCRIBE_MODEL` is unset).

### §07D-5 Sequence diagrams

#### §07D-5.1 Happy path: 30 s audio with `--transcribe azure`

```mermaid
sequenceDiagram
    autonumber
    participant CLI as macrec start CLI
    participant Resolver as ConfigResolver
    participant Factory as TranscriptionProviderFactory
    participant Mgr as TranscriptionManager (batch pipeline)
    participant Buf as SourceBuffer (per source)
    participant Provider as AzureOpenAITranscriptionProvider
    participant WAV as AudioWAVEncoder
    participant MP as MultipartFormDataBuilder
    participant URLSession
    participant Sidecar as TranscriptSidecarWriter (.batch)

    CLI->>Resolver: resolve(cliOverrides)
    Resolver->>Resolver: 4-tier env chain reads AZURE_OPENAI_*
    Resolver-->>CLI: RecordingOptions
    CLI->>Factory: build(TranscriptionProviderFactoryInput)
    Factory->>Factory: switch normalized id "azure"
    Factory->>Provider: init(config: AzureOpenAIConfig, urlSession: .shared)
    Factory-->>CLI: provider

    Note over CLI,Mgr: Recording starts; aligned 100 ms frames flow in.
    loop every 2.5 s (flush cadence) for 30 s
        Buf->>Mgr: drain([Float] 16 kHz mono)
        Mgr->>Provider: transcribe(samples:source:options:)
        Provider->>WAV: encode(samples:)
        WAV-->>Provider: Data (~80 KB WAV)
        Provider->>MP: appendFile(file=audio.wav) + appendField(model, response_format, language, prompt)
        MP-->>Provider: (body, contentType)
        Provider->>URLSession: data(for: URLRequest)\nendpoint/openai/deployments/<dep>/audio/transcriptions?api-version=…
        URLSession-->>Provider: (Data, HTTPURLResponse 200)
        Provider->>Provider: decode AzureOpenAIWire.TranscriptionResponse
        Provider-->>Mgr: text: String
        Mgr->>Sidecar: write segmentAppended / segmentUpdated
    end

    CLI->>Mgr: stop()
    Mgr->>Sidecar: flush + close
    Sidecar-->>CLI: jsonl/srt/vtt/txt files
```

#### §07D-5.2 Happy path: same with `--transcribe elevenlabs`

```mermaid
sequenceDiagram
    autonumber
    participant CLI as macrec start CLI
    participant Mgr as TranscriptionManager (batch)
    participant Provider as ElevenLabsTranscriptionProvider
    participant WAV as AudioWAVEncoder
    participant MP as MultipartFormDataBuilder
    participant URLSession
    participant Sidecar as TranscriptSidecarWriter (.batch)

    Note over CLI,Mgr: Same setup as Azure case; provider id "elevenlabs".

    loop every 2.5 s for 30 s
        Mgr->>Provider: transcribe(samples:source:options:)

        alt samples.count < 1600 (i.e. < 100 ms)
            Provider-->>Mgr: ""
        else normal chunk
            Provider->>WAV: encode(samples:)
            WAV-->>Provider: Data
            Provider->>Provider: pre-flight: bytes <= 3 GB; duration <= 4.5 hr
            Provider->>MP: appendField(model_id, file_format) + appendFile(file) + optional fields
            MP-->>Provider: (body, contentType)
            Provider->>URLSession: data(for:) POST https://api.elevenlabs.io/v1/speech-to-text\nxi-api-key header
            URLSession-->>Provider: (Data, HTTPURLResponse 200)
            Provider->>Provider: decode ElevenLabsWire.TranscriptionResponse
            Provider-->>Mgr: text: String
            Mgr->>Sidecar: write segmentAppended / segmentUpdated
        end
    end
```

#### §07D-5.3 Error path: ElevenLabs HTTP 429 → backoff → success

```mermaid
sequenceDiagram
    autonumber
    participant Mgr as TranscriptionManager
    participant Provider as ElevenLabsTranscriptionProvider
    participant Retry as performRequestWithRetries
    participant URLSession
    participant Clock as TranscriptionClock

    Mgr->>Provider: transcribe(samples:source:options:)
    Provider->>Retry: try POST (attempt 1)
    Retry->>URLSession: data(for:)
    URLSession-->>Retry: HTTPURLResponse 429 (rate_limit_exceeded)
    Retry->>Retry: detail.status == "rate_limit_exceeded" → retry
    Retry->>Clock: sleep(1.0 ± 20 % jitter)

    Retry->>URLSession: data(for:) (attempt 2)
    URLSession-->>Retry: HTTPURLResponse 429 (rate_limit_exceeded)
    Retry->>Clock: sleep(2.0 ± 20 % jitter)

    Retry->>URLSession: data(for:) (attempt 3)
    URLSession-->>Retry: HTTPURLResponse 200
    Retry->>Provider: decode response
    Provider-->>Mgr: text: String

    Note over Provider: If all 3 attempts return 429:\n  throw ElevenLabsSTTError.rateLimited(nil)\n  → MacrecError.transcriptionProviderUnavailable(reason: "ElevenLabs rate-limited; backoff exhausted")\n  → exit 70.
    Note over Provider: 429 with detail.status == "concurrent_limit_exceeded" is NOT retried —\n  surfaced immediately as ElevenLabsSTTError.concurrentLimitExceeded.
```

### §07D-6 Error-handling strategy

#### §07D-6.1 Azure OpenAI

| HTTP / underlying | Typed `AzureOpenAISTTError` | Retry? | `MacrecError` (exit) | User-visible message format |
|---|---|---|---|---|
| 400 (`invalid_request_error`, `invalid_value`) | `.invalidRequest(message)` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Azure rejected request: <message>` |
| 400/413 (`file_too_large`) | `.fileTooLarge(byteCount)` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Audio chunk exceeds Azure's 25 MB limit (chunk longer than ~25 min)` |
| 400/415 (`unsupported_format`) | `.unsupportedAudioFormat(detail)` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Audio format not accepted by Azure (CAF must be converted to WAV/M4A first)` |
| 401 | `.invalidApiKey` | NO | `.transcriptionApiKeyMissing(provider: "azure")` (78) | `transcription API key missing for provider 'azure'` (existing locked string from `MacrecError.description`) |
| 403 | `.permissionDenied` | NO | `.transcriptionPermissionDenied(provider: "azure")` (77) | `transcription permission denied for provider 'azure'. Enable in System Settings → Privacy & Security → Speech Recognition, then re-run.` (existing locked string) |
| 404 (`DeploymentNotFound`) | `.deploymentNotFound(deployment)` | NO | `.transcriptionConfigConflict(reason)` (64) | `transcription configuration conflict: Azure deployment '<name>' not found in resource '<host>'` |
| 408 (timeout) | `.networkTimeout` | YES (max 3) | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Azure read timeout; transient` |
| 429 | `.rateLimited(retryAfter)` | YES (max 3, honour `Retry-After`) | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Azure rate-limited (retry after <s>s); reduce concurrency or upgrade tier` |
| 500/503 | `.serverError(statusCode)` | YES (max 2; backoff) | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Azure server error <code>; transient` |
| URLError (offline / DNS) | `.networkError(underlying)` | YES (max 1) | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Azure unreachable: <localizedDescription>` |
| Decoder | `.decodeFailure(underlying)` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Unexpected Azure response: <message>` |

#### §07D-6.2 ElevenLabs

| HTTP / underlying | Typed `ElevenLabsSTTError` | Retry? | `MacrecError` (exit) | User-visible message format |
|---|---|---|---|---|
| 400 (`audio_too_short`) | n/a — pre-flight short-circuits to `""` | n/a | n/a | (silent) |
| 400/422 (`invalid_audio_format` / `invalid_file_type`) | `.unsupportedFormat(detail)` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Audio format not accepted by ElevenLabs (CAF must be converted)` |
| 401 | `.invalidApiKey` | NO | `.transcriptionApiKeyMissing(provider: "elevenlabs")` (78) | `transcription API key missing for provider 'elevenlabs'` |
| 402 (`insufficient_credits`) | `.insufficientCredits` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: ElevenLabs account out of credits; top up at https://elevenlabs.io/app/billing` |
| 403 (`feature_not_available`) | `.planFeatureGate(feature)` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: ElevenLabs '<feature>' requires plan upgrade` |
| 413 (`request_too_large`) | `.fileTooLarge(byteCount)` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Audio chunk exceeds ElevenLabs 3 GB limit` |
| 422 (`audio_too_long`) | `.audioTooLong(durationSec)` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: Audio exceeds ElevenLabs 4.5 hr per-request limit` |
| 422 (`invalid_parameters`) | `.invalidParameter(field, message)` | NO | `.transcriptionConfigConflict(reason)` (64) | `transcription configuration conflict: ElevenLabs rejected '<field>': <message>` |
| 429 (`rate_limit_exceeded` / `system_busy`) | `.rateLimited(nil)` | YES (max 3; backoff 1/2/4 s ± 20 %) | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: ElevenLabs rate-limited; backoff exhausted` |
| 429 (`concurrent_limit_exceeded`) | `.concurrentLimitExceeded` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: ElevenLabs concurrent-request limit reached on your plan; reduce concurrency or upgrade` |
| 500/503 | `.serverError(statusCode)` | YES (max 2) | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: ElevenLabs server error <code>; transient` |
| URLError | `.networkFailure(underlying)` | YES (max 1) | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: ElevenLabs unreachable: <localizedDescription>` |
| Decoder | `.decodingFailure(underlying)` | NO | `.transcriptionProviderUnavailable` (70) | `transcription provider unavailable: ElevenLabs response malformed: <localizedDescription>` |

Both providers reuse the project's existing `MacrecError`
**description / remediation** strings verbatim — no new
`MacrecError` cases are introduced. Per the codebase scan §IP-13 the
`description` and `remediation` strings are LOCKED by design §2.1, so
new providers compose their richer "reason" text inside the
`(reason: String)` payload of the existing
`.transcriptionProviderUnavailable` / `.transcriptionConfigConflict`
cases. The output to stderr remains the locked two-line format from
`MacrecError.printToStderr()`:

```
macrec: error: transcription provider unavailable: <reason>
  Verify the provider configuration (model id, endpoint) and try again, or pass '--transcribe none' to disable live transcription.
```

This mirrors the existing `GeminiRESTTranscriptionProvider` error path
exactly (see `GeminiRESTTranscriptionProvider.swift:99-121` for the
reference pattern).

#### §07D-6.3 Retry policy summary

| Behavior | Retry? | Max attempts | Backoff |
|---|---|---|---|
| HTTP 429 with `Retry-After` (Azure) | YES | 3 | Honour `Retry-After`; otherwise exponential 1/2/4 s ± 20 %. |
| HTTP 429 without `Retry-After` (ElevenLabs `rate_limit_exceeded` / `system_busy`) | YES | 3 | Exponential 1/2/4 s ± 20 %. |
| HTTP 429 with `concurrent_limit_exceeded` (ElevenLabs) | NO | 1 | n/a — surface immediately so user knows the cap. |
| HTTP 401 / 403 | NO | 1 | Surface immediately. |
| HTTP 404 | NO | 1 | Surface immediately. |
| HTTP 413 / 415 / 422 (validation) | NO | 1 | Surface immediately. |
| HTTP 408 (timeout) | YES | 3 | Exponential 1/2/4 s ± 20 %. |
| HTTP 500 / 503 | YES | 2 | Exponential 1/2 s ± 20 %. |
| `URLError.timedOut`, `URLError.networkConnectionLost` | YES | 1 | Immediate. |

### §07D-7 Concurrency model

Both providers' `transcribe(samples:source:options:)` is `async throws`,
matching the existing `TranscriptionProvider` protocol verbatim. Per the
protocol's contract comment (`TranscriptionProvider.swift:23-24`)
implementations MUST be safe for concurrent calls — the
`TranscriptionManager` may run up to two parallel calls per source under
load.

The proposed `struct` declaration is sufficient for that contract:

- `AzureOpenAITranscriptionProvider` and `ElevenLabsTranscriptionProvider`
  hold immutable stored properties (`config`, `urlSession`, `logger`,
  `clock`). Per-call mutable state lives in the call's own stack frame
  (request, body bytes, decoded response). No shared mutable state →
  `Sendable` is satisfied without an actor.
- `URLSession.shared` is `Sendable` and supports concurrent requests.
- The retry loop awaits `clock.sleep(...)`, which is a single suspension
  point — no other concurrency primitives needed.

#### §07D-7.1 In-memory vs streaming upload

| Provider | Per-request body size (typical macrec 2.5 s chunk) | Per-request body size (per-vendor cap) | Upload mode (v1) |
|---|---|---|---|
| Azure OpenAI | ~80 KB (16 kHz mono Int16 WAV) | 25 MB hard limit (research §5) | **In-memory always.** Azure's 25 MB cap is well below any practical streaming threshold. |
| ElevenLabs | ~80 KB | 3 GB / 4.5 hr (research §9.3) | **In-memory below 50 MB; `URLRequest.httpBodyStream` above.** Threshold = `ElevenLabsTranscriptionProvider.streamingUploadThresholdBytes` (50 MB). |

The 50 MB threshold (`streamingUploadThresholdBytes`) is captured as a
public static `Int` on the provider type rather than a config var — see
§07D-13 OQ-D-3 for the rationale and the recommendation to keep it as a
hardcoded constant in v1.

The streaming-upload code path uses
`URLRequest.httpBodyStream = InputStream(data: body)` — a one-line swap,
since the multipart body is already a single `Data` blob. A future
extension that produces the body lazily as an `InputStream` (writing
parts directly to a `Pipe`) is feasible but explicitly NOT in v1 scope.

### §07D-8 Cost-summary integration

The actual `TranscriptionMetrics` struct in
`Sources/MacrecCore/Transcription/TranscriptEvent.swift:29-37` is:

```swift
public struct TranscriptionMetrics: Sendable, Codable, Equatable {
    public var chunksSent: Int = 0
    public var billableSeconds: Double = 0
    public var lastRttMs: Int = 0
    public var errorCount: Int = 0
    public var bufferOverflowCount: Int = 0

    public init() {}
}
```

There is **no** `CostSummary` struct in the codebase today, and
`TranscriptionMetrics` does NOT expose a USD cost field — it tracks
`billableSeconds` only. Plan-007's references to a
`TranscriptionManagerStats.azureCost(...)` extension point describe an
*intended* shape that does not yet exist. This design pass therefore
specifies the cost-summary surface as follows:

#### §07D-8.1 Per-engine cost computation lives on the provider

Each new provider exposes:

```swift
public func costFor(durationSeconds: Double) -> Double
```

…which uses the per-engine pricing constants in §07D-3.10. The function
is pure — no side effects, easily unit-testable, and avoids leaking
pricing constants into the manager.

#### §07D-8.2 Aggregation surface

Two non-disruptive options:

**Option 1 (recommended; minimal surface change):** Extend
`TranscriptionMetrics` with one additional field:

```swift
public struct TranscriptionMetrics: Sendable, Codable, Equatable {
    public var chunksSent: Int = 0
    public var billableSeconds: Double = 0
    public var lastRttMs: Int = 0
    public var errorCount: Int = 0
    public var bufferOverflowCount: Int = 0
    public var estimatedCostUSD: Double? = nil    // NEW — nil for on-device providers
    public init() {}
}
```

`Codable` / `Equatable` synthesis still works because the new field has
a default value (back-compat for anyone deserialising prior metrics
JSONL — old shape with no `estimatedCostUSD` key still decodes fine).
The `TranscriptionManager` accumulates `estimatedCostUSD` after each
successful provider call by adding `provider.costFor(durationSeconds:)`,
so the existing `TranscriptionMetricsView` can render the cost line
without per-provider switching.

**Option 2 (no surface change):** Compute cost lazily in the UI by
multiplying `billableSeconds` against a per-provider rate looked up by
provider id. Pushes the magic numbers into the UI layer — rejected.

**Decision:** Option 1. The single new optional field is the smallest
possible delta and keeps cost arithmetic next to the provider that
defines its pricing constants.

### §07D-9 Back-compat impact statement

#### §07D-9.1 Protocol changes — NONE

The `TranscriptionProvider` protocol (`TranscriptionProvider.swift:29-44`,
quoted in the codebase scan §IP-1 and verified by reading the actual
file in this design pass) has four members:

```swift
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedModes: Set<TranscriptionMode> { get }
    func transcribe(samples: [Float], source: SourceTag, options: TranscriptionOptions) async throws -> String
    func openStreamingSession(source: SourceTag, options: TranscriptionOptions) async throws -> any StreamingTranscriptionSession
}
```

Both new providers conform without protocol modification:

| Member | Azure provider | ElevenLabs provider |
|---|---|---|
| `id` | `"azure"` | `"elevenlabs"` |
| `displayName` | `"Azure OpenAI"` | `"ElevenLabs Scribe v2"` |
| `supportedModes` | `[.batch]` | `[.batch]` |
| `transcribe(...)` | implements (see §07D-3.8) | implements (see §07D-3.9) |
| `openStreamingSession(...)` | throws `MacrecError.transcriptionConfigConflict(reason: "Azure provider does not support streaming in v1 (gpt-4o-mini-transcribe is REST-only). Use --transcribe apple for streaming.")` | throws `MacrecError.transcriptionConfigConflict(reason: "ElevenLabs provider does not support streaming in v1 (deferred to plan-007 — scribe_v2_realtime). Use --transcribe apple for streaming.")` |

The four existing conformers (`NoOp`, `Fake`, `GeminiREST`,
`AppleSpeech`) — plus the in-tree `WhisperKit` — continue to compile
unchanged because the protocol is untouched.

#### §07D-9.2 Enum extensions

`TranscriptionProviderId` (`Sources/MacrecCore/Config/RecordingOptions.swift:74-79`)
gains three cases (one drift-fix, two new):

```swift
public enum TranscriptionProviderId: String, CaseIterable, Sendable, Codable, Equatable {
    case none
    case apple = "apple"
    case gemini
    case geminiLive = "gemini-live"
    case whisperkit                  // NEW (drift fix — see codebase scan §5)
    case azure                       // NEW
    case elevenlabs                  // NEW
}
```

The enum is `String`-backed and only consumed via the resolver's
`parseEnum(...)` helper; no exhaustive `switch` over `TranscriptionProviderId`
exists in the codebase today (verified via `grep -rn 'switch.*TranscriptionProviderId'`),
so adding cases is purely additive. The single `switch transcribeProviderEnum`
(`ConfigResolver.swift:347-354`) IS extended to handle the three new
cases (`.azure`, `.elevenlabs`, `.whisperkit`) — see §07D-2.

#### §07D-9.3 `TranscriptionOptions` — UNCHANGED

`TranscriptionOptions` (`Sources/MacrecCore/Transcription/TranscriptionOptions.swift:21-75`)
is left untouched. Azure's three extra config values (endpoint,
deployment, apiVersion) are captured by the provider at construction
time via `AzureOpenAIConfig`, NOT threaded through per-call
`TranscriptionOptions`. ElevenLabs' tuning knobs (model, language,
diarize, etc.) are likewise captured in `ElevenLabsConfig`. This
mirrors the existing `GeminiRESTTranscriptionProvider` pattern, where
`modelId` is captured in `init(...)` and stored privately rather than
being read from `TranscriptionOptions` per call.

#### §07D-9.4 `TranscriptionProviderFactoryInput` — three additive fields

```swift
public struct TranscriptionProviderFactoryInput: Sendable {
    public let providerId: String
    public let apiKey: String?
    public let modelId: String?
    public let languageHints: [String]
    public let logger: Logger
    public let keyExpiresAt: Date?
    public let azureOpenAIEndpoint: String?       // NEW
    public let azureOpenAIDeployment: String?     // NEW
    public let azureOpenAIApiVersion: String?     // NEW

    public init(
        providerId: String,
        apiKey: String?,
        modelId: String?,
        languageHints: [String] = [],
        logger: Logger,
        keyExpiresAt: Date?,
        azureOpenAIEndpoint: String? = nil,
        azureOpenAIDeployment: String? = nil,
        azureOpenAIApiVersion: String? = nil
    )
}
```

All three Azure-specific fields default to `nil`, so existing call sites
(Gemini / Apple / WhisperKit construction) compile unchanged.

#### §07D-9.5 `RecordingOptions` — five additive optional fields

Per the codebase scan §IP-7 list:

- `azureOpenAIEndpoint: String?`
- `azureOpenAIDeployment: String?`
- `azureOpenAIApiVersion: String?`
- `azureOpenAIApiKeyExpiresAt: Date?`
- `elevenLabsApiKeyExpiresAt: Date?`

All default to `nil` in `init(...)`. `withOutput(_:)` (line 306) MUST
forward each, and the existing `testWithOutputPreservesTranscriptionFields`
regression test gains one assertion per new field. ElevenLabs tuning
knobs (model, language, diarize, etc.) optionally land here too if the
user wants per-recording overrides; otherwise they remain env-var-only
and are consumed by the factory directly from `ProcessInfo` —
recommendation: keep them env-var-only in v1 to avoid
RecordingOptions-field churn and to match the
no-CLI-flag-for-Azure-deployment decision in plan-007 §A.8.

#### §07D-9.6 Switch statements that gain a new case

| File | Symbol | Why |
|---|---|---|
| `Sources/MacrecCore/Config/ConfigResolver.swift:347-354` | `let transcriptionApiKey: String? = { switch transcribeProviderEnum { … } }()` | Add `.azure → AZURE_OPENAI_API_KEY`, `.elevenlabs → ELEVENLABS_API_KEY`, `.whisperkit → nil`. |
| `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift:46-93` | `switch normalized { … }` | Add `case "azure":` and `case "elevenlabs":`; update `default` error message. |
| `Sources/macrec-ui/Views/ControlBar.swift:253-258` | API-key resolution closure | Replace hardcoded `GOOGLE_API_KEY` lookup with a `switch normalizedProvider` (Phase 0.2). |
| `Sources/macrec-ui/RootView.swift:316-323` | `private static func isCloudProvider(_:)` | Add `"azure"`, `"elevenlabs"`. |

#### §07D-9.7 SwiftUI views that gain a new case

| File | Change |
|---|---|
| `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift:72-77` | Two new `Text(...).tag(...)` rows for Azure + ElevenLabs (Phase C.1). |
| `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift:80-84` | `bodyText` becomes a parameterised `bodyText(for providerId:)` returning Azure-, ElevenLabs-, and Gemini-specific copy (Phase 0.3). The `userDefaultsKey` becomes `…privacy.<providerId>.acknowledged` per provider. |
| `Sources/macrec-ui/Views/Transcription/GeminiKeyField.swift` (or replacement `ProviderKeyField.swift`) | Generalised `ProviderKeyField(providerId:envVarName:displayLabel:helpURL:)` — used for Gemini (existing), Azure, and ElevenLabs (Phase 0.4). |
| `Sources/macrec-ui/RootView.swift` | Two new conditional blocks rendering `ProviderKeyField` plus Azure-specific endpoint/deployment status text (Phase C.2). |

#### §07D-9.8 Config-guide changes summary

`docs/design/configuration-guide.md` gains two new sub-sections:

- **§LT-Az** — five Azure rows (per §07D-4.1).
- **§LT-EL** — nine ElevenLabs rows (per §07D-4.2).

Both follow the existing §LT format (purpose, how to obtain, recommended
storage, options/values, default, expiration tracking).

### §07D-10 Parallel implementation units

| Unit | Phase | Files owned (no overlap) | Depends on |
|---|---|---|---|
| **U-0** Shared scaffolding | Phase 0 | `Transcription/Net/MultipartFormDataBuilder.swift`; `RecordingOptions.swift` (`.whisperkit` enum case); `ControlBar.swift` (Phase 0.2 generalised key lookup); `PrivacyDisclosureSheet.swift` (Phase 0.3 parameterised body); new `ProviderKeyField.swift`; tests for each. | nothing — first |
| **U-A** Azure provider | Phase A | `Transcription/Providers/Azure/AzureOpenAIConfig.swift`; `…/AzureOpenAIWireTypes.swift`; `…/AzureOpenAISTTError.swift`; `…/AzureOpenAITranscriptionProvider.swift`; `Tests/MacrecCoreTests/Transcription/Providers/Azure/*` (4 test files per plan-007 §E.2). | U-0 |
| **U-B** ElevenLabs provider | Phase B | `Transcription/Providers/ElevenLabs/ElevenLabsConfig.swift`; `…/ElevenLabsWireTypes.swift`; `…/ElevenLabsSTTError.swift`; `…/ElevenLabsTranscriptionProvider.swift`; `Tests/MacrecCoreTests/Transcription/Providers/ElevenLabs/*` (4 test files). | U-0 |
| **U-C** Cross-cutting wiring (factory + resolver + UI picker) | Phase C | `Transcription/Providers/TranscriptionProviderFactory.swift` (two new branches; one merge-conflict risk); `Config/ConfigResolver.swift` (Keys + switch); `Config/RecordingOptions.swift` (new fields + `withOutput(_:)`); `macrec-ui/Views/Transcription/TranscriptionPicker.swift`; `macrec-ui/RootView.swift`; `MacrecUIKit/RecordingController.swift` (line 129-131 missing-key derivation). | U-A AND U-B (needs both provider types to switch on) |
| **U-D** Docs + config-guide | Phase D | `docs/design/configuration-guide.md` (§LT-Az + §LT-EL); `docs/tools/macrec.md`; `docs/tools/macrec-ui.md`; `docs/design/project-functions.md` (FR-AZ-* + FR-EL-* rows); `Issues - Pending Items.md`. | U-A, U-B, U-C |
| **U-E** Tests + e2e scripts | Phase E | `Tests/MacrecUIKitTests/PrivacyDisclosureSheetCopyTests.swift`; `Tests/MacrecUIKitTests/ControlBarKeyResolutionTests.swift`; `Tests/MacrecUIKitTests/ProviderKeyFieldTests.swift`; `Tests/MacrecCoreTests/Config/ConfigResolverAzureElevenLabsTests.swift`; `Tests/MacrecCoreTests/Config/RecordingOptionsAzureElevenLabsTests.swift`; `Tests/MacrecCoreTests/Transcription/TranscriptionProviderFactoryAzureElevenLabsTests.swift`; `test_scripts/e2e-transcription-{azure,elevenlabs,…}.sh`. | U-D |

**Critical parallelism observation:** U-A and U-B have **zero file
overlap** — they own different folders, different test files, and
different env-var names. They can be implemented by two independent
agents in parallel as soon as U-0 completes. The single shared file
they both touch later is `TranscriptionProviderFactory.swift` in U-C,
which the wiring agent owns serially after both providers are in place.

### §07D-11 Interface contracts between parallel units

#### §07D-11.1 What U-A and U-B share

**Only two contracts** are visible across the U-A / U-B boundary:

1. **`MultipartFormDataBuilder` API** (§07D-3.1) — owned by U-0; both
   U-A and U-B depend on its public signatures verbatim. No mutation of
   the builder API is permitted by U-A or U-B; if either provider needs
   a builder feature that doesn't exist (e.g. lazy file-stream
   appending), the change is filed as a U-0 follow-up before either
   provider proceeds.
2. **`TranscriptionProvider` protocol** (`TranscriptionProvider.swift:29-44`,
   UNCHANGED) — both providers conform to the same shape, but each
   provides its own implementation. There is no shared base class.

Internal types (`AzureOpenAIWire`, `AzureOpenAIConfig`,
`AzureOpenAISTTError`, etc. and the `ElevenLabs*` analogues) are
**isolated** within their respective subfolders; neither provider
imports the other.

#### §07D-11.2 What U-C needs from U-A and U-B

The factory branch in U-C calls into each provider's public `init(...)`
and `static defaultModelId` (where applicable):

```swift
// U-C reads these public symbols from U-A:
AzureOpenAIConfig.init(endpoint:deployment:apiVersion:apiKey:apiKeyExpiresAt:)
AzureOpenAITranscriptionProvider.init(config:urlSession:logger:clock:)

// And these from U-B:
ElevenLabsConfig.init(apiKey:modelId:…)
ElevenLabsTranscriptionProvider.init(config:urlSession:logger:clock:)
```

Both signature blocks are frozen by §07D-3 of this design — U-A and U-B
implement them exactly as specified so U-C's factory branch compiles
without further coordination.

### §07D-12 Justification of technology choices

#### §07D-12.1 Why Foundation `URLSession` (no Alamofire / async-http-client)

- The project's no-new-SwiftPM-dependencies constraint (refined-request
  Constraints; plan-007 §2.4) is binding. `URLSession` ships with
  Foundation and exposes the exact surface needed: `URLSession.data(for:)`
  returns `(Data, URLResponse)` natively as `async throws`, has
  first-class `Sendable` semantics under Swift 6, and supports both
  `httpBody` (in-memory) and `httpBodyStream` (streaming uploads).
- The existing `GeminiRESTTranscriptionProvider`
  (`GeminiRESTTranscriptionProvider.swift:43-49`) already uses
  `URLSession.shared` injected via `init`. Both new providers mirror
  that pattern verbatim — design consistency over novelty.
- Alamofire would buy nothing for this surface (no auth-flow plumbing,
  no upload progress UI in v1, no caching). Adding a 5,000-line
  dependency for what amounts to a `POST` with multipart and JSON is
  unjustified.

#### §07D-12.2 Why one shared `MultipartFormDataBuilder` rather than a `BatchHTTPTranscriptionProvider` superclass

Plan-007 §3.2 already discusses this in detail; restating the design
rationale here for completeness:

- A `BatchHTTPTranscriptionProvider` superclass would force shared
  state for things that are deliberately per-provider: the URL template
  (Azure has deployment-routing + `api-version`; ElevenLabs has a fixed
  URL), the auth header (`api-key` vs `xi-api-key`), the multipart
  field set (Azure: 6 fields; ElevenLabs: 20+), the response schema
  (Azure: `{"text": "..."}` vs ElevenLabs:
  `{"text", "words[]", "language_code", …}`), the error envelope
  (Azure: dual API/APIM format; ElevenLabs: FastAPI-style
  `{detail: {status, message}}`), and the retry policy
  (Azure honours `Retry-After`; ElevenLabs doesn't expose it).
  A superclass would collapse to abstract methods on every interesting
  method — providing zero code reuse.
- A `MultipartFormDataBuilder` value type is the tightest possible
  shared abstraction: it encodes purely the RFC 7578 boundary /
  field-header / payload mechanics, reused verbatim by both providers
  and by any future REST provider. Per the project's existing pattern
  (`GeminiREST` and `AppleSpeech` are both self-contained, not
  subclassed), adding two more self-contained types is consistent and
  discoverable.

#### §07D-12.3 Why batch-only in v1

Per the investigation §Recommendation:

- Azure has no realtime variant for `gpt-4o-mini-transcribe` (the
  `/realtime` WebSocket only serves the conversational `gpt-realtime`
  family). Streaming for the chosen model is not available — it is
  not a v1 omission, it is a vendor non-feature.
- ElevenLabs DOES expose `scribe_v2_realtime` via WebSocket (GA
  2025-11-11) but its wire protocol is SDK-mediated and only partially
  documented. Adding it would double the implementation surface for
  ElevenLabs, introduce a token-fetch indirection different from the
  batch `xi-api-key` header, and risk shipping against a moving wire
  schema. plan-007 will revisit this after a release cycle of batch
  usage.
- Apple SpeechAnalyzer already covers the live-captioning niche
  on-device for free — the new providers' value-add is multilingual
  quality and enterprise data residency, both of which are batch-mode
  use-cases.

See investigation §Cost-summary and §Recommendation for the full
rationale.

#### §07D-12.4 Why no managed-identity / AAD bearer-token in v1

Per plan-007 §2.4 and Assumption A-7 in the refined request:

- The `api-key` header is the lowest-implementation-cost auth mode
  (one header, no token-refresh logic).
- Parity with `GOOGLE_API_KEY` in the existing Gemini provider keeps
  the env-var resolution chain symmetric across providers.
- Managed identity / Azure AD bearer would require the `azure-identity`
  SDK (a new dependency, ~1.5 MB binary), the `MSAL` token cache, and
  a new TCC-irrelevant but auth-state-relevant background refresh
  task. Out of scope for v1.

`gpt-4o-mini-transcribe`'s endpoint accepts the `api-key` header
identically to all other Azure OpenAI services (research §2), so the
decision is fully reversible — a future `auth-mode: aad` switch can be
added without breaking the v1 surface.

### §07D-13 Open questions / pending decisions for the user

The five questions in plan-007 §13 each receive a planner-recommended
answer there; they remain open for the user. This design pass surfaces
**three additional** questions that emerged while drafting the type
contracts:

#### §07D-13 OQ-D-1 (NEW) — Where should the streaming-upload threshold live: config var or hardcoded constant?

- **Question**: ElevenLabs accepts up to 3 GB per request, but
  in-memory body assembly past ~50 MB is wasteful. The threshold above
  which the provider switches from in-memory to
  `URLRequest.httpBodyStream` could be:
  (a) a hardcoded `public static let streamingUploadThresholdBytes` on
  `ElevenLabsTranscriptionProvider`,
  (b) a documented env var (e.g. `ELEVENLABS_STREAMING_THRESHOLD_BYTES`).
- **Planner's recommendation**: **(a) hardcoded constant.** Rationale:
  - The macrec recording cadence (2.5 s flush) produces ~80 KB chunks;
    the threshold matters only for users who post-process long files
    via a hypothetical `macrec transcribe-file` subcommand — which is
    out of scope for v1.
  - Exposing the threshold as an env var creates a tunable that 99 %
    of users will never touch and that has no good "you're choosing
    wrong" feedback path.
  - The constant is `public static`, so anyone who really needs to
    override it for a downstream binary can do so with a one-line patch.
- **If the user wants (b)**: add `ELEVENLABS_STREAMING_THRESHOLD_BYTES`
  to `ConfigResolver.Keys` and `ElevenLabsConfig`; resolve through the
  factory; update §07D-4.2 to add a tenth row.

#### §07D-13 OQ-D-2 (carried-forward; sharpens plan-007 Az-1) — `AZURE_OPENAI_API_VERSION` resolution layer

- Plan-007 §13 Az-1 asks whether the api-version is required-config or
  config-guide-documented starter. This design adopts the
  config-guide-documented-starter approach (the value lives in code as
  the factory's `?? "2025-03-01-preview"` fallback, and the
  configuration guide documents the value as a "known-good pin" rather
  than a silent default).
- **Sharpening question**: should the factory log the resolved
  api-version at `info` level on every provider build, so the user
  always sees which value is in play? Recommendation: **yes** — single
  log line `Azure provider built: api-version=<value> deployment=<name>`
  removes any ambiguity about which version is wire-active.

#### §07D-13 OQ-D-3 (NEW) — `TranscriptionMetrics.estimatedCostUSD` field — additive struct change OR separate `TranscriptionCostSummary` struct?

- **Question**: §07D-8 proposes adding `estimatedCostUSD: Double?` to
  `TranscriptionMetrics`. An alternative is to introduce a new
  `TranscriptionCostSummary` struct emitted once at session end via a
  new event variant on `TranscriptionEvent`.
- **Planner's recommendation**: **add the optional field to
  `TranscriptionMetrics`.** Rationale:
  - Single field; back-compat preserved by default value.
  - The existing `TranscriptionMetricsView` already polls
    `TranscriptionMetrics` — surfacing cost is one extra `Text(...)`.
  - A separate end-of-session `TranscriptionCostSummary` event would
    require new sidecar handling for a value that's already
    derivable from `billableSeconds × per-engine rate`.
- **If the user prefers a dedicated struct**: introduce
  `public struct TranscriptionCostSummary: Sendable, Codable, Equatable`
  with `provider: String`, `billableSeconds: Double`, `usdCost: Double`,
  `currency: String`; emit one per session via a new
  `TranscriptionEvent.costSummary(...)` case. Higher surface, lower
  ambiguity.

#### Carried forward (plan-007 §13)

- **Az-1** — see OQ-D-2 above.
- **EL-1** — SRT/VTT generation: API `additional_formats` vs
  post-process from `words[]` (planner: post-process).
- **EL-2** — `entity_detection` default ON or OFF (planner: OFF).
- **EL-3** — `pcm_s16le_16` always-on or runtime-checked (planner:
  always-on with a static contract comment).
- **UI-1** — picker layout flat vs "Cloud" submenu (planner: flat).

### §07D-14 References

- Plan that this design complements: `docs/design/plan-007-additional-stt-engines.md`
- Refined request: `docs/design/refined-request-additional-stt-engines.md`
- Codebase scan: `docs/reference/codebase-scan-additional-stt-engines.md`
- Investigation: `docs/reference/investigation-additional-stt-engines.md`
- Wire-schema research:
  `docs/research/azure-openai-gpt-4o-mini-transcribe-wire-schema.md`,
  `docs/research/elevenlabs-stt-wire-schema.md`
- Existing baseline plans (contracts referenced verbatim):
  `docs/design/plan-004-rest-batch-transcription.md`,
  `docs/design/plan-005-apple-speech-streaming.md`
- Existing project rules: `CLAUDE.md` (Approved Exceptions 001 + 002)
- Source files inspected for verification:
  `Sources/MacrecCore/Transcription/TranscriptionProvider.swift`,
  `…/StreamingTranscriptionSession.swift`,
  `…/TranscriptionOptions.swift`,
  `…/AudioWAVEncoder.swift`,
  `…/Providers/GeminiRESTTranscriptionProvider.swift`,
  `…/Providers/TranscriptionProviderFactory.swift`,
  `…/TranscriptEvent.swift` (TranscriptionMetrics),
  `Sources/MacrecCore/Errors/MacrecError.swift`,
  `Sources/MacrecCore/Config/RecordingOptions.swift`,
  `Sources/MacrecCore/Config/ConfigResolver.swift`,
  `Sources/macrec-ui/Views/ControlBar.swift`,
  `Sources/macrec-ui/RootView.swift`.

---

## Plan-007 Design — Phase A2 Addendum: Azure OpenAI Realtime Streaming

> **Added 2026-04-29.** This addendum extends §07D (Plan-007 Design)
> with the technical design for **Phase A2 — Azure OpenAI Realtime
> Streaming Transcription** (`intent=transcription` over WebSocket).
> §07D-1..§07D-14 cover Phase A1 (batch REST) and Phase B (ElevenLabs
> batch); the realtime path lives here (§A2D-1..§A2D-12) so the design
> is self-contained per phase.
>
> **Mandatory inputs read for this addendum**:
> - `docs/research/azure-openai-realtime-transcription-wire-schema.md`
>   (primary; supersedes the §14 stub in the batch wire-schema file)
> - `docs/design/plan-007-additional-stt-engines.md` §A2.1..§A2.11
> - `docs/design/plan-005-apple-speech-streaming.md` (the in-tree
>   streaming-provider pattern this phase mirrors)
> - `Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift`
>   (the protocol contract and event shape — verified)
> - `Sources/MacrecCore/Transcription/TranscriptionProvider.swift`
>   (the parent protocol — verified unchanged from plan-005)
>
> **Approved exceptions honoured**: Exception 001 (Swift), Exception 002
> (macOS 26 — Phase A2 uses Foundation `URLSessionWebSocketTask` and
> `AVAudioConverter`, both available on macOS 13+ but actually used
> with macOS 26 Swift 6 concurrency idioms).
>
> **Project rules honoured**: no fallback values for required
> configuration; no new SwiftPM dependencies (Foundation +
> `AVFoundation` only); vendor-canonical env-var names; expiration
> companion env vars per CLAUDE.md `<configuration-guide>`.

### §A2D-1 Architecture overview

#### §A2D-1.1 The realtime provider as a peer of the batch provider

The new realtime provider lives at the same level as the existing
batch provider, sharing the same Azure config envelope (endpoint,
deployment, api-key, api-version) but using a completely separate
session-managed lifecycle on a `URLSessionWebSocketTask` instead of a
one-shot `URLSession.data(for:)` POST. The two providers register two
distinct ids in `TranscriptionProviderFactory`:

```
                          ┌──────────────────────────────────┐
                          │ TranscriptionProviderFactory     │
                          │  switch normalized {             │
                          │    case "azure":                 │  Phase A1
                          │       AzureOpenAITranscriptionProvider
                          │    case "azure-openai-realtime": │  Phase A2  (NEW)
                          │       AzureOpenAIRealtimeTranscriptionProvider
                          │  }                               │
                          └────────────────┬─────────────────┘
                                           │
                                           ▼
                  ┌────────────────────────────────────────────┐
                  │ TranscriptionProvider (unchanged)          │
                  │   .id "azure"                / "azure-openai-realtime"│
                  │   .supportedModes = [.batch] / [.streaming]│
                  └─────────┬──────────────────────────────────┘
                            │
       ┌────────────────────┼─────────────────────────────────┐
       ▼                                                      ▼
┌─────────────────────────┐                ┌─────────────────────────────────────┐
│ AzureOpenAITranscription│                │ AzureOpenAIRealtimeTranscription    │
│ Provider (A1)           │                │ Provider (A2 — final class, Sendable)│
│ ────────────────────── │                │ ────────────────────────────────── │
│ AzureOpenAIConfig       │                │ AzureOpenAIRealtimeConfig           │
│   endpoint, deployment, │                │   (same shared 5 fields)            │
│   apiVersion, apiKey,   │                │   + vadThreshold, vadPrefixMS,      │
│   apiKeyExpiresAt       │                │     vadSilenceMS, noiseReduction,   │
│                         │                │     includeLogprobs,                │
│                         │                │     deploymentInUrl                 │
│ MultipartFormDataBuilder│                │                                     │
│ AudioWAVEncoder         │                │ AudioResampler16to24                │
│ URLSession.data(for:)   │                │ AudioRingBuffer<Int16> (5 s ring)   │
│ AzureOpenAIWireTypes    │                │ RealtimeWireTypes (Codable enum)    │
│ JSONDecoder ──▶ String  │                │ AzureOpenAIRealtimeSession (actor)  │
│                         │                │   URLSessionWebSocketTask           │
│                         │                │   AsyncStream<StreamingTranscription│
│                         │                │     Event> events                   │
│ supportedModes: [.batch]│                │ supportedModes: [.streaming]        │
└─────────────────────────┘                └─────────────────────────────────────┘
       │                                                    │
       │  String                                            │  AsyncStream
       ▼                                                    ▼
       (TranscriptionManager batch path)         (TranscriptionManager streaming path)
```

The `AudioResampler16to24` and `AudioRingBuffer` collaborate with the
existing `[Float]` audio source. The flow per audio chunk:

```
SCKitSystemAudioSource / AVMicrophoneSource
  │  16 kHz Float32 chunk (2.5 s == 40,000 samples)
  ▼
SourceBuffer  (existing — bounded queue)
  │
  ▼
AzureOpenAIRealtimeSession.ingest(_:)        ──┐
  │                                            │ actor-isolated
  │  AudioResampler16to24.resample(_:)         │
  │    Int16 LE @ 24 kHz (1.5× sample count)   │
  │                                            │
  │  AudioRingBuffer<Int16>.append(_:)         │   ◄── for replay
  │                                            │
  │  Base64-encode → JSON envelope             │
  │  task.send(.string(json))                  │
  ▼                                          ──┘
URLSessionWebSocketTask
  │
  ▼  (network)
Azure /openai/realtime?intent=transcription
  │
  ▼  (network)
URLSessionWebSocketTask.receive() loop  ─────┐
  │                                          │ actor-isolated
  │  RealtimeWireTypes.ServerEvent decode    │
  │  switch on event.type                    │
  │    .delta ──▶ continuation.yield(.partial)│
  │    .completed ──▶ continuation.yield(.final)│
  │    .failed ──▶ continuation.yield(.error)│
  │  on close 1006 ──▶ attemptReconnect()    │
  ▼                                          ──┘
events: AsyncStream<StreamingTranscriptionEvent>
  │
  ▼
TranscriptionManager (existing — streaming path)
  │
  ▼
TranscriptSidecarWriter (.live)  +  LiveTranscriptPanel (UI)
```

### §A2D-2 Module / file map

All new files under `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/`
(sibling of `Sources/MacrecCore/Transcription/Providers/Azure/` from
Phase A1 / §07D-2). Same paths as plan-007 §A2.3:

| File | Public types exported | One-sentence purpose |
|---|---|---|
| `Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeTranscriptionProvider.swift` | `public final class AzureOpenAIRealtimeTranscriptionProvider: TranscriptionProvider, Sendable` | The `TranscriptionProvider` conformer for the realtime path; opens sessions via `openStreamingSession(...)` and throws on `transcribe(...)`. |
| `Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift` | `public actor AzureOpenAIRealtimeSession: StreamingTranscriptionSession` | Owns the `URLSessionWebSocketTask`, the receive loop `Task`, the resampler, the ring buffer, the reconnect timer, and the events `AsyncStream` continuation. |
| `Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeConfig.swift` | `public struct AzureOpenAIRealtimeConfig: Sendable, Equatable` | Resolved configuration captured at provider construction; validates URL shape and VAD ranges; throws `MacrecError.transcriptionConfigConflict` on validation failure. |
| `Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeError.swift` | `public enum AzureOpenAIRealtimeError: Error, LocalizedError, Sendable` | Realtime-specific typed errors; supplements `AzureOpenAISTTError` from Phase A1 with WS-lifecycle and protocol cases. |
| `Transcription/Providers/Azure/Realtime/RealtimeWireTypes.swift` | `public enum RealtimeWireTypes` (namespace) — `TranscriptionSessionUpdate`, `SessionConfig`, `InputAudioBufferAppend`, `RealtimeServerEvent`, plus payload structs | All Codable client + server event models. **Crucially, `InputAudioTranscriptionConfig` has NO `model` property** to prevent the RT-1 Azure bug. |
| `Transcription/Providers/Azure/Realtime/AudioResampler16to24.swift` | `internal struct AudioResampler16to24: Sendable` | `AVAudioConverter`-backed 16 kHz Float → 24 kHz Int16 LE; high-quality mode pinned. |
| `Transcription/Providers/Azure/Realtime/AudioRingBuffer.swift` | `internal struct AudioRingBuffer<Sample: Sendable>: Sendable` | Generic fixed-capacity FIFO; used as `AudioRingBuffer<Int16>` (capacity 120,000 = 5 s @ 24 kHz) in the session. |

**Factory-registration changes** (extend §07D-2's table):

| File | Symbol | Change |
|---|---|---|
| `Transcription/Providers/TranscriptionProviderFactory.swift` | `TranscriptionProviderFactoryInput` | Add 6 new optional fields for the realtime VAD config (`azureOpenAIRealtimeVADThreshold: Double?`, `…VADPrefixPaddingMS: Int?`, `…VADSilenceMS: Int?`, `…NoiseReduction: String?`, `…IncludeLogprobs: Bool?`, `…DeploymentInUrl: Bool?`). |
| `Transcription/Providers/TranscriptionProviderFactory.swift` | `TranscriptionProviderFactory.build(_:)` | Add `case "azure-openai-realtime":` branch before `default`. |
| `Config/RecordingOptions.swift` | `enum TranscriptionProviderId` | Add `case azureOpenAIRealtime = "azure-openai-realtime"`. |
| `Config/RecordingOptions.swift` | `struct RecordingOptions` | Add 6 new optional stored properties (mirror the factory input fields). |
| `Config/ConfigResolver.swift` | `enum Keys` | Add `azureOpenAIRealtimeVADThreshold`, `…VADPrefixPaddingMS`, `…VADSilenceMS`, `…NoiseReduction`, `…IncludeLogprobs`, `…DeploymentInUrl`. |
| `Config/ConfigResolver.swift` | `resolve(cliOverrides:)` switch | Extend the existing Azure branch to also resolve the realtime keys when `provider == .azureOpenAIRealtime`. |

### §A2D-3 Type contracts (Swift signatures)

All signatures below are **verified** against
`Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift`
and `Sources/MacrecCore/Transcription/TranscriptionProvider.swift`
(both unchanged from plan-005).

#### §A2D-3.1 `AzureOpenAIRealtimeTranscriptionProvider`

```swift
import Foundation

public final class AzureOpenAIRealtimeTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    public let id: String = "azure-openai-realtime"
    public let displayName: String = "Azure OpenAI Realtime"
    public let supportedModes: Set<TranscriptionMode> = [.streaming]

    private let config: AzureOpenAIRealtimeConfig
    private let urlSession: URLSession
    private let logger = LoggerFactory.make("macrec.transcription.azure-realtime")

    public init(config: AzureOpenAIRealtimeConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    /// Realtime provider does not support batch — explicit throw.
    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        throw MacrecError.transcriptionConfigConflict(
            reason: "Azure realtime provider does not support batch mode; use --transcribe azure for batch."
        )
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        return AzureOpenAIRealtimeSession(
            config: config,
            source: source,
            options: options,
            urlSession: urlSession
        )
    }
}
```

#### §A2D-3.2 `AzureOpenAIRealtimeSession`

```swift
import AVFoundation
import Foundation

public actor AzureOpenAIRealtimeSession: StreamingTranscriptionSession {
    // MARK: - Public StreamingTranscriptionSession surface
    public nonisolated let events: AsyncStream<StreamingTranscriptionEvent>

    public func ingest(_ samples: [Float]) async {
        // 1. Resample 16→24 kHz Int16
        let pcm16 = await resampler.resample(samples)
        // 2. Append to ring buffer for replay
        ringBuffer.append(contentsOf: pcm16)
        // 3. Send 100 ms chunks to WS
        try? await sendAudioChunks(pcm16)
    }

    public func finish() async {
        userInitiatedClose = true
        await closeWebSocket(code: .normalClosure, reason: nil)
        eventsContinuation.finish()
    }

    // MARK: - Internal state
    private let config: AzureOpenAIRealtimeConfig
    private let source: SourceTag
    private let options: TranscriptionOptions
    private let urlSession: URLSession

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var preemptiveReconnectTask: Task<Void, Never>?

    private let resampler: AudioResampler16to24
    private var ringBuffer: AudioRingBuffer<Int16>            // capacity 120_000 (5 s @ 24 kHz)
    private let eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation

    private var sessionStart: Date?
    private var audioSamplesCommitted: Int = 0
    private var lastFinalRange: ClosedRange<Date>?            // for RT-RISK-3 dedupe
    private var userInitiatedClose: Bool = false
    private var reconnectAttempts: Int = 0
    private var metrics = StreamingProviderMetrics()

    // MARK: - Init
    public init(
        config: AzureOpenAIRealtimeConfig,
        source: SourceTag,
        options: TranscriptionOptions,
        urlSession: URLSession
    ) {
        self.config = config
        self.source = source
        self.options = options
        self.urlSession = urlSession

        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventsContinuation = continuation

        self.resampler = AudioResampler16to24()
        self.ringBuffer = AudioRingBuffer<Int16>(capacity: 120_000)

        Task { await self.openWebSocket() }
    }

    // MARK: - Lifecycle (private helpers)
    private func openWebSocket() async { /* see §A2D-6 sequence */ }
    private func handleClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) async { /* see §A2D-6 */ }
    private func attemptReconnectWithReplay() async { /* see §A2D-6 */ }
    private func sendAudioChunks(_ samples: [Int16]) async throws { /* 100 ms chunks */ }
    private func emit(_ event: StreamingTranscriptionEvent) { eventsContinuation.yield(event) }
    private func closeWebSocket(code: URLSessionWebSocketTask.CloseCode, reason: Data?) async { /* … */ }
}
```

#### §A2D-3.3 `AzureOpenAIRealtimeConfig`

```swift
public struct AzureOpenAIRealtimeConfig: Sendable, Equatable {
    public let endpoint: URL                  // https://{resource}.openai.azure.com (no trailing slash)
    public let deployment: String             // user-chosen deployment name
    public let apiVersion: String             // "2025-04-01-preview"
    public let apiKey: String                 // resolved from AZURE_OPENAI_API_KEY
    public let apiKeyExpiresAt: Date?

    public let vadThreshold: Double           // 0.0..1.0, default 0.5
    public let vadPrefixPaddingMS: Int        // ≥ 0, default 300
    public let vadSilenceMS: Int              // ≥ 0, default 200
    public let noiseReduction: NoiseReduction // .nearField | .farField | .none
    public let includeLogprobs: Bool          // default false
    public let deploymentInUrl: Bool          // default false (per OQ-A2-2)

    public enum NoiseReduction: String, Sendable, Equatable {
        case nearField = "near_field"
        case farField  = "far_field"
        case none      = "none"
    }

    public init(...) throws {
        // Validates endpoint scheme == "https", deployment non-empty,
        // vadThreshold in 0.0..1.0, vadPrefixPaddingMS ≥ 0,
        // vadSilenceMS ≥ 0, noiseReduction enum.
        // Throws MacrecError.transcriptionConfigConflict on any failure.
    }

    /// Build the wss:// URL for the WS upgrade.
    public func buildWebSocketURL() -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.path = "/openai/realtime"
        var queryItems = [
            URLQueryItem(name: "api-version", value: apiVersion),
            URLQueryItem(name: "intent", value: "transcription"),
        ]
        if deploymentInUrl {
            queryItems.append(URLQueryItem(name: "deployment", value: deployment))
        }
        components.queryItems = queryItems
        return components.url!
    }
}
```

#### §A2D-3.4 `AzureOpenAIRealtimeError`

```swift
public enum AzureOpenAIRealtimeError: Error, LocalizedError, Sendable {
    // WS lifecycle
    case connectionFailed(underlying: Error)
    case unauthorizedUpgrade
    case policyViolation
    case abnormalClose(code: Int)
    case sessionExpired

    // Session-level protocol (received as `error` events)
    case sessionRejected(type: String, message: String)
    case rateLimited(resetSeconds: Double?)
    case internalServerError(message: String)
    case modelFieldRejected             // RT-1: model field was sent (regression-only)

    // Item-level (non-fatal)
    case itemTranscriptionFailed(itemId: String, message: String)

    // Audio / format
    case audioFormatMismatch(reason: String)

    // Reconnect
    case reconnectExhausted(attempts: Int)

    // Catch-all
    case unexpectedEvent(name: String)

    public var errorDescription: String? { /* localized strings per case */ }
}
```

#### §A2D-3.5 `AudioResampler16to24`

```swift
import AVFoundation

internal struct AudioResampler16to24: Sendable {
    private let converter: AVAudioConverter

    init() {
        let inputFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let outputFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
        self.converter = AVAudioConverter(from: inputFmt, to: outputFmt)!
        // High-quality mode (RT-RISK-2):
        self.converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter.primeMethod = .normal
    }

    /// Resample 16 kHz Float → 24 kHz Int16 LE. Output sample count is
    /// `floor(inputCount * 1.5)` ± 1.
    func resample(_ floats: [Float]) -> [Int16] {
        // … AVAudioConverter pull-style call returning [Int16] …
    }
}
```

#### §A2D-3.6 `AudioRingBuffer`

```swift
internal struct AudioRingBuffer<Sample: Sendable>: Sendable {
    private var buffer: [Sample]
    private let capacity: Int
    private var head: Int = 0
    private var count: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil as Sample? as! Sample, count: capacity)  // pseudo
    }

    mutating func append(contentsOf samples: [Sample]) { /* circular write */ }

    /// Returns the current contents in chronological order (oldest first).
    func snapshot() -> [Sample] { /* copy out in chronological order */ }

    var currentCount: Int { count }
}
```

### §A2D-4 RealtimeWireTypes module

The `RealtimeWireTypes` namespace contains a Codable model for every
client and server event documented in the realtime research §3-§6. The
critical rule: **`InputAudioTranscriptionConfig` has NO `model`
property**, by design, to prevent the RT-1 Azure server bug.

```swift
public enum RealtimeWireTypes {

    // ============================================================
    // CLIENT → SERVER events
    // ============================================================

    public struct TranscriptionSessionUpdate: Encodable, Sendable {
        public let type: String = "transcription_session.update"
        public let session: SessionConfig
        public init(session: SessionConfig) { self.session = session }
    }

    public struct SessionConfig: Encodable, Sendable {
        public let inputAudioFormat: String                          // "pcm16"
        public let inputAudioTranscription: InputAudioTranscriptionConfig
        public let turnDetection: TurnDetectionConfig?
        public let inputAudioNoiseReduction: NoiseReductionConfig?
        public let include: [String]?
        // NOTE: NO `model` field by design — RT-1 Azure bug prevention.

        public init(
            inputAudioFormat: String = "pcm16",
            inputAudioTranscription: InputAudioTranscriptionConfig,
            turnDetection: TurnDetectionConfig? = nil,
            inputAudioNoiseReduction: NoiseReductionConfig? = nil,
            include: [String]? = nil
        ) {
            self.inputAudioFormat = inputAudioFormat
            self.inputAudioTranscription = inputAudioTranscription
            self.turnDetection = turnDetection
            self.inputAudioNoiseReduction = inputAudioNoiseReduction
            self.include = include
        }

        public enum CodingKeys: String, CodingKey {
            case inputAudioFormat = "input_audio_format"
            case inputAudioTranscription = "input_audio_transcription"
            case turnDetection = "turn_detection"
            case inputAudioNoiseReduction = "input_audio_noise_reduction"
            case include
        }
    }

    public struct InputAudioTranscriptionConfig: Encodable, Sendable {
        public let language: String?
        public let prompt: String?
        // CRITICAL: NO `model` field. Including it triggers RT-1 on Azure.
    }

    public struct TurnDetectionConfig: Encodable, Sendable {
        public let type: String                       // "server_vad"
        public let threshold: Double
        public let prefixPaddingMS: Int
        public let silenceDurationMS: Int
        public let createResponse: Bool

        public enum CodingKeys: String, CodingKey {
            case type, threshold
            case prefixPaddingMS    = "prefix_padding_ms"
            case silenceDurationMS  = "silence_duration_ms"
            case createResponse     = "create_response"
        }
    }

    public struct NoiseReductionConfig: Encodable, Sendable {
        public let type: String                       // "near_field" | "far_field"
    }

    public struct InputAudioBufferAppend: Encodable, Sendable {
        public let type: String = "input_audio_buffer.append"
        public let audio: String                      // base64-encoded PCM16 LE 24 kHz mono
    }

    public struct InputAudioBufferCommit: Encodable, Sendable {
        public let type: String = "input_audio_buffer.commit"
    }

    public struct InputAudioBufferClear: Encodable, Sendable {
        public let type: String = "input_audio_buffer.clear"
    }

    // ============================================================
    // SERVER → CLIENT events (decoded from JSON text frames)
    // ============================================================

    public enum RealtimeServerEvent: Decodable, Sendable {
        case sessionCreated(eventId: String, sessionId: String)
        case sessionUpdated(eventId: String, sessionId: String)
        case transcriptionSessionCreated(eventId: String, sessionId: String)   // alias seen on some envs
        case transcriptionSessionUpdated(eventId: String, sessionId: String)
        case inputAudioBufferSpeechStarted(audioStartMs: Int, itemId: String)
        case inputAudioBufferSpeechStopped(audioEndMs: Int, itemId: String)
        case inputAudioBufferCommitted(previousItemId: String?, itemId: String)
        case inputAudioBufferCleared
        case conversationItemCreated(itemId: String)
        case conversationItemInputAudioTranscriptionDelta(
            eventId: String,
            itemId: String,
            contentIndex: Int,
            delta: String
        )
        case conversationItemInputAudioTranscriptionCompleted(
            eventId: String,
            itemId: String,
            contentIndex: Int,
            transcript: String,
            usage: UsageInfo?
        )
        case conversationItemInputAudioTranscriptionFailed(
            eventId: String,
            itemId: String,
            error: AzureErrorPayload
        )
        case error(eventId: String, error: AzureErrorPayload)
        case rateLimitsUpdated(eventId: String, rateLimits: [RateLimitInfo])
        case unknown(type: String)

        private enum CodingKeys: String, CodingKey { case type }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type_ = try container.decode(String.self, forKey: .type)
            switch type_ {
            case "session.created":
                let p = try SessionPayload(from: decoder)
                self = .sessionCreated(eventId: p.eventId, sessionId: p.session.id)
            case "session.updated":
                let p = try SessionPayload(from: decoder)
                self = .sessionUpdated(eventId: p.eventId, sessionId: p.session.id)
            case "transcription_session.created":
                let p = try SessionPayload(from: decoder)
                self = .transcriptionSessionCreated(eventId: p.eventId, sessionId: p.session.id)
            case "transcription_session.updated":
                let p = try SessionPayload(from: decoder)
                self = .transcriptionSessionUpdated(eventId: p.eventId, sessionId: p.session.id)
            case "input_audio_buffer.speech_started":
                let p = try SpeechStartedPayload(from: decoder)
                self = .inputAudioBufferSpeechStarted(audioStartMs: p.audioStartMs, itemId: p.itemId)
            case "input_audio_buffer.speech_stopped":
                let p = try SpeechStoppedPayload(from: decoder)
                self = .inputAudioBufferSpeechStopped(audioEndMs: p.audioEndMs, itemId: p.itemId)
            case "input_audio_buffer.committed":
                let p = try CommittedPayload(from: decoder)
                self = .inputAudioBufferCommitted(previousItemId: p.previousItemId, itemId: p.itemId)
            case "input_audio_buffer.cleared":
                self = .inputAudioBufferCleared
            case "conversation.item.created":
                let p = try ItemCreatedPayload(from: decoder)
                self = .conversationItemCreated(itemId: p.item.id)
            case "conversation.item.input_audio_transcription.delta":
                let p = try DeltaPayload(from: decoder)
                self = .conversationItemInputAudioTranscriptionDelta(
                    eventId: p.eventId, itemId: p.itemId,
                    contentIndex: p.contentIndex, delta: p.delta
                )
            case "conversation.item.input_audio_transcription.completed":
                let p = try CompletedPayload(from: decoder)
                self = .conversationItemInputAudioTranscriptionCompleted(
                    eventId: p.eventId, itemId: p.itemId,
                    contentIndex: p.contentIndex,
                    transcript: p.transcript, usage: p.usage
                )
            case "conversation.item.input_audio_transcription.failed":
                let p = try FailedPayload(from: decoder)
                self = .conversationItemInputAudioTranscriptionFailed(
                    eventId: p.eventId, itemId: p.itemId, error: p.error
                )
            case "error":
                let p = try ErrorEventPayload(from: decoder)
                self = .error(eventId: p.eventId, error: p.error)
            case "rate_limits.updated":
                let p = try RateLimitsPayload(from: decoder)
                self = .rateLimitsUpdated(eventId: p.eventId, rateLimits: p.rateLimits)
            default:
                self = .unknown(type: type_)
            }
        }
    }

    // Payload structs (each matching the JSON shape of one event):
    public struct AzureErrorPayload: Decodable, Sendable {
        public let type: String?
        public let code: String?
        public let message: String
        public let param: String?
    }

    public struct UsageInfo: Decodable, Sendable {
        public let totalTokens: Int?
        public let inputTokens: Int?
        public let outputTokens: Int?
        public enum CodingKeys: String, CodingKey {
            case totalTokens  = "total_tokens"
            case inputTokens  = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    public struct RateLimitInfo: Decodable, Sendable {
        public let name: String
        public let limit: Int
        public let remaining: Int
        public let resetSeconds: Double
        public enum CodingKeys: String, CodingKey {
            case name, limit, remaining
            case resetSeconds = "reset_seconds"
        }
    }

    // (SessionPayload / SpeechStartedPayload / SpeechStoppedPayload /
    //  CommittedPayload / ItemCreatedPayload / DeltaPayload /
    //  CompletedPayload / FailedPayload / ErrorEventPayload /
    //  RateLimitsPayload omitted for brevity — each is a flat
    //  Decodable struct mirroring the §5 server-event JSON shapes.)
}
```

### §A2D-5 State machine

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> connecting: openWebSocket()
    connecting --> ready: 101 Upgrade + session.created
    connecting --> closed: connection failed
    ready --> buffering: transcription_session.update sent + session.updated received
    buffering --> buffering: ingest(samples) → input_audio_buffer.append
    buffering --> buffering: server delta → emit(.partial)
    buffering --> committed: input_audio_buffer.speech_stopped
    committed --> completed: conversation.item.input_audio_transcription.completed → emit(.final)
    completed --> buffering: next utterance
    buffering --> reconnecting: WS close 1006 / 1001 / 1011
    committed --> reconnecting: WS close 1006 / 1001 / 1011
    completed --> reconnecting: WS close 1006 / 1001 / 1011
    reconnecting --> ready: reconnect successful (≤ 3 attempts)
    reconnecting --> closed: reconnect attempts exhausted (.reconnectExhausted)
    buffering --> reconnecting: 58-min pre-emptive timer fires (after next .committed)
    buffering --> closed: WS close 1008 (.policyViolation)
    buffering --> closed: finish() (close 1000)
    closed --> [*]
```

### §A2D-6 Reconnect-with-replay flow

```mermaid
sequenceDiagram
    participant App as macrec / UI
    participant Sess as AzureOpenAIRealtimeSession (actor)
    participant Ring as AudioRingBuffer<Int16>
    participant Resamp as AudioResampler16to24
    participant WS as URLSessionWebSocketTask
    participant Azure as Azure /openai/realtime

    App->>Sess: ingest([Float] @ 16 kHz)
    Sess->>Resamp: resample(samples)
    Resamp-->>Sess: [Int16] @ 24 kHz
    Sess->>Ring: append(contentsOf:)
    Sess->>WS: send(.string(JSON envelope))
    WS->>Azure: input_audio_buffer.append (text frame)

    Note over Azure,WS: ⚡ Network glitch / APIM timeout

    Azure-->>WS: WS close 1006 (no close frame)
    WS-->>Sess: handleClose(.abnormalClosure, nil)
    Sess->>Sess: emit(.error("reconnecting attempt 1/3…"))
    Sess->>Sess: attemptReconnectWithReplay()

    Sess->>WS: cancel old task
    Sess->>WS: new URLSessionWebSocketTask(with: request + api-key header)
    WS->>Azure: HTTP/1.1 101 Upgrade
    Azure-->>WS: 101 Switching Protocols
    Azure->>WS: session.created
    WS-->>Sess: RealtimeServerEvent.sessionCreated
    Sess->>WS: send(.string(transcription_session.update))
    Azure->>WS: session.updated
    WS-->>Sess: RealtimeServerEvent.sessionUpdated

    Sess->>Ring: snapshot()  (last 5 s = 120 000 Int16 samples)
    Ring-->>Sess: [Int16]
    loop 50 × 100 ms chunks of 4 800 Int16 each
        Sess->>WS: send(input_audio_buffer.append base64)
        WS->>Azure: text frame
    end
    Note over Sess: Replay complete; resume normal ingest()

    App->>Sess: ingest(more samples)
    Sess->>WS: send(...)
    Azure->>WS: speech_started → delta → committed → completed
    WS-->>Sess: RealtimeServerEvent.delta + .completed
    Sess->>Sess: dedupe by lastFinalRange (RT-RISK-3)
    Sess->>App: emit(.partial), emit(.final)
```

### §A2D-7 Pre-emptive 58-min reconnect flow

```mermaid
sequenceDiagram
    participant App as macrec
    participant Sess as AzureOpenAIRealtimeSession (actor)
    participant Timer as preemptiveReconnectTask
    participant Azure as Azure /openai/realtime

    Note over Sess: openWebSocket() at T=0
    Sess->>Sess: sessionStart = Date()
    Sess->>Timer: spawn Task { sleep 58 min; trigger reconnect }

    loop During minute 0..57
        App->>Sess: ingest(samples)
        Sess->>Azure: input_audio_buffer.append
        Azure->>Sess: delta / completed
    end

    Timer-->>Sess: 58:00 — wake up
    Note over Sess: Wait for next safe boundary
    alt currently mid-utterance (no speech_stopped yet)
        loop wait up to 90 s
            Azure->>Sess: speech_stopped + committed
        end
    end

    Sess->>Sess: emit(.metrics(reconnecting=true))
    Sess->>Sess: attemptReconnectWithReplay() (same as §A2D-6 but pre-emptive)

    Note over Sess: New session at T=58:01; sessionStart reset
    Sess->>Timer: spawn fresh 58-min Task
```

### §A2D-8 Concurrency model

#### §A2D-8.1 Events `AsyncStream`

The `AzureOpenAIRealtimeSession` exposes its events as
`nonisolated let events: AsyncStream<StreamingTranscriptionEvent>`.
This matches the existing `StreamingTranscriptionSession` protocol
contract — callers can iterate `for await event in session.events`
from any isolation context without crossing actor boundaries on each
yield. The actor's internal `eventsContinuation` is yielded to from
inside the actor, so there is no race on the continuation.

#### §A2D-8.2 WS receive loop

The session owns a long-lived `Task<Void, Never>` (`receiveLoop`) that
runs:

```swift
private func startReceiveLoop() {
    receiveLoop = Task { [weak self] in
        guard let self = self else { return }
        while !Task.isCancelled {
            do {
                let message = try await self.task!.receive()
                await self.handleIncomingMessage(message)
            } catch {
                await self.handleReceiveError(error)
                return
            }
        }
    }
}
```

`handleIncomingMessage` is `async` (actor-isolated), so the receive
loop hops onto the actor for every decoded event — no shared
mutable state outside the actor boundary.

#### §A2D-8.3 Pre-emptive reconnect timer

The 58-min timer is also a long-lived `Task<Void, Never>`
(`preemptiveReconnectTask`). It uses `Task.sleep(for:)` for the bulk
of the wait, then awaits the next `.committed` event before
triggering the reconnect.

#### §A2D-8.4 Graceful close vs aborted close

- **`finish()`** is the user-initiated close path. It sets
  `userInitiatedClose = true`, sends WS close 1000 (normal closure),
  cancels `receiveLoop` and `preemptiveReconnectTask`, finishes the
  events continuation, and returns. The events stream closes cleanly
  — caller's `for await` loop terminates.
- **WS close 1006 (abnormal)** never sets `userInitiatedClose`, so
  the close handler routes to `attemptReconnectWithReplay()` instead
  of finishing the events stream. The events stream stays open
  through the reconnect; only after reconnect attempts are exhausted
  does the session emit `.error(.reconnectExhausted)` and finish the
  stream.

### §A2D-9 Cost calculation

Per realtime research §10, billing is `$0.003 / minute` of audio
*committed* (not WS connection time). The session tracks this as
`audioSamplesCommitted` (incremented on `input_audio_buffer.committed`
events).

```swift
extension AzureOpenAIRealtimeSession {
    /// USD cost so far for this session's committed audio.
    public func currentEstimatedCostUSD() -> Double {
        let audioMinutes = Double(audioSamplesCommitted) / (24_000.0 * 60.0)
        return audioMinutes * 0.003
    }
}
```

The pricing constant lives at:
`Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift`
as a private static `let azureRealtimePerMinuteUSD: Double = 0.003`.

The cost rides on the existing `TranscriptionMetrics` channel via the
optional `estimatedCostUSD: Double?` field added in §07D-8 (shared
with Phase A1 batch and Phase B). Per metrics tick (typically once
per minute), the session computes the current cost and emits
`.metrics(StreamingProviderMetrics(... lastFinalLatencyMs ...))` plus
a separate `TranscriptionEvent.metrics(TranscriptionMetrics(... estimatedCostUSD: cost))`
on the manager channel.

### §A2D-10 Back-compat impact

#### §A2D-10.1 `TranscriptionProviderId` enum

Add one case (in addition to the three from §07D-9.1):

```swift
public enum TranscriptionProviderId: String, CaseIterable, Sendable, Codable, Equatable {
    case none
    case apple
    case gemini
    case geminiLive          = "gemini-live"
    case whisperkit                                    // §07D-9.1 drift fix
    case azure                                         // §07D-9.1 (Phase A1)
    case azureOpenAIRealtime = "azure-openai-realtime" // NEW — Phase A2
    case elevenlabs                                    // §07D-9.1 (Phase B)
}
```

#### §A2D-10.2 Switch-statement extension list (extend §07D-9.6)

Every existing exhaustive `switch` over `TranscriptionProviderId` must
gain one new branch for `.azureOpenAIRealtime`:

| Site | File | New branch |
|---|---|---|
| `ConfigResolver.resolve(...)` API-key resolution switch | `Sources/MacrecCore/Config/ConfigResolver.swift:345-354` | `case .azureOpenAIRealtime: return value(Keys.azureOpenAIApiKey)` (same as `.azure`) |
| `ConfigResolver` expiry warning | `…:357-360` | Read `AZURE_OPENAI_API_KEY_EXPIRES_AT` (same as `.azure`) |
| `TranscriptionProviderFactory.build(_:)` | `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift:46-93` | New `case "azure-openai-realtime":` branch building `AzureOpenAIRealtimeTranscriptionProvider` |
| `ControlBar.startTapped()` API-key resolution switch | `Sources/macrec-ui/Views/ControlBar.swift` (post-§07D-9.6) | `case "azure-openai-realtime": envKey = "AZURE_OPENAI_API_KEY"` |
| `RootView.isCloudProvider(_:)` | `Sources/macrec-ui/RootView.swift:316-323` | Add `"azure-openai-realtime"` to the cloud set |
| `TranscriptionPicker` provider rows | `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift:72-77` | Insert new entry "Azure OpenAI Realtime (cloud, streaming)" with tag `"azure-openai-realtime"` |
| `PrivacyDisclosureSheet.bodyText(for:)` | `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift` | New `case "azure-openai-realtime":` returning the realtime-specific copy from plan-007 §A2.9 |
| `TranscriptionProviderFactoryInput` initialiser | `…/TranscriptionProviderFactory.swift` | Six new optional realtime VAD config fields, all defaulted to nil |

#### §A2D-10.3 Privacy-disclosure copy variant

The realtime copy is materially different from the batch copy because
the data-flow is materially different (streaming vs file-upload). The
Phase 0.3 per-provider acknowledgement persistence key uses the
provider id, so the realtime variant gets its own:

```
com.local.macrec-ui.transcription.privacy.azure-openai-realtime.acknowledged
```

Selecting the realtime entry after the batch entry was already
acknowledged WILL re-show the disclosure (intentionally — see §A2.9).

#### §A2D-10.4 Picker entry

Verbatim from plan-007 §A2.9:

```swift
Text("Azure OpenAI Realtime (cloud, streaming)").tag("azure-openai-realtime")
```

The label ends in "(cloud, streaming)" to disambiguate from the batch
"Azure OpenAI (cloud, batch)" entry (which is also relabeled in the
same Phase C edit).

### §A2D-11 Open questions

The five Phase A2 open questions (`OQ-A2-1` … `OQ-A2-5`) from
plan-007 §13. The design's recommendation for each:

- **OQ-A2-1 (Resample location)**: Resample inside the provider
  (`AudioResampler16to24` in the Realtime/ folder). Cleanest
  encapsulation; ~5-10 ms latency penalty acceptable.
- **OQ-A2-2 (`&deployment=` in URL)**: Default off, behind a config
  flag (`AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL=false`). Matches the
  TechCommunity reference; user can flip if Azure starts rejecting
  the URL without it.
- **OQ-A2-3 (Deltas on or completed-only)**: Deltas on. Research
  confirms the path supports them; matches Apple/Gemini Live UX.
  Fall-back gate `AZURE_OPENAI_REALTIME_PARTIALS_ENABLED` available
  if needed.
- **OQ-A2-4 (VAD config exposure)**: Env vars with documented starter
  defaults (0.5 / 300 / 200). Lets users tune for noisy environments
  without recompiling. UI exposure deferred to plan-007.
- **OQ-A2-5 (Single PR or split)**: Default to single PR per the user's
  original request, but call out the size increase in `Issues - Pending Items.md`
  so the user can split if review burden is a concern. Natural seam
  is "A1 + B + Phase 0/C/D/E for A1+B" in PR 1, "A2 + Phase C/D/E
  delta for A2" in PR 2.

### §A2D-12 References

- Primary wire schema (Phase A2 design source-of-truth):
  `docs/research/azure-openai-realtime-transcription-wire-schema.md`
- Patched batch §14 (now points at the realtime file):
  `docs/research/azure-openai-gpt-4o-mini-transcribe-wire-schema.md` §14
- Plan implementing this design: `docs/design/plan-007-additional-stt-engines.md`
  §A2.1..§A2.11 (and the supporting changes in §A2.4 to §5.x, §C, §D, §E)
- In-tree streaming-provider pattern referenced for the actor +
  events shape: `docs/design/plan-005-apple-speech-streaming.md`
- Streaming protocol contract verified against:
  `Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift`,
  `Sources/MacrecCore/Transcription/TranscriptionProvider.swift`
- Investigation erratum: top of
  `docs/reference/investigation-additional-stt-engines.md`
  (corrects the original "no Azure realtime" finding)
- Open decisions (OQ-A2-1..5): plan-007 §13 + this design §A2D-11
- Risk register additions: plan-007 §10 RT-RISK-1..7
