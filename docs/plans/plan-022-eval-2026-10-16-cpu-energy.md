# plan-022: EVAL-2026-10-16 CPU / energy wave

Source: `docs/reference/evaluation-2026-10-16-quality-performance.md` §4 item 4 ("CPU/energy wave") and the §2 rows CAP-3, CAP-6, CAP-11, TR-2, TR-11, M1/M2/UI-5, A6/A7, TR-14/F1.
Follows: `plan-021-eval-2026-10-16-aligner-rewrite.md`.
Approved: 2026-10-17. The user said "yes proceed with the CPU/energy wave". One commit per task.

## Tasks

- [x] **T1 (TR-14 / F1)** The aligner live tap spawns one `Task` per frame per source. The Tasks are unordered and unbounded, and `stop()` can run before the last ones have ingested.
  - Add one bounded `AsyncStream` per source with a serial consumer that feeds the dispatcher in order.
  - On teardown: remove the tap, finish the streams, await the consumers, then call `dispatcher.stop()`.
  - Count and log frames dropped when a stalled dispatcher fills the buffer.
- [x] **T2 (A6 / A7 + CAP-13 / CAP-14)** The file log sink formats a `DateFormatter` per line and writes synchronously under a lock, with no rotation. `mic_health` logs at INFO every second, and every transcript event logs at INFO.
  - Cache the formatter, batch the writes on a serial queue, and rotate by size.
  - Demote the hot logs to debug or trace.
  - Done. The `DateFormatter` was already a static; the real cost was the synchronous write, now batched on a utility queue with a flush at exit. Rotation at 10 MB keeps one `.1` backup. `mic_health` stays at INFO for the first 5 ticks and whenever the mic looks unhealthy, and drops to DEBUG otherwise. The per-event forwarder log is now TRACE, so its `String(describing:)` is never built at the default level.
- [x] **T3 (M1 / M2 / UI-5)** The level meters publish at 30 Hz even when nothing changes and the popover is closed. Two `TimelineView`s animate `sin(t·9)` regardless of audio. The meters map linear RMS, so silence and speech look alike.
  - Map levels to dBFS.
  - Skip unchanged values and pause publishing while the popover is hidden.
  - Draw the meters from the data instead of a `TimelineView`.
- [x] **T4 (CAP-3 / CAP-6 / CAP-11)** The AEC NLMS loop makes four full passes over 4096 taps per sample per channel, and holds the lock that `feedReference` (the SCStream thread) needs for the whole loop.
  - Keep a running window energy instead of calling `svesq` per sample, and fuse leakage and update into one `vDSP_vsmsma`.
  - Run one filter against a mono reference when the mic channels are identical, since CoreAudio upmixes a mono mic.
  - Copy the needed reference span under the lock and run the NLMS outside it.
  - **Found while doing T4: the filter never cancelled echo.** The window for mic sample `p` started at ring index `p + 1`, so it read reference samples `p+1 … p+L` (the future) when the reference led by more than L, or `p−2L+1 … p−L` (85–170 ms old) otherwise. On a synthetic delayed echo the old code left a residual larger than the echo itself. The window now ends at `p`. The ring grew from 2L to 4L so the window plus a mic buffer plus the reference lead fit.
  - Done. The CAP-6 part is the mono path inside the AEC; the capture pipeline still upmixes the mic to stereo (moving that to the encoder is a separate change). Release-build benchmark, L = 4096, an adapting echo: 0.053 s → 0.016 s of CPU per second of audio (3.3×). Tests: three echo-convergence tests (mono, upmixed mono, true stereo) that fail on the old code; the double-talk test's pass-through count changed from 2L to L−1 because of the corrected window.
- [x] **T5 (TR-11)** WhisperKit and Parakeet models are reloaded and warmed up on every recording, twice in source-split mode.
  - Add a process-wide model cache with idle eviction.
  - Done. `OnDeviceModelCache` holds one engine per key, plus the `InferenceGate` its callers must share. Concurrent first loads are de-duplicated, failed loads are not cached, and an entry unused for 10 min is dropped (each `transcribe` touches it). `TranscriptionProvider.prepare()` (default no-op) is called when the batch pipeline starts, so the model loads at once instead of inside the first chunk (EVAL-2026-06-12 F28). Real check: `ntakker-cli --transcribe parakeet --transcribe-source both` logged one "loading model" line instead of two, starting at pipeline start.
  - **Found while doing T5:** the CLI rejected `--transcribe parakeet` and `apple-cloud`, because `TranscriptionProviderId` lacked both cases (separate commit).
- [x] **T6 (TR-2)** On-device providers get the same ~2.5 s chunks as the cloud batch providers, padded to the model window (15 s Parakeet, 30 s Whisper).
  - Add a per-provider chunk policy: longer chunks for on-device models, cut at silence.
  - Done. `ChunkPolicy` (`.drainAll` for the cloud batch providers, unchanged; `.silenceCut(10 s, 14 s)` for WhisperKit and Parakeet). A chunk is cut in the middle of the first 50 ms frame below −46 dBFS after 10 s, or at the quietest frame once 14 s is buffered; the rest stays for the next chunk. The overflow cap scales to 2 × the maximum (28 s). Trade-off: on-device text now appears about every 10 s instead of every 2.5 s. Real check with Parakeet on the mic and a spoken passage: two chunks of 10.2 s and 10.0 s, both cut at pauses, and the transcript was word-perfect.

## Verification

- `swift build` clean, release build green.
- New tests pass; the full `swift test` shows no failures beyond the 11 baseline ones.
- Measure CPU before and after where a real recording can show it (AEC on).
