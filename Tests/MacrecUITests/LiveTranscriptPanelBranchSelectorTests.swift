import Testing
@testable import MacrecUIKit
import MacrecCore

@Suite("LiveTranscriptPanelBranchSelector (Phase C6)")
struct LiveTranscriptPanelBranchSelectorTests {

    @Test("dual mode wins regardless of source")
    func dualWins() {
        for src in TranscriptionSource.allCases {
            #expect(LiveTranscriptPanelBranchSelector.branch(mode: .dual, source: src) == .dual)
        }
    }

    @Test("single mode + .both → sourceSplit")
    func singleBoth() {
        #expect(LiveTranscriptPanelBranchSelector.branch(mode: .single, source: .both) == .sourceSplit)
    }

    @Test("single mode + .system / .mic / .mixed → single (DT-INV preservation)")
    func singleNonBoth() {
        for src: TranscriptionSource in [.system, .mic, .mixed] {
            #expect(LiveTranscriptPanelBranchSelector.branch(mode: .single, source: src) == .single)
        }
    }
}
