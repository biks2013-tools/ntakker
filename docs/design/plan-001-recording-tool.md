# Plan 001 — `macrec` macOS Dual-Source Audio Recording Tool

> Phase 4 (Planner) deliverable. Consumed by Phase 5 (Designer), Phase 6
> (parallel Coders), Phase 7 (Code Reviewer), Phase 8 (Dependency
> Validator), Phase 9 (Test Builders), Phase 10 (Integration Verifier).
>
> **Source documents (read in this order before executing this plan):**
> 1. `docs/design/refined-request-recording-tool.md` (FR-1..FR-16, NFR-1..NFR-10, AC-1..AC-15, OQ-1..OQ-10)
> 2. `docs/reference/investigation-recording-tool.md` (architectural decisions)
> 3. `docs/research/scstream-audio-only.md` (system-audio capture recipe)
> 4. `docs/research/avassetwriter-aac.md` (encoder + finalization recipe)
> 5. `CLAUDE.md` (project conventions, Exception 001 — Swift)

---

## Section 1 — Overview

### Summary

`macrec` is a macOS-native command-line tool, written in **Swift 5.9+ for
macOS 14.0+**, that simultaneously captures the system audio submix (via
`ScreenCaptureKit`'s `SCStream` in audio-only configuration) and the
microphone input (via `AVFoundation`'s `AVCaptureSession` +
`AVCaptureAudioDataOutput`), aligns the two streams to a shared host clock,
optionally mixes them, and writes the result to a single configurable
output file in `m4a` (AAC-LC), `wav` (linear PCM), or `caf` (linear PCM)
format. The tool ships as a Swift Package Manager project with one
executable target (`macrec`), one library target (`MacrecCore`), and one
test target (`MacrecCoreTests`). It honors the four-source configuration
precedence chain mandated by `CLAUDE.md` (shell env → `~/.tool-agents/macrec/.env`
→ local `./.env` → CLI flags), bootstraps `~/.tool-agents/macrec/` at mode
`0700` with a seeded `.env` at `0600` on every invocation, raises explicit
errors for missing required configuration (no fallbacks), and treats
`SIGINT`/`SIGTERM` as the canonical "stop" signal in v1.

### Locked decisions (cite OQ refs from the refined request)

- **OQ-1 — Minimum macOS target**: **macOS 14.0+** (Sonoma); Package.swift
  declares `.macOS(.v14)`. `swift-tools-version:5.9`.
- **OQ-2 — CLI binary name**: **`macrec`**. Tool-name token reused for
  `docs/tools/macrec.md` and `~/.tool-agents/macrec/`.
- **OQ-3 — Lifecycle model**: **OVERRIDDEN by user on 2026-04-26.** v1
  supports BOTH foreground (default) and detached background execution.
  - **Foreground (default)**: `start` runs in the current shell, logs
    to stderr, finalizes the file on `SIGINT` / `SIGTERM` /
    `--max-duration` cap. No PID file is written. Two foreground
    recordings to different output files are allowed concurrently.
  - **Detached (`--detach` flag on `start`)**: process double-forks
    (POSIX daemonization pattern), writes its PID to
    `~/.tool-agents/macrec/macrec.pid` (overridable via `--pid-file` /
    `MACREC_PID_FILE`), redirects stdout/stderr to
    `~/.tool-agents/macrec/macrec.log` (overridable via `--log-file` /
    `MACREC_LOG_FILE`, mode `0600`, append), and the parent exits 0
    immediately. The detached child continues recording until SIGTERM /
    SIGINT / `--max-duration` cap.
  - **`stop` subcommand**: reads the PID file (path overridable via
    `--pid-file` / `MACREC_PID_FILE`), distinguishes the four cases
    (no PID file, stale PID, alive-and-stopped, alive-but-timeout),
    waits up to `--stop-timeout` seconds (default 35, env
    `MACREC_STOP_TIMEOUT`) for clean exit. The detached child removes
    its own PID file on every clean exit path. See plan-001 §K and
    project-design §14 for the full state diagrams.
  - Drives **FR-25..FR-29**, **AC-16..AC-20**, and the new
    `MacrecError` cases `noActiveRecording`, `staleRecording`,
    `stopTimeout`, `alreadyRecording`, `pidFileWriteFailed`.
- **OQ-4 — Architectures**: **Universal binary (arm64 + x86_64)** — SPM
  builds both slices automatically; no dependency forces arm64-only.
- **OQ-5 — stdout streaming**: **Not in v1**. Output is always a file path;
  `--output -` is rejected with a parser-level error.
- **OQ-6 — Default track layout**: **`mixed`**.
- **OQ-7 — Default output format**: **`m4a`** (AAC-LC, 192 kbps, 48 kHz
  stereo).
- **OQ-8 — Mic device selection**: accept **either friendly name or UID**;
  resolution is **case-insensitive**; on multiple-name matches, log a
  warning naming all matches and pick the first; if a UID match exists it
  always wins.
- **OQ-9 — System-audio silence detection**: every 10 s at `debug` level,
  log the per-source RMS so users can confirm liveness in debug runs.
- **OQ-10 — Required vs. defaultable config**: **required (no default)**:
  `--output` / `OUTPUT_PATH`. **Defaultable** (defaults documented in
  spec): `--format` (`m4a`), `--layout` (`mixed`), `--sample-rate` (48000),
  `--bit-depth` (16), `--bitrate` (192), `--mic-device` (system default
  input), `--log-level` (`info`).

### Pipeline diagram

```
                ┌──────────────────────────────────────────────────────────────┐
                │                      Capture & Encode Pipeline                │
                │                                                              │
  SCStream ────►│ SCKitSystemAudioSource (Float32/48k/stereo, host-clock PTS)  │
  (host clk)    │             │                                                │
                │             ▼                                                │
                │   [system AVAudioConverter, lifetime-bound]                  │
                │             │                                                │
                │             ▼                                                │
                │       ┌─ HostClockAligner ─┐                                 │
  AVCapture ───►│       │ tracks per-source  │                                 │
  Session       │       │ nextExpectedAudio- │ <── SilenceBufferFactory        │
  (forced       │       │ Time; gap-fills    │     (synthesizes silent         │
  syncClock =   │       │ with silent CMS-   │     CMSampleBuffers when a      │
  hostTimeClk)  │       │ ampleBuffers; emits│     stream stalls)              │
                │       │ time-aligned pairs │                                 │
                │       └────────┬───────────┘                                 │
                │                ▼                                             │
                │     ┌────── Mixer / Splitter ──────┐                         │
                │     │ layout=mixed         → Buf-  │                         │
                │     │   ferSummer (Float32 sum)    │                         │
                │     │ layout=stereo-split  → mic→L,│                         │
                │     │   sys→R (or reverse)         │                         │
                │     │ layout=split         → pass- │                         │
                │     │   through, two writers       │                         │
                │     └──────────────┬───────────────┘                         │
                │                    ▼                                         │
                │   ┌──────────────── Recorder ──────────────────┐             │
                │   │ m4a   → M4ARecorder   (AVAssetWriter, AAC) │             │
                │   │ wav   → WAVRecorder   (AVAudioFile, PCM)   │             │
                │   │ caf   → CAFRecorder   (AVAudioFile, PCM)   │             │
                │   └────────────────┬────────────────────────────┘             │
                │                    ▼                                         │
                │             on-disk output file(s)                           │
                └──────────────────────────────────────────────────────────────┘

  Lifecycle: RecordingSession orchestrates start/stop, signal handlers in
  main.swift post to a DispatchSourceSignal that drives stop().
```

---

## Section 2 — Phases

> Each phase below is a self-contained implementation unit suitable for a
> Phase-6 parallel coder. Phases A→L are sequenced; the parallelization
> map in §4 lists which phases can run concurrently.

---

### Phase A — SPM scaffold + project skeleton

- **Goal**: Stand up the Swift Package, register dependencies, create
  empty stubs for every source file in the locked layout, and confirm
  `swift build` succeeds.
- **Files to create**:
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Package.swift`
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/.gitignore`
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Issues - Pending Items.md`
    (skeleton only — header + pending/completed sections, empty)
  - All source-file stubs under `Sources/macrec/` and `Sources/MacrecCore/`
    listed in §3 — empty `import Foundation` placeholders are sufficient.
  - All test-file stubs under `Tests/MacrecCoreTests/` — each containing an
    empty `XCTestCase` subclass so the test target compiles.
  - `Sources/MacrecCore/Resources/.gitkeep` (placeholder so resource folder
    exists if the test fixtures end up here).
- **Package.swift contents (verbatim)**:
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
                   from: "1.5.4"),
      ],
      targets: [
          .executableTarget(
              name: "macrec",
              dependencies: [
                  "MacrecCore",
                  .product(name: "ArgumentParser",
                           package: "swift-argument-parser"),
              ],
              path: "Sources/macrec"
          ),
          .target(
              name: "MacrecCore",
              dependencies: [
                  .product(name: "Logging", package: "swift-log"),
              ],
              path: "Sources/MacrecCore"
          ),
          .testTarget(
              name: "MacrecCoreTests",
              dependencies: ["MacrecCore"],
              path: "Tests/MacrecCoreTests"
          ),
      ]
  )
  ```
- **`.gitignore` contents**:
  ```
  .build/
  .swiftpm/
  Packages/
  *.xcodeproj
  *.xcworkspace
  DerivedData/
  .DS_Store
  *.swp
  /Tests/MacrecCoreTests/Output/
  ```
- **Acceptance criteria**:
  - `swift build` exits 0 with zero errors and zero warnings on macOS 14+.
  - `swift test` exits 0 (no tests yet, but the test target compiles).
  - `swift run macrec --help` prints `swift-argument-parser`'s default
    "no subcommand" usage banner (the `RootCommand` body is empty in this
    phase — that's fine).
- **Dependencies**: none.
- **Parallelizable with**: nothing (everything depends on this).
- **Effort**: S (1 hour).
- **Risks**:
  - SPM dependency resolution may fail on a sandboxed network. Mitigation:
    Phase 6 must run in an environment with internet access; pre-warm the
    `~/.swiftpm/cache/` if needed.

---

### Phase B — Bootstrap + Config

- **Goal**: Implement the per-user durable defaults bootstrap (FR-13) and
  the four-source configuration resolver (FR-12, FR-14) entirely in pure
  `Foundation`.
- **Files to finalize**:
  - `Sources/MacrecCore/Bootstrap/ToolAgentsBootstrap.swift`
  - `Sources/MacrecCore/Config/DotEnvParser.swift`
  - `Sources/MacrecCore/Config/ConfigResolver.swift`
  - `Sources/MacrecCore/Config/RecordingOptions.swift`
  - `Tests/MacrecCoreTests/ToolAgentsBootstrapTests.swift`
  - `Tests/MacrecCoreTests/DotEnvParserTests.swift`
  - `Tests/MacrecCoreTests/ConfigResolverTests.swift`
  - `Tests/MacrecCoreTests/RecordingOptionsTests.swift`
- **Detailed contracts**:
  - `ToolAgentsBootstrap.ensureToolFolder(toolName: String) throws -> URL`
    - Resolves `~/.tool-agents/<toolName>/`. If absent: create it
      (`FileManager.createDirectory(at:withIntermediateDirectories:attributes:)`
      with `[.posixPermissions: 0o700]`); seed an empty `.env` file
      (mode `0o600`, content: `# macrec durable defaults — see
      docs/design/configuration-guide.md\n`). If present but mode is
      wrong: chmod to `0o700` and the seed file to `0o600`. Return the
      directory URL.
    - Tool-name parameter is injected for testability; production callers
      pass `"macrec"`.
  - `DotEnvParser.parse(_ source: String) -> [String: String]`
    - Trims whitespace per line. Skips blank lines and `#` comments. For
      `KEY=VALUE`: trims `KEY`; strips one matched pair of single or
      double quotes from `VALUE`; preserves embedded `=`. Lines without
      `=` are silently skipped (with an optional `logger.debug` note).
      No environment-variable interpolation (`$VAR`) in v1.
  - `RecordingOptions` struct (resolved): the typed bag the engine
    consumes.
    ```swift
    public struct RecordingOptions {
        public let outputPath: URL
        public let format: OutputFormat            // .m4a | .wav | .caf
        public let layout: TrackLayout             // .mixed | .split | .stereoSplit
        public let sampleRate: Int                 // 44100 | 48000
        public let bitDepth: Int                   // 16 | 24 (PCM only)
        public let bitrate: Int                    // 64...320 kbps (AAC only)
        public let micDevice: String?              // nil = system default
        public let micChannel: StereoChannel       // .left | .right (stereo-split only)
        public let maxDuration: TimeInterval?      // nil = run until SIGINT
        public let overwrite: Bool                 // FR-15
        public let logLevel: LogLevel              // .quiet | .info | .debug
    }
    ```
  - `ConfigResolver`:
    - Constructor: `init(shellEnv: [String: String], userEnvPath: URL,
      localEnvPath: URL, cliFlags: [String: String], fileSystem:
      FileSystem = .live)`. The `fileSystem` indirection allows tests to
      inject synthetic file contents.
    - `resolve(_ key: String) -> String?` returns the highest-priority
      defined value: CLI > local `.env` > user `.env` > shell.
    - `requireString(_ key: String) throws -> String` raises
      `MacrecError.missingRequiredConfig(key:)` (defined in Phase C) when
      every source is `nil`. Must include in the error message which key
      was sought and which sources were checked.
    - `buildRecordingOptions() throws -> RecordingOptions` orchestrates
      conversion: parses ints/enums, validates ranges (sample-rate ∈
      {44100, 48000}; bit-depth ∈ {16, 24}; bitrate ∈ [64, 320]; layout/
      format enum cases; max-duration > 0), expands `~` in paths.
- **Environment-variable name mapping (locked)**:
  | CLI flag         | env-var name        | Default                |
  |------------------|---------------------|------------------------|
  | `--output`       | `OUTPUT_PATH`       | _required (no default)_ |
  | `--format`       | `FORMAT`            | `m4a`                  |
  | `--layout`       | `LAYOUT`            | `mixed`                |
  | `--sample-rate`  | `SAMPLE_RATE`       | `48000`                |
  | `--bit-depth`    | `BIT_DEPTH`         | `16`                   |
  | `--bitrate`      | `BITRATE`           | `192`                  |
  | `--mic-device`   | `MIC_DEVICE`        | _system default input_ |
  | `--mic-channel`  | `MIC_CHANNEL`       | `left`                 |
  | `--max-duration` | `MAX_DURATION`      | _none_                 |
  | `--overwrite`    | `OVERWRITE`         | `false`                |
  | `--log-level`    | `LOG_LEVEL`         | `info`                 |
  | `--detach`       | `DETACH`            | `false` (FR-25)        |
  | `--pid-file`     | `MACREC_PID_FILE`   | `~/.tool-agents/macrec/macrec.pid` (FR-25/FR-27) |
  | `--log-file`     | `MACREC_LOG_FILE`   | `~/.tool-agents/macrec/macrec.log` (FR-29; detach only) |
  | `--stop-timeout` | `MACREC_STOP_TIMEOUT` | `35` seconds (FR-26; `stop` subcommand only) |
- **New ConfigResolver keys (FR-25, FR-26, FR-29)**: `ConfigResolver`
  must learn three new keys (`MACREC_PID_FILE`, `MACREC_LOG_FILE`,
  `MACREC_STOP_TIMEOUT`) and one boolean flag (`DETACH`). The
  `RecordingOptions` builder is unchanged — these four values are
  consumed by `StartCommand` / `StopCommand` directly (they belong to
  the run model, not the encoding pipeline). Validation:
  - `MACREC_PID_FILE`, `MACREC_LOG_FILE`: must be writable paths;
    parent must exist; `~` expansion supported.
  - `MACREC_STOP_TIMEOUT`: positive integer seconds; max 600 (sanity
    bound; reject larger values with `EX_USAGE`).
  - `DETACH`: parsed by the same `"true"|"1"|"yes"` rule as
    `OVERWRITE`.
- **Acceptance criteria**:
  - **AC-9 satisfied** by `ConfigResolverTests`: a precedence-table test
    feeds (shellEnv, user-env-file, local-env-file, cli-flags) tuples
    and asserts the resolved value matches the expected highest-priority
    source.
  - **AC-10 satisfied** by `ToolAgentsBootstrapTests`: a temp-dir test
    deletes the folder, calls `ensureToolFolder`, and asserts the
    directory is recreated at mode `0700` and the seed `.env` exists at
    mode `0600`.
  - `DotEnvParserTests`: covers comments, blank lines, quoted values,
    embedded `=`, missing `=`, leading/trailing whitespace.
  - `RecordingOptionsTests`: covers default-vs-required behavior,
    invalid-enum errors, range validation (e.g. `bitrate=999` rejected).
- **Dependencies**: Phase A (file stubs and Package.swift must exist).
- **Parallelizable with**: Phase C, Phase D, Phase E (independent
  modules).
- **Effort**: M (1 day).
- **Risks**:
  - macOS HFS+/APFS may not honor `0o700` cleanly on every iCloud-
    backed home directory. Mitigation: re-chmod at every invocation;
    treat current-user-rw-only as the success criterion.

---

### Phase C — Logging + Errors

- **Goal**: Provide the swift-log bootstrap and the typed error enum every
  other module returns.
- **Files to finalize**:
  - `Sources/MacrecCore/Logging/LoggerFactory.swift`
  - `Sources/MacrecCore/Errors/MacrecError.swift`
  - `Tests/MacrecCoreTests/MacrecErrorTests.swift`
- **Detailed contracts**:
  - `LoggerFactory.bootstrap(level: LogLevel)` calls
    `LoggingSystem.bootstrap` exactly once (idempotent guard via a
    `static var didBootstrap: Bool`). Hands out
    `StreamLogHandler.standardError(label:)` configured to the requested
    level.
  - Map: `.quiet → .warning`, `.info → .info`, `.debug → .debug`.
  - `MacrecError`:
    ```swift
    public enum MacrecError: Error, CustomStringConvertible {
        case missingRequiredConfig(key: String, sourcesChecked: [String])
        case invalidConfigValue(key: String, value: String, expected: String)
        case outputParentMissing(URL)
        case outputAlreadyExists(URL)              // unless --overwrite
        case screenRecordingPermissionDenied
        case screenRecordingPermissionNotDetermined
        case microphonePermissionDenied
        case microphonePermissionNotDetermined
        case micDeviceNotFound(String)
        case scStreamFailedToStart(underlying: Error)
        case scStreamSilentStopExceeded(restartCount: Int)
        case avCaptureFailedToStart(underlying: Error)
        case writerFailedToStart(underlying: Error)
        case writerFinalizationTimeout(URL)
        case finishWritingFailed(underlying: Error)
        case unknown(String)

        public var exitCode: Int32 { /* see table below */ }
        public var remediation: String { /* user-facing one-liner */ }
        public var description: String { /* short summary, no PII */ }
    }
    ```
  - **Exit-code table (locked)**:
    | Case                                  | Exit code | Reason |
    |---------------------------------------|-----------|--------|
    | normal / SIGINT-finalized             | 0         | success |
    | `unknown`, generic write failure      | 1         | generic error |
    | `writerFinalizationTimeout`           | 2         | partial file |
    | `invalidConfigValue`, parser errors   | 64 (`EX_USAGE`) | bad flag |
    | `outputParentMissing`, `outputAlreadyExists` | 66 (`EX_NOINPUT`) | I/O |
    | `*PermissionNotDetermined`            | 75 (`EX_TEMPFAIL`) | retry after grant |
    | `*PermissionDenied`                   | 77 (`EX_NOPERM`) | denied |
    | `micDeviceNotFound`                   | 78 (`EX_CONFIG`) | bad config |
    | `scStreamFailedToStart`, `avCaptureFailedToStart` | 70 (`EX_SOFTWARE`) | runtime |
    | `scStreamSilentStopExceeded`          | 70 (`EX_SOFTWARE`) | runtime |
    | `missingRequiredConfig`               | 78 (`EX_CONFIG`) | bad config |
    | `finishWritingFailed`                 | 1         | generic error |
- **Acceptance criteria**:
  - `MacrecErrorTests` asserts each case maps to the documented exit
    code, and that `description` strings contain no audio samples /
    device serials (NFR-7).
  - Manual smoke: `swift run macrec --log-level debug start --output /tmp/x.m4a`
    writes a `[debug]` line to stderr (real recording will fail
    permissions; but log line proves the level switch).
- **Dependencies**: Phase A.
- **Parallelizable with**: Phase B, Phase D, Phase E.
- **Effort**: S (4 hours).
- **Risks**: none material.

---

### Phase D — Permissions + Devices

- **Goal**: Implement Screen Recording / Microphone permission detection +
  request, and the Core Audio HAL device enumerator that backs
  `list-devices` and `--mic-device` resolution.
- **Files to finalize**:
  - `Sources/MacrecCore/Permissions/ScreenRecordingPermission.swift`
  - `Sources/MacrecCore/Permissions/MicrophonePermission.swift`
  - `Sources/MacrecCore/Permissions/PermissionGate.swift` (protocol +
    `LivePermissionGate` impl that composes the two above; testable via
    `StubPermissionGate`)
  - `Sources/MacrecCore/Devices/AudioDeviceEnumerator.swift`
  - `Tests/MacrecCoreTests/PermissionDetectionTests.swift` (uses
    `StubPermissionGate`; live calls cannot run in CI)
  - `Tests/MacrecCoreTests/AudioDeviceEnumeratorTests.swift` (uses a
    protocol-injected fake HAL; live HAL tests are exercised manually
    via `list-devices`)
- **Detailed contracts**:
  - `ScreenRecordingPermission`:
    - `current() -> PermissionState` calls `CGPreflightScreenCaptureAccess()`
      (returns `.authorized` true → granted, false → notDetermined; treat
      throws as `.notDetermined`).
    - `request() -> Bool` calls `CGRequestScreenCaptureAccess()` (returns
      Bool immediately; spawns prompt async). Per research §6,
      same-process state observation is unreliable — surface the
      "please relaunch" message at the call site.
  - `MicrophonePermission`:
    - `current() -> PermissionState` reads
      `AVCaptureDevice.authorizationStatus(for: .audio)`.
    - `request(completion: @escaping (Bool) -> Void)` wraps
      `AVCaptureDevice.requestAccess(for: .audio) { ... }`.
  - `PermissionState`: `.authorized | .denied | .notDetermined |
    .restricted`.
  - `AudioDeviceEnumerator.listInputDevices() throws -> [AudioInputDevice]`:
    - Use Core Audio HAL: `AudioObjectGetPropertyDataSize` +
      `AudioObjectGetPropertyData` for
      `kAudioHardwarePropertyDevices`. Filter to input-capable devices
      via `kAudioDevicePropertyStreamConfiguration` scope `Input` (count
      > 0 → input-capable).
    - For each device, fetch `kAudioDevicePropertyDeviceUID` and
      `kAudioDevicePropertyDeviceNameCFString`.
    - Return `AudioInputDevice { uid: String, name: String,
      sampleRateHz: Double, channelCount: Int, isDefault: Bool }`.
  - `AudioDeviceEnumerator.resolve(_ identifier: String) throws ->
    AudioInputDevice`:
    - First match by exact UID (case-sensitive, since UIDs are stable).
    - Else match by case-insensitive name. On multiple name matches:
      log a warning naming all matches and pick the first by ascending
      `AudioObjectID`.
    - Else throw `MacrecError.micDeviceNotFound(identifier)`.
- **Acceptance criteria**:
  - **AC-2 satisfied**: `swift run macrec check-permissions` (Phase K)
    correctly prints both states; this phase is the back-end.
  - **AC-3 satisfied**: `swift run macrec list-devices` (Phase K)
    prints at least the built-in mic with name and UID; this phase is
    the back-end. The Phase-D tests cover the formatting separately
    via `AudioDeviceEnumeratorTests` against a fake HAL.
  - `PermissionDetectionTests` exercises every `PermissionState`
    variant against `StubPermissionGate`.
- **Dependencies**: Phase A, Phase C (uses `MacrecError`).
- **Parallelizable with**: Phase B, Phase E.
- **Effort**: M (1 day).
- **Risks**:
  - TCC ad-hoc-signing instability re-prompts on every rebuild.
    Mitigation: document `tccutil reset ScreenCapture` /
    `tccutil reset Microphone` in `docs/tools/macrec.md` (Phase L).
  - Some Bluetooth devices report odd
    `kAudioDevicePropertyStreamConfiguration` values. Mitigation:
    treat any device with input streams > 0 as listable; do not
    filter on sample-rate or channel-count.

---

### Phase E — Capture protocols + fakes

- **Goal**: Define the protocols every source must conform to, and
  implement an in-process fake source so the rest of the pipeline can be
  exercised before SCStream/AVCapture are stable.
- **Files to finalize**:
  - `Sources/MacrecCore/Capture/SystemAudioSource.swift` (protocol only)
  - `Sources/MacrecCore/Capture/MicrophoneSource.swift` (protocol only)
  - `Sources/MacrecCore/Capture/FakeAudioSource.swift` (test fake; lives
    in the library so test_scripts and the orchestrator's tests can reach
    it without conditional compilation)
  - `Tests/MacrecCoreTests/FakeAudioSourceTests.swift`
- **Detailed contracts**:
  ```swift
  public protocol AudioSource: AnyObject {
      var formatDescription: CMAudioFormatDescription? { get }
      var onSampleBuffer: ((CMSampleBuffer) -> Void)? { get set }
      func start() async throws
      func stop() async
  }

  public protocol SystemAudioSource: AudioSource {}
  public protocol MicrophoneSource: AudioSource {}
  ```
- `FakeAudioSource`:
  - Configurable: `frequencyHz`, `channelCount`, `sampleRate`,
    `bufferDurationMs` (default 20 ms), `tickClock: Clock` (defaults to
    `ContinuousClock`).
  - Generates non-interleaved Float32 sine waves; PTS values are
    derived from a captured `CMClock.hostTimeClock.time` plus
    cumulative buffer durations to simulate real `SCStream` /
    `AVCaptureSession` PTS sequences.
  - `start()` schedules a periodic emit on a background `DispatchQueue`;
    `stop()` cancels.
  - Convenience factories: `makeSystem440Hz()` and `makeMic880Hz()` so
    the orchestrator's E2E test can distinguish the two streams in the
    output file.
- **Acceptance criteria**:
  - `FakeAudioSourceTests`: confirms 60 buffers in ~1.2 s for a 20 ms
    interval (±5 % tolerance); confirms PTSs are monotonically
    increasing; confirms each buffer carries the configured frame
    count, sample rate, channel count.
- **Dependencies**: Phase A.
- **Parallelizable with**: Phase B, Phase C, Phase D.
- **Effort**: S (4–6 hours).
- **Risks**: none material.

---

### Phase F — HostClockAligner + SilenceBufferFactory + BufferSummer

- **Goal**: Pure DSP plumbing — alignment, silence-fill synthesis, and the
  Float32 sum used by the `mixed` layout. No framework I/O. Drives
  AC-12 and underpins NFR-4.
- **Files to finalize**:
  - `Sources/MacrecCore/Aligning/HostClockAligner.swift`
  - `Sources/MacrecCore/Aligning/SilenceBufferFactory.swift`
  - `Sources/MacrecCore/Mixing/BufferSummer.swift`
  - `Tests/MacrecCoreTests/HostClockAlignerTests.swift`
  - `Tests/MacrecCoreTests/SilenceBufferFactoryTests.swift`
  - `Tests/MacrecCoreTests/BufferSummerTests.swift`
- **Detailed contracts**:
  - `HostClockAligner`:
    - Tracks `nextExpectedAudioTime: CMTime?` per source. Pattern from
      `docs/research/scstream-audio-only.md` §4.3 / Nonstrict gap-handling
      blog (also referenced in `docs/reference/investigation-recording-tool.md`
      §4 + §10 sources 8 and 15).
    - On each incoming buffer: compute `gap = pts -
      nextExpectedAudioTime`; if `gap > 1 sample`, prepend a
      silence-fill `CMSampleBuffer` of duration `gap` (constructed via
      `SilenceBufferFactory`); update `nextExpectedAudioTime = pts +
      duration`.
    - Emits **time-aligned pairs**: for the `mixed` and `stereo-split`
      layouts the consumer needs `(systemBuffer, micBuffer)` sharing
      identical PTSs and durations. Implementation: small per-source
      ring buffer (capacity ≈ 200 ms / 10 buffers), drains in lockstep
      whenever both heads have data covering the same time slice.
    - For `split` layout the aligner is bypassed in favor of two
      independent passthroughs (each source still gets its own gap-fill
      via the same silence factory; no cross-source pairing needed).
    - The aligner never blocks the capture callback. Capture sources
      enqueue; a dedicated `alignerQueue` drains.
  - `SilenceBufferFactory.makeSilence(startPTS:duration:formatDescription:sampleRate:)
     throws -> CMSampleBuffer`:
    - Verbatim implementation from `docs/research/avassetwriter-aac.md`
      §4.3 (zeroed `CMBlockBuffer` via
      `CMBlockBufferCreateWithMemoryBlock` + `CMBlockBufferFillDataBytes`).
  - `BufferSummer.sum(_:_:)`:
    - Two `AVAudioPCMBuffer`s of identical Float32 / 48 kHz / stereo /
      non-interleaved format and identical `frameLength`.
    - For each channel: pointwise float add. Optional gain factor
      defaulting to `1.0` per source (no AGC; A-7 in refined request).
    - Saturates at `[-1.0, +1.0]` via a simple clamp to prevent clipping
      on full-scale double signals.
- **Acceptance criteria**:
  - `HostClockAlignerTests`:
    1. **Drift bound**: feed two synthetic streams at exactly 48 kHz
       with PTSs offset by 5 ms; assert the aligner emits paired
       buffers whose `|sysPTS - micPTS|` is < 1 sample period
       (≤ 21 µs) for 10 000 buffers ≈ 200 s.
    2. **Gap fill**: drop 50 ms from the system stream; assert the
       aligner emits a silence-fill buffer of exactly 50 ms with
       PTS continuity preserved.
    3. **No reorder**: confirm output PTSs are strictly monotonically
       increasing.
  - `SilenceBufferFactoryTests`: confirm output buffer's `dataReady ==
    true`, `numSamples == frameCount`, total bytes are zeroed.
  - `BufferSummerTests`: feed two 1-second 0.5-amplitude buffers (one
    sine, one cosine of the same frequency); confirm the sum is the
    per-sample sum within 1e-7 absolute error.
- **Dependencies**: Phase A, Phase C, Phase E (uses `FakeAudioSource` in
  alignment tests).
- **Parallelizable with**: Phase G, Phase H once Phase E is done.
- **Effort**: M (1.5 days).
- **Risks**:
  - Misuse of `CMTime` arithmetic at differing timescales is the most
    common bug. Mitigation: normalize all internal timestamps to
    timescale 48 000 at aligner ingress.

---

### Phase G — Recorder protocol + M4ARecorder

- **Goal**: Define the writer abstraction and implement the AAC m4a path
  using `AVAssetWriter`. Drives AC-4, AC-7, AC-12.
- **Files to finalize**:
  - `Sources/MacrecCore/Encoding/Recorder.swift` (protocol)
  - `Sources/MacrecCore/Encoding/M4ARecorder.swift`
  - `Tests/MacrecCoreTests/M4ARecorderTests.swift`
- **Detailed contracts**:
  - `Recorder` protocol:
    ```swift
    public protocol Recorder: AnyObject {
        func start(at sessionStart: CMTime) throws
        func append(_ buffer: CMSampleBuffer) throws
        func finalize(at sessionEnd: CMTime,
                      timeout: TimeInterval,
                      completion: @escaping (Result<URL, MacrecError>) -> Void)
    }
    ```
  - `M4ARecorder` (AAC-LC, MPEG-4 audio) — copy the exact recipe from
    `docs/research/avassetwriter-aac.md` §1.1 verbatim:
    - `AVAssetWriter(outputURL:fileType: .m4a)`.
    - `writer.shouldOptimizeForNetworkUse = true`.
    - `writer.movieFragmentInterval = CMTime(value: 2, timescale: 1)`
      (2-second fragments → AC-7 belt-and-braces).
    - `outputSettings`:
      ```swift
      AVFormatIDKey:         Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey:       options.sampleRate,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey:   options.bitrate * 1000,
      AVChannelLayoutKey:    Data(bytes: &layout,
                                  count: MemoryLayout<AudioChannelLayout>.size)
      ```
    - `audioInput.expectsMediaDataInRealTime = true`.
    - `start(at:)`: `startWriting` → `startSession(atSourceTime:)` with
      the captured host-clock time (per §2.3 "uptime PTS trap").
    - `append(_:)`: enqueue on a serial `writerQueue`; honor
      `isReadyForMoreMediaData` — drop with a `logger.warning` on back-
      pressure (§4.6).
    - `finalize(at:timeout:completion:)`:
      - `markAsFinished()` → `endSession(atSourceTime:)` →
        `finishWriting { … }`.
      - 30-second `DispatchWorkItem` watchdog; if it fires before
        completion, return `.failure(.writerFinalizationTimeout(url))`.
- **Acceptance criteria**:
  - `M4ARecorderTests`:
    1. **Round-trip**: feed 5 seconds of 440 Hz Float32 stereo via
       `FakeAudioSource`; finalize; open the output with
       `AVURLAsset`; assert duration in [4.95 s, 5.05 s].
    2. **`afinfo`-style metadata**: re-read the file with `AVAudioFile`
       and assert `processingFormat.sampleRate == 48 000.0`,
       `channelCount == 2`, `commonFormat == .pcmFormatFloat32`.
    3. **Crash-safety scaffolding**: assert `shouldOptimizeForNetworkUse`
       is `true` and `movieFragmentInterval` equals `CMTime(2, 1)` on
       the writer instance immediately after `start(at:)` (white-box
       test via `@testable import MacrecCore`).
  - **AC-4 partial** (real recording with mic/system content is exercised
    in Phase J's E2E script).
- **Dependencies**: Phase A, Phase C, Phase F (uses `SilenceBufferFactory`
  for synthetic tests).
- **Parallelizable with**: Phase H (different output formats).
- **Effort**: M (1.5 days).
- **Risks**:
  - "Uptime PTS trap" — covered by §2.3 of the avassetwriter research
    doc. Implementation MUST capture `CMClock.hostTimeClock.time` at
    `RecordingSession.start()` and pass that exact `CMTime` into
    `M4ARecorder.start(at:)`.
  - Per `docs/research/avassetwriter-aac.md` §7.2, the
    `movieFragmentInterval` × `shouldOptimizeForNetworkUse` interaction
    has not been formally verified. Mitigation: an `afinfo` smoke check
    is part of the Phase 10 verification checklist.

---

### Phase H — WAVRecorder + CAFRecorder

- **Goal**: Implement the PCM paths for `wav` and `caf` formats using
  `AVAudioFile`.
- **Files to finalize**:
  - `Sources/MacrecCore/Encoding/WAVRecorder.swift`
  - `Sources/MacrecCore/Encoding/CAFRecorder.swift`
  - `Tests/MacrecCoreTests/WAVRecorderTests.swift`
  - `Tests/MacrecCoreTests/CAFRecorderTests.swift`
- **Detailed contracts**:
  - `WAVRecorder` recipe verbatim from `docs/research/avassetwriter-aac.md`
    §1.2 — settings dict constructed manually (do NOT pass
    `buffer.format.settings`).
  - `CAFRecorder` recipe verbatim from §1.3.
  - Both bridge `CMSampleBuffer` → `AVAudioPCMBuffer` for `write(from:)`
    using the conversion utility in §4.4 (lives in a small private
    extension or in `MacrecCore/Encoding/CMSampleBufferAudioConversion.swift`).
  - `start(at:)` is a no-op on `AVAudioFile` (no session concept); we
    record `sessionStart` only for log diagnostics.
  - `finalize(at:timeout:completion:)`: `AVAudioFile` flushes on
    deallocation; explicitly nil-out the file handle and synchronously
    call `completion(.success(url))` once any pending writes flush. No
    timeout watchdog needed (PCM writes are synchronous).
- **Acceptance criteria**:
  - `WAVRecorderTests`: write 1 s of 440 Hz; re-open with `AVAudioFile`
    for reading; assert `processingFormat.sampleRate == 48 000`,
    `processingFormat.channelCount == 2`, `length == 48 000`.
    Inspect on-disk format: `commonFormat == .pcmFormatInt16`,
    little-endian.
  - `CAFRecorderTests`: same as wav but big-endian PCM.
  - Manual: open both files in QuickTime Player.
- **Dependencies**: Phase A, Phase C, Phase F.
- **Parallelizable with**: Phase G.
- **Effort**: S (6 hours).
- **Risks**:
  - The `buffer.format.settings` runtime conflict (research doc §1.2);
    avoided by constructing the dict by hand.

---

### Phase I — Real capture sources (SCKitSystemAudioSource + AVMicrophoneSource)

- **Goal**: Implement the real `SCStream` and `AVCaptureSession` sources
  conforming to the Phase-E protocols, fully populated with the recipes
  in the research docs.
- **Files to finalize**:
  - `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift`
  - `Sources/MacrecCore/Capture/AVMicrophoneSource.swift`
  - `Tests/MacrecCoreTests/SCKitSystemAudioSourceCompilationTest.swift`
    (compile-only smoke; live capture cannot run in CI)
  - `Tests/MacrecCoreTests/AVMicrophoneSourceCompilationTest.swift`
    (compile-only smoke)
- **Detailed contracts**:
  - `SCKitSystemAudioSource` — implement the full pattern in
    `docs/research/scstream-audio-only.md` §1, §3 (watchdog), §6 (stop
    recipe), §7 (error matrix):
    - `SCStreamConfiguration` with the locked knobs (verbatim from §2 of
      that doc): `capturesAudio = true`, `excludesCurrentProcessAudio =
      true`, `sampleRate = 48_000`, `channelCount = 2`,
      `minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)`,
      `width = 2`, `height = 2`, `queueDepth = 5`, `showsCursor = false`.
      Do NOT set `captureMicrophone` / `microphoneCaptureDeviceID`
      (macOS 15+ only).
    - `SCContentFilter` via `SCShareableContent.excludingDesktopWindows
      (false, onScreenWindowsOnly: true)`, then
      `SCContentFilter(display: ..., excludingApplications: [],
      exceptingWindows: [])`.
    - `addStreamOutput` for both `.audio` and `.screen` (we discard
      `.screen` buffers in the callback).
    - `lastBufferArrival` heartbeat + 5-second poll watchdog with
      10-second staleness threshold; on stall, full-restart (new
      `SCStream` instance — never reuse a stopped one).
    - `didStopWithError` always wraps work in `Task { ... }` to dodge
      the `swift_getErrorValue` `EXC_BAD_ACCESS` framework bug.
    - Restart-counter cap: if > 3 restarts within 60 s, stop trying and
      emit `MacrecError.scStreamSilentStopExceeded(restartCount:)`.
    - On normal stop (`SystemAudioSource.stop()`): cancel watchdog
      Task BEFORE awaiting `stream.stopCapture()`.
  - `AVMicrophoneSource`:
    - `AVCaptureSession.synchronizationClock = CMClockGetHostTimeClock()`
      (mandatory for AC-12 / NFR-4).
    - Resolve `AVCaptureDevice` via `AVCaptureDevice(uniqueID:)` (UID
      first) or by case-insensitive name lookup (Phase D enumerator).
    - `AVCaptureDeviceInput(device:)` → `AVCaptureAudioDataOutput`
      with `setSampleBufferDelegate(self, queue: micQueue)`.
    - `audioSettings` empty by default — let the device deliver native
      format; the `HostClockAligner`'s upstream `AVAudioConverter`
      handles resample/upmix to Float32/48k/stereo.
    - Lifecycle: `session.startRunning()` in `start()`,
      `session.stopRunning()` in `stop()`. No watchdog (AVCapture is
      reliable per investigation §2).
- **Acceptance criteria**:
  - Compilation tests pass — confirms imports, API signatures, and
    delegate conformance match the SDK on the build machine.
  - Manual smoke (developer-only, recorded as part of Phase 10): boot
    `swift run macrec start --output /tmp/sc.m4a --max-duration 5` and
    verify no crash, no hang, and a non-zero file is produced.
  - Watchdog logic exercised by injecting a `Clock` indirection into
    the watchdog so unit tests can simulate stalls without 10 s waits
    (optional; if too costly, defer to Phase 10 manual).
- **Dependencies**: Phase A, Phase C, Phase D, Phase E.
- **Parallelizable with**: Phase G, Phase H.
- **Effort**: L (2–3 days, including the watchdog test surface).
- **Risks**:
  - `replayd` silent-stop bug — mitigated by watchdog restart; residual
    risk that 3 restarts in 60 s legitimately occur on a heavy system,
    causing a false fatal. Mitigation: tune threshold during Phase 10.
  - macOS 26.x (Tahoe) plain-binary TCC listing regression — UX issue
    only; record in Issues - Pending Items.md.

---

### Phase J — RecordingSession orchestrator

- **Goal**: Wire sources → aligner → mixer → recorder; manage lifecycle
  (start, signal-driven stop, max-duration); install signal handlers from
  `main.swift`. Drives AC-4, AC-5, AC-6, AC-7, AC-11, AC-12.
- **Files to finalize**:
  - `Sources/MacrecCore/RecordingSession.swift`
  - `Sources/MacrecCore/SignalHandler.swift`
  - `Tests/MacrecCoreTests/RecordingSessionTests.swift` (uses fake
    sources end-to-end)
- **Detailed contracts**:
  - `RecordingSession`:
    ```swift
    public final class RecordingSession {
        public init(
            options: RecordingOptions,
            systemSource: SystemAudioSource,
            micSource: MicrophoneSource,
            permissions: PermissionGate,
            logger: Logger
        )
        public func start() async throws
        public func stop(reason: StopReason,
                         completion: @escaping (Result<[URL], MacrecError>) -> Void)
    }
    ```
  - `start()`:
    1. Permission gate: assert `.authorized` for both screen & mic;
       else throw the matching `MacrecError`.
    2. Validate output path (FR-15): parent must exist; if file exists
       and `--overwrite` is false, throw `outputAlreadyExists`.
    3. Capture `sessionStart = CMClock.hostTimeClock.time`.
    4. Build per-source `AVAudioConverter` (long-lived; one per
       source per session — research §3.5).
    5. Build `HostClockAligner` (skip for `split` layout).
    6. Build `Recorder`(s) per layout:
       - `mixed` / `stereo-split`: one recorder at the user's path.
       - `split`: two recorders at `<basename>.mic.<ext>` and
         `<basename>.system.<ext>`.
    7. Wire each source's `onSampleBuffer` → converter → aligner →
       mixer/splitter → recorder.append.
    8. `try await systemSource.start()`; `try await micSource.start()`.
    9. `recorder.start(at: sessionStart)` for each recorder (m4a needs
       it; wav/caf no-op).
    10. Install max-duration timer (if set) and SIGINT/SIGTERM
        handlers via `SignalHandler`.
    11. **PID file write (FR-25/FR-27, detach mode only)**: if
        `options.runMode == .detached`, atomically write the current
        PID to `options.pidFilePath` (mode `0600`) IMMEDIATELY after
        step 9 (recording is initialized) but BEFORE the first capture
        buffer is allowed to flow. On write failure, throw
        `MacrecError.pidFileWriteFailed(path:reason:)`. Foreground
        mode does NOT write a PID file.
  - `stop(reason:completion:)`:
    1. Idempotency guard (`isStopping`).
    2. `await systemSource.stop()`; `await micSource.stop()`.
    3. Drain any aligner-buffered data and append.
    4. `recorder.finalize(at: CMClock.hostTimeClock.time, timeout: 30)`
       for each recorder.
    5. **PID file removal (FR-27, detach mode only)**: in the
       completion handler — regardless of `Result` outcome, as long as
       the process is exiting cleanly (SIGINT, SIGTERM, max-duration
       cap, finalize-success) — best-effort `unlink(pidFilePath)`. Log
       a warning if the unlink fails but do NOT propagate it as the
       session result. **DO NOT remove the PID file on crash** — let
       it become a stale marker that the next `stop` call cleans up.
    6. After all recorders complete (or any one fails), call
       `completion(.success([urls]))` or `.failure(...)`.
  - `SignalHandler`: implement the pattern in
    `docs/research/avassetwriter-aac.md` §1.4 / §5.1 — `Darwin.signal(_,
    SIG_IGN)` then `DispatchSource.makeSignalSource` on a
    user-interactive serial queue, posting `stop()` to the session.
  - `StopReason`: `.signal(Int32) | .maxDuration | .programmatic |
    .error(MacrecError)`.
- **Acceptance criteria**:
  - `RecordingSessionTests`:
    1. **Mixed E2E with fakes**: wire two `FakeAudioSource` instances
       (440 Hz mic, 880 Hz system); record for 2 s into a temp `.m4a`;
       assert the output exists, opens, and contains both frequencies
       (verify via FFT on a re-read 1024-sample slice — sketchy in
       unit-test territory; if too brittle, downgrade to "duration
       within ±100 ms and file > 0 bytes").
    2. **Split layout**: same setup with `--layout split`; assert two
       output files exist with the documented names and approximately
       equal durations.
    3. **Stereo-split layout**: assert the output stereo file's
       channel L RMS reflects the mic source only (440 Hz) and
       channel R RMS reflects the system source only (880 Hz).
    4. **Stop on signal**: install handler on a child task; raise
       SIGINT (via `kill(getpid(), SIGINT)`) after 1 s; assert the
       file is finalized and the completion fires within 5 s.
    5. **Max-duration**: set `--max-duration 1`; assert the recording
       stops at 1.0 s ±100 ms and the recorder finalizes.
    6. **PID file lifecycle (FR-27)**: configure the session in
       detached mode (set `options.runMode = .detached` and
       `options.pidFilePath` to a temp path); start the session;
       assert the PID file appears with mode `0600` and contains the
       current PID. Stop the session normally; assert the PID file is
       removed on the clean exit path. Repeat for all four exit paths
       (signal, max-duration, programmatic, recorder error) — only
       the four clean-exit paths must remove the file; a synthetic
       crash path (force-killing the test session via XCTest
       `XCTSkip` if not feasible) is documented but not asserted.
- **Dependencies**: Phase A, B, C, D, F, G, H, E.
- **Parallelizable with**: Phase K (CLI shell can be developed against
  the protocol surface).
- **Effort**: L (2 days; +0.5 day for the PID-file lifecycle hook and
  its tests).
- **Risks**:
  - `finishWriting` 30 s timeout too tight on slow disks. Mitigation:
    Phase 10 manual measurement; configurable via private constant.
  - PID-file removal on the error-exit path may race with `stop`
    invocations from another shell. Mitigation: removal is
    best-effort (`unlink` and ignore `ENOENT`); the `stop` subcommand
    treats a missing PID file as `noActiveRecording`.

---

### Phase K — CLI shell

- **Goal**: Implement the swift-argument-parser command surface, the
  `main.swift` entrypoint, the daemonization (double-fork) logic for
  `--detach`, and the `stop` subcommand. Drives AC-1, AC-2, AC-3,
  **AC-16, AC-17, AC-18, AC-19, AC-20**.
- **Files to finalize**:
  - `Sources/macrec/main.swift`
  - `Sources/macrec/Commands/RootCommand.swift`
  - `Sources/macrec/Commands/StartCommand.swift`
  - `Sources/macrec/Commands/StopCommand.swift` _(NEW — FR-26)_
  - `Sources/macrec/Commands/ListDevicesCommand.swift`
  - `Sources/macrec/Commands/CheckPermissionsCommand.swift`
  - `Sources/macrec/Daemonization/Daemonizer.swift` _(NEW — FR-25)_
  - `Sources/macrec/Daemonization/PidFile.swift` _(NEW — FR-25/FR-27/FR-28)_
  - `Tests/MacrecCoreTests/CLIArgumentParsingTests.swift`
  - `Tests/MacrecCoreTests/StopCommandTests.swift` _(NEW)_
  - `Tests/MacrecCoreTests/PidFileTests.swift` _(NEW)_
- **Detailed contracts**:
  - `main.swift`:
    1. Bootstraps `LoggerFactory` at the resolved log level.
    2. Calls `try ToolAgentsBootstrap.ensureToolFolder(toolName: "macrec")`
       FIRST (FR-13 — every invocation, every subcommand).
    3. Dispatches to `RootCommand.main()`.
  - `RootCommand` (`AsyncParsableCommand`):
    - `subcommands: [StartCommand.self, StopCommand.self,
      ListDevicesCommand.self, CheckPermissionsCommand.self]`.
    - `defaultSubcommand: nil` — running with no subcommand prints
      `--help`.
    - Globally: `--version` derived from `let macrecVersion = "0.1.0"`
      compile-time constant.
  - `StartCommand`:
    - All flags from the env-var mapping table (Phase B). Required:
      `--output`. New flags: `--detach` (Bool), `--pid-file <path>`,
      `--log-file <path>`. Validation pinned in `RecordingOptions`
      builder for the recording knobs; the run-mode flags
      (`detach`, `pidFilePath`, `logFilePath`) are validated in
      `StartCommand.run()`.
    - `run() async throws`:
      1. Build `ConfigResolver` from `ProcessInfo.processInfo.environment`,
         the user `.env`, the local `.env`, and the parsed flags;
         construct `RecordingOptions`.
      2. Resolve run-mode values: `runMode = detached ? .detached : .foreground`,
         `pidFilePath`, `logFilePath`.
      3. **Foreground path** (`runMode == .foreground`): instantiate
         live sources / permissions / recorder via dependency
         factories; call `RecordingSession.start()` and await the
         stop signal. **No PID file written.**
      4. **Detached path** (`runMode == .detached`):
         a. **Already-recording guard (FR-28)**: if `pidFilePath`
            exists and the contained PID is alive (`kill(pid, 0)`
            succeeds OR fails with `EPERM`, indicating the PID is
            in use), exit with `MacrecError.alreadyRecording(pid:
            <pid>, path: <pidFilePath>)`. If the PID is stale
            (`kill(pid, 0)` fails with `ESRCH`), remove the file
            and continue. If the file exists but is unreadable /
            malformed, treat it as stale (log a warning), remove
            it, and continue.
         b. Open the log file at `logFilePath` (`O_WRONLY |
            O_CREAT | O_APPEND`, mode `0600`). On failure, exit
            with `MacrecError.ioError(...)` BEFORE forking.
         c. **Double-fork** via `Daemonizer.detach()`:
            1. `fork()` → if parent, `_exit(0)`. If child:
            2. `setsid()` to detach from the controlling terminal.
            3. `fork()` again → if intermediate, `_exit(0)`. The
               second child is the "grandchild" daemon.
            4. `chdir("/")` (so we don't pin the user's CWD).
            5. `umask(0)`.
            6. Close `stdin`; `dup2(logFd, STDOUT_FILENO)`;
               `dup2(logFd, STDERR_FILENO)`. Close the original
               `logFd`.
         d. Re-bootstrap `LoggerFactory` so its `StreamLogHandler`
            picks up the new fd-2 (which is now the log file).
         e. The grandchild process now runs the same recording
            sequence as foreground mode, except `RecordingSession`
            sees `runMode == .detached` and writes/removes the PID
            file per Phase J §11.
         f. The grandfather and intermediate parents have already
            exited — the user's shell prompt returns immediately.
            **Target wall-clock from invocation to prompt: < 1 s
            (AC-16).**
    - **`--output -` rejected**: same parser-level error as in v1
      (OQ-5).
    - **`stdout` / `stderr` redirection note**: in detach mode,
      stdout is redirected to `logFilePath` (FR-29); stderr is the
      same fd. Foreground mode is unchanged (logs to the inherited
      stderr).
  - `StopCommand` _(NEW — FR-26)_:
    - Flags: `--pid-file <path>` (default
      `~/.tool-agents/macrec/macrec.pid`, env `MACREC_PID_FILE`),
      `--stop-timeout <seconds>` (default 35, env
      `MACREC_STOP_TIMEOUT`).
    - `run() async throws`:
      1. Resolve `pidFilePath` via the standard four-source
         precedence chain.
      2. Read the file. If `ENOENT`: throw
         `MacrecError.noActiveRecording(pidFilePath)`.
      3. Parse the PID (single line, decimal integer, no trailing
         whitespace). On parse failure, treat as stale: remove the
         file and throw `MacrecError.staleRecording(pid: 0, path:
         pidFilePath)`.
      4. Probe the PID with `kill(pid, 0)`:
         - On `ESRCH` (no such process): remove the file, throw
           `MacrecError.staleRecording(pid: pid, path: pidFilePath)`.
         - On `EPERM` (process exists but we don't own it): treat
           as alive (we still try to send SIGTERM; if SIGTERM
           fails with `EPERM`, surface `MacrecError.unknown(...)`
           with the OS error).
         - On success: alive, proceed to step 5.
      5. Send `SIGTERM` to `pid`.
      6. Poll `kill(pid, 0)` every 100 ms for up to
         `stopTimeout` seconds. On `ESRCH`: process exited cleanly.
         Verify the PID file is gone (the daemon should remove it
         on shutdown — Phase J §11); if it's still there, remove
         it and log a warning ("daemon did not clean up its own
         PID file"). Exit 0.
      7. If the timeout fires before `kill(pid, 0)` returns
         `ESRCH`, throw `MacrecError.stopTimeout(pid: pid, seconds:
         stopTimeout)`.
    - `StopCommand` does NOT call `ToolAgentsBootstrap` permission
      gates and does NOT touch any TCC state — it only reads the
      PID file and sends a signal.
  - `ListDevicesCommand`:
    - Unchanged from v1.
  - `CheckPermissionsCommand`:
    - Unchanged from v1.
  - `PidFile` helper _(NEW)_:
    - `PidFile.write(pid: Int32, to: URL) throws` — atomic write via
      a `<path>.tmp` + `rename`; sets mode `0600` on the temp file
      before rename. Throws `MacrecError.pidFileWriteFailed(path:
      reason:)` on any error.
    - `PidFile.read(_ url: URL) throws -> Int32?` — returns nil on
      `ENOENT`; throws on parse error.
    - `PidFile.remove(_ url: URL)` — best-effort `unlink`; logs but
      does not throw on `ENOENT`.
    - `PidFile.isAlive(_ pid: Int32) -> AliveState` — three-way
      enum: `.alive | .stale | .unknown` (the third for `EPERM` —
      caller decides how to interpret).
  - `Daemonizer` helper _(NEW)_:
    - `Daemonizer.detach(logFilePath: URL) throws` — performs the
      double-fork sequence, returns only in the grandchild (parent
      and intermediate `_exit(0)` themselves).
    - Justification for choosing the **classic POSIX `fork()` +
      `setsid()` + `fork()` + `dup2()` sequence** over
      `posix_spawn` or `launchctl bootstrap`:
      1. **`posix_spawn` is one-shot** — it cannot run "the same
         binary as a child" without re-exec'ing it from disk and
         re-resolving every command-line flag, env var, and TCC
         state. We'd need to add an `--internal-detached-child`
         hidden flag and re-bootstrap the entire pipeline; that's
         brittle and security-surface-heavy.
      2. **`launchctl bootstrap` requires a `.plist` agent** —
         ergonomically wrong for a CLI tool the user invokes
         ad-hoc; it also drops us into the LaunchAgent
         lifecycle and out-of-process logging, which conflicts
         with FR-29's "log file at the user-specified path".
      3. **Classic double-fork** is well-understood, in-process,
         keeps every Swift framework reference live (no re-exec),
         and is exactly what the user's mental model expects
         ("`--detach` keeps recording in the background").
       Implementation imports `Darwin` for `fork`, `setsid`,
       `_exit`, `chdir`, `umask`, `dup2`, `close`, and uses
       `Foundation.FileHandle` only for the log fd.
- **Acceptance criteria**:
  - **AC-1**: `swift build` succeeds with zero warnings; no
    deprecation warnings (use `-warnings-as-errors` in CI later if
    desired).
  - **AC-2** & **AC-3**: covered by manual run in Phase 10.
  - **AC-16**: `swift run macrec start --detach --output /tmp/x.m4a`
    returns the prompt within 1 s; PID file appears at
    `~/.tool-agents/macrec/macrec.pid`; the PID is alive; the
    output file exists after `macrec stop`.
  - **AC-17**: `swift run macrec stop` against a live recording
    sends SIGTERM, waits for clean exit within 35 s, finalizes the
    file, removes the PID file. Exit 0.
  - **AC-18**: `rm -f ~/.tool-agents/macrec/macrec.pid && swift run
    macrec stop` exits with `MacrecError.noActiveRecording`'s exit
    code, prints the locked stderr message (see Phase C
    `MacrecError` table update), creates no PID file.
  - **AC-19**: Stale PID file (e.g. write `999999` to the PID file
    where no such PID exists) → `swift run macrec stop` removes
    the file and exits with `MacrecError.staleRecording`'s exit
    code (75 — see Phase C). Documented as informational; the user
    can rerun `start --detach` immediately.
  - **AC-20**: Two consecutive `swift run macrec start --detach
    --output ...` invocations: the second exits with
    `MacrecError.alreadyRecording`'s exit code (78); the first
    keeps recording.
  - `CLIArgumentParsingTests`: feeds `argv` arrays into
    `XxxCommand.parse(_:)` via `ParsableCommand.parseAsRoot`; asserts
    the parsed model, the default values for each flag, the error
    on `--output -` (rejected per OQ-5), and the new flags
    (`--detach`, `--pid-file`, `--log-file`, `--stop-timeout`).
  - `StopCommandTests`: simulates the four `stop` cases against an
    injectable `ProcessSignaler` fake (no real `kill` syscall in
    unit tests).
  - `PidFileTests`: round-trips PID file write/read; asserts mode
    `0600`; asserts atomic-rename behavior; asserts stale detection
    against a synthesized never-existed PID.
- **Dependencies**: Phase A, B, C, D, J.
- **Parallelizable with**: Phase J (interface-driven; both can mock
  each other). The Daemonizer / PidFile / StopCommand sub-modules
  are independent of J except for the PID file path constant
  (shared via `RecordingOptions` / direct config keys).
- **Effort**: M → **L** (1 day → 2 days; +1 day for daemonization,
  `stop`, `PidFile`, and their unit tests).
- **Risks**:
  - **R-14 — Double-fork done wrong → orphan/zombie process.** If
    the intermediate parent exits before the grandchild calls
    `setsid()`, the grandchild can inherit a controlling terminal
    and re-tie itself to the user's shell, causing the recording
    to die when the shell exits. Mitigation: strictly follow the
    `fork → setsid → fork → chdir → umask → dup2` order from
    Stevens APUE §13.3; cover with a `test_scripts/e2e-detach-
    orphan-check.sh` that invokes `start --detach`, exits the
    parent shell, and verifies the recording continues. Residual
    risk: medium — the test is platform-sensitive (macOS may
    handle SIGHUP differently).
  - Argument-parser still well-understood; minimal risk on the
    parser surface.

---

### Phase L — Documentation finalization

- **Goal**: Produce all required docs at the project's standard locations,
  satisfying AC-13, AC-14, AC-15, FR-16.
- **Files to finalize**:
  - `docs/tools/macrec.md` — XML-tagged tool documentation (FR-16
    format).
  - `CLAUDE.md` — append a `macrec` entry under the `## Tools`
    section with a one-line description and a relative link to
    `docs/tools/macrec.md`. **Do NOT duplicate** the full tool
    documentation in CLAUDE.md.
  - `docs/design/configuration-guide.md` — full configuration guide per
    the `<configuration-guide>` rules in CLAUDE.md.
  - `docs/design/project-design.md` — mirrors the locked design (refer
    to the pipeline diagram in §1 of this plan; expanded for Phase 5's
    designer-level detail).
  - `docs/design/project-functions.md` — already authored at the end
    of this Phase 4 (see the FR-update section §9 of this plan), but
    Phase L verifies it reflects FR-1..FR-16 plus any FRs added
    during phases B–K.
  - `Issues - Pending Items.md` — populate with every risk and
    follow-up surfaced by Phases A–K and §6 of this plan.
- **Acceptance criteria**:
  - **AC-13**: `docs/tools/macrec.md` exists with `<toolName>` /
    `<objective>` / `<command>` / `<info>` tags; `CLAUDE.md`'s
    `## Tools` section has the macrec entry pointing at it.
  - **AC-14**: `docs/design/project-design.md` and
    `docs/design/project-functions.md` exist and reflect the
    implementation.
  - **AC-15**: `Issues - Pending Items.md` exists at project root,
    pending items above completed items, ordered by criticality.
- **Dependencies**: Phases A through K (docs reflect the actual
  implementation).
- **Parallelizable with**: nothing (terminal phase).
- **Effort**: S (4 hours).
- **Risks**: minor wording inconsistency between CLAUDE.md and the
  tool doc; mitigated by reviewing both side-by-side.

---

## Section 3 — Files-to-modify matrix

> Each file is created by exactly one phase. "Finalized in" identifies
> the last phase that touches it. **No two phases finalize the same
> file**, so Phase 6 may dispatch them in parallel as long as the
> "Created in" phase has shipped.

| Path                                                                       | Created in | Finalized in |
|----------------------------------------------------------------------------|------------|--------------|
| `Package.swift`                                                            | A          | A            |
| `.gitignore`                                                               | A          | A            |
| `Issues - Pending Items.md`                                                | A          | L            |
| `Sources/macrec/main.swift`                                                | A          | K            |
| `Sources/macrec/Commands/RootCommand.swift`                                | A          | K            |
| `Sources/macrec/Commands/StartCommand.swift`                               | A          | K            |
| `Sources/macrec/Commands/StopCommand.swift`                                | K          | K            |
| `Sources/macrec/Commands/ListDevicesCommand.swift`                         | A          | K            |
| `Sources/macrec/Commands/CheckPermissionsCommand.swift`                    | A          | K            |
| `Sources/macrec/Daemonization/Daemonizer.swift`                            | K          | K            |
| `Sources/macrec/Daemonization/PidFile.swift`                               | K          | K            |
| `Sources/MacrecCore/Bootstrap/ToolAgentsBootstrap.swift`                   | A          | B            |
| `Sources/MacrecCore/Config/DotEnvParser.swift`                             | A          | B            |
| `Sources/MacrecCore/Config/ConfigResolver.swift`                           | A          | B            |
| `Sources/MacrecCore/Config/RecordingOptions.swift`                         | A          | B            |
| `Sources/MacrecCore/Logging/LoggerFactory.swift`                           | A          | C            |
| `Sources/MacrecCore/Errors/MacrecError.swift`                              | A          | C            |
| `Sources/MacrecCore/Permissions/PermissionGate.swift`                      | A          | D            |
| `Sources/MacrecCore/Permissions/ScreenRecordingPermission.swift`           | A          | D            |
| `Sources/MacrecCore/Permissions/MicrophonePermission.swift`                | A          | D            |
| `Sources/MacrecCore/Devices/AudioDeviceEnumerator.swift`                   | A          | D            |
| `Sources/MacrecCore/Capture/SystemAudioSource.swift`                       | A          | E            |
| `Sources/MacrecCore/Capture/MicrophoneSource.swift`                        | A          | E            |
| `Sources/MacrecCore/Capture/FakeAudioSource.swift`                         | A          | E            |
| `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift`                  | A          | I            |
| `Sources/MacrecCore/Capture/AVMicrophoneSource.swift`                      | A          | I            |
| `Sources/MacrecCore/Aligning/HostClockAligner.swift`                       | A          | F            |
| `Sources/MacrecCore/Aligning/SilenceBufferFactory.swift`                   | A          | F            |
| `Sources/MacrecCore/Mixing/BufferSummer.swift`                             | A          | F            |
| `Sources/MacrecCore/Encoding/Recorder.swift`                               | A          | G            |
| `Sources/MacrecCore/Encoding/M4ARecorder.swift`                            | A          | G            |
| `Sources/MacrecCore/Encoding/WAVRecorder.swift`                            | A          | H            |
| `Sources/MacrecCore/Encoding/CAFRecorder.swift`                            | A          | H            |
| `Sources/MacrecCore/Encoding/CMSampleBufferAudioConversion.swift`          | H          | H            |
| `Sources/MacrecCore/RecordingSession.swift`                                | A          | J            |
| `Sources/MacrecCore/SignalHandler.swift`                                   | A          | J            |
| `Tests/MacrecCoreTests/ConfigResolverTests.swift`                          | A          | B            |
| `Tests/MacrecCoreTests/DotEnvParserTests.swift`                            | A          | B            |
| `Tests/MacrecCoreTests/ToolAgentsBootstrapTests.swift`                     | A          | B            |
| `Tests/MacrecCoreTests/RecordingOptionsTests.swift`                        | A          | B            |
| `Tests/MacrecCoreTests/MacrecErrorTests.swift`                             | A          | C            |
| `Tests/MacrecCoreTests/PermissionDetectionTests.swift`                     | A          | D            |
| `Tests/MacrecCoreTests/AudioDeviceEnumeratorTests.swift`                   | A          | D            |
| `Tests/MacrecCoreTests/FakeAudioSourceTests.swift`                         | A          | E            |
| `Tests/MacrecCoreTests/HostClockAlignerTests.swift`                        | A          | F            |
| `Tests/MacrecCoreTests/SilenceBufferFactoryTests.swift`                    | A          | F            |
| `Tests/MacrecCoreTests/BufferSummerTests.swift`                            | A          | F            |
| `Tests/MacrecCoreTests/M4ARecorderTests.swift`                             | A          | G            |
| `Tests/MacrecCoreTests/WAVRecorderTests.swift`                             | A          | H            |
| `Tests/MacrecCoreTests/CAFRecorderTests.swift`                             | A          | H            |
| `Tests/MacrecCoreTests/SCKitSystemAudioSourceCompilationTest.swift`        | A          | I            |
| `Tests/MacrecCoreTests/AVMicrophoneSourceCompilationTest.swift`            | A          | I            |
| `Tests/MacrecCoreTests/RecordingSessionTests.swift`                        | A          | J            |
| `Tests/MacrecCoreTests/CLIArgumentParsingTests.swift`                      | A          | K            |
| `Tests/MacrecCoreTests/StopCommandTests.swift`                             | K          | K            |
| `Tests/MacrecCoreTests/PidFileTests.swift`                                 | K          | K            |
| `test_scripts/e2e-30s-mixed.sh`                                            | L          | L            |
| `test_scripts/e2e-60min-stability.sh`                                      | L          | L            |
| `test_scripts/e2e-sigint-finalize.sh`                                      | L          | L            |
| `test_scripts/e2e-layout-split.sh`                                         | L          | L            |
| `test_scripts/e2e-layout-stereo-split.sh`                                  | L          | L            |
| `test_scripts/e2e-detach-stop.sh`                                          | L          | L            |
| `test_scripts/e2e-detach-orphan-check.sh`                                  | L          | L            |
| `test_scripts/e2e-stop-stale.sh`                                           | L          | L            |
| `test_scripts/e2e-stop-already-recording.sh`                               | L          | L            |
| `docs/tools/macrec.md`                                                     | L          | L            |
| `docs/design/configuration-guide.md`                                       | L          | L            |
| `docs/design/project-design.md`                                            | L          | L            |
| `docs/design/project-functions.md`                                         | (Phase 4)  | L            |
| `docs/design/plan-001-recording-tool.md` (this file)                       | (Phase 4)  | (Phase 4)    |
| `CLAUDE.md` (append `## Tools` entry only)                                 | _existing_ | L            |

Notes:
- "Created in A" means Phase A creates an empty stub. The first phase
  that puts real code in the file is the "Finalized in" phase.
- Phase L is the only phase allowed to write into `CLAUDE.md`. The edit
  is strictly additive: append a single bullet under the existing
  `## Tools` section. Do not modify the `<structure-and-conventions>`
  block or `Exception 001`.

---

## Section 4 — Parallelization map

Phase 6 will run these as parallel implementation units. Each set is
a "wave"; every phase in a wave can run concurrently with the others
in the same wave once the prior wave is complete.

```
Wave 1 — sequential, single phase:
    Phase A   (SPM scaffold + project skeleton)

Wave 2 — fan-out (4 parallel coders):
    Phase B   (Bootstrap + Config)
    Phase C   (Logging + Errors)
    Phase D   (Permissions + Devices)
    Phase E   (Capture protocols + fakes)

Wave 3 — fan-out (3 parallel coders):
    Phase F   (HostClockAligner + SilenceBufferFactory + BufferSummer)
              [needs B, C, E]
    Phase G   (Recorder protocol + M4ARecorder)
              [needs C, F]   ← wait for F before starting
    Phase H   (WAV + CAFRecorder)
              [needs C, F]   ← wait for F before starting

    (G and H run in parallel after F finishes; F starts in parallel
     with the other Wave 3 work that doesn't depend on it. In
     practice Wave 3 splits into 3a (F alone) and 3b (G || H).)

Wave 4 — fan-out (2 parallel coders):
    Phase I   (SCKitSystemAudioSource + AVMicrophoneSource)
              [needs C, D, E]
    Phase J   (RecordingSession orchestrator)
              [needs B, C, D, E, F, G, H]
              ← Phase J starts when G and H are done; can run in
                parallel with Phase I

Wave 5 — sequential:
    Phase K   (CLI shell — now includes `stop` subcommand,
               `--detach` flag, Daemonizer, PidFile per FR-25..FR-29)
              [needs B, C, D, J]
              ← waits for J; can overlap with the tail of I.
              ← Scope grew on 2026-04-26: effort revised M → L
                (added daemonization + stop + PidFile + tests).
              ← Dependency surface unchanged.

Wave 6 — sequential, terminal:
    Phase L   (Documentation finalization — now includes 4 new
               detach/stop test scripts)
              [needs all of A–K]
```

**Critical path**: A → (B || C || D || E) → F → (G || H) → J → K → L.
Phase K's expanded scope does NOT add new critical-path dependencies —
the Daemonizer / PidFile / StopCommand sub-modules build on top of the
existing Phase B (config keys) and Phase J (PID file lifecycle hook in
RecordingSession) outputs.

---

## Section 5 — Acceptance-criteria → phase map

> Phase 10 (Integration Verifier) checks every AC; this table tells the
> verifier where the implementation that satisfies each AC lives.

| AC     | Statement (abridged)                                                 | Owning phase(s)         |
|--------|----------------------------------------------------------------------|-------------------------|
| AC-1   | `swift build` succeeds with no warnings on macOS 14+                 | A, K, L                 |
| AC-2   | `check-permissions` prints state, exit 0 if granted else non-zero    | D, K                    |
| AC-3   | `list-devices` prints built-in mic with name & UID                   | D, K                    |
| AC-4   | 30 s recording mixed produces playable m4a, ±0.5 s, AAC 192 kbps     | F, G, I, J, K           |
| AC-5   | `--layout split` produces two files with documented suffixes         | G or H, J, K            |
| AC-6   | `--layout stereo-split` puts mic on L, system on R                   | F, G or H, J, K         |
| AC-7   | SIGINT finalizes a playable file (no truncated atom errors)          | G, J                    |
| AC-8   | Denying screen recording → exit non-zero, no partial output file     | C, D, J, K              |
| AC-9   | Configuration precedence (CLI > local .env > user .env > shell)      | B                       |
| AC-10  | Removing `~/.tool-agents/macrec/` → recreated 0700, .env at 0600     | B                       |
| AC-11  | 60-minute recording within ±1 s, no audible discontinuities          | F (drift), I (watchdog), J |
| AC-12  | A/V drift ±20 ms across 60 minutes                                   | F, I, J                 |
| AC-13  | `docs/tools/macrec.md` exists in XML format; CLAUDE.md links it      | L                       |
| AC-14  | `project-design.md` & `project-functions.md` exist & match impl      | L (`project-functions.md` seeded in Phase 4) |
| AC-15  | `Issues - Pending Items.md` exists with documented format            | A (skeleton), L (populate) |
| AC-16  | `start --detach` returns prompt < 1 s; PID file present; live PID    | J (PID write), K (Daemonizer + StartCommand --detach path), L (e2e-detach-stop.sh) |
| AC-17  | `stop` against live process: SIGTERM, clean exit ≤ 35 s, file removed | J (PID remove), K (StopCommand), L (e2e-detach-stop.sh) |
| AC-18  | `stop` with no PID file → `noActiveRecording` error                  | C (error case), K (StopCommand), L (e2e-stop-stale.sh covers also this case) |
| AC-19  | `stop` with stale PID file → cleanup + `staleRecording` (exit 75)    | C (error case), K (StopCommand), L (e2e-stop-stale.sh) |
| AC-20  | Second `start --detach` → `alreadyRecording`                          | C (error case), K (StartCommand FR-28 guard), L (e2e-stop-already-recording.sh) |

---

## Section 6 — Dependencies and risk register

### SPM dependencies (locked)

| # | Package                                | Version       | License     | Why                                            |
|---|----------------------------------------|---------------|-------------|------------------------------------------------|
| 1 | `apple/swift-argument-parser`          | `from: "1.5.0"` | Apache-2.0 | CLI subcommands, flags, help, async support    |
| 2 | `apple/swift-log`                      | `from: "1.5.4"` | Apache-2.0 | Levelled logging to stderr; `--log-level` map  |

No third-party non-Apple dependencies. All audio capture, mixing,
encoding, and configuration logic is built on first-party Apple
frameworks (`ScreenCaptureKit`, `AVFoundation`, `CoreAudio`,
`AudioToolbox`, `CoreMedia`, `Foundation`).

### Risk register

| #   | Risk                                                                       | Mitigation                                                                                                                                       | Owner phase | Residual risk |
|-----|----------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|-------------|---------------|
| R-1 | `replayd` silent-stop bug: `SCStream` stops delivering buffers, no callback | Buffer-arrival watchdog (5 s poll, 10 s staleness), full-restart with new `SCStream` instance, max-3-restarts-in-60 s fatal cap; `Task { }` wrap of `didStopWithError` to dodge `EXC_BAD_ACCESS`. Verbatim from research §3. | I           | Medium — heuristic threshold |
| R-2 | TCC ad-hoc-signing instability: developer rebuilds re-prompt every time     | Document in `docs/tools/macrec.md` troubleshooting section: `tccutil reset ScreenCapture`, `tccutil reset Microphone`. No runtime mitigation possible. | L           | Low (DX only) |
| R-3 | Output device change mid-recording: behavior undefined                      | Spec clarification: "captures the submix of the default output device at start time; changing output devices during recording is unsupported." Document in tool doc; consider mid-recording output-device-change detection in v2. | L           | Low |
| R-4 | AAC bitrate validation: FR-8 doesn't bound the range                        | `RecordingOptions` validates `bitrate ∈ [64, 320]`; reject outside range with `EX_USAGE`. | B           | None |
| R-5 | No CI for E2E TCC tests: AC-4..AC-12 must be manual                         | Provide `test_scripts/e2e-*.sh` so the manual procedure is repeatable; document in `docs/tools/macrec.md`. | L           | Acknowledged (NFR-10) |
| R-6 | `finishWriting` timeout on 60-minute file                                   | 30-second `DispatchWorkItem` watchdog; on fire, exit 2 with stderr message naming the partial file. Phase 10 measures actual duration in `e2e-60min-stability.sh`. | G, J        | Low — research estimates 2–8 s on Apple Silicon |
| R-7 | macOS 26.x (Tahoe) plain-binary TCC listing regression                       | Document as known UX limitation; recommend `.app` wrapper for permission management UX. No runtime mitigation. | L           | Low (cosmetic) |
| R-8 | `movieFragmentInterval` × `shouldOptimizeForNetworkUse` interaction unverified | Phase 10 verification step: `afinfo` and `mp4info` on a recorded file confirm atom order and priming. If interaction is broken, drop fragmentation and rely on moov-at-front alone. | G, Phase 10 | Low |
| R-9 | Bluetooth output route can mute system submix in rare configs               | Out of our control (assumption A-4 in refined request). Document in `Issues - Pending Items.md` and tool doc troubleshooting. | L           | Acknowledged |
| R-10 | "Uptime PTS trap": absolute host-time PTSs make file timeline non-zero      | Adopt research recommendation: `startSession(atSourceTime: CMClock.hostTimeClock.time)` captured at `RecordingSession.start()`; aligner produces buffers in same domain. QuickTime shows non-zero start offset; duration & sync correctness preserved. | F, G, J | Documented; revisit if downstream phases need t=0 |
| R-11 | Empty `excludingApplications` filter on macOS 12.x: callback never fires    | Out of scope (we're on macOS 14+). | _none_ | None |
| R-12 | Mic delivers AirPods 24 kHz native: resampler must handle 24 → 48 kHz       | Long-lived `AVAudioConverter` per source (research §3.5); never recreate per buffer. | F, J | Low |
| R-13 | Recording during system sleep: SCStream stops delivering, watchdog tries to restart, can't | Listen for `NSWorkspace.willSleepNotification` / `didWakeNotification`; on wake, reset `lastBufferArrival` baseline so watchdog doesn't insta-fire. (Stretch goal — flag in Issues doc if not implemented in v1.) | I | Medium |
| R-14 | Double-fork done wrong → orphan/zombie process | Strictly follow Stevens APUE §13.3 sequence: `fork → setsid → fork → chdir("/") → umask(0) → close(stdin), dup2(logFd, stdout), dup2(logFd, stderr)`. The intermediate parent MUST `_exit(0)` (NOT `exit(0)` — avoids running atexit handlers that would flush the parent's logger to a now-redirected fd). Cover with `test_scripts/e2e-detach-orphan-check.sh`: invoke `start --detach`, exit the parent shell, sleep 5 s, verify the recording PID is still alive, `stop`, verify the file is finalized. | K | Medium — test is platform-sensitive (macOS SIGHUP / launchd interaction); residual risk acknowledged in Issues - Pending Items.md |
| R-15 | Stale PID race: `start --detach` fires while a previous PID file exists for a stale PID | The new `start --detach` invocation refuses if the PID is alive (FR-28); if stale, removes the file and continues. Covered by AC-20 and `test_scripts/e2e-stop-already-recording.sh`. Residual risk: a fast TOCTOU window between `kill(pid, 0)` returning ESRCH and our PID write — mitigated by atomic `<path>.tmp + rename` in `PidFile.write`. | K | Low |
| R-16 | `stop` timeout too aggressive on slow-disk finalize (large m4a + 35 s) | Configurable via `--stop-timeout` (FR-26 default 35); user can pass a longer value. Phase 10 `test_scripts/e2e-detach-stop.sh` measures actual finalize time in detach mode and tunes the default if needed. | K, Phase 10 | Low |

---

## Section 7 — Verification checklist (Phase 10)

### Build & test (automated)

```sh
# 1. Clean build, zero warnings.
cd /Users/giorgosmarinos/aiwork/coding-platform/recording-tool
swift package clean
swift build -c release 2>&1 | tee build.log
test ! -s <(grep -E '(warning|error)' build.log)   # AC-1

# 2. All unit tests pass.
swift test 2>&1 | tee test.log
grep -q "Test Suite 'All tests' passed" test.log
```

### Manual E2E (cannot be automated due to TCC)

Each script in `test_scripts/` is a thin wrapper around `swift run`
that the developer executes manually after granting Screen Recording
+ Microphone permissions to the binary.

```sh
# 3. 30-second mixed recording with mic + speaker audio (AC-4).
./test_scripts/e2e-30s-mixed.sh
afinfo ~/recordings/test.m4a   # expect: stereo, 48000 Hz, AAC, ~192 kbps,
                                #         duration 30 s ±0.5 s, "optimized"

# 4. 60-minute stability run (AC-11, AC-12, NFR-3).
./test_scripts/e2e-60min-stability.sh
afinfo ~/recordings/long.m4a   # expect: ~3600 s ±1 s, no truncation
# Listen to three random 30-s windows: no audible discontinuities.

# 5. SIGINT-during-recording finalization test (AC-7).
./test_scripts/e2e-sigint-finalize.sh
# Script starts a recording, sleeps 5 s, sends SIGINT, waits for exit,
# confirms exit code 0 and the file plays in QuickTime.

# 6. Layout split (AC-5).
./test_scripts/e2e-layout-split.sh
ls ~/recordings/test.{mic,system}.m4a  # both exist, similar duration

# 7. Layout stereo-split (AC-6).
./test_scripts/e2e-layout-stereo-split.sh
# Open in Audacity; visually confirm channel L = mic only,
# channel R = system audio only.
```

### Configuration & docs (automated where possible)

```sh
# 8. Config precedence (AC-9).
rm -f ./.env ~/.tool-agents/macrec/.env
echo "OUTPUT_PATH=/tmp/from-shell.m4a"        > /tmp/shell.env
echo "OUTPUT_PATH=/tmp/from-user.m4a"          > ~/.tool-agents/macrec/.env
echo "OUTPUT_PATH=/tmp/from-local.m4a"         > ./.env
swift run macrec start --output /tmp/from-cli.m4a --max-duration 1
test -f /tmp/from-cli.m4a   # CLI wins
swift run macrec start --max-duration 1
test -f /tmp/from-local.m4a  # local .env wins over user .env

# 9. Bootstrap (AC-10).
rm -rf ~/.tool-agents/macrec
swift run macrec list-devices
test -d ~/.tool-agents/macrec
test "$(stat -f '%A' ~/.tool-agents/macrec)" = "700"
test -f ~/.tool-agents/macrec/.env
test "$(stat -f '%A' ~/.tool-agents/macrec/.env)" = "600"

# 10. Permission denied (AC-8).
# Manual: revoke Screen Recording in System Settings, then:
swift run macrec start --output /tmp/should-fail.m4a
echo $?   # expect 77 (EX_NOPERM)
test ! -f /tmp/should-fail.m4a   # no partial file

# 11. Docs (AC-13, AC-14, AC-15).
test -f docs/tools/macrec.md
grep -q "<toolName>" docs/tools/macrec.md
grep -q "macrec" CLAUDE.md   # entry in Tools section
test -f docs/design/project-design.md
test -f docs/design/project-functions.md
test -f "Issues - Pending Items.md"
```

### Final gate

The Integration Verifier (Phase 10) declares the task complete only when
every step above exits 0 (or, for manual steps, the developer
explicitly affirms the audible / visual check). Any failure routes back
to the corresponding phase via the `Issues - Pending Items.md` entry.

---

## Section 8 — Open questions for the user

### Refined-request OQs (recommended defaults locked into this plan)

| OQ    | Question                                                  | Locked default                          | Action at design checkpoint (Phase 5) |
|-------|-----------------------------------------------------------|-----------------------------------------|---------------------------------------|
| OQ-1  | Minimum macOS target: 13.0 vs 14.0+?                      | **macOS 14.0+**                         | Confirm or override                   |
| OQ-2  | CLI binary name (`macrec` / `audiorec` / `recorder` / `dualrec`) | **`macrec`**                            | Confirm or override                   |
| OQ-3  | Single-process foreground vs daemon for `stop`            | **OVERRIDDEN 2026-04-26**: foreground (default) + `--detach` background mode + `stop` subcommand. See FR-25..FR-29 and design §14. | _resolved — no further action_ |
| OQ-4  | Intel (x86_64) support                                    | **Universal binary**                    | Confirm or override                   |
| OQ-5  | Output to stdout (`--output -`)                            | **Not in v1; rejected by parser**       | Confirm or override                   |
| OQ-6  | Default track layout                                      | **`mixed`**                             | Confirm or override                   |
| OQ-7  | Default output format                                     | **`m4a`**                               | Confirm or override                   |
| OQ-8  | Mic device selection by name vs UID                       | **Either; case-insensitive name; UID always wins; warn on multi-match** | Confirm or override |
| OQ-9  | Behavior when system audio is silent                       | **Per-source RMS log every 10 s at debug level** | Confirm or override                   |
| OQ-10 | Required vs optional config values                        | **Required: `--output` only. Defaultable: everything else per FR-7..FR-9 defaults** | Confirm or override |

### Research-doc follow-up questions (verbatim, with recommended answers)

#### From `docs/research/scstream-audio-only.md` §8

1. **OI-1 — Minimum reliable `width`/`height` value.**
   *Recommended answer*: ship with `2`/`2` (Azayaka-validated); fall back to
   `32`/`32` if a stream initialization failure is observed during Phase 10
   testing.
2. **OI-2 — `CMTimeScale.max` vs `CMTime(value:1, timescale:1)` stability.**
   *Recommended answer*: ship with `CMTimeScale.max` (cleaner — no video
   frames generated); validate during the Phase-10 60-minute run; fall
   back to 1 fps if any audio-callback regressions are observed.
3. **OI-3 — Watchdog restart count limit.**
   *Recommended answer*: ship with "3 restarts in 60 s = fatal" as a
   private constant in `SCKitSystemAudioSource`; revisit after field
   testing.

#### From `docs/research/avassetwriter-aac.md` §7

1. **7.1 — Priming with `.zero` session start vs host-clock session start.**
   *Recommended answer*: ship with host-clock session start (avoids
   per-buffer retiming allocations). The downstream transcription /
   analysis pipeline (future phase) is expected to be timeline-agnostic
   (it will consume the file's audio, not its absolute PTSs); flag as
   open if that assumption is violated.
2. **7.2 — `movieFragmentInterval` + `shouldOptimizeForNetworkUse` interaction.**
   *Recommended answer*: ship with both enabled; Phase 10 verifies via
   `afinfo` and `mp4info` that the atom order and priming are as
   documented. If broken, drop `movieFragmentInterval`.
3. **7.4 — `finishWriting` duration for 60-minute file.**
   *Recommended answer*: ship with 30-second timeout; Phase 10 measures
   actual duration in `e2e-60min-stability.sh` and tunes if needed.

These six items become entries in `Issues - Pending Items.md` with the
"validate during Phase 10" disposition.

---

## Section 9 — Functional-requirements update for `docs/design/project-functions.md`

Phase 4 (this plan) writes `docs/design/project-functions.md` immediately
alongside this plan. The file:

- Carries forward FR-1..FR-16 verbatim from the refined request.
- Adds the planning-derived FRs uncovered by this plan:
  - **FR-17 — Configuration value validation (Phase B).** Each
    configuration value must be range-validated at parse time;
    out-of-range values fail with `EX_USAGE`. Locked ranges: sample-rate
    ∈ {44100, 48000}; bit-depth ∈ {16, 24}; bitrate ∈ [64, 320]; layout
    ∈ {mixed, split, stereo-split}; format ∈ {m4a, wav, caf}; mic-channel
    ∈ {left, right}; max-duration > 0.
  - **FR-18 — Documented exit-code table (Phase C).** Every error
    path returns one of: 0 success, 1 generic error, 2 partial output,
    64 usage, 66 I/O, 70 software runtime, 75 temp-fail (permission
    not-determined), 77 no-perm (permission denied), 78 config error.
  - **FR-19 — Watchdog-driven SCStream restart (Phase I).** The system
    audio source must monitor buffer arrival staleness (5 s poll,
    10 s threshold) and restart the stream on stall; > 3 restarts in
    60 s is fatal.
  - **FR-20 — `finishWriting` timeout (Phase G/J).** Finalization must
    abort and exit 2 if the writer's `finishWriting` does not complete
    within 30 seconds.
  - **FR-21 — Crash-resilient AAC (Phase G).** The m4a writer must
    enable `shouldOptimizeForNetworkUse = true` and
    `movieFragmentInterval = CMTime(value: 2, timescale: 1)` so a hard
    kill leaves a recoverable file.
  - **FR-22 — Host-clock synchronization for AVCapture (Phase I).**
    The microphone capture session must set
    `synchronizationClock = CMClockGetHostTimeClock()` so its PTSs are
    directly comparable with SCStream PTSs (NFR-4 enforcement).
  - **FR-23 — Per-source RMS heartbeat (Phase J, OQ-9).** When
    `--log-level debug` is active, log per-source RMS every 10 s so a
    silent stream (capture failure vs legitimate silence) is
    distinguishable in debug logs.
  - **FR-24 — Output overwrite gate (FR-15 elaborated, Phase B).**
    The output path's parent directory must exist (no implicit mkdir);
    if the file exists, refuse unless `--overwrite` is passed; for
    `split` layout, both per-source paths are checked.
  - **FR-25 — Detach mode (Phase K, OQ-3 override 2026-04-26).** When
    `--detach` is passed to `start`, the tool MUST double-fork, write
    its PID to `~/.tool-agents/macrec/macrec.pid` (or the path
    resolved via `--pid-file` / `MACREC_PID_FILE`), redirect
    stdout/stderr to `~/.tool-agents/macrec/macrec.log` (mode 0600,
    append), and the parent process MUST exit 0 immediately while
    recording continues in the detached child.
  - **FR-26 — `stop` subcommand (Phase K, OQ-3 override).** The CLI
    MUST expose a `stop` subcommand that reads the PID file and sends
    SIGTERM to the running process, waiting up to `--stop-timeout`
    seconds (default 35) for clean shutdown. Behavior MUST distinguish
    between (a) no PID file present, (b) PID file present but process
    gone (stale), (c) process alive and stopped cleanly, (d) process
    alive but did not exit within timeout.
  - **FR-27 — PID file lifecycle (Phase J, OQ-3 override).** The
    detached process MUST remove its own PID file on every clean
    exit path (SIGINT, SIGTERM, max-duration cap, normal finalize).
    It MUST NOT remove the PID file on crash; subsequent `stop` calls
    detect and clean up stale files.
  - **FR-28 — Already-recording guard (Phase K, OQ-3 override).** A
    `start --detach` invocation MUST refuse to start if the resolved
    PID file is present and references a live process; it MUST exit
    with a descriptive error naming the conflicting PID. Foreground
    `start` (no `--detach`) is exempt from this check.
  - **FR-29 — Detach log file (Phase K, OQ-3 override).** In detach
    mode, all logs MUST go to `~/.tool-agents/macrec/macrec.log` at
    mode 0600, append-mode. The path is configurable via `--log-file`
    / env var `MACREC_LOG_FILE`. Foreground mode logs to stderr
    unchanged.

The full FR list (FR-1..FR-29) is materialized in
`docs/design/project-functions.md` alongside this plan.

---

## Appendix — Phase-6 dispatch quick reference

For each phase, a Phase-6 coder needs exactly:
1. The "Files to finalize" list from §2.
2. The "Detailed contracts" sub-section from §2.
3. The corresponding research-doc section references in §2 ("verbatim
   from research §X").
4. The acceptance-criteria block from §2.
5. The `Issues - Pending Items.md` entries assigned to the phase by §6.

No phase requires re-reading the investigation or research documents
end-to-end — every load-bearing recipe has been transcluded into this
plan with a doc-section citation for traceability.
