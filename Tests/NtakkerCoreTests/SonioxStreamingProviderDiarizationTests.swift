import Testing
import Foundation
@testable import NtakkerCore

@Suite("SonioxStreamingTranscriptionProvider.diarize plumbing (Phase A3)")
struct SonioxStreamingProviderDiarizationTests {

    @Test("provider exposes its diarize value")
    func diarizeReadable() async {
        let provider = SonioxStreamingTranscriptionProvider(
            apiKey: "k",
            diarize: false
        )
        #expect(await provider.currentDiarize() == false)
    }

    @Test("default constructor preserves builder default (true)")
    func defaultMatchesBuilder() async {
        let provider = SonioxStreamingTranscriptionProvider(apiKey: "k")
        #expect(await provider.currentDiarize() == SonioxConfigBuilder.defaultDiarize)
    }
}
