// NtakkerCoreTests/Transcription/NoOpTranscriptionProviderTests.swift
//
// Phase C (plan-004 rest-batch) — unit tests for the
// `NoOpTranscriptionProvider`. The provider returns "" for every call
// regardless of the input audio buffer.

import Foundation
import Testing
@testable import NtakkerCore

@Suite("NoOpTranscriptionProvider")
struct NoOpTranscriptionProviderTests {
    @Test("returns empty string regardless of input")
    func returnsEmpty() async throws {
        let p = NoOpTranscriptionProvider()
        let opts = TranscriptionOptions(
            providerId: "none",
            apiKey: nil,
            modelId: nil,
            languageHints: [],
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )
        let out = try await p.transcribe(
            samples: Array(repeating: Float(0.5), count: 16_000),
            source: .microphone, options: opts)
        #expect(out == "")
    }
}
