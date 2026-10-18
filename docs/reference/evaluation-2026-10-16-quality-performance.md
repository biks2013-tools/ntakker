# ntakker — Quality, Speed & Resource-Efficiency Scan (2026-10-16)

**Request:** "scan the application and detect improvements in quality and speed, as well as areas where the application could be better in terms of performance and more efficient in resource use."
**Commit reviewed:** `bf69be5` (master; working tree only touches `.serena/project.yml`, `CLAUDE.md`).
**Method:** four parallel read-only review passes (capture/encoding/aligner · transcription core + providers · Soniox/Asking/Config/Logging/Daemon/CLI · UI), each re-checking the still-open findings of the [2026-06-12 evaluation](evaluation-2026-06-12-summary.md) and hunting for new ones. The highest-impact claims (CAP-1, CAP-4, TR-1, TR-3, TR-6, INF-4) were re-verified by hand against the source. `swift build -c release` green (45 s clean-ish, binaries 17 MB `ntakker` / 13 MB `ntakker-cli`; `.build` is 4.7 GB).

**New finding IDs:** CAP-1…18 (capture), TR-1…20 (transcription), INF-1…15 (infra/Soniox/Asking/CLI), UI-1…9 (UI) — **62 new findings**. Prior-finding status tables are at the end.

---

## 1. Fix-first list (correctness / data loss — these also hurt perceived quality)

| # | ID | Sev | Where | Problem | Effort |
|---|----|-----|-------|---------|--------|
| 1 | **CAP-1** | ~~High~~ *fixed (plan-021 T1)* | `Aligning/HostClockAligner.swift:458-462` | `headPTS` only re-anchored when the buffer is empty; with 1024-frame buffers vs 4800-frame windows leftover is almost never empty, so a gap (dropped buffer, SCStream restart, PTS jump) is collapsed, never silence-filled → that track is **permanently early** for the rest of the recording. Probable cause of the 2 failing `HostClockAlignerStress` gap-fill tests. Place samples by PTS (as `SoftwareAECProcessor.feedReference` does). | M |
| 2 | **CAP-2** | ~~High~~ *fixed (plan-021 T1)* | `HostClockAligner.swift:536-566` | If one source stalls, `sourceReady` stays false → nothing emitted, the other source's buffer grows unbounded and is fully copied per append (~180 MB/s memcpy after 10 s). Add a max-skew (300–500 ms) → silence-fill the stalled side, cap backlog. | M |
| 3 | **TR-1** | High | `Providers/ParakeetTranscriptionProvider.swift:113-119`, `WhisperKitTranscriptionProvider.swift:129` | `maxInFlightPerSource = 2` lets two concurrent inferences run on one non-thread-safe engine (FluidAudio `AsrManager` mutates inout decoder state across awaits). Guaranteed at cold start. Serialize on-device inference. | S |
| 4 | **TR-3** | High | `Azure/Realtime/AzureOpenAIRealtimeSession.swift:153-159` | `finish()` closes immediately: no `input_audio_buffer.commit`, no wait for pending `transcription.completed` → last utterance lost on every stop. | S |
| 5 | **UI-1** | High | `Views/Asking/SessionExporter.swift:61-90`, `SessionCoordinator.swift:604-631` | Save looks for `<stem>.part01.transcript.jsonl` (doesn't exist — only audio is renamed), ignores later parts and `.system/.microphone` sidecars → `transcript.md` falls back to the 100-segment in-memory list; part-1 sidecar left behind. | M |
| 6 | **INF-1** | High | `Live/Soniox/SonioxStreamingSession.swift:279-285, 336-344` | Soniox reconnect replays the whole 5 s ring (already-transcribed audio) to a fresh session without resetting the aggregator → duplicated text; chunks arriving during replay are never sent; 5 s ring smaller than worst-case outage. | M |
| 7 | **INF-3** | ~~Med (verify)~~ *not reproduced (plan-019 T2: `test_scripts/ws-resource-timeout-probe.swift` keeps an upgraded socket open past a 3 s resource timeout, with traffic and across a 6 s idle gap)* | `URLSessionWebSocketTaskTransport.swift:82` | `timeoutIntervalForResource = 300` may kill every WebSocket at 5 min → reconnect storm (×INF-1 duplicates). Set `.infinity`, verify with a >6 min session. | S |
| 8 | **UI-4** | Med | `SessionCoordinator.swift:239-245` | All control events (state, segmentCompleted, errors) share a `.bufferingNewest(16)` stream with transcript partials → can be dropped; a dropped `.recording` leaves the controller stuck in `.starting` (Stop disabled) thanks to the H1 gate. | S–M |
| 9 | **TR-8 / TR-9** | Med | `SourceSplitTranscriptionManager.swift:106-109`; `TranscriptionManager.swift:350-370` | Source-split stops children sequentially (2×5 s) inside a 5 s outer budget → mic drain abandoned. F18 deadline uses `withTaskGroup`, which waits for non-cancellable children (CoreML, model load) — deadline not real. | S |
| 10 | **CAP-5** | ~~Med~~ Low — *not reproduced (plan-018 T6: 3 s files measure 3.0000 s before and after)* | `Encoding/M4ARecorder.swift:203, 689`; `HostClockAligner.swift:289-294` | `endSession(atSourceTime:)` uses last buffer's *start* PTS → final ~100 ms trimmed on every m4a and every split seam; `flush()` discards ≤99 ms leftover. | S |
| 11 | **CAP-7 / CAP-8** | Med | `WAVRecorder.swift:122-140`, `CAFRecorder.swift:115-125`, `M4ARecorder.swift:210-216` | WAV/CAF write errors (disk full) only logged — finalize reports success on a truncated file; M4A `markAsFinished()` without draining `pending`. | S |
| 12 | **TR-4** | Med | `AppleCloudTranscriptionProvider.swift:263-282, 465-476` | 55 s rotation ignores audio until the old final arrives → ~1.5–3 s lost per minute (3–5%). | M |
| 13 | **TR-5 / TR-6 / TR-7** | Med | `AppleSpeechTranscriptionProvider.swift:293-315`; `TranscriptSanitizer.swift:24-39` | Dual-locale reconciliation never matches (both languages emitted); sanitizer strips `[` from `[Speaker 1]` (verified) and deletes genuine one-word answers ("yeah", "ok") in 2 s chunks. | S–M |
| 14 | **INF-4** | Med | `Daemon/Daemonizer.swift:184` | `umask(0)` in the daemon → transcripts/audio created 0666 in `--detach` mode. Use `umask(0o077)`. | S |
| 15 | **CAP-10** | Med | `SCKitSystemAudioSource.swift:419-436, 527` | `restartStream` has no in-progress latch → overlapping restarts can leak a live SCStream. | S |
| 16 | **INF-2** | Med | `SonioxStreamingSession.swift:330-342`, `SonioxKeepaliveTimer.swift:49` | `finish()` racing a reconnect leaves a fresh socket + a 10 s keepalive loop alive forever. | S |
| 17 | **INF-7** | Med | `Asking/AskConfig.swift:125,134,149,211` | Force-unwrapped `URL(string: env…)!` — a malformed `*_BASE_URL`/`OLLAMA_HOST` crashes the menu-bar app. | S |
| 18 | **UI-2 / UI-3** *(fixed, plan-023)* | Med | `PopoverStatusBar.swift:108-129`, `RecordingController.swift:682-689` | Pause/Resume/Split are unreachable in the popover (ControlBar only shown idle/failed). Once exposed, pause tears down level meters and flashes the "stopped" UI. | S |

## 2. Highest-leverage speed & resource-efficiency improvements

| # | ID | Where | Today | Improvement | Effort |
|---|----|-------|-------|-------------|--------|
| 1 | **CAP-3** *(fixed, plan-022)* | `Capture/SoftwareAECProcessor.swift:584-649` | NLMS does 4 full passes over 4096 taps per sample ×2 channels ≈ **1.6 G MAC/s** + ~384k vDSP calls/s while AEC is on | Running-sum `refPower` (drop `svesq`), fuse leak+update (`vDSP_vsmsma`/block leakage), process mono once (CAP-6). Long-term: frequency-domain block filter (~1/50 cost). Also move the NLMS pass out of the lock (CAP-11, 2–4 ms stalls of the SCStream thread). | M / L |
| 2 | **TR-2** *(fixed, plan-022)* | `TranscriptionManager.swift:38-44` + on-device providers | ~2 s chunks padded to 15 s (Parakeet) / 30 s (Whisper) → **7.5–15× wasted encoder compute**, ~1,800 encoder passes/h/source; words cut at chunk edges | Per-provider chunk policy (10–15 s on-device, cut at silence) — big CPU/ANE/battery win and better accuracy. | M |
| 3 | **TR-11** (+F28/F29) *(fixed, plan-022)* | `RecordingSession.swift:1091-1143, 1201-1210` | WhisperKit large-v3 (626 MB) / Parakeet (~600 MB) reloaded + ANE warm-up on **every** recording, twice in source-split mode; first seconds lost while loading | Process-wide model cache actor with idle eviction (~10 min) + warm-up at pipeline start. | M |
| 4 | **C1 + CAP-1/2** *(fixed, plan-021)* | `HostClockAligner.swift:353, 425-461, 719-761` | Every ingest/emit rebuilds full buffers with scalar loops (~300 allocs/s, 4–5 MB/s steady; unbounded under stall) | One ring-buffer rewrite with PTS placement + max-skew. Fix the stress-test baseline first (plan-017 T17 rationale). | M |
| 5 | **CAP-4** | `SCKitSystemAudioSource.swift:608` | `minimumFrameInterval = 1/CMTimeScale.max` ≈ 0 → "as fast as display refresh": likely 60–120 discarded 2×2 video frames/s with compositor/IOSurface cost | `CMTime(value: 1, timescale: 1)` (or larger). Verify `.screen` callback count in Instruments. | S |
| 6 | **CAP-6** *(AEC part fixed, plan-022)* | `AVMicrophoneSource.swift:334` | Mono mic upmixed to stereo at capture → 2× mic memory/copies through AEC, aligner, summer; AEC runs 2 identical filters | Capture native channel count; upmix only at encoder. Halves AEC cost. | M |
| 7 | **M1/M2/UI-5** *(fixed, plan-022)* | `LevelMeterPublisher.swift:149-178`, `PopoverStatusBar.swift:261-316` | 30 Hz observable writes always (108k/h) even with popover closed; two 30 Hz `TimelineView`s animating `sin(t·9)` regardless of audio; linear RMS → silence ≈ speech visually | dBFS mapping, dedup unchanged values, pause when popover hidden, data-driven leaf view (removes the TimelineViews). | S–M |
| 8 | **H2** | `SessionExporter.swift:34, 259-285` | Save copies then deletes audio on the main actor (1 h WAV ≈ 690 MB) → beachball | `FileManager.moveItem` (same-volume rename ≈ instant) + run off-main. | S |
| 9 | **A6/A7 + CAP-13/14** *(fixed, plan-022)* | `Logging/LoggerFactory.swift:449, 546-559`; `AVMicrophoneSource.swift:554, 619`; `RecordingSession.swift:1261` | Synchronous `handle.write` under a lock + `DateFormatter` per line; no rotation; `mic_health` INFO every second; per-transcript-event INFO with `String(describing:)` | Async batched writer with cached formatter + size rotation; demote hot logs to `.trace/.debug`. | S–M |
| 10 | **F17** | `SonioxStreamingSession.swift:214` | Unconditional 2 s sleep on every Soniox stop | Wait for the final `finished` frame with a 2 s cap. | S |
| 11 | **CAP-9** (verify) | `M4ARecorder.swift:390`, `RecordingSession.swift:821` | `shouldOptimizeForNetworkUse = true` on fragmented output likely rewrites the whole file at finalize (time ∝ length; split allows only 5 s) | Set `false` (local files), or measure 1–2 h finalize. | S |
| 12 | **TR-12** | `AzureOpenAIRealtimeSession.swift:128` | 48→16→24 kHz double resample (converter rebuilt per chunk, F3); 24 kHz stream with nothing above 8 kHz | Direct stateful 48→24 kHz. | M |
| 13 | **TR-14 / F1** *(fixed, plan-022)* | `RecordingSession.swift:1304-1328` | One `Task` per frame, unbounded and unordered; ~46 MB/min pile-up on a network stall | One bounded `AsyncStream` + serial consumer per source, finished/awaited before `dispatcher.stop()`. | M |
| 14 | **Smaller hot-path allocs** | CAP-12, CAP-15, CAP-16, CAP-17, C3, TR-18/INF-11 | Per-buffer `[[Float]]`/malloc in AEC extraction; mix computed twice in `.mixed`; stereo-split builds 4 arrays + new format description per frame, `pending.removeFirst()` O(n); `stateQueue.async`+`Date()` heartbeat per buffer (~94 closures/s); `PCMConvert.floatToInt16LE` 3 allocations/chunk; `JSONDecoder` per Soniox frame | Pointer access + `CMMemoryPool`, share the mix, cache format description + Deque, atomic `mach_absolute_time` heartbeat, in-place clamp into `Data(count:)`, static decoders. | S each |
| 15 | **UI-7 / UI-8 / M3 / M8** | `AskingModeView.swift`, `ResizeHandle.swift`, `LiveTranscriptPanel.swift`, `RecordingStarter.swift` | Per-token main-actor publish + full-string `onChange` (O(L²)); `@AppStorage` write + sync layout per drag tick; non-lazy transcript list with animated scroll per partial; `.env` parsed up to 7× per Start click | Batch tokens ~50 ms; commit size on drag end; `LazyVStack`; read once from `ProcessInfo`. | S |
| 16 | **INF-9 / A13** | `Asking/AskPromptBuilder.swift:104-116` | `.full` context: repeated `removeFirst()` + full `joined()` — ~300 MB copied per question on a 3 h meeting (50–150 ms on main) | Walk newest→oldest summing `utf8.count`, join once. | S |

## 3. Resilience / safety items (non-perf, worth bundling)

- **TR-10** — circuit breaker half-open resets counter to 0 (5 more doomed calls ×3 retries per cycle, error event per failure); Gemini 401/403 never trips permanently. **TR-16** — Azure batch `Retry-After` uncapped (>3 min slot hold). **F31** — retry policy now duplicated 3× (Azure, ElevenLabs, Gemini) → shared policy.
- **TR-13** — Azure realtime replays 5 s of already-committed audio on (even planned 58-min) reconnect → duplicate finals.
- **TR-17 / F24 remainder** — all four sidecar writers still `createFile(contents:nil)` → silent truncation of an existing sidecar. **TR-20** — writer goes permanently broken on first I/O error with only a log line.
- **INF-5** — `start --detach` exits 0 before TCC/PID/writer checks; add a readiness pipe. **INF-13** — `stop` removes the PID file regardless of who owns it. **INF-14** — `SFSpeechRecognizer.supportedLocales()` runs before `fork()` (worsens A1).
- **INF-6** — Gemini *Ask* client still sends the API key in the URL query (F13 fixed only the STT path). **INF-15** — all OSLog output `%{public}@`, including transcript text at debug.
- **CAP-18** — mic `wasDisconnectedNotification` not observed in core → silent mic stall (feeds CAP-2). **UI-9** — cost estimate shown for free on-device providers. **UI-6** — Ask "Full"/"15 min" and Save transcript only see the 100-segment UI list.

---

## 3b. Found while fixing (2026-10-17)

- **M4A busy loop (High, fixed in plan-021 T1b).** `M4ARecorder` used `requestMediaDataWhenReady`. With a push producer the callback returned immediately whenever nothing was pending, and AVFoundation called it again at once.
  - Measured with `ntakker-cli`: an M4A recording (the default format) ran at about 100 % CPU, against about 3 % for WAV.
  - After the fix: 4.2 % CPU.
- **`JSONLTranscriptReader` tombstone bug (High, fixed in plan-020 T6a).** The reader dropped every segment rewritten via tombstone-and-append, so Save lost every grown batch-provider segment.
- **`RecordingSessionTests` hang.** Besides the aligner and the M4A loop, two tests had no stop condition when the runner holds the TCC grants. Fixed in plan-021 T3.
- **C5 (2026-06-12) fixed:** `lastDriftSec` now reports the residual track skew.
- **AEC never cancelled echo (High, fixed in plan-022 T4).** The NLMS reference window for mic sample `p` started at `p + 1`, so it read future reference audio or audio 85–170 ms old. On a synthetic echo the old filter left more energy than the echo itself. The window now ends at `p`, and the ring grew from 2L to 4L.
- **CLI rejected `--transcribe parakeet` and `apple-cloud` (Medium, fixed in plan-022).** `TranscriptionProviderId` lacked both cases, although the factory built both providers.
- **`--transcribe-source mic` refused without `--mic-device` (Medium, fixed in plan-023 T10).** The resolver treats an unset mic device (meaning "system default") as "mic disabled". This is the cause of the baseline failure "Shell env supplies transcription keys".

## 4. Suggested attack order

1. **Quick, high-value (all S):** TR-1, TR-3, INF-4, INF-7, CAP-4, CAP-5, CAP-7/8, CAP-10, TR-8, TR-9, TR-17, INF-3, F17, H2 (`moveItem`), UI-4.
2. **Transcript correctness:** INF-1 + INF-2 (Soniox reconnect), TR-13, TR-4, TR-5/6/7, UI-1 + UI-6.
3. **Aligner rewrite (one unit):** fix stress-test baseline → CAP-1 + CAP-2 + C1 + C5 + flush padding.
4. **CPU/energy wave:** CAP-3 + CAP-6 + CAP-11 (AEC), TR-2 + TR-11 (on-device chunking + model cache), M1/M2/UI-5 (meters), TR-14/F1 (ordered fan-out), A6/A7 (logging).
5. **Hygiene** *(done, plan-023)*: shared retry policy (F31) + TR-10/TR-16, F33 writer consolidation, A9 `.env` parser unification, UI-2/UI-3 pause controls, dead views (L3).

---

## 5. Status of prior (2026-06-12) findings

**Fixed and holding:** C4, C8, F7, F10/F11/F12, F13 (STT path), F19, F20, F21, F32, H1 (caveat: UI-4), H3, H4.
**Partially fixed:** C2, C3, F1 (inner seam only), F4 (round-trip remains), F9 (reconnect exists, but INF-1/INF-2), F15 (TR-10), F18 (TR-9), F24 (TR-17), M2/M3/L6.
**Still open:** C1, C5, C6, C7 (worse: split throw also skips sidecar rotation), C9; F2, F3, F5, F6 (overflow metric never populated → UI always 0), F8, F14, F16, F17, F22, F23, F25–F31, F33, F34; H2, M1, M4–M10, L1–L5, L7–L10 (L3/L9 wider); A1–A14 (all).
**Doc drift:** plan-017 T13/T14 checkboxes unticked although the code landed, CLAUDE.md advertises popover pause/resume/split that are unreachable (UI-2).

## 6. Positive observations

- Pause/resume fully stops the session — no CPU burned while paused. Idle (not recording) the app does almost nothing beyond two 2 s permission polls while the popover is open.
- Config resolution is cheap in the CLI (two `.env` reads per run); signal handling is sound (`SIG_IGN` + `DispatchSourceSignal`).
- The plan-017 vDSP `PCMConvert` consolidation, AEC deinterleave and Azure realtime config gate are correct.
