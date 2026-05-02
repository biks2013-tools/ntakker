// Tests/MacrecCoreTests/Transcription/Soniox/SonioxAggregatorSpeakerBoundaryTests.swift
//
// Plan-012 Phase A4: speaker-boundary handling in `SonioxTokenAggregator`.
//
// Soniox emits diarisation labels (`spk:1`, `spk:2`, …) on individual
// tokens when `enable_speaker_diarization=true`. The aggregator must
// translate those labels into speaker-tagged segments by:
//
//   1. Adopting the first non-nil `speaker` it sees as the active speaker.
//   2. Carrying the active speaker through tokens whose `speaker == nil`
//      (silent / unlabelled material in the same utterance).
//   3. Flushing the buffered material as a `.final` tagged with the OLD
//      speaker as soon as a token arrives whose `speaker` differs from
//      the active one — then adopting the new label.
//   4. Resetting the active speaker on `<end>` / `<fin>` marker flushes
//      so the next utterance starts fresh.
//
// These three tests cover those four behaviours against the REAL
// `SonioxTokenAggregator` API (`ingest(_:now:)`, `drain(now:)`).

import Testing
import Foundation
@testable import MacrecCore

@Suite("SonioxTokenAggregator speaker-boundary handling (Phase A4)")
struct SonioxAggregatorSpeakerBoundaryTests {

    private let now = Date(timeIntervalSince1970: 1_000)

    @Test("speaker change inside an utterance flushes the active partial and starts a new one")
    func speakerChangeFlushes() async {
        let agg = SonioxTokenAggregator()

        // Batch 1: two committed words from speaker spk:1.
        let batch1: [SonioxToken] = [
            SonioxToken(text: "hello", isFinal: true, startMs: 0,    endMs: 500, speaker: "spk:1"),
            SonioxToken(text: " world", isFinal: true, startMs: 500, endMs: 1000, speaker: "spk:1"),
        ]
        let events1 = await agg.ingest(batch1, now: now)
        // Expect ONE partial reflecting the post-batch state (per the
        // existing one-partial-per-batch contract).
        #expect(events1.count == 1)
        if case .partial(_, _, _, let speaker) = events1[0] {
            #expect(speaker == "spk:1")
        } else {
            Issue.record("expected partial event")
        }

        // Batch 2: a token from a NEW speaker, spk:2.
        // Expected event sequence: ONE final with speaker=spk:1
        // (carrying the buffered hello world), THEN ONE partial with
        // speaker=spk:2 (carrying the just-appended "ok").
        let batch2: [SonioxToken] = [
            SonioxToken(text: "ok", isFinal: true, startMs: 1000, endMs: 1300, speaker: "spk:2"),
        ]
        let events2 = await agg.ingest(batch2, now: now)
        #expect(events2.count == 2)

        if case .final(_, let text, _, _, _, let speaker) = events2[0] {
            #expect(speaker == "spk:1")
            #expect(text.contains("hello"))
        } else {
            Issue.record("first event should be a final for spk:1")
        }
        if case .partial(_, let text, _, let speaker) = events2[1] {
            #expect(speaker == "spk:2")
            #expect(text == "ok")
        } else {
            Issue.record("second event should be a partial for spk:2")
        }
    }

    @Test("nil speaker on an incoming token leaves the active speaker untouched")
    func nilSpeakerCarryThrough() async {
        let agg = SonioxTokenAggregator()

        // Establish active speaker via batch 1.
        _ = await agg.ingest([
            SonioxToken(text: "alpha", isFinal: true, startMs: 0, endMs: 500, speaker: "spk:1")
        ], now: now)
        // Batch 2 token has nil speaker — must not flush, must not
        // change active speaker.
        let events = await agg.ingest([
            SonioxToken(text: " beta", isFinal: true, startMs: 500, endMs: 1000, speaker: nil)
        ], now: now)
        // Expect ONE partial. Speaker should still be spk:1 (carried
        // through despite the new token being nil).
        #expect(events.count == 1)
        if case .partial(_, let text, _, let speaker) = events[0] {
            #expect(speaker == "spk:1")
            #expect(text.contains("alpha") && text.contains("beta"))
        } else {
            Issue.record("expected partial event")
        }
    }

    @Test("marker flush emits the active speaker on the final, then resets")
    func markerFlushResetsSpeaker() async {
        let agg = SonioxTokenAggregator()
        _ = await agg.ingest([
            SonioxToken(text: "hi", isFinal: true, startMs: 0, endMs: 200, speaker: "spk:1")
        ], now: now)
        let endEvents = await agg.ingest([
            SonioxToken(text: "<end>", isFinal: true, confidence: 1.0)
        ], now: now)
        #expect(endEvents.count == 1)
        if case .final(_, _, _, _, _, let speaker) = endEvents[0] {
            #expect(speaker == "spk:1")
        } else {
            Issue.record("expected final after <end> marker")
        }

        // Next utterance should start fresh — a token with a new
        // speaker should NOT trigger a phantom flush (there's nothing
        // to flush).
        let next = await agg.ingest([
            SonioxToken(text: "next", isFinal: true, startMs: 1000, endMs: 1200, speaker: "spk:2")
        ], now: now)
        #expect(next.count == 1)
        if case .partial(_, _, _, let speaker) = next[0] {
            #expect(speaker == "spk:2")
        } else {
            Issue.record("expected partial for new utterance")
        }
    }
}
