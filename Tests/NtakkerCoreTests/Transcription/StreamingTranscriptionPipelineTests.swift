// Tests/NtakkerCoreTests/Transcription/StreamingTranscriptionPipelineTests.swift
// — see docs/design/plan-005-apple-speech-streaming.md §"Phase E / Task E.3".
//
// Behavioural unit tests for `StreamingTranscriptionPipeline`. Drives the
// pipeline through `MockSpeechAnalyzer` (via `AppleSpeechTranscriptionProvider`)
// so the tests exercise the real per-utterance bookkeeping (id → segment
// index map, partial-vs-final dispatch, `.privacyDisclosure` ordering).
//
// CAVEAT: `AppleSpeechTranscriptionProvider.openStreamingSession(...)` calls
// `SpeechPermission.ensureGranted()`. On a TCC-denied dev host that throws
// `NtakkerError.transcriptionPermissionDenied`, the pipeline catches the
// error inside its session-open `Task`, yields a single `.error(...)` event
// and never produces partial / final results. The tests below assume the
// happy path (Speech permission granted) — when run on a TCC-denied host
// they will fail by emitting only `.privacyDisclosure` + `.error`. End-to-end
// behaviour with TCC granted is covered by `e2e-transcription-apple.sh` in
// plan-005 Phase I.
//
// Note: the package's deployment target is `.macOS(.v26)`, so the
// `@available(macOS 26.0, *)` annotation that fences off
// `StreamingTranscriptionPipeline` and `AppleSpeechTranscriptionProvider`
// in production is redundant inside the test target — and Swift Testing's
// `@Suite` / `@Test` macros refuse to be applied to types/functions
// carrying an explicit `@available` attribute.

import Foundation
import Testing
@testable import NtakkerCore
import Logging

@Suite("StreamingTranscriptionPipeline")
struct StreamingTranscriptionPipelineTests {

    @Test("first partial emits .segmentAppended; second partial for same utterance emits .segmentUpdated; final emits .segmentFinalized")
    func partialDispatchOrdering() async throws {
        let mock = MockSpeechAnalyzer()
        let provider = AppleSpeechTranscriptionProvider(
            analyzerFactory: { _ in mock })
        let opts = TranscriptionOptions(
            providerId: "apple",
            apiKey: nil,
            modelId: nil,
            languageHints: ["en-US"],
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )
        let pipeline = StreamingTranscriptionPipeline(
            provider: provider,
            source: .mic,
            options: opts,
            sidecarWriter: nil,
            logger: Logger(label: "test")
        )

        let stream = await pipeline.start()

        // Allow the session-open Task and the per-session drain Task to
        // attach before pushing canned results.
        try? await Task.sleep(for: .milliseconds(100))

        mock.push(TranscriptionResult(text: "he",
                                      confidence: 0.5,
                                      isFinal: false,
                                      timeRange: nil))
        mock.push(TranscriptionResult(text: "hello",
                                      confidence: 0.7,
                                      isFinal: false,
                                      timeRange: nil))
        mock.push(TranscriptionResult(text: "hello world",
                                      confidence: 0.9,
                                      isFinal: true,
                                      timeRange: nil))
        await pipeline.stop()

        var saw = (appended: 0, updated: 0, finalized: 0)
        for await ev in stream {
            switch ev {
            case .segmentAppended:  saw.appended += 1
            case .segmentUpdated:   saw.updated += 1
            case .segmentFinalized: saw.finalized += 1
            default: break
            }
        }
        #expect(saw.appended == 1)
        #expect(saw.updated >= 1)
        #expect(saw.finalized == 1)
    }
}
