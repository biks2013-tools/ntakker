# Investigation: Minimal macOS Toolbar UI for `macrec`

## Executive Summary

This investigation evaluates the seven technical topics flagged by the
refined request for `macrec-ui` — a menu-bar SwiftUI front end on top of
the existing `MacrecCore` Swift engine. All architectural macro-decisions
are already locked in `docs/design/refined-request-toolbar-ui.md`
(`Decisions Locked` table); the goal here is to fill in the
implementation-level "how" for each locked decision.

The single highest-leverage finding is that the **`MenuBarExtra` SwiftUI
scene is structurally inadequate for the required UX** because it cannot
be programmatically dismissed, lacks reliable status-icon highlighting,
and prevents access to the underlying `NSStatusItem` (no first-party API
to swap the icon between idle / recording / paused / failed visuals as
FR-41 requires). The recommended path is therefore **AppKit-driven
`NSStatusItem` + `NSPopover` containing an `NSHostingController<RootView>`,
hosted inside a SwiftUI `App` lifecycle whose `Settings { EmptyView() }`
scene is the only declared scene** (a documented, idiomatic pattern for
"AppKit-shell with SwiftUI-content" menu-bar apps in 2025).

For the engine bridge, the recommendation is to expose a single
`@MainActor @Observable` view model (`RecordingController`) that owns one
unstructured `Task`, drains an `AsyncStream<SessionState>` published by
`RecordingSession`, and delegates pause/split orchestration to a small
non-MainActor `SessionCoordinator` actor.

For pause and split semantics, since pause is locked as
**stop-and-stitch**, the heavy lifting lives entirely in the UI
coordinator (multiple sequential `RecordingSession` instances with
`partNN`-suffixed URLs); only **manual split (FR-32)** requires a new
encoder-rotation primitive inside `RecordingSession`. The recommended
split implementation is a **dual-recorder overlap** technique on the
aligner output queue, with the aligner's `onAlignedFrame` closure
re-pointed atomically under the session's `serialQueue`.

For level meters, **vDSP_rmsqv / vDSP_maxmgv on `floatChannelData`**
fed via a separate non-blocking `levelTap` closure on each source,
publishing at **30 Hz** through a coalesced `AsyncStream<LevelSample>`,
keeps the audio thread RT-safe while staying within FR-43 cadence.

For `LSUIElement`, the existing CLI's `-sectcreate` linker-flag pattern
is reused unchanged with a separate `Resources/MacrecUI-Info.plist`.

The remaining topics (filename auto-generation, segment naming) are
straightforward and resolved inline.

## Context

**Investigated**: How to implement the locked-in UI design (menu-bar
status item + popover, in-process `MacrecCore` linking, stop-and-stitch
pause, manual split, SwiftPM `macrec-ui` target, macOS 14+, Swift) at the
level of detail required to proceed to planning and implementation.

**Key constraints**:
- Decisions Locked (refined-request §"Decisions Locked") supersede the
  recommended defaults in the Open Questions table — **no
  re-litigation** of MenuBarExtra-vs-NSStatusItem at the macro level
  (locked to popover) or pause semantics (locked to stop-and-stitch).
- macOS 14+ only (NFR-1).
- Swift only — Exception 001 in `CLAUDE.md` applies.
- Apple-first-party frameworks preferred; only existing locked third-party
  deps (`swift-argument-parser`, `swift-log`) are permitted on
  `MacrecCore`. Additional UI-only deps are acceptable only if no
  first-party equivalent exists.
- SwiftPM-buildable on CommandLineTools (no full Xcode); `-sectcreate`
  linker flag pattern already proven by the CLI.
- UI must NOT regress AC-1..AC-20 of the CLI (additive only).
- `RecordingSession` is `@unchecked Sendable` with a `serialQueue` for
  state transitions; the UI must respect that pattern.
- Level meters require a NEW tap point that does not exist today.
- Pause and split are NEW core capabilities; today's `RecordingSession`
  has no segment concept.

**Refined request**:
[docs/design/refined-request-toolbar-ui.md](../design/refined-request-toolbar-ui.md)

**Codebase scan**:
[docs/reference/codebase-scan-toolbar-ui.md](codebase-scan-toolbar-ui.md)

---

## Topic 1 — Menu-bar status item + popover with SwiftUI on macOS 14+

### Options Identified

#### Option 1A: Pure SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`
- **Description**: Declare `MenuBarExtra("macrec", systemImage: ...) { ContentView() }.menuBarExtraStyle(.window)` as the only scene in a SwiftUI `App`. No AppKit code at the application level.
- **Strengths**: Minimum boilerplate; Apple-blessed declarative path; first-class SwiftUI App lifecycle; zero `NSApplicationDelegate` plumbing.
- **Weaknesses (decisive for `macrec-ui`)**:
  - **No programmatic dismiss API** — there is no first-party way to close the popover from inside the UI (e.g., after Stop, after a confirm-quit dialog, after an error toast). [FB11984872 still open through macOS 14.](https://github.com/feedback-assistant/reports/issues/383)
  - **No access to the underlying `NSStatusItem`** — but FR-41 mandates four distinct status-icon visual states (`idle` / `recording` / `paused` / `failed`). `MenuBarExtra` will accept a static `Image`/`systemImage` only via the trailing closure of its label, and recomposing the label through state is unreliable in practice (the menu-bar redraw is stalled while the window is presented, which is precisely when the state transition happens). Achievable only via the third-party [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) package, which adds a new dependency.
  - **No reliable highlight while window is open** — [FB10185639 still open](https://github.com/feedback-assistant/reports/issues/331); the icon does not stay highlighted, contradicting normal macOS UX expectations.
  - **`.interactiveDismissDisabled()` is ignored** ([FB10185468](https://github.com/feedback-assistant/reports/issues/330)) — cannot prevent dismiss during a critical "finalizing file…" wait.
  - **Setting `isPresented` to `false` is silently dropped** while the window is up — defeats AC-UI-13-style flows where the UI must close itself programmatically.
- **Effort/Complexity**: Low to scaffold, **but high to work around all four documented bugs**.
- **Risk**: High. The bugs are unfixed for >2 macOS releases and there is no Apple roadmap signal.
- **Best suited when**: The app is a pure preferences/launcher utility with a static menu-bar icon and no UI-driven state transitions.

#### Option 1B: AppKit `NSStatusItem` + `NSPopover` with `NSHostingController<RootView>` in a SwiftUI `App` shell
- **Description**: SwiftUI `@main App` whose only declared scene is `Settings { EmptyView() }` (placeholder so the App compiles); a `@NSApplicationDelegateAdaptor` provides an `AppDelegate` that creates the `NSStatusItem`, builds an `NSPopover`, and sets `popover.contentViewController = NSHostingController(rootView: RootView())`. Status-bar button click toggles the popover via `popover.show(relativeTo:of:preferredEdge:)` / `popover.performClose(_:)`.
- **Strengths**:
  - **Full programmatic control** over open/close, including from inside the SwiftUI body (pass the `NSPopover` reference into the SwiftUI environment).
  - **Direct access to `NSStatusItem.button.image`** — switching between four template images (`circle`, `record.circle.fill`, `pause.circle.fill`, `exclamationmark.triangle.fill`) is one assignment per state transition, exactly what FR-41 demands.
  - **Click-outside dismiss is opt-in** via `popover.behavior = .transient` (default for a "system menu" feel) or `.semitransient` (closes only on activation of another app, not on click in another window of the same app — useful for the `NSOpenPanel` folder picker so it does not close the popover).
  - **No third-party dependency**; uses Foundation/AppKit only.
  - **Pure-SwiftUI body remains intact** — `RootView` is a normal SwiftUI view; only ~80 lines of AppKit shell. Matches the "70% SwiftUI / 30% AppKit" ratio reported as standard by 2025 menu-bar app authors ([anhphong's lessons-learned](https://medium.com/@p_anhphong/what-i-learned-building-a-native-macos-menu-bar-app-eacbc16c2e14)).
- **Weaknesses**:
  - **Popover UX has a known papercut**: 2025 community consensus ([Multi.app blog](https://multi.app/blog/pushing-the-limits-nsstatusitem)) reports popovers "feel slightly delayed and floaty" compared to `NSMenu`. For a recording-control surface this is acceptable (the user is always actively interacting with the popover when it's open), but it is not a no-trade-off win.
  - Requires `NSApp.setActivationPolicy(.accessory)` defensively at app launch (in addition to `LSUIElement=true` in Info.plist) — this is a one-line `applicationDidFinishLaunching` call.
  - The `Settings { EmptyView() }` scene is a small wart but is the documented idiom ([nilcoalescing.com](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/) and Sarunw's tutorial series).
- **Effort/Complexity**: Low-Medium. ~80 LOC of `AppDelegate` + status-item setup; the rest is SwiftUI.
- **Risk**: Low. This pattern has shipped in dozens of well-known apps (Bartender, iStat Menus, Loom-style tools); the constituent APIs (`NSStatusItem`, `NSPopover`, `NSHostingController`) are stable since macOS 11 with no recent deprecations.
- **Best suited when**: The menu-bar UI is rich (custom controls, programmatic dismiss, dynamic icon, level meters) and the app already needs an `AppDelegate` for any other reason.

#### Option 1C: AppKit `NSStatusItem` + custom `NSWindow` (panel) instead of `NSPopover`
- **Description**: Same as 1B but with a borderless `NSPanel` / `NSWindow` positioned below the status item, instead of `NSPopover`.
- **Strengths**:
  - More layout flexibility (no fixed-arrow popover chrome).
  - Can stay open across app activations (sticky window mode for "always-visible recorder" use cases).
- **Weaknesses**:
  - You re-implement everything `NSPopover` already does for free: positioning, arrow, transient dismiss, animation. **Significantly more code** for a feature set that is identical to 1B for `macrec-ui`'s use case.
  - The "stick around" capability is not requested by the user (OQ-UI-9 is locked to "sit quietly in menu bar; user clicks to open"), so the only advantage is unused.
- **Effort/Complexity**: Medium-High. Manual window positioning, click-outside detection, and arrow rendering.
- **Risk**: Medium. More custom code = more places for visual / interaction bugs.
- **Best suited when**: The popover form factor is genuinely insufficient (e.g., the UI must be resizable, draggable to detach into its own window, or remain visible on screen-edge changes) — none of which `macrec-ui` requires.

### Comparison

| Criterion | 1A: MenuBarExtra | 1B: NSStatusItem + NSPopover | 1C: NSStatusItem + NSPanel |
|-----------|------------------|------------------------------|-----------------------------|
| FR-41 dynamic icon (4 states) | Hard (3rd-party dep needed) | **Trivial (1 LOC per state)** | Trivial |
| Programmatic dismiss (Stop / Quit confirm) | Broken (FB11984872) | **Works** | Works |
| Click-outside dismiss | Auto, can't prevent | **Auto, configurable** | Manual |
| `NSOpenPanel` folder picker compat | Closes popover | **`.semitransient` keeps it open** | Configurable |
| Third-party deps | MenuBarExtraAccess | **None** | None |
| LOC for shell | ~5 | ~80 | ~200+ |
| Long-term viability | Medium (Apple-bug-gated) | **High** | High |
| Apple-platform alignment | Yes (declarative) | **Yes (idiomatic AppKit pattern)** | Yes |
| Risk | High | **Low** | Medium |

### Recommendation: **Option 1B — AppKit `NSStatusItem` + `NSPopover` with `NSHostingController<RootView>` in a SwiftUI `App` shell.**

**Justification**:
- The four FR-41 status-icon states alone disqualify Option 1A; the stack of four open Apple Feedback issues against `MenuBarExtra` makes it actively risky for a tool we will continue to develop in 2026.
- Option 1B costs ~80 lines of AppKit boilerplate (a one-time tax) and unlocks every UI capability the request asks for, plus standard macOS UX expectations.
- The pattern is well-documented and has been the **2025 community recommendation** for any menu-bar app with non-trivial UI.
- Option 1C buys nothing for this use case at a measurable cost.

**Gotchas**:
- Set `NSApp.setActivationPolicy(.accessory)` in `applicationDidFinishLaunching` BEFORE creating the status item — even with `LSUIElement=true`, this is defensive and necessary for clean Dock-icon suppression in SwiftPM-built executables not wrapped in `.app`.
- Use **`.transient`** popover behavior by default (closes on click outside). Switch to `.semitransient` only while a modal `NSOpenPanel` is up so the folder picker doesn't dismiss the popover.
- Make the status-item image a **template image** (`image.isTemplate = true`) so it adapts to light/dark menu-bar appearance without a duplicate asset.
- Status item must be retained on the `AppDelegate` (or another long-lived owner) — a local variable will be deallocated and the icon vanishes silently.

**Sources**:
[FB11984872 — MenuBarExtra programmatic close](https://github.com/feedback-assistant/reports/issues/383),
[FB10185639 — MenuBarExtra highlight bug](https://github.com/feedback-assistant/reports/issues/331),
[FB10185468 — interactiveDismissDisabled bug](https://github.com/feedback-assistant/reports/issues/330),
[Multi.app — Pushing the limits of NSStatusItem](https://multi.app/blog/pushing-the-limits-nsstatusitem),
[nilcoalescing — Build a menu bar utility](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/),
[Sarunw — How to make a macOS menu bar app](https://sarunw.com/posts/how-to-make-macos-menu-bar-app/),
[anhphong — Lessons from shipping a menu bar app](https://medium.com/@p_anhphong/what-i-learned-building-a-native-macos-menu-bar-app-eacbc16c2e14).

---

## Topic 2 — Driving an `async` engine from SwiftUI views

### Options Identified

#### Option 2A: `@MainActor @Observable` view model owning a single unstructured `Task` + `AsyncStream<SessionState>`
- **Description**: A `@MainActor @Observable final class RecordingController` owns:
  - A non-optional state (`@Published`-equivalent under `@Observable`): `var state: SessionState = .idle`, `var elapsedSeconds: Int = 0`, `var levels: LevelSample = .silence`.
  - A nullable `Task<Void, Never>?` (`runTask`) that wraps the `try await session.run()` call.
  - A nullable subscription `Task<Void, Never>?` (`stateTask`) that drains `for await state in session.stateStream { self.state = state }`.
  - On Start: build `RecordingOptions`, build `RecordingSession`, store reference, launch both tasks.
  - On Stop: `session.requestStop()` (already public). `runTask` returns; `stateTask` ends when the stream finalizes.
- **Strengths**:
  - Matches the [2025-canonical pattern](https://swiftwithmajid.com/2025/02/11/task-cancellation-in-swift-concurrency/) for SwiftUI long-running async work.
  - `@MainActor` on the controller guarantees all observed property mutations happen on the main actor — no `DispatchQueue.main.async` ceremony in the call sites.
  - `@Observable` (macOS 14+) outperforms `ObservableObject` + `@Published` for fine-grained UI updates (per-property dependency tracking).
  - Cleanly handles `CancellationError` because `requestStop` does not throw — the `run()` Task simply returns normally.
  - The unstructured `Task` is the right shape because the work outlives any single view (the popover may close while recording continues — confirmed by FR-37, NFR-13 envelopes).
- **Weaknesses**:
  - `@Observable` macro has a [documented friction with `@MainActor`](https://forums.swift.org/t/observable-macro-conflicting-with-mainactor/67309) at view-`@State` initialization sites — solvable with `@StateObject`-shaped fallback or by annotating the `App` scope `@MainActor` (no real cost since SwiftUI views are already main-actor by default in macOS 14+).
  - Requires `RecordingSession` to expose the new `stateStream: AsyncStream<SessionState>` (FR-33) — confirmed as a NEW API in the codebase scan §4.3.
- **Effort/Complexity**: Low. The pattern is ~50 LOC of controller + a stream-emitter on the session.
- **Risk**: Low.
- **Best suited when**: The engine pushes a small enum-typed state machine and the UI consumes it 1:1.

#### Option 2B: `ObservableObject` + `@Published` + Combine `PassthroughSubject<SessionState>`
- **Description**: Pre-`@Observable` pattern. `class RecordingController: ObservableObject` with `@Published var state` etc., session emits via a `PassthroughSubject` the controller subscribes to with `.receive(on: DispatchQueue.main).sink`.
- **Strengths**:
  - Time-tested and macOS-12-compatible (irrelevant here — locked to macOS 14+).
  - Combine operators (`.debounce`, `.throttle`) come for free — relevant for level-meter coalescing if we route levels through Combine too.
  - Explicit `.receive(on: .main)` makes the threading discipline obvious in code review.
- **Weaknesses**:
  - More boilerplate per property (`@Published` per field) than `@Observable` (just `var`).
  - Per-property change re-renders the entire view subtree (Combine objectWillChange is coarse), versus `@Observable`'s tracked-key access (relevant for the 30 Hz level-meter view).
  - Combine is in maintenance mode; Apple is steering new code toward Observation + AsyncSequence.
- **Effort/Complexity**: Low.
- **Risk**: Low — but increasing slowly as Apple deprioritizes Combine.
- **Best suited when**: You need rich operator chains (debounce, combineLatest) on the published streams.

#### Option 2C: Wrap `RecordingSession` in a Swift `actor` and have the view model `await` from it
- **Description**: `actor RecordingSessionActor { ... }` instead of the existing serial-queue-based `@unchecked Sendable` class. The view model calls `await actor.start()`, `await actor.stop()`.
- **Strengths**:
  - Cleaner Sendable story (no `@unchecked`).
  - First-class await semantics.
- **Weaknesses (decisive)**:
  - **Conflicts with the existing engine architecture**. `RecordingSession` is `@unchecked Sendable` with a `serialQueue` because it bridges multiple non-Sendable C-style audio callbacks (`SCStreamOutput`, `AVCaptureAudioDataOutputSampleBufferDelegate`) that arrive on framework-managed queues. Re-architecting to an actor would touch the entire capture pipeline.
  - This is an **engine refactor**, not a UI change. Out of scope per the refined request's "additive only" constraint.
  - Apple guidance ([Swift Forums consensus](https://forums.swift.org/t/what-would-be-the-go-to-pattern-consuming-updates-from-actors-from-mainactor/70909)) is that view models should remain `@MainActor` and bridge OUT to background actors for work — not be replaced by them.
- **Effort/Complexity**: High. Touches every file in `Sources/MacrecCore/Capture/`, `Aligning/`, `Encoding/`.
- **Risk**: High. Breaks AC-1..AC-20 of the existing CLI.
- **Best suited when**: Greenfield engine; not applicable here.

### Comparison

| Criterion | 2A: @Observable + AsyncStream | 2B: ObservableObject + Combine | 2C: actor refactor |
|-----------|-------------------------------|--------------------------------|---------------------|
| Modernity (macOS 14+ idiom) | **Best (Apple-current)** | OK (still supported) | Best — but breaks engine |
| LOC overhead | **Low** | Medium | Very high |
| Engine impact | Stream-emitter only | Stream-emitter only | Full engine refactor |
| Per-property update granularity | **Fine (Observation tracks reads)** | Coarse (objectWillChange) | Fine |
| Threading clarity | Implicit (@MainActor) | Explicit (.receive(on:)) | Implicit (await) |
| Compatibility with existing CLI | **No regression** | No regression | Regression risk high |
| Risk | **Low** | Low | High |

### Recommendation: **Option 2A — `@MainActor @Observable RecordingController` owning unstructured `Task`s + `AsyncStream<SessionState>` from `RecordingSession`.**

**Justification**:
- It is the canonical 2025 SwiftUI pattern for long-running async work tied to a view model.
- It demands the **smallest engine change** — only the FR-33 `stateStream` continuation needs to be added to `RecordingSession`, alongside the existing `_runContinuation` field already at line 349 of `RecordingSession.swift`.
- It does not regress the existing CLI behavior (the CLI does not subscribe to the stream; it remains a no-op for `StartCommand`).
- Per-property tracking under `@Observable` is materially better than `@Published` for the high-frequency level-meter UI (Topic 5).

**Concrete shape**:

```swift
@MainActor
@Observable
final class RecordingController {
    private(set) var state: SessionState = .idle
    private(set) var levels: LevelSample = .silence
    private(set) var segmentElapsed: Duration = .zero
    private(set) var totalElapsed: Duration = .zero

    private var session: RecordingSession?
    private var runTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var levelsTask: Task<Void, Never>?
    private var coordinator: SessionCoordinator?  // see Topic 3

    func start(options: RecordingOptions) { /* launch tasks */ }
    func requestStop() { session?.requestStop() }
    func pause() async { try? await coordinator?.pause() }
    func resume() async { try? await coordinator?.resume() }
    func split() async { try? await coordinator?.split() }
}
```

**Gotchas**:
- The `@Observable` + `@State` initialization friction in `App` scope. Workaround: declare the controller in the `AppDelegate` and pass it down via `.environment(\.recordingController, controller)`. This is also necessary to keep the controller alive when the popover closes (the `AppDelegate` outlives any view).
- Always write to the controller's properties from `@MainActor`-isolated code paths. The `for await s in session.stateStream` loop must be inside `Task { @MainActor in ... }` (or simply executed on the controller, which is already `@MainActor`).
- `runTask?.cancel()` is **NOT** the way to stop recording — that would interrupt the await on `session.run()` mid-finalize. Always use `session.requestStop()` (which posts to the session's `serialQueue` and triggers the existing FR-21 finalize path). Cancellation of `runTask` is reserved for app shutdown.

**Sources**:
[Swift with Majid — Task cancellation 2025](https://swiftwithmajid.com/2025/02/11/task-cancellation-in-swift-concurrency/),
[Hacking with Swift — @MainActor](https://www.hackingwithswift.com/quick-start/concurrency/how-to-use-mainactor-to-run-code-on-the-main-queue),
[Swift Forums — Observable macro and @MainActor](https://forums.swift.org/t/observable-macro-conflicting-with-mainactor/67309),
[Swift Forums — Consuming actor updates from MainActor](https://forums.swift.org/t/what-would-be-the-go-to-pattern-consuming-updates-from-actors-from-mainactor/70909),
[Pol Piella — Property changes via AsyncStreams](https://www.polpiella.dev/observable-property-changes).

---

## Topic 3 — Stop-and-stitch pause with the existing `RecordingSession`

The decision is **locked to stop-and-stitch (multi-file)** by OQ-UI-2.
The investigation question is: where does the orchestration logic live?

### Options Identified

#### Option 3A: Pause / Resume orchestration entirely in a UI-side `SessionCoordinator` actor; `RecordingSession` itself stays single-segment
- **Description**: A new `actor SessionCoordinator` in `Sources/macrec-ui/` owns:
  - Current `RecordingSession`.
  - Segment counter (1-based).
  - Output basename + format + folder (immutable for the coordinator's lifetime).
  - `pause()`: calls `currentSession.requestStop()`, awaits the run-task to complete, parks the coordinator in the `.paused` state, emits `.paused` to the UI.
  - `resume()`: increments segment counter, computes `partNN`-suffixed `URL` via `SegmentNamer`, builds a new `RecordingOptions` and a new `RecordingSession`, awaits its `run()`.
  - `RecordingSession` itself receives **no new code** for pause/resume.
- **Strengths**:
  - **Zero engine changes** for pause/resume — the codebase scan §4.3 explicitly recommends this placement ("the UI controller manages the sequence of sessions and segment URLs").
  - Side-steps every `SCStream` lifecycle concern. Each pause-resume cycle creates a fresh `SCStream` + fresh `AVCaptureSession`, both already proven by the CLI.
  - Naturally composes with the `SessionState` stream from FR-33: each child session emits its own `.starting → .recording → .stopping → .stopped`; the coordinator interposes synthetic `.pausing` / `.paused` / `.resuming` states between sessions.
  - Coordinator can be `actor`-isolated cleanly because it only touches `RecordingSession` from within `await` calls (no audio-callback bridging).
- **Weaknesses**:
  - **Resume latency includes SCStream warmup** (~200-500 ms on Apple Silicon, sometimes higher with display sleep involved per [R-21 / SCStream-reliability concerns](https://issues.apple.com)). Each resume is a "cold start" of the capture stack. Confirmed by the [Apple-developer-forum thread documenting SCStream initialization cost](https://developer.apple.com/forums/tags/screencapturekit). For a "pause for a moment" UX this latency is acceptable; for "pause every 30 seconds" it would not be.
  - **Each resume re-prompts TCC if entitlements drift** (R-2 / R-21 in `Issues - Pending Items.md`). Mitigation: the entitlements are already granted by the time the user presses Pause; the second start within the same UI process should not re-prompt unless the OS has invalidated the grant (rare).
  - **Each resume creates a new `M4ARecorder`** with its own AAC priming gap (~2048 samples ≈ 42 ms at 48 kHz). This is invisible to the user across pause/resume because **the FR-34 spec already accepts that pause produces multiple files** — there is no "stitching" expectation at the audio-sample level. AC-UI-7 is about **split** (≤250 ms), not pause.

#### Option 3B: Add `pause()` / `resume()` methods on `RecordingSession` itself; keep the same `RecordingSession` instance across the cycle, internally stop-and-restart sources
- **Description**: `RecordingSession.pause()` stops sources, finalizes recorder, swaps in a fresh recorder pre-flighted to the next `partNN` URL, and parks. `resume()` rebuilds and restarts sources within the same session instance.
- **Strengths**:
  - One observable session = one continuous `SessionState` stream (no synthesis).
  - Marginally less UI-side state machine.
- **Weaknesses (decisive)**:
  - **Significant engine surface change**. `RecordingSession` would need to:
    - Refactor steps 4-9 of `run()` (lines 251-369) into a re-runnable inner method.
    - Add segment-counter + output-URL-rotation logic (currently neither exists).
    - Decide what happens to `_runContinuation` across a pause (currently it resolves once and exits).
    - Decide what happens to the signal handlers (currently installed in `run()` and torn down at exit).
  - The session was designed around **single `run()` call → single output file**. Forcing it to be multi-segment internally means **most of `run()`** changes shape.
  - Codebase scan §4.3 explicitly disrecommends this placement.
- **Effort/Complexity**: High. Touches the most-tested file in the project.
- **Risk**: Medium-High. Likely to introduce regressions in the CLI's signal-handling and finalize paths.

#### Option 3C: Soft-pause within a single session (gate the aligner output) — already locked OUT by OQ-UI-2
Recorded for completeness only; not in scope.

### Comparison

| Criterion | 3A: UI-side coordinator | 3B: pause inside RecordingSession |
|-----------|------------------------|-----------------------------------|
| Engine code changes | **None for pause** | Heavy refactor of run() |
| Test surface impact | Adds new tests in macrec-ui only | Reworks every existing session test |
| CLI regression risk | **None** | Medium |
| Resume latency | ~200-500 ms (cold start) | Same (sources still restart) |
| State stream model | Synthesized in coordinator | Native |
| Codebase scan recommendation | **Aligned** | Misaligned |
| Risk | **Low** | Medium-High |

### Recommendation: **Option 3A — UI-side `SessionCoordinator` actor manages multi-session pause/resume; `RecordingSession` stays single-segment.**

**Justification**:
- The codebase scan §4.3 explicitly identifies this as the recommended placement.
- It is fully consistent with the OQ-UI-2 lock (stop-and-stitch produces multiple files; the coordinator is the natural owner of the segment counter).
- It creates zero CLI regression risk.
- The resume latency penalty is the same whether the orchestration lives in the UI or the engine — because the underlying "stop SCStream, start a new SCStream" cost is identical. Choosing 3A spares the engine refactor for no countervailing benefit.

**Concrete shape**:

```swift
actor SessionCoordinator {
    private let basename: String          // "recording-2026-04-26-103015"
    private let folder: URL
    private let baseOptions: RecordingOptions
    private var segmentCounter: Int = 0
    private var current: RecordingSession?
    private var currentRunTask: Task<Void, Error>?

    let stateStream: AsyncStream<SessionState>
    private let stateContinuation: AsyncStream<SessionState>.Continuation

    func start() async throws { /* segment 1 */ }
    func pause() async throws  { /* requestStop on current; await; emit .paused */ }
    func resume() async throws { /* segment N+1 */ }
    func split() async throws  { /* delegates to session.split() — Topic 4 */ }
    func stop() async throws   { /* requestStop on current; await; emit .stopped */ }
}
```

**Gotchas**:
- During pause the coordinator must keep emitting state, even though no `RecordingSession` is alive. The synthesized states are: `.pausing → .paused → .resuming` (between two sessions).
- Detect "pause but recorder is still finalizing" — the coordinator must `await currentRunTask?.value` before returning from `pause()`, otherwise the file may not be playable when AC-UI-6 measures it.
- The stop-and-stitch pause does **not** require the system audio TCC prompt to re-fire on resume because the bundle identity is the same and the OS-side grant is sticky for the lifetime of the host process. (Subject to R-2 ad-hoc-signing rebuild caveats.)
- Naming per FR-34: keep an explicit `SegmentNamer` helper in `Sources/macrec-ui/SegmentNamer.swift` (codebase scan §4.3) that takes `(basename, ext, layout, segmentNumber, totalSegments) -> URL`. If `totalSegments == 1` (no pause, no split was used), strip the `.partNN` infix entirely (FR-34 first bullet).

---

## Topic 4 — Manual split with the existing `RecordingSession`

Manual split (FR-32) requires keeping the SCStream and AVCaptureSession
**alive** across the encoder rotation, with a max-250ms audible gap
(AC-UI-7). This is genuinely harder than pause and **must** live inside
`RecordingSession`.

### Options Identified

#### Option 4A: Single-recorder atomic swap on the aligner's `onAlignedFrame` queue
- **Description**:
  1. UI calls `session.split()` (new method).
  2. Posted onto `serialQueue`. On that queue:
     - Pre-flight a new `Recorder` for the next `partNN` URL via `makeRecorder`. **Do not start it yet** (start is async; we need the swap point synchronous).
     - `await newRecorder.start()` (this is fine; we are inside an async method on the session).
     - Replace `_recorder` with the new recorder.
     - Re-point `aligner.onAlignedFrame` to write to the new recorder.
     - `await oldRecorder.finalize(timeout: 5)` (drains in-flight buffers).
  3. The aligner's frame closure reads the recorder reference each call. The reference swap is the atomic boundary.
- **Gap analysis**: between "old recorder accepts last frame" and "new recorder accepts first frame", the aligner is delivering frames at the configured 48 kHz with ~10 ms callback granularity. The reference swap completes within microseconds. **The audible gap is ≤ one aligner-frame interval (~10 ms)**, well under AC-UI-7's 250 ms ceiling.
- **Strengths**:
  - One recorder live at a time → minimum memory.
  - Reference-swap on a serial queue is well-understood concurrency-wise.
  - Reuses the existing `Recorder` protocol unchanged.
- **Weaknesses**:
  - The new recorder's first frame inherits a fresh AAC priming gap (~42 ms at 48 kHz for `m4a`; zero for `wav`/`caf`). This is implicit in any AAC encoder swap and is the dominant component of the seam-gap budget. **Still well under 250 ms.**
  - `oldRecorder.finalize` is async and can take seconds (M4A finalize writes the moov atom). It must run **after** the swap, not before, otherwise frames in flight to the old recorder are dropped. The session's `serialQueue` must serialize the swap (sync) but `await` the finalize (off the queue, on the Task's executor).

#### Option 4B: Dual-recorder overlap (write the seam frame to BOTH)
- **Description**: Same as 4A, but for a small window (e.g., 1 frame ≈ 10 ms) after the swap, the aligner writes to **both** old and new recorders. Then old finalizes.
- **Strengths**:
  - Eliminates the theoretical possibility of a single dropped frame at the swap (already vanishingly small in 4A).
  - Standard pattern in the [GDCL article on AVAssetWriter rotation](https://www.gdcl.co.uk/2013/02/20/iOS-Video-Encoding.html) for video rotation.
- **Weaknesses**:
  - The overlapping frame appears in two files — the user-facing seam now has duplicated audio for ~10 ms, which is **audible as a phasing artifact** if the two files are concatenated downstream. Worse than a 10 ms gap.
  - Doubles encoder work briefly (negligible CPU but a complication).
- **Best suited when**: For video, where a duplicated I-frame is fine because video frames are discrete. For audio, dropped is better than duplicated (silence is a cleaner seam than echo).

#### Option 4C: Stop-and-restart-with-buffering (essentially the pause primitive)
- **Description**: Stop the old recorder; while sources are still feeding aligned frames, buffer them in memory; start a new recorder; flush buffer.
- **Strengths**: None over 4A.
- **Weaknesses**: Adds an in-memory queue with bounded growth concerns; doesn't actually reduce gap.

### Comparison

| Criterion | 4A: Single-recorder swap | 4B: Dual-recorder overlap | 4C: Buffered restart |
|-----------|--------------------------|----------------------------|----------------------|
| Seam audio quality | ~10 ms gap (clean) | ~10 ms duplication (phasing) | Variable |
| Memory | Minimum | +1 recorder briefly | +buffer |
| Code complexity | **Low** | Medium | Medium |
| AC-UI-7 ≤ 250 ms compliance | **Yes (well under)** | Yes | Yes |
| AAC priming gap inherent | Yes (~42 ms) | Yes | Yes |
| Risk | **Low** | Low-Medium (audio artifact) | Medium |

### Recommendation: **Option 4A — Single-recorder atomic swap on `serialQueue`, with `aligner.onAlignedFrame` re-pointed under the same lock.**

**Justification**:
- The total audible seam gap is ≤ ~52 ms (10 ms swap latency + 42 ms AAC priming for m4a, ~10 ms total for wav/caf), well under AC-UI-7's 250 ms.
- Audio gap is preferable to audio duplication. Option 4B trades a clean seam for a phasing seam.
- Reuses every existing `Recorder` protocol contract unchanged.
- `RecordingSession.serialQueue` is already the synchronization point for state changes; adding `split()` to it is consistent.

**Concrete contract**:

```swift
extension RecordingSession {
    /// Rotate the encoder to a new output URL without stopping capture.
    /// FR-32. Audible gap MUST be < 250 ms (AC-UI-7).
    public func split(nextOutput: URL) async throws {
        // 1. Pre-flight new recorder (off serial queue — uses async start).
        let newOptions = options.withOutput(nextOutput)
        let newRecorder = try makeRecorder(options: newOptions, logger: ...)
        try await newRecorder.start()

        // 2. Swap atomically (on serial queue).
        let oldRecorder: Recorder = serialQueue.sync {
            let old = _recorder
            _recorder = newRecorder
            // re-point closure: aligner reads _recorder via self
            return old!
        }

        // 3. Finalize old (off serial queue; can take seconds).
        try await oldRecorder.finalize(timeout: 5)
    }
}
```

**Gotchas**:
- The `aligner.onAlignedFrame` closure currently captures `recorder` by weak reference (line 302 of `RecordingSession.swift`). For the swap to take effect, the closure must instead read `self._recorder` each call (or be re-installed with the new weak capture). The simpler refactor is **read through self**:
  ```swift
  aligner.onAlignedFrame = { [weak self] frame in
      guard let recorder = self?.serialQueue.sync(execute: { self?._recorder }) else { return }
      try? recorder.append(frame)
  }
  ```
  But `serialQueue.sync` on the audio path is a contention risk. **Better**: store `_recorder` in a `os_unfair_lock`-guarded reference, or use `OSAtomic`-equivalent (`Atomic` with `Atomics` package / `ManagedAtomic`). Simplest: a single `os_unfair_lock` around `_recorder` — read on every aligned frame, write only on split.
- The new recorder must be **fully started** (`await recorder.start()` returned) before it appears in `_recorder`, otherwise the first aligned frame after the swap calls `append` on an unstarted recorder.
- The output URL passed to `split()` must be pre-validated by `makeRecorder` BEFORE the swap, so a bad path fails the split rather than crashing the recording mid-swap. The existing `makeRecorder` factory does this pre-flight (codebase scan, "makeRecorder factory").
- For `--layout split` (the format, not the manual `split()` action — note the naming collision), the recorder is internally two writers (mic + system). `split()` must rotate **both** simultaneously. Handle inside the recorder factory (the `Recorder` protocol is already the right abstraction; both writers are inside one `Recorder` instance in `--layout split` mode per existing `M4ARecorder` design).

**Sources**:
[GDCL — AVAssetWriter rotation pattern](https://www.gdcl.co.uk/2013/02/20/iOS-Video-Encoding.html),
[Apple Forums — Recoverable AAC files via shouldOptimizeForNetworkUse](https://forums.developer.apple.com/forums/thread/720691).

---

## Topic 5 — Per-source level meters from a tap point

### Options Identified

#### Option 5A: Add a `levelTap: ((CaptureBuffer) -> Void)?` closure on each source; coalesce + publish at 30 Hz via `AsyncStream<LevelSample>`
- **Description**:
  1. Add `var levelTap: ((CaptureBuffer) -> Void)?` to `SCKitSystemAudioSource` and `AVMicrophoneSource` (codebase scan §4.3 recommends this placement). Existing `onSampleBuffer` is unchanged.
  2. Each source invokes `levelTap?(buffer)` on its own capture queue (`macrec.capture.system` / `macrec.capture.mic`), AFTER calling `onSampleBuffer`.
  3. The UI installs a tap that:
     a. Wraps the `CMSampleBuffer` in an `AVAudioPCMBuffer` reusing a pre-allocated buffer (allocated once at session start, sized to the largest expected frame count).
     b. Calls `vDSP_rmsqv(channelData, 1, &rmsValue, frameLength)` and `vDSP_maxmgv(channelData, 1, &peakValue, frameLength)` on the float channel data.
     c. Coalesces to 30 Hz: a `_lastEmitTime` instance var; emit only if `(now - lastEmit) >= 33.3 ms`.
     d. Yields a `LevelSample(source: .system, peak: peakValue, rms: rmsValue, timestamp: now)` into a `AsyncStream<LevelSample>.Continuation`.
  4. The `RecordingController` consumes the stream via `Task { for await s in levelStream { self.levels = ... } }`.
- **Strengths**:
  - **Fully RT-safe**: no allocations on the audio thread (pre-allocated PCM buffer + vDSP in-place math), no main-thread dispatch (the AsyncStream continuation `.yield` is lock-free under the hood when consumer keeps up; it accepts back-pressure via `bufferingPolicy: .bufferingNewest(2)`).
  - Existing `onSampleBuffer` semantics are unchanged → no regression risk to capture pipeline.
  - 30 Hz is sufficient for visually smooth meter UX (60 Hz is over-design; the eye can't perceive level changes faster than ~25 Hz).
  - Uses Apple-first-party Accelerate framework only.
- **Weaknesses**:
  - Pre-allocated `AVAudioPCMBuffer` requires knowing the max frame count up front. SCK and AVCapture both deliver ~480-1024 samples per buffer at 48 kHz. Sizing for 4096 samples gives 8x headroom and costs ~64 KB.
  - Coalescing means the tap drops most buffers — not a problem for meters (visual smoothing handles this).

#### Option 5B: Reuse the existing `onSampleBuffer` and chain the level computation into it
- **Description**: No new closure; the UI replaces `onSampleBuffer` with `{ [oldHandler] buf in oldHandler(buf); computeLevel(buf) }`.
- **Strengths**: No new API.
- **Weaknesses**:
  - The session sets `onSampleBuffer` in `RecordingSession.run()` (lines 293-298) and **owns** that closure. Re-pointing it from the UI breaks the session's invariant that "the aligner is the only consumer".
  - Codebase scan §4.3 explicitly discourages this: "the cleaner design is a second, optional tap closure so the session's wiring is unchanged".

#### Option 5C: Lock-free ring buffer between audio queue and a dedicated reader thread
- **Description**: Each source writes raw audio into a `TPCircularBuffer` (or a Swift port); a dedicated reader thread on a `userInteractive` queue drains, computes levels, publishes.
- **Strengths**: Maximum decoupling.
- **Weaknesses**:
  - Significantly more code for no measurable benefit over 5A. The audio thread already runs on a dedicated capture queue; computing 4 floats from a 1024-sample buffer with vDSP takes single-digit microseconds.
  - Adds a third-party dependency (no first-party `TPCircularBuffer`-equivalent in Swift) — violates the constraint.

### Comparison

| Criterion | 5A: levelTap closure + AsyncStream | 5B: chain onSampleBuffer | 5C: ring buffer |
|-----------|-----------------------------------|---------------------------|------------------|
| Audio-thread blocking risk | **None (vDSP, no alloc)** | None | None |
| API impact on session | **Zero (additive closure)** | Breaks invariant | Zero |
| Code volume | Low | Low | High |
| 3rd-party deps | None | None | Yes (TPCircularBuffer) |
| Codebase scan alignment | **Recommended** | Discouraged | Not mentioned |
| Risk | **Low** | Low-Medium | Medium |

### Recommendation: **Option 5A — `levelTap: ((CaptureBuffer) -> Void)?` closure on each source, vDSP on a pre-allocated `AVAudioPCMBuffer`, 30 Hz coalesced `AsyncStream<LevelSample>`.**

**Justification**:
- Recommended directly by the codebase scan §4.3.
- 30 Hz cadence balances visual smoothness against UI-thread cost.
- vDSP is the standard non-allocating peak/RMS path on Apple platforms; the [Kodeco AVAudioEngine tutorial](https://www.kodeco.com/21672160-avaudioengine-tutorial-for-ios-getting-started/page/2) and [AudioKit's processing helpers](https://github.com/AudioKit/AudioKit/blob/main/Sources/AudioKit/Audio%20Files/AVAudioPCMBuffer+Processing.swift) both follow this idiom.

**Concrete shape**:

```swift
struct LevelSample: Sendable {
    let source: CaptureBuffer.Source  // .system | .mic
    let peakDb: Float                 // -inf..0
    let rmsDb: Float
    let timestamp: ContinuousClock.Instant
    static let silence = LevelSample(source: .mic, peakDb: -80, rmsDb: -80, ...)
}

final class LevelMeterTap: @unchecked Sendable {
    private let pcmBuffer: AVAudioPCMBuffer  // pre-allocated, reused
    private let lock = OSAllocatedUnfairLock(initialState: ContinuousClock.Instant.now)
    private let continuation: AsyncStream<LevelSample>.Continuation
    let stream: AsyncStream<LevelSample>

    init(format: AVAudioFormat, source: CaptureBuffer.Source) { ... }

    func onCapture(_ buf: CaptureBuffer) {
        // Coalesce: emit only every ~33ms.
        let now = ContinuousClock.Instant.now
        let shouldEmit = lock.withLock { last in
            if now - last < .milliseconds(33) { return false }
            last = now; return true
        }
        guard shouldEmit else { return }

        // Convert CMSampleBuffer → reused AVAudioPCMBuffer.
        // Run vDSP_rmsqv + vDSP_maxmgv → dB.
        // Yield.
        continuation.yield(LevelSample(...))
    }
}
```

**Gotchas**:
- The `AsyncStream` must use `bufferingPolicy: .bufferingNewest(2)` so a slow consumer (UI lag) does not back up audio-thread memory.
- `peakDb` floor: `20 * log10(0)` is `-inf`. Clamp to `-80 dB`.
- The pre-allocated `pcmBuffer` is per-source; sharing a buffer across mic+system causes a data race.
- For `stereo-split` layout (`micChannel: .left | .right`), the meter should still report per-source (mic vs system) levels, not per-channel — agreed by FR-43 ("peak + RMS meter per source (mic, system)").

**Sources**:
[Apple Dev Forum — CMSampleBuffer ↔ AVAudioPCMBuffer](https://developer.apple.com/forums/thread/123926),
[aibo-cora — Buffer converter gist](https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c),
[Kodeco — AVAudioEngine level metering](https://www.kodeco.com/21672160-avaudioengine-tutorial-for-ios-getting-started/page/2),
[AudioKit — AVAudioPCMBuffer+Processing](https://github.com/AudioKit/AudioKit/blob/main/Sources/AudioKit/Audio%20Files/AVAudioPCMBuffer+Processing.swift).

---

## Topic 6 — Filename auto-generation

### Options Identified

#### Option 6A: Standalone `FilenameGenerator` struct in the UI module
- **Description**: `Sources/macrec-ui/FilenameGenerator.swift` exposes:
  ```swift
  struct FilenameGenerator {
      static func defaultFilename(now: Date = .now,
                                  format: OutputFormat,
                                  formatter: DateFormatter = .iso8601-ish-default) -> String
  }
  ```
  Returns `recording-2026-04-26-103015.m4a`.
- **Strengths**:
  - Explicit, testable.
  - UI-scoped — the CLI does not need this (the CLI requires `--output` explicitly).
  - One file, ~15 LOC.
- **Weaknesses**: None.

#### Option 6B: Method on `RecordingOptions` (in `MacrecCore`)
- **Description**: Add `static func defaultOutputURL(format: OutputFormat, in folder: URL) -> URL` to `RecordingOptions`.
- **Strengths**: Centralizes the policy.
- **Weaknesses**:
  - Adds a UI-only concern to the engine. The CLI does not auto-fill output names (it errors on missing `--output`).
  - Bloats the engine API surface for no engine consumer.

### Recommendation: **Option 6A — `FilenameGenerator` struct in `Sources/macrec-ui/`.**

**Justification**:
- Codebase scan §4.3 directly recommends `Sources/macrec-ui/FilenameGenerator.swift`.
- Keeps the engine free of UI policy.
- Trivial test surface: `let f = FilenameGenerator.defaultFilename(now: fixedDate, format: .m4a); XCTAssertEqual(f, "recording-2026-04-26-103015.m4a")`.

**Concrete shape**:

```swift
struct FilenameGenerator {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    static func defaultFilename(now: Date = .now, format: OutputFormat) -> String {
        "recording-\(formatter.string(from: now)).\(format.rawValue)"
    }
}
```

**Gotchas**:
- Use `en_US_POSIX` locale to avoid Arabic-numeral / non-Gregorian-calendar surprises on user systems.
- The generator emits a **basename + extension only** (no folder). Folder concatenation happens in `RecordingController` using the `UserDefaults`-stored output folder (FR-36).
- When the user edits the field then changes the format dropdown, the **extension** must update but the user-edited basename must be preserved (FR-38: "Selecting a format MUST update the file extension shown in the FR-35 filename field"). Implementation: keep `basename` and `format` as separate `@Observable` properties; render `"\(basename).\(format.rawValue)"`.

---

## Topic 7 — `LSUIElement` Info.plist embedding for SPM-built executables

### Options Identified

#### Option 7A: Reuse the existing `-sectcreate` linker-flag pattern with a SEPARATE `Resources/MacrecUI-Info.plist`
- **Description**: Identical to the current CLI's pattern (codebase scan §4.3 documents the exact `Package.swift` snippet). Add a new plist file at `Resources/MacrecUI-Info.plist` containing:
  - `LSUIElement = true`
  - `CFBundleIdentifier = com.local.macrec-ui`
  - `CFBundleExecutable = macrec-ui`
  - Same `NSMicrophoneUsageDescription` + `NSScreenCaptureUsageDescription` strings as the CLI (TCC requires them on the binary that requests permission).
  - `LSMinimumSystemVersion = 14.0`
- **Strengths**:
  - **Identical mechanism** to the proven CLI build (`Sources/macrec` already ships with `-sectcreate ... Resources/Info.plist`).
  - Pure SwiftPM; works on CommandLineTools (NFR-14).
  - Zero risk of plist-conflict because each target gets its own.
- **Weaknesses**:
  - Two near-identical plist files. Mitigated by a comment header in each pointing at the other.

#### Option 7B: Use SwiftPM's `resources:` array
- **Description**: List `Info.plist` in `resources:` and let SwiftPM bundle it.
- **Strengths**: Declarative.
- **Weaknesses (decisive)**:
  - **SPM rejects top-level `Info.plist` files in `resources:`** (community-documented; reproduced in the search above). The build fails with "files named 'Info.plist' are reserved".
  - Resources are bundled into a `<Module>.bundle` directory adjacent to the executable, not embedded in the Mach-O `__TEXT,__info_plist` section — `launchctl` and `Info.plist`-reading APIs ignore them.
- **Best suited when**: The plist is for runtime asset discovery only (not for app metadata).

#### Option 7C: Wrap the SwiftPM-built executable in a `.app` bundle via post-build script
- **Description**: After `swift build`, a script creates `MacrecUI.app/Contents/MacOS/macrec-ui` and copies a `Contents/Info.plist` next to it.
- **Strengths**:
  - "Real" app bundle that Finder recognizes.
  - Easier code-signing path for v2.
- **Weaknesses**:
  - **Out of scope for v1** (refined-request "Out of scope" explicitly excludes `.dmg` packaging and notarization).
  - The `__info_plist` Mach-O section must STILL be embedded — `launchctl`, command-line invocation, and TCC all read the embedded section, not just the bundle's `Info.plist`. So 7C does not replace 7A; it composes with it.
- **Best suited when**: Distribution-ready v2.

### Recommendation: **Option 7A — `-sectcreate` with a separate `Resources/MacrecUI-Info.plist`.**

**Justification**:
- Reuses the proven CLI mechanism (no new tooling).
- Compatible with CommandLineTools-only build (NFR-14).
- Codebase scan §4.3 documents the exact `Package.swift` shape.

**Concrete `Package.swift` addition** (per codebase scan §4.3, with minor annotations):

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
),
```

And the corresponding `Resources/MacrecUI-Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.local.macrec-ui</string>
    <key>CFBundleName</key>
    <string>macrec-ui</string>
    <key>CFBundleDisplayName</key>
    <string>macrec-ui</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>macrec-ui</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>macrec-ui records the microphone alongside system audio. Audio is written only to the file path you choose. Nothing is sent over the network.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>macrec-ui uses the Screen Recording permission to capture system audio (the audio output of all running applications) via ScreenCaptureKit. No video frames are saved; only audio is recorded.</string>
    <key>NSScreenCaptureDescription</key>
    <string>macrec-ui uses the Screen Recording permission to capture system audio (the audio output of all running applications) via ScreenCaptureKit. No video frames are saved; only audio is recorded.</string>
</dict>
</plist>
```

**Gotchas**:
- The `CFBundleIdentifier` differs from the CLI (`com.local.macrec` vs `com.local.macrec-ui`). The two binaries are **separate TCC identities**. Granting Screen Recording to the CLI does NOT grant it to the UI; users will be prompted again. Document this in `Issues - Pending Items.md` per refined-request "documentation" instruction.
- The `__info_plist` path is resolved by `ld` relative to the package root, NOT the target source dir. Using `Resources/MacrecUI-Info.plist` (top-level Resources dir) matches the CLI's `Resources/Info.plist`.
- Verify post-build with `otool -P .build/debug/macrec-ui` (prints the embedded plist).
- Defensively call `NSApp.setActivationPolicy(.accessory)` in `applicationDidFinishLaunching` even with `LSUIElement=true` — for `swift run` invocations from Terminal, the OS sometimes treats the process as a CLI tool and skips the LSUIElement honoring; the explicit policy call is bulletproof.

**Sources**:
[Pol Piella — Adding Info.plist to Swift CLI](https://www.polpiella.dev/info-plist-swift-cli/),
[Swift Forums — Use of Info.plist in SPM](https://forums.swift.org/t/swift-package-manager-use-of-info-plist-use-for-apps/6532),
[CocoaDev — LSUIElement](https://cocoadev.github.io/LSUIElement/),
[NSApplication.ActivationPolicy.regular docs](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/regular).

---

## Comparison Matrix (cross-topic at-a-glance)

| Topic | Recommended option | Risk | Engine impact | UI LOC estimate |
|-------|-------------------|------|----------------|-----------------|
| 1: UI shell | NSStatusItem + NSPopover + NSHostingController | Low | None | ~80 |
| 2: View-model bridge | @MainActor @Observable + AsyncStream | Low | Add stateStream to RecordingSession | ~150 |
| 3: Pause | UI-side SessionCoordinator actor | Low | None | ~120 |
| 4: Split | Single-recorder atomic swap on serialQueue | Low-Medium | Add split() to RecordingSession + lock _recorder | ~50 (engine) + 20 (UI) |
| 5: Levels | levelTap closure + vDSP + 30 Hz AsyncStream | Low | Add levelTap to two sources | ~120 |
| 6: Filename | Standalone FilenameGenerator struct | Low | None | ~15 |
| 7: LSUIElement | -sectcreate with separate plist | Low | None | 1 plist + 1 Package.swift target |

**Total engine surface change**: 4 additions to `MacrecCore` (
`SessionState` enum + `stateStream`,
`split(nextOutput:)`,
`levelTap` on two sources,
optional `RecordingOptions.withOutput(_:)` helper).
**Total UI module size**: ~600 LOC + plist + Package.swift entry — well within v1 reach.

---

## Recommendation (Cross-cutting)

The seven recommendations interlock cleanly:

1. **Shell**: `@main App` with `Settings { EmptyView() }` scene + `NSApplicationDelegateAdaptor`. The delegate creates the `NSStatusItem` and the `NSPopover` containing the `NSHostingController<RootView>`. The delegate also sets `NSApp.setActivationPolicy(.accessory)` and owns the long-lived `RecordingController`.

2. **Controller**: A `@MainActor @Observable RecordingController` injected into the SwiftUI environment. It owns three `Task`s (run, state-subscribe, levels-subscribe) and a `SessionCoordinator` actor that manages multi-segment pause/resume.

3. **Engine extensions** (added to `MacrecCore`):
   - `enum SessionState` + `var stateStream: AsyncStream<SessionState>` on `RecordingSession`
   - `func split(nextOutput: URL) async throws` on `RecordingSession`
   - `var levelTap: ((CaptureBuffer) -> Void)?` on `SCKitSystemAudioSource` and `AVMicrophoneSource`
   - `PermissionGating` protocol (unblocks ISSUE-02 — codebase scan §5).

4. **UI module structure** (`Sources/macrec-ui/`):
   - `MacrecUIApp.swift` — `@main` scaffolding
   - `AppDelegate.swift` — status item + popover + activation policy
   - `RootView.swift` — SwiftUI popover content
   - `RecordingController.swift` — `@Observable` view model
   - `SessionCoordinator.swift` — pause/resume/split orchestration actor
   - `LevelMeterTap.swift` — vDSP peak/RMS extraction
   - `FilenameGenerator.swift` — timestamp-based default name
   - `SegmentNamer.swift` — `partNN` URL computation
   - `PermissionStatusView.swift` — FR-37 indicator
   - `LevelMeterView.swift` — FR-43 meter rendering
   - `Resources/MacrecUI-Info.plist` (NOT in `resources:` — referenced via linker flag only)

5. **The recommendation would change** if any of the following shifts:
   - **macOS minimum drops to 13**: Topic 1 reconsider (MenuBarExtra has no status-icon dynamics on 13 either, so 1B still wins, but `@Observable` in Topic 2 must fall back to `ObservableObject`).
   - **The user accepts a third-party SwiftPM dep**: `MenuBarExtraAccess` would re-open Topic 1's Option 1A as viable. Still not preferred (the underlying `MenuBarExtra` bugs are not all fixable from a wrapper).
   - **Pause semantics change to soft-pause** (a different OQ-UI-2 lock): Topic 3 reconsider — soft-pause requires gating in the aligner (engine change) rather than a coordinator (UI change).
   - **Split is moved to time-based auto-split**: Topic 4 still applies but the `split()` call site moves from a UI button to a session-internal timer.

---

## Technical Research Guidance

**Research needed**: **No.**

All seven topics produced concrete, implementable recommendations
backed by canonical 2025 sources and direct corroboration with the
codebase scan. The investigation sourced:
- Apple Feedback issues for Topic 1's MenuBarExtra limitations.
- Multiple 2025-current articles on the recommended SwiftUI async +
  `@Observable` pattern for Topic 2.
- The codebase's own §4.3 placement guidance for Topics 3, 5, 6.
- The proven CLI linker-flag pattern for Topic 7.
- Standard Apple-platform peak/RMS conventions (vDSP, Kodeco, AudioKit)
  for Topic 5.

The two areas where extra DEPTH would marginally help — but is NOT
required to plan and implement v1 — are:

- **`SCStream` cold-start latency on resume after stop-and-stitch
  pause** (Topic 3). The investigation cites "200-500 ms on Apple
  Silicon" from community sources but did not measure on the
  project's specific dev hardware. **Recommendation**: defer to
  implementation phase. Measure during AC-UI-6 verification; if the
  observed cold-start exceeds 1 second consistently, revisit (e.g.,
  pre-warm a parked SCStream during the paused state). The v1 spec
  does not impose a resume-latency SLO, so this is a "tune if needed",
  not a "block on research".

- **AAC priming / encoder-delay accounting for split seams** (Topic 4).
  The investigation states the priming gap is ~42 ms at 48 kHz for
  m4a. Whether downstream tools (QuickTime, ffprobe) honor the
  `iTunSMPB` edit-list atom emitted by `AVAssetWriter` to mask the
  priming has not been independently verified for our specific
  `M4ARecorder`. **Recommendation**: defer to implementation phase
  with a verification step. AC-UI-7 tolerates 250 ms; we have ~200 ms
  of headroom even if priming is fully audible.

Neither is a blocker for the team to proceed to planning and design.

---

## Implementation Considerations

**Key decisions still to be made (during planning, not investigation)**:

- The exact set of `SessionState` enum cases. The refined request lists
  `{ idle, starting, recording, pausing, paused, resuming, splitting,
  stopping, stopped, failed(MacrecError) }` — confirm during design that
  `splitting` is needed as a separate state vs. a transient flag (the
  split window is ~50 ms; UI may not need to render it).

- Whether to use `OSAllocatedUnfairLock` (macOS 13+, Sendable) or a
  classic `os_unfair_lock_s` for the `_recorder` reference in Topic 4.
  Recommendation: `OSAllocatedUnfairLock` — it is the macOS 13+
  Sendable-friendly successor.

- Where to put the `SessionCoordinator` actor — codebase scan suggests
  `Sources/macrec-ui/`. Confirm during planning that the coordinator
  is UI-module code (it does not need to ship with the engine library).

- The exact `LevelSample` rendering cadence inside the SwiftUI view.
  30 Hz from the producer is correct; the consumer view should use
  `.onReceive`-equivalent (`for await`) with a final `.animation(.linear(duration: 0.05))` smoothing.

**Dependencies / prerequisites**:

- ISSUE-02 in `Issues - Pending Items.md` (`PermissionGate` not
  injectable into `RecordingSession`) should be unblocked **before** UI
  testing begins. The fix is a one-protocol-extraction change and is
  recommended in codebase scan §4.3 ("`PermissionGating` protocol —
  unblocks ISSUE-02").

- `swift-log` is already a dependency; no new SPM deps required if all
  recommendations are followed.

**Potential pitfalls to watch for**:

1. **TCC identity drift**: `macrec` and `macrec-ui` have different
   bundle IDs and therefore different TCC grants. Document
   prominently in the macrec-ui tool docs (per FR-44) and in
   `Issues - Pending Items.md` so the user is not surprised by a
   permission re-prompt.

2. **`NSStatusItem` retention**: forgetting to retain it on the
   `AppDelegate` makes the icon vanish silently and the bug is hard
   to spot — code review should explicitly check this.

3. **`NSOpenPanel` + popover interaction**: using `.transient`
   popover behavior closes the popover when the folder picker
   appears. Switch to `.semitransient` for the duration of the panel
   (see Topic 1 gotchas).

4. **`AsyncStream` continuation lifecycle**: failing to call
   `continuation.finish()` on session teardown leaks the consumer
   `Task`. The session's `resolveRunLoop` is the right place to call
   `stateContinuation.finish()`.

5. **AAC priming gap on first-segment-after-pause**: the FR-34
   semantics correctly accept multi-file output; users should not
   expect concatenated playback without a downstream tool. Document
   in `docs/tools/macrec-ui.md`.

6. **Quit-while-recording (OQ-UI-10 locked to "confirm + finalize +
   quit")**: `applicationShouldTerminate` must return
   `.terminateLater` while the finalize is in flight, then call
   `NSApp.reply(toApplicationShouldTerminate: true)` from the
   `state == .stopped` observer. Standard AppKit pattern, easy to
   miss.

**Suggested first steps (for planning phase)**:

1. Plan-001: Engine extensions (FR-31 partial — `pause` is UI-side, but
   `SessionState`/`stateStream`/`split`/`levelTap`/`PermissionGating` are
   engine).
2. Plan-002: UI module skeleton + `Package.swift` target + Info.plist
   embedding (Topic 7).
3. Plan-003: `RecordingController` + `SessionCoordinator` (Topics 2, 3).
4. Plan-004: SwiftUI `RootView` + sub-views (start/stop/pause/split,
   filename field, format/layout dropdowns, folder picker, mic
   dropdown, permission indicator, elapsed timer, status icon).
5. Plan-005: Level meters (Topic 5).
6. Plan-006: `docs/tools/macrec-ui.md` scaffolded by the
   `tool-doc-config-architect` subagent (per AC-UI-15 / `CLAUDE.md`
   mandate).
7. Plan-007: Acceptance verification per AC-UI-1..AC-UI-18.

---

## References

| # | Source | URL | What was learned |
|---|--------|-----|------------------|
| 1 | FB11984872 — MenuBarExtra programmatic close | https://github.com/feedback-assistant/reports/issues/383 | MenuBarExtra cannot be programmatically dismissed; bug open through macOS 14. Drives Topic 1 recommendation. |
| 2 | FB10185639 — MenuBarExtra highlight bug | https://github.com/feedback-assistant/reports/issues/331 | MenuBarExtra status icon does not stay highlighted while window is open. |
| 3 | FB10185468 — interactiveDismissDisabled bug | https://github.com/feedback-assistant/reports/issues/330 | `.interactiveDismissDisabled()` does not work on MenuBarExtra. |
| 4 | Multi.app — Pushing the limits of NSStatusItem | https://multi.app/blog/pushing-the-limits-nsstatusitem | Why NSStatusItem + NSPopover (or NSMenu+NSHostingView) is preferred over MenuBarExtra in 2025; "feels delayed" caveat for popovers. |
| 5 | nilcoalescing — Build a menu bar utility | https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/ | Canonical SwiftUI-`Settings`+`AppDelegate` pattern for menu bar apps. |
| 6 | Sarunw — How to make a macOS menu bar app | https://sarunw.com/posts/how-to-make-macos-menu-bar-app/ | MenuBarExtra basics and migration paths. |
| 7 | anhphong — Lessons shipping a menu bar app | https://medium.com/@p_anhphong/what-i-learned-building-a-native-macos-menu-bar-app-eacbc16c2e14 | "70% SwiftUI / 30% AppKit" ratio; macOS 14+ targeting recommendation. |
| 8 | MenuBarExtraAccess (orchetect) | https://github.com/orchetect/MenuBarExtraAccess | Third-party workaround for MenuBarExtra limitations (not adopted; Apple-first-party path preferred). |
| 9 | Swift with Majid — Task cancellation 2025 | https://swiftwithmajid.com/2025/02/11/task-cancellation-in-swift-concurrency/ | Canonical cooperative cancellation pattern with `try Task.checkCancellation()`. |
| 10 | Hacking with Swift — @MainActor | https://www.hackingwithswift.com/quick-start/concurrency/how-to-use-mainactor-to-run-code-on-the-main-queue | Recommendation to keep `@MainActor` explicit on `@Observable` view models. |
| 11 | Swift Forums — @Observable + @MainActor friction | https://forums.swift.org/t/observable-macro-conflicting-with-mainactor/67309 | The `@State` + `@MainActor @Observable` initialization workaround. |
| 12 | Swift Forums — Consuming actor updates from MainActor | https://forums.swift.org/t/what-would-be-the-go-to-pattern-consuming-updates-from-actors-from-mainactor/70909 | View models should remain `@MainActor`; bridge to background actors via AsyncStream. |
| 13 | Pol Piella — Property changes via AsyncStreams | https://www.polpiella.dev/observable-property-changes | AsyncStream from a `didSet` property pattern. |
| 14 | Apple Forums — CMSampleBuffer ↔ AVAudioPCMBuffer | https://developer.apple.com/forums/thread/123926 | Conversion path for level metering taps. |
| 15 | aibo-cora — Buffer converter gist | https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c | Working conversion class. |
| 16 | Kodeco — AVAudioEngine level metering | https://www.kodeco.com/21672160-avaudioengine-tutorial-for-ios-getting-started/page/2 | Peak/RMS math; `20*log10(rms)` and noise-floor scaling. |
| 17 | AudioKit — AVAudioPCMBuffer+Processing | https://github.com/AudioKit/AudioKit/blob/main/Sources/AudioKit/Audio%20Files/AVAudioPCMBuffer+Processing.swift | Idiomatic `floatChannelData` pointer use. |
| 18 | TN3136 — AVAudioConverter | https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions | Sample-rate conversion guidance (only relevant if levels are computed at a different rate from capture). |
| 19 | GDCL — AVAssetWriter rotation pattern | https://www.gdcl.co.uk/2013/02/20/iOS-Video-Encoding.html | Dual-writer overlap technique for atomic file rotation; foundation for Topic 4. |
| 20 | Apple Forums — shouldOptimizeForNetworkUse for crash-safe m4a | https://forums.developer.apple.com/forums/thread/720691 | Putting moov atom at front aids recoverability; relevant to FR-21 / NFR-12 compatibility. |
| 21 | SCStream documentation | https://developer.apple.com/documentation/screencapturekit/scstream | Update vs stop/restart semantics; no first-party pause/resume API. |
| 22 | Pol Piella — Adding Info.plist to Swift CLI | https://www.polpiella.dev/info-plist-swift-cli/ | Confirms `-sectcreate` is the SwiftPM-native path for embedding Info.plist. |
| 23 | Swift Forums — Use of Info.plist in SPM | https://forums.swift.org/t/swift-package-manager-use-of-info-plist-use-for-apps/6532 | SPM rejects `Info.plist` in `resources:`; linker flag is the supported path. |
| 24 | CocoaDev — LSUIElement | https://cocoadev.github.io/LSUIElement/ | Semantics of LSUIElement and its interaction with menu-bar / Dock-icon visibility. |
| 25 | Apple Forums — NSApp.setActivationPolicy(.regular) issues | https://developer.apple.com/forums/thread/650270 | Known caveats when toggling activation policy; defensive `.accessory` setting at launch. |
| 26 | NSApplication.ActivationPolicy.regular docs | https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/regular | Apple-canonical definition of `.accessory` and `.regular` policies. |
| 27 | Pol Piella — Menu-bar-only AppKit app | https://www.polpiella.dev/a-menu-bar-only-macos-app-using-appkit/ | End-to-end AppKit pattern matching Topic 1's recommendation. |
| 28 | Steipete — Settings from menu bar items | https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items | Edge cases when an accessory app needs to show modal windows; relevant to NSOpenPanel folder picker (Topic 1 gotcha). |

---

## Original Request

> I want you to create a minimal toolbar ui to allow the user to start
> recording, define the output file name and pause or stop the recording
> or split it in smaller parts, et cetera.

Refined to the spec at
[`docs/design/refined-request-toolbar-ui.md`](../design/refined-request-toolbar-ui.md)
with macro-decisions locked in the "Decisions Locked" table on
2026-04-26. This investigation operates within those locks and produces
implementation-level recommendations for the seven uncertain technical
topics flagged by the orchestrator.
