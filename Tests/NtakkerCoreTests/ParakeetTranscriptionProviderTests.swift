import Testing
import Logging
@testable import NtakkerCore

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
        await #expect(throws: NtakkerError.self) {
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

    /// Regression for "Parakeet transcribe error: Invalid audio data
    /// provided. Must be at least 1 second of 16kHz audio." — FluidAudio's
    /// `AsrTranscription.swift:11` requires at least 16_000 samples. Our
    /// guard MUST short-circuit before that point or FluidAudio raises
    /// `ASRError.invalidAudioData` (which our code re-wraps as
    /// `transcriptionProviderUnavailable`). This case used to pass the
    /// 6_400-threshold guard and reach FluidAudio.
    @Test("transcribe returns empty for chunks shorter than 1 second (FluidAudio's minimum)")
    func belowOneSecondThreshold() async throws {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        // Boundary cases that previously fell INTO the buggy gap
        // (6_400 ≤ count < 16_000): the old guard passed them through,
        // FluidAudio rejected them. Both must short-circuit to "".
        for count in [6_400, 8_000, 12_000, 15_999] {
            let result = try await p.transcribe(
                samples: [Float](repeating: 0, count: count),
                source: .system,
                options: TranscriptionOptions(
                    providerId: "parakeet",
                    apiKey: nil,
                    modelId: nil,
                    customSystemInstruction: nil,
                    keyExpiresAt: nil
                )
            )
            #expect(result.isEmpty, "Sub-1s chunk (\(count) samples) must short-circuit before reaching FluidAudio")
        }
    }

    @Test("displayName surfaces the model id")
    func displayNameMentionsModel() {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        #expect(p.displayName.contains("parakeet-tdt-0.6b-v3"))
    }
}
