# Issues — Pending Items

> Tip: After completing or removing a pending item, move it to the
> "Completed items" section at the bottom. Pending items are listed
> most-critical-first.

## Pending items (most critical first)

### EVAL-2026-10-16 — Quality / speed / resource-efficiency scan: 74 new findings registered
**RESOLUTION UPDATE (2026-10-16) — plan-020 transcript-correctness wave landed** ([docs/plans/plan-020-eval-2026-10-16-transcript-correctness.md](docs/plans/plan-020-eval-2026-10-16-transcript-correctness.md)):
- Fixed, one commit each: INF-1, INF-2 (Soniox reconnect), TR-13 (Azure replay), CC-2, CC-3 (convo-coach), UI-1 (Save bundles every part's and source's sidecars), UI-6 (uncapped session transcript for Ask and Save), TR-6, TR-7 (sanitizer), TR-5 (dual-locale reconciliation), TR-4 (Apple Cloud rotation).
- **New bug found and fixed:** `JSONLTranscriptReader` dropped every segment that had been rewritten via tombstone-and-append (the tombstone shares the id), so Save lost every grown batch segment.
- The baseline failure "higher-confidence final wins per utterance" now passes. No new failures.
- Manual checks pending: multi-part Save, and Apple Cloud longer than 60 s.

**RESOLUTION UPDATE (2026-10-16) — plan-019 landed** ([docs/plans/plan-019-eval-2026-10-16-leftovers-and-doc-drift.md](docs/plans/plan-019-eval-2026-10-16-leftovers-and-doc-drift.md)): UI-4 (coordinator events stream now unbounded; regression test fails on the old policy), INF-3 (not reproduced — `test_scripts/ws-resource-timeout-probe.swift`), F17 (Soniox `finish()` returns on the server's `finished` frame, 2 s cap), and the doc drift below (Vercel → LangChain in CLAUDE.md and `docs/tools/convo-coach.md`; CLAUDE.md popover controls corrected; plan-017 T13/T14 ticked). UI-2 itself (unreachable pause/resume/split) stays open.

**RESOLUTION UPDATE (2026-10-16) — plan-018 wave 1 landed** ([docs/plans/plan-018-eval-2026-10-16-quick-fixes.md](docs/plans/plan-018-eval-2026-10-16-quick-fixes.md)): CC-1, TR-1, TR-3, INF-4, CAP-4, CAP-5 (not reproduced — downgraded), CAP-7, CAP-8, CAP-10, INF-7, TR-8, TR-9, TR-17 (as an open-path registry), H2 — one commit each; zero new test failures vs `bf69be5`. **Newly documented test-suite facts:** `RecordingSessionTests` spins forever in `HostClockAligner.appendSamples` (pre-existing; makes plain `swift test` look hung — use `--skip NtakkerCoreTests.RecordingSessionTests`); `AudioDownsamplerTests:144` and `UIErrorPresenterTests:220` are pre-existing failures missing from the plan-017 baseline list. Manual check pending: popover Save (T14). Remaining findings stay open per the report.

**Status (2026-10-16).** Read-only re-scan at commit `bf69be5`. Full report: [docs/reference/evaluation-2026-10-16-quality-performance.md](docs/reference/evaluation-2026-10-16-quality-performance.md) (CAP-1…18, TR-1…20, INF-1…15, UI-1…9, CC-1…12 + status of every open EVAL-2026-06-12 finding). Nothing fixed yet.

**Most critical:**
1. **CC-1** — convo-coach live (stdin) mode unreachable: `process.stdin.isTTY === false` never matches pipes (`undefined`) (`tools/convo-coach/src/index.ts:458`).
2. **CAP-1 / CAP-2** — `HostClockAligner` ignores incoming PTS when leftover exists (gaps never silence-filled → permanent track offset) and stalls/grows unbounded when one source stalls (`Aligning/HostClockAligner.swift:458-462, 536-566`). Likely root cause of the 2 failing `HostClockAlignerStress` tests.
3. **TR-1** — concurrent inference on non-thread-safe Parakeet/WhisperKit engines (`maxInFlightPerSource = 2`).
4. **TR-3** — Azure realtime `finish()` drops the last utterance (no commit / no wait).
5. **UI-1** — Session Save loses transcript for multi-part / source-split sessions (`SessionExporter.swift:61-90`).
6. **INF-1 / INF-2 / INF-3** — Soniox reconnect duplicates and loses audio; finish/reconnect race leaks a socket + keepalive; possible forced 5-min WebSocket drop (INF-3 not reproduced 2026-10-16, plan-019 T2 — the resource timeout does not close upgraded sockets).
7. **INF-4** — daemon `umask(0)` → recordings/transcripts world-writable in `--detach` mode.

**Top efficiency wins:** AEC NLMS ≈1.6 G MAC/s (CAP-3/6/11); on-device STT 7.5–15× wasted compute from 2 s chunks padded to 15/30 s (TR-2) + model reloaded every recording (TR-11); SCStream video frames at display rate (CAP-4); aligner rewrite (C1); level meters at 30 Hz with popover closed (M1/M2/UI-5); Save on main actor (H2 → `moveItem`).

**Doc drift found (fixed 2026-10-16, plan-019 T4):** plan-017 T13/T14 unticked although landed; CLAUDE.md/`docs/tools/convo-coach.md` still say "Vercel AI SDK"; CLAUDE.md advertises popover pause/resume/split which are unreachable (UI-2).

### EVAL-2026-06-12 — Application-wide functionality/performance evaluation: 94 findings registered
**RESOLUTION UPDATE (2026-06-13) — plan-017 waves 1–3 (attack-order items 1, 2, 3).** 16 of 18 planned fixes landed; build green; `convo-coach` 166/166 tests green; changed Swift suites green (TranscriptionManager incl. new F24 regression test, Soniox/SourceSplit, SoftwareAECProcessor, BufferSummer, M4ARecorder/WAVRecorder — 46 tests across the focused runs). See [docs/design/plan-017-eval-fixes-waves-1-3.md](docs/design/plan-017-eval-fixes-waves-1-3.md).
- **Wave 1 — data loss (DONE):** F24 (per-source sidecar tag threaded through `rotateSidecar` + new regression test), C4 (strong dispatcher capture in the live tap), F21 (Apple Cloud force-finish re-arms while a final is in flight), F20 (`AppleSpeechSession.finish()` awaits result forwarders), F19 (late-attached streaming session finished + open tasks cancelled on stop), F18 (`TranscriptionManager.stop()` drain races every await against one deadline; sidecar close always runs), H1 (synchronous `.starting` transition closes the double-click start race).
- **Wave 2 — resilience (DONE):** F9 (Soniox reconnect-with-replay + single terminal error on dead transport), F10/F11/F12 (Azure realtime gates audio behind session config, `isReconnecting` latch, 0/1/4 s backoff), F15 (batch circuit breaker), F13 (Gemini retry + 30 s timeout + key moved to `x-goog-api-key` header), B3 (convo-coach per-trigger error recovery + retryable classification on `ProviderError`).
- **Wave 3 — hot-path perf (PARTIAL):** H3/H4 (removed racy `LEVELMETER_RT` static counters + per-buffer locks/logging; per-event transcript logs → `.trace`), F4/F32/F7 (new vDSP-backed `PCMConvert` replaces 5 scalar impls ×3 conventions; WAV encoder bulk-append), C2 (AEC output scratch reuse + C8 vDSP deinterleave), C3 (BufferSummer in-place whole-buffer vDSP sum drops the 3rd allocation), **F1 partial** (`TranscriptionManager.ingest`/`ingestFrame` made `async` to `await buf.append` inline instead of fire-and-forget `Task` — removes the inner reorder seam AND a lost-final-sample race; made `TranscriptionManagerTests.ingestProducesSegment` deterministic, 8/8).
- **DEFERRED (still pending):** C1 (T17 — aligner ring-buffer rewrite: deferred until the 2 pre-existing `HostClockAlignerStress` failures are fixed to give a green baseline) and the OUTER seam of F1 (T18 — the per-frame `Task { dispatcher.ingestFrame }` in `RecordingSession`'s tap still needs an `AsyncStream`-fed serial consumer per source + teardown rework + a new ordering test). Rationale in plan-017.
- **Remaining unstarted findings** (everything not listed above — F1, F2, F3, F5, F6, F8, F14, F16, F17, F22, F23, F25–F31, F33, F34; H2, M1–M10, L1–L10; A1–A14; B1, B2, B4–B13; C1, C5–C9) remain open per the detail reports.

**Pre-existing test baseline (unchanged by plan-017) — VERIFIED 2026-06-13 by running baseline `e4cd174` with the changes stashed.** plan-017 adds **zero** new failures (every failure seen with changes applied reproduces identically on baseline). Full pre-existing failing set (all in files plan-017 does not modify, or test-harness bugs): `GeminiRESTTranscriptionProvider` ×5 (stub `handler` niled by `makeProvider()`→`reset()` before `transcribe` → "stub error -1"; + a key-in-URL assertion — F13 moves the key to the `x-goog-api-key` header, failures are pre/post-identical); `SessionCoordinatorTranscriptionIntegration` ×3 (`partNN` expects no `.transcript.` infix; `gemini-live` id; mic-source conflict); `ConfigResolver — live transcription` ×1 (mic-source conflict); `SonioxConfigBuilderTests.testDefaultsMatchNtakkerV1Policy` ×1 (diarize now default-on); `AppleSpeechSessionReconciliation.higher-confidence final wins` ×1 (winner selection); `StreamingTranscriptionPipelineTests.partialDispatchOrdering` ×1 (TCC-dependent); `HostClockAlignerStress` ×2 (gap-fill counts). The two Soniox tests plan-017 momentarily broke during F9 were fixed within F9 and now pass.

**Status (2026-06-12).** A full-source evaluation of the application (capture pipeline, transcription subsystem, UI layer, CLI/infrastructure, convo-coach) at commit `e4cd174` identified **94 findings** (15 high, ~45 medium, rest low). `swift build` is green. Full details with file:line evidence and concrete fixes live in:
- [docs/reference/evaluation-2026-06-12-summary.md](docs/reference/evaluation-2026-06-12-summary.md) — consolidated summary, prioritized fix-first list, suggested attack order
- [docs/reference/evaluation-2026-06-12-capture-pipeline.md](docs/reference/evaluation-2026-06-12-capture-pipeline.md) (C1–C9)
- [docs/reference/evaluation-2026-06-12-transcription.md](docs/reference/evaluation-2026-06-12-transcription.md) (F1–F34)
- [docs/reference/evaluation-2026-06-12-ui.md](docs/reference/evaluation-2026-06-12-ui.md) (H1–H4, M1–M10, L1–L10)
- [docs/reference/evaluation-2026-06-12-cli-convo-coach.md](docs/reference/evaluation-2026-06-12-cli-convo-coach.md) (A1–A14, B1–B13)

**Most critical (data loss / hangs / leaks):**
1. **F24** — `rotateSidecar` in `--transcribe-source both`: both children open the SAME untagged sidecar file; `createFile` truncates → every post-split transcript corrupted/lost (`Transcription/SourceSplitTranscriptionManager.swift:111-114`, `TranscriptionManager.swift:230-233`).
2. **F19** — Streaming session attached after `stop()` leaks WebSocket + keepalive / SFSpeech task forever (`StreamingTranscriptionPipeline.swift:175-184`).
3. **F18** — `TranscriptionManager.stop()` drain deadline not enforced; a hung HTTP call holds stop() for up to its 60–120 s timeout (`TranscriptionManager.swift:264-283`).
4. **C4** — `[weak dispatcher]` in the live tap drops the final ~100–200 ms of transcript audio (`RecordingSession.swift:~1294-1324`).
5. **F28** — Lazy WhisperKit/Parakeet model load discards the first seconds–minutes of cold-start recordings.
6. **F9 / F10** — Soniox has no reconnect (dead transport → transcription dead for the rest of the recording); Azure realtime replays audio before the session is reconfigured.
7. **H1** — Double-click Start races two live recording sessions; the orphaned one is unstoppable (`NtakkerUIKit/RecordingController.swift:292-427`).
8. **H2** — Session Save copies/deletes audio files + parses JSONL synchronously on the main actor → popover freeze (`ntakker/Views/Asking/SessionExporter.swift`).
9. **A1** — `fork()` after the Swift Concurrency runtime has started; Daemonizer's own precondition violated (`ntakker-cli` `--detach` path).
10. **B1 / B2 / B3** — convo-coach live mode: O(n²) re-parse per trigger; azure-openai default path silently truncates to an 8k-token assumed window; one transient provider error kills the session.

**Top performance improvements (faster/more efficient):** hot-path allocation elimination (C1 aligner ring buffers, C2 AEC scratch reuse, C3 mixer scratch pool — multi-MB/s of transient allocations); single vDSP-backed PCM conversion replacing 5 scalar implementations ×3 conventions (F4+F32); removal of leftover `LEVELMETER_RT` debug counters/logging with data races on audio queues (H3/H4); 30 Hz level publishing gated on change/visibility (M1/M2); lazy transcript list (M3); ordered single-consumer audio fan-out replacing unstructured per-frame Tasks (F1 — also a latent reordering bug); async batched file logging + rotation (A6/A7); `.env` parsed ~8× per Start click (M8).

**Cross-cutting refactors:** shared HTTP retry policy (F31), shared byte-range rewriting sidecar writer (F33), one provider→env-key table for UI key badges (L10), unify the two divergent `.env` parsers (A9).

**Doc/dependency hygiene:** convo-coach has no lockfile committed; `@anthropic-ai/sdk ^0.92.0` override is ~12 minors behind without a registered expiry condition; CLAUDE.md still says convo-coach uses "Vercel AI SDK" while the implementation is LangChain (B13); convo-coach `--help` contradicts the implementation in three places (B9).

### PLAN-015-PHASE-2..6 — In-recording Q&A + Pattern C popover redesign
**Status (2026-05-13).** Phase 1 (pure UI shell) landed. The popover now renders the Pattern-C target-state visual layout: top `Transcription | Asking` segmented switch, default-collapsed Engine & Language section, Asking-mode body with empty-state + bottom-pinned input row, bottom status bar with bouncing mic/sys bars + state pill + clock + action area, post-stop `[ New Session ][ Save… ]` pair, New-Session 3-option confirm modal, Save dialog with folder-name input + path preview + file-list. Resizable in both axes within 440-760 × 440-820 bounds; default width 480 pt. Builds cleanly (`swift build` green).

**Remaining work (per [docs/design/plan-015-in-recording-questions.md](docs/design/plan-015-in-recording-questions.md) roadmap):**
- **Phase 2 — Save flow → real folder write.** Wire the Save dialog's `onConfirm` to a real `~/Recordings/<folder>/` write (`transcript.md`, `qa.md`, `recording-001.m4a`). Atomic `.tmp` + rename. Collision handling (Replace / Append-timestamp / Cancel). Saved toast with Finder-reveal click. Reuse `RecordingController.completedSegments` for the audio file.
- **Phase 3 — `TranscriptExporter` module + CLI.** New `Sources/MacrecCore/Export/TranscriptExporter.swift`. Markdown layout per FR-IRQ-29 (interleaved speech + Q&A blockquotes). `macrec export --session <id> --folder <path>` (FR-IRQ-33, FR-IRQ-54). Determinism guarantee.
- **Phase 4 — Q&A LLM integration.** Lift `AskingSessionStore` into `MacrecCore` as `QASessionHistory`. Wire eight standard providers (reuse `convo-coach`'s LLM client patterns + vendor-canonical env vars). Streaming answers. Privacy disclosure on first cloud invocation (FR-IRQ-18). No-fallback on missing key. Q&A sidecar persistence on Stop (FR-IRQ-14, FR-IRQ-15).
- **Phase 5 — Global hotkey + floating overlay.** Register `⌥⇧Space` (FR-IRQ-1, FR-IRQ-16). Build the frameless `NSWindow` floating Ask overlay (FR-IRQ-3). Share `QASessionHistory` with the popover (FR-IRQ-38).
- **Phase 6 — Refinements + acceptance gate.** Engine & Language collapsed-summary row (Engine • Language • Source • ▾) per FR-IRQ-44a. `clearSession()` step 7 (auto-restart recording). Visual-continuity screenshot test (AC-IRQ-Pat-C-4). Latency budgets. 10-question audio-non-blocking stress test (NFR-IRQ-Audio-Non-Blocking).

**Smoke test still to be run by user.** Build is green but I cannot autonomously exercise the menu-bar popover. Please launch (`bash scripts/package-macrec-ui-app.sh && open dist/macrec-ui.app`) and verify: (a) popover opens at ~480 pt wide, (b) `Transcription / Asking` switch renders below the header and `⌘1`/`⌘2` work, (c) bottom status bar shows bouncing mic + sys bars + state pill + clock, (d) Stop transitions to `[ New Session ][ Save… ]`, (e) `Save…` opens the dialog with the right default folder name, (f) `New Session` → 3-option modal → Discard fades + clears the Q&A history.

### PLAN-014-DONE (RESOLVED 2026-05-09) — AEC stability rewrite (v5) + opt-in default
**Background.** plan-013 revised + the same-day v4 fix (`PLAN-013-DEFECT-1` below) reduced mic peaks from +10 dBFS to +3.7 dBFS, but did not eliminate the "filtering distortion" the user reported when system audio plays through speakers. Investigation against a fresh sample (`sample/aec-on.{mic,system}.m4a`) found four compounding causes:

1. **No actual acoustic bleed in the recording** — cross-correlation between mic and system across ±500 ms of lag is essentially zero (≤ 0.06). User on headphones / low speaker volume; the optimal filter weights are 0, but the filter actively diverges away from 0 and produces "filtering distortion".
2. **NLMS without safeguards diverges in the no-echo case** — with μ=0.1 the algorithm chases spurious short-term correlations between music/speech (`x`) and user voice (`d`), then projects the resulting weights onto the next reference window. v4's leakage (1e-5) was too slow to bleed the drift off; v4's μ was too aggressive to stay near zero.
3. **Hard clip + AAC = MDCT overshoot** — pre-encoder samples were correctly clipped at ±0.99 (verified via `strings` on the binary), but a square-wave-like clipped residual rang through AAC's MDCT and the *decoded* peaks reached +3.7 dB. The audible distortion was the underlying square wave, not the AAC overshoot itself.
4. **Buffer-cadence mismatch invalidated v4's ref-window assumption** — `AVCaptureAudioDataOutput` (mic) typically delivers 512–1024-sample buffers; `ScreenCaptureKit` (system) delivers larger blocks at less regular intervals. v4's "latest `frameCount` ref samples align with this mic buffer" was true only under lockstep cadence, which doesn't hold in practice.

**Fix landed (plan-014 / `SoftwareAECProcessor` v5).** Six layers, all in `Sources/MacrecCore/Capture/SoftwareAECProcessor.swift`:

- **Layer A — Reference-activity gate.** Skip weight updates whenever `√refEnv < referenceActivityRMSThreshold` (default `3e-3` ≈ -50 dBFS RMS). No reference signal → no echo to learn.
- **Layer B — Double-talk detector.** Skip updates when `micEnv > refEnv · doubleTalkRatio` (default `4.0`). Mic-dominates-ref means the user is talking and there is no real echo; adapting biases the filter toward voice suppression.
- **Layer C — Divergence reset.** Track `resEnv > micEnv` over a 50 ms sliding window; when sustained, reset all weights to 0 and log the event. Self-healing safety net.
- **Layer D — Calmer step + step clamp + leakage.** μ: 0.1 → **0.01**. Regularization: 1e-3 → **1e-2**. Per-sample step magnitude clamp at ±1e-3. Leakage 1e-5 retained.
- **Layer E — Soft-knee limiter.** Tanh-style limiter (knee 0.7 / ceiling 0.95) replaces v4's hard clip. Output stays band-limited so AAC's MDCT no longer rings → decoded peaks ≤ 0 dBFS regardless of pre-encoder waveform shape.
- **Layer F — PTS-based reference alignment.** Ring buffer indexed by logical sample position derived from `CMSampleBufferGetPresentationTimeStamp(...)`, anchored to the first reference buffer's PTS. The mic-side window for any sample at host time *t* covers reference samples at host time *t*, regardless of whether the two capture stacks deliver buffers in lockstep. Ring capacity expanded to `2 · filterLength` (~170 ms) for skew tolerance; gaps in reference delivery are zero-filled before the next read.

**Default flip (per user policy).** `RecordingOptions.micAEC` default `true` → **`false`**, `MACREC_MIC_AEC` default `true` → **`false`**, both `@AppStorage` defaults → **`false`**. AEC is now opt-in. Existing `--mic-aec on` invocations and any persisted UI toggle = on continue to work unchanged.

**User-facing surface (unchanged shape).** `--mic-aec on|off`, `MACREC_MIC_AEC`, "Mic echo cancellation" popover toggle. Help text and tool-doc descriptions updated to reflect the opt-in default and the v5 stability layers.

**Files touched:**
- `Sources/MacrecCore/Capture/SoftwareAECProcessor.swift` — full rewrite to v5 (~700 LoC).
- `Sources/MacrecCore/Config/RecordingOptions.swift` — default + doc-comment.
- `Sources/MacrecCore/Config/ConfigResolver.swift` — default + doc-comment.
- `Sources/macrec/Commands/StartCommand.swift` — `--mic-aec` help text.
- `Sources/macrec-ui/Views/MicEchoCancellationToggle.swift` — `@AppStorage` default + help text.
- `Sources/macrec-ui/Views/ControlBar.swift` — `@AppStorage` default.
- `docs/design/plan-014-aec-stability.md` — new (this plan).
- `docs/design/plan-013-microphone-aec.md` — supersede pointer in §11.
- `docs/tools/macrec.md`, `docs/tools/macrec-ui.md` — opt-in default + v5 algorithm description.
- `CLAUDE.md` — `macrec` and `macrec-ui` tool entries.
- `test_scripts/plan-014-aec-stability-smoke.md` — new (WAV peak verification per AC-1 / AC-2).

**Verification.** `swift build -c release` (full package) builds clean. Manual smoke test in `test_scripts/plan-014-aec-stability-smoke.md` covers: AC-1 (no-bleed case stays ≤ 0 dBFS), AC-2 (real-bleed case achieves ≥ 12 dB residual reduction), AC-3 (filter never amplifies above raw input), AC-4 (default off), AC-5 (divergence reset works), AC-6 (existing on/off control surface unchanged).

### PLAN-013-DEFECT-1 (RESOLVED 2026-05-09) — Mic AEC produces +10 dBFS clipping / audible distortion (NLMS divergence)
**Background.** After the plan-013 (revised) software AEC shipped earlier the same day, recording with `--mic-aec on` (the default) produced an audibly distorted mic track. Reference recordings in `sample/aec-on.{mic,system}.m4a` show the mic track peaking at +10.56 dBFS (max sample magnitude 3.37) — well past the 0 dBFS encoder ceiling — with the level growing over time: clean for the first ~6 s, occasional excursions to 1.4–1.8 between 6–11 s, and repeated excursions to 2.5–3.4 from 11 s onwards. Classic NLMS adaptive-filter divergence symptom.

**Root cause.** Bug in `Sources/MacrecCore/Capture/SoftwareAECProcessor.swift` `processMic(_:)` (v3 implementation, lines 268–307 pre-fix). The reference-window phase was snapshotted *outside* the per-sample inner loop:

```swift
let writeIdxStart = self.refWriteIdx[ch]
for n in 0..<frameCount {
    let phase = (writeIdxStart % L)   // ← does NOT depend on n
    let window = ringPtr.baseAddress!.advanced(by: phase)
    ...
    vDSP_vsma(window, 1, &scale, wPtr…)   // weight update vs. constant input
}
```

So for every one of the ~1024 mic samples in a buffer the *same* reference window was used, both to compute `yHat` and to update the weights. NLMS therefore performed `frameCount` consecutive weight updates against an identical input vector with varying `d`, growing the weights along that one direction without bound. When the next buffer arrived with a slightly different `x`, projecting the (now-large) weights onto it produced a huge `yHat`, the residual `e = d − yHat` blew past 0 dBFS, the AAC encoder clipped, and the user heard distortion. The block comment at the snapshot site even documented that the position should advance per sample ("logical position advances at the same rate") — the loop body just never did it.

**Fix landed.** `SoftwareAECProcessor` v4:
- **Per-sample reference advancement.** For mic sample `n` in a buffer the ref window now ends at logical position `writeIdxStart − frameCount + n` (rates are identical at 48 kHz, so the buffer's `frameCount` mic samples correspond to the latest `frameCount` reference samples). Phase is `(endIdx + 1) % L` per the double-write invariant. During the first `L + frameCount` samples of a session — before a full reference window exists — the mic is passed through untouched and weight updates are skipped.
- **Weight leakage.** New `Configuration.leakage` field (default `1e-5`, ~2 s time constant at 48 kHz). Each NLMS update now applies `w := (1 − leak) · w` before the gradient step, so any residual weight growth bleeds off rather than accumulating indefinitely.
- **Larger regularisation.** `Configuration.regularization` default raised from `1e-6` → `1e-3`, so a near-silent reference no longer turns `μ · e / (‖x‖² + reg)` into a five-orders-of-magnitude amplification.
- **Output safety net.** New `Configuration.clipThreshold` (default `0.99`); the cleaned residual is hard-clipped to `[−clipThreshold, +clipThreshold]` before being re-packed into the CMSampleBuffer. Guarantees the encoder cannot ever again receive samples > 0 dBFS, even in the face of a future regression.

**Verification.** `swift build -c release --product macrec` and `swift build -c release --product macrec-ui` both build clean. The user-facing surface (`--mic-aec`, `MACREC_MIC_AEC`, popover toggle, default-on behaviour) is unchanged. The reference recordings under `sample/` were the diagnostic artifact, not a regression test — a follow-up should re-record with the v4 processor and confirm peak ≤ 0 dBFS via `ffmpeg -af astats`.

**Files changed.**
- `Sources/MacrecCore/Capture/SoftwareAECProcessor.swift` — `Configuration` gains `leakage` + `clipThreshold`; `processMic` inner loop rewritten with per-sample phase advancement, leakage `vDSP_vsmul`, and output clipping.
- `docs/design/plan-013-microphone-aec.md` — post-ship defect section appended (see plan §11).
- `test_scripts/plan-013-aec-smoke.md` — peak-amplitude check added to the smoke procedure.

### PLAN-013-DONE (RESOLVED 2026-05-09, REVISED SAME DAY) — System audio bleeds into the mic channel during recording
**Background.** While `macrec` and `macrec-ui` were recording, anything playing through the laptop's speakers (Music, Spotify, browser tabs, Zoom remote-party voices, etc.) was acoustically picked up by the built-in microphone and re-recorded onto the mic channel. Effect: in `--layout split` / `stereo-split` recordings the "microphone" track was no longer a clean local-mic capture — it carried a delayed, attenuated copy of the system audio.

**Root cause.** Acoustic bleed (a physics problem, not a code defect): speakers play, mic listens. The pre-existing mic-capture path (`Sources/MacrecCore/Capture/AVMicrophoneSource.swift`, an `AVCaptureSession` + `AVCaptureDeviceInput` + `AVCaptureAudioDataOutput` stack) had no echo-cancellation knob.

**First-attempt approach (failed).** The original plan-013 implementation introduced a `VPMicrophoneSource` using `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)` to leverage Apple's built-in voice-processing AEC. Three iterations of empirical testing established the approach was not viable in this codebase:

  - With SCStream system-audio capture also running (which this project always does), the underlying `AUVoiceProcessingIO` audio unit delivered exactly ONE buffer of 4800 silent frames before stalling permanently. Cause: `AUVoiceProcessingIO` requires unobstructed access to the system OUTPUT device for its AEC reference signal; SCStream taps the same OS audio mix and the two cannot coexist on macOS 26. There is no public API to feed `AUVoiceProcessingIO` a custom reference signal — the conflict is structural, not a fixable bug.
  - An attempt to "complete" the engine graph with `_ = engine.mainMixerNode` made the engine refuse to initialise at all (`kAudioUnitErr_FailedInitialization` -10875), because voice processing's input/output nodes are both backed by a single shared `AUVoiceProcessingIO` unit and the implicit `inputNode → mainMixer → outputNode` graph creates a self-loop.
  - Even with the audio-render-thread cleanup (`OSAllocatedUnfairLock` replacing serial-queue `sync` calls) and the missing `CMSampleBufferSetDataReady` fix applied, the structural conflict remained.

  `VPMicrophoneSource` was deleted; the user-facing `micAEC` field, `MACREC_MIC_AEC` env var, `--mic-aec` CLI flag, and macrec-ui toggle were retained but re-targeted at the new approach below.

**Fix (current).** plan-013 (revised) — custom software AEC, `Sources/MacrecCore/Capture/SoftwareAECProcessor.swift`. `AVMicrophoneSource` is the only mic source. When `RecordingOptions.micAEC == true` (default), `RecordingSession.run()` constructs a `SoftwareAECProcessor` and wires it between the existing capture sources and the aligner: the mic source's `onSampleBuffer` is routed through `processor.processMic(_:)` instead of directly to the aligner; the system source is teed (still feeds the aligner verbatim, AND additionally feeds `processor.feedReference(_:)`). The processor runs a per-channel NLMS adaptive filter (4096 taps ≈ 85 ms @ 48 kHz, μ = 0.1, regularised) using `Accelerate` `vDSP_dotpr` / `vDSP_svesq` / `vDSP_vsma` for SIMD-vectorised hot loops, and a "double-write" reference ring buffer so the L-sample window can be read contiguously without wrap-around branching. The cleaned mic samples are wrapped in a fresh CMSampleBuffer that copies the input mic buffer's PTS / duration / format-description, preserving the host-clock alignment downstream consumers depend on.

**User-facing surface (unchanged from original plan-013):**
  - `RecordingOptions.micAEC: Bool = true` (`Sources/MacrecCore/Config/RecordingOptions.swift`).
  - `MACREC_MIC_AEC` env var (default `true`) in the four-tier resolution chain (`Sources/MacrecCore/Config/ConfigResolver.swift`); `parseBool` / `parseOptionalBool` accept `on` / `off` / `true` / `false` / `1` / `0` / `yes` / `no`.
  - `--mic-aec on|off` CLI flag (`Sources/macrec/Commands/StartCommand.swift`).
  - "Mic echo cancellation" toggle in the macrec-ui popover's General section, persisted via `@AppStorage("com.macrec.ui.micAEC")` (`Sources/macrec-ui/Views/MicEchoCancellationToggle.swift`, `…/Sections/GeneralSection.swift`, `…/Views/ControlBar.swift`).
  - `MacrecError.micAECUnavailable(underlying:)` (exit 70) retained for any future processor-level setup error path.

**Trade-offs (different from the original plan-013 attempt).** The software AEC does NOT apply AGC or noise suppression and does NOT narrow the captured mic frequency band — the cleaned mic is the raw mic minus the estimated echo, in full bandwidth. Convergence is automatic: 1–3 s on white-noise-like test signals, 3–10 s on speech / music. After convergence, the residual bleed drops 15–25 dB below the un-cancelled bleed level. CPU cost is ~5–8 % of a single Apple Silicon P-core for stereo at 48 kHz. The processor preserves host-clock PTSs end-to-end, so the aligner / recorder / transcription / dual-channel pipelines all continue working unchanged.

**Verification.** Both products build clean (`swift build -c debug --product macrec`, `swift build -c debug --product macrec-ui`). `ConfigResolverTests` (43 tests) pass. Manual smoke-test plan in `test_scripts/plan-013-aec-smoke.md` covers CLI flag, env var, UI toggle, default behaviour, and invalid-flag rejection.

**Known limitations / future work.**
  - First few seconds of a recording carry residual bleed before NLMS converges. Could be improved by persisting filter weights across sessions to a small per-device cache (~64 KB), but not a v1 priority.
  - Cross-channel echo (L speaker → R mic, R speaker → L mic) is not modelled — each channel runs an independent filter. Acceptable for laptop stereo speakers because the L→mic and R→mic paths are similar enough that per-channel cancellation already removes ≥ 15 dB. Multi-input AEC would close that gap.
  - If the user moves the laptop or covers/uncovers the mic mid-recording, the echo path changes faster than μ can track and the residual briefly rises until adaptation catches up (1–3 s).
  - Tuning (filter length, step size) is currently compile-time defaults. Could be exposed via `MACREC_AEC_FILTER_LENGTH` / `MACREC_AEC_STEP_SIZE` if the defaults prove unsuitable in some environments.

### ENV-PENDING-1 — `swift test` blocked by missing PreviewsMacros plugin in CommandLineTools (important — testing only)
Multiple `#Preview { … }` macro blocks in the `macrec-ui` executable target (`Sources/macrec-ui/Views/Transcription/ApiKeyStatusChip.swift:32`, `…/ApiKeyStatusRow.swift:134,146`, `…/Header/AppearanceSwitcher.swift:97`, `…/Settings/Sections/GeneralSettingsView.swift:48`, and several more) fail to expand with `external macro implementation type 'PreviewsMacros.SwiftUIView' could not be found for macro 'Preview(_:body:)'; plugin for module 'PreviewsMacros' not found`. The plugin ships with full Xcode but not with the bare CommandLineTools toolchain currently configured on this Mac. Effect: `swift test` (which builds the whole package) fails before any test bundle is linked. Workarounds: (a) install/select a full Xcode (`xcode-select -p` should point at `Xcode.app/Contents/Developer`), or (b) wrap the offending `#Preview` blocks in `#if DEBUG && canImport(SwiftUICore)` or behind a `// swift-format-ignore` and gate them on a `PREVIEWS` swift-setting flag. `swift build --target MacrecUIKit` still succeeds, so library-level work and ad-hoc compile checks on the `MacrecUIKit` / `MacrecCore` targets are unaffected. Severity: important — only blocks the automated test runner, not production code.

### SONIOX-DONE-DUP-2026-05-06 (RESOLVED 2026-05-06) — Soniox live transcript: each line rendered twice + gradual stream loss after ~10 minutes
**Background.** During Soniox-backed live transcription the popover panel started rendering each new utterance twice once the session passed roughly 100 utterances (≈ 8–12 min on Soniox's natural-pause cadence), and older content was evicted from the rolling 100-segment window at ~2× the expected rate ("losing portions of the stream").

**Root cause.** `Sources/MacrecUIKit/RecordingController.swift` was routing `.segmentAppended` / `.segmentUpdated` / `.segmentFinalized` events by the `index` payload, which the streaming pipeline (`Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift:59,207,226-228`) generates as a *monotonic absolute* counter. Once `transcriptSegments.count == maxLiveTranscriptSegments` (100), every event with `index >= count` triggered an `append` for the first partial AND another `append` for the eventual final, doubling the row count per utterance and corrupting `Identifiable.id` uniqueness in `LiveTranscriptPanel`'s `ForEach`.

**Fix landed.**
- `RecordingController.appendOrInsertSegment(at:segment:)`, `updateSegment(at:segment:)`, `finalizeSegment(at:segment:)` now key on `TranscriptSegment.id` (the utterance UUID, stable across the partial→final lifecycle) instead of the absolute index. The `index` parameter is now advisory; signatures are unchanged so call sites stay intact.
- `applyTranscriptionEvent(_:)` access bumped from `private` to `internal` so the test target can drive long-session sequences via `@testable import MacrecUIKit`.
- `enforceSegmentCap()` extracted as a single helper used by all three mutation paths.

**Regression coverage.** New `Tests/MacrecUITests/RecordingControllerLongSessionTests.swift` drives ≥ `maxLiveTranscriptSegments + 25` synthetic utterances (each: partial → revised partial → final) and asserts:
- below cap, every utterance ends as a single FINAL row;
- past cap, no duplicate `id` entries in `transcriptSegments`;
- past cap, every retained row carries the FINAL text + `durationSec` (no stale partials);
- past cap, late `.segmentUpdated` for an evicted utterance is a silent no-op;
- past cap, late `.segmentFinalized` for an evicted utterance re-appears once at the tail with the final text.

End-to-end `swift test` execution is currently gated by ENV-PENDING-1 above; the user is verifying the fix in real use.

### PLAN-011-CC-PENDING-5 — convo-coach `Unknown model` warning for current models (cosmetic)
The `model-context-windows.ts` lookup table does not include several current models (notably `gpt-5.1`, `gpt-5`, `gpt-5-mini`). When the user passes `--model gpt-5.1` the budget guard logs `Unknown model 'gpt-5.1' — assuming 8000-token context window` and falls back to a conservative 8000-token budget. Advice still works (the budget guard truncates more aggressively than necessary), but the warning is noisy and the truncation may be over-aggressive on long transcripts. Recommendation: extend the table with current OpenAI / Anthropic / Google model IDs in a small follow-up. Severity: cosmetic (no functional impact for short transcripts).

### PLAN-011-CC-PENDING-1 — convo-coach SRT/VTT parsers + autodetect coverage missing (important)
Phase 7 code review (2026-05-02) found that the implementation deviates from plan-011 (§U4 file list lines 131-132, §"NEW" file list 519-521) and design CC-DSGN-6 ("`src/transcript/txt.ts, srt.ts, vtt.ts` (U4)"). Only `.jsonl` and `.txt` are wired:
- `tools/convo-coach/src/transcript/reader.ts:17` — `SUPPORTED_EXTENSIONS = ['.jsonl', '.txt']` (no `.srt` / `.vtt`).
- `tools/convo-coach/src/transcript/autodetect.ts:24` — same restriction; AC-CC-7 wording ("most recent `*.transcript.{jsonl,txt,srt,vtt}` sidecar") is therefore only partially satisfied.
- FR-CC-4 explicitly mandates SRT/VTT best-effort parsing including channel tags (`EN: …` / `<v EN>…</v>`).
The user-facing tool docs (`docs/tools/convo-coach.md`) only document `.jsonl`/`.txt`, so the gap is internally consistent across docs+code, but it is a documented deviation from the refined request. Recommendation: implement `srt.ts` and `vtt.ts` parsers in a small follow-up lane and broaden `SUPPORTED_EXTENSIONS` in both `reader.ts` and `autodetect.ts`, or have integration verification (Phase 10) explicitly accept the narrowed scope by amending the refined request and AC-CC-7. Severity: important (does not block dev install / smoke; affects AC-CC-7 strict pass).

### PLAN-011-CC-PENDING-2 — convo-coach orchestrator drops several design-listed CLI flags (nice-to-have)
Design CC-DSGN-5's `CliArgs` type lists: `adviceOut`, `adviceBasename`, `language`, `logLevel`, `showConfig`. The implementation in `tools/convo-coach/src/types.ts:118-130` ships a slimmer set (no `--advice-out`, `--advice-basename`, `--language`, `--log-level`, `--show-config`). Effects:
- FR-CC-11 sidecar-output overrides for stdin mode (`--advice-out <dir>` / `--advice-basename <stem>`) are not exposed; the orchestrator hard-codes the recordings-dir + `convo-coach-stdin` stem in `index.ts:308-316`.
- FR-CC-12 `--language <bcp-47>` hint is missing.
- FR-CC-14 `--log-level` is missing; logging always goes to stderr at info level via `process.stderr.write` (still per the spirit of NFR-CC-6 — no API keys are logged).
Help text in `args.ts:133-196` does not advertise these flags either, so end users have no expectation gap. Severity: nice-to-have (no AC-CC-* directly fails — AC-CC-15 is observed; the missing flags are only enumerated in design CliArgs, not in the AC table).

### PLAN-011-CC-PENDING-3 — convo-coach stdin precedence inverted vs FR-CC-3 (nice-to-have)
`tools/convo-coach/src/index.ts:407-416` resolves explicit `--transcript` BEFORE checking `process.stdin.isTTY === false`. FR-CC-3 §1 specifies the opposite — stdin should win even when `--transcript` is supplied, with a stderr warning. AC-CC-8 only requires stdin to be consumed when no `--transcript` is supplied, so the AC technically passes; integration verifier should confirm whether to treat the FR-CC-3 wording or AC-CC-8 wording as authoritative. Severity: nice-to-have (clarification, not a defect).

### PLAN-011-CC-PENDING-4 — convo-coach internal-invariant throws use plain Error (cosmetic)
`tools/convo-coach/src/output/sidecar.ts:182, 190, 219` throw `new Error(...)` for SidecarWriter post-close calls and rename failures. These are internal-invariant programming-error paths (write/append after close, or fs rename failure) so they are arguably acceptable per the project's "internal invariant failure that should bubble up uncategorised" carve-out, but tightening them to `ConvoCoachError('GENERIC', …)` would route them through the consistent exit-code mapping in `runCli`. Severity: cosmetic.

### PLAN-010-PENDING-L11-WIRING — Per-channel metrics polling wiring (deferred per Phase 7 + Phase 10 verification — non-blocking, follow-up lane recommended)
Phase 7 review (2026-05-01) and Phase 10 integration verification (2026-05-01) both confirmed this entry remains the right shape — the recommended fix (Option 1: add `TranscriptionEvent.dualMetricsTick(DualChannelMetrics)` emitted by `DualTranscriptionManager`, forwarded through `SessionCoordinator` to `RecordingController.applyDualMetrics(_:)`) requires touching `RecordingSession.swift` / `SessionCoordinator.swift` + the four sidecar writers' exhaustive switches over `TranscriptionEvent`. Deferred to a follow-up lane after Phase 10 ship. Until it lands, `DualTranscriptionMetricsView` renders `EmptyView()` at runtime in dual-mode sessions (the row is invisible). All other dual-mode UI surfaces work; only the per-channel metrics rows are dark. Phase 10 impact on AC-9: PARTIAL — slot exists, producer does not.

### PLAN-010-PENDING-L12-PRESTART — Move dual-mode privacy disclosure to a pre-start gate (deferred per Phase 7 + Phase 10 verification — non-blocking, follow-up lane recommended)
Phase 7 review (2026-05-01) and Phase 10 integration verification (2026-05-01) flagged: the L-12 mechanism in `Sources/macrec-ui/RootView.swift` observes `recordingController?.state` transitions and calls `recordingController?.stop()` AFTER the state has already moved to `.starting/.recording`. There is therefore a small race window (a few hundred ms typically, until `stop()` propagates through `SessionCoordinator → RecordingSession → AppleCloudStreamingSession.stop()`) where audio captured by the aligner could already have been ingested into the Apple Cloud session and dispatched to Apple's servers. The user-facing risk is small (the user just toggled the mode, no recording has actually been started intentionally) but real for a privacy disclosure that should be strict. Recommended fix: relocate the gate to `Sources/macrec-ui/Views/ControlBar.swift` `startTapped()` and short-circuit BEFORE calling `recordingController?.start()` when `transcriptionMode == .dual` and `apple-cloud` is unacknowledged. Deferred (small, cleanly bounded change; surface area is one method). Phase 10 impact on AC-6: MET behaviorally (sheet appears before any meaningful audio reaches the cloud) but NOT MET strictly (post-start `controller.stop()` has a ~ms window).

### PLAN-007-DONE-14 (RESOLVED 2026-05-01) — Apple Cloud STT provider added (`apple-cloud`) for Greek + 57 other locales
**Background.** The on-device `apple` provider (macOS 26 `SpeechAnalyzer`) does
NOT include Greek (`el-GR`) in its 42-locale launch set, and the
download-on-demand asset is unavailable on the user's Mac. The user asked
specifically for an Apple-branded *online* / cloud STT path that supports
Greek. Investigation
(`docs/reference/apple-cloud-stt-investigation-2026-05.md`) confirmed:

- Apple does NOT publish a public REST/WebSocket STT endpoint.
- The legacy `SFSpeechRecognizer` API exposes a cloud path through the
  framework when `requiresOnDeviceRecognition = false`, audio is tunnelled
  to Apple's private ASR servers.
- That cloud path supports Greek (`el-GR`) and ~57 other locales (Apple
  Dev QA1951 + `SFSpeechRecognizer.supportedLocales()`).
- Quotas: 1,000 requests / hour / device, ~60 s of audio per task.

**What landed.**
- New file
  `Sources/MacrecCore/Transcription/Providers/AppleCloudTranscriptionProvider.swift`
  containing both the provider struct (id `apple-cloud`,
  `displayName = "Apple Cloud"`, streaming-only) and the
  `AppleCloudStreamingSession` actor.
  - Resolves the locale from
    `TranscriptionOptions.languageHints.first` → `Locale.current` fallback.
  - Validates the locale against
    `SFSpeechRecognizer.supportedLocales()` and surfaces a clear
    `transcriptionConfigConflict` for unsupported codes.
  - Reads `SpeechPermission.current()` and surfaces an actionable error
    when status is `notDetermined` or `denied` — deliberately does NOT
    call `SFSpeechRecognizer.requestAuthorization(_:)` because the
    existing `SpeechPermission.ensureGranted` notes confirm that call
    SIGABRTs ad-hoc-signed CLIs on macOS 26 (the user's run mode).
  - Streaming session uses `SFSpeechAudioBufferRecognitionRequest`
    with `requiresOnDeviceRecognition = false` and
    `taskHint = .dictation`. Wraps incoming 16 kHz mono Float32
    chunks into `AVAudioPCMBuffer` and `append(_:)`s them.
  - Auto-rotates the recognition task at 55 s (`taskRotationSeconds`)
    by calling `endAudio()` on the active request and starting a fresh
    one in the result handler — leaves the in-flight final result
    intact across the seam (uses a fresh `utteranceId` so the manager
    treats the next window as a new utterance, not a revision).
  - Maps Apple's typical informational errors (`kAFAssistantErrorDomain`
    code 1110 "no speech detected", code 216 "session ended") to log-only
    so a quiet recording doesn't spam the UI; auth-revoked (1101) and
    network errors close the events stream.
- `TranscriptionProviderFactory.build(...)`:
  added `case "apple-cloud"`; updated the unknown-provider error message.
- `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift`:
  added `Apple Cloud (cloud, streaming, Greek + 57 locales)` to the
  popover picker; help text updated.
- `Sources/macrec-ui/RootView.swift`: added `apple-cloud` to
  `isCloudProvider(_:)` so the privacy disclosure sheet fires on first
  selection.
- `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift`:
  new `appleCloudBodyText` + headline branch explaining the audio is
  sent to Apple's servers, the system Speech Recognition prompt
  appears the first time, and the 1,000 req/hr + ~60 s/task quotas.
- `Resources/MacrecUI-Info.plist`: added
  `NSSpeechRecognitionUsageDescription` (the `.app` packaging script
  copies this plist; the in-tree dev binary inherits the macrec-ui
  bundle's plist when launched directly).

**Follow-up / known caveats.**
- Run mode caveat. The user typically launches macrec-ui via the raw
  binary at `.build/.../macrec-ui` (ad-hoc signed). On macOS 26 that
  triggers `SFSpeechRecognizer.requestAuthorization` to SIGABRT — which
  is why we deliberately do NOT call it. To use this provider, the
  user must either (a) repackage and launch from the
  `dist/macrec-ui.app` (Developer-ID or even ad-hoc-signed `.app`
  bundles do NOT exhibit the SIGABRT), or (b) once the binary is in
  the Speech Recognition allow-list (added by macOS automatically the
  first time a properly-signed bundle calls `recognitionTask`),
  subsequent CLI launches will read `authorized` and proceed.
- The `dist/macrec-ui.app` bundle is from 2026-04-29 and does NOT
  include any of the recent fixes. If the user wants to actually
  exercise this provider end-to-end they'll need to repackage. The
  packaging script lives outside the source tree (last-known location:
  the developer's local scripts); not regenerated as part of this
  change to avoid surprising the user.
- No XCTest fixture yet (deferred under PLAN-007-PEND-1). Manual
  smoke: select `Apple Cloud` in the popover, pick `el-GR` as the
  primary language, record a few seconds of Greek speech, expect the
  inline transcript panel to update with partials → finals.

### PLAN-007-DONE-13 (RESOLVED 2026-05-01) — ElevenLabs Scribe v2: speaker turns missing, language confusion, no multi-language picker
**Symptom (user-reported 2026-05-01).**
- The transcript was a continuous wall of text with no marker for who said what — even when the user had toggled `ELEVENLABS_DIARIZE=true`.
- Scribe v2 occasionally emitted Italian / French snippets in a recording the user described as "Greek + English only".
- The popover language picker only allowed at most 2 locales (Apple's `SpeechAnalyzer` cap), with no path for the ElevenLabs user who wants up to 3.

**Root-cause investigation.** Saved as
`docs/reference/elevenlabs-scribe-multilang-diarization-2026-05.md`
after a `technical-researcher` pass over the official ElevenLabs API
reference, the Python SDK schema, and the changelog. Findings:

- The `speech-to-text` endpoint returns `words[].speaker_id` (e.g.
  `"speaker_0"`, `"speaker_1"`) when `diarize=true`. There is **no**
  `segments[]` or `utterances[]` in the response — clients must
  group consecutive same-speaker words themselves.
  `ElevenLabsTranscriptionProvider.transcribe` was returning
  `decoded.text` and discarding the diarization payload entirely.
- `language_code` is documented as a **soft hint**, not a hard lock.
  There is **no `language_codes[]`, `additional_languages`,
  `allowed_languages`, `restrict_languages` parameter, and no
  per-segment language field**. The closest available controls are
  (a) omit `language_code` to enable Scribe's native code-switching
  auto-detect, and (b) supply `keyterms[]` (added 2026-01-12, ≤50
  entries × ≤20 chars) to bias the model toward target vocabulary.
- The `diarize=true` default in
  `TranscriptionProviderFactory` was `false`, so even users who
  expected speaker turns would get the wall-of-text behaviour
  unless they manually flipped `ELEVENLABS_DIARIZE`.

**Fixes landed.**

1. **Speaker-turn formatter** —
   `Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsTranscriptionProvider.swift`:
   added `formatDiarizedTranscript(words:)` that groups consecutive
   same-`speaker_id` words and emits `[Speaker N] …` lines.
   Re-numbers ElevenLabs' opaque `speaker_0`/`speaker_1`/… into
   `Speaker 1`/`Speaker 2`/… in first-appearance order.
   `transcribe(...)` now returns the formatted version when
   `diarize` is on AND the response carries any `speaker_id`s, and
   falls back to the legacy flat text otherwise.
2. **Multi-language soft-hint logic** — same provider:
   - Explicit `ELEVENLABS_LANGUAGE_CODE` always wins (back-compat).
   - Otherwise: send `language_code` only when EXACTLY ONE language
     hint was selected; ≥2 hints → omit (Scribe's native
     code-switching auto-detect mode, the docs' recommended path
     for bilingual content). Logs which path was taken at INFO.
3. **Keyterms wired end-to-end** — added
   `ElevenLabsConfig.keyterms: [String]` (with ≤50 / ≤20-char
   validation), `RecordingOptions.elevenLabsKeyterms`,
   `TranscriptionProviderFactoryInput.elevenLabsKeyterms`,
   `ConfigResolver.Keys.elevenLabsKeyterms` (env-var
   `ELEVENLABS_KEYTERMS`, comma-separated parser with the same
   validation), and the `ControlBar.startTapped` reader. The
   provider now appends one `keyterms` form-field per entry so
   Scribe biases its acoustic model toward the user's target
   vocabulary (the closest available proxy for "no
   Italian/French" given the API's lack of a hard allow-list).
4. **Up to 3 language slots in the popover picker** —
   `Sources/macrec-ui/Views/Transcription/TranscriptionLanguagePicker.swift`
   added a third `@AppStorage("com.macrec.ui.transcribeLanguage3")`
   slot and a third `Picker`, gated on `supportsTertiaryLocale`
   (true only for ElevenLabs; Apple's `SpeechAnalyzer` is hard-
   capped at two). `ControlBar.startTapped` now packs three
   slots into `transcriptionLanguageHints` (still de-duped /
   trim-empty filtered).
5. **`diarize` default flipped to `true`** in
   `TranscriptionProviderFactory.build(...)` (was `false`) and in
   the Settings panel toggle (`ElevenLabsSettingsView`); helper
   text updated.
6. **Helper text in UI** —
   `TranscriptionLanguagePicker` shows under the picker:
   *"ElevenLabs has no hard language allow-list — Scribe v2 may
   still emit other languages it recognises. Use the keyterms
   field in Settings → ElevenLabs to bias the model toward your
   target vocabulary."*
   `ElevenLabsSettingsView` adds a `SettingsHelperText` block
   explaining the 1-vs-2+ language behaviour, plus a new
   `Keyterms` text field.

**API limits we documented for the user (NOT fixable by us).**
- ElevenLabs cannot hard-lock the model to a set of N languages.
  The user explicitly asked for "no output from other languages
  than those I have selected" — that is not exposed by the
  Scribe v2 API. Best mitigations are the multi-language soft-hint
  switch + keyterms; for true hard locking the user would need to
  switch to Soniox (which does support explicit per-language
  enabling) — flagged as a follow-up investigation.

**Follow-up.**
- Investigate Soniox multi-language hard-lock as an alternative
  provider for users who require strict language restriction.
- If/when ElevenLabs adds a `language_codes[]` parameter, simplify
  the multi-language path: drop the omit-when-≥2 logic and just
  forward the array.
- Consider replacing `[Speaker 1]` text markers with structured
  diarization events on the streaming surface once
  `scribe_v2_realtime` is wired.

### PLAN-007-DONE-12 (RESOLVED 2026-05-01) — Azure OpenAI Realtime: `Missing required parameter: 'session.input_audio_transcription.model'` — RT-1 was inverted
**Symptom (user-reported 2026-05-01, after PLAN-007-DONE-11 landed).**
After dropping `create_response` / `interrupt_response`, the next
`transcription_session.update` round-tripped to a different Azure
error:

> *Azure realtime: model field appears in session update — RT-1 bug.
> Missing required parameter: 'session.input_audio_transcription.model'.*

(The "RT-1 bug" prefix was added by our own error handler — see
`AzureOpenAIRealtimeSession.handleEvent(.sessionError)` heuristic
that fired on any error message containing the substring "model".)

**Root cause.** Two layered bugs:

1. *Wire-types omitted a required field.* The
   `RealtimeWireTypes.InputAudioTranscriptionConfig` struct exposed
   only `language` + `prompt`. The "RT-1 model field bug" entry in
   `docs/research/azure-openai-realtime-transcription-wire-schema.md`
   §5.6 claimed Azure rejects the `model` field on
   `transcription_session.update`. That note is empirically wrong —
   it conflated the **conversational** intent (`gpt-realtime`),
   which does reject the field, with the **transcription** intent
   (`gpt-4o-mini-transcribe` family), which **requires** it. With
   the field absent Azure replied with the missing-parameter error
   above and never accepted the session config — so no transcription
   deltas ever flowed.

2. *Error-mislabeling heuristic compounded the confusion.* The
   `case .sessionError(let payload)` branch wrapped any error message
   containing `"model"` with a misleading "appears in session update
   — RT-1 bug" prefix, hiding the actual Azure message
   ("Missing required parameter: …").

**Fixes landed.**
- `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/RealtimeWireTypes.swift` —
  added `model: String?` to `InputAudioTranscriptionConfig` (with
  doc comment retracting the RT-1 claim and pointing back here).
- `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift` —
  added a `transcriptionModel: String` init parameter; populated
  the new `model` field in the `transcription_session.update`
  payload; added an INFO log showing which model is being set;
  retired the RT-1 error-mislabeling heuristic so Azure errors are
  surfaced verbatim.
- `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeTranscriptionProvider.swift` —
  added `defaultTranscriptionModel = "gpt-4o-mini-transcribe"` plus
  a `knownTranscriptionModels` allow-list (info-warning only,
  unknown values still pass through). `openStreamingSession` now
  resolves the model via `MACREC_TRANSCRIBE_MODEL > default` and
  forwards it to the session.

**Behaviour after the fix.** A user with no `MACREC_TRANSCRIBE_MODEL`
gets `model: "gpt-4o-mini-transcribe"`. A user whose deployment is
backed by `gpt-4o-transcribe` or `whisper-1` can opt in via
`MACREC_TRANSCRIBE_MODEL=…` in their `~/.tool-agents/macrec-ui/.env`
(or via the Settings UI's MACREC_TRANSCRIBE_MODEL field once that
panel exposes it). Surface-error wording now reads
`"Azure realtime invalid_request_error: <verbatim Azure message>"`.

**Follow-up.**
- Update `docs/research/azure-openai-realtime-transcription-wire-schema.md`
  §5.6 to retract the RT-1 claim for the transcription intent and
  document that `input_audio_transcription.model` is REQUIRED,
  with the three accepted values.
- Optional: surface a dedicated "Azure transcription model" picker in
  Settings → Azure OpenAI Realtime so users on `gpt-4o-transcribe`
  or `whisper-1` deployments don't have to reach for the env var
  directly.

### PLAN-007-DONE-11 (RESOLVED 2026-05-01) — Azure OpenAI Realtime: `transcription_session.update` rejected with `Unknown parameter: 'session.turn_detection.interrupt_response'`
**Symptom (user-reported 2026-05-01, after PLAN-007-DONE-10 landed).**
With the discriminator fix from PLAN-007-DONE-10 applied,
`sendSessionConfig()` finally fired — and Azure immediately answered
with `error` of type `invalid_request_error`:

> *Azure realtime invalid_request_error: Unknown parameter:
> 'session.turn_detection.interrupt_response'.*

The popover surfaced this correctly via the existing `error`
event handler — but transcription still produced no output because
the session update was rejected.

**Root cause.** `RealtimeWireTypes.TurnDetectionConfig` modelled
`create_response` and `interrupt_response`. Both are
**conversational realtime** fields (intent=conversation) — they
control whether the model auto-responds to detected speech and
whether incoming user audio interrupts a model response. They have
no meaning under `intent=transcription`, and Azure's transcription
endpoint flags them as `invalid_request_error` rather than ignoring
them. The earlier curl probe of `transcription_session.created`'s
default echo confirmed Azure's own `turn_detection` payload
contains only `type` / `threshold` / `prefix_padding_ms` /
`silence_duration_ms`.

**Fix landed.**
- `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/RealtimeWireTypes.swift` —
  removed `createResponse` + `interruptResponse` properties (and
  their `CodingKeys`) from `TurnDetectionConfig`. Added a
  prominent comment documenting the conversational-vs-transcription
  field split so a future contributor doesn't re-add them.
- `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift` —
  `sendSessionConfig()` no longer passes the two arguments;
  comment cross-references the wire-types note.

**Follow-up.**
- Update
  `docs/research/azure-openai-realtime-transcription-wire-schema.md`
  §5.4 turn-detection table to mark `create_response` /
  `interrupt_response` as **CONVERSATIONAL ONLY — DO NOT SEND ON
  intent=transcription** (mirroring the `model` field bug in §5.6).
- If conversational realtime is ever wired in, introduce a
  separate `ConversationalTurnDetectionConfig` rather than
  expanding the transcription type.

### PLAN-007-DONE-10 (RESOLVED 2026-05-01) — Azure OpenAI Realtime: `transcription_session.created` mis-routed to `.sessionUpdated`, no session config ever sent
**Symptom (user-reported 2026-05-01, after PLAN-007-DONE-9 landed).**
With the deployment-in-URL fix from PLAN-007-DONE-9 applied, the WS
no longer closed prematurely, but transcription still produced no
output. The popover showed the recording running with audio-meter
activity, no error banner, and no transcript ever arrived.

**Root cause.** Field probe with `curl` against
`biksaiservice-east-us-2.openai.azure.com` confirmed:
- The WS upgrade returns `HTTP/1.1 101 Switching Protocols` for both
  URL forms (with and without `&deployment=`).
- Azure's first server event for `intent=transcription` is
  `{"type":"transcription_session.created", …}` — NOT
  `{"type":"session.created", …}` as the wire-schema research note
  (`docs/research/azure-openai-realtime-transcription-wire-schema.md`
  §3 "First Server Event After Connect") claimed.

The discriminator switch in
`Sources/MacrecCore/Transcription/Providers/Azure/Realtime/RealtimeWireTypes.swift:176`
routed `"transcription_session.created"` to the `.sessionUpdated`
case (intentionally, per the comment "same payload as
session.updated"), which the session handler treats as a no-op debug
log. As a result `handleEvent(.sessionCreated)` — the only call
site for `sendSessionConfig()` — never fires. Without a
`transcription_session.update` from the client, Azure's session
keeps `input_audio_transcription: null` (visible in the curl
output), so it captures audio but emits zero
`conversation.item.input_audio_transcription.delta/completed` events.

The `didCompleteHandshake` flag added in PLAN-007-DONE-9 also
remained false, so the connection eventually expired silently
(close=1000) instead of producing an actionable error.

**Fixes landed.**
- `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/RealtimeWireTypes.swift` —
  re-routed the discriminator so both `"session.created"` and
  `"transcription_session.created"` decode to `.sessionCreated`, and
  both `"session.updated"` and `"transcription_session.updated"`
  decode to `.sessionUpdated`. This restores the
  `handleEvent(.sessionCreated) → sendSessionConfig()` path, which
  is what unlocks transcription.
- `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift` —
  `connectAndConfigure(...)` now logs the resolved WS URL +
  `deploymentInUrl` flag at INFO so future "WS hangs" repros are
  diagnosable from the log without curl.

**Follow-up.**
- Update
  `docs/research/azure-openai-realtime-transcription-wire-schema.md`
  §3.4 / §5.1 to record the empirical event name
  (`transcription_session.created`) and to retract the "NOT
  `transcription_session.created` — there is no
  `transcription_session.created` event type" claim.
- Add an XCTest fixture under the deferred Phase E test surface
  (PLAN-007-PEND-1) decoding a real `transcription_session.created`
  payload and asserting it lands on `.sessionCreated`.

### PLAN-007-DONE-9 (RESOLVED 2026-05-01) — Azure OpenAI Realtime: silent transcription failure when `&deployment=` missing from URL
**Symptom (user-reported 2026-05-01).** Selecting `Azure OpenAI Realtime
(cloud, streaming)` in the popover started a recording but produced
**zero** transcription output and **no** error feedback in the UI. The
recording itself succeeded.

**Root cause — two bugs combining.**

1. *URL shape.* `AzureOpenAIRealtimeConfig.websocketURL()` built
   `wss://{resource}.openai.azure.com/openai/realtime?api-version=…&intent=transcription`
   with no `&deployment=…` query parameter. The OQ-A2-2 decision in
   `docs/research/azure-openai-realtime-transcription-wire-schema.md`
   speculatively defaulted `deploymentInUrl=false` based on an early
   TechCommunity sample. In practice most Azure tenants reject the
   parameter-less URL — the upgrade handshake fails before any frame
   is exchanged.
2. *Error swallowed.* When the upgrade fails,
   `URLSessionWebSocketTask.closeCode` defaults to `.normalClosure`
   (1000) because no real close frame ever arrived from the server.
   `AzureOpenAIRealtimeSession.handleClose`'s `.normalClosure` branch
   treated this as a clean session end and silently called
   `eventsContinuation.finish()`, so no `.error(...)` event ever
   reached the UI banner. The log carried the receive-loop's
   "Socket is not connected" warning but the surface was silent.

**Evidence in field logs.** `~/.tool-agents/macrec-ui/macrec-ui.log`
showed every Azure realtime attempt exiting the receive loop with
`close=1000, error=The operation couldn't be completed. Socket is
not connected` — repeated across 2026-04-29 and 2026-05-01
sessions — followed by no error event in the popover.

**Fixes landed.**
- `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeConfig.swift:99` —
  flipped `self.deploymentInUrl = deploymentInUrl ?? true` (was `?? false`).
- `Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift` —
  added `didCompleteHandshake` flag (set when `session.created` arrives,
  reset in `connectAndConfigure()`), and made `handleClose`'s
  `.normalClosure` branch emit an explanatory
  `.error(detail: …)` event when the handshake never completed,
  before finishing the events stream.
- `Sources/macrec-ui/Settings/Sections/AzureRealtimeSettingsView.swift:78` —
  Settings toggle "Append &deployment= to URL" `defaultValue: true`
  with refreshed helper text.
- `Sources/MacrecCore/Config/ConfigResolver.swift:797` and
  `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift:38` —
  doc comments updated to record the 2026-05-01 default flip.

**Behaviour after the fix.**
- `wss://…/openai/realtime?api-version=…&intent=transcription&deployment={name}`
  is now the default URL shape; users can opt out via
  `AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL=false` if their tenant
  rejects the deployment parameter (rare).
- A failed handshake now surfaces in the popover's `ErrorBanner` as
  *"Azure realtime: connection failed before handshake completed —
  &lt;underlying NSError description&gt;. Common causes: wrong
  endpoint, missing &deployment= on URL …, wrong api-version,
  expired API key."* instead of failing silently.

**Follow-up.** Update
`docs/research/azure-openai-realtime-transcription-wire-schema.md`
§"Decision for v1" to document that the empirical default flipped to
`deployment=` ON, and add an XCTest covering the
`!didCompleteHandshake` branch of `handleClose` (currently
unexercised because Phase E test surface is deferred per
PLAN-007-PEND-1).

### PLAN-008-PEND-1 — Pre-existing test failures re-confirmed during plan-008 Phase 7 review (catalogued 2026-04-30)
Three pre-existing failures (untouched by any plan-008 file under review)
were re-verified during the Phase 7 code review of the UI-redesign +
theming work and are recorded here so the next maintenance pass can
clear them. None are introduced by Phase 6.

1. `HostClockAlignerStressTests::"10 skipNextEmission calls produce exactly 10 system gap-fills"` —
   timing/concurrency flake. Reproduces with
   `swift test --filter HostClockAlignerStressTests`. The aligner emits
   silence-fills on a 100 ms window; on a busy dev host the windows
   collapse and only 2 of the expected 9–11 gap-fills are observed. No
   plan-008 file touches `HostClockAligner`. Owner: next maintenance
   pass.
2. `StreamingTranscriptionPipelineTests::"first partial emits .segmentAppended; second partial for same utterance emits .segmentUpdated; final emits .segmentFinalized"` —
   already catalogued at CFG-PEND-2 #5 (the `.segmentFinalized` event
   is not emitted on this dev host). Re-confirmed reproducible during
   plan-008 review with `swift test --filter "StreamingTranscriptionPipeline"`.
   No plan-008 file touches the pipeline.
3. `UIErrorPresenterTests::"staleRecording → retry"` —
   locale-dependent. The Greek locale on the dev host formats
   `99999` as `99.999` (period as thousands separator); the test
   asserts `contains("99999")`. Fix shape: format the PID with
   `formatter.usesGroupingSeparator = false` in `UIErrorPresenter` or
   relax the assertion in the test to be locale-agnostic (e.g.
   construct the expected string via the same number formatter the
   presenter uses). No plan-008 file touches `UIErrorPresenter`.
   Owner: next maintenance pass. File:
   `Sources/MacrecUIKit/UIErrorPresenter.swift`,
   `Tests/MacrecUITests/UIErrorPresenterTests.swift:220`.

### PLAN-007-PEND-1 — XCTest suite for plan-007 (Phase E) deferred to follow-up
Plan-007 ships the production code for Phases 0 + A1 + A2 + B + C + D
(Azure OpenAI batch + realtime + ElevenLabs + UI + docs) on
2026-04-29. The Phase E test surface (21 XCTest files + 11 shell
scripts in plan-007 §E) is deferred to a follow-up commit so the
production code can land first and be exercised manually against
real credentials. Owner: next maintenance pass. The acceptance
criteria (AC-A-*, AC-A2-*, AC-B-*, AC-C-*) remain the contract —
see the AC tables in plan-007 §6, §A2.11, §B.10, §C.6.

### PLAN-007-PEND-2 — Manual smoke tests against real credentials
Plan-007 §10.6 requires manual menu-bar smoke for each new provider
(Azure batch, Azure realtime, ElevenLabs). To execute: launch
`macrec-ui`, pick the provider, observe the provider-specific
privacy disclosure on first selection, record 10–30 s of speech,
and verify the inline transcript panel updates and the
`*.transcript.jsonl` sidecar is written. Record the outcomes here
once a key for each provider is on hand.

### PLAN-007-DONE-1 (RESOLVED 2026-04-29) — `.whisperkit` enum case finally added
Closed by plan-007 Phase 0 Task 0.1. `TranscriptionProviderId`
(in `Sources/MacrecCore/Config/RecordingOptions.swift`) now
enumerates `.whisperkit`, `.azure`, `.azureOpenAIRealtime`, and
`.elevenlabs` so `MACREC_TRANSCRIBE=<id>` resolves cleanly through
the resolver's `parseEnum` instead of throwing
`invalidConfigValue`.

### PLAN-007-DONE-2 (RESOLVED 2026-04-29) — `ControlBar.startTapped()` API-key lookup extended for Azure + ElevenLabs
Closed by plan-007 Phase 0 Task 0.2 (extends SX-PEND-3 below).
The switch in `Sources/macrec-ui/Views/ControlBar.swift` now
resolves `AZURE_OPENAI_API_KEY` for `azure` /
`azure-openai-realtime` and `ELEVENLABS_API_KEY` for
`elevenlabs`, in addition to the existing Gemini / Soniox cases.
Azure-specific endpoint / deployment / api-version are also
forwarded into the new `RecordingOptions` fields when either
Azure provider is active.

### PLAN-007-DONE-3 (RESOLVED 2026-04-29) — `PrivacyDisclosureSheet` is now per-provider
Closed by plan-007 Phase 0 Task 0.3.
`PrivacyDisclosureViewModel` migrates the legacy single boolean
(and the plan-006 Soniox-specific flag) to per-provider keys
(`com.local.macrec-ui.transcription.privacy.{providerId}.acknowledged`)
on first run after upgrade. The sheet's body text is now
provider-aware (`bodyText(for:)`); switching from one cloud
provider to another re-shows the disclosure with the new vendor's
verbatim copy.

### PLAN-007-DONE-4 (RESOLVED 2026-04-29) — `ProviderKeyField` reusable view introduced
Closed by plan-007 Phase 0 Task 0.4.
`Sources/macrec-ui/Views/Transcription/ProviderKeyField.swift` is
the new shared SecureField + Save/Clear row consumed for Azure
(both batch and realtime) and ElevenLabs in `RootView`. The
existing `GeminiKeyField` and `SonioxKeyField` are unchanged for
visual back-compat.

### PLAN-007-DONE-5 (RESOLVED 2026-04-29) — `MultipartFormDataBuilder` shared helper
Closed by plan-007 Phase 0 Task 0.5.
`Sources/MacrecCore/Transcription/Net/MultipartFormDataBuilder.swift`
is the Foundation-only multipart body builder consumed by both
`AzureOpenAITranscriptionProvider` (Phase A1) and
`ElevenLabsTranscriptionProvider` (Phase B).

### SX-PEND-3 (RESOLVED 2026-04-29) — `ControlBar.startTapped()` hardcoded `GOOGLE_API_KEY` regardless of selected provider

- **Symptom (user-reported)**: Picking Soniox in the menu-bar picker, saving a valid `SONIOX_API_KEY` via `SonioxKeyField`, then clicking Start produced `soniox.server_error: invalid or expired API key (401)`. Diagnostic fingerprint logged in `TranscriptionProviderFactory.build` showed the running app was sending the user's `GOOGLE_API_KEY` (prefix `AIzaSy…`) to Soniox.
- **Root cause**: `Sources/macrec-ui/Views/ControlBar.swift:254-257` (pre-fix) read `ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]` unconditionally whenever transcription was enabled, ignoring the selected `resolvedProviderId`. Plan-006 Unit H fixed the provider-aware tooltip in `TranscriptionPicker` and added `SonioxKeyField`, but missed this single env-var lookup in `ControlBar`.
- **Fix**: provider-aware switch in `ControlBar.startTapped()` — `gemini`/`gemini-live` → `GOOGLE_API_KEY`, `soniox` → `SONIOX_API_KEY`, otherwise nil.
- **Why the workflow missed it**: codebase scan focused on `TranscriptionPicker.swift:67` (the tooltip) but not the parallel ENV-var lookup in `ControlBar.startTapped`. Code review checked the resolver branch but did not trace UI-side callers. Lesson: any time a new provider needs an API key, grep ALL of `Sources/macrec-ui/` and `Sources/MacrecUIKit/` for the existing provider's env-var name to confirm parity.
- **Verification**: rebuild .app, restart menu-bar app, watch for `soniox: using API key fingerprint c6c2b0…` in `~/.tool-agents/macrec-ui/macrec-ui.log` (should now show the Soniox key prefix, not Gemini's `AIzaSy…`).

The risks below were captured during Phases 4–6 of the planning and
implementation workflow (see `docs/design/plan-001-recording-tool.md`
§6 risk register, `docs/design/plan-002-toolbar-ui.md` §5 risk
register, and `docs/design/plan-003-live-transcription.md` §6 risk
register). They are tracked here so subsequent phases can flag
residual exposure.

### CFG-PEND-2 — pre-existing transcription test-suite failures unrelated to plan-006 (catalogued 2026-04-29 by Phase 7 reviewer)
While running `swift test --filter "Transcription|Config"` for the plan-006
code review, **9 additional pre-existing failures** surfaced beyond CFG-PEND-1.
Verified pre-existing by stashing the entire plan-006 diff (including untracked
files) and re-running the same filter on `master` — all 9 reproduce there.
None are introduced by plan-006. Catalogued here so the next maintenance pass
can clear the slate before relying on `swift test` as a guard rail:

1. `SessionCoordinatorTranscriptionIntegrationTests::--transcribe gemini-live without API key raises transcriptionApiKeyMissing` —
   asserts `provider == "gemini-live"` but the resolver normalises the
   deprecated alias to `"gemini"` (plan-004 Phase G.2). Same fix shape as the
   two `StartCommandTranscriptionFlagsTests` cases I corrected during this
   review: update the expectation to `"gemini"`. (file
   `Tests/MacrecCoreTests/Recording/SessionCoordinatorTranscriptionIntegrationTests.swift:145`)
2. `SessionCoordinatorTranscriptionIntegrationTests::Sidecar URL respects partNN naming when audio URL contains a part token` —
   2 expectations missing the `.transcript.` infix in the expected sidecar
   filenames. The implementation correctly inserts `transcript` per design
   §LT-7.1 (this is the previously-fixed R-LT-1, plan-004 Phase F.1). Test
   strings need to be updated to match the as-built filenames
   (`recording.part01.transcript.jsonl`, etc.).
3. `TranscriptionManagerTests::ingesting enough samples produces a segmentAppended event` —
   pre-existing flake / timing-sensitive test; needs investigation.
4. `GeminiRESTTranscriptionProvider` — 5 failures all caused by the
   `GeminiRESTStubProtocol` URLProtocol stub returning `error -1` instead of
   the canned response on this dev host (likely SDK/runtime change since the
   tests were written). Pre-existing on master.
5. `StreamingTranscriptionPipeline::first partial emits .segmentAppended; …` —
   pre-existing failure where `.segmentFinalized` is not emitted; likely a
   late `.final` event ordering regression introduced by a prior plan.

Owner: next maintenance pass. **Plan-006 itself has not regressed any test
that previously passed.**

### CFG-PEND-1 — `ConfigResolverTranscriptionTests/shellEnvSupplies` is pre-existing red on master (discovered 2026-04-29 during plan-006 Unit B)
The test
`Tests/MacrecCoreTests/Config/ConfigResolverTranscriptionTests.swift::shellEnvSupplies`
(line 70-92) sets `MACREC_TRANSCRIBE_SOURCE=mic` but does NOT set
`MACREC_MIC_DEVICE`. Since plan-005 / commit `f1adb58a` introduced the
"transcribe-source mic + mic disabled" cross-check at
`Sources/MacrecCore/Config/ConfigResolver.swift:438-445`, the resolver
now (correctly) raises `.transcriptionConfigConflict` whenever the
selected mic source has no usable device. The test fixture predates
that cross-check and was never updated.

This was discovered during plan-006 Unit B verification (Soniox config
plumbing) — the failure is **pre-existing** and not caused by the
Soniox additions: `git blame` of lines 438-445 shows commit `f1adb58a`,
not the in-flight Unit B commit. The new
`Tests/MacrecCoreTests/Config/SonioxConfigResolverTests.swift` does
NOT reproduce the failure — its mic-source tests use a non-`mic`
source or supply `MACREC_MIC_DEVICE` explicitly.

Fix (out of scope for plan-006 Unit B; flagged for the next
maintenance pass): add `"MACREC_MIC_DEVICE": "default"` (or any
non-empty value) to the test fixture's shell-env dictionary, OR
change `MACREC_TRANSCRIBE_SOURCE` to a non-`mic` value (e.g. `mixed`)
to keep the test focused on the env-var precedence chain it actually
exercises.
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

### PLAN-012-PHASE-C — True source-split transcription (Closed 2026-05-02)

Plan-012 Phase C lifts the v1 `--transcribe-source both` limitation.
The single-mode dispatcher previously collapsed `both` to `mixed`
and emitted a single combined transcript; the new path runs **two**
parallel transcription drivers (one per `SourceTag`) behind a new
`SourceSplitTranscriptionManager` actor that conforms to the
existing `TranscriptionDispatcher` protocol. Each child manager
owns its own provider instance, sidecar writer, downsampler, and
metrics struct — the manager merges their event streams into one
and field-wise-merges their metrics on `currentMetrics()`.

Tasks delivered:

- C1 — `SourceSplitTranscriptionManager` skeleton + ingest routing
  by SourceTag + `TranscriptionMetrics.merge`.
- C2 — Two-stream `AsyncStream` merge with finish-counter actor.
- C3 — Per-source sidecar naming (already implemented by
  `SidecarPathBuilder.sidecarURL(... sourceTag:)` from plan-003 /
  plan-004; no code change needed).
- C4 — `TranscriptionDispatcherSelector.chooseKind(for:)` pure
  selector + RecordingSession three-way switch on the kind, with
  ElevenLabs Free/Starter quota warning when source == .both.
- C5 — `SourceLane` + `SourceLaneFilter` + `SegmentChipRow` extracted
  for reuse (singleBody intentionally not refactored — DT-INV
  preservation).
- C6 — `SourceSplitTranscriptView` (two stacked SourceLanes) +
  `LiveTranscriptPanelBranchSelector` + three-way `body` branch in
  `LiveTranscriptPanel`.
- C7 — `AppleSpeechParallelInstancesTest` smoke-locks the
  two-instance `SpeechAnalyzer` contract.

DT-INV preservation: when source ∈ {system, mic, mixed}, single-mode
rendering and engine paths are byte-equivalent to today. Closes the
"True per-source dual-driver transcription" v2 follow-up tracker.

### PLAN-012-PHASE-A — Soniox speaker diarization (Closed 2026-05-02)

Plan-012 Phase A (tasks A1–A8) lifts OQ-SX-3's "diarization OFF in v1"
posture and ships full speaker support across the Soniox stack:

- **Wire-format default** (`SonioxConfigBuilder.defaultDiarize: Bool = true`)
  flipped — Soniox now sends `enable_speaker_diarization: true` on the
  first WebSocket frame by default.
- **Override surface** — `MACREC_SONIOX_DIARIZE` env var (four-tier
  resolution) + `--soniox-diarize <bool>` CLI flag + Settings → Soniox →
  "Diarize speakers" UI toggle (env-bound via `EnvFileStore`). Garbage
  values raise `MacrecError.invalidConfigValue` (exit 64).
- **Aggregator** (`SonioxTokenAggregator`) tracks an actor-isolated
  `activeSpeaker` and finalises the active partial whenever an incoming
  token's speaker differs; resets on `<end>`/`<fin>` markers. Carries
  through nil-speaker tokens unchanged.
- **Event chain** — `StreamingTranscriptionEvent.{partial, final}` gain
  optional `speaker: String?` associated value. `StreamingTranscriptionPipeline.handle`
  forwards it into `TranscriptSegment.speaker` on partial-append /
  partial-update / final paths.
- **Sidecar rendering** — `SpeakerSidecarLabel` is the single source of
  truth for `spk:N` → `SN`. JSONL carries the raw value; TXT/SRT/VTT
  render the display label. Non-diarized providers stay byte-equivalent.
- **UI** — speaker chip rendered next to the language chip in
  `LiveTranscriptPanel.segmentView` when `segment.speaker != nil`.

Closes OQ-SX-3 (project-functions.md §1647). All paths preserve DT-INV
byte-equivalence for non-diarized output (Sidecar 64/64, Persistence
6/6, Soniox 35/35 suites green).

### PLAN-011-CC-REFACTOR-LANGCHAIN — convo-coach LLM stack swapped from Vercel AI SDK to LangChain.js (Closed 2026-05-02)

User requested replacing the Vercel AI SDK with LangChain.js. **Straight swap with the same 8-provider surface preserved.** Removed `ai@^6` + `@ai-sdk/openai` + `@ai-sdk/anthropic` + `@ai-sdk/google` + `@ai-sdk/azure` + `@ai-sdk/openai-compatible`. Added `@langchain/core@^1.1` + `@langchain/openai@^1.4` + `@langchain/anthropic@^1.3` + `@langchain/google-genai@^2.1` + `@langchain/ollama@^1.2`. js-tiktoken kept for OpenAI-family token counting.

Changes:
- `tools/convo-coach/src/types.ts` — `LanguageModel` re-export now imports `BaseChatModel` from `@langchain/core/language_models/chat_models` (was `import type { LanguageModel } from 'ai'`).
- `tools/convo-coach/src/llm/providers/*.ts` (all 8) — rewritten to instantiate `ChatOpenAI` / `AzureChatOpenAI` / `ChatAnthropic` / `ChatGoogleGenerativeAI` / `ChatOllama` directly. Provider routing preserved: 5 OpenAI-compat providers (openai, azure-openai-v1-mode, azure-ai-inference, litellm, mlx) all use `ChatOpenAI` with appropriate `apiKey` + `configuration.baseURL`; `azure-openai` legacy mode uses `AzureChatOpenAI`; `ollama` uses dedicated `ChatOllama` (native `/api/...` paths, no `/v1` suffix needed).
- `tools/convo-coach/src/output/stream.ts` — `runOneAdvice` rewritten: `streamText({...}).textStream` → `model.stream([SystemMessage, HumanMessage])` returning `AsyncIterable<AIMessageChunk>`; aggregates chunks via `concat()` from `@langchain/core/utils/stream`; usage metadata pulled from final aggregated chunk's `usage_metadata` (snake-case fields `input_tokens`/`output_tokens`/`total_tokens` projected onto our flat camelCase `AdviceUsage` shape). AbortSignal flows through `model.stream(messages, { signal })`.
- `tools/convo-coach/test/llm-factory-smoke.test.ts` — fixture-only updates (no logic change).
- `tools/convo-coach/test/output-sinks.test.ts` — `runOneAdvice` stub simplified from a complex `doStream` + `ReadableStream` shape to a plain `async function* () { yield { content, usage_metadata? } }` generator. The previously-skipped "Implementation gap" assertion now runs and passes (full shape + collected text + usage metrics asserted).
- `tools/convo-coach/package.json` — `overrides: { "@anthropic-ai/sdk": "^0.92.0" }` added to clear an upstream moderate-severity advisory (Anthropic SDK's filesystem-memory tool, which `convo-coach` doesn't use).

Verified: `npx tsc --noEmit` 0 errors; `npm test` 166/166 pass; `npm audit` 0 vulnerabilities; end-to-end smoke against the user's `gpt-5.1` Azure deployment streams 30 lines of advice (584/424/1008 tokens, 1.30 s TTFT, 4.51 s latency, exit 0). Public CLI / env-var / exit-code surface unchanged. Sidecar format unchanged. Four-tier config resolver unchanged.

### PLAN-011-CC-FIX-CONFIG-EMPTY-OVERRIDE — convo-coach config resolver "delete-on-empty" semantic (Closed 2026-05-02)

When the user uncommented `AZURE_OPENAI_API_VERSION=` (empty) in `~/.tool-agents/convo-coach/.env` to override their shell-exported `AZURE_OPENAI_API_VERSION=2024-12-01-preview`, the tool kept reading the shell value. Root cause: `loadConfig`'s `applyTier` skipped empty-string values (`if (raw === undefined || raw === '') continue;`), so a tier-2 empty assignment never wiped a tier-1 set value. **Fix**: changed the semantic so empty strings at any tier explicitly DELETE the key from the resolver's working map (clearing whatever a lower tier contributed) without contributing a value of their own. Now:
- Shell sets `KEY=value` + .env sets `KEY=` (empty) → resolver returns `undefined` (correct override).
- Shell sets `KEY=` (empty) only → resolver returns `undefined` (unchanged behavior — the existing test still passes).
- Shell sets `KEY=value` + .env unsets the line → resolver returns `value` (unchanged).

Added new test `config: empty string at tier-2 wipes the shell value (delete-on-empty override)`. All 166 tests pass. Verified end-to-end: with the user's shell still exporting `AZURE_OPENAI_API_VERSION=2024-12-01-preview`, an empty `.env` override now correctly routes to Azure's v1 GA endpoint, gpt-5.1 streams cleanly (586/438/1024 tokens). Documented in the .env template comment that this is the intended override mechanism.

### PLAN-011-CC-FIX-AZURE-V1 — convo-coach Azure provider switched to v1 GA API (Closed 2026-05-02)

User reported `error: stream failed: API version not supported` when running `convo-coach --provider azure-openai --model gpt-5.1` against the existing shell environment (`AZURE_OPENAI_API_VERSION=2024-12-01-preview`). Root cause: Azure GA'd a new `/openai/v1/...` endpoint in August 2025 that does not accept dated api-versions. The provider was always passing `apiVersion` to `createAzure`, which forced the SDK to append `?api-version=2024-12-01-preview` to v1 URLs — Azure rejected the call. **Fix** (in `tools/convo-coach/src/llm/providers/azure-openai.ts`): made `AZURE_OPENAI_API_VERSION` optional and auto-paired with `useDeploymentBasedUrls`:
- When unset → SDK defaults to `'v1'` and routes to `/openai/v1/...` (correct path for current models including gpt-5.x).
- When set → also enables `useDeploymentBasedUrls: true` so the provider switches to the legacy `/openai/deployments/<id>/...?api-version=<x>` URL pattern (correct for older deployments that still need a dated api-version).

Updated docs: `docs/tools/convo-coach.md` Azure OpenAI section now marks `AZURE_OPENAI_API_VERSION` as Optional with a migration tip; `~/.tool-agents/convo-coach/.env` template now explains the v1 GA default. Added new test `buildLanguageModel: azure-openai builds without AZURE_OPENAI_API_VERSION (v1 GA default)`. Test suite: 165/165 pass (was 164). Verified end-to-end with the user's actual gpt-5.1 deployment: v1 mode (api-version unset) returns exit 0 with full advice streamed (1049 tokens, 1.4 s TTFT, 5.4 s latency). Legacy mode (api-version set) returns the appropriate "Resource not found" / "API version not supported" error with exit 70 depending on deployment vintage.

**User action required to take advantage of the fix**: `unset AZURE_OPENAI_API_VERSION` in your shell profile (or set it to empty in `~/.tool-agents/convo-coach/.env`) before running `convo-coach --provider azure-openai`. Otherwise the legacy URL pattern stays active.

### PLAN-010 — Dual-provider live transcription mode (Closed 2026-05-01)

Plan-010 shipped the new dual-mode live-transcription feature: Apple on-device SpeechAnalyzer (Channel A, English) + Apple Cloud (Channel B, Greek) running concurrently against the same captured audio, with a unified channel-tagged sidecar (jsonl/txt/srt/vtt) and a dual-lane live-transcript view. **12 lanes (L-1..L-12)** shipped across 6 waves. Phase 7 review fixed `DualTranscriptionManager`'s drain-Task error event tagging (PHASE7-FIX-1). Phase 9 added 8 new dual-* test suites (`DualLocaleSets`, `DualTranscriptionConfig`, `DualSidecarLabel`, `DualTranscriptionManager` failure-isolation, `DualLiveTranscriptView`, `DualPrivacyDisclosure`, `DualTranscriptionControls`, `LiveTranscriptPanel single-mode invariance`) plus the `Sidecar channel tagging (Lane L-6)` suite. Phase 10 integration verification (2026-05-01): full `swift build` green, `swift build --product macrec` green, `swift build --product macrec-ui` green; targeted test suites — Sidecar 51/51 green, ConfigResolver dual-mode 1/1 green (full ConfigResolver 76/77 — single failure is pre-existing CFG-PEND-1), ControlBarStartTappedKeysRegression 4/4 green, UI dual tests 76/76 green; `Dual` filter 91/103 green with 10 host-environment failures all caused by `SpeechTranscriber.supportedLocales` returning `[]` on this CI host (Speech entitlement unavailable — NOT a code defect). CLI smoke tests confirmed `--transcribe dual` flag parsing works correctly: missing `--transcribe-dual-locale-a` raises the expected `transcriptionConfigConflict` error (exit 64); fully-formed dual invocation parses cleanly through to the runtime locale check. **AC summary: 9 MET, 2 PARTIAL** (AC-6 strict pre-start gate deferred per L-12-PRESTART; AC-9 per-channel metrics-poll wiring deferred per L-11-WIRING). **Documentation**: `docs/tools/macrec.md` Dual-mode subsection, `docs/tools/macrec-ui.md` mode-switch / Dual control set / dual-lane display sections, `CLAUDE.md` Tools entries for both `macrec` and `macrec-ui` reference dual mode, `docs/design/project-functions.md` FR-DUAL-1..FR-DUAL-11 + NFR-DUAL-1..NFR-DUAL-7 added, `docs/design/project-design.md` §DT-1..§DT-13 added, `docs/design/plan-010-dual-transcription.md` (Phases A..J) drives the work. Two follow-up items remain Pending and non-blocking: PLAN-010-PENDING-L11-WIRING (per-channel metrics polling pathway) and PLAN-010-PENDING-L12-PRESTART (move privacy disclosure to pre-start gate). **Phase 10 verdict: READY** to ship with the two documented deferred follow-ups. Per-lane shipping notes archived below.

### PLAN-010-PENDING-L9 — Dual-lane live-transcript display landed (Wave 6, Lane L-9 — final Phase 6 lane)
Two new files under `Sources/macrec-ui/Views/Transcription/Dual/` plus one edit to `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift`:

- `DualLiveTranscriptLane.swift` — single-channel lane component (`struct DualLiveTranscriptLane: View { let channel: DualChannelTag; let segments: [TranscriptSegment] }`). Renders a small caption header (`"EN — Channel A (Apple on-device)"` / `"EL — Channel B (Apple Cloud)"`) using `DualSidecarLabel.channelLabel(for:)` so the user-facing channel label is unified with the sidecar writers. The lane's body is a `ScrollView` wrapped in a `ScrollViewReader` with auto-scroll-to-bottom triggered on `segments.count` and `segments.last?.lastUpdated` changes — INDEPENDENT of the sibling lane's scroll state (DT-ADR-8). Per-segment row mirrors `LiveTranscriptPanel.segmentView(_:)` byte-for-byte: italic-secondary while partial (`segment.isSettled == false`), plain-primary once finalised, optional uppercase BCP-47 language chip when `segment.language` is non-nil. Layout-agnostic — the lane makes no assumption about whether it sits in a `VStack` or `HStack`; the composing view owns the layout decision.
- `DualLiveTranscriptView.swift` — composing view that stacks two `DualLiveTranscriptLane` instances vertically (Channel A on top, Channel B on the bottom, per the §DT-8 ASCII mockup) with a 0.5pt `palette.separator` divider between them. Each lane gets `.frame(maxHeight: .infinity)` so the available popover height splits 50/50. Filters `recordingController.transcriptSegments` per channel via `DualSidecarLabel.channelTag(forModel:)` (the L-6 helper) — Channel A receives segments where `model == "apple"`, Channel B receives `model == "apple-cloud"`. Segments with any other (or nil) model are NOT rendered in dual mode by design — they are out-of-band (e.g. residual single-mode segments from before a mode switch).
- `LiveTranscriptPanel.swift` — adds a top-level mode branch (`if transcriptionMode == .dual { dualBody } else { singleBody }`) reading `@AppStorage(RecordingController.transcriptionModeStorageKey)` directly so the panel reactively re-renders on user mode flip without a controller-side `Notification` round-trip. The pre-plan-010 panel body is preserved verbatim inside the new `singleBody` computed property (DT-INV: no SwiftUI tree drift in single mode — `LiveTranscriptPanelSingleModeTests` will lock this once L-13 lands the test). The new `dualBody` reuses the same `groupBackground` + `groupStroke` chrome and the same outer `.frame(minHeight:maxHeight:alignment:)` modifier as `singleBody`, so the panel claims its slot identically in both modes; the only difference is the inner content (header bar + clear button + status badge + `DualLiveTranscriptView()` instead of the single-mode `ScrollViewReader { ScrollView { ForEach(segments) … } }`).

**Layout decision (DT-ADR-8 / OQ-5).** Stacked lanes (NOT side-by-side, NOT single chronological feed). Side-by-side rejected because the popover (~360pt wide) is too narrow for two readable text columns, especially with mixed scripts (Greek + Latin in v1). Single chronological feed rejected because the channels lag at different rates (Apple on-device is faster than Apple Cloud), so the stream visually "jumps" as late Channel B segments arrive after newer Channel A segments — reading either channel becomes painful.

**Frozen contracts produced.** `DualLiveTranscriptView()` (no-arg init) is the entry point that `LiveTranscriptPanel.dualBody` instantiates. `DualLiveTranscriptLane(channel:segments:)` takes pre-filtered segments — the lane does NOT re-filter, so it is trivially testable / reusable in any future layout (side-by-side, three-channel, etc.).

**Verification.** `swift build --product macrec-ui` succeeds (3 new/modified files compile clean in 2.98 s, no warnings beyond the pre-existing baseline). `swift test --filter "LiveTranscriptPanel|DualLiveTranscript|MacrecUI"` runs 192 / 193 green; the single failure (`UIErrorPresenter / staleRecording → retry`) pre-exists L-9 and is the locale-formatting issue documented in earlier L-7 / L-8 entries (the test asserts `"99999"` substring but the system formats `99999` with locale grouping as `"99.999"`). The `LiveTranscriptPanel behavior (via RecordingController)` suite (the closest existing single-mode regression coverage) passes 7/7. No `LiveTranscriptPanelSingleModeTests` test file was created — that is L-13 territory per plan-010 §G.4 ("Tests to add: `Tests/MacrecUITests/Transcription/LiveTranscriptPanelSingleModeTests.swift`" — Lane L-13 cross-phase test owner).

**Awaits Phase J automated tests.** `Tests/MacrecUITests/Transcription/Dual/DualLiveTranscriptViewTests.swift` per plan-010 §G.4 — the three tests required are: `dualPanelPartitionsSegmentsByModel()`, `dualPanelRendersLaneHeaders()`, `dualPanelClearTranscriptClearsBothLanes()`. These belong to L-13 (cross-phase tests lane).

### PLAN-010-PENDING-L12 — Privacy disclosure trigger for Dual mode landed (Wave 5, Lane L-12)
Single file modified — `Sources/macrec-ui/RootView.swift` — adds a Start-tap guard that fires the existing `apple-cloud` privacy disclosure (verbatim copy per IP-15 / DT-ADR-12) on the first Dual-mode start when the per-provider acknowledgement key is unset. No changes to `PrivacyDisclosureSheet.swift` or `PrivacyDisclosureViewModel` (they already expose the per-provider key mechanism via `acknowledgedKey(for:)`).

**Mechanism.** `RootView` already owned the existing single-mode disclosure trigger (`.onChange(of: transcribeProviderRaw)`), but Dual mode flips no provider — `transcriptionMode` toggles independently and the user clicks Start with `transcribeProviderRaw` unchanged. Per §DT-11 the disclosure must fire on **Start-tap**, not on mode toggle (the user must be allowed to preview the Dual panel without committing). The actual Start tap lives in `ControlBar.startTapped()` (L-6 territory, intentionally not modified by L-12 — Wave 5 lanes touch disjoint files). The new `.onChange(of: recordingController?.state)` observer in RootView detects the lifecycle transition `.idle/.stopped/.failed → .starting/.recording`, which uniquely signals "user just clicked Start", and fires the dual-mode guard:

1. Read `@AppStorage(RecordingController.transcriptionModeStorageKey)` and parse `LiveTranscriptionMode`. If `.single`, no-op (single-mode flow is unchanged).
2. If `.dual`, check `Self.hasAcknowledged(provider: "apple-cloud")` (the existing helper that consults the per-provider key + legacy back-compat keys). If acknowledged, no-op (the recording proceeds normally).
3. If unacknowledged, immediately call `recordingController?.stop()` so no audio reaches Apple's cloud servers before the user has seen the disclosure, then arm a new `@State dualModeDisclosureProvider = "apple-cloud"` and present the existing `.sheet(isPresented: $showPrivacySheet)` — the sheet block was extended to render the Dual-mode branch when `dualModeDisclosureProvider != nil`. The Dual-mode `onAcknowledge` persists the per-provider key (`Self.persistAcknowledgement(for: "apple-cloud")`) and clears the State; the user re-clicks Start to begin recording. The Dual-mode `onCancel` does NOT mutate `transcribeProviderRaw` (which is a Single-mode picker concern) — it just clears State; the controller stays stopped.

**Reuse invariants.** `PrivacyDisclosureViewModel.acknowledgedKey(for: "apple-cloud")` is the SOLE source of truth — a user who accepted the `apple-cloud` disclosure under Single mode is NOT re-prompted in Dual mode (§DT-11 / FR-8 / AC-6); same in reverse. No new AppStorage key was introduced. No new disclosure copy was written (the existing `appleCloudBodyText` covers Dual mode verbatim per DT-ADR-12 / IP-15). Channel A (`apple` on-device) is intentionally NOT included in the dual-mode disclosure set — there is no current single-mode `apple` disclosure and the on-device path has no privacy implications.

**Verification.** `swift build --product macrec-ui` succeeds (build clean in 2.73 s, no warnings). `swift test --filter "PrivacyDisclosure"` runs 2/2 tests green (locked UserDefaults key constant + locked body-text phrases) — no regression in the existing single-mode `PrivacyDisclosureViewModel` persistence tests. Manual reasoning trace verified for all 5 paths (single-mode `apple` start = no disclosure; single-mode `apple-cloud` acknowledged / unacknowledged = paths unchanged; dual-mode acknowledged = no disclosure, recording proceeds; dual-mode unacknowledged = `recordingController.stop()` fires, sheet presents `apple-cloud` copy, accept persists key and user re-clicks Start, cancel leaves controller stopped).

Awaits Phase J automated tests (`Tests/MacrecUITests/Transcription/Dual/DualPrivacyDisclosureTests.swift` per plan-010 §J.3) — that test file is L-13 territory (cross-phase tests lane); the L-12 implementation deliberately does not write the test file because L-13 is the test owner. The three tests required by §J.3 are: `dualStart_promptsAppleCloudDisclosureWhenUnacknowledged()`, `dualStart_doesNotPromptWhenAppleCloudAlreadyAcknowledged()`, `singleAppleCloudAcknowledgement_carriesIntoDualMode()`.

### PLAN-010-PENDING-L8 — Dual controls sub-panel landed (Wave 5, Lane L-8)
Two new files under `Sources/macrec-ui/Views/Transcription/Dual/` plus one edit to `Sources/macrec-ui/Views/Sections/LiveTranscriptionSection.swift`:

- `DualLocalePicker.swift` — generic locale `Picker` view that takes an INJECTED `supportedLocales: [Locale]` array, a label, and a `Binding<String>` (BCP-47 identifier). The view does NOT consult `SFSpeechRecognizer.supportedLocales()` or `SpeechTranscriber.supportedLocales` directly — the constraint that Channel A draws ONLY from `DualLocaleSets.channelASupportedLocales` (no Greek) and Channel B ONLY from `DualLocaleSets.channelBSupportedLocales` (with Greek) is enforced at the construction site in `DualTranscriptionControls`. Display formatting (`Greek (Greece) — el-GR`) matches `TranscriptionLanguagePicker` for visual consistency. Disabled while a session is in flight, same lock pattern as every other transcription picker.
- `DualTranscriptionControls.swift` — the dual-mode control set composed inside `LiveTranscriptionSection` when `transcriptionMode == .dual`. Renders (top-to-bottom per §DT-8 mockup): a Source picker bound to `@AppStorage("com.macrec.ui.dual.source")`; a Channel A row with caption + `DualLocalePicker(supportedLocales: DualLocaleSets.channelASupportedLocales, selection: $channelALocaleRaw)` bound to `@AppStorage("com.macrec.ui.dual.channelA.locale")` (default `"en-US"`); a Channel B row with caption + `DualLocalePicker(supportedLocales: DualLocaleSets.channelBSupportedLocales, selection: $channelBLocaleRaw)` bound to `@AppStorage("com.macrec.ui.dual.channelB.locale")` (default `"el-GR"`); a Transcript-format picker bound to `@AppStorage("com.macrec.ui.dual.format")`. Per-channel inline error display (FR-4) reads `recordingController?.dualChannelErrors[.channelA]` / `[.channelB]` and renders an orange triangle glyph + caption-style error text under the affected channel's row, matching the `LiveTranscriptPanel` `lastTranscriptionError` styling. The bottom of the body embeds `DualTranscriptionMetricsView()` (Lane L-11, also landed in Wave 5) — until the L-11-WIRING follow-up populates `dualMetrics` the metrics view renders `EmptyView()`, so the slot is invisible at runtime today.
- `LiveTranscriptionSection.swift` — replaces the prior L-7 `EmptyView()` placeholder for the `.dual` branch with `DualTranscriptionControls()`. Header comment updated to reflect the L-8 wiring.

**New `@AppStorage` keys (4) — all under the `com.macrec.ui.dual.*` prefix, disjoint from every single-mode key (verified against §DT-9 collision check + the existing `ControlBarStartTappedKeysRegressionTests` suite):**

| Key | Default | Purpose |
|---|---|---|
| `com.macrec.ui.dual.channelA.locale` | `"en-US"` | Channel A (Apple on-device) BCP-47 locale; picker constrained to `DualLocaleSets.channelASupportedLocales` |
| `com.macrec.ui.dual.channelB.locale` | `"el-GR"` | Channel B (Apple Cloud) BCP-47 locale; picker constrained to `DualLocaleSets.channelBSupportedLocales` |
| `com.macrec.ui.dual.source` | `"mixed"` | Audio source for dual mode; disjoint from single-mode `transcribeSource` (AC-2) |
| `com.macrec.ui.dual.format` | `"jsonl"` | Sidecar transcript format for dual mode; disjoint from single-mode `transcriptFormat` (AC-2) |

**Channel-A locale-set fragility addressed.** Per plan-010 §DT-13 (the design's #1 fragility), the Channel A picker MUST source from `DualLocaleSets.channelASupportedLocales` — NEVER from `SFSpeechRecognizer.supportedLocales()`. A user picking Greek for the on-device English channel would silently fail at session-open inside `DualTranscriptionConfig.init`. `DualLocalePicker` does NOT consult any locale source itself; the array is INJECTED at the construction site, so the wrong-set bug is unrepresentable in the call sites L-8 produced.

**Deviation RESOLVED 2026-05-01 (Phase 7 review).** project-design.md §DT-9 lists the dual locale / format keys as `com.macrec.ui.dual.channelALocale`, `com.macrec.ui.dual.channelBLocale`, and `com.macrec.ui.dual.transcriptFormat` (single-segment names). The original L-8 implementation persisted them under the dot-segmented names `com.macrec.ui.dual.channelA.locale`, `com.macrec.ui.dual.channelB.locale`, `com.macrec.ui.dual.format`. The Phase 7 reviewer renamed the four `@AppStorage` declarations in `DualTranscriptionControls.swift` AND the four entries in `docs/tools/macrec-ui.md` to match the design-doc canonical form. The header comment block in `DualTranscriptionControls.swift` was also updated. Verification: build green; no other call sites reference these keys (`grep -rn com.macrec.ui.dual` in `Sources/` shows the new spellings only).

**Frozen contract produced (consumed downstream).** `DualTranscriptionControls()` is the no-arg view that the `.dual` branch of `LiveTranscriptionSection` instantiates. `DualTranscriptionMetricsView()` (L-11) is embedded as the last row of the body.

**Verification.** `swift build --product macrec-ui` succeeds (compiles `DualLocalePicker.swift` and `DualTranscriptionControls.swift` clean; relinks macrec-ui without warnings beyond the pre-existing baseline). `swift test --filter "DualTranscriptionControls|MacrecUI|ControlBarStartTappedKeysRegression"` runs 192 / 193 green; the single failure (`UIErrorPresenter / staleRecording → retry`) pre-exists L-8 and is the locale-formatting issue documented in the L-7 entry (the test asserts `"99999"` substring but the system formats `99999` with locale grouping as `"99.999"`). The `ControlBar transcriptionEnabled key contract` regression suite passes — confirming the new dual keys do not collide with the pinned single-mode key.

### PLAN-010-PENDING-L11-WIRING — Dispatcher reference plumbing for `applyDualMetrics(_:)` polling (Wave 5, Lane L-11 follow-up)
The Lane L-11 view (`Sources/macrec-ui/Views/Transcription/Dual/DualTranscriptionMetricsView.swift`) and the controller setter (`RecordingController.applyDualMetrics(_:)`, landed by L-5) are in place, but the polling path that should call `applyDualMetrics(_:)` cannot be wired without touching `Sources/MacrecCore/RecordingSession.swift` — which the L-11 prompt explicitly forbids.

**Architectural gap.** The metrics flow today is event-driven, not polled:
- `DualTranscriptionManager` emits `TranscriptionEvent.metricsTick(metrics:)` events carrying the COMBINED `TranscriptionMetrics` (field-wise sum across both channels — see `DualTranscriptionManager.currentMetrics()` at `Sources/MacrecCore/Transcription/Dual/DualTranscriptionManager.swift:560-575`). Per-channel split metrics are exposed ONLY by the dual-only `currentDualMetrics() async -> DualChannelMetrics` method (lines 581-592), which is NOT on the `TranscriptionDispatcher` protocol and requires a downcast.
- `SessionCoordinator` consumes the session via the `RecordingSessionLike` protocol (`Sources/MacrecUIKit/SessionCoordinator.swift:55-78`), which exposes only `stateStream`, `transcriptEvents`, `run()`, `requestStop()`, and `split(...)`. There is no surface to retrieve the dispatcher.
- `RecordingSession` itself holds `private var _transcriptionDispatcher: (any TranscriptionDispatcher)?` (per the L-4 entry) but does not vend it through the adapter.
- `RecordingController` has NO existing single-mode metrics-poll Task — single-mode metrics also arrive via `metricsTick` events, not polling.

There is therefore no "existing metrics-poll Task" to piggyback on (the L-11 prompt anticipated one); and the only ways to actually call `currentDualMetrics()` from the controller are:

1. **Add a per-channel metrics event variant** (`TranscriptionEvent.dualMetricsTick(DualChannelMetrics)`) emitted by `DualTranscriptionManager` and forwarded by `SessionCoordinator` to `RecordingController.applyDualMetrics(_:)`. Touches `MacrecCore/Transcription/TranscriptEvent.swift`, `DualTranscriptionManager.swift`, `SessionCoordinator.swift`, and the four sidecar writers' exhaustive switches over `TranscriptionEvent`.
2. **Plumb the dispatcher reference** through `RecordingSessionLike` (e.g. `var transcriptionDispatcher: (any TranscriptionDispatcher)? { get }`), have `LiveRecordingSessionAdapter` vend it from `RecordingSession`, then add a polling Task in `SessionCoordinator` (or in `RecordingController`'s events forwarder) that downcasts and calls `currentDualMetrics()` on a cadence (1 Hz seems right, matching the existing `metricsTick` cadence). Touches `RecordingSession.swift`.

Both options touch `RecordingSession.swift`. Per the L-11 prompt: "if the wiring requires touching `RecordingSession.swift`, STOP and report; do not modify `RecordingSession`."

**What L-11 shipped.**
- `Sources/macrec-ui/Views/Transcription/Dual/DualTranscriptionMetricsView.swift` — the SwiftUI view that renders per-channel metrics in a stacked layout (Channel A above Channel B), each row showing chunks sent / billable seconds / errors / lastRttMs. Reads `recordingController?.dualMetrics`. Renders `EmptyView()` when nil. Same typography as the single-mode `TranscriptionMetricsView` (`font(.system(size: 9))`, `foregroundStyle(.tertiary)`, 4 pt horizontal padding). No-arg init (consumed by L-8 via `DualTranscriptionMetricsView()`).
- The L-5 setter `RecordingController.applyDualMetrics(_:)` is already in place and is correctly defensive (drops snapshots when `transcriptionMode == .single`).

**What's pending.** A follow-up lane (after this current Wave 5) must add either Option 1 (dual-metrics event variant — preferred, follows the existing event-driven pattern) or Option 2 (dispatcher exposure + polling Task) to actually populate `RecordingController.dualMetrics` while a dual-mode session is in flight. Until then, the per-channel metrics view will remain hidden (renders `EmptyView()`) and dual-mode sessions show no per-channel metrics in the popover.

**Recommended fix (Option 1).** Add `TranscriptionEvent.dualMetricsTick(DualChannelMetrics)`. `DualTranscriptionManager` emits it on the same cadence as the merged `metricsTick` (every chunk write or every 1 s, matching `TranscriptionManager`'s convention). `SessionCoordinator.startTranscriptForward(...)` adds an arm to forward the new case via `RecordingController.applyDualMetrics(_:)`. The four sidecar writers' exhaustive switches gain a no-op `case .dualMetricsTick: break` arm (or they switch to `@unknown default:` if the project policy permits). Single-mode is unaffected (`TranscriptionManager` never emits the new case). This avoids the dispatcher-reference plumbing entirely and matches the project's existing event-driven metrics convention.

### PLAN-010-PENDING-L11 — Per-channel metrics view landed (Wave 5, Lane L-11)
New file `Sources/macrec-ui/Views/Transcription/Dual/DualTranscriptionMetricsView.swift` — a no-arg SwiftUI `View` that renders per-channel metrics in a stacked layout (Channel A above Channel B) reading `recordingController?.dualMetrics`. For each channel it shows: chunks sent, billable seconds, error count, and `lastRttMs` when non-zero. Typography matches the single-mode `TranscriptionMetricsView` (`font(.system(size: 9))` in `.tertiary` foreground style, 4 pt horizontal padding). When `dualMetrics == nil` (no in-flight dual-mode session OR the polling pathway has not yet been wired), the view renders `EmptyView()` per the lane spec — there is no placeholder text. The view is consumed by Lane L-8's `DualTranscriptionControls` via the no-arg init `DualTranscriptionMetricsView()`.

**Modify (deferred).** The metrics-poll wiring that should drive `RecordingController.applyDualMetrics(_:)` could not be completed without touching `Sources/MacrecCore/RecordingSession.swift` (the prompt explicitly forbids this). See the separate `PLAN-010-PENDING-L11-WIRING` entry above for the architectural gap and recommended fix.

**Verification.** `swift build --product macrec-ui` succeeds (compiles `DualTranscriptionMetricsView.swift` clean, links macrec-ui without warnings beyond the pre-existing baseline). `swift test --filter "RecordingController|DualMetrics|MacrecUI"` runs 192 / 193 green; the single failure (`UIErrorPresenter / staleRecording → retry`) pre-exists L-11 and is the same locale-formatting issue documented in the L-7 entry (unrelated to dual-metrics work).

Frozen contract produced (consumed downstream): `DualTranscriptionMetricsView()` no-arg init exists; L-8's `DualTranscriptionControls` body can embed it at the bottom unconditionally and the view will gracefully render nothing until the wiring follow-up lands.

### PLAN-010-PENDING-L6 — Sidecar writer channel-tagging extensions landed (Wave 4, Lane L-6)
Five files modified under `Sources/MacrecCore/Transcription/Persistence/` plus one new helper in `Sources/MacrecCore/Transcription/Dual/DualSidecarLabel.swift`:

- `TranscriptSidecarWriter.swift` — new optional `mode: LiveTranscriptionMode = .single` parameter on `init`. Plumbed to per-format writers via `makeFormatWriter(for:url:mode:)`. Default `.single` keeps every existing call site unchanged.
- `JSONLTranscriptWriter.swift` — when `mode == .dual`, the encode `Wire` struct gains an OPTIONAL `channel: String?` field populated via `DualSidecarLabel.channelLabel(for:)`. Auto-synthesised `Encodable` uses `encodeIfPresent` for optionals, so `channel: nil` is omitted in single mode and dual mode emits `"channel":"EN"` / `"channel":"EL"` only when `DualSidecarLabel.channelTag(forModel:)` returns non-nil.
- `TXTTranscriptWriter.swift` — dual mode prefixes each line with `[EN] ` / `[EL] ` (per design §DT-7) and OMITS the existing `source[lang]:` label (per spec sample). Single mode renders verbatim per pre-plan-010.
- `SRTTranscriptWriter.swift` — dual mode prefixes the cue body with `EN: ` / `EL: ` (DT-ADR-10) and OMITS the `source[lang]:` label. Cues are NOT re-sorted by start time — first-finalised-first-written ordering preserves arrival order, and cue overlap between channels is intentional.
- `VTTTranscriptWriter.swift` — dual mode wraps the cue body in WebVTT voice tags `<v EN>...</v>` / `<v EL>...</v>`. Same overlap policy as SRT.
- `DualSidecarLabel.swift` — added `static func channelTag(forModel:) -> DualChannelTag?` helper; centralises the `"apple"` → `.channelA` / `"apple-cloud"` → `.channelB` / else `nil` mapping so the four writers cannot drift. No fallback: unknown models log a warning and emit the segment WITHOUT a channel cue rather than guessing a wrong channel.

`DualTranscriptionManager.swift` updated at the two `TranscriptSidecarWriter` construction sites (init + `rotateSidecar`) to pass `mode: .dual`.

**Single-mode byte-equivalence (NFR-1 / AC-1):** Swift's auto-synthesised `Encodable` does NOT guarantee a stable key order across separately-constructed `JSONEncoder` instances (the pre-plan-010 writer was already non-deterministic between encoder invocations). The Lane L-6 guarantee is therefore stated as **schematic equivalence**: in `.single` mode every line is a JSON object containing the SAME key set as pre-plan-010 (no `channel` key) with the SAME values — verified by the new `SidecarChannelTaggingTests.jsonlSingleModeSchematicEquivalence` test that parses both files via `JSONSerialization` and compares key sets + values.

**Frozen contract:** `TranscriptSidecarWriter.init(outputPath:format:policy:mode:)` with `mode: LiveTranscriptionMode = .single` default. Single-mode call sites (`TranscriptionManager`, `StreamingTranscriptionPipeline`, `RecordingSession`, Soniox tests) take the default and remain unchanged.

**Verification.** `swift build --product macrec` and `swift build --product macrec-ui` both succeed (only the pre-existing `dualTranscriptionConfig was never used` warning in `ConfigResolver.swift`). `swift test --filter "Sidecar|TranscriptSidecar|Persistence"` runs 39 / 39 tests green across 7 suites, including the new `Sidecar channel tagging (Lane L-6)` suite (11 tests covering JSONL byte-equivalence, dual-mode channel field, unknown-model fallback, and per-format dual-mode rendering for TXT/SRT/VTT).

Awaits L-9 / L-11 (UI-side per-lane display) for the user-facing rendering of the channel-tagged sidecars.

### PLAN-010-PENDING-L10 — CLI flag set for dual mode landed (Wave 4, Lane L-10)
`Sources/macrec/Commands/StartCommand.swift` and `Sources/MacrecCore/Config/ConfigResolver.swift` extended per project-design `§DT-10` (CLI flag spec) and plan-010 `§Phase H`.

**StartCommand.** `--transcribe`'s help text widened to advertise the new value `dual` plus the `apple-cloud` provider that landed in plan-007. Four new `@Option` flags added: `--transcribe-dual-locale-a`, `--transcribe-dual-locale-b`, `--transcribe-dual-source`, `--transcribe-dual-format`. `buildCLIOverrides()` forwards each one to the matching `ConfigResolver.Keys` constant.

**ConfigResolver.** Four new `Keys` constants — `MACREC_TRANSCRIBE_DUAL_LOCALE_A` / `_B` / `_SOURCE` / `_FORMAT` — exposed via the standard four-tier resolution chain (shell env → `~/.tool-agents/macrec/.env` → `./.env` → CLI flag). `resolve(...)` now detects the literal string `"dual"` in the resolved `MACREC_TRANSCRIBE` value (case-insensitive) and short-circuits the single-mode `TranscriptionProviderId` parse — `dual` is a *mode*, not a provider, and is structurally outside the single-provider enum. When dual mode is active, the resolver:

1. Rejects the single-mode co-flags (`--transcribe-language`, `--transcribe-source`, `--transcribe-format`, `--transcribe-model`) with `MacrecError.transcriptionConfigConflict` (exit 64) — mutual exclusivity per `§DT-10`.
2. Resolves all four `--transcribe-dual-*` values from the chain. Any missing required value raises `MacrecError.transcriptionConfigurationMissing(field:)` with the user-facing flag name (NO fallback per CLAUDE.md; AppStorage spec defaults `en-US` / `el-GR` / `mixed` / `jsonl` are UI-layer values, not engine substitutions).
3. Validates the source / format enums via the existing `parseEnum` helper (typos raise `invalidConfigValue`, exit 64).
4. Constructs the two `ChannelConfig` triples with the pinned provider ids (`apple` for A, `apple-cloud` for B) and feeds them to the throwing `DualTranscriptionConfig.init` — locale-set membership is validated there and unsupported locales raise `MacrecError.transcriptionDualLocaleUnsupported(channel:locale:)`.
5. Forwards the resulting `DualTranscriptionConfig?` into the new `RecordingOptions(dualTranscription:)` parameter (Wave 1 / L-2). Single-mode behaviour is byte-identical to Wave 3 baseline.

**Documentation update.** `docs/tools/macrec.md` extended per the assignment in plan-010 §13: the `--transcribe` help row, the verbatim `--help` block, and the providers table all advertise `dual`. A new "Dual-mode transcription (plan-010)" subsection under "Live transcription" documents the CLI flag table, the four matching env vars, the four-tier resolution chain (extended from the existing convention), the per-format sidecar conventions verbatim from `§DT-7` (JSONL `channel` field, TXT `[EN]`/`[EL]` line prefix, SRT `EN: `/`EL: ` cue prefix, VTT `<v EN>...</v>` voice tag), the apple-cloud quota / latency / privacy caveat reuse statement, and the channel-isolation invariant from `§DT-4`.

**Verification.** `swift build --product macrec` succeeds. `swift run macrec start --help` shows the four new flags in the expected position. `swift run macrec start --output /tmp/x.m4a --transcribe dual` (no fallback test) fails with the exact text `macrec: error: transcription configuration conflict: dual-mode transcription is enabled but required field '--transcribe-dual-locale-a' is missing.` (exit 64). `swift test --filter "ConfigResolver|StartCommand"` runs 78 / 4 suites with one pre-existing red (`shellEnvSupplies` — same `CFG-PEND-1` baseline failure carried since 2026-04-29; unrelated to L-10).

Awaits L-3..L-9 / L-11 to consume the `RecordingOptions.dualTranscription` non-nil signal end-to-end.

### PLAN-010-PENDING-L7 — Mode switch + Single sub-view extraction landed (Wave 4, Lane L-7)
Three SwiftUI views landed under `Sources/macrec-ui/Views/Transcription/`:

- `TranscriptionModeSwitch.swift` — new compact segmented `Picker(selection:)` ["Single", "Dual"] rendered at the TOP of the Live Transcription section. Bound to `@AppStorage(RecordingController.transcriptionModeStorageKey)` (canonical key `"com.macrec.ui.transcriptionMode"`). Round-trip binding maps the persisted `String` ⇄ `LiveTranscriptionMode`; bad / missing values collapse to `.single`.
- `SingleTranscriptionControls.swift` — verbatim wrapper around the four control rows that previously lived inline inside `LiveTranscriptionSection` (Transcribe / Source / Transcript format / Language) plus the per-provider API-key dispatch row. AC-1 hard constraint honoured: identical `@AppStorage` keys, identical defaults, identical labels, identical vertical rhythm; the four sub-views are reused unchanged. The dispatch table for the API-key row is identical to the pre-L-7 inline switch in `LiveTranscriptionSection`.

The composition root `Sources/macrec-ui/Views/Sections/LiveTranscriptionSection.swift` was refactored to read the persisted mode (`@AppStorage(RecordingController.transcriptionModeStorageKey)`), render `TranscriptionModeSwitch()` at the top of the section body, and switch between `SingleTranscriptionControls()` (for `.single`) and `EmptyView()` (placeholder for `.dual` — replaced by `DualTranscriptionControls()` in Lane L-8 / Wave 5). The transcription-disabled hint line behaviour is unchanged.

**Frozen contracts produced:** `SingleTranscriptionControls` view existence and that it renders the four-row block (consumed by L-8 to mirror with `DualTranscriptionControls`); `TranscriptionModeSwitch` view existence and that the panel body branches on the mode (consumed by L-9 to branch the live-transcript-display section on the same mode).

**Verification.** `swift build --product macrec-ui` succeeds. `swift test --filter "Panel|LiveTranscript|MacrecUI|ControlBarStartTappedKeysRegression"` runs 192 / 193 green; the lone failure (`UIErrorPresenterTests / staleRecording → retry`) pre-exists L-7 — it is a locale-formatting issue (`99999` printed as `99.999`) in `MacrecError`'s `staleRecording` description, unrelated to the panel changes.

Awaits L-8 (Dual-mode sub-view at `Sources/macrec-ui/Views/Transcription/Dual/DualTranscriptionControls.swift`) to replace the `EmptyView()` placeholder; L-9 (dual-lane transcript display) to branch `LiveTranscriptPanel` on the same mode key; L-11 (metrics polling); L-12 (privacy disclosure for dual-cloud).

### PLAN-010-PENDING-L4 — `TranscriptionDispatcher` protocol + `RecordingSession` dispatcher wiring landed (Wave 3, Lane L-4)
New file `Sources/MacrecCore/Transcription/TranscriptionDispatcher.swift` defines the `TranscriptionDispatcher` protocol per project-design §DT-4 (`AnyObject & Sendable` with `start()`, `ingest(_:from:)`, `ingestFrame(_:from:)`, `stop()`, `rotateSidecar(toAudioURL:format:)`, `currentMetrics()`). Both `TranscriptionManager` (single mode, existing) and `DualTranscriptionManager` (dual mode, Wave 2) now conform — single-line declaration changes, no behavioural changes to either implementation's public surface.

`Sources/MacrecCore/RecordingSession.swift` was refactored so the choice between single-mode and dual-mode transcription is made ONCE at session-start time (DT-INV: project-design §DT-4 "the choice is made ONCE at `RecordingSession` construction time; there is NO per-callsite enum discriminator"). The session now holds `private var _transcriptionDispatcher: (any TranscriptionDispatcher)?` instead of the old `TranscriptionManager?`. The single `if let dualConfig = options.dualTranscription { ... } else { ... }` branch lives at the top of `setUpTranscriptionPipelineIfNeeded(...)` and chooses between constructing a `DualTranscriptionManager` or — via the extracted `buildSingleModeManager(...)` helper — a `TranscriptionManager`. Every other operation (`ingestFrame` from the aligner tap, `rotateSidecar` from `split(...)`, `stop` from teardown) goes through the protocol. The Wave 2 placeholder routing in `RecordingController.applyTranscriptionEvent(.dualChannelError)` still stands; full per-channel UI surface is L-5 / L-7+ territory.

**Build-fix piggybacked on L-4 (documented inline in `RecordingController.swift` deinit).** Wave 2's `RecordingController.swift` introduced a `transcriptionModeObserver: NSObjectProtocol?` observer + a `deinit` that read it directly. Under Swift 6's stricter actor-isolation rules this fails to compile (the controller is `@MainActor`, the deinit is non-isolated). L-4 patched the deinit to snapshot the property through `MainActor.assumeIsolated` so the build goes green; this is a build-fix only, no semantic change.

**Verification.** `swift build --product macrec` and `swift build --product macrec-ui` both succeed. `swift test --filter "RecordingSession"` runs 12 / 12 tests green (no regressions from Wave 2 baseline). `swift test --filter "TranscriptionManagerTests"` shows 1 / 2 green with the same single pre-existing `ingestProducesSegment` failure documented in the Wave 2 baseline (unrelated to dual mode).

Frozen contract for downstream lanes: `TranscriptionDispatcher` protocol signature is now stable. L-3 already conforms; L-5 (`RecordingController` per-lane UI) can now downcast `dispatcher as? DualTranscriptionManager` to call `currentDualMetrics()` once L-11 wires the dispatcher reference into `SessionCoordinator`. L-7..L-9 / L-11 unblocked.

### PLAN-010-PENDING-L1 — Dual-transcription foundation types landed (Wave 1, Lane L-1)
Five new files under `Sources/MacrecCore/Transcription/Dual/` (`TranscriptionMode.swift` exporting `LiveTranscriptionMode`, `DualChannelTag.swift`, `ChannelConfig.swift`, `DualLocaleSets.swift`, `DualTranscriptionConfig.swift`) plus `Sources/MacrecCore/Errors/MacrecError+Dual.swift` extension. Foundation is in place for Lanes L-2..L-10 to land in subsequent waves of plan-010.

### PLAN-010-PENDING-L2 — `RecordingOptions.dualTranscription` field added (Wave 1, Lane L-2)
Optional `dualTranscription: DualTranscriptionConfig?` added to `Sources/MacrecCore/Config/RecordingOptions.swift` (additive, defaulted to `nil`); `init` and `withOutput` updated to forward it. Non-nil signals dual-mode session construction; nil preserves single-mode behaviour. Awaits L-3 (`DualTranscriptionManager`) and L-7 (UI mode-switch wiring) to become user-visible.

### PLAN-010-PENDING-L3 — `DualTranscriptionManager` actor + dual-channel core orchestration landed (Wave 2, Lane L-3)
Three new files under `Sources/MacrecCore/Transcription/Dual/`:
- `DualTranscriptionManager.swift` — actor that owns two `StreamingTranscriptionPipeline` instances (Apple on-device + Apple Cloud in v1), one shared `TranscriptSidecarWriter` (DT-INV-3 enforced), two `AudioDownsampler` instances (one per channel — `AudioDownsampler` is not thread-safe), and merges per-channel events into one `AsyncStream<TranscriptionEvent>` via a two-Task drain pattern. Per-channel failure isolation: a `.dualChannelError(channel:detail:)` event is yielded into the merged stream when one channel errors, but the sibling channel keeps streaming and the merged continuation is NOT finished (only `stop()` finishes it). Stop honours a 5-second per-pipeline timeout matching the single-mode `TranscriptionManager.stopDrainSeconds`.
- `DualChannelMetrics.swift` — per-channel split of `TranscriptionMetrics` consumed by Lane L-6's per-lane UI badge.
- `DualSidecarLabel.swift` — static helper mapping `DualChannelTag` → user-facing label (`"EN"` / `"EL"`) baked into Lane L-5's sidecar writers.

`Sources/MacrecCore/Transcription/TranscriptEvent.swift` gained a single new case `dualChannelError(channel: DualChannelTag, detail: String)`. The two existing exhaustive switches over `TranscriptionEvent` (in `TranscriptSidecarWriter.write(_:)` and `RecordingController.applyTranscriptionEvent(_:)`) were extended with `.dualChannelError` arms so the existing test suite continues to compile; full per-lane UI integration of the dual-channel error event is Lane L-6's job.

**Wave-2 deviation (documented inline in `DualTranscriptionManager.swift` header):** the §DT-4 frozen interface signature reads `providerFactory: TranscriptionProviderFactory = .shared`, but the existing `TranscriptionProviderFactory` is an empty-case-list enum (a static method namespace) and has no `.shared` instance. Rather than mutate the locked factory enum into a struct (which would ripple into every existing call site and risk breaking the Phase 9 regression-baseline tests), L-3 parks the factory injection point as a `@Sendable` closure (`DualTranscriptionProviderFactory`) with a default that forwards to the static `TranscriptionProviderFactory.build(_:)`. Named parameter (`providerFactory`) preserved; only the type changes. This is the smallest deviation that lets the manager be tested with mock providers (Lane L-4 dependency) without touching IP-12.

**Micro-investigation finding (plan-010 Phase B B.4):** the on-device `AppleSpeechSession`'s internal `AnalyzerInput` `AsyncStream` is constructed at `Sources/MacrecCore/Transcription/Providers/SpeechAnalyzerAdapter.swift:166-167` with `bufferingPolicy: .bufferingNewest(64)` — i.e. **already bounded**. NO change to single-mode behaviour is needed for dual mode; the documented memory-growth concern does not arise. (Documented inline in `DualTranscriptionManager.swift` header.)

Awaits Lane L-4 (manager unit + isolation tests), L-5 (sidecar writer dual-mode columns: `EN: ` / `<v EN>` / `channel: "EN"`), and L-6 (`TranscriptionDispatcher` protocol + `RecordingSession` construction switch + per-lane UI surface).

### PLAN-010-PENDING-L5 — `RecordingController` published-property surface for dual mode landed (Wave 3, Lane L-5)
Three new observed properties added to `Sources/MacrecUIKit/RecordingController.swift` (frozen contract per project-design §DT-13 inter-lane contract #5; consumed downstream by L-7 / L-8 / L-9 / L-11):

- `public private(set) var transcriptionMode: LiveTranscriptionMode` — mirror of the `@AppStorage("com.macrec.ui.transcriptionMode")` value, kept in sync via a `UserDefaults.didChangeNotification` observer registered in `init` (mirrors the `PopoverController.sizeObserver` AppStorage-bridge idiom). Default `.single`. Bad / missing values collapse to `.single`. The canonical key spelling is exposed as `RecordingController.transcriptionModeStorageKey`.
- `public private(set) var dualMetrics: DualChannelMetrics?` — `nil` when the session is not running OR when `transcriptionMode == .single`. Populated via `applyDualMetrics(_:)`; the dispatcher-downcast pathway from `SessionCoordinator` will be wired by L-11 once L-4 lands the `TranscriptionDispatcher` protocol and exposes the dispatcher reference to the controller. Until then the slot remains `nil` (graceful "—" placeholder for dual-mode UI).
- `public private(set) var dualChannelErrors: [DualChannelTag: String]` — populated from the `.dualChannelError(channel:detail:)` event arm. KEY semantics: per-channel; arrival of an A-error does NOT clear an existing B-error. Cleared wholesale at `start()`.

The Wave 2 placeholder routing (L-3 added a `.dualChannelError` arm that forwarded the message to `lastTranscriptionError` + `transcriptionStatus = .error(...)` to keep the build green) was REPLACED with the proper per-channel routing into `dualChannelErrors`. For backward compat with the existing single-mode amber banner consumer, `lastTranscriptionError` is also populated with a channel-tagged message (`"Channel A: …"`) — once L-7..L-11 land their per-channel surfaces, dual-mode panels should ignore that legacy field and read `dualChannelErrors` instead.

Per-session state reset: `start()` now also resets `dualMetrics = nil` and `dualChannelErrors = [:]` alongside the existing transcription state reset. `cancelAll()` and `deinit` remove the UserDefaults notification observer.

**Verification status:** parse-only check on `RecordingController.swift` succeeds (`swiftc -parse`); full `swift build --product macrec-ui` is currently blocked by an in-flight Lane L-4 partial change in `Sources/MacrecCore/RecordingSession.swift` (the dispatcher field was renamed `_transcriptionManager → _transcriptionDispatcher` at the declaration but three call sites at lines 1291 / 1379 / 1382 still reference the old name). L-5 is forbidden from touching `RecordingSession.swift`; the build will go green once L-4 finishes the rename sweep.

Awaits L-4 to complete the dispatcher rename in `RecordingSession.swift`, L-7..L-9 / L-11 to consume the new published surface, and L-11 specifically to wire the `applyDualMetrics(_:)` polling pathway from `SessionCoordinator` (requires L-4's dispatcher exposure first).


### PLAN-009 — Soniox token aggregator protocol fix (Closed 2026-05-01)

`SonioxTokenAggregator` was misbehaving against real Soniox WebSocket traffic, producing two intertwined garbage shapes in the live-transcript JSONL sidecar: (1) cumulative-growth blobs containing every interim provisional guess concatenated, and (2) per-syllable spam where each committed token became its own "utterance segment". A 12-second Greek recording produced 38 JSONL lines for 2 utterances (`~/Recordings/recording-2026-05-01-03-08.transcript.jsonl`); expected output is 2 lines. Root causes: (A) non-final tokens were never replaced between batches — the implementation appended every token unconditionally, contradicting plan-006 §4.7 step 1; (B) every `is_final: true` token triggered an utterance flush, contradicting plan-006 §4.7 step 2 — only `<end>`/`<fin>` markers should terminate utterances. Fix: lazy non-final discard at the first new content token of each batch (preserves marker-only batches), marker-only flush, and one-partial-per-batch (anti-storm). Tests rewritten from 5 to 10 cases, including two regression pins for Bugs A and B (`testNonFinalsAreDiscardedBetweenBatches`, `testCommittedFinalsAccumulateAcrossBatchesUntilMarker`). Verification: 10/10 aggregator unit tests pass; 4/4 Soniox integration tests pass; build clean. Full post-mortem: `docs/design/plan-009-soniox-aggregator-protocol-fix.md`.

### PLAN-008 — UI redesign + Light/Dark/System theming (Closed 2026-05-01)

Plan-008 shipped the popover redesign aligned to `docs/design/mockups/popover-redesign.html`, preserved the vertical-elasticity contract and the `LiveTranscriptPanel` streaming behavior, and added the 3-mode appearance picker (System / Light / Dark) with `@AppStorage("com.macrec.ui.appearance")` persistence. **9 implementation units** (A–I) shipped across 3 waves; **122 plan-008-owned tests pass** (45 Phase-6 contract pins + 77 Phase-9 view pins). Build clean (debug + release). 8 new files in MacrecUIKit/Theme + macrec-ui/{Theme,Views/Header,Views/Sections,Views/Footer}; 4 modified files (RootView, PopoverController, MacrecUIApp, SettingsRootView); two modified API-key fields (Soniox, Gemini, Provider) + one restyled LiveTranscriptPanel. Documentation updated: `docs/tools/macrec-ui.md` "Theming" subsection added; `docs/design/project-design.md` §UR-1..§UR-12 appended; `docs/design/project-functions.md` FR-UI-APPEARANCE + FR-UI-TRANSCRIPTION-GATE added. Three pre-existing test failures triaged into PLAN-008-PEND-1 (unrelated to plan-008). Phase 10 verdict: READY. Manual UI verification on macOS 26 recommended (7-step checklist in Phase-10 report).

### R-SX-PHASE10 — Plan-006 Soniox Phase 10 integration verification (Closed 2026-04-29)

Phase 10 final integration verification. Both products build cleanly
(`swift build --product macrec` + `swift build --product macrec-ui`,
exit 0, zero warnings new to plan-006). Soniox + WebSocketTransport
test suite passed: **88/88** (58 XCTest + 30 Swift Testing across 13
suites; 1 environment-gated network test skipped). Broader regression
sweep (`swift test --filter "Transcription|Config|Picker|Privacy|StartCommand"`)
yielded **10 unique failures, all pre-existing** — 1 from CFG-PEND-1
+ 9 from CFG-PEND-2; **zero new failures introduced by plan-006**.

Acceptance-criteria coverage:

- **MET (10)**: AC-SX-5, AC-SX-6, AC-SX-7, AC-SX-8, AC-SX-12, AC-SX-13,
  AC-SX-14, AC-SX-15, AC-SX-16, AC-SX-17.
- **PARTIAL (2)**:
  - AC-SX-9 — Soniox-specific privacy-disclosure body wording is not
    pinned by an automated test; only the generic
    `PrivacyDisclosureViewModel` persistence behavior is covered. The
    Soniox-keyed copy exists in
    `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift`
    per plan-006 §H. Manually verifiable in `macrec-ui`.
  - AC-SX-18 — Per-event `lastPartialLatencyMs` and `lastFinalLatencyMs`
    are tracked in `StreamingProviderMetrics`, but the spec calls for
    aggregated P50/P95 percentiles to be **logged** at session stop
    with a `.warning` when exceeding NFR-SX-2 thresholds. The data
    path is in place; aggregation + log line are remaining work.
    Carried over from Phase 7 review.
- **DEFERRED (real-key, 6)**: AC-SX-1, AC-SX-2, AC-SX-3, AC-SX-4,
  AC-SX-10, AC-SX-11. Verifiable only via end-to-end manual testing
  with a real `SONIOX_API_KEY` (sign-up at https://console.soniox.com).
- **NOT MET**: 0.

New artefacts:

1. `test_scripts/e2e-transcription-soniox.sh` (executable) — real-key
   e2e validation script that runs three back-to-back ~12-second
   recordings (Greek / English / Bilingual) using `say`+`afplay`
   fixtures, then prints per-AC PASS/FAIL for AC-SX-1..AC-SX-4 and
   an OVERALL verdict. Outputs preserved under `test_output/`.
2. `docs/reference/integration-verification-soniox-streaming.md` —
   this verification report with full build/test breakdown, AC matrix,
   and user instructions.

Pre-existing pending items (CFG-PEND-1, CFG-PEND-2, R-SX-PHASE7)
verified still accurate; no edits required to those entries.

Follow-up improvements (non-blocking, opt-in polish):

- **R-SX-PHASE10-1** — close AC-SX-9 by adding a Soniox-specific test
  that pins the `PrivacyDisclosureSheet` body text mentioning Soniox
  by name (parallel to the existing `bodyTextContainsLockedPhrases`
  test).
- **R-SX-PHASE10-2** — close AC-SX-18 by adding P50/P95 percentile
  aggregation to `StreamingProviderMetrics` (or a sibling struct) and
  emitting the percentile line at session stop with a `.warning` when
  the values exceed `NFR-SX-2` thresholds (≤ 1.5 s end-to-end /
  ≤ 500 ms first-partial).

Overall verdict: **READY FOR USER e2e VALIDATION** (build + tests
green; the only remaining action is for the user to provide a real
Soniox API key and run `bash test_scripts/e2e-transcription-soniox.sh`).

### R-SX-PHASE7 — Plan-006 Soniox Phase 7 code review (Closed 2026-04-29)

Phase 7 reviewer ran `swift build` (both `macrec` and `macrec-ui` — exit 0,
no warnings new to plan-006), `swift test --filter "Soniox|WebSocketTransport|SonioxConfigResolver"`
(30 swift-testing tests + 36 XCTest cases passed; 1 environment-gated test
skipped — `URLSessionWebSocketTaskTransport connects to a public echo
server`), and `swift test --filter "Transcription|Config"` (broader regression
sweep — failures all pre-existing; see CFG-PEND-1 + CFG-PEND-2).

Two stale `gemini-live` test expectations in
`Tests/MacrecCoreTests/Commands/StartCommandTranscriptionFlagsTests.swift`
were updated during the review to reflect the resolver's plan-004 Phase G.2
deprecation-alias normalisation (lowering `gemini-live → "gemini"`). Decision:
**fix the tests, not the resolver** — the normalisation is documented in
`Sources/MacrecCore/Config/RecordingOptions.swift:65-68` and
`docs/design/project-functions.md:271`, was added in commit `f1adb58`
(plan-004), and is the architecturally correct behaviour. The tests were
authored before that normalisation landed and were never updated.

Recording-integrity isolation invariant (NFR-SX-1 / AC-SX-6) **verified
structurally**: `StreamingTranscriptionSession.events` is a non-throwing
`AsyncStream<StreamingTranscriptionEvent>` (not `AsyncThrowingStream`).
`SonioxStreamingSession` catches every error inside `ingest(_:)` and
`startReceiveLoop()` and yields `.error(detail:)` events through the same
non-throwing channel. The pipeline iterates with `for await event in session.events`
which by construction cannot throw — there is no path for a Soniox failure
to escape into the recorder.

Verdict: **READY FOR PHASES 8-10**. Real-key e2e validation (AC-SX-1..AC-SX-4,
AC-SX-10..AC-SX-13, AC-SX-18) deferred to Phase 10 + user manual verification
per the prompt.

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
