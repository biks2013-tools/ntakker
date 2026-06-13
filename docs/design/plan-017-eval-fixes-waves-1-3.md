# plan-017 — Evaluation fixes, waves 1–3 (data loss · resilience · hot-path performance)

**Specification source (authoritative):**
- `docs/reference/evaluation-2026-06-12-summary.md` (suggested attack order, items 1–3)
- Detail reports: `evaluation-2026-06-12-capture-pipeline.md` (C*), `evaluation-2026-06-12-transcription.md` (F*), `evaluation-2026-06-12-ui.md` (H*/M*/L*), `evaluation-2026-06-12-cli-convo-coach.md` (A*/B*)
- Registered as `EVAL-2026-06-12` in `Issues - Pending Items.md`.

**Baseline (commit `e4cd174`) pre-existing test failures — VERIFIED 2026-06-13 by running the baseline with this plan's changes stashed.** `swift build` green. **This plan adds ZERO new failures**: every failure observed with the changes applied reproduces identically on the clean baseline. The pre-existing set (each in a file this plan does not modify, or a test-harness bug):
- `GeminiRESTTranscriptionProvider` — **5** (test-harness bug: the test sets the stub `handler` then calls `makeProvider()`, whose `reset()` nils it before `transcribe` → "GeminiRESTStubProtocol error -1"; plus `URL contains … key` asserting key-in-URL). The F13 change (key→`x-goog-api-key` header + retry + 30 s timeout) does NOT affect these — identical pre/post.
- `SessionCoordinatorTranscriptionIntegration` — **3** (`partNN` asserts a name without the `.transcript.` infix `SidecarPathBuilder` always adds; `gemini-live` expects the pre-canonicalization id; mic-source config conflict). Those files are untouched here.
- `ConfigResolver — live transcription` — **1** (mic-source config conflict). `ConfigResolver.swift` untouched.
- `SonioxConfigBuilderTests.testDefaultsMatchNtakkerV1Policy` — **1** (asserts `enableSpeakerDiarization == false`; project default is now on — stale "v1 policy" test; `SonioxConfigBuilder.swift` untouched).
- `AppleSpeechSessionReconciliation.higher-confidence final wins per utterance` — **1** (winner-selection logic; fails identically on baseline — F20's forwarder-await does not touch winner selection).
- `StreamingTranscriptionPipelineTests.partialDispatchOrdering` — **1** (TCC/Speech-permission-dependent per its own caveat).
- `HostClockAlignerStress` — **2** (gap-fill count expectations; the reason T17/C1 is deferred).

No task below may add a NEW failure beyond this baseline. (The two Soniox tests this plan momentarily broke during F9 — `SonioxIntegrationTests.testTransportReceiveErrorIsNonFatalThroughPipeline` and `SonioxStreamingSessionTests.testFinishDrainsPendingNonFinalAsFinal` — were fixed within F9 and now pass; see the F9 note below.)

**Note on F9 (T8):** the receive-loop fix makes a mid-session transport drop *reconnect* (when a `transportFactory` is present — always true via the provider) rather than emit a per-chunk error. To keep operator visibility (and satisfy `SonioxIntegrationTests.testTransportReceiveErrorIsNonFatalThroughPipeline`), a SINGLE transient `.error(detail: "… — reconnecting")` is emitted per drop (mirrors Azure realtime), not per chunk.

**Execution rules:** one task at a time; `swift build` + targeted tests after each task; commit after each task (standing user authorization for plan execution). convo-coach tasks use `npm` build/tests inside `tools/convo-coach/`.

---

## Wave 1 — Data-loss fixes (small, surgical)

- [x] **T1 (F24)** Sidecar rotation in `--transcribe-source both` corrupts both sidecars after `split()`.
  Files: `Sources/NtakkerCore/Transcription/TranscriptionManager.swift` (`rotateSidecar`), `StreamingTranscriptionPipeline.swift` (`rotateSidecar`), `SourceSplitTranscriptionManager.swift`.
  Fix: managers already know their source; thread the `sidecarSourceTag` into `SidecarPathBuilder.sidecarURL(...)` on rotation so each child opens its tagged path. Guard writer creation against truncating an existing file.
  Verify: new unit test — rotate in both-mode produces two distinct tagged paths.

- [x] **T2 (C4)** `[weak dispatcher]` in the live tap drops final frames.
  File: `Sources/NtakkerCore/RecordingSession.swift` (~1294–1324). Fix: strong capture (session owns dispatcher lifetime through stop()).

- [x] **T3 (F21)** Apple Cloud `forceFinishIfStillOpen()` cuts off the in-flight final.
  File: `Providers/AppleCloudTranscriptionProvider.swift`. Fix: only force-finish when no recognition task is still in flight; let the result handler close the stream otherwise.

- [x] **T4 (F20)** `AppleSpeechSession.finish()` doesn't await result-forwarding tasks → late finals dropped.
  File: `Providers/AppleSpeechTranscriptionProvider.swift`. Fix: store forwarding tasks; await them after `finalizeAndFinish()` before reconciling/finishing.

- [x] **T5 (F19)** Streaming session attached after `stop()` leaks (WebSocket/keepalive/SFSpeech task).
  File: `StreamingTranscriptionPipeline.swift`. Fix: `attach` guards on `stopped` and finishes the late session; `stop()` cancels pending open tasks.

- [x] **T6 (F18)** `TranscriptionManager.stop()` drain deadline not enforced; sidecar close can be skipped.
  File: `TranscriptionManager.swift` (~264–287). Fix: race final-drain provider calls and `await t.value` against the remaining deadline; cancel past deadline; always close sidecar + finish events continuation.

- [x] **T7 (H1)** Double-click Start races two live sessions.
  File: `Sources/NtakkerUIKit/RecordingController.swift` (`start()`). Fix: synchronous `.starting` state transition (or pending gate) before spawning tasks; clear on failure.

## Wave 2 — Resilience

- [x] **T8 (F9)** Soniox: dead transport → per-chunk error spam, transcription dead; no reconnect.
  File: `Live/Soniox/SonioxStreamingSession.swift` (+ provider for transport factory injection).
  Fix: (a) on receive-loop failure call `terminate()` so exactly one terminal error surfaces; (b) reconnect-with-replay: inject transport factory, keep bounded PCM ring (~5 s), up to 3 attempts with backoff, re-send config, replay ring.

- [x] **T9 (F10)** Azure realtime: replay/live audio sent before session reconfigured after reconnect.
  File: `Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift`. Fix: gate audio sends behind configured state; buffer until `session.created` + config sent, then flush replay + resume. Also add `isReconnecting` latch (F11) since the same code path is touched.

- [x] **T10 (F15)** Batch pipeline circuit breaker.
  File: `TranscriptionManager.swift` (`runProviderCall`). Fix: after N (5) consecutive failures pause provider calls 60 s, emit one degraded event; trip permanently on missing/invalid-key class errors.

- [x] **T11 (F13)** Gemini: no retry, no timeout, API key in URL query.
  File: `Providers/GeminiRESTTranscriptionProvider.swift`. Fix: `timeoutInterval = 30`, retry on 429/5xx/transient URLError (mirror Azure batch policy), move key to `x-goog-api-key` header.

- [x] **T12 (B3)** convo-coach: one transient provider error kills the live session.
  Files: `tools/convo-coach/src/index.ts` (stdin loop), `src/output/stream.ts` (preserve status/class on ProviderError).
  Fix: per-trigger catch — log, footer, continue; exit only on ConfigError/UsageError or N consecutive failures; bounded backoff for 429/5xx/network.

## Wave 3 — Hot-path performance

- [ ] **T13 (H3+H4)** Remove `LEVELMETER_RT` instrumentation (racy static counters on audio queues, warning-level hot-path logs); downgrade per-event transcript logs to `.trace`/`.debug`.
  Files: `Sources/NtakkerUIKit/LevelMeterTap.swift`, `RecordingController.swift`, `SessionCoordinator.swift`.

- [ ] **T14 (F32+F4)** One vDSP-backed `PCMConvert` utility (Float32↔Int16, single documented convention); replace the 5 scalar implementations; eliminate the Int16→Float→Int16 round-trip in `TranscriptionManager.ingestFrame`.
  Files: `TranscriptionManager.swift`, `Live/Soniox/SonioxStreamingSession.swift`, `Providers/SpeechAnalyzerAdapter.swift`, `AudioWAVEncoder.swift`, `Providers/AppleCloudTranscriptionProvider.swift`, new `Transcription/PCMConvert.swift`.

- [x] **T15 (C2)** `SoftwareAECProcessor`: reuse the output scratch buffer (move-out/move-back so it stays uniquely referenced → in-place writes, no per-buffer 2-D allocation). C8 done via vDSP strided gather (`vDSP_vadd` into a zeroed channel) — `cblas_scopy` avoided (deprecated on macOS 13.3+ without a build flag).
  File: `Sources/NtakkerCore/Capture/SoftwareAECProcessor.swift`. ✅ build + `SoftwareAECProcessor` suite green.

- [x] **T16 (C3)** `BufferSummer`: sum + clamp in place into `srcA` over the whole payload in one vDSP pass — drops the third (`out`) allocation and the per-channel loop. Full scratch-pooling deferred (stateless enum called from multiple queues → needs a caller-owned-buffer API; noted in code + Issues).
  File: `Sources/NtakkerCore/Mixing/BufferSummer.swift`. ✅ build + `BufferSummer`/`M4ARecorder` suites green.

- [ ] **T17 (C1) — DEFERRED.** `HostClockAligner` per-ingest full-buffer rebuild (`appendSamples`, O(n)/ingest) + per-emission slicing → ring buffers.
  **Rationale for deferral:** highest-risk component in the project (a bug corrupts the A/V alignment of *every* recording); 2 pre-existing failing stress tests (`HostClockAlignerStress` gap-fill counts) mean there is NO green regression baseline and the plan's "must not regress further" bar is unverifiable. Correct sequence: investigate + fix the pre-existing gap-fill test failures FIRST (establish green baseline), THEN do the ring-buffer rewrite under that safety net. Pure performance optimization — not worth shipping without verification.

- [~] **T18 (F1) — PARTIAL (one of two reorder seams fixed).** Ordered audio fan-out.
  **Done during T6 validation:** the F18 `stop()` restructuring exposed a pre-existing race — `TranscriptionManager.ingest` was fire-and-forget (`Task { await buf.append }`), so (a) the LAST ingest before `stop()` could be drained away before it was buffered (final samples silently lost) and (b) concurrent ingests raced on the `SourceBuffer` actor. Fixed by making `ingest`/`ingestFrame` `async` and awaiting `buf.append` / `streamingPipeline.ingest` inline (the protocol already declared them `async`). This removes the **inner** F1 reorder seam — the manager now submits appends to `SourceBuffer` in FIFO call order — and makes `TranscriptionManagerTests.ingestProducesSegment` deterministic (was 1/5, now 8/8). `TranscriptionManager.swift:207-243`.
  **Still DEFERRED — the outer seam:** the tap (`RecordingSession.swift:1294-1324`) still spawns one `Task { await dispatcher.ingestFrame(...) }` per frame, so adjacent frames can still reach the dispatcher out of order under scheduler contention. Converting that to one `AsyncStream`-fed serial consumer per source needs careful teardown (finish continuations + await consumers BEFORE `dispatcher.stop()`, preserving the C4 final-frame guarantee) and a new ordering test. Warrants dedicated focus.

---

## Acceptance

- `swift build` green after every task; full `swift test` at the end of each wave with no NEW failures vs baseline.
- convo-coach: `npm run build` (tsc) green + existing tests pass after T12.
- Each completed task: commit referencing the finding IDs; tick the checkbox here; move the corresponding finding toward resolution in `Issues - Pending Items.md` at wave boundaries.
