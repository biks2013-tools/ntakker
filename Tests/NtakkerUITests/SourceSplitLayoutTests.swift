import Testing
import Foundation
@testable import NtakkerUIKit
import NtakkerCore

/// The source-split transcript's resizable divider and synced
/// scrolling (2026-10-21).
@Suite("SourceSplitLayout")
struct SourceSplitLayoutTests {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("dragging the divider moves the share by translation / available, within limits")
    func dragFraction() {
        #expect(SourceSplitLayout.fraction(start: 0.5, translation: 50, available: 200) == 0.75)
        #expect(SourceSplitLayout.fraction(start: 0.5, translation: -500, available: 200) == SourceSplitLayout.minFraction)
        #expect(SourceSplitLayout.fraction(start: 0.5, translation: 500, available: 200) == 1 - SourceSplitLayout.minFraction)
        #expect(SourceSplitLayout.fraction(start: 0.4, translation: 30, available: 0) == 0.4)
        #expect(SourceSplitLayout.clamped(.nan) == SourceSplitLayout.defaultFraction)
    }

    @Test("the aligned line is the last one that started at or before the moment")
    func alignedLine() {
        let mic = [0.0, 10, 20].map {
            TranscriptSegment(timestamp: t0.addingTimeInterval($0), text: "m\($0)", source: .microphone)
        }
        #expect(SourceSplitLayout.alignedSegmentID(in: mic, at: t0.addingTimeInterval(15)) == mic[1].id)
        #expect(SourceSplitLayout.alignedSegmentID(in: mic, at: t0.addingTimeInterval(20)) == mic[2].id)
        #expect(SourceSplitLayout.alignedSegmentID(in: mic, at: t0.addingTimeInterval(-5)) == mic[0].id)
        #expect(SourceSplitLayout.alignedSegmentID(in: [], at: t0) == nil)
    }
}
