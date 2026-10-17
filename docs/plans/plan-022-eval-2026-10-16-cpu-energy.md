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
- [ ] **T4 (CAP-3 / CAP-6 / CAP-11)** The AEC NLMS loop makes four full passes over 4096 taps per sample per channel, and holds the lock that `feedReference` (the SCStream thread) needs for the whole loop.
  - Keep a running window energy instead of calling `svesq` per sample, and fuse leakage and update into one `vDSP_vsmsma`.
  - Run one filter against a mono reference when the mic channels are identical, since CoreAudio upmixes a mono mic.
  - Copy the needed reference span under the lock and run the NLMS outside it.
- [ ] **T5 (TR-11)** WhisperKit and Parakeet models are reloaded and warmed up on every recording, twice in source-split mode.
  - Add a process-wide model cache with idle eviction.
- [ ] **T6 (TR-2)** On-device providers get the same ~2.5 s chunks as the cloud batch providers, padded to the model window (15 s Parakeet, 30 s Whisper).
  - Add a per-provider chunk policy: longer chunks for on-device models, cut at silence.

## Verification

- `swift build` clean, release build green.
- New tests pass; the full `swift test` shows no failures beyond the 11 baseline ones.
- Measure CPU before and after where a real recording can show it (AEC on).
