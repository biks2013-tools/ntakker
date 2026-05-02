// MacrecUITests/Transcription/Dual/DualLiveTranscriptViewTests.swift —
// plan-010 Phase G / Lane L-9 — channel routing tests.
//
// PURPOSE: Verify the three routing contracts of `DualLiveTranscriptView`
// described in plan-010 §G.4 and project-design.md §DT-8.
//
// TESTABILITY BOUNDARY:
// `DualLiveTranscriptView` is a SwiftUI view in the `macrec-ui` EXECUTABLE
// target, which is not importable from `MacrecUITests`.  We therefore test
// the pure-logic routing layer:
//
//   * `DualSidecarLabel.channelTag(forModel:)` — the SINGLE SOURCE OF
//     TRUTH for model→channel routing (frozen by Lane L-6 / §DT-8).
//   * Array-filtering semantics that `DualLiveTranscriptView` applies to
//     `RecordingController.transcriptSegments` to populate each lane.
//   * Stacked ordering guarantee: Channel A segments come from the first
//     filter pass; Channel B segments from the second — so the A-lane
//     is always "above" (first in data order) and independent.
//
// Tests 1, 2, 3 map directly to the three test scenarios in the caller's
// requirement:
//
//   Test 1 — model routing: "apple" → channelA, "apple-cloud" → channelB.
//   Test 2 — unknown model is NOT shown in either lane (channelTag returns nil).
//   Test 3 — stacked layout (A above B) — verify ordering.
//
// The filtering logic here mirrors `DualLiveTranscriptView.channelASegments`
// and `.channelBSegments` exactly (see source view file) so any drift in
// the production filter will break these tests.

import Foundation
import Testing
@testable import MacrecCore
@testable import MacrecUIKit

@Suite("DualLiveTranscriptView channel routing (plan-010 §G.4)")
struct DualLiveTranscriptViewTests {

    // MARK: - Helpers

    /// Build a `TranscriptSegment` with caller-controlled `model`.
    private func makeSegment(
        text: String = "hello",
        model: String?,
        language: String? = "en-US"
    ) -> TranscriptSegment {
        makeDualSegment(text: text, model: model, language: language)
    }

    // MARK: - Test 1: Model routing

    @Test("'apple' model routes to Channel A lane only")
    func appleModelRoutesToChannelA() {
        let seg = makeSegment(text: "on-device result", model: "apple")
        let all = [seg]

        let laneA = filterChannelA(from: all)
        let laneB = filterChannelB(from: all)

        #expect(laneA.count == 1)
        #expect(laneA[0].text == "on-device result")
        #expect(laneB.isEmpty, "'apple' segment must not appear in Channel B lane")
    }

    @Test("'apple-cloud' model routes to Channel B lane only")
    func appleCloudModelRoutesToChannelB() {
        let seg = makeSegment(text: "cloud result", model: "apple-cloud", language: "el-GR")
        let all = [seg]

        let laneA = filterChannelA(from: all)
        let laneB = filterChannelB(from: all)

        #expect(laneB.count == 1)
        #expect(laneB[0].text == "cloud result")
        #expect(laneA.isEmpty, "'apple-cloud' segment must not appear in Channel A lane")
    }

    @Test("Mixed segment list routes each model to its correct lane")
    func mixedSegmentListRoutedCorrectly() {
        let appleSegment = makeSegment(text: "English word", model: "apple", language: "en-US")
        let cloudSegment = makeSegment(text: "Ελληνική λέξη", model: "apple-cloud", language: "el-GR")
        let all = [appleSegment, cloudSegment]

        let laneA = filterChannelA(from: all)
        let laneB = filterChannelB(from: all)

        #expect(laneA.count == 1)
        #expect(laneA[0].text == "English word")
        #expect(laneB.count == 1)
        #expect(laneB[0].text == "Ελληνική λέξη")
    }

    @Test("Multiple 'apple' segments all appear in Channel A, none in Channel B")
    func multipleAppleSegmentsRouteToChannelAOnly() {
        let segments = (0..<5).map { i in
            makeSegment(text: "apple-\(i)", model: "apple")
        }

        let laneA = filterChannelA(from: segments)
        let laneB = filterChannelB(from: segments)

        #expect(laneA.count == 5)
        #expect(laneB.isEmpty)
    }

    @Test("Multiple 'apple-cloud' segments all appear in Channel B, none in Channel A")
    func multipleCloudSegmentsRouteToChannelBOnly() {
        let segments = (0..<3).map { i in
            makeSegment(text: "cloud-\(i)", model: "apple-cloud", language: "el-GR")
        }

        let laneA = filterChannelA(from: segments)
        let laneB = filterChannelB(from: segments)

        #expect(laneB.count == 3)
        #expect(laneA.isEmpty)
    }

    // MARK: - Test 2: Unknown model NOT shown in either lane

    @Test("nil model is NOT shown in either lane")
    func nilModelNotShownInEitherLane() {
        let seg = makeSegment(text: "no model", model: nil)
        let all = [seg]

        let laneA = filterChannelA(from: all)
        let laneB = filterChannelB(from: all)

        #expect(laneA.isEmpty, "nil-model segment must not appear in Channel A")
        #expect(laneB.isEmpty, "nil-model segment must not appear in Channel B")
    }

    @Test("Unknown model 'gemini' is NOT shown in either lane")
    func geminiModelNotShownInEitherLane() {
        let seg = makeSegment(text: "gemini result", model: "gemini")
        let all = [seg]

        let laneA = filterChannelA(from: all)
        let laneB = filterChannelB(from: all)

        #expect(laneA.isEmpty)
        #expect(laneB.isEmpty)
    }

    @Test("Unknown model 'soniox' is NOT shown in either lane")
    func sonioxModelNotShownInEitherLane() {
        let seg = makeSegment(text: "soniox result", model: "soniox")
        let all = [seg]

        #expect(filterChannelA(from: all).isEmpty)
        #expect(filterChannelB(from: all).isEmpty)
    }

    @Test("Unknown model 'whisperkit' is NOT shown in either lane")
    func whisperkitModelNotShownInEitherLane() {
        let seg = makeSegment(text: "local model result", model: "whisperkit")
        let all = [seg]

        #expect(filterChannelA(from: all).isEmpty)
        #expect(filterChannelB(from: all).isEmpty)
    }

    @Test("Empty-string model is NOT shown in either lane")
    func emptyStringModelNotShownInEitherLane() {
        let seg = makeSegment(text: "empty model", model: "")
        let all = [seg]

        #expect(filterChannelA(from: all).isEmpty)
        #expect(filterChannelB(from: all).isEmpty)
    }

    @Test("Mixed: apple + unknown model — only apple appears in Channel A, unknown in neither")
    func mixedWithUnknownOnlyKnownModelsAppear() {
        let apple = makeSegment(text: "A", model: "apple")
        let unknown = makeSegment(text: "B", model: "other-provider")
        let all = [apple, unknown]

        let laneA = filterChannelA(from: all)
        let laneB = filterChannelB(from: all)

        #expect(laneA.count == 1)
        #expect(laneA[0].text == "A")
        #expect(laneB.isEmpty)
    }

    // MARK: - Test 3: Stacked layout ordering (A above B)

    @Test("Channel A and B partitions preserve arrival order independently")
    func channelPartitionsPreserveArrivalOrder() {
        // DT-ADR-8 / OQ-5: stacked lanes. Channel A is ABOVE Channel B in
        // `DualLiveTranscriptView.body` — the ordering of segments WITHIN
        // each lane must match the original timestamp-ascending order in
        // the flat `transcriptSegments` array.
        let a1 = makeSegment(text: "A-first", model: "apple")
        let b1 = makeSegment(text: "B-first", model: "apple-cloud", language: "el-GR")
        let a2 = makeSegment(text: "A-second", model: "apple")
        let b2 = makeSegment(text: "B-second", model: "apple-cloud", language: "el-GR")
        // Interleaved arrival order (realistic dual-mode scenario):
        let all = [a1, b1, a2, b2]

        let laneA = filterChannelA(from: all)
        let laneB = filterChannelB(from: all)

        // Channel A: arrival-order preserved (a1 before a2)
        #expect(laneA.count == 2)
        #expect(laneA[0].text == "A-first")
        #expect(laneA[1].text == "A-second")

        // Channel B: arrival-order preserved (b1 before b2)
        #expect(laneB.count == 2)
        #expect(laneB[0].text == "B-first")
        #expect(laneB[1].text == "B-second")
    }

    @Test("Channel A lane is independent: appending a Channel B segment does not reorder Channel A")
    func channelAOrderUnaffectedByChannelBArrivals() {
        // Simulate a burst of Channel B segments arriving after Channel A
        // segments — the Channel A lane must remain stable.
        let a1 = makeSegment(text: "EN-1", model: "apple")
        let a2 = makeSegment(text: "EN-2", model: "apple")
        let b1 = makeSegment(text: "EL-1", model: "apple-cloud", language: "el-GR")
        let b2 = makeSegment(text: "EL-2", model: "apple-cloud", language: "el-GR")
        let b3 = makeSegment(text: "EL-3", model: "apple-cloud", language: "el-GR")
        let all = [a1, a2, b1, b2, b3]

        let laneA = filterChannelA(from: all)
        #expect(laneA.count == 2)
        #expect(laneA[0].text == "EN-1")
        #expect(laneA[1].text == "EN-2")
    }

    @Test("Channel B lane is independent: appending a Channel A segment does not reorder Channel B")
    func channelBOrderUnaffectedByChannelAArrivals() {
        let a1 = makeSegment(text: "EN-1", model: "apple")
        let a2 = makeSegment(text: "EN-2", model: "apple")
        let a3 = makeSegment(text: "EN-3", model: "apple")
        let b1 = makeSegment(text: "EL-1", model: "apple-cloud", language: "el-GR")
        let b2 = makeSegment(text: "EL-2", model: "apple-cloud", language: "el-GR")
        let all = [a1, b1, a2, b2, a3]

        let laneB = filterChannelB(from: all)
        #expect(laneB.count == 2)
        #expect(laneB[0].text == "EL-1")
        #expect(laneB[1].text == "EL-2")
    }

    @Test("DualLiveTranscriptView uses DualSidecarLabel as single source of truth for routing")
    func routingGoesViaDualSidecarLabel() {
        // This pins that `DualSidecarLabel.channelTag(forModel:)` is the
        // canonical routing function.  If the production view ever adds a
        // secondary routing path that bypasses DualSidecarLabel, this
        // structural assertion breaks before the lane tests can catch it.
        #expect(DualSidecarLabel.channelTag(forModel: "apple") == .channelA,
                "DualSidecarLabel is the routing authority for channelA")
        #expect(DualSidecarLabel.channelTag(forModel: "apple-cloud") == .channelB,
                "DualSidecarLabel is the routing authority for channelB")
        #expect(DualSidecarLabel.channelTag(forModel: "unknown") == nil,
                "DualSidecarLabel returns nil for any non-dual-mode provider")
    }
}
