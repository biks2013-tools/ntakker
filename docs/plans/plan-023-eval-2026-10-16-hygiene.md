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
  - Seen once under full-suite load: two `FakeAudioSource` timing tests ("skipNextEmission…", "injectPTSJump…") failed and then passed 3 of 3 when run alone. They are timing-sensitive (5 ms buffers and semaphores) and flaky; this is not a regression.
- [ ] **T2 (F33)** The four transcript writers (JSONL, TXT, SRT, VTT) each copy the byte-range index, the short-grow padding and the long-grow tombstone-and-append code. Extract one rewriting file writer; the format writers keep only their rendering.
- [ ] **T3 (A9)** `EnvFileStore` (the app) has its own minimal `.env` parser that keeps quotes and silently ignores a malformed file. Delegate to `DotEnvParser`, log parse failures, and quote values on write when needed.
- [ ] **T4 (UI-2 / UI-3)** Pause, Resume and Split are unreachable in the popover. Expose them in the status bar while recording, and stop a pause from tearing down the level meters or flashing the stopped UI.
- [ ] **T5 (convo-coach B1 / B5 / B10 / CC-10 / CC-11)**
  - Parse stdin records incrementally instead of re-parsing the whole history on every trigger.
  - Cache token counts per record and for the system prompt.
  - Use `o200k_base` for the models that use it.
  - Import the selected provider lazily so `--help` does not load every SDK.
- [ ] **T6 (L3)** Delete the dead `LevelMeterView` and `ElapsedTimeView`.
- [ ] **T7 (C6)** Bound the M4A recorder's pending-buffer queue.
- [ ] **T8 (C7)** `split()` leaves the session inconsistent when finalizing the old segment fails. Roll back, and keep the sidecar rotation consistent.
- [ ] **T9 (CAP-18)** Observe the mic's `wasDisconnectedNotification` so an unplugged mic is reported instead of stalling silently.
- [ ] **T10 (found in plan-022)** `--transcribe-source mic` is refused unless `--mic-device` is set, because the resolver treats "system default" as disabled. This is the baseline failure "Shell env supplies transcription keys".

## Verification

- `swift build` clean, release build green, convo-coach `npm test` green.
- Full `swift test`: no new failures; T10 should take one failure off the baseline list.
