# plan-009 — Soniox token aggregator protocol fix (post-mortem + repair)

**Type:** post-mortem + bug-fix (not a feature plan).
**Date:** 2026-05-01.
**Scope:** `Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift` and its unit tests.
**Cross-references:** plan-006 §4.7 (original — and **correct** — algorithm spec); `Issues - Pending Items.md` Completed `PLAN-009` entry.

---

## 1. Symptom

Live-transcription JSONL sidecar files for Soniox sessions contained two intertwined kinds of garbage:

1. **Cumulative-growth blobs** — single records whose `text` field was the concatenation of every interim provisional guess produced by Soniox while it refined a hypothesis, e.g.

   ```text
   "Κ Κά Κάπως Κάπως θα Κάπως θα πρέ Κάπως θα πρέπει να
    Κάπως θα πρέπει να δού Κάπως θα πρέπει να δούμε
    Κάπως θα πρέπει να δούμε τι Κάπως θα πρέπει να δούμε τι Κ"
   ```

2. **Per-syllable spam** — immediately after each cumulative blob, dozens of single-token records each treated as its own "utterance segment", e.g.

   ```text
   {"text":"ά"} {"text":"πως"} {"text":"θα"} {"text":"π"}
   {"text":"ρέ"} {"text":"πει"} {"text":"να"} {"text":"δ"}
   {"text":"ού"} {"text":"με"} {"text":"τ"} {"text":"ι"} {"text":"."}
   ```

A real ~12-second Greek recording produced **38 JSONL lines for two utterances** (`~/Recordings/recording-2026-05-01-03-08.transcript.jsonl`). The expected output is **2 lines**.

The user reported the live-UI text was "in general accurate but also confused" — a symptom both of (1) being shown briefly and (2) finals arriving as single-token slivers.

## 2. Root cause

`SonioxTokenAggregator` was built in plan-006 Phase C (Unit D1). The plan's §4.7 spec described the algorithm correctly:

> 1. **Replace** `partialBuffer` with the message's non-final tokens.
> 2. For each final token in the message in order:
>    * If `text == "<end>"` or `text == "<fin>"`: aggregate `pendingFinals` into one `TranscriptSegment` … emit `.final(…)`, clear `pendingFinals`.
>    * Else: **append to `pendingFinals`**.

The implementation collapsed `pendingFinals` and `partialBuffer` into one `buffer: [SonioxToken]`, then introduced two protocol violations:

### Bug A — non-final tokens were never replaced between batches

The Soniox WebSocket protocol distinguishes:

- `is_final: false` (provisional) — the model's current best guess; **revised** by the next batch's non-finals.
- `is_final: true` (committed) — a word/syllable that will never change.

The implementation appended every token to `buffer` unconditionally:

```swift
// SonioxTokenAggregator.swift (pre-fix, line 47)
buffer.append(token)
```

So when batch 4 arrived with the revised non-final `"Κάπως θα δούμε"`, batches 1–3's superseded guesses (`"Κ"`, `"Κά"`, `"Κάπως"`) were still in the buffer. By the time the marker arrived, `flush()` concatenated all of them — producing the cumulative blob.

This contradicts plan-006 §4.7 step 1 ("**Replace** `partialBuffer`") and is also called out in the source-level documentation of `SonioxToken.isFinal`:

> `false` = provisional, **may be revised by a later non-final batch**.

### Bug B — every committed token triggered an utterance flush

```swift
// SonioxTokenAggregator.swift (pre-fix, lines 49-53)
if token.isFinal {
    if let event = flush(now: now) {
        events.append(event)
    }
}
```

This flushes the buffer on **every** `is_final: true` token. Soniox commits one word at a time as `isFinal: true` while the user is still speaking — these are word-level commits, not utterance terminators. Flushing on each one made every committed word into its own `.segmentFinalized` event → its own JSONL line → the per-syllable spam.

This contradicts plan-006 §4.7 step 2 — only the `<end>` / `<fin>` marker branch was supposed to emit a final.

The misleading test `testTwoNonFinalsThenFinalEmitsTwoPartialsAndOneFinal` baked Bug B into the contract by feeding the aggregator `[non-final, non-final, isFinal:true]` in one batch (no marker) and asserting `events.count == 3` with the third being a `.final`. That input shape never occurs in real Soniox traffic — every utterance is terminated by a marker — but the test fixed the wrong behavior in place.

## 3. The fix

### 3.1 Lazy non-final discard

Drop the previous batch's non-finals **just before** the first new content token of the current batch is appended:

```swift
if !didDiscardPriorNonFinals {
    buffer.removeAll { !$0.isFinal }    // keep finals; drop revisable non-finals
    didDiscardPriorNonFinals = true
}
```

Lazy (rather than eager) is critical because a batch consisting solely of `[<end>]` must preserve the buffer it's about to flush. An eager-at-start-of-batch discard wipes the marker's payload — caught by `testNonFinalsAreDiscardedBetweenBatches` failing with `events.count == 0` when expecting `1` during development of this fix.

### 3.2 Marker-only flush

The per-token-`isFinal:true` flush is removed. Only `<end>` / `<fin>` markers terminate an utterance:

```swift
if token.isMarker {
    if let event = flush(now: now) { events.append(event) }
    continue
}
// else (final or non-final, non-marker): just append to the buffer.
```

### 3.3 One partial per batch

The implementation previously emitted one `.partial` per non-final token (so a batch of 5 non-finals produced 5 partials → 5 UI redraws). It now emits **one** `.partial` per batch reflecting the post-batch buffer state:

```swift
if batchHadNewContent, let id = currentUtteranceId, !buffer.isEmpty {
    events.append(.partial(utteranceId: id, text: concatenatedText(buffer), …))
}
```

This matches the server's update cadence (1 batch → 1 UI redraw) and eliminates a class of UI flicker that wasn't filed but was implicit in the symptom report.

### 3.4 Drain semantics preserved

`drain()` (called at session close before any `<end>`/`<fin>` arrived) still flushes whatever's in the buffer — both committed finals AND any pending non-finals. At session close there is no future batch to revise the non-final, so it represents the user's last and best information.

Test coverage: `testDrainFlushesBufferedFinalsWhenNoMarkerEverArrived`.

## 4. Test changes

`Tests/MacrecCoreTests/Transcription/Soniox/SonioxTokenAggregatorTests.swift` was rewritten — 10 tests (was 5) covering the corrected protocol semantics:

| # | Test | Pins |
|---|---|---|
| 1 | `testSingleNonFinalTokenEmitsOnePartial` | One non-final → one `.partial`. |
| 2 | `testBatchEmitsOnePartialNotOnePerToken` | Batch of N non-finals → exactly 1 partial (anti-storm regression). |
| 3 | `testEndMarkerFlushesAsFinalWithoutMarkerText` | `<end>` flushes; marker text is not echoed in the final. |
| 4 | `testFinMarkerBehavesSameAsEndMarker` | `<fin>` and `<end>` are equivalent. |
| 5 | `testMixedFinalsAndMarkerInOneBatchProducesOneFinal` | Replaces the misleading `testTwoNonFinalsThenFinalEmits…` — the only utterance terminator is the marker. |
| 6 | `testNonFinalsAreDiscardedBetweenBatches` | **Bug A regression pin** — three batches of revising non-finals + `<end>` → final has only the latest revision. |
| 7 | `testCommittedFinalsAccumulateAcrossBatchesUntilMarker` | **Bug B regression pin** — finals scattered across batches accumulate into one `.final` at the marker; non-finals interleaved are discarded on revision. |
| 8 | `testMultipleUtterancesEachTerminatedByItsOwnMarker` | State resets cleanly between utterances. |
| 9 | `testDrainWithEmptyBufferReturnsEmpty` | Drain on empty buffer is a no-op. |
| 10 | `testDrainFlushesBufferedFinalsWhenNoMarkerEverArrived` | Session-close drain emits whatever is in the buffer. |

Both regression-pin tests (6, 7) fail under the pre-fix code and pass under the fix.

## 5. Verification

| Suite | Result |
|---|---|
| `SonioxTokenAggregatorTests` (10 tests) | ✅ all pass |
| `SonioxIntegrationTests` (4 tests — full session→pipeline→sidecar) | ✅ all pass |
| `Soniox*` + `StreamingTranscription*` filter (24 tests total) | ✅ 23 pass, 1 pre-existing failure unchanged (`StreamingTranscriptionPipelineTests`, tracked as `PLAN-008-PEND-1` #2 — different code path, uses `MockProvider`, not the Soniox aggregator) |
| `swift build` | ✅ clean |

## 6. Behavioral change observable to the user

For the same Greek audio sample that produced the 38-line JSONL (`~/Recordings/recording-2026-05-01-03-08.transcript.jsonl`), the post-fix output is **2 clean lines** — one per `<end>`-terminated utterance:

```jsonl
{"text":"Κάπως θα πρέπει να δούμε τι.","language":"el","durationSec":2.4,…}
{"text":"Γίνεται και πώς προχωράνε τα πράγματα.","language":"el","durationSec":3.12,…}
```

The live UI panel now redraws once per server batch instead of once per token, eliminating the flicker storm that accompanied the bug.

## 7. Why this wasn't caught earlier

Three reasons stacked:

1. **Plan-006 phase-D unit test for the aggregator (`testTwoNonFinalsThenFinalEmits…`) baked the wrong behavior in place** — the test author conflated `is_final: true` (commit) with end-of-utterance (marker), and the test happened to produce a sensible final for the synthetic input.

2. **Plan-006 phase-D integration test (`testThreeUtteranceFlow`) used hand-rolled mock batches where every utterance happened to fit into a single batch ending with both an `is_final: true` token AND a `<end>` marker.** Under the pre-fix code, the `is_final: true` token flushed the buffer and the trailing `<end>` was a no-op flush of an empty buffer — producing the right number of finals by accident. Under the post-fix code, the `is_final: true` accumulates and `<end>` flushes — producing the same right number of finals deliberately. The integration test couldn't distinguish the two algorithms.

3. **The bug only surfaces with multi-batch utterances** — i.e. real human speech where the model sends many provisional updates over hundreds of milliseconds before committing. None of the synthetic test fixtures exercise that path.

The post-fix unit test `testNonFinalsAreDiscardedBetweenBatches` is the missing fixture — it sends three batches of revising non-finals and asserts the cumulative growth does NOT appear in the final.

## 8. Files touched

- **Modified** `Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift` (algorithm + extensive doc comment update)
- **Rewritten** `Tests/MacrecCoreTests/Transcription/Soniox/SonioxTokenAggregatorTests.swift` (5 tests → 10 tests)
- **Created** `docs/design/plan-009-soniox-aggregator-protocol-fix.md` (this file)
- **Updated** `Issues - Pending Items.md` (Completed section: `PLAN-009` entry)

No source files outside `SonioxTokenAggregator.swift` were touched. The session, pipeline, and sidecar layers were already correct against the (originally specified) aggregator contract.
