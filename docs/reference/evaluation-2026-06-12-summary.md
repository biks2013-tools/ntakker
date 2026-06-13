# ntakker — Application Evaluation: Functionality, Performance, Weaknesses (2026-06-12)

**Request:** "check and evaluate the application in terms of functionality and performance, and identify possible improvements and existing weaknesses, so that it becomes faster and more efficient."
**Commit reviewed:** `e4cd174` (master, clean).
**Method:** full-source review by four parallel analysis passes (capture pipeline, transcription subsystem, UI layer, CLI/infrastructure + convo-coach), plus a build and test-suite run.

**Detailed reports (full findings with code excerpts):**
- [evaluation-2026-06-12-capture-pipeline.md](evaluation-2026-06-12-capture-pipeline.md) — 9 findings (C1–C9)
- [evaluation-2026-06-12-transcription.md](evaluation-2026-06-12-transcription.md) — 34 findings (F1–F34)
- [evaluation-2026-06-12-ui.md](evaluation-2026-06-12-ui.md) — 24 findings (H1–H4, M1–M10, L1–L10)
- [evaluation-2026-06-12-cli-convo-coach.md](evaluation-2026-06-12-cli-convo-coach.md) — 27 findings (A1–A14, B1–B13)

---

## Overall assessment

The architecture is sound: clean protocol seams around providers and sessions, consistent actor isolation, an exemplary typed error surface with locked remediation text, recording-integrity isolation (transcription failures never kill the recording), and a correct PTS-anchored dual-capture design. The weaknesses are concentrated in four themes:

1. **Data-loss edge cases** — the most serious category. Several paths silently lose audio or transcript text (sidecar truncation after split in `both` mode, final-frame drops at stop, on-device model cold-start swallowing the first seconds/minutes, force-finish racing the last utterance).
2. **Hot-path efficiency** — the real-time audio path allocates megabytes per second of transient arrays (aligner, AEC, mixer), converts PCM Float↔Int16 up to three times per chunk without vDSP, and carries leftover always-on debug logging at warning level. None of this breaks recordings today, but it is the primary "make it faster/more efficient" surface.
3. **Network-session resilience** — Soniox has no reconnect (a blip kills transcription for the rest of the recording), Gemini has no retry/timeout, the batch pipeline has no circuit breaker, and Azure realtime's reconnect replays audio before the session is reconfigured.
4. **Lifecycle/teardown gaps** — stop() drain deadlines not actually enforced, streaming sessions that finish opening after stop() leak WebSockets/timers forever, fork()-after-concurrency-runtime in the daemonizer, no log rotation.

## Build & test health

- `swift build` (debug): **green** (5.4 s incremental).
- `swift test`: result recorded in `Issues - Pending Items.md` entry for this evaluation (run executed 2026-06-12 as part of this review).

## Top-priority findings (fix-first list)

| Rank | ID | Subsystem | Finding | Impact |
|------|----|-----------|---------|--------|
| 1 | F24 | Transcription | `rotateSidecar` in `--transcribe-source both` points both children at the SAME untagged file; `createFile` truncates → every post-split transcript corrupted/lost | Data loss; small fix |
| 2 | F19 | Transcription | Streaming session attached after `stop()` leaks WebSocket + keepalive / SFSpeech task forever (billable Soniox session) | Resource leak, cost |
| 3 | F18 | Transcription | `TranscriptionManager.stop()` "bounded" drain is unbounded (awaits hung HTTP calls; sidecar close may never run) | Hang on stop |
| 4 | C4 | Capture | `[weak dispatcher]` in live tap drops the final ~100–200 ms of transcript audio | Data loss (last words) |
| 5 | F28 | Transcription | Lazy WhisperKit/Parakeet model load discards the first seconds–minutes of cold-start recordings (in-flight slots blocked + SourceBuffer 50% drops) | Data loss, UX |
| 6 | F9 | Transcription | Soniox: no reconnect; dead transport → error per chunk forever, transcription dead for rest of session | Resilience |
| 7 | F10 | Transcription | Azure realtime reconnect replays audio before `transcription_session.update` is configured | Data loss on reconnect |
| 8 | H1 | UI | Double-click Start races two live sessions; the orphaned one is unstoppable and keeps writing | Correctness |
| 9 | H2 | UI | Session Save copies/deletes audio files + parses JSONL synchronously on the main actor | UI freeze/beachball |
| 10 | A1 | CLI | `fork()` after the Swift Concurrency runtime started (async `main`) — Daemonizer's own precondition violated; rare post-fork hangs | Daemon stability |
| 11 | B1 | convo-coach | Stdin live mode: unbounded buffer + O(n²) full re-parse per trigger | Perf, memory |
| 12 | B2 | convo-coach | Default provider (azure-openai) keyed by deployment name → 8k-token unknown-model fallback → silent aggressive truncation | Quality on default path |
| 13 | H3/H4 | UI | Data races on static diag counters on audio queues + leftover `LEVELMETER_RT` warning-level logging in 30 Hz/per-buffer/per-partial hot paths | UB + log spam |
| 14 | A2/A4 | CLI | `stop` SIGTERMs unverified PID (PID-reuse hazard); PID-file claim is TOCTOU-racy | Safety |
| 15 | B3 | convo-coach | One transient provider error kills the live coaching session; no retries anywhere | Availability |

## Highest-leverage performance improvements (speed/efficiency theme)

1. **Eliminate hot-path allocations** (C1 aligner ring buffers, C2 AEC scratch reuse, C3 mixer scratch pool) — multi-MB/sec of transient allocations removed from the real-time path.
2. **Single PCM conversion with vDSP** (F4 + F32): convert Float↔Int16 once at the wire boundary via one shared `PCMConvert` utility instead of 3× scalar loops per chunk in 5 implementations with 3 scaling conventions.
3. **Remove leftover debug instrumentation** (H3/H4): per-buffer locks, per-event `String(describing:)` at `.info`/`.warning`, fresh `Logger` per emission on audio threads.
4. **Stop publishing levels at 30 Hz when nothing changed / popover closed** (M1/M2) and make the transcript list lazy (M3) — main-actor churn during every recording.
5. **Async batched file logging** (A6) and log rotation (A7).
6. **Ordered single-consumer audio fan-out** (F1): replaces ~10–20 unstructured Tasks/sec/source with one AsyncStream consumer per source — fixes a latent reordering correctness bug *and* reduces scheduling overhead.
7. **convo-coach incremental parsing + token-count caching** (B1, B5) and fd-based sidecar appends (B4).
8. **Faster stop:** F17 (Soniox unconditional 2 s grace sleep), F18 (drain deadline), M8 (.env parsed ~8× per Start click on the main actor).

## Cross-cutting refactors that pay for themselves

- **Shared HTTP retry policy** (F31) — currently duplicated in Azure batch + ElevenLabs, absent in Gemini.
- **Shared byte-range rewriting file writer** (F33) — tombstone machinery duplicated across 4 sidecar format writers.
- **One provider→env-key table** shared by `RecordingStarter` and `RecordingController.setOptions` (L10) — missing-key badge currently only works for Gemini.
- **Unify the two divergent `.env` parsers** (A9) — quoted values currently resolve differently in CLI vs UI.

## Functional gaps / correctness notes (non-performance)

- Source-split merged event stream emits colliding segment indices (F22) — UI rows can overwrite the wrong row in `both` mode.
- `totalElapsed` counts ticks, not time — visible clock drift on long sessions and wrong Q&A anchors (M4).
- Quit "Stop & Quit" has no watchdog — a stalled finalize makes the app unquittable (M5); `cancelAll()` is never called (M6).
- Fresh installs can never see the screen-recording permission prompt from `start` (A5).
- `stop` runs full config validation — an unrelated config error makes a daemon unstoppable (A3).
- convo-coach help text contradicts implementation (B9); SIGINT exits as PROVIDER_FAILURE (B6); no lockfile committed (B13).
- Project doc drift: CLAUDE.md says convo-coach uses "Vercel AI SDK"; the implementation is LangChain (B13).

## Suggested attack order

1. **Data-loss fixes (small, surgical):** F24, C4, F21, F20 → then F19 + F18 (teardown), H1 (start race).
2. **Resilience:** F9 (Soniox reconnect via the Azure pattern), F10, F15 (circuit breaker), F13 (Gemini retry/timeout/header key), B3 (coach retry loop).
3. **Performance wave 1 (hot path):** C1–C3, F4+F32, H3/H4 removal, F1 ordered fan-out.
4. **Performance wave 2 (UX-perceived):** H2 off-main-actor save, M1–M3, M8, F17, A6/A7.
5. **convo-coach:** B1, B2, B4, B5, B7.
6. **Hygiene:** A1 (re-exec daemonization), A2/A4 (PID identity + O_EXCL), A9, L10, B13 lockfile, doc fixes.
