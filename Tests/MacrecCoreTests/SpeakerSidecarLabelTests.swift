import Testing
@testable import MacrecCore

@Suite("SpeakerSidecarLabel")
struct SpeakerSidecarLabelTests {

    @Test("Soniox spk:N maps to S<N>")
    func sonioxFormat() {
        #expect(SpeakerSidecarLabel.label(for: "spk:1") == "S1")
        #expect(SpeakerSidecarLabel.label(for: "spk:42") == "S42")
    }

    @Test("nil returns nil")
    func nilPassthrough() {
        #expect(SpeakerSidecarLabel.label(for: nil) == nil)
    }

    @Test("empty string returns nil")
    func emptyReturnsNil() {
        #expect(SpeakerSidecarLabel.label(for: "") == nil)
    }

    @Test("opaque string falls back to the raw value uppercased")
    func opaqueFallback() {
        #expect(SpeakerSidecarLabel.label(for: "alice") == "ALICE")
    }

    @Test("malformed spk: prefix without suffix falls back to uppercased raw")
    func malformedPrefixFallsBack() {
        #expect(SpeakerSidecarLabel.label(for: "spk:") == "SPK:")
    }
}
