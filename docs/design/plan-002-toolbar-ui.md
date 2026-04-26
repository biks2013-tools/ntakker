# Plan 002 — `macrec-ui` Minimal Menu-Bar Toolbar UI

> Phase 4 (Planner) deliverable for the v1.1 toolbar-UI add-on. Sibling
> document to `plan-001-recording-tool.md` (which planned the CLI engine).
> Consumed downstream by Phase 5 (Designer), Phase 6 (parallel Coders),
> Phase 7 (Code Reviewer), Phase 8 (Dependency Validator), Phase 9 (Test
> Builders), and Phase 10 (Integration Verifier).
>
> **Date**: 2026-04-26
>
> **Source documents (read in this order before executing this plan):**
>
> 1. `docs/design/refined-request-toolbar-ui.md` — refined spec
>    (FR-30..FR-44, NFR-11..NFR-16, AC-UI-1..AC-UI-18, "Decisions Locked"
>    table). Authoritative for scope.
> 2. `docs/reference/investigation-toolbar-ui.md` — investigation results
>    for the seven uncertain technical topics. Authoritative for the
>    "how" of every locked decision.
> 3. `docs/reference/codebase-scan-toolbar-ui.md` — engine integration
>    points with file:line citations. Authoritative for "where the new
>    code attaches".
> 4. `docs/design/project-design.md` — current project design (component
>    index in §1, exit codes in §9.5, error contract in §2.1). The new
>    UI section is added by Phase 5 (Designer); this plan does NOT modify
>    that file.
> 5. `docs/design/plan-001-recording-tool.md` — engine plan, referenced
>    here only for phasing-style and gate-criteria conventions.
> 6. `CLAUDE.md` (project, `Exception 001` — Swift implementation
>    language; tool-scaffolding mandate).

---

## Section 0 — Explicit Ambiguities

Each item is a question that the locked-decisions table did not fully
resolve. Each carries a recommended default the planner has assumed; the
Designer (Phase 5) and Code Reviewer (Phase 7) confirm or flag overrides.

| # | Ambiguity | Assumed default for this plan | Resolution gate |
|---|-----------|------------------------------|-----------------|
| AMB-1 | Should `splitting` be a discrete `SessionState` case (~50 ms transient) or a transient flag on `recording`? | **Discrete case** — keeps the FR-33 enum exhaustive and matches the spec verbatim; UI may render it identically to `recording`. | Phase 5 (Designer) confirms in the §15 design block. |
| AMB-2 | Choice of mutex around `_recorder` for the split-swap on `RecordingSession` (`OSAllocatedUnfairLock` vs `os_unfair_lock_s`). | **`OSAllocatedUnfairLock<Recorder?>`** — macOS 13+, Sendable-friendly successor; matches investigation Topic 4 recommendation. | Phase 6 (Coders, Phase A1) at implementation. |
| AMB-3 | Whether `FilenameGenerator` lives in `Sources/macrec-ui/` (UI-only) or in `Sources/MacrecCore/` (shared). | **`Sources/macrec-ui/`** — codebase scan §4.3 + investigation Topic 6 explicitly recommend keeping UI policy out of the engine. | Phase 5 (Designer) confirms. |
| AMB-4 | Whether `SessionCoordinator` is an `actor` or a `@MainActor`-isolated class. | **`actor`** — matches investigation Topic 3, isolates segment-counter mutation, never touches SwiftUI state directly. | Phase 5 (Designer). |
| AMB-5 | Default UI log level on first launch (`.info` vs `.debug`). | **`.info`** per NFR-16; a hidden "Show debug log" menu item toggles to `.debug`. | Phase 6 (Phase H). |

No other ambiguity blocks this plan from proceeding.

---

## Section 1 — Goal

Add a **minimal native macOS menu-bar UI** named `macrec-ui` on top of the
existing `MacrecCore` engine so the user can drive a recording without
remembering CLI flags. The UI is a SwiftUI-content / AppKit-shell hybrid
(`NSStatusItem` + `NSPopover` + `NSHostingController<RootView>`) that
links `MacrecCore` in-process and drives `RecordingSession` directly. It
exposes the four lifecycle controls the user named (Start, Pause/Resume
under stop-and-stitch, Stop, manual Split) plus the locked "et cetera"
controls (filename field, format/layout/folder/mic dropdowns, permission
indicator, elapsed-time indicator, per-source level meters). The plan is
strictly additive: the existing `macrec` CLI MUST continue to build and
pass AC-1..AC-20 unchanged.

The work is broken into eleven sequenced phases (Phase 0..K) mirroring
the gate-criteria style of `plan-001-recording-tool.md`. Phases A and B
are independent prerequisites that unlock Phases C–G; Phases H and J can
run alongside the UI build-out; Phase I (test build) is gated behind
R-22, the toolchain test-runner caveat.

---

## Section 2 — Scope

### 2.1 In scope (v1)

Direct mirror of refined-spec §"In scope (v1)":

- A native macOS menu-bar UI surface — `NSStatusItem` + `NSPopover` +
  SwiftUI body via `NSHostingController` (locked OQ-UI-1).
- Four lifecycle controls: Start, Pause/Resume (stop-and-stitch
  multi-file; locked OQ-UI-2), Stop, manual Split (locked OQ-UI-3).
- Output filename field with auto-generated timestamp default
  (`recording-YYYY-MM-DD-HHmmss.<ext>`); editable pre-record; locked
  during recording (FR-35; locked OQ-UI-5).
- Surfacing the four "core extras": elapsed-time indicator (FR-40),
  format dropdown (FR-38), layout dropdown (FR-38), permission status
  indicator (FR-37) — locked OQ-UI-6 core.
- Surfacing the three "optional extras": output folder picker (FR-36),
  microphone device dropdown (FR-39), per-source level meters (FR-43) —
  locked OQ-UI-6 optional.
- Recording-state visual cue in the menu-bar icon (FR-41).
- New `MacrecCore` capabilities required to back the UI:
  - `SessionState` enum + `stateStream` observer (FR-33).
  - `split(nextOutput:)` async method on `RecordingSession` (FR-32).
  - `levelTap` closure on `SCKitSystemAudioSource` and
    `AVMicrophoneSource` (FR-43).
  - `PermissionGating` protocol + `LivePermissionGate` conformer
    (unblocks ISSUE-02 in `Issues - Pending Items.md`).
- Reuse of the existing `ConfigResolver`, `PermissionGate`,
  `AudioDeviceEnumerator`, `RecordingSession`, `Recorder`
  implementations, `MacrecError`, and `LoggerFactory`. UI never
  re-implements these.
- Quit-while-recording flow with confirm dialog → finalize → quit (locked
  OQ-UI-10).
- Documentation:
  - `docs/tools/macrec-ui.md` scaffolded by the
    `tool-doc-config-architect` subagent (per `CLAUDE.md` mandate).
  - `~/.tool-agents/macrec-ui/` scaffolded by the same subagent.
  - `## Tools` entry in `CLAUDE.md` with summary + relative link.
  - `docs/design/project-functions.md` extended with FR-30..FR-44 +
    NFR-11..NFR-16 (this plan writes those in Phase 0).
  - `docs/design/project-design.md` gains a new "UI Architecture"
    section — written by **Phase 5 (Designer)**, NOT this plan.
  - `Issues - Pending Items.md` updated with new risks (R-22..R-25).

### 2.2 Out of scope (v1)

Direct mirror of refined-spec §"Out of scope":

- Waveform display, scrubbing, post-record playback, post-record
  trim/edit, transcription preview, summarization, or any
  post-processing pipeline.
- Multi-window / multi-recording UX. v1 is single-recording.
- Time-based or size-based auto-split. Manual split only.
- Code signing, notarization, App Store, Sparkle updater, Homebrew
  cask, `.dmg` packaging. v1 is an `swift build` artifact.
- Localization — English-only copy wrapped in `String(localized:)`.
- Full accessibility audit / VoiceOver-tuned labels (a short pre-ship
  pass IS in scope).
- Any modification of the existing CLI surface that is not strictly
  additive.
- Cross-platform support.

### 2.3 Architectural locks (do not re-litigate)

- **Form factor**: AppKit `NSStatusItem` + `NSPopover` containing
  `NSHostingController<RootView>` inside a SwiftUI `App` whose only
  declared scene is `Settings { EmptyView() }`. Investigation Topic 1
  Option 1B. **NOT `MenuBarExtra`** (R-24).
- **View-model bridge**: `@MainActor @Observable RecordingController`
  + unstructured `Task` + `AsyncStream<SessionState>`. Investigation
  Topic 2 Option 2A.
- **Pause**: UI-side `actor SessionCoordinator` orchestrates
  multi-segment stop-and-stitch. Investigation Topic 3 Option 3A.
  No engine change for pause.
- **Split**: Single-recorder atomic swap on `RecordingSession.serialQueue`
  with `OSAllocatedUnfairLock<Recorder?>` guarding `_recorder` and a
  re-pointed `aligner.onAlignedFrame` closure. Investigation Topic 4
  Option 4A.
- **Level meters**: New `levelTap` closure on each capture source +
  vDSP peak/RMS on a pre-allocated `AVAudioPCMBuffer` + 30 Hz coalesced
  `AsyncStream<LevelSample>`. Investigation Topic 5 Option 5A.
- **Filename auto-generation**: Standalone `FilenameGenerator` struct
  in `Sources/macrec-ui/`. Investigation Topic 6 Option 6A.
- **Info.plist embedding**: `-Xlinker -sectcreate __TEXT __info_plist
  Resources/MacrecUI-Info.plist` linker flag. Investigation Topic 7
  Option 7A.
- **Process model**: in-process linking of `MacrecCore`. No subprocess
  shell-out (locked OQ-PROC-1).
- **No fallback config values**: every missing required value raises
  `MacrecError` (project-wide rule). UI's `UserDefaults`-backed
  preferences are *UI state*, not configuration.

---

## Section 3 — Phasing

> Each phase below is a self-contained implementation unit. Each lists
> **Inputs**, **Files** (created or modified), **Outputs**, **Gate
> criteria**, and a **Parallelism note**. Phases A and B are independent
> and can run in parallel after Phase 0; Phase H and J can run alongside
> the UI build-out; Phase I (tests) is gated by R-22.

---

### Phase 0 — Pre-flight: docs scaffolding + functional registry

- **Goal**: Stand up the documentation and configuration scaffolding
  required by `CLAUDE.md` BEFORE any code is written, so subsequent
  phases land in a conformant project state.

- **Inputs**:
  - Refined spec (FR-30..FR-44, NFR-11..NFR-16, all locked decisions).
  - Investigation document (Topic 7 plist contents).
  - Existing `docs/tools/macrec.md` as a precedent for the XML
    `<toolName>` block format.
  - Existing `~/.tool-agents/macrec/` as a precedent for permissions
    and `.env` shape.

- **Files**:
  - **Create** `docs/tools/macrec-ui.md` — produced by
    `/tool-conventions scaffold macrec-ui` (dispatches the
    `tool-doc-config-architect` subagent). MUST NOT be hand-authored.
    The orchestrator runs the slash command before this phase exits.
    Initial content is a template populated by the subagent; Phase J
    fills in the operator-facing description from the implemented
    behavior.
  - **Create** `~/.tool-agents/macrec-ui/` (mode `0700`) and
    `~/.tool-agents/macrec-ui/.env` (mode `0600`) — produced by the
    same subagent invocation.
  - **Modify** `CLAUDE.md` — append a `## Tools`-section entry for
    `macrec-ui` with the recommended-entry text the subagent prints
    after scaffolding.
  - **Modify** `docs/design/project-functions.md` — append FR-30..FR-44
    and NFR-11..NFR-16 with `Status: PLANNED` and the phase mapping
    from §6 of this plan. (This plan writes them in Phase 0; Phase 5
    Designer does NOT touch project-functions.md.)
  - **Modify** `Issues - Pending Items.md` — pre-register R-22..R-25
    (this plan's risk register, §5) so Phase 7 / Phase 10 see them.

- **Outputs**:
  - The four documentation deliverables above.
  - A working `~/.tool-agents/macrec-ui/` folder honored by NFR-16
    log-file resolution.

- **Gate criteria**:
  - `/tool-conventions audit macrec-ui` passes (AC-UI-15).
  - `docs/tools/macrec-ui.md` exists with the required `<toolName>`
    XML block.
  - `~/.tool-agents/macrec-ui/` exists at mode `0700`; `.env` at
    `0600`.
  - `CLAUDE.md` has the new entry under `## Tools`.
  - `docs/design/project-functions.md` contains FR-30..FR-44 and
    NFR-11..NFR-16 (AC-UI-16, partial — full pass also requires Phase
    K's verification).
  - `Issues - Pending Items.md` has the R-22..R-25 entries.
  - `swift build` of the existing CLI still succeeds (no regression).

- **Parallelism note**: All four file outputs in this phase are
  independent edits; they can be batched by a single coder agent in one
  pass. The `/tool-conventions scaffold` command MUST run first
  (creates two of the files), then the `CLAUDE.md`,
  `project-functions.md`, and `Issues - Pending Items.md` edits run as
  three independent edits.

---

### Phase A — `MacrecCore` engine extensions (PREREQUISITE for UI)

- **Goal**: Land the four engine APIs that the UI requires:
  `SessionState` + `stateStream` (FR-33), `split(nextOutput:)` (FR-32),
  `levelTap` (FR-43), and `PermissionGating` protocol (unblocks
  ISSUE-02). These are additive only; the existing CLI must compile and
  behave identically.

- **Inputs**:
  - Investigation Topics 2, 3, 4, 5 (concrete shapes and gotchas).
  - Codebase scan §4 (integration points with file:line citations).
  - Existing `Sources/MacrecCore/RecordingSession.swift`
    (`serialQueue` line 120; `_runContinuation` line 144; `_recorder`
    line 157; `requestStop` line 218; `aligner.onAlignedFrame`
    re-point line 302; `_running = true` line 349).
  - Existing `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift`
    and `Sources/MacrecCore/Capture/AVMicrophoneSource.swift`
    (existing `onSampleBuffer` closure).
  - Existing `Sources/MacrecCore/Permissions/PermissionGate.swift`
    (existing `snapshot()` and `requireBothOrThrow()`).

- **Files** (all under `Sources/MacrecCore/` and the test target):
  - **Create** `Sources/MacrecCore/SessionState.swift` — defines
    ```swift
    public enum SessionState: Sendable, Equatable {
        case idle, starting, recording, pausing, paused, resuming,
             splitting, stopping, stopped
        case failed(MacrecError)
    }
    ```
    plus a small `description` helper for logging.
  - **Modify** `Sources/MacrecCore/RecordingSession.swift`:
    - Add `private let stateContinuation: AsyncStream<SessionState>.Continuation`
      and `public let stateStream: AsyncStream<SessionState>`,
      initialized via `AsyncStream.makeStream(of: SessionState.self,
      bufferingPolicy: .bufferingNewest(8))` in `init`.
    - Emit at every transition: when entering `run()` (`.starting`),
      after sources/recorder are wired and `_running = true`
      (`.recording`), in `requestStop()` body (`.stopping`), in the
      `resolveRunLoop` cleanup (`.stopped` or `.failed(error)`).
    - Add `private var _recorderLock = OSAllocatedUnfairLock<Recorder?>(initialState: nil)`
      to replace the existing `_recorder: Recorder?` storage. Update
      `aligner.onAlignedFrame` (line 302) to read through the lock so
      the split-swap is observable atomically. (See AMB-2.)
    - Add `public func split(nextOutput: URL) async throws` — the
      atomic-swap recipe from investigation Topic 4: pre-flight new
      `Recorder` via `makeRecorder` + `await newRecorder.start()`,
      `_recorderLock.withLock { swap }`, then
      `await oldRecorder.finalize(timeout: 5)` off the lock. Emit
      `.splitting` at entry and `.recording` after the swap settles.
    - Add a small private helper `RecordingOptions.withOutput(_ url: URL)
      -> RecordingOptions` (or as an extension elsewhere) used by
      `split()` to derive the new options. Investigation Topic 4
      gotcha.
    - Call `stateContinuation.finish()` at the end of
      `resolveRunLoop` (investigation Topic-2 §"AsyncStream
      continuation lifecycle" gotcha).
  - **Modify** `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift`:
    - Add `public var levelTap: ((CaptureBuffer) -> Void)?` alongside
      the existing `onSampleBuffer`. Invoke `levelTap?(buffer)` after
      `onSampleBuffer?(buffer)` in `handleAudioBuffer`. No other
      behavior change.
  - **Modify** `Sources/MacrecCore/Capture/AVMicrophoneSource.swift`:
    - Same `levelTap` addition next to its existing `onSampleBuffer`.
  - **Modify** `Sources/MacrecCore/Permissions/PermissionGate.swift`:
    - Extract a new `public protocol PermissionGating: Sendable {
      func snapshot() async -> Snapshot; func requireBothOrThrow()
      async throws }`. Mark the existing `PermissionGate` class as
      conforming to it. Define a struct/class
      `LivePermissionGate: PermissionGating` if a name change is
      preferred; otherwise the existing `PermissionGate` IS the
      `Live` conformer. (See codebase-scan §4.3.)
  - **Modify** `Sources/MacrecCore/RecordingSession.swift` (init):
    - Add a new optional parameter
      `permissionGate: (any PermissionGating)? = nil` to the public
      initializer. Default: `nil` → constructs `PermissionGate(logger:)`
      internally (existing behavior). Test injection point. **Resolves
      ISSUE-02.**
  - **Create** test files (Swift Testing) — these author tests for
    the new APIs. Per R-17 they will compile but cannot be trusted on
    the dev host:
    - `Tests/MacrecCoreTests/SessionStateTests.swift` — exhaustive
      switch over the enum; `Equatable` round-trip;
      `MacrecError.failed` payload match.
    - `Tests/MacrecCoreTests/RecordingSessionStateStreamTests.swift`
      — using a `FakeAudioSource` + a stub `PermissionGating` (mock
      that always grants), assert the emitted state sequence is
      `[.starting, .recording, .stopping, .stopped]` for a normal
      cycle and `[..., .failed(...)]` on a forced recorder error.
    - `Tests/MacrecCoreTests/RecordingSessionSplitTests.swift` —
      assert `split(nextOutput:)` emits
      `[.splitting, .recording]` and that the old recorder's
      `finalize` was called.
    - `Tests/MacrecCoreTests/LevelTapTests.swift` — verify the tap
      fires on every `CaptureBuffer` delivered by the fake source.
    - `Tests/MacrecCoreTests/PermissionGatingProtocolTests.swift` —
      conformance + injection through `RecordingSession.init`.

- **Outputs**:
  - `MacrecCore` exposes the four new APIs with no behavior change to
    existing call sites.
  - The CLI `macrec` continues to build and run.
  - Five new test files (compile-checked; runtime-untrusted per R-22).

- **Gate criteria**:
  - `swift build` exits 0 with zero warnings about deprecated APIs
    (AC-UI-1).
  - `swift build --product macrec` produces a binary that, when
    executed, has identical behavior to pre-Phase-A (CLI regression
    gate; AC-UI-14 pre-check).
  - `swift build --build-tests` exits 0 (compile-check of new test
    files).
  - All five test files import `Testing`, declare `@Suite` /
    `@Test`, and reference at least one assertion each.
  - `Issues - Pending Items.md` ISSUE-02 is marked **Resolved Phase A,
    plan-002**.

- **Parallelism note**: Within Phase A, the
  `Sources/MacrecCore/SessionState.swift` creation, the two
  `levelTap` additions, and the `PermissionGating` protocol extraction
  are independent and can be split across three coder agents. The
  `RecordingSession.swift` modifications (state stream + split + lock
  refactor + permission injection) are tightly coupled and MUST be a
  single coder. The five test files are independent of each other and
  can each run as a separate agent once their target API exists.

---

### Phase B — `Package.swift` + `MacrecUI-Info.plist`

- **Goal**: Register the new `macrec-ui` `executableTarget` in
  `Package.swift`, embed the UI's separate Info.plist via the
  `-sectcreate` linker pattern, and confirm `swift build --product
  macrec-ui` succeeds against an empty `main.swift` stub. This phase
  produces no functional UI yet — only the build slot. (Investigation
  Topic 7 Option 7A.)

- **Inputs**:
  - Investigation Topic 7 (verbatim plist + Package.swift snippets).
  - Codebase scan §4.3 (Package.swift current shape).
  - Existing `Resources/Info.plist` as a precedent (CLI plist).

- **Files**:
  - **Modify** `Package.swift`:
    - Add a new `.executable(name: "macrec-ui", targets:
      ["macrec-ui"])` to `products`.
    - Add a new `.executableTarget(name: "macrec-ui", dependencies:
      ["MacrecCore", .product(name: "Logging", package:
      "swift-log")], path: "Sources/macrec-ui", linkerSettings: [
      .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
      "-Xlinker", "__info_plist", "-Xlinker",
      "Resources/MacrecUI-Info.plist"]) ])`. Verbatim from
      investigation Topic 7.
    - **Do NOT** add `ArgumentParser` to UI deps (codebase scan
      §4.3).
  - **Create** `Resources/MacrecUI-Info.plist` — verbatim from
    investigation Topic 7. Required keys:
    `CFBundleIdentifier=com.local.macrec-ui`,
    `CFBundleExecutable=macrec-ui`, `CFBundleName=macrec-ui`,
    `CFBundleShortVersionString=0.1.0`, `CFBundleVersion=0.1.0`,
    `CFBundlePackageType=APPL`, `LSMinimumSystemVersion=14.0`,
    `LSUIElement=true`, `NSMicrophoneUsageDescription` (UI-specific
    string), `NSScreenCaptureUsageDescription` (UI-specific string),
    `NSScreenCaptureDescription` (mirror of the previous).
  - **Create** `Sources/macrec-ui/main.swift` — minimal stub:
    `import Foundation; print("macrec-ui placeholder"); exit(0)`.
    Replaced wholesale by Phase C.

- **Outputs**:
  - A `swift build --product macrec-ui` invocation produces
    `.build/debug/macrec-ui`.
  - `otool -P .build/debug/macrec-ui` shows the embedded Info.plist
    section with `LSUIElement=true` and `CFBundleIdentifier=com.local.macrec-ui`
    (investigation Topic 7 verification recipe).

- **Gate criteria**:
  - `swift build --product macrec-ui` exits 0 with zero warnings.
  - `swift build --product macrec` (CLI) still exits 0 — i.e. the
    Package.swift change does not regress the CLI.
  - `otool -P .build/debug/macrec-ui` prints the embedded plist with
    the required keys.

- **Parallelism note**: Phase B is independent of Phase A and runs in
  parallel with it after Phase 0 completes. No file overlap.

---

### Phase C — UI shell (status item + popover + activation policy)

- **Goal**: Land the AppKit shell that hosts the SwiftUI body — the
  `@main` SwiftUI App, the AppDelegate, the `NSStatusItem`, the
  `NSPopover`, and a `RootView` placeholder. After this phase, clicking
  the menu-bar icon opens an empty popover that closes on outside-click.

- **Inputs**:
  - Investigation Topic 1 Option 1B (verbatim shell shape, gotchas).
  - Codebase scan §4.3 (UI module file layout).
  - Phase B's `Sources/macrec-ui/main.swift` stub (replaced).

- **Files** (all under `Sources/macrec-ui/`):
  - **Replace** `Sources/macrec-ui/main.swift` with `MacrecUIApp.swift`
    — `@main struct MacrecUIApp: App` whose body is `Settings {
    EmptyView() }` with a `@NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate`.
  - **Create** `Sources/macrec-ui/AppDelegate.swift` — `final class
    AppDelegate: NSObject, NSApplicationDelegate`. Members:
    `var statusItem: NSStatusItem!`, `var popover: NSPopover!`,
    `var statusItemController: StatusItemController!`,
    `var popoverController: PopoverController!`, `var
    recordingController: RecordingController!`. In
    `applicationDidFinishLaunching(_ notification:)`:
    1. `LoggerFactory.bootstrap(level: .info)` (NFR-16).
    2. `NSApp.setActivationPolicy(.accessory)` (investigation Topic 1
       gotcha — defensive even with `LSUIElement=true`).
    3. Construct `RecordingController` and assign to `self`.
    4. Build status item via `StatusItemController` (Phase D).
    5. Build popover via `PopoverController` (Phase D).
    6. Wire status-button action to popover toggle.
    Also implement `applicationShouldTerminate(_:)` returning
    `.terminateLater` while `recordingController.state` is
    non-`.idle`/`.stopped`/`.failed` (Phase F finishes this; stub
    here returns `.terminateNow`).
  - **Create** `Sources/macrec-ui/StatusItemController.swift` — owns
    the `NSStatusItem`. API: `init(statusItem: NSStatusItem,
    onClick: @escaping () -> Void)`; method
    `func setIcon(for state: SessionState)` that maps states to
    template `NSImage`s (`circle`, `record.circle.fill`,
    `pause.circle.fill`, `exclamationmark.triangle.fill` —
    investigation Topic 1 §"Recommendation"). All images set
    `image.isTemplate = true`.
  - **Create** `Sources/macrec-ui/PopoverController.swift` — owns
    the `NSPopover` + its `NSHostingController<RootView>`. API:
    `init(rootView: RootView)`; `func toggle(relativeTo button:
    NSStatusBarButton)`; `func close()`. Behavior defaults to
    `.transient`; Phase E switches to `.semitransient` while
    `NSOpenPanel` is up (folder picker gotcha, investigation Topic 1).
  - **Create** `Sources/macrec-ui/RootView.swift` — placeholder
    SwiftUI view returning `Text("macrec-ui placeholder")` for now;
    Phase E replaces the body with the real form.

- **Outputs**:
  - Running `.build/debug/macrec-ui` shows a menu-bar icon, no Dock
    icon, and clicking the icon opens an empty popover that closes
    on outside-click.
  - `RecordingController` is alive in `AppDelegate` (long-lived
    parent for `Task`s).

- **Gate criteria**:
  - `swift build --product macrec-ui` exits 0 with zero warnings.
  - Manual smoke: launch produces a status icon visible in the menu
    bar; clicking opens / closes the popover.
  - No Dock icon visible (`LSUIElement=true` honored).
  - `applicationDidFinishLaunching` calls `setActivationPolicy(.accessory)`
    before status-item creation.
  - `statusItem` is held by a strong reference on `AppDelegate`
    (investigation Topic 1 gotcha — not a local variable).

- **Parallelism note**: Phase C internal files are tightly coupled
  (each is wired by `AppDelegate`). One coder agent owns the whole
  phase. Phase C depends on Phase B (the build slot exists) and Phase A
  (the `RecordingController` it instantiates depends on `SessionState`).

---

### Phase D — UI domain layer (controller + coordinator + helpers)

- **Goal**: Land the headless logic: `RecordingController` (view
  model), `SessionCoordinator` (pause/resume/split orchestration
  actor), `FilenameGenerator`, `SegmentNamer`, `LevelMeterTap` (vDSP),
  and a small `LevelMeterPublisher` that coalesces the 30 Hz stream.
  After this phase, no SwiftUI views consume them yet — Phase E does
  that — but unit tests can drive every method.

- **Inputs**:
  - Phase A engine extensions (`SessionState`, `stateStream`,
    `split(nextOutput:)`, `levelTap`).
  - Investigation Topics 2 (controller shape), 3 (coordinator shape),
    5 (level meter shape), 6 (filename helper shape).
  - Codebase scan §4.3 file placements.
  - `RecordingOptions` shape from
    `Sources/MacrecCore/Config/RecordingOptions.swift`.

- **Files** (all under `Sources/macrec-ui/`):
  - **Create** `Sources/macrec-ui/RecordingController.swift` — the
    `@MainActor @Observable final class RecordingController`. Fields
    per investigation Topic 2: `state`, `levels`, `segmentElapsed`,
    `totalElapsed`, `permissionSnapshot`, `latestErrorMessage`. Owns
    `runTask`, `stateTask`, `levelsTask`, and the `SessionCoordinator?`.
    Methods: `start(options:)`, `requestStop()`, `pause()`, `resume()`,
    `split()`, `cancelAll()`. Strict `@MainActor` discipline — every
    write to observed properties is on main.
  - **Create** `Sources/macrec-ui/SessionCoordinator.swift` —
    `actor SessionCoordinator` per investigation Topic 3 verbatim
    shape. Holds `basename`, `folder`, `baseOptions`, `segmentCounter`,
    `current: RecordingSession?`, `currentRunTask: Task<Void, Error>?`,
    `stateStream`, `stateContinuation`. Synthesizes `.pausing →
    .paused → .resuming` between sessions. `stop()` finalizes the
    current segment and emits `.stopped`.
  - **Create** `Sources/macrec-ui/FilenameGenerator.swift` —
    investigation Topic 6 verbatim shape (`en_US_POSIX` locale, format
    `yyyy-MM-dd-HHmmss`). Returns basename + extension only; folder
    join happens in `RecordingController`.
  - **Create** `Sources/macrec-ui/SegmentNamer.swift` — pure helper
    that takes `(basename: String, ext: String, layout: TrackLayout,
    segmentNumber: Int, totalSegments: Int) -> URL` (or `[URL]` for
    `--layout split`). FR-34 rules:
    - `totalSegments == 1` → no `partNN` infix.
    - `totalSegments > 1` → `<basename>.partNN.<ext>` (or
      `.partNN.mic.<ext>` / `.partNN.system.<ext>` for split layout —
      infix BEFORE the `.mic`/`.system` token, per FR-34).
  - **Create** `Sources/macrec-ui/LevelMeterTap.swift` —
    investigation Topic 5 verbatim shape. Pre-allocated
    `AVAudioPCMBuffer` (4096-sample headroom), `OSAllocatedUnfairLock`
    around `lastEmit: ContinuousClock.Instant`, vDSP_rmsqv +
    vDSP_maxmgv, dB conversion clamped at -80, yields into an
    `AsyncStream<LevelSample>` with `.bufferingNewest(2)`.
  - **Create** `Sources/macrec-ui/LevelMeterPublisher.swift` — small
    facade that owns one `LevelMeterTap` per source (mic + system),
    merges the two streams, and re-emits to a single
    `AsyncStream<LevelSample>` consumed by `RecordingController`.
  - **Create** `Sources/macrec-ui/LevelSample.swift` — the
    `Sendable` value type per investigation Topic 5.
  - **Create** Swift Testing test files under
    `Tests/MacrecUITests/` (NEW test target — see §6 file manifest):
    - `Tests/MacrecUITests/FilenameGeneratorTests.swift` — golden
      strings against fixed `Date`s.
    - `Tests/MacrecUITests/SegmentNamerTests.swift` — exhaustive
      cases (single, multi, split layout) per FR-34.
    - `Tests/MacrecUITests/SessionCoordinatorTests.swift` — drives
      the coordinator with a stubbed `RecordingSession` factory;
      asserts state synthesis sequence.
    - `Tests/MacrecUITests/RecordingControllerTests.swift` — drives
      `start → pause → resume → stop` against a stubbed coordinator;
      asserts `state` transitions on `@MainActor`.
  - **Modify** `Package.swift` — add `.testTarget(name:
    "MacrecUITests", dependencies: ["macrec-ui"], path:
    "Tests/MacrecUITests")`. Note: testing an `executableTarget`
    requires a small refactor — see Parallelism note.

- **Outputs**:
  - The headless UI domain layer is fully implemented and
    test-covered (compile-only on the dev host per R-22).
  - `RecordingController` is wired to the `RecordingSession`
    extensions from Phase A.

- **Gate criteria**:
  - `swift build --product macrec-ui` exits 0 with zero warnings.
  - `swift build --build-tests` exits 0 (test target compiles).
  - Each new file has at least one Swift Testing `@Test` referencing
    it (compile-checked).
  - `RecordingController.start(options:)` accepts a real
    `RecordingOptions` and constructs a real `SessionCoordinator`
    (no compile-time dependency on stubs).

- **Parallelism note**: `FilenameGenerator`, `SegmentNamer`,
  `LevelSample`, and `LevelMeterTap` are all independent files and can
  be split across four coder agents. `RecordingController` and
  `SessionCoordinator` are tightly coupled (the former owns the
  latter); one agent owns both. The four test files are independent of
  each other once their target API exists.
  **Caveat**: Swift Testing on an `executableTarget` requires either
  splitting headless logic into a small library target (e.g., a
  `MacrecUIKit` `.library` target that the executable links and that
  the test target also links — clean approach), or the
  `@testable import macrec_ui` pattern (less clean but no Package.swift
  refactor). The plan recommends the former: add a `MacrecUIKit`
  library target containing all non-`@main` files, and reduce
  `Sources/macrec-ui/` to `MacrecUIApp.swift` + `AppDelegate.swift` +
  `main.swift` (entry only). This is clarified in the Files section
  above as a Phase-D Package.swift edit. AMB-3 review by Phase 5
  Designer.

---

### Phase E — UI views (popover form + sub-views)

- **Goal**: Replace the `RootView` placeholder with the real popover
  form. Build each "core extra" and "optional extra" as a focused
  sub-view. Wire every control to `RecordingController` via the
  SwiftUI environment.

- **Inputs**:
  - Phase D's `RecordingController` (the data source for every view).
  - Refined-spec FR-35..FR-43 (per-control behavior).
  - Investigation Topic 5 (level-meter rendering cadence — `for await`
    with `.animation(.linear(duration: 0.05))` smoothing).

- **Files** (all under `Sources/macrec-ui/Views/` — new sub-folder):
  - **Replace** `Sources/macrec-ui/RootView.swift` body — vertical
    stack: filename row, format/layout row, folder picker row, mic
    dropdown row, permission indicator row, control-button row,
    elapsed-time row, level-meters row, "saved to" disclosure row.
    Each row reads `@Environment(\.recordingController)`.
  - **Create** `Sources/macrec-ui/Views/FilenameField.swift` (FR-35) —
    `TextField` bound to `recordingController.basename`; locked
    (`disabled(...)`) when state is non-`.idle`; renders resolved
    path as a small caption below.
  - **Create** `Sources/macrec-ui/Views/FormatPicker.swift` (FR-38) —
    `Picker` over `OutputFormat`; persists via `@AppStorage("com.macrec.ui.format")`;
    disabled while recording. On selection change, updates the
    extension shown in `FilenameField`.
  - **Create** `Sources/macrec-ui/Views/LayoutPicker.swift` (FR-38) —
    same shape, over `TrackLayout`;
    `@AppStorage("com.macrec.ui.layout")`.
  - **Create** `Sources/macrec-ui/Views/FolderPicker.swift` (FR-36) —
    "Choose Folder…" button that opens an `NSOpenPanel`
    (folder-only, single selection). Persists via
    `@AppStorage("com.macrec.ui.outputFolder")` (URL bookmarks if
    needed for sandbox future). Default `~/Recordings/`; create on
    first use if missing. **Wraps the open-panel call in a
    `popoverController.setBehavior(.semitransient)` /
    `.transient`-restore pair** per investigation Topic 1 gotcha.
  - **Create** `Sources/macrec-ui/Views/MicrophonePicker.swift`
    (FR-39) — `Picker` over `AudioInputDevice` from
    `AudioDeviceEnumerator.listInputs()`. Persists by `uid` via
    `@AppStorage("com.macrec.ui.micUID")`. Refresh on
    `AVCaptureDeviceWasConnectedNotification` /
    `AVCaptureDeviceWasDisconnectedNotification` (use a
    `.onReceive(NotificationCenter.default.publisher(...))` block).
    Disabled while recording.
  - **Create** `Sources/macrec-ui/Views/PermissionStatusView.swift`
    (FR-37) — two indicator rows (Screen Recording, Microphone),
    each with a colored badge (green / red / yellow) per
    `granted` / `denied` / `not-determined`. Polls via a 2 s
    `Timer.publish` while popover is visible (use
    `.onReceive(NotificationCenter.default.publisher(for:
    NSWindow.didBecomeKeyNotification))` to refresh). Tapping a
    `denied` row opens the System Settings deep link from
    project-design §8 (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording`
    / `Privacy_Microphone`). Tapping a `not-determined` row triggers
    the underlying TCC prompt via the existing
    `*Permission.request()` calls.
  - **Create** `Sources/macrec-ui/Views/ElapsedTimeView.swift`
    (FR-40) — two `HH:MM:SS` labels (segment + cumulative). Driven
    by a 1 Hz `TimelineView(.periodic(from:by:1))` while popover is
    visible. Reads `recordingController.segmentElapsed` /
    `.totalElapsed`.
  - **Create** `Sources/macrec-ui/Views/ControlBar.swift` — five
    buttons: Start, Pause, Resume, Stop, Split. Enabled/disabled
    derived from `recordingController.state` per FR-33 transition
    table:
    | State | Start | Pause | Resume | Stop | Split |
    |-------|-------|-------|--------|------|-------|
    | idle | ENABLED (if perms granted) | – | – | – | – |
    | starting / stopping | – | – | – | – | – |
    | recording | – | ENABLED | – | ENABLED | ENABLED |
    | pausing / paused / resuming | – | – | ENABLED (paused) | ENABLED | – |
    | splitting | – | – | – | – | – |
    | stopped / failed | reset to idle on next user action | – | – | – | – |
  - **Create** `Sources/macrec-ui/Views/LevelMeterView.swift` (FR-43)
    — two horizontal bars (mic, system); each renders peak (lighter
    line) + RMS (filled). Reads
    `recordingController.levels[.mic]` / `[.system]` with
    `.animation(.linear(duration: 0.05))` smoothing per
    investigation Topic 5.
  - **Create** `Sources/macrec-ui/Views/SavedToDisclosure.swift`
    (FR-34, OQ-UI-11) — a disclosure showing the resolved output
    file(s). For `--layout split`, lists both `.mic` and `.system`
    files; for multi-segment, lists every `.partNN` file produced so
    far (read from `recordingController.completedSegments: [URL]`).
  - **Create** `Sources/macrec-ui/Views/RecordingControllerKey.swift`
    — `EnvironmentKey` defining `recordingController` so each view
    can pull from the SwiftUI environment.
  - **Create** Swift Testing tests under
    `Tests/MacrecUITests/Views/` only for the headless behavior
    (button-enable matrix is computed in `RecordingController`, not
    in views, so the existing `RecordingControllerTests.swift`
    covers it). No SwiftUI snapshot tests (out of scope per NFR-14).

- **Outputs**:
  - The popover, when opened, renders all twelve UI elements above.
  - Every control is wired to `RecordingController` and persists state
    via `@AppStorage` where applicable.

- **Gate criteria**:
  - `swift build --product macrec-ui` exits 0 with zero warnings.
  - Manual smoke (deferred to Phase K): every control is visible and
    responds to clicks per the FR table.
  - `@AppStorage` keys match the FR-36 / FR-38 / FR-39 specifications
    (`com.macrec.ui.outputFolder`, `com.macrec.ui.format`,
    `com.macrec.ui.layout`, `com.macrec.ui.micUID`).
  - The `OPENAI_API_KEY`-style "no fallback config" rule does not
    apply here (UserDefaults is UI state, not configuration —
    explicitly called out in refined-spec Constraints).

- **Parallelism note**: Each view file is independent of the others
  once `RecordingController` and the EnvironmentKey exist. Up to nine
  coder agents can work in parallel: one per view file
  (`FilenameField`, `FormatPicker`, `LayoutPicker`, `FolderPicker`,
  `MicrophonePicker`, `PermissionStatusView`, `ElapsedTimeView`,
  `ControlBar`, `LevelMeterView`, `SavedToDisclosure`). The
  `RootView` and `RecordingControllerKey` are written by a tenth
  agent that integrates them.

---

### Phase F — Quit-while-recording flow

- **Goal**: Honor OQ-UI-10: when the user invokes Quit (Cmd-Q from a
  context menu, or `applicationShouldTerminate` from the system) while
  a recording is active, present a confirm dialog, and on confirm
  finalize the current file then quit.

- **Inputs**:
  - Phase C `AppDelegate.applicationShouldTerminate` stub.
  - Phase D `RecordingController.requestStop()` and the `state`
    observable.
  - Investigation §"Implementation considerations" item 6
    (`terminateLater` + `reply(toApplicationShouldTerminate:)`
    pattern).

- **Files**:
  - **Modify** `Sources/macrec-ui/AppDelegate.swift`:
    - Replace the stub `applicationShouldTerminate` with the real
      flow: if `recordingController.state` is in
      `[.recording, .paused, .pausing, .resuming, .splitting]`,
      present an `NSAlert` ("Stop recording and quit?" with
      Cancel + "Stop & Quit" buttons). On Cancel: return
      `.terminateCancel`. On confirm: call
      `recordingController.requestStop()`, return
      `.terminateLater`, and observe `state` for `.stopped` /
      `.failed`. When that lands, call
      `NSApp.reply(toApplicationShouldTerminate: true)`.
    - Add a "Quit" menu item to a context menu on the status item
      (or a button at the bottom of the popover) that invokes
      `NSApp.terminate(nil)`. (No app menu — `LSUIElement=true`.)

- **Outputs**:
  - User-initiated Quit while recording produces a confirm alert; on
    confirm the file is finalized and the process exits cleanly.

- **Gate criteria**:
  - `swift build --product macrec-ui` exits 0.
  - Manual smoke (Phase K): start a recording → click Quit →
    confirm → verify the file is playable in QuickTime and the
    process exits 0.
  - `applicationShouldTerminate` returns `.terminateNow` when state
    is `.idle`, `.stopped`, or `.failed`.

- **Parallelism note**: Phase F is a single-file edit; one coder
  agent. Phase F runs in parallel with Phase G (error mapping) and
  Phase H (logging) — they touch different files.

---

### Phase G — Error mapping (`MacrecError` → user-facing alerts)

- **Goal**: Surface engine errors to the user via non-intrusive UI
  banners / toasts, never via stderr. Reuse `MacrecError.description`
  + `.remediation` per codebase scan §3.

- **Inputs**:
  - `Sources/MacrecCore/Errors/MacrecError.swift` (existing 26 cases).
  - Phase D `RecordingController.latestErrorMessage` field.
  - NFR-12 (crash isolation: a recoverable engine error MUST NOT
    bring down the UI process).

- **Files**:
  - **Create** `Sources/macrec-ui/Views/ErrorBanner.swift` — a small
    banner view that renders `latestErrorMessage` at the top of the
    popover when non-nil; auto-dismisses after 8 s or on click.
  - **Modify** `Sources/macrec-ui/RecordingController.swift`:
    - On receiving a `.failed(error)` state, set
      `latestErrorMessage = "\(error.description)\n\(error.remediation)"`.
      Schedule auto-clear after 8 s.
    - Distinguish recoverable errors (kept in UI as banners) from
      unrecoverable ones (currently none in the UI flow — the CLI
      exit-code mapping doesn't apply). All `MacrecError` cases are
      treated as banner-displayable.
  - **Modify** `Sources/macrec-ui/RootView.swift`:
    - Insert `ErrorBanner` at the top of the popover stack, bound to
      `recordingController.latestErrorMessage`.

- **Outputs**:
  - Engine errors render in a banner with description + remediation;
    UI process never crashes on a recoverable error.

- **Gate criteria**:
  - `swift build --product macrec-ui` exits 0.
  - Unit test in `Tests/MacrecUITests/RecordingControllerTests.swift`
    asserts that `state = .failed(.permissionDenied)` produces a
    non-nil `latestErrorMessage`.
  - Manual smoke (Phase K): revoke Microphone permission → click
    Start → banner appears with the documented remediation.

- **Parallelism note**: Phase G is two-file edits; one coder agent.
  Independent of Phases F and H.

---

### Phase H — Logging (Console.app + per-UI log file)

- **Goal**: Route UI logs through the existing `LoggerFactory` /
  swift-log pipeline. Emit to `~/.tool-agents/macrec-ui/macrec-ui.log`
  (mode `0600`, append) when running outside an Xcode debugger
  session, mirroring FR-29's pattern. Default level `.info`; hidden
  toggle to `.debug`.

- **Inputs**:
  - `LoggerFactory.bootstrap(level:)` and `LoggerFactory.make(_:)`
    from `Sources/MacrecCore/Logging/LoggerFactory.swift`.
  - NFR-16 (per-UI log file path + permission requirements).
  - `Sources/MacrecCore/Bootstrap/ToolAgentsBootstrap.swift` (existing
    `ensure(toolName:)` reused).

- **Files**:
  - **Modify** `Sources/macrec-ui/AppDelegate.swift`:
    - In `applicationDidFinishLaunching` (early): call
      `try ToolAgentsBootstrap.ensure(toolName: "macrec-ui")` to
      create `~/.tool-agents/macrec-ui/` at mode `0700` and seed
      `.env` at `0600`. If launched from a TTY (debugger), skip the
      log redirection and let stderr be the sink. Otherwise, open
      `~/.tool-agents/macrec-ui/macrec-ui.log` (mode `0600`, append)
      and `dup2(logFd, STDERR_FILENO)`. Same pattern as the CLI's
      `Daemonizer` minus the double-fork.
    - Call `LoggerFactory.bootstrap(level: .info)` once.
    - Build the AppDelegate's logger via
      `LoggerFactory.make("macrec.ui.app")`.
  - **Create** `Sources/macrec-ui/UILoggingMenu.swift` — a small
    helper that adds "Show debug log" / "Hide debug log" menu items
    to the status-item context menu; toggling re-bootstraps
    `LoggerFactory.bootstrap(level: .debug)` (the function is
    documented as idempotent in codebase scan §3).
  - **Modify** `Sources/macrec-ui/RecordingController.swift`:
    - Acquire `Logger` via `LoggerFactory.make("macrec.ui.controller")`
      and emit `.error` on every `.failed(error)` state with the
      MacrecError context. Per NFR-16.
  - **Modify** `Sources/macrec-ui/SessionCoordinator.swift`:
    - Acquire `Logger` via `LoggerFactory.make("macrec.ui.session")`
      and emit `.info` on each segment boundary.

- **Outputs**:
  - Running `macrec-ui` outside a debugger writes its logs to
    `~/.tool-agents/macrec-ui/macrec-ui.log` (verified via `tail -f`).
  - Console.app shows the same logs in real time when launched from
    an active debugger session.
  - Errors surface at `.error` level by NFR-16.

- **Gate criteria**:
  - `swift build --product macrec-ui` exits 0.
  - `~/.tool-agents/macrec-ui/macrec-ui.log` exists at mode `0600`
    after a launch.
  - The "Show debug log" toggle re-bootstraps the level; subsequent
    `.debug` logs appear in the file.

- **Parallelism note**: Phase H touches AppDelegate (shared with Phase
  F) and adds two new files. The AppDelegate edits are non-overlapping
  with Phase F's; both can be applied independently and merged. One
  coder agent owns Phase H.

---

### Phase I — Test build (gated by R-22)

- **Goal**: Ensure every test file from Phases A and D compiles
  cleanly, and that the test surface is exhaustive enough that a
  CI-side full-Xcode run will exercise meaningful behavior. Per R-22
  (continuation of R-17), `swift test` output is NOT trusted on the
  dev host.

- **Inputs**:
  - All test files written in Phases A and D.
  - Issues - Pending Items.md R-17 (existing) + R-22 (new).

- **Files**:
  - No NEW source files. The phase consists of:
    - **Modify** `Tests/MacrecCoreTests/` files as needed if Phase A
      tests revealed compile gaps.
    - **Modify** `Tests/MacrecUITests/` files as needed if Phase D
      tests revealed compile gaps.
    - **Modify** `Issues - Pending Items.md` — append a "Phase I
      gate" note clarifying that `swift test` results are not
      trustworthy on the dev host (dovetails with R-17 and R-22).
    - **Create** `test_scripts/ci-run-tests.sh` — a helper script
      future CI can run in a full-Xcode environment:
      ```sh
      #!/usr/bin/env bash
      set -euo pipefail
      swift test --enable-code-coverage 2>&1 | tee test.log
      grep -q "Test Suite 'All tests' passed" test.log
      ```
      Marked executable.

- **Outputs**:
  - `swift build --build-tests` exits 0.
  - A reusable CI script exists.
  - Issues - Pending Items.md documents the trust boundary.

- **Gate criteria**:
  - `swift build --build-tests` exits 0 with zero warnings.
  - Every `@Test` declaration has at least one assertion (audited
    by `grep -c "#expect" Tests/...`).
  - R-22 entry exists in `Issues - Pending Items.md` referencing
    Phase I and the future Xcode-based CI.

- **Parallelism note**: Phase I is a verification/audit pass, single
  coder. It runs after Phases A, D, E, F, G are complete (their tests
  exist). It can run alongside Phase J.

---

### Phase J — Documentation update (Designer + cleanup)

- **Goal**: Finalize all v1 documentation that does NOT live in
  `project-design.md` (which Phase 5 Designer owns). Specifically:
  populate the operator-facing content of `docs/tools/macrec-ui.md`
  produced in Phase 0; resolve ISSUE-02 in `Issues - Pending Items.md`;
  add R-22..R-25 if not already present from Phase 0; cross-check the
  FR-30..FR-44 status fields after implementation lands.

- **Inputs**:
  - Phase 0's scaffolded `docs/tools/macrec-ui.md`.
  - `docs/tools/macrec.md` as a precedent for the `<info>` block
    contents.
  - `Issues - Pending Items.md` current state.
  - The implemented behavior from Phases A–H.

- **Files**:
  - **Modify** `docs/tools/macrec-ui.md`:
    - Fill in the `<info>` block: launch from `swift run macrec-ui`
      or `.build/debug/macrec-ui`; how to grant TCC; how to use
      every UI control; where files land (default
      `~/Recordings/`); behavior on Quit while recording; how to
      switch debug logging.
    - Reference `Issues - Pending Items.md` for known caveats
      (R-22..R-25).
  - **Modify** `Issues - Pending Items.md`:
    - Confirm ISSUE-02 is in the **Completed items** section
      (Phase A resolves it).
    - Confirm R-22..R-25 are present in the **Pending items**
      section (Phase 0 should have added them; verify here).
  - **Modify** `docs/design/project-functions.md`:
    - For each FR-30..FR-44, update **Status:** from `PLANNED` to
      `IMPLEMENTED` if the corresponding phase has shipped at the
      time Phase J runs. (Phase J is the last phase before K, so
      most should flip.)
  - **Modify** `CLAUDE.md`:
    - Verify the `## Tools` entry for `macrec-ui` is present (Phase
      0 added it). Adjust the one-line summary if implementation
      revealed a different scope.
  - **NOT modified by this phase**: `docs/design/project-design.md`.
    That belongs to Phase 5 (Designer), which runs separately.

- **Outputs**:
  - Operator-facing tool docs are complete.
  - Project-functions registry is up-to-date.
  - Pending issues file is consistent.

- **Gate criteria**:
  - `docs/tools/macrec-ui.md` `<info>` block contains a usage walk-
    through of every control listed in §2.1 of this plan.
  - `Issues - Pending Items.md` has no orphaned references
    (e.g., ISSUE-02 not still in Pending after being moved to
    Completed).
  - `/tool-conventions audit macrec-ui` passes.

- **Parallelism note**: Phase J runs in parallel with Phase E / Phase
  F / Phase G — it touches only documentation files, never source
  files. One agent owns the four edits.

---

### Phase K — Manual smoke test + AC verification

- **Goal**: Walk the complete acceptance-criteria checklist (AC-UI-1
  through AC-UI-18) on the dev host, confirm no CLI regression
  (AC-1..AC-20 still pass), and gate the v1.1 ship.

- **Inputs**:
  - All previous phases complete.
  - `docs/tools/macrec.md` "Manual TCC test prerequisite for E2E
    scripts" — TCC procedure already established for the CLI.
  - `Issues - Pending Items.md` current state.

- **Files**:
  - **Create** `test_scripts/e2e-ui-smoke.md` — a checklist document
    walking through AC-UI-1..AC-UI-18 with the exact click sequence
    and the expected on-disk artifact for each. Each item is a
    checkbox the developer ticks during a smoke run.
  - **Modify** `Issues - Pending Items.md` — log any failures
    discovered during Phase K (these become inputs to a v1.1.x
    follow-up).

- **Outputs**:
  - A signed-off checklist documenting the v1.1 ship.

- **Gate criteria** (this is the final ship gate):
  - **Build & install**:
    - `swift build -c release` exits 0 with zero deprecated-API
      warnings (AC-UI-1).
    - `swift build --product macrec` (CLI) still produces a working
      binary that passes the existing CLI smoke (AC-UI-14
      regression gate; reuse `test_scripts/e2e-30s-mixed.sh`).
  - **First-launch UX** (AC-UI-2, AC-UI-3): on a `tccutil
    reset`-cleaned host, the UI shows "not determined" indicators;
    Start is disabled; clicking each indicator triggers the right
    prompt or System Settings deep link.
  - **Lifecycle**:
    - Start → Stop produces a playable file within ±0.5 s of the
      elapsed-time indicator (AC-UI-4, AC-UI-5).
    - Pause → Resume produces a `.partNN` second segment within 30 s
      finalize timeout (AC-UI-6, FR-34, FR-20).
    - Split during recording produces consecutive segments with
      seam ≤ 250 ms measured against
      `afinfo` durations (AC-UI-7) — this is the R-25 measurement
      gate.
  - **UX**:
    - Filename field locks during recording (AC-UI-8).
    - Folder picker persists across launch (AC-UI-9).
    - Layout-split + Pause produces four `.partNN.{mic,system}`
      files per FR-34 (AC-UI-10).
    - Mic dropdown reflects `list-devices` output and refreshes on
      hot-plug within 2 s (AC-UI-11).
    - Elapsed-time indicator advances at 1 Hz, freezes on pause
      (AC-UI-12).
    - Force-quit during recording leaves a playable partial file
      (AC-UI-13, FR-21 reuse).
  - **Documentation**:
    - `docs/tools/macrec-ui.md` exists, `~/.tool-agents/macrec-ui/.env`
      exists, `## Tools` entry exists (AC-UI-15).
    - FR-30..FR-44 in `project-functions.md` show
      `Status: IMPLEMENTED` (AC-UI-16).
    - `project-design.md` has a new UI section (AC-UI-17) — Phase 5
      Designer's deliverable.
    - `Issues - Pending Items.md` is up-to-date (AC-UI-18).
  - **No CLI regression**: AC-1..AC-20 from `plan-001-recording-tool.md`
    §7 still pass. Reuse `test_scripts/e2e-30s-mixed.sh` and
    `test_scripts/e2e-layout-split.sh` for spot checks.

- **Parallelism note**: Phase K is sequential by definition — one
  developer driving a manual checklist on a real host.

---

## Section 4 — Dependency Graph

```
Phase 0 (docs scaffolding) ─┬─► Phase A (engine extensions)
                            └─► Phase B (Package + plist)
                                       │
                                       ▼
                                Phase C (UI shell)
                                       │
                                       ▼
                                Phase D (UI domain layer)
                                       │
                                       ▼
                                Phase E (UI views)
                                       │
                                       ▼
                                Phase F (Quit-while-rec)
                                       │
                                       ▼
                                Phase G (Error mapping)
                                       │
                                       ▼
                            (parallel) Phase H (Logging)
                            (parallel) Phase J (Docs)
                                       │
                                       ▼
                                Phase I (Test build audit)
                                       │
                                       ▼
                                Phase K (Manual smoke)
```

- **Phases 0 → A**: A consumes the FR registry written by 0.
- **Phases 0 → B**: B reuses the plist conventions referenced by 0's
  tool docs.
- **Phase A and Phase B are independent** of each other; they can run
  in parallel after Phase 0.
- **Phase C** depends on BOTH A and B (it instantiates
  `RecordingController` whose state machine is `SessionState` from
  Phase A, and it builds against the target slot from Phase B).
- **Phase D** depends on Phase C (`RecordingController` is wired into
  `AppDelegate`) — though strictly speaking, Phase D could begin in
  parallel with Phase C if `RecordingController` is treated as a
  standalone class first and wired into AppDelegate after both land.
  The plan keeps them sequential for clarity.
- **Phase E** depends on Phase D (every view reads
  `RecordingController` through the SwiftUI environment).
- **Phases F, G** depend on Phase E (they reference `RootView`).
- **Phases H, J** can run in parallel with Phase E, F, or G — they
  touch AppDelegate / docs only.
- **Phase I** depends on every test-author phase (A and D); it gates
  the test-target compile.
- **Phase K** depends on every prior phase. Final gate.

**Suggested parallelization for Phase 6 (parallel coders)**:
- Wave 1 (after Phase 0): A + B in parallel (two coder agents).
- Wave 2 (after Wave 1): C alone (one agent).
- Wave 3 (after Wave 2): D alone (one agent).
- Wave 4 (after Wave 3): E (up to ten agents per file) + H (one
  agent) + J (one agent) in parallel.
- Wave 5 (after Wave 4): F + G in parallel (two agents).
- Wave 6: I (one agent).
- Wave 7: K (manual, one developer).

---

## Section 5 — Risk Register

> Risks newly surfaced by this plan. Existing R-1..R-21 from
> `Issues - Pending Items.md` continue to apply where relevant. Phase 0
> registers R-22..R-25 in `Issues - Pending Items.md`.

| ID | Risk | Severity | Mitigation | Owner |
|----|------|----------|------------|-------|
| **R-22 (toolbar)** | `swift test` exits 0 silently on Apple CommandLineTools (continuation of R-17). Tests written in Phases A and D compile but cannot be trusted on the dev host. | High (DX) | Author every test with `import Testing` + `@Suite` / `@Test` so it is ready for a real runner. Re-run on a CI image with full Xcode before declaring Phase I complete. Document in Phase I gate. | Phase I, Phase 7 (Code Reviewer), user (CI provisioning) |
| **R-23 (toolbar)** | TCC re-prompt on every UI rebuild because `com.local.macrec-ui` is a different bundle id from the CLI's `com.local.macrec`. Granting Screen Recording to the CLI does NOT grant it to the UI. | Medium (DX) | Document prominently in `docs/tools/macrec-ui.md` and `Issues - Pending Items.md`. Do not attempt to fix in v1; defer to v2 `.app` packaging with stable Developer-ID signature. | Phase J (docs); user accepts the rebuild-reprompt cost |
| **R-24 (toolbar)** | SwiftUI `MenuBarExtra` Apple Feedback bugs (FB11984872, FB10185639, FB10185468) prevent the four FR-41 status-icon states and programmatic dismiss. | High (architecture) | **Already mitigated by the locked architecture**: use AppKit `NSStatusItem` + `NSPopover` + `NSHostingController<RootView>` (investigation Topic 1 Option 1B), NOT `MenuBarExtra`. No further mitigation needed. | Phases C, E (architecture lock) |
| **R-25 (toolbar)** | Manual split (`split()` atomic-swap) inherits an audible seam gap of up to ~52 ms (10 ms swap latency + 42 ms AAC priming for m4a; ~10 ms for wav/caf). AC-UI-7 ceiling is 250 ms. | Low | Measure during Phase K with `afinfo` durations on consecutive segments. Headroom is comfortable (≥ 200 ms). If observed seam exceeds 100 ms in the field, revisit Topic 4 — pre-warm the new recorder earlier in the swap. | Phase K (verification); user accepts the ≤ 250 ms ceiling |
| **R-26 (toolbar)** | `NSStatusItem` deallocated silently if not retained on `AppDelegate` (icon vanishes with no error). | Low | Phase 7 Code Reviewer must verify `AppDelegate.statusItem` is a stored property (strong reference). Code review checklist item. | Phase 7 |
| **R-27 (toolbar)** | `NSOpenPanel` interaction with `.transient` popover: opening the folder picker dismisses the popover. | Low | Folder-picker code switches popover to `.semitransient` for the duration of the panel and restores `.transient` on close (investigation Topic 1 gotcha). Verified by Phase K folder-picker walk-through. | Phase E (FolderPicker) |
| **R-28 (toolbar)** | `AsyncStream` continuation leaks if `.finish()` is not called on session teardown. | Low | `RecordingSession.resolveRunLoop` calls `stateContinuation.finish()` at exit (investigation Topic 2 §"AsyncStream continuation lifecycle"). Code review checklist item. | Phase A, Phase 7 |
| **R-29 (toolbar)** | SCStream cold-start latency on Resume (~200–500 ms on Apple Silicon). Each Resume incurs SCStream warmup. | Low | v1 spec does not impose a Resume-latency SLO. Measure during Phase K AC-UI-6; if observed cold-start > 1 s consistently, file a v1.1 follow-up to pre-warm a parked SCStream. | Phase K |

Continuing prior risks that still apply:
- **R-2** (TCC ad-hoc-signing instability) — applies to UI as much as
  CLI; user already accepts.
- **R-13** (recording during system sleep) — applies to UI sessions
  too; existing engine mitigation reused.
- **R-17** — superseded by R-22 above.
- **ISSUE-02** — **resolved by Phase A** (PermissionGating protocol
  injection).

---

## Section 6 — File Manifest

> Flat list of every file this plan creates or modifies. Used by Phase
> 6 to assign non-overlapping work to parallel coders. **Path is
> absolute relative to the project root**: `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/`.

### 6.1 Source files — created

| File | Purpose | Phase |
|------|---------|-------|
| `Sources/MacrecCore/SessionState.swift` | `SessionState` enum + helpers (FR-33). | A |
| `Sources/macrec-ui/MacrecUIApp.swift` | SwiftUI `@main` App with `Settings { EmptyView() }` scene + `@NSApplicationDelegateAdaptor`. | C |
| `Sources/macrec-ui/AppDelegate.swift` | `NSApplicationDelegate`; status item, popover, activation policy, controller, terminate flow. | C / F / H |
| `Sources/macrec-ui/StatusItemController.swift` | Owns `NSStatusItem`; maps `SessionState` → icon (FR-41). | C |
| `Sources/macrec-ui/PopoverController.swift` | Owns `NSPopover` + `NSHostingController<RootView>`; toggle / close (FR-30). | C |
| `Sources/macrec-ui/RootView.swift` | Top-level SwiftUI body that composes every sub-view. | C / E / G |
| `Sources/macrec-ui/RecordingController.swift` | `@MainActor @Observable` view model owning Tasks + coordinator (FR-33). | D / G / H |
| `Sources/macrec-ui/SessionCoordinator.swift` | `actor` orchestrating multi-segment pause/resume (FR-31, FR-34). | D / H |
| `Sources/macrec-ui/FilenameGenerator.swift` | Auto-named timestamp default (FR-35). | D |
| `Sources/macrec-ui/SegmentNamer.swift` | `partNN` URL computation (FR-34). | D |
| `Sources/macrec-ui/LevelMeterTap.swift` | vDSP peak/RMS extraction with pre-allocated buffer (FR-43). | D |
| `Sources/macrec-ui/LevelMeterPublisher.swift` | Merges per-source streams into one (FR-43). | D |
| `Sources/macrec-ui/LevelSample.swift` | `Sendable` value type for level samples. | D |
| `Sources/macrec-ui/UILoggingMenu.swift` | Hidden debug-log toggle helper (NFR-16). | H |
| `Sources/macrec-ui/Views/RecordingControllerKey.swift` | SwiftUI `EnvironmentKey` for `recordingController`. | E |
| `Sources/macrec-ui/Views/FilenameField.swift` | Filename input field (FR-35). | E |
| `Sources/macrec-ui/Views/FormatPicker.swift` | Format dropdown (FR-38). | E |
| `Sources/macrec-ui/Views/LayoutPicker.swift` | Layout dropdown (FR-38). | E |
| `Sources/macrec-ui/Views/FolderPicker.swift` | Output folder picker via `NSOpenPanel` (FR-36). | E |
| `Sources/macrec-ui/Views/MicrophonePicker.swift` | Mic dropdown via `AudioDeviceEnumerator` (FR-39). | E |
| `Sources/macrec-ui/Views/PermissionStatusView.swift` | TCC indicator (FR-37). | E |
| `Sources/macrec-ui/Views/ElapsedTimeView.swift` | 1 Hz elapsed-time indicator (FR-40). | E |
| `Sources/macrec-ui/Views/ControlBar.swift` | Start / Pause / Resume / Stop / Split buttons (FR-31, FR-32). | E |
| `Sources/macrec-ui/Views/LevelMeterView.swift` | Per-source bar render (FR-43). | E |
| `Sources/macrec-ui/Views/SavedToDisclosure.swift` | Output-files disclosure (FR-34, OQ-UI-11). | E |
| `Sources/macrec-ui/Views/ErrorBanner.swift` | Banner for `MacrecError` surfacing (NFR-12). | G |
| `Resources/MacrecUI-Info.plist` | UI's separate Info.plist with `LSUIElement=true` (FR-30). | B |
| `Tests/MacrecCoreTests/SessionStateTests.swift` | Enum exhaustiveness + Equatable. | A |
| `Tests/MacrecCoreTests/RecordingSessionStateStreamTests.swift` | `stateStream` emits expected sequence. | A |
| `Tests/MacrecCoreTests/RecordingSessionSplitTests.swift` | `split(nextOutput:)` swap behavior. | A |
| `Tests/MacrecCoreTests/LevelTapTests.swift` | `levelTap` invocation per buffer. | A |
| `Tests/MacrecCoreTests/PermissionGatingProtocolTests.swift` | Protocol conformance + injection (resolves ISSUE-02). | A |
| `Tests/MacrecUITests/FilenameGeneratorTests.swift` | Golden-string tests against fixed dates. | D |
| `Tests/MacrecUITests/SegmentNamerTests.swift` | FR-34 cases (single, multi, split). | D |
| `Tests/MacrecUITests/SessionCoordinatorTests.swift` | Pause/resume state synthesis. | D |
| `Tests/MacrecUITests/RecordingControllerTests.swift` | `start → pause → resume → stop` transitions; error banner population. | D / G |
| `test_scripts/ci-run-tests.sh` | CI helper for full-Xcode test runs (R-22). | I |
| `test_scripts/e2e-ui-smoke.md` | AC-UI-1..AC-UI-18 manual checklist. | K |

### 6.2 Source files — modified

| File | Change | Phase |
|------|--------|-------|
| `Package.swift` | Add `macrec-ui` `executableTarget` + `MacrecUIKit` library target (AMB-3) + `MacrecUITests` test target + `macrec-ui` product. | B / D |
| `Sources/MacrecCore/RecordingSession.swift` | `stateStream` (FR-33), `split(nextOutput:)` (FR-32), `_recorderLock` refactor, `permissionGate` injection (resolves ISSUE-02). | A |
| `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift` | Add `levelTap` closure (FR-43). | A |
| `Sources/MacrecCore/Capture/AVMicrophoneSource.swift` | Add `levelTap` closure (FR-43). | A |
| `Sources/MacrecCore/Permissions/PermissionGate.swift` | Extract `PermissionGating` protocol; existing class conforms. | A |
| `Sources/MacrecCore/Config/RecordingOptions.swift` | (Optional) `withOutput(_:)` helper — see AMB resolution by Phase 5. | A |

### 6.3 Documentation files — created or modified

| File | Change | Phase |
|------|--------|-------|
| `docs/tools/macrec-ui.md` | **Create** via `/tool-conventions scaffold macrec-ui`; populate `<info>` block in Phase J. | 0 / J |
| `~/.tool-agents/macrec-ui/.env` | **Create** via the same slash command (mode `0600`). | 0 |
| `~/.tool-agents/macrec-ui/` | **Create** as mode-`0700` folder via the same slash command. | 0 |
| `CLAUDE.md` | Append `## Tools` entry for `macrec-ui` with one-line summary + relative link. | 0 |
| `docs/design/project-functions.md` | Append FR-30..FR-44 + NFR-11..NFR-16 (PLANNED → IMPLEMENTED). | 0 / J |
| `docs/design/plan-002-toolbar-ui.md` | **This document.** | 0 |
| `Issues - Pending Items.md` | Pre-register R-22..R-25, R-26..R-29; mark ISSUE-02 Completed after Phase A. | 0 / A / J / K |

### 6.4 Files NOT modified by this plan

> These belong to other phases or are out of scope. Listed for clarity.

| File | Reason |
|------|--------|
| `docs/design/project-design.md` | Owned by Phase 5 (Designer). UI architecture section added there, not here. |
| `Sources/macrec/**` | CLI is strictly read-only; no functional change. |
| `Sources/MacrecCore/Aligning/HostClockAligner.swift` | Pause/split/level changes do not require aligner edits. |
| `Sources/MacrecCore/Mixing/BufferSummer.swift` | Internal to `M4ARecorder` only. |
| `Sources/MacrecCore/Daemon/Daemonizer.swift` | UI is foreground-only; never touches the daemon path. |
| `Sources/MacrecCore/Daemon/PidFile.swift` | Same — no PID file in the UI. |
| `Sources/MacrecCore/Encoding/Recorder.swift` | The `Recorder` protocol shape is unchanged; `makeRecorder` is reused as-is. |

---

## Section 7 — Acceptance-Criteria Coverage Matrix

> Every AC-UI-* from the refined spec is mapped to the phase that
> satisfies it. No AC may be unmapped.

| AC | Verbatim summary | Phase | Verification path |
|----|------------------|-------|-------------------|
| AC-UI-1 | `swift build` produces UI binary, no deprecated-API warnings | B (build slot), C (shell), all subsequent | `swift build -c release 2>&1 \| grep -E "warning"` empty (Phase K) |
| AC-UI-2 | First-launch shows "not determined" + Start disabled | E (PermissionStatusView, ControlBar) | Manual: tccutil reset; launch; observe (Phase K) |
| AC-UI-3 | Click `not-determined` triggers prompt; click `denied` opens System Settings | E (PermissionStatusView) | Manual (Phase K) |
| AC-UI-4 | Start produces file within 1 s; icon transitions within 100 ms | C (StatusItemController), D (RecordingController), A (stateStream) | Manual + stopwatch (Phase K) |
| AC-UI-5 | Stop finalizes a playable file; duration matches indicator ±0.5 s | D (RecordingController.requestStop), A (stateStream `.stopped`) | Manual + `afinfo` (Phase K) |
| AC-UI-6 | Pause / Resume produces consecutive `partNN` files; finalize ≤30 s | D (SessionCoordinator), A (FR-20 reused) | Manual + `ls`, `afinfo` (Phase K) |
| AC-UI-7 | Split: seam ≤ 250 ms | A (`split(nextOutput:)`), D (SessionCoordinator.split), R-25 measurement | Manual: record splits; `afinfo` durations diff vs wall-clock (Phase K) |
| AC-UI-8 | Filename field locks during recording | E (FilenameField) | Manual: type → Start → verify field disabled (Phase K) |
| AC-UI-9 | Folder picker persists across launch | E (FolderPicker, `@AppStorage`) | Manual: pick → quit → relaunch → Start; verify path (Phase K) |
| AC-UI-10 | `--layout split` + Pause = four `.partNN.{mic,system}` files | E (LayoutPicker) + D (SegmentNamer FR-34) | Manual: layout=split; pause; resume; stop; `ls` (Phase K) |
| AC-UI-11 | Mic dropdown lists at least built-in; refreshes on hot-plug ≤ 2 s | E (MicrophonePicker, `AVCaptureDeviceWasConnectedNotification`) | Manual: USB mic plug/unplug (Phase K) |
| AC-UI-12 | Elapsed-time advances at 1 Hz; freezes on pause | E (ElapsedTimeView), D (RecordingController.segmentElapsed) | Manual: stopwatch alongside UI (Phase K) |
| AC-UI-13 | Force-quit during recording leaves a playable partial file | A (`split` reuse + existing FR-21 m4a fragment-interval flush) | Manual: `kill -9 $(pgrep macrec-ui)`; play file (Phase K) |
| AC-UI-14 | CLI AC-1..AC-20 still pass after UI merge | A (additive only), B (linker change is target-scoped), all | Reuse `test_scripts/e2e-30s-mixed.sh` etc. (Phase K) |
| AC-UI-15 | `docs/tools/macrec-ui.md`, `~/.tool-agents/macrec-ui/.env`, `## Tools` entry exist | 0 (scaffold) + J (populate) | `/tool-conventions audit macrec-ui` exits 0 |
| AC-UI-16 | `project-functions.md` contains FR-30..FR-44 with phase mapping | 0 (PLANNED) + J (IMPLEMENTED) | Manual diff |
| AC-UI-17 | `project-design.md` gains UI architecture section | **Phase 5 (Designer)** — NOT this plan | Designer deliverable |
| AC-UI-18 | `Issues - Pending Items.md` updated with new risks | 0 (R-22..R-25) + J (cleanup) + K (any field-discovered issues) | Manual review at Phase 7 / Phase 10 |

**Coverage**: 18 / 18 ACs mapped. AC-UI-17 is the only AC not owned by
this plan (Designer's deliverable).

---

## Section 8 — Functional-Requirements Update for `project-functions.md`

Phase 0 of this plan appends the following to
`docs/design/project-functions.md` (new top-level section "1.4 Added by
plan-002 — toolbar UI"). Each item lists the FR number, status, phase,
and a one-line summary; the full text of each FR is taken verbatim from
the refined-spec §"Functional requirements".

Carried forward from refined-spec §"Functional requirements":
- **FR-30** — Toolbar UI form factor (NSStatusItem + NSPopover). PLANNED, Phase C.
- **FR-31** — Pause/Resume on `RecordingSession` via stop-and-stitch. PLANNED, Phase A (engine support) + Phase D (orchestration).
- **FR-32** — Manual split (`split(nextOutput:)`). PLANNED, Phase A.
- **FR-33** — `SessionState` observable. PLANNED, Phase A.
- **FR-34** — Segment file naming (`partNN`). PLANNED, Phase D (SegmentNamer).
- **FR-35** — Output filename UX. PLANNED, Phase E (FilenameField).
- **FR-36** — Output folder picker. PLANNED, Phase E (FolderPicker).
- **FR-37** — Permission status indicator. PLANNED, Phase E (PermissionStatusView).
- **FR-38** — Format and layout selection. PLANNED, Phase E (FormatPicker, LayoutPicker).
- **FR-39** — Microphone device selection. PLANNED, Phase E (MicrophonePicker).
- **FR-40** — Elapsed-time indicator. PLANNED, Phase E (ElapsedTimeView).
- **FR-41** — Recording-state visual cue. PLANNED, Phase C (StatusItemController).
- **FR-42** — Process model (in-process). PLANNED, Phase A + Phase D (architectural).
- **FR-43** — Per-source level meters (`levelTap`). PLANNED, Phase A (engine tap) + Phase D (LevelMeterTap) + Phase E (LevelMeterView).
- **FR-44** — UI documentation and registration. PLANNED, Phase 0 + Phase J.

Carried forward from refined-spec §"Non-functional requirements":
- **NFR-11** — UI responsiveness (100 ms click → state). PLANNED, Phase D + Phase K verification.
- **NFR-12** — Crash isolation (`MacrecError` → banner). PLANNED, Phase G.
- **NFR-13** — Footprint (UI < 80 MB idle; combined < 250 MB). PLANNED, Phase K verification.
- **NFR-14** — Build constraint (CommandLineTools-buildable; no Xcode requirement). PLANNED, Phase B + Phase I.
- **NFR-15** — Architecture parity with CLI (universal binary). PLANNED, Phase B.
- **NFR-16** — Logging (per-UI log file at `~/.tool-agents/macrec-ui/macrec-ui.log`). PLANNED, Phase H.

---

## Section 9 — Phase-6 Dispatch Quick Reference

For each phase, a Phase-6 coder needs exactly:
1. The **Inputs** list from §3.
2. The **Files** list from §3 (created or modified).
3. The **Outputs** list from §3.
4. The **Gate criteria** block from §3.
5. The corresponding source-document section references in the
   investigation (Topic 1..7) and codebase scan (§4.x).
6. Any **Risk register** entry assigned to the phase by §5.

No phase requires re-reading the full refined-spec or investigation
end-to-end — every load-bearing recipe has been transcluded into this
plan with a doc-section citation for traceability.

---

## Section 10 — Plan Self-Review

Before declaring Phase 4 complete, this plan is reviewed against the
contract:

- [x] Every phase has all five fields: **Inputs**, **Files**,
      **Outputs**, **Gate criteria**, **Parallelism note**. (Phases
      0, A, B, C, D, E, F, G, H, I, J, K all checked.)
- [x] Every AC-UI-1..AC-UI-18 is mapped to a phase in §7. (18 / 18.)
- [x] The file manifest in §6 lists every file the implementation
      will touch (created or modified), grouped into source +
      modified + documentation + NOT-modified buckets.
- [x] Risk register R-22..R-25 are all present (plus four
      additional R-26..R-29 surfaced during planning).
- [x] No TypeScript / Node / npm tooling is proposed; everything
      lives under `Sources/macrec-ui/` (Swift) or `Sources/MacrecCore/`
      (Swift) per Exception 001.
- [x] No fallback configuration values. UI's `UserDefaults` keys
      are explicitly *UI state*, not configuration, per refined-spec
      Constraints.
- [x] `/tool-conventions scaffold macrec-ui` is invoked in Phase 0
      BEFORE any `~/.tool-agents/macrec-ui/` files exist; the
      docs/tools file is never hand-authored.
- [x] R-17 / R-22 acknowledgement: tests authored with
      `import Testing`; `swift test` results NOT trusted on dev host;
      a CI script is created in Phase I.
- [x] Plan does NOT modify `docs/design/project-design.md` —
      Phase 5 (Designer) owns AC-UI-17.
- [x] AMB-1..AMB-5 are listed at the top with assumed defaults +
      resolution gates.
- [x] Plan file path is exactly
      `docs/design/plan-002-toolbar-ui.md` per the next-sequential
      number after `plan-001-recording-tool.md`.

Plan ready for Phase 5 (Designer) consumption.
