import Testing
@testable import NtakkerUIKit
import NtakkerCore

@Suite("LiveTranscriptPanelBranchSelector (Phase C6)")
struct LiveTranscriptPanelBranchSelectorTests {

    @Test(".both → sourceSplit")
    func bothSplits() {
        #expect(LiveTranscriptPanelBranchSelector.branch(source: .both) == .sourceSplit)
    }

    @Test(".system / .mic / .mixed → single")
    func nonBothIsSingle() {
        for src: TranscriptionSource in [.system, .mic, .mixed] {
            #expect(LiveTranscriptPanelBranchSelector.branch(source: src) == .single)
        }
    }
}
