# plan-019: EVAL-2026-10-16 leftovers and doc drift

Source: `docs/reference/evaluation-2026-10-16-quality-performance.md`, §4 item 1 (quick fixes not in plan-018) and §5 "Doc drift".
Follows: `plan-018-eval-2026-10-16-quick-fixes.md`.
Approved: 2026-10-16 ("yes please"); one commit per task.

## Tasks

- [x] **T1 (UI-4)** `SessionCoordinator.events` uses `.bufferingNewest(16)` and carries state, segment, error and transcript events together. A burst of transcript events can drop a `.stateChanged(.recording)` and leave the controller in `.starting`. Switch the stream to `.unbounded`; the controller drains it continuously on the main actor and every event is small. Add a regression test that emits a state change followed by more than 16 transcript events before consuming.
- [x] **T2 (INF-3)** Verify whether `timeoutIntervalForResource = 300` kills the Soniox WebSocket at 5 minutes. Fix only if it reproduces.
  - Result: not reproduced. `test_scripts/ws-resource-timeout-probe.swift` keeps an upgraded socket open well past a 3 s resource timeout, with continuous traffic and with a 6 s idle gap. No code change.
- [x] **T3 (F17)** `SonioxStreamingSession.finish()` sleeps the full 2 s grace period on every stop. Wait for the server's `{"finished": true}` frame (or the end of the inbound stream), with the grace period as the cap. Add a test that `finish()` returns well before the cap once `finished` arrives.
- [ ] **T4 (doc drift)**
  - CLAUDE.md and `docs/tools/convo-coach.md` say "Vercel AI SDK"; the implementation is LangChain (`@langchain/*`).
  - CLAUDE.md says the popover exposes pause / resume / split; those controls exist in `ControlBar` but are not reachable (UI-2).
  - plan-017 T13 / T14 are unticked although the code landed (T14's F4 round-trip is still open per the evaluation).
  - Commit only these hunks of CLAUDE.md, never the user's uncommitted edits.

## Verification

- `swift build` clean.
- New tests pass; full suite run with `--skip NtakkerCoreTests.RecordingSessionTests` shows no failures beyond the plan-018 baseline list.
