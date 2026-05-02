// Tests/MacrecCoreTests/Transcription/Soniox/SonioxTokenAggregatorTests.swift
//
// Plan-006 Phase D / Unit D1: tests for `SonioxTokenAggregator`'s
// state machine.
//
// Rewritten 2026-05-01 to reflect the corrected protocol semantics:
//   * Non-final tokens from prior batches are DISCARDED on the next
//     batch (Soniox revises non-finals; only finals are committed).
//   * Per-token `is_final: true` is a word-level commit, NOT an
//     utterance terminator. Only `<end>` and `<fin>` markers flush
//     the buffer to a `.final` event.
//   * One `.partial` per batch (not per non-final token) reflecting
//     the post-batch buffer state.
// The original test set baked the old (incorrect) per-token-final
// flush behavior into the contract; the symptoms in
// ~/Recordings/recording-2026-05-01-03-08.transcript.jsonl proved
// that contract was wrong against real Soniox traffic.

import XCTest
@testable import MacrecCore

final class SonioxTokenAggregatorTests: XCTestCase {

    // MARK: - Single-batch baseline

    func testSingleNonFinalTokenEmitsOnePartial() async {
        let agg = SonioxTokenAggregator()
        let tok = SonioxToken(
            text: "hello",
            isFinal: false,
            startMs: 0,
            endMs: 100,
            confidence: 0.9,
            language: "en"
        )
        let events = await agg.ingest([tok])
        XCTAssertEqual(events.count, 1)
        guard case let .partial(_, text, confidence, _) = events[0] else {
            return XCTFail("Expected .partial; got \(events[0])")
        }
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(confidence, 0.9)
    }

    func testBatchEmitsOnePartialNotOnePerToken() async {
        // Real Soniox emits 1–N tokens per server message. The aggregator
        // should produce ONE `.partial` per batch (matching the server's
        // update cadence), not one per non-final token. The old per-token
        // emission produced a partial-storm.
        let agg = SonioxTokenAggregator()
        let t1 = SonioxToken(text: "Κάπως",       isFinal: false, confidence: 0.7, language: "el")
        let t2 = SonioxToken(text: " θα",          isFinal: false, confidence: 0.7, language: "el")
        let t3 = SonioxToken(text: " δούμε",       isFinal: false, confidence: 0.8, language: "el")
        let events = await agg.ingest([t1, t2, t3])
        XCTAssertEqual(events.count, 1, "expected exactly one partial per batch")
        guard case let .partial(_, text, _, _) = events[0] else {
            return XCTFail("Expected .partial; got \(events[0])")
        }
        XCTAssertEqual(text, "Κάπως θα δούμε")
    }

    // MARK: - Marker-driven flush (the canonical utterance terminator)

    func testEndMarkerFlushesAsFinalWithoutMarkerText() async {
        let agg = SonioxTokenAggregator()
        let t1 = SonioxToken(text: "hello", isFinal: false, confidence: 0.9, language: "en")
        let endMarker = SonioxToken(text: "<end>", isFinal: true, confidence: 1.0)
        let events = await agg.ingest([t1, endMarker])
        XCTAssertEqual(events.count, 1)
        guard case let .final(_, text, _, _, _, _) = events[0] else {
            return XCTFail("Expected .final; got \(events[0])")
        }
        XCTAssertEqual(text, "hello")
        XCTAssertFalse(text.contains("<end>"))
    }

    func testFinMarkerBehavesSameAsEndMarker() async {
        let agg = SonioxTokenAggregator()
        let t1 = SonioxToken(text: "yes", isFinal: false, confidence: 0.9, language: "en")
        let finMarker = SonioxToken(text: "<fin>", isFinal: true, confidence: 1.0)
        let events = await agg.ingest([t1, finMarker])
        XCTAssertEqual(events.count, 1)
        guard case let .final(_, text, _, _, _, _) = events[0] else {
            return XCTFail("Expected .final; got \(events[0])")
        }
        XCTAssertEqual(text, "yes")
        XCTAssertFalse(text.contains("<fin>"))
    }

    func testMixedFinalsAndMarkerInOneBatchProducesOneFinal() async {
        // Replaces the misleading testTwoNonFinalsThenFinalEmits…
        // The original asserted that a per-token `is_final: true`
        // triggers utterance flush; the corrected contract is that
        // ONLY `<end>` / `<fin>` markers terminate an utterance.
        let agg = SonioxTokenAggregator()
        let t1 = SonioxToken(text: "hello",  isFinal: false, confidence: 0.8, language: "en")
        let t2 = SonioxToken(text: " world", isFinal: false, confidence: 0.9, language: "en")
        let t3 = SonioxToken(text: "!",      isFinal: true,  confidence: 1.0, language: "en")
        let endMarker = SonioxToken(text: "<end>", isFinal: true, confidence: 1.0)
        let events = await agg.ingest([t1, t2, t3, endMarker])
        // Expect ONE final ("hello world!") — the marker drives the flush.
        // No interim partials are emitted on the same batch because the
        // marker fires before we'd emit a post-batch partial.
        XCTAssertEqual(events.count, 1, "expected one .final from the <end> marker; got \(events)")
        guard case let .final(_, text, _, _, language, _) = events[0] else {
            return XCTFail("Expected .final; got \(events[0])")
        }
        XCTAssertEqual(text, "hello world!")
        XCTAssertEqual(language, "en")
    }

    // MARK: - Multi-batch revision (the real protocol)

    func testNonFinalsAreDiscardedBetweenBatches() async {
        // This is the heart of the bug fix. Soniox revises non-final
        // tokens batch-by-batch — successive batches send NEW provisional
        // guesses that REPLACE the previous batch's non-finals. The
        // aggregator must drop prior non-finals at the start of each
        // ingest() call so the eventual final does not contain the
        // accumulated growth history.
        let agg = SonioxTokenAggregator()
        // Batch 1: provisional guess "Κά"
        let b1 = [SonioxToken(text: "Κά", isFinal: false, confidence: 0.5, language: "el")]
        _ = await agg.ingest(b1)
        // Batch 2: revised guess "Κάπως"
        let b2 = [SonioxToken(text: "Κάπως", isFinal: false, confidence: 0.7, language: "el")]
        _ = await agg.ingest(b2)
        // Batch 3: revised guess "Κάπως θα"
        let b3 = [SonioxToken(text: "Κάπως θα", isFinal: false, confidence: 0.8, language: "el")]
        _ = await agg.ingest(b3)
        // Batch 4: end marker → flushes the buffer
        let b4 = [SonioxToken(text: "<end>", isFinal: true, confidence: 1.0)]
        let events = await agg.ingest(b4)

        XCTAssertEqual(events.count, 1)
        guard case let .final(_, text, _, _, _, _) = events[0] else {
            return XCTFail("Expected .final; got \(events[0])")
        }
        // CRITICAL — must be ONLY the latest revision, not the
        // concatenation "Κά Κάπως Κάπως θα".
        XCTAssertEqual(
            text, "Κάπως θα",
            "non-finals from prior batches must be discarded; got cumulative growth instead"
        )
    }

    func testCommittedFinalsAccumulateAcrossBatchesUntilMarker() async {
        // When Soniox commits a word as `is_final: true` mid-utterance,
        // it must be retained across subsequent batches (only non-finals
        // are revisable). Multiple committed finals should accumulate
        // into the single final emitted at the marker.
        let agg = SonioxTokenAggregator()
        // Batch 1: commit "Hello"
        let b1 = [SonioxToken(text: "Hello", isFinal: true, confidence: 0.95, language: "en")]
        _ = await agg.ingest(b1)
        // Batch 2: commit " world" + provisional " how"
        let b2 = [
            SonioxToken(text: " world", isFinal: true,  confidence: 0.95, language: "en"),
            SonioxToken(text: " how",   isFinal: false, confidence: 0.5,  language: "en"),
        ]
        _ = await agg.ingest(b2)
        // Batch 3: revise the non-final to " are you" and finalize that too
        let b3 = [
            SonioxToken(text: " are you", isFinal: true,  confidence: 0.9, language: "en"),
        ]
        _ = await agg.ingest(b3)
        // Batch 4: marker → flush
        let events = await agg.ingest([SonioxToken(text: "<end>", isFinal: true, confidence: 1.0)])

        XCTAssertEqual(events.count, 1)
        guard case let .final(_, text, _, _, _, _) = events[0] else {
            return XCTFail("Expected .final; got \(events[0])")
        }
        // Committed finals: "Hello" + " world" + " are you"
        // Provisional " how" from batch 2 was dropped at the start
        // of batch 3 (per the discard rule).
        XCTAssertEqual(text, "Hello world are you")
    }

    func testMultipleUtterancesEachTerminatedByItsOwnMarker() async {
        // Three utterances, each ends with its own marker. Each marker
        // produces exactly one `.final`. State resets cleanly between
        // utterances.
        let agg = SonioxTokenAggregator()

        let u1 = [
            SonioxToken(text: "first",  isFinal: true,  confidence: 0.9),
            SonioxToken(text: "<end>",  isFinal: true,  confidence: 1.0),
        ]
        let u2 = [
            SonioxToken(text: "second", isFinal: true,  confidence: 0.9),
            SonioxToken(text: "<end>",  isFinal: true,  confidence: 1.0),
        ]
        let u3 = [
            SonioxToken(text: "third",  isFinal: true,  confidence: 0.9),
            SonioxToken(text: "<fin>",  isFinal: true,  confidence: 1.0),
        ]

        let e1 = await agg.ingest(u1)
        let e2 = await agg.ingest(u2)
        let e3 = await agg.ingest(u3)

        XCTAssertEqual(e1.count, 1)
        XCTAssertEqual(e2.count, 1)
        XCTAssertEqual(e3.count, 1)

        let texts: [String] = [e1, e2, e3].compactMap { batch in
            guard case let .final(_, text, _, _, _, _) = batch[0] else { return nil }
            return text
        }
        XCTAssertEqual(texts, ["first", "second", "third"])
    }

    // MARK: - Drain (session close before <end>/<fin>)

    func testDrainWithEmptyBufferReturnsEmpty() async {
        let agg = SonioxTokenAggregator()
        let events = await agg.drain()
        XCTAssertEqual(events.count, 0)
    }

    func testDrainFlushesBufferedFinalsWhenNoMarkerEverArrived() async {
        // If the recording is stopped before Soniox sends `<end>`/`<fin>`,
        // drain() must still surface whatever has been committed.
        let agg = SonioxTokenAggregator()
        _ = await agg.ingest([
            SonioxToken(text: "draft", isFinal: true, confidence: 0.9),
            SonioxToken(text: " text", isFinal: false, confidence: 0.5),
        ])
        let drained = await agg.drain()
        XCTAssertEqual(drained.count, 1)
        guard case let .final(_, text, _, _, _, _) = drained[0] else {
            return XCTFail("Expected .final from drain; got \(drained[0])")
        }
        // Drain emits both finals AND the still-pending non-final
        // (best-effort: at session close there is no future batch
        // that could revise the non-final, so it's the user's last
        // and best information).
        XCTAssertEqual(text, "draft text")
    }
}
