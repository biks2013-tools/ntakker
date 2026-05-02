// Tests/MacrecCoreTests/Transcription/Providers/AppleSpeechSessionReconciliationTests.swift
// — see docs/design/plan-005-apple-speech-streaming.md §"Phase D / Task D.2".
//
// Behavioural unit tests for `AppleSpeechSession`'s dual-locale
// reconciliation. Drives the session through `MockSpeechAnalyzer`
// instances so the tests never touch `Speech.framework` and run
// deterministically regardless of TCC state.

import Foundation
import Testing
@testable import MacrecCore
import Logging

// Note: the package's deployment target is `.macOS(.v26)`, so the
// `@available(macOS 26.0, *)` annotation that fences off
// `AppleSpeechSession` in production is redundant inside the test
// target — and Swift Testing's `@Suite` / `@Test` macros refuse to be
// applied to types/functions carrying an explicit `@available` attribute.
@Suite("AppleSpeechSession reconciliation")
struct AppleSpeechSessionReconciliationTests {

    @Test("higher-confidence final wins per utterance")
    func higherConfidenceWins() async throws {
        let mockEN = MockSpeechAnalyzer()
        let mockEL = MockSpeechAnalyzer()
        let session = AppleSpeechSession(
            analyzers: [
                (Locale(identifier: "en-US"), mockEN),
                (Locale(identifier: "el-GR"), mockEL)
            ],
            source: .microphone,
            logger: Logger(label: "test")
        )

        // Allow drain Tasks to attach.
        try? await Task.sleep(for: .milliseconds(50))

        mockEN.push(TranscriptionResult(text: "hello world",
                                        confidence: 0.95,
                                        isFinal: true,
                                        timeRange: nil))
        mockEL.push(TranscriptionResult(text: "γεια σου",
                                        confidence: 0.42,
                                        isFinal: true,
                                        timeRange: nil))

        await session.finish()

        var finals: [String] = []
        var winnerLanguage: String?
        for await ev in session.events {
            if case .final(_, let text, _, _, let lang, _) = ev {
                finals.append(text)
                winnerLanguage = lang
            }
        }
        #expect(finals == ["hello world"])
        #expect(winnerLanguage == "en-US")
    }

    @Test("partial event surfaces immediately for first locale")
    func partialPropagates() async throws {
        let mockEN = MockSpeechAnalyzer()
        let session = AppleSpeechSession(
            analyzers: [(Locale(identifier: "en-US"), mockEN)],
            source: .microphone,
            logger: Logger(label: "test")
        )

        try? await Task.sleep(for: .milliseconds(50))

        mockEN.push(TranscriptionResult(text: "hello",
                                        confidence: 0.5,
                                        isFinal: false,
                                        timeRange: nil))
        await session.finish()

        var sawPartial = false
        for await ev in session.events {
            if case .partial(_, let text, _, _) = ev, text == "hello" {
                sawPartial = true
            }
        }
        #expect(sawPartial)
    }
}
