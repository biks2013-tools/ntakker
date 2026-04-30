// MacrecUITests/Transcription/LiveTranscriptPanelTests.swift — see
// plan-003 §4 Phase G ("Tests to create") and project-design.md
// §LT-8.5, refreshed for plan-004 Phase H (rest-batch event shape).
//
// The SwiftUI `LiveTranscriptPanel` view lives in the macrec-ui
// executable target and is not directly importable from this test
// target. The controller-side behavior the panel renders IS testable
// here:
//
//   * Empty state — `transcriptSegments.isEmpty &&
//     transcriptionStatus == .idle` (the panel hides itself).
//   * `segmentAppended` events extend the array.
//   * `segmentUpdated` events replace in place.
//   * Cap at `maxLiveTranscriptSegments` (drop-oldest when over the
//     cap).
//   * `metricsTick` flips status to `.active` and clears any prior
//     transient error.
//   * `error(detail:)` flips status to `.error(detail)` and surfaces
//     the message via `lastTranscriptionError`.

import Foundation
import Testing
@testable import MacrecCore
@testable import MacrecUIKit

@MainActor
@Suite("LiveTranscriptPanel behavior (via RecordingController)")
struct LiveTranscriptPanelTests {

    private func makeController() -> RecordingController {
        RecordingController(logger: .init(label: "test"))
    }

    private func makeSegment(
        text: String = "hello",
        source: SourceTag = .system
    ) -> TranscriptSegment {
        TranscriptSegment(
            timestamp: Date(),
            text: text,
            source: source
        )
    }

    @Test("Initial state: transcriptSegments empty, status idle, no error")
    func initialState() {
        let c = makeController()
        #expect(c.transcriptSegments.isEmpty)
        #expect(c.transcriptionStatus == .idle)
        #expect(c.lastTranscriptionError == nil)
        #expect(c.pendingDisclosure == nil)
    }

    @Test("maxLiveTranscriptSegments is 100 (panel cap from design §LT-8.5)")
    func capIs100() {
        #expect(RecordingController.maxLiveTranscriptSegments == 100)
        // Source-compat alias used by older callers.
        #expect(RecordingController.maxLiveTranscriptLines == 100)
    }

    @Test("TranscriptionUIState equality covers every case (idle/active/error)")
    func uiStateEquality() {
        #expect(TranscriptionUIState.idle == .idle)
        #expect(TranscriptionUIState.active == .active)
        #expect(TranscriptionUIState.error("x") == .error("x"))
        #expect(TranscriptionUIState.error("x") != .error("y"))
        #expect(TranscriptionUIState.active != .idle)
    }

    @Test("TranscriptionMetrics default has all-zero counters")
    func metricsEmptyIsZero() {
        let m = TranscriptionMetrics()
        #expect(m.chunksSent == 0)
        #expect(m.billableSeconds == 0)
        #expect(m.lastRttMs == 0)
        #expect(m.errorCount == 0)
        #expect(m.bufferOverflowCount == 0)
    }

    @Test("Two TranscriptSegments with the same text have distinct ids")
    func segmentIdsAreUnique() {
        let a = makeSegment(text: "hello")
        let b = makeSegment(text: "hello")
        #expect(a.id != b.id)
    }

    @Test("clearTranscriptSegments is a safe no-op on a fresh controller")
    func clearOnFreshControllerIsNoOp() {
        let c = makeController()
        c.clearTranscriptSegments()
        #expect(c.transcriptSegments.isEmpty)
        #expect(c.lastTranscriptionError == nil)
        #expect(c.transcriptionStatus == .idle)
    }
}

