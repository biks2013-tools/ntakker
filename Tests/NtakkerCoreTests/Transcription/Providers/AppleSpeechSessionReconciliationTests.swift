// Tests/NtakkerCoreTests/Transcription/Providers/AppleSpeechSessionReconciliationTests.swift
// — see docs/design/plan-005-apple-speech-streaming.md §"Phase D / Task D.2".
//
// Behavioural unit tests for `AppleSpeechSession`'s dual-locale
// reconciliation. Drives the session through `MockSpeechAnalyzer`
// instances so the tests never touch `Speech.framework` and run
// deterministically regardless of TCC state.

import Foundation
import Testing
@testable import NtakkerCore
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

    // MARK: - EVAL-2026-10-16 TR-5

    private func dualSession() -> (AppleSpeechSession, MockSpeechAnalyzer, MockSpeechAnalyzer) {
        let en = MockSpeechAnalyzer()
        let el = MockSpeechAnalyzer()
        let session = AppleSpeechSession(
            analyzers: [(Locale(identifier: "en-US"), en), (Locale(identifier: "el-GR"), el)],
            source: .microphone,
            logger: Logger(label: "test")
        )
        return (session, en, el)
    }

    private func range(_ start: Double, _ end: Double) -> ClosedRange<Date> {
        Date(timeIntervalSince1970: start)...Date(timeIntervalSince1970: end)
    }

    @Test("partials from both locales share one utterance id with the final")
    func partialsShareTheFinalId() async throws {
        let (session, en, el) = dualSession()
        try? await Task.sleep(for: .milliseconds(50))
        en.push(TranscriptionResult(text: "hel", confidence: nil, isFinal: false, timeRange: nil))
        try? await Task.sleep(for: .milliseconds(20))
        el.push(TranscriptionResult(text: "χελ", confidence: nil, isFinal: false, timeRange: nil))
        try? await Task.sleep(for: .milliseconds(20))
        en.push(TranscriptionResult(text: "hello", confidence: 0.9, isFinal: true, timeRange: range(0, 1)))
        el.push(TranscriptionResult(text: "χέλο", confidence: 0.3, isFinal: true, timeRange: range(0, 1)))
        await session.finish()

        var ids = Set<UUID>()
        var finals: [String] = []
        for await ev in session.events {
            switch ev {
            case let .partial(id, _, _, _): ids.insert(id)
            case let .final(id, text, _, _, _, _): ids.insert(id); finals.append(text)
            default: break
            }
        }
        #expect(finals == ["hello"])
        #expect(ids.count == 1, "no orphan partial rows")
    }

    @Test("two utterances in a row reconcile separately")
    func consecutiveUtterances() async throws {
        let (session, en, el) = dualSession()
        try? await Task.sleep(for: .milliseconds(50))
        en.push(TranscriptionResult(text: "first", confidence: 0.9, isFinal: true, timeRange: range(0, 1)))
        el.push(TranscriptionResult(text: "φερστ", confidence: 0.2, isFinal: true, timeRange: range(0, 1)))
        try? await Task.sleep(for: .milliseconds(30))
        en.push(TranscriptionResult(text: "δεύτερο?", confidence: 0.1, isFinal: true, timeRange: range(1, 2)))
        el.push(TranscriptionResult(text: "δεύτερο", confidence: 0.8, isFinal: true, timeRange: range(1, 2)))
        await session.finish()

        var finals: [String] = []
        for await ev in session.events {
            if case let .final(_, text, _, _, _, _) = ev { finals.append(text) }
        }
        #expect(finals == ["first", "δεύτερο"])
    }

    @Test("a straggler final after reconciliation is dropped")
    func stragglerDropped() async throws {
        let (session, en, el) = dualSession()
        try? await Task.sleep(for: .milliseconds(50))
        en.push(TranscriptionResult(text: "hello", confidence: 0.9, isFinal: true, timeRange: range(0, 1)))
        // The window expires before el reports.
        try? await Task.sleep(for: .milliseconds(AppleSpeechSession.reconciliationWindowMs + 150))
        el.push(TranscriptionResult(text: "χέλο", confidence: 0.3, isFinal: true, timeRange: range(0.1, 1)))
        await session.finish()

        var finals: [String] = []
        for await ev in session.events {
            if case let .final(_, text, _, _, _, _) = ev { finals.append(text) }
        }
        #expect(finals == ["hello"])
    }

    @Test("back-to-back ranges that only touch are different utterances")
    func touchingRangesDoNotOverlap() {
        #expect(!AppleSpeechSession.overlaps(range(0, 1), range(1, 2)))
        #expect(AppleSpeechSession.overlaps(range(0, 1), range(0.2, 1.1)))
    }
}

