# ntakker UI Layer Review — Performance / Functionality / Robustness

Scope: `Sources/ntakker/` + `Sources/NtakkerUIKit/` at commit `e4cd174` (branch `master`).
Date: 2026-06-12.

All paths relative to `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/`.

---

## HIGH severity

### H1. Double-click Start races two live recording sessions (orphaned, unstoppable session)

**File:** `Sources/NtakkerUIKit/RecordingController.swift:292-427` (guard at 300-306)

```swift
public func start() {
    ...
    switch state {
    case .idle, .stopped, .failed:
        break
    default: ... return
    }
    ...
    let coord = SessionCoordinator(baseOptions: options, logger: logger)
    self.coordinator = coord
    startEventsForwarder(coord)
    ...
    Task { [weak self] in
        ...
        try await coord.start()
    }
}
```

**Why it's a problem:** `start()` never moves `state` out of `.idle` synchronously — the transition to `.starting`/`.recording` only arrives later via the coordinator's async event stream. A second click on Start (or the `ErrorBanner` "Try Again" button, or `clearSession()`'s restart) that lands before the first `.starting` event passes the guard, constructs a **second** `SessionCoordinator`, and overwrites `self.coordinator`. The first coordinator's `RecordingSession` is already spinning up (TCC capture, file open) but is now unreachable: `stop()` forwards only to the *current* coordinator, so the orphaned session keeps capturing and writing to the same output URL until process exit. `startEventsForwarder` also cancels the first forwarder, so its `.failed`/`.stopped` events are silently dropped.

**Fix:** Set a synchronous local gate before spawning any Task — e.g. introduce `state = .starting` (or a private `isStartPending` flag checked in the guard) as the first statement after the guard, and clear it on failure. This makes the idle→active transition atomic with respect to the main actor.

---

### H2. Session Save performs bulk file IO (audio copy + delete, JSONL parse) synchronously on the main actor — popover and status item freeze

**Files:**
- `Sources/ntakker/Views/Asking/SessionExporter.swift:34` (`@MainActor enum SessionExporter`), `:161-301` (`write(...)`), `:261-284` (copy/delete loop), `:204-213` (sidecar JSONL parse)
- `Sources/ntakker/RootView.swift:375-405` (`performSessionSave` invoked directly from the sheet's `onConfirm`)

```swift
@MainActor
enum SessionExporter {
    static func write(...) throws -> WriteResult {
        ...
        let transcriptFromSidecar = sidecars.transcript.flatMap { JSONLTranscriptReader.read(from: $0) ... }
        ...
        for source in resolvedAudioFiles {
            try FileManager.default.copyItem(at: source, to: dest)   // potentially hundreds of MB
            try FileManager.default.removeItem(at: source)
        }
```

**Why it's a problem:** `write` runs entirely on the main actor: it parses the full transcript JSONL sidecar (unbounded for long sessions), renders Markdown, creates directories, and **copies then deletes every audio file** of the session. An hour-long m4a is easily 50–150 MB; the `split` layout doubles the file count; WAV is 10× larger. While the copy runs, the popover, the menu-bar icon's state observer, the level-meter drain, the QA panel — everything on the main thread — is frozen, and macOS may show the beachball. `RootView.performSessionSave` then chains `clearSession()`/`resetToIdle()` behind the same blocked frame.

**Fix:** Drop the `@MainActor` annotation and move the heavy body to a detached task or a dedicated IO actor: `Task.detached { try SessionExporter.write(...) }` with the result hopped back to the main actor for `saveResult`/banner updates. Add a "Saving…" progress state to the popover so the buttons are disabled instead of frozen. Same applies to `RootView.persistQASidecarIfNeeded` (`RootView.swift:340-368`), which writes a JSONL on the main actor on every `.stopped` transition.

---

### H3. Data races on unsynchronized `static var` diagnostic counters mutated from the audio capture queues

**Files:**
- `Sources/NtakkerUIKit/LevelMeterTap.swift:154` — `struct Diag { static var dropFrame = 0; static var dropCopy = 0; static var dropChan = 0; static var ok = 0 }`, mutated at `:157, :186, :197, :203` inside `extractLevels`, which runs on **both** the mic and the system capture queues concurrently.
- `Sources/NtakkerUIKit/RecordingController.swift:753-759` — `struct ApplyCounter { static var n: Int = 0 }` (main-actor only, so benign, but the same anti-pattern).

```swift
struct Diag { static var dropFrame = 0; static var dropCopy = 0; ... }
...
Diag.ok += 1
if Diag.ok % 30 == 1 {
    Logger(label: "ntakker-cli.ui.levelTap.diag").warning("LEVELMETER_RT extractLevels OK ...")
}
```

**Why it's a problem:** `extractLevels` is invoked from two different dispatch queues (mic + system taps). Unsynchronized read-modify-write of a `static var` is undefined behavior in Swift (and a hard error under strict concurrency once these globals are flagged). Beyond the race, a fresh `Logger(label:)` is constructed on the audio thread per emission, and the logs go out at `.warning` level — they bypass the user's chosen `info` level and land in both OSLog *and* the `~/.tool-agents/ntakker/ntakker.log` file forever.

**Fix:** Delete the `LEVELMETER_RT` diagnostic scaffolding (it's clearly leftover debug instrumentation — see also H4) or replace counters with `OSAllocatedUnfairLock<Int>` / `ManagedAtomic<Int>` and demote to `.trace` behind a debug flag.

---

### H4. Leftover `LEVELMETER_RT` warning-level diagnostics in hot paths (30 Hz / per-buffer / per-segment) — log spam, file growth, CPU

**Files & lines:**
- `Sources/NtakkerUIKit/RecordingController.swift:293` (`start()` entry), `:351` (format check), `:365-389` (per-buffer sink counter + lock + log every 200 buffers), `:391-405` (drain log every 60 samples), `:749-760` (`applyLevels` log every 60 ticks)
- `Sources/NtakkerUIKit/LevelMeterTap.swift:154-206` (per-ingest counters/logs)
- `Sources/NtakkerUIKit/SessionCoordinator.swift:502-514` — **every** transcript event is logged at `.info` with a `String(describing:)` render: `coordLogger.info("coordinator transcript forward: emitting event #\(seen) \(String(describing: event).prefix(60))")`
- `Sources/NtakkerUIKit/RecordingController.swift:573-581` — every `segmentAppended`/`segmentUpdated` partial is logged at `.info` with text interpolation.

**Why it's a problem:** Per-event string interpolation + `String(describing:)` of enum payloads runs on every transcript partial (Soniox emits several per second) and on the level pipeline. `OSAllocatedUnfairLock` acquisition per audio buffer in `sinkClosure` exists *only* to feed the diagnostic counter. The `.warning` ones are always-on regardless of `NTAKKER_UI_LOG_LEVEL` and grow the 0600 log file unboundedly.

**Fix:** Remove the `LEVELMETER_RT` instrumentation, the `sinkCounter` lock, and downgrade per-event transcript logs to `.trace`/`.debug`. After removal, `sinkClosure` collapses to the two-line dispatch on `capture.source`.

---

## MEDIUM severity

### M1. LevelMeterPublisher publishes a fresh sample at 30 Hz unconditionally — observable churn with no new data, even while the popover is closed

**File:** `Sources/NtakkerUIKit/LevelMeterPublisher.swift:164-180`; consumer at `Sources/NtakkerUIKit/RecordingController.swift:392-405, :749-762`

```swift
publishTask = Task { [weak self] in
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: intervalNs)
        ...
        let merged = MergedLevelSample(
            system: snapshot.system, mic: snapshot.mic,
            timestamp: Date().timeIntervalSince1970   // unique every tick
        )
        self.continuation.yield(merged)
    }
}
```

**Why it's a problem:** The tick loop yields whether or not either tap produced a new sample (silence, paused sources). Because `timestamp` is regenerated per tick, every sample is distinct, so `RecordingController.applyLevels` writes `latestLevels` (an `@Observable` property) 30 times per second on the main actor for the entire duration of a recording — including when the popover is closed and nothing renders the meters, and during `.paused` segments. Every write schedules observation invalidations.

**Fix:** (a) Skip the yield when neither slot changed since the previous tick (keep the last published pair and compare); (b) pause/resume the drain task from `PopoverController` visibility (`popoverWillShow`/`DidClose` delegate hooks) so the main actor sees zero level traffic while the UI is invisible; (c) drop `timestamp` from equality or use the source sample's timestamp.

### M2. `PopoverStatusBar` re-evaluates its entire body at 30 Hz; meters are not isolated into a leaf view

**File:** `Sources/ntakker/Views/Footer/PopoverStatusBar.swift:44-76, :261-267`

```swift
private var micIntensity: Double {
    Double(recordingController?.latestLevels?.mic?.rms ?? 0)
}
```

**Why it's a problem:** `body` reads `latestLevels` (via `micIntensity`/`systemIntensity`), so every 30 Hz publish invalidates the *whole* status bar — state pill, gradient stop button with shadow, clock, action area — not just the bars. On top of this, each `BouncingBars` runs its own `TimelineView(.animation(minimumInterval: 1/30))`, so while recording the bottom band renders from two independent 30 Hz drivers.

**Fix:** Move the `latestLevels` read into a tiny `MeterIntensityReader` child view (pass the controller, read `latestLevels` only inside it) so observation-scoped invalidation stays in the leaf. Alternatively pass `intensity` via a `@State` updated by `onChange` with rounding (e.g. quantize RMS to 1/64) to dedupe sub-perceptual changes.

### M3. Live transcript list is a non-lazy `VStack` re-laid-out in full on every partial, plus an animated auto-scroll per partial

**Files:**
- `Sources/ntakker/Views/Transcription/LiveTranscriptPanel.swift:218-245` (`ScrollView { VStack { ForEach(segments) ... } }`, `.onChange(of: segments.last?.lastUpdated) { scrollToBottom }`)
- `Sources/ntakker/Views/Transcription/SourceLane.swift:41-63` (same pattern × 2 lanes in split mode)

**Why it's a problem:** With the 100-segment cap, every `segmentUpdated` (several per second on streaming providers) mutates the observable array, and the plain `VStack` forces layout/diff of all ~100 rows (each with chips, italic state, etc.). `AskingModeView` already uses `LazyVStack` (`AskingModeView.swift:253`) — the transcript panel should too. Additionally `scrollToBottom` runs `withAnimation(.easeOut(0.15))` on *every* partial update, stacking animations, and it always force-scrolls even when the user has scrolled up to read earlier text.

**Fix:** Use `LazyVStack`; scroll without animation on partials (animate only on `segments.count` change); track "user scrolled away" (compare scroll offset or use `onScrollPhaseChange` on macOS 15+) and suspend auto-scroll until they return to bottom.

### M4. `totalElapsed` counts timer ticks, not time — visible clock drift on long sessions

**File:** `Sources/NtakkerUIKit/RecordingController.swift:714-743`

```swift
elapsedTask = Task { [weak self] in
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        ...
    }
}
...
private func tickElapsed() {
    ...
    segmentElapsed = seconds      // clock-derived — correct
    totalElapsed += 1             // tick-derived — drifts
}
```

**Why it's a problem:** `Task.sleep` guarantees *at least* the interval; under load each cycle is 1 s + scheduling latency, so `totalElapsed` falls behind wall-clock cumulatively (minutes over a multi-hour recording). `PopoverStatusBar`'s clock (`PopoverStatusBar.swift:256-259`) and the Q&A timestamps (`AskingModeView.submitDraft` uses `totalElapsed`, line 508) read this drifting value, so question anchors in the sidecar are wrong by the same amount. `segmentElapsed` is computed from the clock and does not drift — the asymmetry is the bug.

**Fix:** Track `totalElapsedBase: TimeInterval` (accumulated at each pause/stop) + `segmentStartedAt`, and compute `totalElapsed = totalElapsedBase + (now - segmentStartedAt)` in `tickElapsed()`, mirroring the `segmentElapsed` math.

### M5. Quit "Stop & Quit" path has no watchdog — a stalled finalize wedges the app in `.terminateLater` forever

**File:** `Sources/ntakker/QuitFlow.swift:134-151, :232-270`

```swift
case .alertSecondButtonReturn:
    controller.stop()
    observeTerminalStateThenReply()
    return .terminateLater
```

**Why it's a problem:** If the engine's drain/finalize hangs (e.g. `writerFinalizationTimeout` paths that never resolve into `.stopped`/`.failed`, or the H1 orphaned-coordinator case where the observed controller never transitions), `NSApplication.reply(toApplicationShouldTerminate:)` is never called. AppKit does not time `.terminateLater` out — the app becomes unquittable except via `kill`, with no UI feedback.

**Fix:** Arm a `Task` watchdog (e.g. 15 s) alongside the observation; on expiry log, force `cancelAll()`, and reply `true`. Cancel the watchdog when the terminal state lands.

### M6. `cancelAll()` is never called — `applicationWillTerminate` was never implemented; per-session coordinators are never torn down

**Files:**
- `Sources/ntakker/AppDelegate.swift` — comments at `:87` and `:316` promise "Cancelled in `applicationWillTerminate(_:)` (Phase F owns that hook)", but the class implements no `applicationWillTerminate`. `grep` confirms zero production callers of `RecordingController.cancelAll()` (`RecordingController.swift:492-510`).
- `Sources/NtakkerUIKit/RecordingController.swift:322-326` — each `start()` replaces `self.coordinator` without calling `teardown()` on the previous one, so the old coordinator's `eventsContinuation` is never `finish()`ed (`SessionCoordinator.swift:434-443`).

**Why it's a problem:** (a) The documented shutdown contract (forwarder cancellation, level-publisher finish, coordinator teardown) is dead code — termination relies on process death to reclaim tasks, which is survivable today but means the QuitFlow "stop & quit" path exits with the events forwarder, elapsed task and 30 Hz publisher still live. (b) Between sessions, each retired `SessionCoordinator` keeps an unfinished `AsyncStream` continuation and its 16-element buffer alive until the controller drops the reference at the *next* start — a slow accumulation pattern and a trap if anything ever retains the events stream.

**Fix:** Implement `applicationWillTerminate` calling `recordingController.cancelAll()`; in `RecordingController.start()`, `Task { await oldCoordinator.teardown() }` before replacing the reference (or call it from the `.stopped`/`.failed` handler).

### M7. Settings window promoted via blocking `NSApp.runModal(for:)` with a fragile window heuristic

**File:** `Sources/ntakker/AppDelegate.swift:459-524`

```swift
if let raw = window.identifier?.rawValue,
   raw == "com_apple_SwiftUI_Settings_window"
    || raw.lowercased().contains("settings") { return true }
```

**Why it's a problem:** (a) `runModal(for:)` parks the main call stack inside `promoteSettingsWindowToModal` for as long as Settings is open; any code after the notification dispatch resumes only on close, and a second nested modal (NSAlert from QuitFlow, NSSavePanel from `MarkdownPaneExporter`) during the session creates nested modal pumps — Cmd-Q while Settings is open runs `QuitFlow`'s `NSAlert.runModal()` *inside* the settings modal session, and a "Stop & Quit" reply then races `stopModal()`. (b) The `contains("settings")` fallback can capture unrelated windows (any future window whose identifier mentions "settings"), promoting them to app-modal unexpectedly. (c) `NSApp.stopModal()` from the `willClose` observer is documented to be unreliable when invoked outside the modal loop's event callout (it can no-op until the next event).

**Fix:** Prefer `window.level`/`NSApp.runModalSession` polling or — simpler — make the popover ignore events while Settings is key (disable controls via an environment flag) instead of an AppKit modal pump. At minimum, tighten the identifier match to the exact SwiftUI identifier + localized-title pair and guard against entering the modal while another modal session is active (`NSApp.modalWindow == nil`).

### M8. Start path re-reads and re-parses `~/.tool-agents/ntakker/.env` from disk up to ~8 times per click, on the main actor

**Files:** `Sources/ntakker/RecordingStarter.swift:89-162` (calls at :100, :108, :112, :114, :137, :149, :156) → `:194-202 resolvedEnvValue` → `Sources/NtakkerCore/Bootstrap/EnvFileStore.swift:80-85` (`read` does a full file parse per call). Mirrored in `Sources/ntakker/Views/ControlBar.swift:107-115`.

**Why it's a problem:** Each `resolvedEnvValue` call stats + reads + parses the .env file synchronously on the main actor. For an Azure/ElevenLabs configuration the start click does this seven-plus times. It's small IO, but it's repeated synchronous disk access on the UI thread at the most latency-sensitive interaction (button press → perceived start).

**Fix:** Parse the file once at the top of `RecordingStarter.start` (`EnvFileStore.parse`/`loadIntoProcess` already exist) into a `[String: String]` snapshot and resolve all keys against it.

### M9. `ErrorBanner` "Try Again" restarts with stale options instead of recomposing via `RecordingStarter`

**File:** `Sources/ntakker/Views/ErrorBanner.swift:129-134`

```swift
case .retry:
    Button(String(localized: "Try Again")) {
        controller.start()
        controller.dismissError()
    }
```

**Why it's a problem:** `controller.start()` reuses the `RecordingOptions` captured at the failed attempt. Anything the user changed since (folder, mic, provider, key added to Settings) is ignored, and the timestamp-derived default basename is not regenerated — retrying after fixing an "output already exists"-class issue or after granting a permission can re-fail or write to a stale filename. Every other start path goes through `RecordingStarter.start(controller:)`, which recomposes options from current persisted state; the banner bypasses it.

**Fix:** `RecordingStarter.start(controller: controller)` in the retry action (the file already lives in the same target).

### M10. "New Session while active" restart race in `clearSession()`

**File:** `Sources/ntakker/RootView.swift:597-622`

```swift
switch controller.state {
case .recording, .paused, ...:
    controller.stop()        // async — state is still active here
default: break
}
RecordingStarter.start(controller: controller)  // start() will refuse: state not terminal yet
```

**Why it's a problem:** `controller.stop()` only spawns a Task; `state` remains `.recording` when `RecordingStarter.start` runs one statement later, so `RecordingController.start()` hits its guard and silently no-ops (a warning log only). The comment says this branch "future-proofs the shortcut path" — it does the opposite: the documented Phase-5 global-hotkey flow will stop the session but never start the new one.

**Fix:** Await the terminal state before restarting — e.g. observe `controller.state` (the same `withObservationTracking` pattern as QuitFlow) or add an async `controller.stopAndWait()` and call `RecordingStarter.start` in its continuation.

---

## LOW severity

### L1. `PopoverController.deinit` comment is wrong — block-based NotificationCenter observer is never removed

**File:** `Sources/ntakker/PopoverController.swift:167-212`

```swift
deinit {
    // KVO observation token is released automatically.
    _ = sizeObserver
}
```

Block-based observers (`addObserver(forName:object:queue:using:)`) must be removed with `removeObserver(_:)`; the token going out of scope does *not* deregister it. `PopoverController` lives for the process lifetime so nothing leaks today, but the comment will mislead future refactors (e.g. recreating the controller per appearance). Fix: `NotificationCenter.default.removeObserver(sizeObserver!)` in `deinit` (capture-safe pattern), or switch to the token-auto-invalidating `NSObjectProtocol` wrapper.

### L2. Process-wide `UserDefaults.didChangeNotification` work on every defaults write

**File:** `Sources/ntakker/PopoverController.swift:167-204`. Every `@AppStorage` write anywhere in the app (mode switch, provider change, language hints, acknowledgement flags…) fires this handler, which reads two defaults keys and computes clamps before bailing on the 0.5 pt delta check. Cheap but constant noise; during a drag it also runs `layoutSubtreeIfNeeded()` synchronously per tick. Consider observing the two specific keys via KVO on `UserDefaults` (`object(forKeyPath:)`) or debouncing.

### L3. Dead views: `LevelMeterView` and `ElapsedTimeView` are referenced nowhere

**Files:** `Sources/ntakker/Views/LevelMeterView.swift`, `Sources/ntakker/Views/ElapsedTimeView.swift`. Grep finds no usage outside their own files (superseded by `PopoverStatusBar`). They still cost maintenance and contain their own churn quirks (e.g. `LevelMeterView.animationKey` builds an interpolated `String` per 30 Hz tick as an animation value — `LevelMeterView.swift:42-46`). Delete or fold into the status bar.

### L4. `Date()` allocation per audio buffer on the capture queue

**File:** `Sources/NtakkerUIKit/LevelMeterTap.swift:113-119`. `ingest` calls `Date().timeIntervalSince1970` for every buffer (≈ 47/sec per source at 1024-frame callbacks) just for 30 Hz coalescing. Use `CACurrentMediaTime()`/`mach_absolute_time` — monotonic (immune to wall-clock jumps mid-recording) and allocation-free.

### L5. Q&A sidecar write failure logged with `print`, on the main actor

**File:** `Sources/ntakker/RootView.swift:363-367`. `print("QA sidecar write failed: ...")` goes to stdout (invisible for an `LSUIElement` app) instead of the project logger, and the write itself runs on the main actor inside an `onChange` (small file — acceptable, but inconsistent with the logging design §15.13). Route through `Logger` and consider `Task.detached`.

### L6. Per-token whole-array publish + unanimated scroll per token in Asking mode

**File:** `Sources/ntakker/Views/Asking/AskingModeView.swift:155-158, :268-273`. Each streamed token mutates `history[idx].answer` → `@Published` array fires → all subscribed views diff; `onChange(of: store.history.last?.answer)` calls `proxy.scrollTo` per token. `LazyVStack` keeps this tolerable, but for long answers consider batching deltas (e.g. flush every 50 ms) before appending, which also reduces sidecar-equality churn.

### L7. `startEventsForwarder` does a redundant `MainActor.run` hop per event

**File:** `Sources/NtakkerUIKit/RecordingController.swift:516-528`. The unstructured `Task` created inside a `@MainActor` method already inherits main-actor isolation; the inner `await MainActor.run { self.handle(event) }` adds an extra enqueue per event. Harmless but misleading about where the loop runs; annotate the task `@MainActor` and call `handle(event)` directly (as the level drain at `:392` already does).

### L8. `RootView.defaultAudioFilename()` is a hardcoded placeholder

**File:** `Sources/ntakker/RootView.swift:662` — `{ "recording-001.m4a" }`. The Save dialog displays a filename that almost never matches the real audio file (`completedSegments.last?.lastPathComponent` is available on the controller). Cosmetic, but it tells the user the bundle will contain a file it won't.

### L9. `PermissionStatusView` polls TCC every 2 s whenever visible, even after both grants are green in `.always` mode

**File:** `Sources/ntakker/Views/PermissionStatusView.swift:97-112`. The cadence is documented and popover-scoped (SwiftUI cancels `.task` on disappear), so the cost is small; an event-driven refresh (`didBecomeActiveNotification` is already wired) plus a slower idle cadence (10 s) once both are `.authorized` would eliminate the steady-state timer.

### L10. `RecordingController.setOptions` hardcodes the needs-key provider list, diverging from `RecordingStarter`

**File:** `Sources/NtakkerUIKit/RecordingController.swift:206-231` — only `gemini`/`gemini-live` set `needsKey = true`, while `RecordingStarter.swift:89-101` resolves keys for soniox / azure / elevenlabs too. The missing-key badge therefore never lights for Soniox/Azure/ElevenLabs even when their key is absent; the user only finds out at session start. Share one provider→env-var table between the two sites.

---

## Strengths (brief)

- **Bounded transcript memory:** `maxLiveTranscriptSegments = 100` cap with sidecar files as the persistent record (`RecordingController.swift:135-142, :669-674`); the id-keyed segment store fixes the duplicate-row bug correctly.
- **Level pipeline architecture is right:** allocation-free vDSP extraction with a pre-allocated scratch buffer (`LevelMeterTap.swift:148-224`), 30 Hz coalescing at the tap, `bufferingNewest(2)` stream policies everywhere, lock-protected latest-sample merge (`LevelMeterPublisher.swift:62-68`).
- **Actor-isolated coordinator with a documented state machine**, including the deliberately synthesized `.stopped` emission that defeats the forwarder-cancellation race (`SessionCoordinator.swift:380-415`) — a subtle bug class identified and fixed correctly.
- **Run-task is never cancelled to stop a recording** (file-level note, `RecordingController.swift:26-31`) — finalize integrity is protected by design.
- **`withObservationTracking` re-arm pattern** for the status-item icon and quit flow is idiomatic and weakly captured throughout (`AppDelegate.swift:319-335`, `QuitFlow.swift:244-270`).
- **`UIErrorPresenter` exhaustively maps all 26+ engine error cases** with typed recovery actions and no default clause, so new cases break the build instead of degrading (`UIErrorPresenter.swift:98-435`).
- **`BouncingBars` `TimelineView` is `paused: !isActive`** (`PopoverStatusBar.swift:289`) — no idle animation cost.
- **FR-34 renames and other file IO in `SessionCoordinator` run on the actor, off the main thread** (`SessionCoordinator.swift:604-655`).

## Finding index

| ID | Title | Severity |
|----|-------|----------|
| H1 | Double-click Start races two live sessions (orphaned session) | High |
| H2 | Session Save does bulk file IO on the main actor (UI freeze) | High |
| H3 | Data races on static diagnostic counters on audio queues | High |
| H4 | Leftover LEVELMETER_RT / per-event logging in hot paths | High |
| M1 | 30 Hz unconditional level publishing (even popover-closed / silent) | Medium |
| M2 | PopoverStatusBar whole-body re-eval at 30 Hz | Medium |
| M3 | Non-lazy transcript VStack + animated auto-scroll per partial | Medium |
| M4 | totalElapsed tick-count drift (visible clock + Q&A anchors) | Medium |
| M5 | Quit `.terminateLater` has no watchdog — unquittable on stall | Medium |
| M6 | cancelAll never called; coordinators never torn down | Medium |
| M7 | Settings runModal promotion: nested-modal + heuristic risks | Medium |
| M8 | .env re-parsed ~8× per Start click on main actor | Medium |
| M9 | ErrorBanner Try Again restarts with stale options | Medium |
| M10 | clearSession stop-then-start race when active | Medium |
| L1 | PopoverController notification observer never removed (wrong comment) | Low |
| L2 | Process-wide UserDefaults observer churn | Low |
| L3 | Dead views LevelMeterView / ElapsedTimeView (+ per-tick string key) | Low |
| L4 | Date() per audio buffer on capture queue | Low |
| L5 | QA sidecar failure via print(), write on main actor | Low |
| L6 | Per-token whole-array publish + scrollTo in Asking mode | Low |
| L7 | Redundant MainActor.run hop per coordinator event | Low |
| L8 | Hardcoded default audio filename in Save dialog | Low |
| L9 | 2 s TCC polling continues when both grants green | Low |
| L10 | Missing-key badge provider list diverges from RecordingStarter | Low |
