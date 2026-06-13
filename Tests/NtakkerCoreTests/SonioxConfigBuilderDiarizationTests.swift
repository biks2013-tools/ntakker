import Testing
@testable import NtakkerCore

@Suite("SonioxConfigBuilder diarization default (Phase A2)")
struct SonioxConfigBuilderDiarizationTests {

    @Test("default enables speaker diarization")
    func defaultIsTrue() {
        let msg = SonioxConfigBuilder.build(
            apiKey: "k",
            languageHints: ["en"]
        )
        #expect(msg.enableSpeakerDiarization == true)
    }

    @Test("explicit false override is honoured")
    func overrideFalse() {
        let msg = SonioxConfigBuilder.build(
            apiKey: "k",
            languageHints: ["en"],
            diarize: false
        )
        #expect(msg.enableSpeakerDiarization == false)
    }

    @Test("explicit true override is honoured")
    func overrideTrue() {
        let msg = SonioxConfigBuilder.build(
            apiKey: "k",
            languageHints: ["en"],
            diarize: true
        )
        #expect(msg.enableSpeakerDiarization == true)
    }
}
