---
language: swift
framework: none
package_manager: swift-package-manager
build_command: "swift build"
test_command: "swift test"
lint_command: null
entry_points:
  - Sources/macrec/main.swift
  - Sources/MacrecCore/RecordingSession.swift
last_scanned_commit: null
scanned_for_request: refined-request-toolbar-ui.md
scanned_at: "2026-04-26T00:00:00Z"
---

# Codebase Scan — macrec (toolbar-ui narrowing)

## 1. Project Overview

Swift package targeting macOS 14+, managed entirely by Swift Package Manager. Two
products: an `executableTarget` named `macrec` (CLI) and a `.library` named
`MacrecCore` (the shared engine). The library is the sole integration point for
the new `macrec-ui` executable target. External dependencies are
`swift-argument-parser 1.5.x` and `swift-log 1.5.x`; both are in `Package.resolved`.
The codebase uses `async/await` with `DispatchQueue`-confined mutable state
(Swift 5.9 / `@unchecked Sendable`) throughout. There is no git history (the
working tree is not a git repo).

## 2. Module Map

| Path | Purpose | Representative symbols |
|------|---------|----------------------|
| `Sources/macrec/main.swift` | CLI process entry — dispatches to `RootCommand` | `asyncMainEntry`, `RootCommand.main` |
| `Sources/macrec/Commands/` | ArgumentParser subcommands | `StartCommand`, `StopCommand`, `CheckPermissionsCommand`, `ListDevicesCommand`, `RootCommand` |
| `Sources/MacrecCore/RecordingSession.swift` | Top-level session orchestrator — the primary UI driver | `RecordingSession`, `StopReason`, `Stats` |
| `Sources/MacrecCore/Config/` | 4-tier config resolution and options value type | `ConfigResolver`, `RecordingOptions`, `OutputFormat`, `TrackLayout`, `StereoChannel`, `RunMode`, `LogLevel` |
| `Sources/MacrecCore/Errors/` | Typed error enum with exit codes and stderr messages | `MacrecError` (26 cases) |
| `Sources/MacrecCore/Capture/` | System-audio and microphone capture sources | `SCKitSystemAudioSource`, `AVMicrophoneSource`, `SystemAudioSource` (protocol), `MicrophoneSource` (protocol), `CaptureBuffer`, `FakeAudioSource` |
| `Sources/MacrecCore/Aligning/` | Host-clock alignment and gap-fill | `HostClockAligner`, `AlignedFrame`, `SilenceBufferFactory` |
| `Sources/MacrecCore/Encoding/` | Recorder protocol and format implementations | `Recorder` (protocol), `M4ARecorder`, `WAVRecorder`, `CAFRecorder`, `makeRecorder` (factory) |
| `Sources/MacrecCore/Mixing/` | Per-frame stereo mixing | `BufferSummer` |
| `Sources/MacrecCore/Permissions/` | TCC gate and per-permission types | `PermissionGate`, `ScreenRecordingPermission`, `MicrophonePermission` |
| `Sources/MacrecCore/Devices/` | CoreAudio HAL device enumeration | `AudioDeviceEnumerator`, `AudioInputDevice` |
| `Sources/MacrecCore/Logging/` | swift-log bootstrap and factory | `LoggerFactory` |
| `Sources/MacrecCore/Bootstrap/` | `~/.tool-agents/<name>/` directory creation | `ToolAgentsBootstrap` |
| `Sources/MacrecCore/Daemon/` | Double-fork daemonizer and PID file | `Daemonizer`, `PidFile` |
| `Tests/MacrecCoreTests/` | Unit + integration tests (swift-testing framework) | 19 test files — see §5 for ISSUE-02 blocker |
| `Resources/Info.plist` | Embedded Info.plist for TCC usage strings and bundle id | `CFBundleIdentifier=com.local.macrec` |

## 3. Conventions

- **Error handling** (`Sources/MacrecCore/Errors/MacrecError.swift:18`): all
  public API surfaces throw `MacrecError`, a single typed enum with 26 cases.
  Exit codes are locked (design §9.5). No fallback values are substituted for
  missing configuration — `missingRequiredConfig` is always thrown. The UI must
  catch `MacrecError` and present it via the `description` + `remediation` pair;
  it MUST NOT introduce a parallel error type.

- **Logging** (`Sources/MacrecCore/Logging/LoggerFactory.swift:67`): every
  component receives a `Logger` from `LoggerFactory.make("macrec.<subsystem>")`.
  `LoggerFactory.bootstrap(level:)` is idempotent and must be called once at
  process start. The UI must call `bootstrap` early in its `@main` / `App.init`
  and pass loggers under the `macrec.ui.*` prefix namespace.

- **Config resolution** (`Sources/MacrecCore/Config/ConfigResolver.swift:82`):
  `ConfigResolver(toolName:).resolve(cliOverrides:)` merges four sources
  (shell env > user `.env` > local `.env` > CLI flags) and returns a
  `RecordingOptions`. The UI does NOT use this chain for its own persistent
  state (format, folder, device) — those are `UserDefaults`-backed UI state
  (FR-36/FR-38) — but it MUST call `ConfigResolver` with `toolName: "macrec"`
  to produce the `RecordingOptions` that is passed to `RecordingSession`.

- **Concurrency** (`Sources/MacrecCore/RecordingSession.swift:88`): the
  session is `@unchecked Sendable` with all mutable state confined to a private
  `DispatchQueue(label: "macrec.session.serial")`. Public mutation (`requestStop`)
  posts asynchronously onto the serial queue. The pattern is consistent
  throughout: each subsystem owns one `stateQueue` serial queue; the audio
  delivery queues are separate `userInteractive` queues. The UI must adopt the
  same model — no shared mutable state without queue confinement or actor
  isolation.

- **Import style** (`Sources/macrec/Commands/StartCommand.swift:31`): named
  imports only (`import ArgumentParser`, `import MacrecCore`). No namespace
  imports or `@_implementationOnly`. Type names are PascalCase; methods
  camelCase; one type per file; file name matches the primary type.

- **No fallback configuration**
  (`Sources/MacrecCore/Config/ConfigResolver.swift:97`): every required field
  that cannot be resolved from any of the four sources throws
  `MacrecError.missingRequiredConfig`. Optional fields use Swift `Optional`
  with explicit `nil` semantics. This rule is enforced uniformly — there are no
  silent defaults substituted at a lower level.

## 4. Integration Points

### 4.1 In-Scope — Existing API the UI drives directly

#### `RecordingSession` — primary driver (`Sources/MacrecCore/RecordingSession.swift`)

| Aspect | Details |
|--------|---------|
| `init` signature | `init(options: RecordingOptions, logger: Logger? = nil, systemSource: (any SystemAudioSource)? = nil, micSource: (any MicrophoneSource)? = nil)` — line 175 |
| Public methods (current) | `run() async throws` (line 231), `requestStop()` (line 218), `isRunning: Bool` (line 192), `stats: Stats` (line 200) |
| Lifecycle | `init` → `run()` blocks until stopped → returns (throws on error). `requestStop()` is the programmatic stop signal; SIGINT/SIGTERM also resolve it. |
| State surface (current) | **None** — no publisher, no state enum, no observer. The UI must poll `isRunning` (unreliable for UI) or subscribe to nothing. |
| **New APIs required** | `pause() async throws`, `resume() async throws`, `split() async throws`, `SessionState` observable (FR-31/32/33). These do NOT exist today. |
| Stop-and-stitch architecture | Pause = `requestStop()` equivalent on the current segment + start a new `RecordingSession` for the resumed segment; stitch is handled at the filename level (FR-34). The session itself has no concept of segments today. |
| Fit point for `SessionState` | The `serialQueue` block at line 349 (`_running = true`) and the `resolveRunLoop` method at line 513 are the two state-transition nodes. An `AsyncStream<SessionState>` continuation can be stored alongside `_runContinuation` and emitted from each transition. |
| Fit point for `pause()`/`resume()` | A `pause()` method can call `resolveRunLoop(reason: .programmatic, ...)` to finalize the current segment, then `resume()` can construct and `run()` a new session with a `partNN`-suffixed output URL. The session itself needs no new fields — the UI controller coordinates the sequence. |
| Fit point for `split()` | Per FR-32 the encoder rotates while sources stay alive. This requires new lifecycle hooks inside `M4ARecorder.finalize` + `start` without tearing down `SCKitSystemAudioSource`/`AVMicrophoneSource`. The `RecordingSession` would need a `split()` async method that: (a) drains `HostClockAligner`, (b) calls `recorder.finalize`, (c) installs a new `Recorder` with the next `partNN` URL, (d) calls `recorder.start()`, (e) re-wires `aligner.onAlignedFrame`. |

#### `RecordingOptions` — value type the UI constructs (`Sources/MacrecCore/Config/RecordingOptions.swift`)

All fields are `public let`. The UI constructs this with:

- `output`: resolved from the FR-35 filename field + FR-36 folder picker. No
  `ConfigResolver` chain involved for the output path — the UI owns this.
- `format`, `layout`, `micChannel`: from FR-38 dropdowns.
- `micDevice`: from FR-39 dropdown (pass UID string or `nil`).
- `runMode`: always `.foreground` for the UI (the UI never daemonizes).
- `sampleRate`, `bitDepth`, `bitrate`: UI can expose or use hardcoded defaults.
- `maxDuration`: `nil` (UI uses Stop button, not a timer cap).
- `overwrite`: `false` initially; UI may offer a confirm dialog.
- `pidFile`, `logFile`: `RecordingOptions.defaultPidFile` / `defaultLogFile`
  (foreground mode never writes PID file, so these are irrelevant).

#### `ConfigResolver.Keys` — env-var key namespace (`Sources/MacrecCore/Config/ConfigResolver.swift:235`)

The UI does NOT call `ConfigResolver.resolve(cliOverrides:)` for its own
persistent format/folder/device preferences. Those live in `UserDefaults`.
However, `ConfigResolver(toolName: "macrec")` is still needed if the UI wants
to pick up `.env`-configured defaults for non-UI fields (sampleRate, bitrate,
etc.). Decision: the UI can call `ConfigResolver` with an empty `cliOverrides`
and let the user's `.env` supply audio encoding defaults, or hard-code them. The
UI MUST NOT skip `ToolAgentsBootstrap.ensure(toolName: "macrec")` — the session
calls it internally (line 234), so the UI doesn't need to call it separately.

#### `PermissionGate` (`Sources/MacrecCore/Permissions/PermissionGate.swift`)

- `PermissionGate().snapshot() async -> Snapshot` — line 53 — returns
  `Snapshot(screenRecording:, microphone:)` without prompting. Use this for
  FR-37 polling on a 2 s timer while the popover is visible.
- `PermissionGate.Snapshot.bothAuthorized: Bool` — line 41 — drives the
  Start button enabled state.
- `requireBothOrThrow()` — line 73 — is called inside `RecordingSession.run()`
  already. The UI should additionally call `snapshot()` separately for the
  indicator, and NOT call `requireBothOrThrow()` from the UI layer directly
  (the session handles it).
- `ScreenRecordingPermission.State` and `MicrophonePermission.State` are the
  per-source enums. Their `authorized / denied / notDetermined` cases map
  directly to FR-37's three visual states.

#### `AudioDeviceEnumerator` (`Sources/MacrecCore/Devices/AudioDeviceEnumerator.swift`)

- `AudioDeviceEnumerator.listInputs() throws -> [AudioInputDevice]` — line 34 —
  powers FR-39 dropdown. Returns `name`, `uid`, `sampleRateRange`,
  `channelCount`.
- `AudioInputDevice.uid` is the stable identifier to persist in `UserDefaults`
  (per FR-39 / OQ-8). Persist by UID, match back by UID on relaunch, fall back
  to system default if UID not found.
- Refresh on `AVCaptureDeviceWasConnectedNotification` /
  `AVCaptureDeviceWasDisconnectedNotification` — call `listInputs()` on the
  main actor.

#### `MacrecError` (`Sources/MacrecCore/Errors/MacrecError.swift`)

The UI's only error presentation layer: catch `MacrecError`, read `.description`
for the banner/toast title and `.remediation` for the detail. The `exitCode`
is CLI-only and not relevant to the UI. Do NOT throw or create new `MacrecError`
cases in the UI layer for UI-specific failures (e.g., UserDefaults unreadable);
use Swift `Error` subtypes scoped to the UI module, or surface as non-fatal UI
warnings.

#### `LoggerFactory` (`Sources/MacrecCore/Logging/LoggerFactory.swift`)

- `LoggerFactory.bootstrap(level:)` — line 46 — call once in the UI's
  `@main` body with `.info` (NFR-16 default). The `BootstrapState` guard
  ensures idempotency.
- `LoggerFactory.make("macrec.ui.<subsystem>")` — line 67 — use for every
  UI component (e.g., `"macrec.ui.session"`, `"macrec.ui.permissions"`,
  `"macrec.ui.devices"`).
- NFR-16 requires logs go to `~/.tool-agents/macrec-ui/macrec-ui.log`
  (mode `0600`, append) outside Xcode debugger. This requires the UI's
  own `ToolAgentsBootstrap.ensure(toolName: "macrec-ui")` call on startup,
  and FD-level redirection (same pattern as `Daemonizer`, but without
  the double-fork — the UI is a foreground accessory app).

#### `makeRecorder` factory (`Sources/MacrecCore/Encoding/Recorder.swift:123`)

The factory pre-flights output path existence and overwrite. The UI should
call this path check eagerly before pressing Start (to surface errors in the
filename field, not mid-recording). There is no standalone "validate path"
function; instantiate `makeRecorder` to validate, or duplicate the 12-line
pre-flight logic in a UI helper.

#### Audio pipeline tap point for level meters (FR-43)

The buffer path is:

```
SCKitSystemAudioSource.handleAudioBuffer  (macrec.capture.system queue)
    → onSampleBuffer closure
AVMicrophoneSource.captureOutput          (macrec.capture.mic queue)
    → onSampleBuffer closure
    → HostClockAligner.ingest()           (internal)
    → aligner.onAlignedFrame closure      → Recorder.append(AlignedFrame)
```

The correct tap point for level meters is **`onSampleBuffer`** on each source,
because that gives per-source pre-mix buffers with host-clock PTS. The tap
must be non-blocking (deliver to a ring buffer or a `@Sendable` closure posted
on a background queue). The existing `CaptureBuffer` struct
(`Sources/MacrecCore/Capture/CaptureBuffer.swift`) carries `source: .system |
.mic` and the raw `CMSampleBuffer`, which is all that a peak/RMS meter needs.
New API needed: add a `levelTap: ((CaptureBuffer) -> Void)?` closure on
`SCKitSystemAudioSource` and `AVMicrophoneSource` (or reuse the existing
`onSampleBuffer` by chaining — the session currently monopolizes it). The
cleaner design is a second, optional tap closure so the session's wiring is
unchanged.

#### File-naming auto-default for FR-35

There is **no existing helper** that generates `recording-YYYY-MM-DD-HHmmss.<ext>`.
`StartCommand` requires `--output` explicitly (it is the only required
config field, `ConfigResolver.swift:96`). The UI must implement a small helper
function (e.g., `defaultFilename(format: OutputFormat) -> String`) in the UI
module. Recommended location: a `FilenameGenerator.swift` file under
`Sources/macrec-ui/`.

The FR-34 segment naming scheme (`<basename>.part01.<ext>`, `.part02.`, ...)
is also new — no existing code handles this. The UI session controller must
maintain a `segmentCounter: Int` and compute `partNN` URLs before each
`RecordingSession.run()` invocation.

#### `Package.swift` — current structure and UI target requirements

Current targets (all at `Sources/<name>/`):

| Target | Kind | Dependencies | Linker extras |
|--------|------|-------------|---------------|
| `macrec` | `executableTarget` | `MacrecCore`, `ArgumentParser`, `Logging` | `-sectcreate __TEXT __info_plist Resources/Info.plist` |
| `MacrecCore` | `target` (library) | `Logging`, `ArgumentParser` | — |
| `MacrecCoreTests` | `testTarget` | `MacrecCore` | CLT framework search paths |

The new `macrec-ui` target needs:

1. A new `executableTarget` entry:
   ```swift
   .executableTarget(
       name: "macrec-ui",
       dependencies: [
           "MacrecCore",
           .product(name: "Logging", package: "swift-log"),
       ],
       path: "Sources/macrec-ui",
       linkerSettings: [
           .unsafeFlags([
               "-Xlinker", "-sectcreate",
               "-Xlinker", "__TEXT",
               "-Xlinker", "__info_plist",
               "-Xlinker", "Resources/MacrecUI-Info.plist",
           ])
       ]
   )
   ```
2. A **separate `Resources/MacrecUI-Info.plist`** (not the CLI's file)
   containing: `CFBundleIdentifier=com.local.macrec-ui`, the same
   `NSMicrophoneUsageDescription` and `NSScreenCaptureUsageDescription`
   strings, and critically **`LSUIElement = true`** (makes the process a
   menu-bar-only accessory — no Dock icon, no app menu when in the background;
   required for FR-30 / OQ-UI-1). `CFBundleExecutable` must be `macrec-ui`.
3. No `ArgumentParser` dependency (the UI has no CLI parsing needs; it reads
   `UserDefaults` and receives user actions via SwiftUI).
4. A new product entry so `swift build --product macrec-ui` works:
   ```swift
   .executable(name: "macrec-ui", targets: ["macrec-ui"])
   ```

#### `StartCommand` wiring — pattern the UI replicates (`Sources/macrec/Commands/StartCommand.swift`)

The UI's session-start sequence mirrors `StartCommand.run()` steps 1–6, minus
steps 4 (log bootstrap — done at UI launch) and 5 (daemonize — never):

1. `ToolAgentsBootstrap.ensure(toolName: "macrec")` — the session calls this
   internally; the UI does not need to call it separately.
2. Build `RecordingOptions` directly (UI-controlled fields from `UserDefaults` +
   the filename field), NOT via `ConfigResolver.resolve(cliOverrides:)`.
3. `RecordingSession(options: options, logger: logger)`.
4. `Task { try await session.run() }` on a background `Task`; observe state
   via the FR-33 `SessionState` stream.
5. On Stop button: `session.requestStop()` (already public, line 218).

`buildCLIOverrides()` at line 174 is CLI-specific and not reused by the UI.

#### `Daemonizer` — NOT reused by the UI (`Sources/MacrecCore/Daemon/Daemonizer.swift`)

The UI is a foreground menu-bar accessory app. It never calls
`Daemonizer.detach(_:)`. `runMode` is always `.foreground` in the
`RecordingOptions` the UI builds.

### 4.2 Out of Scope — Modules the UI does NOT touch

- `Sources/macrec/Commands/StopCommand.swift` — CLI-only; UI uses
  `session.requestStop()` directly.
- `Sources/macrec/Commands/ListDevicesCommand.swift` — CLI-only; UI calls
  `AudioDeviceEnumerator.listInputs()` directly.
- `Sources/macrec/Commands/RootCommand.swift` — CLI-only.
- `Sources/MacrecCore/Daemon/Daemonizer.swift` — never used by the UI.
- `Sources/MacrecCore/Daemon/PidFile.swift` — the UI runs foreground; no PID file.
- `Sources/MacrecCore/Config/DotEnvParser.swift` — consumed only by
  `ConfigResolver`, which the UI calls at most once for non-UI defaults.
- `Sources/MacrecCore/Aligning/HostClockAligner.swift` — internal to session;
  no direct UI interaction.
- `Sources/MacrecCore/Mixing/BufferSummer.swift` — internal to `M4ARecorder`.

### 4.3 New Integration Points (do not exist today)

| New item | Recommended location | Rationale |
|----------|---------------------|-----------|
| `SessionState` enum + `AsyncStream` | `Sources/MacrecCore/RecordingSession.swift` | FR-33; extend `RecordingSession` with a `stateStream: AsyncStream<SessionState>` property and emit from `resolveRunLoop` and each lifecycle transition |
| `pause() async` / `resume() async` | UI session coordinator in `Sources/macrec-ui/` | Stop-and-stitch does not modify `RecordingSession` itself; the UI controller manages the sequence of sessions and segment URLs |
| `split() async` | `Sources/MacrecCore/RecordingSession.swift` | FR-32 requires encoder rotation with sources alive — must be a method on the session because it needs to reach the recorder and aligner internals |
| `levelTap` closure on sources | `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift` and `AVMicrophoneSource.swift` | FR-43; add `var levelTap: ((CaptureBuffer) -> Void)?` alongside the existing `onSampleBuffer` |
| `FilenameGenerator` helper | `Sources/macrec-ui/FilenameGenerator.swift` | FR-35 auto-named timestamp; no existing helper |
| Segment URL computation (`partNN`) | `Sources/macrec-ui/SegmentNamer.swift` | FR-34; no existing helper |
| `MacrecUI-Info.plist` | `Resources/MacrecUI-Info.plist` | Separate Info.plist for the UI with `LSUIElement=true` and `CFBundleIdentifier=com.local.macrec-ui` |
| `Sources/macrec-ui/main.swift` | `Sources/macrec-ui/main.swift` | SwiftUI `@main` App entry point; drives `NSStatusItem` + popover |
| `PermissionGating` protocol | `Sources/MacrecCore/Permissions/PermissionGate.swift` | Unblocks ISSUE-02; injectable in tests |

## 5. Notes

- **ISSUE-02 blocks `RecordingSession` testing** (`Issues - Pending Items.md`
  line 56): `PermissionGate` is not injectable into `RecordingSession`. Every
  test of the pipeline throws `screenRecordingPermissionDenied` before reaching
  any recording logic. The UI implementation plan should fix this (introduce a
  `PermissionGating` protocol) as a prerequisite, since the UI will also need
  to mock permissions in any integration tests.

- **R-17: no working test runner on CommandLineTools** (`Issues - Pending Items.md`
  line 39): `swift test` exits 0 without actually running `@Test` suites. All
  19 test files compile but are not exercised locally. NFR-14 / AC-UI-1 require
  the UI to build with CommandLineTools — UI tests (if any) must be manual or
  CI-only.

- **R-21 / R-2: ad-hoc TCC instability applies to the UI too**
  (`Issues - Pending Items.md` line 14): the UI binary will re-prompt for TCC
  on every rebuild (same root cause as the CLI). The UI's `LSUIElement=true`
  Info.plist makes the bundle a different identity from the CLI, so TCC grants
  are NOT shared between `macrec` and `macrec-ui`.

- **No auto-filename timestamp helper exists in `MacrecCore`**: the CLI requires
  `--output` explicitly (it is the only truly required field). The UI must
  implement `FilenameGenerator` from scratch in the `macrec-ui` module. This is
  a small addition (~15 lines) but must not be missed in the implementation plan.
