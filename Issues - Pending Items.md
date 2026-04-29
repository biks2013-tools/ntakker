# Issues — Pending Items

> Tip: After completing or removing a pending item, move it to the
> "Completed items" section at the bottom. Pending items are listed
> most-critical-first.

## Pending items (most critical first)

The risks below were captured during Phases 4–6 of the planning and
implementation workflow (see `docs/design/plan-001-recording-tool.md`
§6 risk register, `docs/design/plan-002-toolbar-ui.md` §5 risk
register, and `docs/design/plan-003-live-transcription.md` §6 risk
register). They are tracked here so subsequent phases can flag
residual exposure.

### PLAN-007-DRIFT — `plan-007` drifts from actual code (NEW 2026-04-29)
Discovered during the Phase-5 Designer pass for plan-007 (additional
STT engines: Azure OpenAI + ElevenLabs). The plan must be patched
before any implementation work begins. Drifts:

1. `AudioWAVEncoder.encode(samples:)` is **non-throwing** (see
   `Sources/MacrecCore/Transcription/AudioWAVEncoder.swift:5`). plan-007
   §A.3 line 639 and §B.3 line 922 wrap the call in `try`. Drop the
   `try` keyword in both places.
2. `CostSummary` and `TranscriptionManagerStats` **do not exist**.
   The actual struct is `TranscriptionMetrics` in
   `Sources/MacrecCore/Transcription/TranscriptEvent.swift:29-37`.
   plan-007 §A.9 (line 824) and §B.9 (line 1129) build extensions on
   non-existent types. The design (§07D-8) corrects this by putting
   `costFor(durationSeconds:)` on each provider and proposing one
   optional new field on `TranscriptionMetrics`.
3. `ElevenLabsResponse.languageCode` is typed as non-optional in
   plan-007 §B.5 (line 1041). The wire shape may omit it — the design
   models it as `String?`.
4. plan-007 §B.5 only models the single-channel response. That is
   correct for v1 but should be made explicit (the multi-channel
   `MultichannelSpeechToTextResponseModel` is intentionally skipped
   because v1 never sets `use_multi_channel`). Design §07D-3.5 makes
   this explicit.
5. `ConfigResolver.resolve` switch at lines 347-354 is currently
   non-exhaustive after enum extension. plan-007 mentions the
   `.whisperkit` enum-case fix (§4.5) but does not call out that the
   compiler will demand new branches for `.whisperkit`, `.azureOpenAI`,
   and `.elevenLabs`. The design table in §07D-9.6 lists the exact
   extension.

### PLAN-007-A2 — Phase A2 (Azure Realtime) added to plan-007 (NEW 2026-04-29)
Phase A2 (Azure OpenAI Realtime over WebSocket) was originally
deferred to a hypothetical plan-007 because of an incorrect reading
of the batch wire-schema research's §14. After dedicated deep
research (`docs/research/azure-openai-realtime-transcription-wire-schema.md`)
confirmed the path is real, well-documented, and within reach of
Foundation `URLSessionWebSocketTask`, the user decided to bring the
work into plan-007. Status of the integration:

- **Plan**: `docs/design/plan-007-additional-stt-engines.md`
  re-titled to mention realtime; new "Phase A2 — Azure OpenAI Realtime
  Streaming (WebSocket)" section inserted between Phase A1 (renamed
  from Phase A) and Phase B; new VAD env vars in §A2.4; new error
  matrix in §8.1.RT; new risk register entries RT-RISK-1..7 in §10;
  new sequencing DAG with A1, A2, B as siblings in §11; new open
  decisions OQ-A2-1..5 appended in §13.
- **Design**: `docs/design/project-design.md` extended with new
  section "Plan-007 Design — Phase A2 Addendum: Azure OpenAI Realtime
  Streaming" (§A2D-1..§A2D-12). This addendum is the **authoritative
  spec** for the realtime path — Swift type signatures, Codable wire
  models with the model-field omission baked in by design, state
  machine, reconnect flow, 58-min pre-emptive reconnect flow,
  concurrency model, cost calculation, and back-compat impact.
- **Functions**: `docs/design/project-functions.md` extended with
  FR-AZ-13..FR-AZ-25 covering the realtime provider type, WebSocket
  transport, 24 kHz PCM16 framing, 16→24 kHz resample, model-field
  omission, VAD config, delta-event surface, 1006 reconnect-with-
  replay, 58-min pre-emptive reconnect, cost calculation, CLI mode,
  picker entry, and privacy-disclosure variant.
- **Research files**: §14 of the batch wire-schema patched to strip
  the `model` field from the example JSON, add the AZURE-SPECIFIC
  BUG callout, and point at the new realtime research file.
  Investigation file gained an erratum at the top correcting the
  original "Azure has no realtime variant" finding.

**Five new open decisions the user must answer before Phase A2
implementation can start (added to plan-007 §13):**

- **OQ-A2-1** — Resample location: inside `AzureOpenAIRealtimeSession`
  (planner: yes — isolated change) vs. add a 24 kHz capture path to
  `SCKitSystemAudioSource` and `AVMicrophoneSource` (cleaner but
  touches more files).
- **OQ-A2-2** — Should the WS URL include `&deployment={name}`?
  (planner: default false, behind a config flag
  `AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL`).
- **OQ-A2-3** — Ship A2 with delta events on (planner: yes — research
  confirms they work for `intent=transcription`) or `.completed`-only
  first?
- **OQ-A2-4** — Expose `turn_detection.threshold` / `prefix_padding_ms`
  / `silence_duration_ms` as env vars (planner: yes, with documented
  starter defaults 0.5 / 300 / 200) or hardcode?
- **OQ-A2-5** — Single PR for A1 + A2, or split (A1 in PR 1, A2 in
  PR 2)? Planner: default single PR per the user's original request,
  but the size increase is non-trivial — splitting would reduce
  review burden if the user prefers.

**Carried-forward dependency on PLAN-007-DRIFT**: the five drifts
listed in `PLAN-007-DRIFT` above are unchanged by Phase A2 — they
must still be fixed in plan-007 §A.3, §A.9, §B.5 (twice), and the
ConfigResolver switch before any code lands, regardless of whether
A2 ships in the same PR or a follow-up.

**Authoritative spec**: the new design subsection §A2D-1..§A2D-12
in `docs/design/project-design.md` is the source of truth for the
realtime path. The plan-007 §A2 section is the WHAT/WHEN; §A2D is
the HOW.

### PLAN-007-OQ — Open questions for plan-007 (NEW 2026-04-29)
Decisions the user must confirm before implementation starts. The
five plan-007 §13 questions are listed there; three additional
questions surfaced during design:

- **OQ-D-1**: Where should the ElevenLabs streaming-upload threshold
  (50 MB switchover from in-memory body to `httpBodyStream`) live —
  hardcoded `public static let` on the provider, or a config var
  `ELEVENLABS_STREAMING_THRESHOLD_BYTES`? Design recommends hardcoded.
- **OQ-D-2**: Should the factory log the resolved
  `AZURE_OPENAI_API_VERSION` at `info` level on every provider build?
  Design recommends yes.
- **OQ-D-3**: Cost surface as one extra `Double?` field on the
  existing `TranscriptionMetrics`, or a new `TranscriptionCostSummary`
  struct emitted via a new `TranscriptionEvent.costSummary(...)` case?
  Design recommends extending `TranscriptionMetrics` (minimal churn).

### UI-PEND-1 — Start/Stop buttons disappear after pressing Stop (FIXED 2026-04-28)
Reported by the user: after pressing Stop in the menu-bar popover, the
ControlBar empties out — neither Start nor Stop is visible — leaving
the user no way to start a new recording without restarting the app.
Root cause: `SessionCoordinator.stop()` in the `.recording` branch
relied on the engine's own `.stopped` reaching the UI via
`stateForwardTask`, but `stopCurrentAndAwait()` cancels that forwarder
as soon as `currentRunTask` resolves. Because the engine's
`stateStream` is a buffered `AsyncStream`, the `.stopped` (and
sometimes the preceding `.stopping`) could still be sitting in the
buffer when the cancellation fires; `Task.cancel()` on a task awaiting
an `AsyncStream` iterator returns `nil` from `next()` and skips the
remaining buffered items. The controller therefore stayed parked in
`.stopping`, and the ControlBar matrix
(`Sources/macrec-ui/Views/ControlBar.swift:140-148`) treats every
transient state as "no buttons visible" — hence the empty bar in the
screenshot. Fix: synthesise `emit(.stateChanged(.stopped))` inside
`SessionCoordinator.stop()` (`Sources/MacrecUIKit/SessionCoordinator.swift`)
right after `stopCurrentAndAwait()` and `.segmentCompleted`, mirroring
what `pause()` already does for `.paused`. The forwarder's relayed
`.stopped` (when it wins the race) is harmlessly idempotent against
`RecordingController.applyState(.stopped)`. Regression test added at
`Tests/MacrecUITests/SessionCoordinatorTests.swift::stopFromRecordingEmitsStoppedOnEvents`
that drains `coordinator.events` and asserts a `.stateChanged(.stopped)`
arrives after `stop()` from `.recording`. Build clean. Closed.

### LT-PEND-7 — `transcriptionSource == .mixed` silently dropped microphone audio (FIXED 2026-04-28)
Reported by the user after they verified mic capture was working
correctly via the new `mic_health` heartbeat (mic peak amplitude
0.02–0.41 → real voice present in the recording), but the
transcription sidecar contained only the system-audio side (other
Microsoft Teams participants), not the user's own voice — even though
the audio file was correctly mixed. Root cause:
`Sources/MacrecCore/RecordingSession.swift::setUpTranscriptionPipelineIfNeeded`
routed the `.mixed` case through
`manager.ingestFrame(frame, from: .system)`, and
`TranscriptionManager.ingestFrame(_:from:)` then read
`frame.systemBuffer` exclusively, dropping `frame.micBuffer`. So
`.mixed` was silently equivalent to `.system` for transcription —
inconsistent with `M4ARecorder`, which correctly mixes both via
`BufferSummer.sum(...)` for the audio file. Fix: in the addLiveTap
closure, sum `frame.systemBuffer` + `frame.micBuffer` with the same
`BufferSummer.sum(_:_:)` the recorder uses, then synthesise a
single-buffer `AlignedFrame` and forward it to the manager via the
existing `.system` branch (no manager API change). Verified: build of
`macrec-ui` clean. User-side e2e: a fresh recording with the default
`.mixed` source should now produce a sidecar containing the user's
voice in addition to whatever was playing through the speakers.
Closed.

### PEND-LOG-1 — UI file backend silently absent at `~/.tool-agents/macrec-ui/macrec-ui.log` (Open — investigation, 2026-04-28)
After the `.app` wrapper landed and TCC mic prompt was granted, the
user reported that `~/.tool-agents/macrec-ui/macrec-ui.log` does not
exist while OSLog (`log show --predicate 'subsystem ==
"com.local.macrec-ui"'`) shows the full log stream as expected. The
directory itself exists at mode `0700` (touched on launch by
`ToolAgentsBootstrap.ensure`), so the directory bootstrap is fine;
only the file-sink open path appears to be silently failing. The
`bootstrapLogging()` flow falls through to OSLog-only on
`FileLogSink.open` failure, writing only a stderr line that is
invisible when the app is launched via `open` (stderr goes to
launchd, not the console). Hypotheses: (a) `FileManager.createFile`
returning false under a path quirk specific to launches via
LaunchServices, (b) the `home` resolver returning a different URL
when the process is started by `open` vs a CLI shell. Workaround for
now: rely on `log show` for diagnostics. Owner: follow-up; estimate
30 min once the user reports back whether the file appears after the
`.mixed` transcription fix is in.

### PEND-AS-1 — TCC re-prompt for Speech Recognition on every ad-hoc-signed rebuild (Low — DX, plan-005 §9.3, 2026-04-28)
Same R-2 limitation applies to the new `NSSpeechRecognitionUsageDescription` permission: SPM-built CLI tools are ad-hoc-signed, so macOS invalidates the TCC grant on every rebuild and re-prompts the user. Documented in `docs/tools/macrec.md` parity with the existing R-2 mention. v2 `.app` packaging with a stable Developer-ID signature solves this. Owner: future packaging phase.

### LT-PEND-5 — UI ControlBar did not propagate transcription @AppStorage to RecordingOptions (FIXED 2026-04-27)
Reported by the user after Phase G shipped: launching macrec-ui,
selecting `Gemini Live` in the picker, and starting a recording
produced audio fine but **no live transcription appeared in the panel
and no sidecar `.jsonl` was written**. Root cause: `Sources/macrec-ui/Views/ControlBar.swift`
`startTapped()` composed `RecordingOptions` with only
`output / format / layout / micDevice`, ignoring the
`com.macrec.ui.transcribeProvider` / `transcribeSource` /
`transcriptFormat` `@AppStorage` keys and never resolving
`GOOGLE_API_KEY` from `ProcessInfo`. The result was that
`transcriptionProviderId` was always `nil`, so
`RecordingSession.setUpTranscriptionPipelineIfNeeded` short-circuited
at the `guard` and recording proceeded with no transcription pipeline
constructed — silently. The CLI path (`StartCommand.buildCLIOverrides`)
was unaffected because it routes through `ConfigResolver`.

Fix: extended `ControlBar` to read the three transcription `@AppStorage`
keys (provider / source / format), to resolve `GOOGLE_API_KEY` from the
merged process environment (the `AppDelegate` startup already merges
`~/.tool-agents/macrec-ui/.env` into `ProcessInfo`, so the documented
four-tier chain is honoured), and to pass all four into the
`RecordingOptions` initializer. Verified: `swift build --product
macrec-ui -c release` clean. Test recording with `Gemini Live` in the
picker should now spin up the WebSocket and produce a sidecar. Closed.

### LT-PEND-3 — `MACREC_TRANSCRIBE_PROVIDER` vs `MACREC_TRANSCRIBE` naming alignment (Low — DX / docs, plan-003 Phase H, 2026-04-26)
Plan-003 §4 Phase C originally specified `MACREC_TRANSCRIBE_PROVIDER`
and `MACREC_TRANSCRIPT_FORMAT`. Per the user-prompt direction at Phase
H, the as-built env-var family adopted the shorter `MACREC_TRANSCRIBE`
and `MACREC_TRANSCRIBE_FORMAT` for naming consistency
(project-design §LT-5.2 records the rationale). Documentation
(`docs/tools/macrec.md`, `docs/tools/macrec-ui.md`,
`docs/design/configuration-guide.md`, `docs/design/project-functions.md`)
has been updated to match the as-built names. **The plan-003 file
itself was not retroactively rewritten** — its §4 Phase C narrative
still references the original names. Open question for the user:
update plan-003 to reflect the as-built names too, or keep it as a
historical record and trust the doc reader to follow the "renamed at
Phase H" notes? Default: leave plan-003 historical.

### LT-PEND-4 — `MACREC_TRANSCRIBE_LANGUAGE` validation against provider supported list deferred (Low — DX, plan-003 Phase C, 2026-04-26)
The `--transcribe-language` / `MACREC_TRANSCRIBE_LANGUAGE` value is
passed to the provider as a hint without v1-time validation against
the provider's published supported-languages list. An invalid BCP-47
tag is silently ignored by the provider (auto-detect kicks in).
Tracked as a v2 follow-up to surface a friendly error or a
known-supported-languages dropdown in the UI. Owner: v2 backlog.

### R-LT-3 (Phase 7 review) — `transcriptionApiKeyMissing` deferred from resolver to driver-start (Low — deviation from design, plan-003 Phase C, 2026-04-26)
Project-design §LT-5.5 step 6 says: "Resolve the provider-specific API key … If nil → throw `MacrecError.transcriptionApiKeyMissing`." `ConfigResolver.resolve` instead returns `RecordingOptions` with `transcriptionApiKey = nil` and lets `RecordingSession.run` raise the exception inside `setUpTranscriptionPipelineIfNeeded` (which runs at Step 7.5, BEFORE `recorder.start()` at Step 8/9). AC-LT-4 ("no audio file is created") is therefore satisfied — the recorder never opens — but the failure boundary is one layer below the design's stated boundary.
The `RecordingOptions.swift` source comment acknowledges and documents this as an intentional exception, but it is NOT recorded in the project-memory "Approved Exceptions" section per CLAUDE.md's rule on configuration-rule exceptions ("If I ask you to make an exception to the configuration setting rule, you must write this exception in the projects memory file, before you implement it").
Resolution options: (a) move the check into `ConfigResolver.resolve` to match the design exactly (cleaner, matches no-fallback rule semantics — though the apiKey case is "missing key" not "fallback for missing key"), or (b) record the exception in `CLAUDE.md` "Project Memory / Approved Exceptions" with rationale (e.g. resolver doesn't know whether a session will run; deferring the throw lets the UI present a missing-key affordance without aborting the controller). Either is acceptable.
Owner: plan-003 follow-up. Estimate: 30 min for option (b), 1 h for option (a) including test updates.

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

### PEND-AS-2 — Apple SpeechAnalyzer SIGABRT on ad-hoc-signed CLI / Float32 buffers (Resolved 2026-04-28 in plan-005 Phase I debug)

First real-key e2e run of `test_scripts/e2e-transcription-apple.sh` on
2026-04-28 aborted with SIGABRT (exit 134) before producing any
output. Two distinct bugs surfaced sequentially during the debug
session:

1. **`SFSpeechRecognizer.requestAuthorization` crashes ad-hoc-signed
   CLIs on macOS 26.** TCC rejects the call (`"This app has crashed
   because it attempted to access privacy-sensitive data without a
   usage description"`) even when `NSSpeechRecognitionUsageDescription`
   is correctly embedded in `__TEXT,__info_plist`. Verified by
   isolating: a 6-line standalone Swift binary calling
   `SFSpeechRecognizer.requestAuthorization` aborts identically, even
   wrapped in an `.app` bundle in `~/Applications`. All third-party
   apps using SpeechRecognition on the host (Claude, Ghostty,
   Raycast, Notes) carry a real `TeamIdentifier` — Apple appears to
   gate this TCC service behind Developer ID signatures on macOS 26.
   **Resolution**: `SpeechPermission.ensureGranted()` made a no-op
   (the modern `SpeechAnalyzer` API does not require any TCC
   permission — verified end-to-end with `Speech.framework` directly,
   no IPC to `tccd` whatsoever).

2. **`SpeechAnalyzer` requires Int16 PCM, not Float32.** After fix #1,
   surfaced as `"Failed precondition: Audio sample data must be 16-bit
   signed integers"` in `SpeechFramework` log. Phase B's
   `ProductionSpeechAnalyzerAdapter` was constructing Float32
   `AVAudioPCMBuffer`s and yielding them via `AnalyzerInput`.
   **Resolution**: `pcmFormat` switched from
   `.pcmFormatFloat32 / non-interleaved` to
   `.pcmFormatInt16 / interleaved`; `makePCMBuffer` clamps incoming
   `[Float]` to `[-1, 1]` and quantises to full Int16 range via
   `int16ChannelData`. Also added `AssetInventory.assetInstallationRequest`
   download-on-first-use so the on-device language pack lands without
   user intervention.

Verification (`bash test_scripts/e2e-transcription-apple.sh`):
**PASS** — 4 apple-tagged sidecar lines, 5 of 6 keyword hits, model
field `"apple"`, language field `"en_US@rg=grzzzz"`. Regression
checks on `noop`, `key-missing`, and `gemini` scripts all PASS.

Files changed:
- `Sources/MacrecCore/Permissions/SpeechPermission.swift` (`ensureGranted` no-op + extensive docs)
- `Sources/MacrecCore/Transcription/Providers/SpeechAnalyzerAdapter.swift` (Int16 format + Int16 buffer fill + asset download)

### PEND-LT-6 — Default Gemini REST model id may 4xx; documented fallback (Resolved 2026-04-28 by switching the default in code)
The plan-004 brainstorming session (2026-04-28) initially pinned
`gemini-3.1-flash-live-preview` as the v1 default per user direction.
The same day's first real-key run of
`test_scripts/e2e-transcription-gemini.sh` empirically confirmed that
the model id returns HTTP 404 on `:generateContent` (it is the Live
WebSocket API SKU, not a REST SKU — exactly as the Gemini docs at
<https://ai.google.dev/gemini-api/docs/audio> warned). Re-running with
`MACREC_TRANSCRIBE_MODEL=gemini-3-flash-preview` produced a clean PASS
(2 segments, 6/6 keyword hits) using the documented Google REST audio
model. The default in
`Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift`
was switched from `gemini-3.1-flash-live-preview` to
`gemini-3-flash-preview` on 2026-04-28 along with the corresponding
doc updates in `docs/design/configuration-guide.md`,
`docs/tools/macrec.md`, and `docs/tools/macrec-ui.md`.
The old id remains in the `allowedModelIds` set for backward-compat
with explicit user configs (will produce HTTP 404, but is allowed).
The PEND-LT-6 risk recorded in plan-004 §9.1 is closed.

### LT-PEND-1 — Phase I manual smoke test against a real `GOOGLE_API_KEY` is still pending (High — verification, plan-003 Phase I, 2026-04-26)
Phases A–H of plan-003 (engine, configuration, persistence, networking,
provider, UI, documentation) are complete. **Phase I — the ten-step
manual smoke test against a real Gemini Live API key (plan-003 §4
Phase I) — has NOT yet been executed.** The user must:
1. Obtain a key at <https://aistudio.google.com/app/apikey>.
2. Run `bash test_scripts/e2e-transcription-noop.sh` (regression; no
   key required) and confirm exit 0.
3. Run `GOOGLE_API_KEY=… bash test_scripts/e2e-transcription.sh` and
   confirm exit 0.
4. Walk the UI happy path (steps 6–8 in plan-003 §4 Phase I).
5. Validate long-session reconnect (step 9) and network-drop simulation
   (step 10).
Until Phase I is signed off, the Gemini Live empirical-reliability
escalation (ESC-LT-1) remains open — if step 4 fails (no `final` event
within 30 s), fall back to the `gemini-live-2.5-flash-native-audio`
model (set `MACREC_TRANSCRIBE_MODEL`) and re-run. Owner: user.

Resolved by plan-004 (Phase J.2) — the new `e2e-transcription-gemini.sh` script automates the Phase I manual smoke test against a real `GOOGLE_API_KEY` for the REST-batch architecture.
(Resolved 2026-04-28 by plan-004 Phase J.2 — actual phase noted above)

### LT-PEND-2 — `--transcribe-source both` v1 limitation: single-driver fallback to `mixed` (Medium — feature gap, plan-003 Phase D / F, 2026-04-26)
v1 ships a single `TranscriptionDriver` (one provider Task, one
WebSocket session, one sidecar writer). When `--transcribe-source both`
is requested with a non-`split` recording layout, the driver falls
back to `mixed` and emits a single sidecar (project-design §LT-7.1
covers the layout-`split` × `both` case fully; the
non-split + `both` combination is the gap). True per-source dual-driver
transcription (two parallel WebSocket sessions, two sidecars labelled
`.system.transcript.<ext>` and `.mic.transcript.<ext>`) for the
non-split + `both` case is tracked as a v2 follow-up: extend
`TranscriptionDriver` to fan out into two cooperating drivers when the
combo demands it. The CLI / UI documentation calls out the fallback
explicitly. Owner: v2 backlog.

Resolved by plan-004 (Phase E) — the new `TranscriptionManager` actor instantiates one `SourceBuffer` per source for `--transcribe-source both` (regardless of recording layout) and emits per-source-tagged segments to a single sidecar.
(Resolved 2026-04-28 by plan-004 Phase E — actual phase noted above)

### R-LT-1 (Phase 7 review) — Sidecar filenames missing `.transcript.` infix (High — defect, plan-003 Phase D / G, 2026-04-26)
Both refined-request §AC-LT-1 ("absence of any `*.transcript.*` files") and §AC-LT-5 (`…part01.transcript.jsonl`) and project-design §LT-7.1 specify that sidecar paths are `recording-….transcript.<ext>` (and `…partNN.transcript.<ext>`). The implemented `SidecarPathBuilder.sidecarURL(...)` produces `recording-….<ext>` and `recording-….partNN.<ext>` — no `.transcript.` infix. The unit-test suite (`SidecarPathBuilderTests`) was authored to match the buggy implementation, not the design, so it does not catch the deviation.
Files to fix: `Sources/MacrecCore/Transcription/Persistence/SidecarPathBuilder.swift` (insert `"transcript"` into the components list right before `format.rawValue`), `Tests/MacrecCoreTests/Transcription/Persistence/SidecarPathBuilderTests.swift` (every expected-name string), and any e2e script under `test_scripts/` that lists sidecar paths.
Impact: AC-LT-5 (sidecar naming) fails as written; AC-LT-1 still passes (because it asserts negative match for `*.transcript.*` and the bug means no such file exists, but the assertion is moot). The transcription stream itself works correctly — only filenames are off-spec.
Owner: plan-003 follow-up coder. Estimate: 30 min including test updates.

Resolved by plan-004 (Phase F.1) — `SidecarPathBuilder` is updated to insert the `"transcript"` infix before `format.rawValue`; `SidecarPathBuilderTests` are rewritten to match the design.
(Resolved 2026-04-28 by plan-004 Phase F.1 — actual phase noted above)

### R-LT-2 (Phase 7 review) — `--detach --transcribe gemini-live` cross-check missing (Medium — design conformance, plan-003 Phase C, 2026-04-26)
Project-design §LT-5.5 step 8 mandates: "if `--detach` is true AND provider != `.none`, throw `MacrecError.transcriptionDetachUnsupported`." `MacrecError` does not have a `transcriptionDetachUnsupported` case, and `ConfigResolver.resolve` does not perform the cross-check. A user who runs `macrec start --detach --transcribe gemini-live` will reach `RecordingSession.run`, daemonize, and only then have transcription open a WebSocket from a detached process — which has no foreground stderr/stdout for partial output (the original concern that motivated the v1 exclusion in OQ-LT-5).
Files to fix: `Sources/MacrecCore/Errors/MacrecError.swift` (add `transcriptionDetachUnsupported` case → exit 64 EX_USAGE; description / remediation per design §LT-4); `Sources/MacrecCore/Config/ConfigResolver.swift` (add the cross-check after step 7 — before returning the `RecordingOptions`).
Impact: detach + transcribe currently launches a transcription session whose UI surface is invisible. No data corruption — transcription writes the sidecar — but the privacy disclosure path (FR-53) is bypassed and the user has no signal that the WebSocket is open.
Owner: plan-003 follow-up. Estimate: 1 h including new MacrecErrorTranscriptionTests assertion.

Resolved by plan-004 (Phase G.1) — by deletion. The REST architecture has no terminal-output dependency, so detach + transcribe is now valid. `MacrecError.transcriptionDetachUnsupported` is removed and `ConfigResolver` no longer enforces the cross-check.
(Resolved 2026-04-28 by plan-004 Phase G.1/G.4 — actual phase noted above)

### R-LT-4 (Phase 7 review) — JSONL header / footer not implemented (Medium — feature gap, plan-003 Phase D, 2026-04-26)
Project-design §LT-7.2 / §LT-9.1 specifies a 512-byte-padded JSONL header line that's "rewritten in place on every metric update and at session end" plus a `metricsSnapshot()` and `rotateSidecar(toAudioURL:)` actor surface. The implemented `JSONLTranscriptWriter` writes only per-event lines (no header), and `TranscriptSidecarWriter` exposes only `init / write / close / isOpen` — no `rotateSidecar`, no `metricsSnapshot`. The `JSONLTranscriptWriter`'s file-header comment acknowledges the omission ("there is no header line in this Phase D unit"). Phase G surfaces metrics from the controller's events stream rather than from the header, so the user-visible behavior of FR-58 still works — but a sidecar consumer that wanted to read summary metrics from the file alone (offline post-processing) cannot.
Impact: `jsonl` sidecars don't carry the metric summary specified in design table §LT-7.2 (the "header line is rewritten with final counts" footer is also absent). AC-LT-14 ("cost metrics emitted") is satisfied at the UI layer but not at the file layer.
Owner: plan-003 follow-up phase or v2. Estimate: 4–6 h including header rewrite, the actor's `rotateSidecar(toAudioURL:)` for in-place split + tests.

Resolved by removal in plan-004 — the 512-byte-padded JSONL header / footer rewrite scheme from project-design §LT-7.2 / §LT-9.1 is dropped (those design subsections are explicitly superseded by plan-004's §LT callout). The REST-batch architecture surfaces metrics via the `TranscriptionMetrics` value type (FR-58: chunks sent, billable seconds, error count, last RTT) emitted at stop on the events stream, in the post-stop UI summary, and at the `info`-level log line. JSONL sidecars carry only one record per coalesced segment with id-keyed in-place rewrite (plan-004 §5.2).
(Resolved 2026-04-28 by plan-004 — by removal; metrics surface via TranscriptionMetrics field — actual resolution noted above)

### R-LT-5 (Phase 7 review) — `RecordingSession.split(nextOutput:)` does not rotate sidecar (Medium — defect, plan-003 Phase G, 2026-04-26)
`RecordingSession.split(nextOutput:)` rotates the audio recorder atomically but leaves `_transcriptionSidecar` untouched. The driver continues writing to the original sidecar URL even though the audio file has rotated to `.partNN`. **Pause/resume flow (`SessionCoordinator.pause/resume`) is unaffected** — that path stops + restarts the session, so each segment naturally builds its own sidecar via `setUpTranscriptionPipelineIfNeeded`. Only the manual in-place split (FR-32 / `split()`) loses the rotation.
Impact: when a user invokes manual `split()` with transcription on, the resulting `recording.partNN.<format>` audio files do not have matching `recording.partNN.transcript.<ext>` siblings — there is one transcript that spans every partNN segment.
Resolution: when `_transcriptionSidecar` is non-nil during `split()`, close the old sidecar after the recorder swap, derive the new sidecar URL via `SidecarPathBuilder.sidecarURL(forRecording: nextOutput, …)`, open a new `TranscriptSidecarWriter`, and switch the forwarder task's target.
Owner: plan-003 follow-up.

Resolved by plan-004 (Phase G.4) — `RecordingSession.split(nextOutput:)` calls `manager.rotateSidecar(toAudioURL:)`, which closes the current sidecar writers, opens fresh ones at the path derived from `nextOutput` via `SidecarPathBuilder`, and resets the `SegmentCoalescer`. Surface added in Phase F.
(Resolved 2026-04-28 by plan-004 Phase G.4 — actual phase noted above)

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
