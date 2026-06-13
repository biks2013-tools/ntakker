// NtakkerUITests/RecordingControllerLongSessionTests.swift
//
// Regression suite for the duplication-after-cap bug observed with the
// Soniox streaming provider in long sessions (>= ~10 min). Symptoms
// reported by the user:
//
//   * After ~100 utterances the live transcript panel renders each new
//     line twice.
//   * Older content is evicted from the rolling 100-segment window at
//     roughly twice the expected rate, so portions of the stream
//     visibly disappear.
//
// Root cause (fixed in `RecordingController.appendOrInsertSegment` /
// `updateSegment` / `finalizeSegment`): the streaming pipeline's
// `nextSegmentIndex` is monotonic across the whole session, but the
// controller was treating it as a position inside the length-capped
// `transcriptSegments` array. Once `count == maxLiveTranscriptSegments`,
// every index >= count produced an APPEND for both the partial and the
// final, doubling the row count per utterance.
//
// The fix routes by `TranscriptSegment.id` (the utterance UUID, stable
// across `.segmentAppended` / `.segmentUpdated` / `.segmentFinalized`
// for the same utterance — see `StreamingTranscriptionPipeline.handle`).
// These tests pin that invariant.

import Foundation
import Testing
@testable import NtakkerCore
@testable import NtakkerUIKit

@MainActor
@Suite("RecordingController long session — duplicates & loss past cap")
struct RecordingControllerLongSessionTests {

    /// Drive `n` synthetic utterances through the controller — for each
    /// utterance: one `.segmentAppended` (partial), one `.segmentUpdated`
    /// (partial revision), one `.segmentFinalized` (with `durationSec`
    /// stamped so the row renders as "settled"). The pipeline's
    /// monotonic absolute index is simulated by `idx`.
    private func driveUtterances(
        _ controller: RecordingController,
        count n: Int
    ) -> [UUID] {
        var ids: [UUID] = []
        for i in 0..<n {
            let id = UUID()
            ids.append(id)
            let idx = i
            let partialA = TranscriptSegment(
                id: id,
                timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                text: "u\(i)-partial",
                source: .system,
                model: "soniox"
            )
            let partialB = TranscriptSegment(
                id: id,
                timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                text: "u\(i)-partial-revised",
                source: .system,
                model: "soniox"
            )
            let final = TranscriptSegment(
                id: id,
                timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                lastUpdated: Date(timeIntervalSince1970: TimeInterval(i) + 1),
                text: "u\(i)-final",
                source: .system,
                model: "soniox",
                durationSec: 1.0,
                language: "en-US"
            )
            controller.applyTranscriptionEvent(.segmentAppended(index: idx, segment: partialA))
            controller.applyTranscriptionEvent(.segmentUpdated(index: idx, segment: partialB))
            controller.applyTranscriptionEvent(.segmentFinalized(index: idx, segment: final))
        }
        return ids
    }

    @Test("Below cap: each utterance produces exactly one final row, no duplicates")
    func belowCapHasNoDuplicates() {
        let c = RecordingController(logger: .init(label: "test.long.below"))
        let ids = driveUtterances(c, count: 50)

        #expect(c.transcriptSegments.count == 50)
        // Every row carries a unique id…
        let uniqueIds = Set(c.transcriptSegments.map(\.id))
        #expect(uniqueIds.count == c.transcriptSegments.count)
        // …and each utterance ended up with the FINAL text + duration.
        for (i, id) in ids.enumerated() {
            let row = c.transcriptSegments.first { $0.id == id }
            #expect(row?.text == "u\(i)-final")
            #expect(row?.durationSec == 1.0)
        }
    }

    @Test("Past cap: no duplicate ids in the panel array")
    func pastCapHasNoDuplicateIds() {
        let c = RecordingController(logger: .init(label: "test.long.dup"))
        let n = RecordingController.maxLiveTranscriptSegments + 25  // 125
        _ = driveUtterances(c, count: n)

        #expect(c.transcriptSegments.count == RecordingController.maxLiveTranscriptSegments)
        let allIds = c.transcriptSegments.map(\.id)
        let uniqueIds = Set(allIds)
        #expect(
            allIds.count == uniqueIds.count,
            "duplicate utterance ids present in transcriptSegments — the panel will render each line twice"
        )
    }

    @Test("Past cap: every retained row carries the FINAL text (not the stale partial)")
    func pastCapEveryRetainedRowIsFinal() {
        let c = RecordingController(logger: .init(label: "test.long.final"))
        let n = RecordingController.maxLiveTranscriptSegments + 25
        let ids = driveUtterances(c, count: n)

        // All rows should be the finalised counterpart — non-nil
        // duration, "u<i>-final" text. A stale partial would carry
        // "…-partial" or "…-partial-revised" and a nil duration.
        for row in c.transcriptSegments {
            #expect(row.durationSec == 1.0, "row \(row.id) is still a partial — finalize was misrouted")
            #expect(row.text.hasSuffix("-final"), "row \(row.id) carries stale partial text: \(row.text)")
        }

        // The retained window MUST be the most-recent N utterances —
        // exactly one entry per id, in original arrival order, with no
        // earlier-utterance regression.
        let retainedIds = c.transcriptSegments.map(\.id)
        let expectedSuffix = Array(ids.suffix(RecordingController.maxLiveTranscriptSegments))
        #expect(retainedIds == expectedSuffix)
    }

    @Test("Past cap: late `.segmentUpdated` for an evicted utterance is a silent no-op")
    func lateUpdateForEvictedUtteranceIsNoop() {
        let c = RecordingController(logger: .init(label: "test.long.lateupdate"))
        let n = RecordingController.maxLiveTranscriptSegments + 5
        let ids = driveUtterances(c, count: n)

        let evicted = ids[0]  // first utterance — evicted by the cap
        #expect(!c.transcriptSegments.contains { $0.id == evicted })

        let countBefore = c.transcriptSegments.count
        let lateUpdate = TranscriptSegment(
            id: evicted,
            timestamp: Date(),
            text: "stale-revision",
            source: .system,
            model: "soniox"
        )
        c.applyTranscriptionEvent(.segmentUpdated(index: 0, segment: lateUpdate))

        // Late update for an evicted utterance MUST NOT re-introduce
        // it, and MUST NOT corrupt some unrelated retained row.
        #expect(c.transcriptSegments.count == countBefore)
        #expect(!c.transcriptSegments.contains { $0.id == evicted })
        #expect(!c.transcriptSegments.contains { $0.text == "stale-revision" })
    }

    @Test("Past cap: late `.segmentFinalized` for an evicted utterance re-appears with final text")
    func lateFinalizeForEvictedUtteranceReAppears() {
        let c = RecordingController(logger: .init(label: "test.long.latefinal"))
        let n = RecordingController.maxLiveTranscriptSegments + 5
        let ids = driveUtterances(c, count: n)

        let evicted = ids[0]
        #expect(!c.transcriptSegments.contains { $0.id == evicted })

        let lateFinal = TranscriptSegment(
            id: evicted,
            timestamp: Date(),
            lastUpdated: Date().addingTimeInterval(2),
            text: "late-final",
            source: .system,
            model: "soniox",
            durationSec: 2.0,
            language: "en-US"
        )
        c.applyTranscriptionEvent(.segmentFinalized(index: 0, segment: lateFinal))

        // The row should re-appear — but only ONCE, and at the tail.
        let matches = c.transcriptSegments.filter { $0.id == evicted }
        #expect(matches.count == 1)
        #expect(c.transcriptSegments.last?.id == evicted)
        #expect(c.transcriptSegments.last?.text == "late-final")
        #expect(c.transcriptSegments.count == RecordingController.maxLiveTranscriptSegments)
    }
}
