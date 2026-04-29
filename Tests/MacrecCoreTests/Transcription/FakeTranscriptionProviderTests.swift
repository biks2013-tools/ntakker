// MacrecCoreTests/Transcription/FakeTranscriptionProviderTests.swift
//
// Phase C (plan-004 rest-batch) — unit tests for the
// `FakeTranscriptionProvider`. Acceptance criteria:
//   (a) scripted text is returned in order;
//   (b) per-call counter increments and the last input is remembered.

import Foundation
import Testing
@testable import MacrecCore

@Suite("FakeTranscriptionProvider")
struct FakeTranscriptionProviderTests {

    private static func makeOptions() -> TranscriptionOptions {
        TranscriptionOptions(
            providerId: "fake",
            apiKey: nil,
            modelId: nil,
            languageHints: [],
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )
    }

    @Test("returns scripted text in order")
    func returnsScripted() async throws {
        let p = FakeTranscriptionProvider(script: ["one", "two", "three"])
        let opts = Self.makeOptions()
        let r1 = try await p.transcribe(samples: [0.1], source: .microphone, options: opts)
        let r2 = try await p.transcribe(samples: [0.1], source: .microphone, options: opts)
        let r3 = try await p.transcribe(samples: [0.1], source: .microphone, options: opts)
        #expect(r1 == "one"); #expect(r2 == "two"); #expect(r3 == "three")
    }

    @Test("counts calls and remembers last input")
    func counts() async throws {
        let p = FakeTranscriptionProvider(script: ["a"])
        let opts = Self.makeOptions()
        _ = try await p.transcribe(samples: [0.7], source: .system, options: opts)
        let count = await p.receivedCallCount
        let src = await p.lastSource
        #expect(count == 1)
        #expect(src == .system)
    }
}
