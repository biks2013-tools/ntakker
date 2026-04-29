---
language: swift
framework: none
package_manager: swift-package-manager
build_command: "swift build"
test_command: "swift test"
lint_command: null
entry_points:
  - Sources/macrec/main.swift
  - Sources/macrec-ui/MacrecUIApp.swift
last_scanned_commit: cc462530ec8148eee49ae3522d7ddd384756f762
scanned_for_request: refined-request-live-transcription.md
scanned_at: "2026-04-26T20:00:00Z"
---

# Codebase Scan — macrec / macrec-ui (live-transcription narrowing)

## 1. Project Overview

Swift-only SwiftPM workspace targeting macOS 14+. Three products: `macrec`
(CLI executable), `macrec-ui` (menu-bar app executable), and `MacrecCore`
(shared library). A fourth library target, `MacrecUIKit`, houses the pure
domain layer shared by `macrec-ui` and its test target `MacrecUITests`.
The build system is SwiftPM (no Xcode project file); dependencies are
locked to `swift-argument-parser` (≥ 1.5.0) and `swift-log` (≥ 1.5.4).
There is currently **zero networking code** in any target — this is the
project's first planned network integration.

---

## 2. Module Map

| Path | Purpose | Representative symbols |
|---|---|---|
| `Sources/MacrecCore/Capture/` | Raw PCM acquisition — SCStream system audio, AVCaptureSession mic, fake source for tests | `SCKitSystemAudioSource`, `AVMicrophoneSource`, `FakeAudioSource` |
| `Sources/MacrecCore/Aligning/` | Host-clock-driven cross-source aligner; emits 100 ms `AlignedFrame` windows | `HostClockAligner`, `AlignedFrame`, `SilenceBufferFactory` |
| `Sources/MacrecCore/Mixing/` | Element-wise Float32 summer (Accelerate vDSP); powers `mixed` layout | `BufferSummer` |
| `Sources/MacrecCore/Encoding/` | `Recorder` protocol + factory; concrete `M4ARecorder`, `WAVRecorder`, `CAFRecorder` | `Recorder`, `makeRecorder`, `M4ARecorder` |
| `Sources/MacrecCore/Config/` | Four-tier env-var resolver, option struct, `.env` parser | `ConfigResolver`, `RecordingOptions`, `DotEnvParser` |
| `Sources/MacrecCore/Errors/` | Typed error enum with locked exit codes and stderr formatting | `MacrecError` |
| `Sources/MacrecCore/Aligning/` | `CaptureBuffer` envelope, `AlignedFrame` pair | `CaptureBuffer`, `CaptureSourceTag` |
| `Sources/MacrecCore/Bootstrap/` | Materializes `~/.tool-agents/<toolName>/` on first run | `ToolAgentsBootstrap` |
| `Sources/MacrecCore/Logging/` | Logger factory wrapping swift-log | `LoggerFactory` |
| `Sources/MacrecCore/Daemon/` | Double-fork daemonizer + PID file r/w | `Daemonizer`, `PidFile` |
| `Sources/MacrecCore/Permissions/` | TCC gate (screen recording + mic) | `PermissionGate`, `PermissionGating` |
| `Sources/MacrecCore/Devices/` | AVCaptureDevice enumeration | `DeviceEnumerator` |
| `Sources/MacrecCore/RecordingSession.swift` | End-to-end pipeline orchestrator; exposes `stateStream: AsyncStream<SessionState>` | `RecordingSession`, `StopReason` |
| `Sources/MacrecCore/SessionState.swift` | Lifecycle enum for the state stream | `SessionState` |
| `Sources/MacrecUIKit/` | Domain layer for the UI: controller, coordinator, level metering, filename generation | `RecordingController`, `SessionCoordinator`, `LevelMeterTap`, `LevelMeterPublisher` |
| `Sources/macrec/Commands/` | CLI subcommands built with swift-argument-parser | `StartCommand`, `StopCommand`, `ListDevicesCommand`, `CheckPermissionsCommand`, `RootCommand` |
| `Sources/macrec-ui/` | AppKit + SwiftUI menu-bar app shell | `MacrecUIApp`, `AppDelegate`, `PopoverController`, `StatusItemController`, `RootView` |
| `Sources/macrec-ui/Views/` | Popover UI components | `FormatPicker`, `LayoutPicker`, `MicrophonePicker`, `FolderPicker`, `LevelMeterView`, `ControlBar` |
| `Tests/MacrecCoreTests/` | Swift Testing unit suite for `MacrecCore` (24 files) | `RecordingSessionTests`, `HostClockAlignerTests`, `ConfigResolverTests` |
| `Tests/MacrecUITests/` | Swift Testing unit suite for `MacrecUIKit` | (coordinator + controller tests) |
| `test_scripts/` | Shell e2e scripts (run with real TCC grants) | `e2e-30s-mixed.sh`, `e2e-detach-stop.sh`, `e2e-60min-stability.sh` |

---

## 3. Conventions

- **Concurrency model: `AsyncStream` throughout.** Every observable pipeline
  output uses `AsyncStream.makeStream(of:bufferingPolicy:)` with a
  `.bufferingNewest(N)` drop policy. Examples: `RecordingSession.stateStream`
  (`bufferingNewest(8)`, `RecordingSession.swift:233`),
  `LevelMeterTap.stream` (`bufferingNewest(2)`,
  `MacrecUIKit/LevelMeterTap.swift:86`),
  `SessionCoordinator.events` (`bufferingNewest(16)`,
  `MacrecUIKit/SessionCoordinator.swift:223`). **No Combine** anywhere
  in the codebase. The transcription tap must use `AsyncStream` with the same
  `.bufferingNewest` drop policy.

- **Error model: typed enum, no fallbacks.** `MacrecError` is the sole error
  type (`MacrecCore/Errors/MacrecError.swift:18`). Every missing-config
  situation throws `MacrecError.missingRequiredConfig(key:sourcesChecked:)` —
  never a silent default. Exit codes are locked by design §9.5. Config errors
  map to `EX_CONFIG` (78). The transcription subsystem must add new cases to
  this same enum.

- **Config resolution: four-tier merge in `ConfigResolver.resolve`.** The
  `value(_:)` closure at `ConfigResolver.swift:88` implements
  `cliOverrides > localEnv > userEnv > shellEnv`. Each new env-var key is
  registered as a `static let` inside `ConfigResolver.Keys`
  (`ConfigResolver.swift:235-251`). `RecordingOptions` is the sole
  configuration struct; new transcription fields must be added as stored
  properties there (`RecordingOptions.swift:55`).

- **Queue discipline: serial queues own all mutable state; callbacks must not
  block.** `SCKitSystemAudioSource.handleAudioBuffer` invokes `onSampleBuffer`
  and `levelTap` synchronously on `macrec.capture.system`
  (`SCKitSystemAudioSource.swift:339-345`). Any transcription tap attached at
  this point must enqueue-and-return immediately — it cannot block or call
  `await`. `HostClockAligner.onAlignedFrame` fires on `macrec.aligner.serial`
  with the same non-blocking contract (`RecordingSession.swift:382-394`).

- **UI is `@MainActor @Observable`.** `RecordingController`
  (`MacrecUIKit/RecordingController.swift:36`) owns all SwiftUI-visible state.
  Pickers follow the `FormatPicker` pattern: `@AppStorage` for persistence,
  a `Binding` derived at read time, disabled while `state` is not `.idle` /
  `.stopped` / `.failed` (`macrec-ui/Views/FormatPicker.swift:29-35`).
  Level-meter data flows through `LevelMeterPublisher` into
  `RecordingController.applyLevels(_:)` (`RecordingController.swift:332`).

- **Testing: FakeAudioSource injection, no live TCC calls.** Tests inject
  `FakeAudioSource` and a stub `PermissionGating` into `RecordingSession.init`
  (`RecordingSession.swift:213-219`). Tests that need the full pipeline run as
  e2e shell scripts in `test_scripts/` (require actual TCC grants).

---

## 4. Integration Points

### 4.1 In-Scope — Audio Pipeline Tap Points

The transcription side-channel must tap into the PCM stream **without
modifying any existing call site**. The two viable tap points are:

**Tap Point A — Post-`SCKitSystemAudioSource.handleAudioBuffer` (system audio
only, pre-aligner)**

- File: `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift`, lines
  323–345, method `handleAudioBuffer(_:)`.
- The source already exposes a second optional closure `levelTap: ((CaptureBuffer) -> Void)?`
  (line 178) installed by `LevelMeterPublisher`. A `transcriptionTap:
  ((CaptureBuffer) -> Void)?` property can be added alongside it with
  identical semantics (invoked after `onSampleBuffer`, same
  `macrec.capture.system` queue).
- The `CaptureBuffer` at this stage is `Float32 / 48 kHz / stereo /
  non-interleaved` (per `CaptureBuffer.swift:37-40`). The transcription
  module must downsample to `Int16 / 16 kHz / mono` in a dedicated
  `AVAudioConverter` owned by the transcription subsystem — the recording
  converter must not be reused (constraint from refined-request §Technical).
- Parallel tap needed on `AVMicrophoneSource` for the `--transcribe-source
  mic` / `both` cases. Check `Sources/MacrecCore/Capture/AVMicrophoneSource.swift`
  for the same `levelTap` hook pattern.

**Tap Point B — Post-`HostClockAligner.onAlignedFrame` (mixed / aligned,
post-aligner) — PREFERRED for `--transcribe-source mixed`**

- File: `Sources/MacrecCore/RecordingSession.swift`, lines 382–394, the
  `aligner.onAlignedFrame` closure.
- The `AlignedFrame` (`AlignedFrame.swift:24`) carries both `systemBuffer`
  and `micBuffer` at the same 100 ms window. For the `mixed` transcription
  source, this is the ideal tap: the aligner has already gap-filled and
  time-aligned both sources. The tap reads `frame.systemBuffer` +
  `frame.micBuffer` and sums them (same `BufferSummer` call the recorder
  uses) into a mono downsample.
- **How to wire it without modifying the closure:** `RecordingSession` could
  expose an optional `transcriptionTap: ((AlignedFrame) -> Void)?` property
  (analogous to `levelTap` on sources). The closure fires on
  `macrec.aligner.serial`; it must enqueue-and-return immediately.
- `RecordingSession.split(nextOutput:)` at line 573 rotates the recorder
  through `_recorderLock` atomically; the transcription tap does **not** need
  rotation — it stays alive across splits.

**Key data types for the tap:**

| Symbol | File | Line | Role |
|---|---|---|---|
| `CaptureBuffer` | `Capture/CaptureBuffer.swift` | 33 | Envelope with source tag + `CMSampleBuffer` |
| `CaptureSourceTag` | `Capture/CaptureBuffer.swift` | 21 | `.system` / `.microphone` |
| `AlignedFrame` | `Aligning/AlignedFrame.swift` | 24 | Time-aligned pair, 100 ms window |
| `HostClockAligner.onAlignedFrame` | `Aligning/HostClockAligner.swift` | 81 | Callback set point |
| `SCKitSystemAudioSource.levelTap` | `Capture/SCKitSystemAudioSource.swift` | 178 | Existing tap hook pattern to mirror |

---

### 4.2 In-Scope — Configuration / Env-Var Layer

**Where to add new keys:**

- `Sources/MacrecCore/Config/ConfigResolver.swift`, `enum Keys` block,
  lines 235–251. Add one `static let` per new env-var
  (`MACREC_TRANSCRIBE_PROVIDER`, `MACREC_TRANSCRIBE_SOURCE`,
  `MACREC_TRANSCRIPT_FORMAT`, `GOOGLE_API_KEY`,
  `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`).
- `ConfigResolver.resolve(cliOverrides:)` at line 82 is where each key is
  read via the four-source `value(_:)` closure (line 88). New transcription
  fields follow the same `parseEnum` / `parseBool` / missing-throws pattern.
- `Sources/MacrecCore/Config/RecordingOptions.swift`: add new `let`
  properties for each transcription setting. The struct is `Sendable` and
  `Equatable`; new fields must conform. `withOutput(_:)` at line 185 must
  be updated to forward the new fields.
- `ConfigResolver.userEnvURL()` at line 255 resolves
  `~/.tool-agents/macrec/.env` — the CLI chain. The UI chain analogously
  resolves `~/.tool-agents/macrec-ui/.env`; that chain is constructed in
  `MacrecUIKit` (look for `ConfigResolver(toolName: "macrec-ui")`).

**Missing-key behavior (project invariant):** when a non-`none` provider is
selected and the provider API key resolves to `nil`, the resolver **must
throw** `MacrecError.missingRequiredConfig(key: "GOOGLE_API_KEY",
sourcesChecked: [...])`. The proposed new case
`MacrecError.transcriptionApiKeyMissing` should either be added to
`MacrecError` at `Errors/MacrecError.swift:18` or aliased to the existing
`missingRequiredConfig` case with exit code 78 (`EX_CONFIG`, matching the
existing mapping at `MacrecError.swift:67-71`).

---

### 4.3 In-Scope — UI Surfaces (macrec-ui / MacrecUIKit)

**Existing picker pattern (to replicate for transcription picker):**

- `Sources/macrec-ui/Views/FormatPicker.swift` (entire file, 61 lines) is
  the canonical picker template: `@AppStorage` for persistence under
  `com.macrec.ui.<key>`, a `Binding<EnumType>` derived at read, disabled
  via the `isLocked` computed var that checks `recordingController?.state`.
- `Sources/macrec-ui/Views/LayoutPicker.swift` and
  `Sources/macrec-ui/Views/MicrophonePicker.swift` follow the same pattern.
- New "Live transcription" picker: `Sources/macrec-ui/Views/TranscriptionPicker.swift`
  (new file). `@AppStorage("com.macrec.ui.transcribeProvider")`. Enum values:
  `none`, `gemini-live` (plus future providers).
- A `TranscriptionSourcePicker` for `system / mic / mixed / both` follows the
  same template.

**Level-meter rendering (for positioning the transcript panel):**

- `Sources/macrec-ui/Views/LevelMeterView.swift` — the existing level-meter
  SwiftUI view.
- `Sources/MacrecUIKit/LevelMeterPublisher.swift` — merges system + mic
  `LevelSample` streams into a `MergedLevelSample AsyncStream`.
- `Sources/MacrecUIKit/LevelMeterTap.swift` — the raw extraction primitive.
  The transcript panel must be placed **below** the level meters in the popover
  view hierarchy (per FR-52).

**View-model bridge (`RecordingController`):**

- `Sources/MacrecUIKit/RecordingController.swift:36` — `@MainActor @Observable`.
  New observed properties needed: `transcriptEvents: [TranscriptEvent]`,
  `transcriptionState: TranscriptionState` (idle / active / paused / error),
  `transcriptionProviderMissingKey: Bool` (drives the red badge).
- `RecordingController.setOptions(_:)` at line 117 is the point where UI
  state is pushed into `RecordingOptions`; the transcription provider
  selection must also flow through here.
- `RecordingController.start()` at line 127 constructs `SessionCoordinator`;
  the transcription subsystem must be initialized and started at the same
  point (or inside `SessionCoordinator.start()` so it is segment-aware).

**SessionCoordinator integration:**

- `Sources/MacrecUIKit/SessionCoordinator.swift:126` — `actor
  SessionCoordinator`. The coordinator already synthesizes segment lifecycle
  events (`segmentCompleted`); on pause/resume it finalizes one sidecar and
  opens the next. The transcript sidecar rotation must follow the same
  `pause()` / `resume()` hooks at lines 266 and 294.

**Privacy disclosure:** new modal dialog, no existing analog. Simplest
landing: a new `TranscriptionPrivacyAlert` SwiftUI view triggered by a
`@State var showPrivacyAlert: Bool` in `RootView`
(`Sources/macrec-ui/RootView.swift`). First-use flag stored under
`@AppStorage("com.macrec.ui.transcribePrivacyAccepted")`.

---

### 4.4 In-Scope — CLI Surface (macrec)

**Flag parsing:**

- `Sources/macrec/Commands/StartCommand.swift:36` — `struct StartCommand`.
  New `@Option` flags: `--transcribe <provider>`, `--transcribe-source
  <system|mic|mixed|both>`, `--transcript-output <path>`,
  `--transcript-format <jsonl|txt|srt|vtt>`.
- `StartCommand.buildCLIOverrides()` at line 174 translates parsed flags into
  the `[String: String]` dictionary consumed by `ConfigResolver`. Each new
  flag maps to a new `ConfigResolver.Keys` constant.
- `StartCommand.run()` at line 92 invokes `ConfigResolver(toolName: "macrec")`
  at line 112. Transcription provider resolution and API key validation must
  happen inside `ConfigResolver.resolve()` — **before** `RecordingSession` is
  constructed — so that a missing key exits fast with no audio file created
  (per AC-LT-4).

**Exit codes:** `MacrecError.missingRequiredConfig` already maps to exit code
78 (`MacrecError.swift:67`). The proposed `transcriptionApiKeyMissing` case
should map to the same code. A new `transcriptionProviderInvalid` case (bad
provider name) maps to 64 (`EX_USAGE`, matching `invalidConfigValue`).

---

### 4.5 In-Scope — Error Model

**Current `MacrecError` cases to extend** (`Errors/MacrecError.swift:18`):

- Add to the enum: `transcriptionApiKeyMissing(provider: String, key: String)`,
  `transcriptionProviderUnavailable(provider: String, reason: String)`,
  `transcriptionSessionFailed(provider: String, reason: String)`.
- Exit code mapping (`MacrecError.exitCode`, line 65): `transcriptionApiKeyMissing`
  → 78 (`EX_CONFIG`); `transcriptionProviderUnavailable` → 70 (`EX_SOFTWARE`);
  `transcriptionSessionFailed` → non-fatal (not directly mapped — it should
  not stop the recording).
- `description` and `remediation` strings are locked in format per the
  file-level note at line 7; new cases must follow the same style.
- `MacrecError.printToStderr()` at line 299 is used unchanged.

**No-fallback invariant:** `MacrecError.swift` file-header explicitly states
that defaults are forbidden. The transcription config path must not silently
disable itself when a key is missing; it must throw.

---

### 4.6 In-Scope — Networking Layer (GAP — first network code in project)

**Current state:** A full-text search for `URLSession`, `WebSocket`,
`URLSessionWebSocketTask`, `HTTPURLResponse`, and `URLRequest` across all
source files returns **zero matches**. There is no networking code anywhere
in the project.

**Implication:** The `GeminiLiveTranscriptionProvider` implementation will
introduce the project's first `URLSessionWebSocketTask` usage. Because the
project has no existing network patterns to follow, the implementation is
unconstrained — but should document its own patterns in
`docs/research/live-transcription-feasibility.md` (per the refined-request
Phase 0 investigation deliverable).

**Recommended landing:** a new `Sources/MacrecCore/Transcription/` directory
containing:
- `TranscriptionProvider.swift` — protocol
- `TranscriptionPCMChunk.swift` — value type for PCM frames with source tag
- `TranscriptEvent.swift` — output event type
- `TranscriptSink.swift` — fan-out to UI and disk
- `GeminiLiveTranscriptionProvider.swift` — `URLSessionWebSocketTask` impl
- `NoOpTranscriptionProvider.swift`
- `TranscriptionTap.swift` — the bounded `AsyncStream` side-channel

No new SwiftPM dependency should be added unless the Gemini SDK is
unavoidable (per constraint in refined-request §Technical).

**macOS sandbox note:** network access does not require a TCC permission but
does require the `com.apple.security.network.client` entitlement if the
binary is ever sandboxed. Currently neither `macrec` nor `macrec-ui` is
sandboxed (no `.entitlements` file found in the project). No change needed
for v1, but flag this in `Issues - Pending Items.md`.

---

### 4.7 In-Scope — Build / Test / Lint

| Concern | Command / path |
|---|---|
| Build all targets | `swift build` |
| Build release | `swift build -c release` |
| Run unit tests | `swift test` |
| Run specific suite | `swift test --filter HostClockAlignerTests` |
| E2E scripts | `bash test_scripts/e2e-30s-mixed.sh` (requires TCC grants) |
| Swift Testing framework path | `/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework` (registered via `unsafeFlags` in `Package.swift:57-66`) |
| Lint | No lint tool configured; no `.swiftlint.yml`, `.swiftformat`, or pre-commit hooks detected |

**Test isolation for new transcription tests:** The existing pattern is to
inject fake sources via `RecordingSession.init(systemSource:micSource:permissionGate:)`.
New transcription tests must inject a `FakeTranscriptionProvider` (per the
refined-request requirement) through a similar init-time injection point on
`RecordingSession` or `SessionCoordinator`. Tests that exercise real network
calls must be gated on the presence of `GOOGLE_API_KEY` in the environment,
following the same pattern as `e2e-detach-stop.sh` which checks env vars
before running.

---

### 4.8 In-Scope — Existing Async Patterns

The project uses **`AsyncStream` exclusively** (Swift Concurrency). No
Combine publishers anywhere in source. The pattern is consistent:

```
AsyncStream.makeStream(of: T.self, bufferingPolicy: .bufferingNewest(N))
```

Consumed via `for await element in stream { ... }` inside a `Task`. The
transcription PCM tap must use `AsyncStream<TranscriptionPCMChunk>` with
`.bufferingNewest(N)` (drop-newest-when-full per FR-46). The provider output
stream must also be `AsyncStream<TranscriptEvent>`.

The coordinator uses `actor` isolation (`SessionCoordinator` is an `actor`
at `MacrecUIKit/SessionCoordinator.swift:126`). If the transcription
subsystem needs its own serialized state, it should also be an `actor`.

---

### 4.9 Out of Scope (modules unaffected by this request)

The following modules have no integration point with live transcription and
must not be modified as part of this feature:

- `Sources/MacrecCore/Daemon/` — detach / PID file (v1 excludes detach-mode
  transcription per A-LT-4 and OQ-LT-5).
- `Sources/MacrecCore/Permissions/` — no new TCC permissions required.
- `Sources/MacrecCore/Devices/` — device enumeration is unchanged.
- `Sources/MacrecCore/Bootstrap/` — `ToolAgentsBootstrap` works unchanged;
  transcription keys live in the existing `.env` files it manages.
- `Sources/MacrecCore/Logging/` — `LoggerFactory` is unchanged; the
  transcription module uses `LoggerFactory.make("macrec.transcription")`.
- `Sources/MacrecCore/Aligning/SilenceBufferFactory.swift` — unchanged.
- `Sources/macrec/Commands/StopCommand.swift` — unchanged (stop propagates
  through `RecordingSession.requestStop()` which already drains).
- `Sources/macrec/Commands/ListDevicesCommand.swift` — unchanged.
- `Sources/macrec/Commands/CheckPermissionsCommand.swift` — unchanged.
- `Sources/macrec-ui/Views/ErrorBanner.swift` — unchanged (existing error
  display is reused for transcription errors surfaced via `latestError`).
- `Sources/macrec-ui/Views/SavedToDisclosure.swift` — will need a minor
  update to list transcript sidecar paths alongside audio paths (FR-57), but
  is otherwise not architecturally implicated.

---

## 5. Notes

- **`BufferSummer` is already available for the mixed tap.** The
  `BufferSummer.sum(_:_:)` CMSampleBuffer overload at
  `MacrecCore/Mixing/BufferSummer.swift:108` accepts `nil` inputs and is
  exactly what the `mixed`-source transcription tap needs to combine system
  and mic frames before downsampling. No new sum implementation is required.

- **`levelTap` hook on `SCKitSystemAudioSource` is the proven tap pattern.**
  It was added to support level metering (FR-43) without modifying the core
  delivery path. Transcription uses the same hook slot, same threading
  contract. The analogous hook on `AVMicrophoneSource` may not yet exist —
  verify before Phase D coding begins.

- **No Xcode project file — TCC grants on CLI test targets require manual
  setup.** `RecordingSessionTests.swift:12-35` documents that full pipeline
  tests cannot run under `swift test` without a TCC screen-recording grant
  on the test runner binary. Integration tests for the transcription
  subsystem must either (a) use `FakeTranscriptionProvider` to bypass real
  network calls, or (b) run as shell scripts in `test_scripts/` with the
  real binary under TCC grants.

- **`MacrecError.exitCode` switch is a locked table.** Any new `MacrecError`
  case added for transcription must also be added to the `exitCode` switch at
  `MacrecError.swift:65` and to `description` / `remediation`. Phase 9 (Test
  Builders) will regression-test the locked strings verbatim, so the strings
  must be finalized before coding begins.

- **`RecordingOptions.withOutput(_:)` copies all fields.** When the
  transcription settings are added as stored properties, `withOutput(_:)` at
  `RecordingOptions.swift:185` must be updated to include them. Forgetting
  this causes silent transcription-options loss on every segment rotation
  (pause/resume) — a non-obvious integration bug.
