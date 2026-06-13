import Testing
import Foundation
@testable import NtakkerUIKit
import NtakkerCore

@Suite("SourceLaneFilter (Phase C5)")
struct SourceLaneFilterTests {

    @Test("filters segments by source")
    func filtersBySource() {
        let segments: [TranscriptSegment] = [
            TranscriptSegment(timestamp: Date(), text: "sys", source: .system),
            TranscriptSegment(timestamp: Date(), text: "mic", source: .microphone),
        ]
        let onlySystem = SourceLaneFilter.segments(segments, for: .system)
        #expect(onlySystem.count == 1)
        #expect(onlySystem.first?.text == "sys")

        let onlyMic = SourceLaneFilter.segments(segments, for: .microphone)
        #expect(onlyMic.count == 1)
        #expect(onlyMic.first?.text == "mic")
    }

    @Test("empty list filters to empty")
    func emptyList() {
        let segments: [TranscriptSegment] = []
        #expect(SourceLaneFilter.segments(segments, for: .system).isEmpty)
        #expect(SourceLaneFilter.segments(segments, for: .microphone).isEmpty)
    }
}
