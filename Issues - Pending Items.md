# Issues — Pending Items

> Tip: After completing or removing a pending item, move it to the
> "Completed items" section at the bottom. Pending items are listed
> most-critical-first.

## Pending items (most critical first)

The risks below were captured during Phases 4–6 of the planning and
implementation workflow (see `docs/design/plan-001-recording-tool.md`
§6 risk register and `docs/design/plan-002-toolbar-ui.md` §5 risk
register). They are tracked here so subsequent phases can flag
residual exposure.

### R-22 (toolbar) — `swift test` exits 0 silently on Apple CommandLineTools (High — DX, plan-002 Phase 0, 2026-04-26)
Continuation of R-17. Tests written for `MacrecUITests` and
`MacrecCoreTests` compile but cannot be trusted on the dev host — the
test runner stub exits 0 without driving suites. Mitigation: every test
authored with `import Testing` + `@Suite`/`@Test` so it is ready for a
real runner; re-run on a CI image with full Xcode before declaring
plan-002 Phase I complete. Owner: Phase I, Phase 7 (Code Reviewer),
user (CI provisioning).

### R-23 (toolbar) — TCC re-prompt on every UI rebuild (Medium — DX, plan-002 Phase 0, 2026-04-26)
`com.local.macrec-ui` is a different bundle id from the CLI's
`com.local.macrec`, so granting Screen Recording to the CLI does NOT
grant it to the UI. Ad-hoc-signed SPM builds also re-prompt on every
rebuild (continuation of R-2). Mitigation: documented prominently in
`docs/tools/macrec-ui.md`; deferred to v2 `.app` packaging with a stable
Developer-ID signature. Owner: user accepts the rebuild-reprompt cost
in v1.

### R-24 (toolbar) — SwiftUI `MenuBarExtra` Apple Feedback bugs (High — architecture, plan-002 Phase 0, 2026-04-26)
FB11984872, FB10185639, FB10185468 prevent the four FR-41 status-icon
states and programmatic dismiss. **Already mitigated by the locked
architecture**: use AppKit `NSStatusItem` + `NSPopover` +
`NSHostingController<RootView>` (investigation Topic 1 Option 1B), NOT
`MenuBarExtra`. No further mitigation needed. Owner: Phases C, E
(architecture lock).

### R-25 (toolbar) — Manual split inherits AAC priming seam (Low, plan-002 Phase 0, 2026-04-26)
Manual `split()` atomic-swap has an audible seam gap of up to ~52 ms
(10 ms swap latency + 42 ms AAC priming for m4a; ~10 ms for wav/caf).
AC-UI-7 ceiling is 250 ms; comfortable headroom. Mitigation: measure
during plan-002 Phase K with `afinfo` durations on consecutive segments;
if observed seam exceeds 100 ms in the field, revisit by pre-warming
the new recorder earlier in the swap. Owner: Phase K verification.

### R-26 (toolbar) — `NSStatusItem` deallocates silently (Low, plan-002 Phase 0, 2026-04-26)
If `NSStatusItem` is not retained on `AppDelegate`, the icon vanishes
with no error. Mitigation: Phase 7 Code Reviewer must verify
`AppDelegate.statusItem` is a stored strong-reference property. Code
review checklist item.

### R-27 (toolbar) — `NSOpenPanel` dismisses transient popover (Low, plan-002 Phase 0, 2026-04-26)
`NSOpenPanel` interaction with `.transient` popover behavior dismisses
the popover when the folder picker opens. Mitigation: `FolderPicker`
switches popover to `.semitransient` for the duration of the panel and
restores `.transient` on close. Verified by Phase K folder-picker
walk-through.

### R-28 (toolbar) — `AsyncStream` continuation leak on teardown (Low, plan-002 Phase 0, 2026-04-26)
Continuation leak if `.finish()` is not called on session teardown.
Mitigation: `RecordingSession.resolveRunLoop` calls
`stateContinuation.finish()` at exit. Code review checklist item for
Phase 7.

### R-29 (toolbar) — SCStream cold-start latency on Resume (Low, plan-002 Phase 0, 2026-04-26)
Each Resume incurs SCStream warmup (~200–500 ms on Apple Silicon). v1
spec does not impose a Resume-latency SLO. Measure during plan-002
Phase K (AC-UI-6); if observed cold-start > 1 s consistently, file a
v1.1 follow-up to pre-warm a parked SCStream. Owner: Phase K.

### R-30 (toolbar) — Wave 5 shared `RootView.swift` edit boundary (Low — architecture, plan-002 Phase 5 Designer, 2026-04-26)
Phase F (quit flow) and Phase G (error mapping) both attach modifiers
to `RootView`. Dispatching them as parallel coders would race on the
same file. Mitigation: orchestrator must dispatch Wave 5 sequentially
(F → G) or merge the modifications via a foreground Merge Resolver
agent after parallel runs. Owner: Phase 6 dispatch (orchestrator).

### R-21 — Embedded Info.plist now present, but TCC binding to bundle id is path-sensitive (Medium — discovered post-Phase 10, 2026-04-26)
SPM-built CLI tools have no Info.plist by default, so macOS could not
display TCC prompts (the `check-permissions` UX printed "not determined"
and lied about a prompt being triggered). Fixed by:
1. Creating `Resources/Info.plist` with `NSMicrophoneUsageDescription`,
   `NSScreenCaptureUsageDescription`, `NSScreenCaptureDescription`,
   `CFBundleIdentifier=com.local.macrec`, `CFBundleVersion=0.1.0`.
2. Updating `Package.swift` to embed it via
   `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist
    -Xlinker Resources/Info.plist`.
3. Rewiring `CheckPermissionsCommand` to actually call
   `MicrophonePermission.request()` and `ScreenRecordingPermission.request()`
   when state is `.notDetermined` (was: print-only).
4. Rewriting the misleading "Approve the prompt that just appeared"
   hint when no prompt was triggered.
Verified: `otool -s __TEXT __info_plist` shows the section is now
embedded (1,415 bytes).
**Residual risk**: macOS TCC keys permissions by binary path AND
bundle id. If the user moves `.build/release/macrec` to another
location, they may need to re-grant Screen Recording. The ad-hoc
signature also re-prompts on every rebuild (this is the long-standing
R-2 ad-hoc-signing instability — wrap in a real `.app` with a stable
Developer-ID signature when shipping for production).
Owner: user / future packaging phase.

### R-17 — Local toolchain has no XCTest runner (High — discovered Phase A, 2026-04-26)
The dev host is on Apple CommandLineTools (Swift 6.3.1, no Xcode).
XCTest is not bundled with CLT, and `swiftpm-testing-helper` for the
`swift-testing` framework on CLT is a stub that exits 0 without
actually driving the runner — including for deliberately-failing
`#expect(false)` checks. All test files were authored with `import
Testing` + `@Suite/@Test`, so the codebase is ready for a real
runner. **Subsequent phases (B–L), the Code Reviewer (Phase 7), and
the Integration Verifier (Phase 10) must NOT trust local `swift test`
output.** Mitigation options:
1. Install Xcode on the dev host (gives a working test runner).
2. Run tests in CI with a macOS image that ships Xcode.
3. Accept that local `swift test` is a build check only.
Owner: user decision — flag at Phase 7 / Phase 10.


### R-1 — `replayd` silent-stop bug (Medium)
`SCStream` may stop delivering buffers without a `didStopWithError`
callback. Mitigated by the buffer-arrival watchdog (5 s poll, 10 s
staleness threshold), full restart of the `SCStream`, and a fatal
3-restarts-in-60-s cap. `Task { }` wraps `didStopWithError` to dodge
`EXC_BAD_ACCESS`. Owner: Phase I (wired). Residual: heuristic threshold —
real-world stress test pending Phase 10 / production use.

### R-13 — Recording during system sleep (Medium)
`SCStream` stops delivering when the host sleeps; the watchdog cannot
restart it without help. Implementation listens for
`NSWorkspace.willSleepNotification` / `didWakeNotification` and resets
the `lastBufferArrival` baseline on wake. Owner: Phase I. Residual:
real-world sleep/wake test pending Phase 10.

### R-14 — Double-fork done wrong → orphan/zombie (Medium)
Strict adherence to Stevens APUE §13.3 sequence
(`fork → setsid → fork → chdir("/") → umask(0) → close(stdin),
dup2(logFd, stdout/stderr)`). Intermediate parent MUST `_exit(0)`. To
be covered by `test_scripts/e2e-detach-orphan-check.sh` (Phase 10).
Owner: Phase K (implementation), Phase 10 (verification).
Residual: medium — test is platform-sensitive
(macOS SIGHUP / launchd interaction).


### R-6 — `finishWriting` timeout on 60-minute file (Low)
Long m4a finalization can exceed expected bounds. Mitigated by a 30-s
`DispatchWorkItem` watchdog; on fire, exit 2 with stderr message naming
the partial file. Phase 10 measures actual duration in
`e2e-60min-stability.sh`. Owner: Phase G (implemented), Phase 10
(verification).

### R-16 — `stop` timeout too aggressive on slow finalize (Low)
`--stop-timeout` is configurable (FR-26 default 35 s). Phase 10's
`e2e-detach-stop.sh` measures actual finalize time and may tune the
default. Owner: Phase K (implemented), Phase 10 (verification).

### R-8 — `movieFragmentInterval` × `shouldOptimizeForNetworkUse` (Low)
Interaction unverified; Phase 10 will run `afinfo` and `mp4info` on a
recorded file to confirm atom order. If broken, drop fragmentation and
rely on moov-at-front. Owner: Phase G, Phase 10.

### R-10 — "Uptime PTS trap" in absolute host-time PTSs (Documented)
Host-time PTS makes the file timeline non-zero in QuickTime. Adopted
research recommendation:
`startSession(atSourceTime: CMClock.hostTimeClock.time)` captured at
`RecordingSession.start()`. Duration & sync correctness preserved;
QuickTime shows non-zero start offset. Revisit if downstream phases
need t = 0. Owner: Phase F, G, J.

### R-2 — TCC ad-hoc-signing instability (Low — DX only)
Developer rebuilds re-prompt every time. Documented in
`docs/tools/macrec.md` "Permissions" section together with
`tccutil reset ScreenCapture` and `tccutil reset Microphone`
remediation. Owner: Phase L (documented).

### R-3 — Output device change mid-recording undefined (Low)
Spec clarification: "captures the submix of the default output device
at start time; changing output devices during recording is
unsupported." Documented in `docs/tools/macrec.md` "Limitations" section.
Consider mid-recording output-device-change detection in v2.
Owner: Phase L (documented).

### R-7 — macOS 26.x (Tahoe) plain-binary TCC listing regression (Low)
Cosmetic UX limitation; documented in `docs/tools/macrec.md`
"Limitations". Recommend `.app` wrapper for permission management UX.
No runtime mitigation. Owner: Phase L (documented).

### R-9 — Bluetooth output route can mute submix in rare configs (Acknowledged)
Out of our control (assumption A-4). Documented in
`docs/tools/macrec.md` "Limitations". Owner: Phase L (documented).

### R-5 — No CI for E2E TCC tests (Acknowledged — NFR-10)
AC-4..AC-12 must be manual. `test_scripts/e2e-*.sh` provide a
repeatable manual procedure; documented in `docs/tools/macrec.md`
"Manual TCC test prerequisite for E2E scripts". Owner: Phase L
(documented).

### R-11 — Empty `excludingApplications` filter on macOS 12.x (None)
Out of scope (we target macOS 14+). No mitigation owed.

### R-20 — Strict-concurrency=complete warnings in encoders (Low — discovered Phase 10, 2026-04-26)
Building with `-Xswiftc -strict-concurrency=complete` (Swift 6 forward-looking) emits ~25+ Sendable warnings, all concentrated in two files:
- `Sources/MacrecCore/Encoding/M4ARecorder.swift` — `CMSampleBuffer` and `[WriterUnit]` captures in `@Sendable` closures, generic `T` not `Sendable` in `withTimeout` helper.
- `Sources/MacrecCore/Capture/SCKitSystemAudioSource.swift` — `CMSampleBuffer` capture in a `@Sendable` closure (line 325).
The default build (Swift 5.9 mode) is clean — no warnings, no errors. This issue tracks the work needed if/when the project moves to Swift 6 language mode (where these warnings become errors). No runtime impact today.

### R-30 — Wave 5 (Phases F + G) shared edit boundary on `RootView.swift` (Low — discovered Phase 5 design, 2026-04-26)
Plan-002 dispatches Phase F (quit-while-recording flow) and Phase G (error-mapping banner) in parallel within Wave 5. The design (`docs/design/project-design.md` §15.15 "Wave 4 → Wave 5" boundary table) shows that both phases edit `Sources/MacrecUIKit/Views/RootView.swift`: F adds a Quit button at the bottom of the popover stack; G inserts an `ErrorBanner` at the top. Concurrent agents editing the same file will race or merge-conflict. **Mitigation**: Phase 6 orchestrator MUST dispatch F and G **sequentially** within Wave 5 — F first (adds the Quit affordance) then G (adds the ErrorBanner) is the recommended order, but either ordering is acceptable as long as the two are not concurrent. Each individual phase remains a single-file edit; only the Wave 5 dispatch order matters. Owner: Phase 6 orchestrator + Phase 7 Code Reviewer.

## Completed items

### R-31 (Phase 7 review) — FR-34 `.part01` rename of first segment unimplemented (Resolved 2026-04-26)
Resolution: `SessionCoordinator.pause()` and `split()` now invoke a new private `renameFirstSegmentOnDisk(bareURL:)` on the seg 1 → seg 2 transition. The helper consults `baseOptions.layout` to decide whether to rename one file (mixed / stereo-split) or both `.system` and `.mic` sidecars (split layout). `SegmentNamer` gained `renameForFirstSegment(_:)` and `splitSidecarURLs(baseURL:)` static helpers. Failures are logged at `.warning` and swallowed. Tests: `Tests/MacrecUITests/SegmentNamerTests.swift` (4 new cases) and `Tests/MacrecUITests/SessionCoordinatorTests.swift` (3 new cases — mixed rename, split-layout dual rename, rename-failure non-fatal). Files: `Sources/MacrecUIKit/SegmentNamer.swift`, `Sources/MacrecUIKit/SessionCoordinator.swift`. Owner: Phase 7 follow-up.

### R-32 (Phase 7 review) — `~/Recordings/` default folder unimplemented (Resolved 2026-04-26)
Resolution: `Sources/macrec-ui/Views/FolderPicker.swift` now declares a `DefaultRecordingFolder.resolve()` helper that returns `~/Recordings/` (creating it if missing), with conservative fallbacks to `~/Documents/` and `NSTemporaryDirectory()` if `~/Recordings/` cannot be created. `FolderPicker.body.onAppear` bootstraps `folderPath` to the resolved default on first launch and persists it back to `@AppStorage`. `ControlBar.startTapped()` performs the same resolve-and-persist, and the Start button's `.disabled(folderPath.isEmpty)` gate has been removed (it was the friction). Files: `Sources/macrec-ui/Views/FolderPicker.swift`, `Sources/macrec-ui/Views/ControlBar.swift`. Owner: Phase 7 follow-up.

### R-33 (Phase 7 review) — `docs/tools/macrec-ui.md` `@AppStorage` table wrong (Resolved 2026-04-26)
Resolution: the `<info>` block's `@AppStorage` table now lists all five `com.macrec.ui.*` keys (`outputFolder`, `basename`, `format`, `layout`, `micUID`) matching the `@AppStorage(...)` declarations in `Sources/macrec-ui/Views/*.swift`, plus a clarifying note that the prefix is `com.macrec.ui.*` reverse-DNS and that these are UI persistence (NOT runtime configuration, so the no-fallback rule does not apply). File: `docs/tools/macrec-ui.md`. Owner: Phase 7 follow-up.

### R-34 (Phase 7 review) — `project-functions.md` Phase J flips never landed (Resolved 2026-04-26)
Resolution: status lines flipped to `IMPLEMENTED (Phase X completed 2026-04-26)` for FR-35, FR-36, FR-37, FR-38, FR-39, FR-40 (all Phase E); FR-41 (Phases C+E); FR-43 (Phases A+D+E); FR-44 (Phases 0+J); NFR-11 (Phases D+E, Phase K verification still pending); NFR-12 (Phase G); NFR-16 (Phase H). NFR-13 left as `PLANNED (Phase K verification pending)` per spec. File: `docs/design/project-functions.md`. Owner: Phase 7 follow-up.

### ISSUE-02 — PermissionGate not injectable into RecordingSession (Resolved by plan-002 Phase A, 2026-04-26)
Resolved by plan-002 Phase A: `PermissionGating` protocol introduced (project-design §15.3.4); `RecordingSession.init` accepts `permissionGate: (any PermissionGating)? = nil` injection. Default-`nil` preserves pre-Phase-A CLI behavior (constructs a live `PermissionGate` exactly as before). Tests inject a stub conformer (`AlwaysAuthorizedGate` / `StubPermissionGating`) that bypasses the TCC check, unblocking happy-path pipeline tests on hosts without a screen-recording grant. `LivePermissionGate` is exposed as a typealias for the live conformer name. Files: `Sources/MacrecCore/Permissions/PermissionGate.swift`, `Sources/MacrecCore/RecordingSession.swift`. Tests: `Tests/MacrecCoreTests/PermissionGatingProtocolTests.swift`. Owner: plan-002 Phase A.

### ISSUE-01 — Pre-existing test-target build failures in BufferSummerTests.swift and FakeAudioSourceTests.swift (Resolved Phase 9, 2026-04-26)
Resolved during Phase 9 test-builder work. The MacrecCoreTests target now builds cleanly with `swift build --build-tests` (verified Phase 10). The duplicate-overload and actor-isolation errors flagged at Phase J have been fixed in the corresponding test files.

### R-18 — `Recorder` protocol shape diverged from design §2.10 (Resolved Phase 7, 2026-04-26)
Resolution: **Option A** — design doc updated to match the implemented
`async throws` shape. `docs/design/project-design.md` §2.10 now shows
`func start() async throws`, `func append(_ frame: AlignedFrame) throws`,
and `func finalize(timeout:) async throws` plus a callout describing the
deviation rationale. The original closure-based draft is preserved only
in commit history. The `async throws` shape integrates cleanly with the
async `RecordingSession` lifecycle (no
`withCheckedThrowingContinuation` shim at every callsite) and preserves
FR-20 watchdog semantics (the 30 s `finalize(timeout:)` race is
implemented inside `M4ARecorder.withTimeout`). Files unchanged in code:
`Sources/MacrecCore/Encoding/Recorder.swift` and the three concrete
recorders are already on the new shape. Owner: Phase 7.

### R-19 — Env-var prefix inconsistency: `OUTPUT_PATH` is unprefixed (Resolved Phase 7, 2026-04-26)
Resolution: **Option A** — keep `OUTPUT_PATH` unprefixed. Rationale:
(a) the value is semantically generic and the project's CLAUDE.md
explicitly recommends sharing common env-var names across tools (e.g.
the LLM-provider canonical names like `OPENAI_API_KEY`); (b) the
documentation in `docs/design/configuration-guide.md` §2.1 and
`docs/tools/macrec.md` already explains the choice; (c) renaming would
add migration cost with no functional improvement. Phase 7 also fixed a
small adjacent issue: `MacrecError.flagName(forConfigKey:)` previously
mapped `OUTPUT_PATH` → `output-path` in remediation strings, so the
"missing required config" message read "Set --output-path on the
command line" while the actual flag is `--output`. The mapping now
special-cases `OUTPUT_PATH` → `output`. File:
`Sources/MacrecCore/Errors/MacrecError.swift`. Owner: Phase 7.

### R-12 — FR-15 output-path validation (Completed Phase G, 2026-04-26)
`RecordingOptions` validates the AAC bitrate range (`64–320 kbps`); the
recorder factory in
`Sources/MacrecCore/Encoding/Recorder.swift` validates the output path
parent existence and overwrite semantics before opening the writer.
Implemented in Phase G.

### R-15 — Stale PID race on `start --detach` (Completed Phase K, 2026-04-26)
A new `start --detach` may fire while a stale PID file exists. Refused
if the PID is alive (FR-28); if stale, removed and continued. TOCTOU
window between `kill(pid, 0)` ESRCH and our PID write is mitigated by
atomic `<path>.tmp + rename` in `PidFile.write`. The check is
implemented in
`Sources/MacrecCore/RecordingSession.swift::checkExistingPidFile` and
exercised by `test_scripts/e2e-stop-already-recording.sh`. Owner:
Phase K.

### R-4 — AAC bitrate validation (Completed Phase B, 2026-04-26)
FR-8 didn't bound the range originally; `ConfigResolver.parseBitrate`
now validates `bitrate ∈ [64, 320]` kbps (or equivalently
`[64000, 320000]` bps) and rejects out-of-range values with
`MacrecError.invalidConfigValue` (exit 64, `EX_USAGE`). Owner: Phase B.
