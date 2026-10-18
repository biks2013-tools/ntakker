# plan-023: EVAL-2026-10-16 hygiene wave

Source: `docs/reference/evaluation-2026-10-16-quality-performance.md` §4 item 5 ("Hygiene"), plus the open items carried from earlier waves: C6, C7, CAP-18, and the `--transcribe-source mic` resolver bug found in plan-022.
Follows: `plan-022-eval-2026-10-16-cpu-energy.md`.
Approved: 2026-10-17. The user said "Do the cleanup items". One commit per task.

## Tasks

- [x] **T1 (F31 + TR-10 + TR-16)** Retry and circuit-breaker hygiene for the REST batch providers.
  - Extract one shared HTTP retry policy (`Transcription/Net/`) and adopt it in Azure batch, ElevenLabs and Gemini. Gemini had no retry at all.
  - Cap `Retry-After` so one 429 cannot hold a slot for minutes (TR-16).
  - Circuit breaker: a failed half-open probe re-opens the circuit at once instead of allowing 5 more failures (TR-10). An auth failure (401/403) from any provider trips it permanently.
  - Done. `HTTPRetryPolicy` is now the only retry loop; the providers keep their own status sets and error mapping. `ProviderCircuitBreaker` holds the transitions as plain state, so they are unit-tested. Gemini maps 401 to `transcriptionApiKeyMissing` and 403 to `transcriptionPermissionDenied`; Azure and ElevenLabs already did.
  - **Found while doing T1: the five Gemini REST baseline failures were test bugs.** `makeProvider()` reset the URL stub after each test had installed its handler, so every request failed with "stub error -1". `requestURL` still expected the key in the query string, although F13 moved it to a header. `requestBodyShape` did not account for JSONEncoder escaping `/`. All six Gemini tests now pass.
  - Seen once under full-suite load: two `FakeAudioSource` timing tests ("skipNextEmission…", "injectPTSJump…") failed and then passed 3 of 3 when run alone. They were racy tests, not a regression: under load the 5 ms source can emit another buffer between the test seeing buffer 2 and injecting the skip or jump, so the gap lands one pair later than the pair the tests checked. Fixed at the end of the wave: the tests now look for exactly one such pair.
- [x] **T2 (F33)** The four transcript writers (JSONL, TXT, SRT, VTT) each copy the byte-range index, the short-grow padding and the long-grow tombstone-and-append code. Extract one rewriting file writer; the format writers keep only their rendering.
  - Done. `RewritableSegmentFile` owns the handle, the byte index and both grow paths; each format writer supplies its rendering, terminator and tombstone. New short-grow and long-grow tests for TXT, SRT and VTT (only JSONL had them) pass on both the old and the new writers, so the bytes on disk are unchanged.
- [x] **T3 (A9)** `EnvFileStore` (the app) has its own minimal `.env` parser that keeps quotes and silently ignores a malformed file. Delegate to `DotEnvParser`, log parse failures, and quote values on write when needed.
  - Done. `loadIntoProcess` now throws, and `AppDelegate` logs the error at launch; a malformed file loads nothing, as in the CLI. `read` still returns nil on a bad file. `upsert` quotes values with surrounding whitespace, a `#`, or a leading quote.
- [x] **T4 (UI-2 / UI-3)** Pause, Resume and Split are unreachable in the popover. Expose them in the status bar while recording, and stop a pause from tearing down the level meters or flashing the stopped UI.
  - Done. Cause of UI-3: `SessionCoordinator.pause()` relayed the engine's own `.stopping` / `.stopped`, and the controller treats `.stopped` as the end of the session (meters torn down, Save / Discard shown) until `.paused` arrives. Those two states are now held back while a pause stops the segment; a new test fails on the old coordinator. The buttons are build-verified only (SwiftUI view in the app target). Manual check: Pause, Resume and Split from the popover.
- [x] **T6 (L3)** Delete the dead `LevelMeterView` and `ElapsedTimeView`. Done; neither was referenced anywhere.
- [x] **T7 (C6)** Bound the M4A recorder's pending-buffer queue.
  - Done. Past 600 queued frames (a minute of audio) the writer is failed as stalled; the failure surfaces from the next `append` / `finalize` as for any encoder error, and the queue is freed. Build-verified plus the existing M4A tests; a stalled `AVAssetWriterInput` cannot be produced in a unit test.
- [x] **T8 (C7)** `split()` leaves the session inconsistent when finalizing the old segment fails. Roll back, and keep the sidecar rotation consistent.
  - Done, as "complete forward" rather than roll back: once the recorders are swapped, the new part is already recording and the old recorder cannot be reopened. `split` now finishes the sidecar rotation and emits `.recording`, then throws `SplitPreviousSegmentError`. The coordinator does its part bookkeeping (counter, boundary, `segmentCompleted`) before rethrowing it. The coordinator path has a test; the `RecordingSession` side is build-verified, because its recorders are created internally and cannot be made to fail in a test.
- [x] **T9 (CAP-18)** Observe the mic's `wasDisconnectedNotification` so an unplugged mic is reported instead of stalling silently.
  - Done.
    - When following the system default input, the source re-attaches to the new default after 0.5 s.
    - When a device was chosen explicitly, the source does not switch to another mic; it logs an error and stops, and the recording continues with a silent mic track (the aligner fills it).
    - Build-verified only, since a device disconnect cannot be produced in a unit test. Manual check: unplug a USB or Bluetooth mic mid-recording, with the default device and with an explicit one.
- [x] **T10 (found in plan-022)** `--transcribe-source mic` is refused unless `--mic-device` is set, because the resolver treats "system default" as disabled. This is the baseline failure "Shell env supplies transcription keys".
  - Done. Only an explicit `none` counts as disabled now. The baseline test passes, and two new tests were added. Real check: `ntakker-cli start --transcribe parakeet --transcribe-source mic` (with no `--mic-device`) records.

## Verification

- `swift build` clean, release build green.
- Full `swift test`: no new failures; T10 should take one failure off the baseline list.

## Wave result (2026-10-17)

- All ten tasks landed, one commit each, plus a test-only fix for the two racy `FakeAudioSource` tests.
- **Baseline failures: 11 → 5.**
  - T1 fixed five Gemini REST test bugs; T10 fixed the "Shell env" resolver bug.
  - Still failing: gemini-live API-key test, partNN sidecar naming, SonioxConfigBuilder V1 (XCTest), AudioDownsampler:144, UIErrorPresenter:220.
- Tests: 522 Swift Testing + 218 UI + 70 XCTest; two full runs in a row were clean apart from those 5. The release build is green.
- Build-verified only:
  - T4: the popover buttons.
  - T7: the M4A stall cap.
  - T8: the `RecordingSession` side of split.
  - T9: mic disconnect.
- Manual checks:
  - Pause, Resume and Split from the popover while recording; the meters stay up and Save/Discard should not flash on pause.
  - Unplug a USB or Bluetooth mic mid-recording, both with the default device and with an explicitly chosen one.
