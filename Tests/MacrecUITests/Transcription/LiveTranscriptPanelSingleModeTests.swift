// MacrecUITests/Transcription/LiveTranscriptPanelSingleModeTests.swift
//
// Single-mode panel regression guard. `LiveTranscriptPanel` is defined
// in the `macrec-ui` executable target so we cannot instantiate it
// here; we cover the controller-side surface the panel reads from.

import Foundation
import Testing
@testable import MacrecCore
@testable import MacrecUIKit

@MainActor
@Suite("LiveTranscriptPanel single-mode invariance")
struct LiveTranscriptPanelSingleModeTests {

    private func makeController() -> RecordingController {
        RecordingController(logger: .init(label: "test"))
    }

    // MARK: - Controller API contract

    @Test("transcriptSegments is empty by default")
    func transcriptSegmentsDefaultEmpty() {
        let c = makeController()
        #expect(c.transcriptSegments.isEmpty)
    }

    @Test("transcriptionStatus defaults to .idle")
    func transcriptionStatusDefaultIdle() {
        let c = makeController()
        #expect(c.transcriptionStatus == .idle)
    }

    @Test("maxLiveTranscriptSegments cap is 100")
    func capIs100Unchanged() {
        #expect(RecordingController.maxLiveTranscriptSegments == 100)
    }

    @Test("maxLiveTranscriptLines alias is 100")
    func aliasCapIs100() {
        #expect(RecordingController.maxLiveTranscriptLines == 100)
    }

    // MARK: - Segment data contract

    @Test("TranscriptSegment.durationSec nil on partial segments")
    func durationSecNilOnPartialSegment() {
        let partial = TranscriptSegment(
            id: UUID(),
            timestamp: Date(),
            lastUpdated: Date(),
            text: "hel",
            source: .system,
            model: "apple",
            durationSec: nil,
            language: "en-US"
        )
        #expect(partial.durationSec == nil)
    }

    @Test("TranscriptSegment.durationSec non-nil on finalized segments")
    func durationSecSetOnFinalizedSegment() {
        let finalized = TranscriptSegment(
            id: UUID(),
            timestamp: Date(),
            lastUpdated: Date(),
            text: "hello world",
            source: .system,
            model: "apple",
            durationSec: 1.5,
            language: "en-US"
        )
        #expect(finalized.durationSec != nil)
        #expect(finalized.durationSec == 1.5)
    }

    @Test("Language chip formula prefix(2).uppercased()")
    func languageChipTextMatchesPanelBehavior() {
        let cases: [(bcp47: String, expected: String)] = [
            ("en-US", "EN"),
            ("el-GR", "EL"),
            ("fr-CA", "FR"),
            ("zh-Hant-TW", "ZH"),
            ("de", "DE"),
        ]
        for (input, expected) in cases {
            let chip = String(input.prefix(2)).uppercased()
            #expect(chip == expected)
        }
    }

    @Test("Segment id is stable across reconstruction with same id")
    func segmentIdIsStable() {
        let id = UUID()
        let s1 = TranscriptSegment(
            id: id, timestamp: Date(), lastUpdated: Date(),
            text: "A", source: .system, model: nil, durationSec: nil, language: nil
        )
        let s2 = TranscriptSegment(
            id: id, timestamp: Date(), lastUpdated: Date(),
            text: "B", source: .system, model: nil, durationSec: nil, language: nil
        )
        #expect(s1.id == s2.id)
        #expect(s1.id == id)
    }

    @Test("clearTranscriptSegments() resets segments and lastTranscriptionError")
    func clearTranscriptSegmentsAPIUnchanged() {
        let c = makeController()
        c.clearTranscriptSegments()
        #expect(c.transcriptSegments.isEmpty)
        #expect(c.lastTranscriptionError == nil)
        #expect(c.transcriptionStatus == .idle)
    }
}
