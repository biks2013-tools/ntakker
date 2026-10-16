# plan-018 — EVAL-2026-10-16 quick fixes (wave 1: small, high-value)

**Specification source (authoritative):** `docs/reference/evaluation-2026-10-16-quality-performance.md` §1, §2, §4 item 1. Registered as `EVAL-2026-10-16` in `Issues - Pending Items.md`.

**Execution rules:** one task at a time; `swift build` + targeted tests after each task (convo-coach: `npm run build` + `npm test`); commit after each task (user-authorized 2026-10-16), staging only the files the task touched. Pre-existing failing test baseline is the one recorded in `docs/design/plan-017-eval-fixes-waves-1-3.md` — no task may add a new failure.

## Tasks

- [x] **T1 (CC-1)** convo-coach stdin mode unreachable — `tools/convo-coach/src/index.ts:458` `isTTY === false` → `!process.stdin.isTTY`; add piped-input test.
- [x] **T2 (TR-1)** Serialize inference in `ParakeetTranscriptionProvider` / `WhisperKitTranscriptionProvider` (engines are not re-entrant).
- [x] **T3 (TR-3)** Azure realtime `finish()`: send `input_audio_buffer.commit`, wait (≤2 s) for outstanding transcriptions, then close.
- [x] **T4 (INF-4)** Daemonizer `umask(0)` → `umask(0o077)`.
- [x] **T5 (CAP-4)** SCStream `minimumFrameInterval` → 1 s so the throw-away video output stops running at display rate.
- [x] **T6 (CAP-5)** M4A `endSession` at last PTS **+ duration** (stop trimming the final frame). **Note:** the claimed loss did NOT reproduce — 3 s recordings measure 3.0000 s (AVURLAsset duration + track timeRange) and 144 000 encoded frames both before and after. Kept as an API-semantics correctness change (no measurable effect); CAP-5 downgraded in the report.
- [x] **T7 (CAP-7)** WAV/CAF recorders latch the first write error and surface it from `append`/`finalize`.
- [x] **T8 (CAP-8)** M4A finalize drains pending buffers before `markAsFinished()`.
- [x] **T9 (CAP-10)** SCStream `restartStream` in-progress latch.
- [x] **T10 (INF-7)** AskConfig: no force-unwrapped env URLs → `invalidConfigValue`.
- [x] **T11 (TR-8)** SourceSplit `stop()` stops both children in parallel.
- [x] **T12 (TR-9)** `TranscriptionManager.awaitValue` deadline via continuation race (not `withTaskGroup`).
- [x] **T13 (TR-17)** Sidecar writers never truncate a file that is still open in this process. **Scope refined:** truncating a *stale* sidecar from an earlier recording is correct (the audio path is already guarded by `--overwrite`), so the guard is a process-wide open-path registry in `TranscriptSidecarWriter` (second open → `alreadyOpen`), not "never truncate".
- [x] **T14 (H2)** Session Save: `moveItem` (fallback copy across volumes) off the main actor.

## Acceptance
`swift build` green after each task; touched suites green; no new failures vs plan-017 baseline; checkbox ticked + finding noted in the Issues register at the end of the wave.

## Wave result (2026-10-16)

All 14 tasks landed, one commit each. `swift build` green; convo-coach 168/168.

**Full-suite comparison — zero new failures.** Every failure seen at HEAD reproduces identically at the pre-plan commit `bf69be5` (checked in a temporary worktree):
- The plan-017 baseline set: Gemini REST ×5, SessionCoordinatorTranscriptionIntegration (`gemini-live` alias, `partNN` naming), ConfigResolver "Shell env supplies transcription keys", SonioxConfigBuilder V1-policy, AppleSpeechSessionReconciliation, HostClockAlignerStress ×2.
- **Two pre-existing failures missing from the plan-017 list:** `AudioDownsamplerTests:144` ("100 ms of 1 kHz sine → Int16 within bounds") and `UIErrorPresenterTests:220` ("staleRecording → retry").
- **`NtakkerCoreTests.RecordingSessionTests` never finishes — at baseline too.** `sample` shows the test process spinning in `HostClockAligner.appendSamples` (C1 full-buffer copy per ingest + CAP-2 backlog growth), not deadlocked. This is why a plain `swift test` appears to hang. Run the rest with `swift test --skip NtakkerCoreTests.RecordingSessionTests`. Fixing it belongs to the aligner rewrite (CAP-1/CAP-2/C1).

**Verified only by build / reasoning (no harness):** T3 (Azure realtime WebSocket), T9 (SCStream restart race), T14 (popover Save — needs a manual Save of a recorded session).

