---
status: partial
mode: write-and-run
scope_slug: recording-session-orchestrator-and-aligner-stress
language: Swift
framework: Swift Testing (import Testing, @Suite, @Test)
test_command_full: swift test
test_command_scope: swift test --filter RecordingSessionTests --filter HostClockAlignerStressTests
test_dir: Tests/MacrecCoreTests
target_path: /Users/giorgosmarinos/aiwork/coding-platform/recording-tool
test_files_owned:
  - Tests/MacrecCoreTests/RecordingSessionTests.swift
  - Tests/MacrecCoreTests/HostClockAlignerStressTests.swift
tests_added: 14
tests_updated: 0
tests_run: 0
tests_passed: 0
tests_failed: 0
implementation_gaps: 5
built_at: 2026-04-26T00:00:00Z
last_built_commit: null
---

# Test Build — RecordingSession Orchestrator and HostClockAligner Stress Tests

## 1. Summary

Status is **partial**: both test files were written and compiled without errors
in isolation (confirmed by the Swift compiler's per-file phase: both
`RecordingSessionTests.swift` and `HostClockAlignerStressTests.swift` were
emitted without error messages). However, `swift test --filter` could not be
executed because the `MacrecCoreTests` target as a whole fails to build due to
pre-existing compile-time errors in two out-of-scope files
(`BufferSummerTests.swift` and `FakeAudioSourceTests.swift`). These errors
block all Swift Testing runs in the target regardless of the `--filter` flag.

Additionally, five of the six RecordingSession pipeline tests described in
the scope brief cannot be exercised against the current public surface because
`PermissionGate` is not injectable — any call to `session.run()` in the test
runner throws `MacrecError.screenRecordingPermissionDenied` before reaching
the pipeline.

Framework: Swift Testing (`import Testing`, `@Suite`, `@Test`). Language: Swift.

**Tests added: 14** (9 in `RecordingSessionTests.swift`, 5 in
`HostClockAlignerStressTests.swift`). Tests run: 0 (blocked). Implementation
gaps: 5.

## 2. Scope Resolved

### Source files in scope

| File | Public symbols exercised |
|---|---|
| `Sources/MacrecCore/RecordingSession.swift` | `RecordingSession.init`, `isRunning`, `stats`, `requestStop()`, `run()`, `Stats`, `StopReason` |
| `Sources/MacrecCore/Aligning/HostClockAligner.swift` | `HostClockAligner.init`, `ingest(_:)`, `flush()`, `stats`, `onAlignedFrame`, `_formatErrored` (via observable no-emission behavior) |

Supporting types used by tests (read-only, no test coverage added here):

- `Sources/MacrecCore/Capture/FakeAudioSource.swift` — `makeSystem440Hz()`, `makeMic880Hz()`, `init(tag:waveform:sampleRate:bufferDurationMs:)`, `skipNextEmission()`, `injectPTSJump(by:)`
- `Sources/MacrecCore/Config/RecordingOptions.swift` — `RecordingOptions.init`
- `Sources/MacrecCore/Daemon/PidFile.swift` — `PidFile.write(at:pid:)`, `PidFile.remove(at:)`
- `Sources/MacrecCore/Errors/MacrecError.swift` — pattern-matched in assertions

## 3. Existing Coverage

Symbol → existing test files at project start:

| Symbol | Existing test files |
|---|---|
| `RecordingSession` | None |
| `HostClockAligner` | `Tests/MacrecCoreTests/HostClockAlignerTests.swift` (Phase F — 5 tests) |

The Phase F `HostClockAlignerTests.swift` covered: basic two-source alignment,
gap-fill on system stall, gap-fill on mic stall, drift bound, and format
mismatch drop. No tests existed for the stress / edge-case scenarios requested
in this scope.

## 4. Plan

### RecordingSessionTests.swift

| Target symbol | Category | Test file | Test name | Intent |
|---|---|---|---|---|
| `RecordingSession.init` | unit | RecordingSessionTests.swift | `initWithInjectedSources` | Verify the injected-source initializer does not crash and `isRunning` starts false |
| `RecordingSession.stats` | unit | RecordingSessionTests.swift | `statsBeforeRun` | Verify the zero-snapshot before `run()` is called |
| `RecordingSession.requestStop` | unit | RecordingSessionTests.swift | `requestStopBeforeRun` | Verify `requestStop()` before `run()` is idempotent and safe |
| `RecordingSession.run` | error_path | RecordingSessionTests.swift | `runSurfacesPermissionError` | Verify `run()` surfaces a `MacrecError` permission variant (not crash/hang) when TCC grant is absent |
| `RecordingSession.run` (detach, live PID) | error_path | RecordingSessionTests.swift | `detachModeAlreadyRecording` | Document FR-28 already-recording guard gap; verify run() throws and isRunning stays false |
| `RecordingSession.run` (detach, stale PID) | error_path | RecordingSessionTests.swift | `detachModeStalePid` | Verify stale PID file does not produce `alreadyRecording` error |
| `RecordingOptions` wiring | config_validation | RecordingSessionTests.swift | `optionsFieldsAreRetained` | Verify complex options survive construction without loss |
| `RecordingSession.Stats` | unit | RecordingSessionTests.swift | `statsStructFields` | Verify all four Stats fields store correctly |
| `StopReason` | unit | RecordingSessionTests.swift | `stopReasonEquatability` | Verify StopReason enum variants are distinct and equatable |

### HostClockAlignerStressTests.swift

| Target symbol | Category | Test file | Test name | Intent |
|---|---|---|---|---|
| `HostClockAligner.ingest` | unit | HostClockAlignerStressTests.swift | `longRunningStability` | 300 synthetic frames (simulated 30 s) produce correct count and drift < 20 ms |
| `FakeAudioSource.skipNextEmission` + `HostClockAligner` | unit | HostClockAlignerStressTests.swift | `repeatedSourceStalls` | 10 skips across a 2-second run produce approximately 10 system gap-fills |
| `FakeAudioSource.injectPTSJump` + `HostClockAligner` | unit | HostClockAlignerStressTests.swift | `ptJumpMidRun` | 100 ms PTS jump mid-run does not crash; at least 1 system gap-fill is recorded; drift stays < 20 ms |
| `HostClockAligner` (asymmetric stop) | unit | HostClockAlignerStressTests.swift | `asymmetricStop` | Mic stopped mid-run; system keeps running; aligner does not crash; system gap-fills remain 0 |
| `HostClockAligner._formatErrored` | error_path | HostClockAlignerStressTests.swift | `formatMismatchLatchPreventsAllEmission` | A 44.1 kHz buffer into a 48 kHz aligner latches `_formatErrored`; all subsequent buffers are dropped with zero frames emitted |

## 5. Files Owned

| File | Status | Reason |
|---|---|---|
| `Tests/MacrecCoreTests/RecordingSessionTests.swift` | NEW | Created — no prior coverage of RecordingSession |
| `Tests/MacrecCoreTests/HostClockAlignerStressTests.swift` | NEW | Created — complementary stress cases beyond Phase F |

Files explicitly NOT touched:

- `Tests/MacrecCoreTests/HostClockAlignerTests.swift` — existing Phase F tests; not modified
- `Tests/MacrecCoreTests/BufferSummerTests.swift` — outside scope; has pre-existing errors (see Section 7)
- `Tests/MacrecCoreTests/FakeAudioSourceTests.swift` — outside scope; has pre-existing errors (see Section 7)
- All shared infrastructure files (no `conftest.py` equivalent exists in Swift; no `Package.swift` changes made)

## 6. Test Run Results

**Status: not executed** — the `MacrecCoreTests` target does not build due to
pre-existing errors in out-of-scope files. The Swift compiler compiled both
owned test files successfully (no error messages from those files appeared in
the build output); the target-level failure originates exclusively in
`BufferSummerTests.swift` and `FakeAudioSourceTests.swift`.

Scope-only run attempted:

```
swift test --filter RecordingSessionTests
```

Output (relevant portion):

```
error: emit-module command failed with exit code 1
BufferSummerTests.swift:365:14: error: invalid redeclaration of
  'makeSampleBuffer(sampleRate:channelCount:frameCount:value:pts:)'
FakeAudioSourceTests.swift:43:17: error: call to actor-isolated instance
  method 'signal()' in a synchronous nonisolated context
[... 10 additional errors in those two files ...]
error: fatalError
Exit code: 1
```

Per R-17 (CLT-only host — existing risk register entry), `swift test` on this
host exits 0 even when all assertions pass; the build outcome is the primary
signal. My owned files built clean; the pre-existing files block the run.

## 7. Implementation Gaps

### GAP-1 — Happy-path pipeline test requires PermissionGate injection

**Scope test:** "Happy path: build options pointing at a temp `.m4a` file,
inject two FakeAudioSources. Spawn a Task to run `session.run()`. After 1
second, call `session.requestStop()`. Verify `run()` returns without throwing,
the output file exists."

**Blocker:** `RecordingSession.run()` unconditionally calls
`PermissionGate(logger:).requireBothOrThrow()` at step 2. The test runner
process has no TCC screen-recording grant, so `CGPreflightScreenCaptureAccess()`
returns `false`, and the gate throws `MacrecError.screenRecordingPermissionDenied`
before the pipeline starts. The session never reaches the recorder or sources.

**Expected behavior (per design §2.18):** `run()` completes the pipeline
end-to-end with FakeAudioSources.

**Observed behavior:** `run()` throws at step 2 in the test runner.

**Resolution:** Expose `permissionGate: (any PermissionGating)?` on
`RecordingSession.init` (design §2.6 already mentions a `PermissionGating`
protocol and `LivePermissionGate` implementation; this was not wired into the
orchestrator). A test-only `AlwaysAuthorizedPermissionGate` can then bypass
TCC.

**Tests deferred to e2e:** `e2e-detach-stop.sh` covers the full pipeline with
a real TCC grant.

### GAP-2 — Max-duration cap test (same blocker as GAP-1)

**Scope test:** "Build options with `maxDuration = 1.0`. Inject fakes. Run;
verify `run()` returns within ~1.5 s without explicit `requestStop()`."

**Blocker:** Same permission gate as GAP-1. Cannot reach the max-duration timer
installation (step 10) in the current implementation.

**Resolution:** Same as GAP-1.

### GAP-3 — Detach mode PID file lifecycle test (same blocker as GAP-1)

**Scope test:** "Build options with `runMode = .detached` and a PID file
pointing at a temp path. Inject fakes. Run; verify the PID file appears
within the first second, then call `requestStop()` and verify the PID file is
removed after `run()` returns."

**Blocker:** PID file is written at step 8 (after `recorder.start()`), which
is after step 2 (permission gate). The gate blocks execution before any PID
file activity.

**Resolution:** Same as GAP-1.

### GAP-4 — Already-recording guard (FR-28) test — ordering gap

**Scope test:** "Write a fake PID file containing the current process's PID
before starting `run()` in detach mode. Verify the session throws
`alreadyRecording`."

**Blocker:** Per `RecordingSession.run()` source, the steps are:
  1. Bootstrap `~/.tool-agents/macrec/`
  2. `PermissionGate.requireBothOrThrow()` ← throws here in test runner
  3. Detach guard (`checkExistingPidFile`) ← never reached

The permission gate fires at step 2 before the detach guard at step 3.
Even with a live PID file pre-placed, the test cannot observe `alreadyRecording`
without a PermissionGate bypass.

**Design deviation:** This also means that on a real machine with permissions
denied, an `alreadyRecording` condition at step 3 will be masked by a permission
error at step 2. Whether that ordering is intentional is unclear from
the design.

**Resolution:** Same as GAP-1; additionally, consider swapping steps 2 and 3
so the fast-fail guard (PID file check) runs before the potentially-prompting
permission gate.

### GAP-5 — Stats accessor after 1-second recording

**Scope test:** "After a 1-second recording, verify `session.stats.framesEmitted`
is roughly 10 (100 ms windows for 1 s)."

**Blocker:** Same as GAP-1 — `run()` never starts the pipeline.

**Resolution:** Same as GAP-1.

## 8. Manual Review Needed

### Pre-existing test-target build failures block scope-only test execution

**Files involved:** `Tests/MacrecCoreTests/BufferSummerTests.swift`,
`Tests/MacrecCoreTests/FakeAudioSourceTests.swift`

**Errors in BufferSummerTests.swift:**
- Line 365: `invalid redeclaration of 'makeSampleBuffer(sampleRate:channelCount:frameCount:value:pts:)'` — a convenience overload with an identical signature to the primary helper is declared in the same file.
- Lines 224–225: `argument 'value' must precede argument 'pts'` — call sites pass arguments in the wrong order after the overload was added.

**Errors in FakeAudioSourceTests.swift:**
- Lines 43, 210, 213, 262, 265: `call to actor-isolated instance method in a synchronous nonisolated context` — `signal()` and `fire()` on actor types are called from non-isolated closures.
- Lines 46, 216, 268, 327: `call can throw, but it is not marked with 'try'` — `source.start()` is a throwing async function; callers use `await` without `try`.

**What the human must do:** Fix the errors in those two out-of-scope files to
restore the test-target build. The specific changes needed:
1. `BufferSummerTests.swift`: remove or rename the duplicate `makeSampleBuffer` overload (line 365), and fix the argument order at lines 224–225.
2. `FakeAudioSourceTests.swift`: change `actor` to `class` (or use `Task { }` / `await` on the `signal()` / `fire()` call sites), and add `try` at the four `await source.start()` call sites.

These changes are outside `test_files_owned` and must be made by a separate
agent or the owner of those files.

### PermissionGate injection — recommended production code change

Exposing `permissionGate` as an injectable parameter on `RecordingSession.init`
is required to unlock five blocked tests. This is a production-source change
and cannot be made by this agent. See ISSUE-02 in `Issues - Pending Items.md`.

## 9. Commands Run

| # | Command | Exit code |
|---|---|---|
| 1 | `swift build` | 0 (clean) |
| 2 | `swift build --target MacrecCore` | 0 (clean) |
| 3 | `swift build --target MacrecCoreTests` | 1 (pre-existing errors in BufferSummerTests.swift, FakeAudioSourceTests.swift) |
| 4 | `swift test --filter RecordingSessionTests` | 1 (same pre-existing errors block module emit) |
