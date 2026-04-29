// Tests/MacrecCoreTests/Transcription/Providers/AppleSpeechTranscriptionProviderTests.swift
// — see docs/design/plan-005-apple-speech-streaming.md §"Phase D / Task D.3".
//
// Provider-surface unit tests. Intentionally limited to assertions on the
// stateless properties (id, displayName, supportedModes) because
// `openStreamingSession(...)` invokes `SpeechPermission.ensureGranted()`,
// which depends on real TCC state and is therefore not portable across
// dev hosts. End-to-end behaviour with TCC granted is covered by
// `e2e-transcription-apple.sh` in plan-005 Phase I.

import Foundation
import Testing
@testable import MacrecCore

// Note: the package's deployment target is `.macOS(.v26)`, so the
// `@available(macOS 26.0, *)` annotation that fences off
// `AppleSpeechTranscriptionProvider` in production is redundant inside
// the test target — and Swift Testing's `@Suite` / `@Test` macros refuse
// to be applied to types/functions carrying an explicit `@available` attribute.
@Suite("AppleSpeechTranscriptionProvider")
struct AppleSpeechTranscriptionProviderTests {

    @Test("supportedModes is .streaming only")
    func supportsStreamingOnly() {
        let p = AppleSpeechTranscriptionProvider(
            analyzerFactory: { _ in MockSpeechAnalyzer() })
        #expect(p.supportedModes == [.streaming])
    }

    @Test("id and displayName are constant")
    func identityProperties() {
        let p = AppleSpeechTranscriptionProvider(
            analyzerFactory: { _ in MockSpeechAnalyzer() })
        #expect(p.id == "apple")
        #expect(p.displayName == "Apple Speech (on-device)")
    }

    // openStreamingSession() goes through SpeechPermission.ensureGranted() which
    // requires real TCC state. Covered by e2e-transcription-apple.sh in Phase I.
}
