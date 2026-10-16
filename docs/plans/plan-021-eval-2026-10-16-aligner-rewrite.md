# plan-021: EVAL-2026-10-16 aligner rewrite

Source: `docs/reference/evaluation-2026-10-16-quality-performance.md` §4 item 3 ("Aligner rewrite (one unit)"): CAP-1, CAP-2, C1, C5 and flush padding. Also the pre-existing `RecordingSessionTests` spin and the two failing `HostClockAlignerStress` tests.
Follows: `plan-020-eval-2026-10-16-transcript-correctness.md`.
Approved: 2026-10-16. The user said "yes please" to the proposed order: plan-019, then transcript correctness, then the aligner rewrite. One commit per task.

## Problems

- **CAP-1:** `appendSamples` re-anchors `headPTS` only when the buffer is empty. A hole inside a running source is collapsed instead of silence-filled, and that track stays early for the rest of the recording. This is the cause of the stress failures "10 skipNextEmission calls…" and "PTS jump…".
- **CAP-2:** when one source stalls or never starts, `sourceReady` stays false. Nothing is emitted, and the other source's buffer grows without bound.
- **C1:** every ingest rebuilds the whole per-source buffer with scalar loops, and every emitted window reslices it. Under a stall this becomes quadratic, which is the `RecordingSessionTests` spin.
- **C5:** `lastDriftSec` compares the two output buffers' PTS, which are both the window start by construction, so it is always 0.
- **Flush padding:** `flush()` discards the final partial window, losing up to about 100 ms at the end of every recording.

## Tasks

- [ ] **T1** Rewrite the `HostClockAligner` core; the public API and `Stats` stay unchanged.
  - Each source keeps a queue of PTS-stamped chunks, with one copy per ingest. Emission copies the window's overlap straight into the output block buffer. No whole-buffer rebuilds.
  - Each chunk is placed at its PTS. A deviation within 5 ms of the previous chunk's end is snapped (contiguous). A larger forward deviation is a hole, silence-filled and counted as a gap-fill for every window it touches. A backward deviation trims the overlap.
  - Max skew of 400 ms: a source lagging the other by more than that is silence-filled for the window and counted as a gap-fill. Output never blocks on a stalled or absent source, and buffering stays bounded.
  - Data older than the emission cursor is dropped; the aligner never goes back in time.
  - `flush()` emits the remaining partial windows padded with silence. These padding windows are not counted as gap-fills.
  - `lastDriftSec`: the absolute difference between the two sources' current snap deviations (the residual misalignment, at most 5 ms per track).
- [ ] **T2** Turn the stress-test expectations into the baseline. The two failing stress tests should pass; tighten the asymmetric-stop assertion now that stalls are detected; add tests for an in-stream hole, a never-started source, and flush padding.
- [ ] **T3** Re-run `RecordingSessionTests` (it used to spin forever), and the full suite without `--skip` if it now terminates. Remove the memory note and the doc caveat about the hang.

## Verification

- `swift build` clean.
- `HostClockAligner*` suites green.
- Full suite shows no new failures; the two stress failures leave the baseline list.
