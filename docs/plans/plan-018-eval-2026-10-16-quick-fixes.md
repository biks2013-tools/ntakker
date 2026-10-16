# plan-018 — EVAL-2026-10-16 quick fixes (wave 1: small, high-value)

**Specification source (authoritative):** `docs/reference/evaluation-2026-10-16-quality-performance.md` §1, §2, §4 item 1. Registered as `EVAL-2026-10-16` in `Issues - Pending Items.md`.

**Execution rules:** one task at a time; `swift build` + targeted tests after each task (convo-coach: `npm run build` + `npm test`); commit after each task (user-authorized 2026-10-16), staging only the files the task touched. Pre-existing failing test baseline is the one recorded in `docs/design/plan-017-eval-fixes-waves-1-3.md` — no task may add a new failure.

## Tasks

- [ ] **T1 (CC-1)** convo-coach stdin mode unreachable — `tools/convo-coach/src/index.ts:458` `isTTY === false` → `!process.stdin.isTTY`; add piped-input test.
- [ ] **T2 (TR-1)** Serialize inference in `ParakeetTranscriptionProvider` / `WhisperKitTranscriptionProvider` (engines are not re-entrant).
- [ ] **T3 (TR-3)** Azure realtime `finish()`: send `input_audio_buffer.commit`, wait (≤2 s) for outstanding transcriptions, then close.
- [ ] **T4 (INF-4)** Daemonizer `umask(0)` → `umask(0o077)`.
- [ ] **T5 (CAP-4)** SCStream `minimumFrameInterval` → 1 s so the throw-away video output stops running at display rate.
- [ ] **T6 (CAP-5)** M4A `endSession` at last PTS **+ duration** (stop trimming the final frame).
- [ ] **T7 (CAP-7)** WAV/CAF recorders latch the first write error and surface it from `append`/`finalize`.
- [ ] **T8 (CAP-8)** M4A finalize drains pending buffers before `markAsFinished()`.
- [ ] **T9 (CAP-10)** SCStream `restartStream` in-progress latch.
- [ ] **T10 (INF-7)** AskConfig: no force-unwrapped env URLs → `invalidConfigValue`.
- [ ] **T11 (TR-8)** SourceSplit `stop()` stops both children in parallel.
- [ ] **T12 (TR-9)** `TranscriptionManager.awaitValue` deadline via continuation race (not `withTaskGroup`).
- [ ] **T13 (TR-17)** Sidecar writers never truncate an existing file.
- [ ] **T14 (H2)** Session Save: `moveItem` (fallback copy across volumes) off the main actor.

## Acceptance
`swift build` green after each task; touched suites green; no new failures vs plan-017 baseline; checkbox ticked + finding noted in the Issues register at the end of the wave.
