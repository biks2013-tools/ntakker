import Testing
import Logging
@testable import MacrecCore

@Suite("ParakeetTranscriptionProvider basic surface (Phase B2)")
struct ParakeetTranscriptionProviderTests {

    @Test("id is 'parakeet'")
    func providerId() {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        #expect(p.id == "parakeet")
    }

    @Test("supportedModes is .batch only")
    func batchOnly() {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        #expect(p.supportedModes == [.batch])
    }

    @Test("openStreamingSession throws transcriptionConfigConflict")
    func streamingThrows() async {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        await #expect(throws: MacrecError.self) {
            _ = try await p.openStreamingSession(
                source: .system,
                options: TranscriptionOptions(
                providerId: "parakeet",
                apiKey: nil,
                modelId: nil,
                customSystemInstruction: nil,
                keyExpiresAt: nil
            )
            )
        }
    }

    @Test("transcribe returns empty for sub-threshold sample count")
    func belowThreshold() async throws {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        let result = try await p.transcribe(
            samples: [Float](repeating: 0, count: 100),
            source: .system,
            options: TranscriptionOptions(
                providerId: "parakeet",
                apiKey: nil,
                modelId: nil,
                customSystemInstruction: nil,
                keyExpiresAt: nil
            )
        )
        #expect(result.isEmpty)
    }

    @Test("displayName surfaces the model id")
    func displayNameMentionsModel() {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        #expect(p.displayName.contains("parakeet-tdt-0.6b-v3"))
    }
}
