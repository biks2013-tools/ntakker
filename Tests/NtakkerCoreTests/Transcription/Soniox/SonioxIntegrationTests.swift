// Tests/NtakkerCoreTests/Transcription/Soniox/SonioxIntegrationTests.swift
//
// Plan-006 Phase D / Integration: end-to-end verification that
// `SonioxStreamingTranscriptionProvider`, driven by a
// `MockWebSocketTransport`, produces correct `TranscriptionEvent`
// output and sidecar JSONL when wired through the full
// `StreamingTranscriptionPipeline`.  No real Soniox API key is needed.
//
// Coverage (4 tests):
//
//   1. testPipelineIntegrationThreeUtteranceGreekTranscript
//      Build a full StreamingTranscriptionPipeline with a Soniox
//      provider whose transportFactory returns a MockWebSocketTransport
//      pre-loaded with 3 realistic utterances (Greek + English tokens).
//      Push audio, drive to completion, assert 3 `.segmentFinalized`
//      events land in the pipeline's public event stream AND a matching
//      JSONL sidecar is written with 3 non-empty lines and `model:soniox`.
//
//   2. testBilingualLanguageIdentificationOnFinalEvents
//      Pre-load mock with two token batches carrying different `language`
//      fields ("el" then "en").  Assert the resulting `.segmentFinalized`
//      events carry the correct `segment.language` attribute for each.
//
//   3. testDrainOnSessionFinishThroughPipeline
//      Pre-load mock with one non-final token + no marker, then trigger
//      pipeline.stop().  Assert the drain logic produces at least one
//      `.segmentFinalized` event for the buffered partial.
//
//   4. testTransportReceiveErrorIsNonFatalThroughPipeline
//      Inject a transport receive error mid-stream via the mock.  Assert
//      the pipeline emits the error as a `.error(detail:)` event and the
//      subsequent audio segments (if any) are still processed.  The
//      recording-level caller never sees a thrown error.
//
// Test framework: XCTest (matching the pattern established by
// SonioxStreamingSessionTests in this same directory).

import XCTest
@testable import NtakkerCore
import Foundation
import Logging

@available(macOS 26.0, *)
final class SonioxIntegrationTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Build a Soniox provider whose WebSocket transport is the supplied
    /// mock, and wire it into a `StreamingTranscriptionPipeline` that
    /// writes a JSONL sidecar at `sidecarURL`.
    ///
    /// - Parameters:
    ///   - mock: Pre-scripted `MockWebSocketTransport`.
    ///   - sidecarURL: Destination for the `.jsonl` transcript sidecar.
    ///     Pass `nil` to run without sidecar output.
    /// - Returns: The constructed pipeline (not yet started).
    private func makePipeline(
        transport mock: MockWebSocketTransport,
        sidecarURL: URL? = nil
    ) throws -> StreamingTranscriptionPipeline {

        let provider = SonioxStreamingTranscriptionProvider(
            apiKey: "integration-test-key",
            transportFactory: { mock }
        )

        let opts = TranscriptionOptions(
            providerId: "soniox",
            apiKey: "integration-test-key",
            modelId: nil,
            languageHints: ["el", "en"],
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )

        // Build the sidecar writer if a path was supplied.
        let writer: TranscriptSidecarWriter?
        if let url = sidecarURL {
            // Ensure the parent directory exists before constructing the
            // writer — SidecarWriter checks this and throws if absent.
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: nil
            )
            writer = try TranscriptSidecarWriter(
                outputPath: url,
                format: .jsonl,
                policy: .streaming
            )
        } else {
            writer = nil
        }

        return StreamingTranscriptionPipeline(
            provider: provider,
            source: .mic,
            options: opts,
            sidecarWriter: writer,
            logger: Logger(label: "soniox-integration-test")
        )
    }

    /// Pre-load `mock` with three realistic Soniox token-batch messages
    /// that produce three distinct utterances:
    ///
    ///   1. Greek utterance — "Καλημέρα" via `<end>` endpoint marker
    ///   2. English utterance — "Good morning" via `<end>` endpoint marker
    ///   3. Greek utterance — "ευχαριστώ" via `<fin>` finalize marker
    ///
    /// Followed by the terminal `{"finished":true,...}` envelope that
    /// closes the session event stream.
    ///
    /// Payload shapes match the `SonioxTokenAggregator` contract: within
    /// a single utterance, intermediate tokens carry `is_final: false`
    /// (which yields partials without flushing the buffer); only the
    /// last token in an utterance carries `is_final: true` (which flushes
    /// the buffer immediately), before the `<end>` / `<fin>` marker
    /// confirms the endpoint boundary.  This mirrors the "With `language`
    /// field" example in `docs/research/soniox-wire-schema.md` §3.1.
    private func enqueueThreeUtteranceGreekTranscript(
        on mock: MockWebSocketTransport
    ) async {

        // Utterance 1 — Greek "Καλημέρα" (single token, final, then <end>)
        // Single word — one token at is_final: true flushes, then <end>
        // is a marker that flushes again (empty buffer → no-op).
        let utterance1 = """
        {
          "tokens": [
            { "text": "Καλημέρα", "start_ms": 120, "end_ms": 480,
              "confidence": 0.97, "is_final": true, "language": "el" },
            { "text": "<end>", "start_ms": 480, "end_ms": 480,
              "confidence": 1.0, "is_final": true, "language": "el" }
          ],
          "final_audio_proc_ms": 480, "total_audio_proc_ms": 480
        }
        """
        await mock.enqueueIncomingText(utterance1)

        // Utterance 2 — English "Good morning"
        // Two tokens: first is non-final (partial), second is final
        // (flushes the buffer with combined text "Good morning"),
        // then <end> is a no-op flush (empty buffer).
        let utterance2 = """
        {
          "tokens": [
            { "text": "Good",    "start_ms": 600,  "end_ms": 750,
              "confidence": 0.80, "is_final": false, "language": "en" },
            { "text": " morning","start_ms": 750,  "end_ms": 980,
              "confidence": 0.95, "is_final": true, "language": "en" },
            { "text": "<end>",   "start_ms": 980,  "end_ms": 980,
              "confidence": 1.0,  "is_final": true, "language": "en" }
          ],
          "final_audio_proc_ms": 980, "total_audio_proc_ms": 980
        }
        """
        await mock.enqueueIncomingText(utterance2)

        // Utterance 3 — Greek "ευχαριστώ", finalized manually with <fin>
        // Single token, is_final: true, then <fin> marker (buffer is
        // already empty so <fin> does a no-op flush).
        let utterance3 = """
        {
          "tokens": [
            { "text": "ευχαριστώ", "start_ms": 1100, "end_ms": 1540,
              "confidence": 0.88, "is_final": true, "language": "el" },
            { "text": "<fin>",     "start_ms": 1540, "end_ms": 1540,
              "confidence": 1.0,  "is_final": true, "language": "el" }
          ],
          "final_audio_proc_ms": 1540, "total_audio_proc_ms": 1540
        }
        """
        await mock.enqueueIncomingText(utterance3)

        // Terminal envelope — closes the session's event stream.
        let finished = """
        {"tokens":[],"finished":true,"final_audio_proc_ms":1540,"total_audio_proc_ms":1540}
        """
        await mock.enqueueIncomingText(finished)
    }

    /// Collect `TranscriptionEvent`s from `stream` until it closes or
    /// `timeout` elapses. Returns whatever arrived.
    private func collectPipelineEvents(
        from stream: AsyncStream<TranscriptionEvent>,
        timeout: Duration = .seconds(5)
    ) async -> [TranscriptionEvent] {
        await withTaskGroup(of: [TranscriptionEvent].self) { group in
            group.addTask {
                var collected: [TranscriptionEvent] = []
                for await evt in stream {
                    collected.append(evt)
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    // MARK: - Test 1: Pipeline integration — three utterances → three finalised segments

    /// Verifies that the full `StreamingTranscriptionPipeline` wired
    /// through a Soniox provider and `MockWebSocketTransport` pre-loaded
    /// with three realistic utterances (Greek + English) produces:
    ///
    ///   a. Exactly three `.segmentFinalized` events in the public
    ///      pipeline event stream.
    ///   b. A sidecar JSONL file with exactly three non-empty, non-
    ///      tombstone lines, each carrying `model:"soniox"`.
    ///
    /// This tests the full path: provider → session → aggregator →
    /// pipeline event fan-out → sidecar writer.
    func testPipelineIntegrationThreeUtteranceGreekTranscript() async throws {

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sidecarURL = tmpDir.appendingPathComponent("recording.transcript.jsonl")

        let mock = MockWebSocketTransport()
        await enqueueThreeUtteranceGreekTranscript(on: mock)

        let pipeline = try makePipeline(transport: mock, sidecarURL: sidecarURL)
        let stream = await pipeline.start()

        // Allow the session-open Task time to attach.
        try await Task.sleep(for: .milliseconds(150))

        // Push a small audio buffer so the binary-send path exercises at
        // least one frame (the mock already has all server messages queued,
        // so the session immediately starts draining them).
        await pipeline.ingest([Float](repeating: 0.0, count: 160), from: .microphone)

        // Stop the pipeline — this calls session.finish(), which sends the
        // EOS sentinel and waits for the receive loop to drain, then closes
        // the public event stream.
        await pipeline.stop()

        // Collect all pipeline events (stream is now closed).
        let events = await collectPipelineEvents(from: stream)

        // --- Assert: public event stream has three finalized segments ---
        let finalized = events.compactMap { evt -> TranscriptSegment? in
            if case .segmentFinalized(_, let seg) = evt { return seg }
            return nil
        }
        XCTAssertEqual(
            finalized.count, 3,
            "expected exactly 3 .segmentFinalized events — got \(finalized.count). " +
            "All events: \(events)"
        )

        // The third finalized segment is the last one from the mock so
        // it must have originated from source .microphone (the pipeline's
        // source is .mic → .microphone tag).
        for seg in finalized {
            XCTAssertEqual(
                seg.model, "soniox",
                "every segment model must be 'soniox' — got \(String(describing: seg.model))"
            )
            XCTAssertEqual(
                seg.source, .microphone,
                "pipeline source is .mic → segments must carry .microphone tag"
            )
        }

        // --- Assert: sidecar JSONL has three content lines ---
        let rawFile = try String(contentsOf: sidecarURL, encoding: .utf8)
        let lines = rawFile
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        // Filter out tombstone lines (the JSONL writer may emit them for
        // in-place rewrites, but the streaming policy only calls
        // appendSegment — tombstones should be absent).
        let contentLines = lines.filter { !$0.contains("\"_tombstone\"") }

        XCTAssertEqual(
            contentLines.count, 3,
            "JSONL sidecar must contain exactly 3 content lines — got \(contentLines.count).\n" +
            "File content:\n\(rawFile)"
        )

        // Every JSONL line must contain `"model":"soniox"`.
        for line in contentLines {
            XCTAssertTrue(
                line.contains("\"model\":\"soniox\""),
                "every JSONL line must carry model:soniox — got: \(line)"
            )
        }

        // Cleanup.
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Test 2: Bilingual language identification on final events

    /// Verifies that when a `MockWebSocketTransport` is pre-loaded with
    /// two consecutive token batches where each carries a different
    /// `language` field ("el" then "en"), the resulting
    /// `.segmentFinalized` events carry the correct `segment.language`
    /// attribute.
    ///
    /// This tests FR-SX-10 (per-segment language tagging) and the
    /// aggregator's language-tracking logic through the full pipeline.
    func testBilingualLanguageIdentificationOnFinalEvents() async throws {

        let mock = MockWebSocketTransport()

        // First utterance: Greek (el) — two tokens, first non-final (partial),
        // second final (flushes buffer as one segment), then <end> (no-op).
        // This matches the aggregator contract: only one `is_final: true`
        // per utterance boundary so exactly one .final event is emitted.
        let greekBatch = """
        {
          "tokens": [
            { "text": "Γεια", "start_ms": 0, "end_ms": 200,
              "confidence": 0.88, "is_final": false, "language": "el" },
            { "text": " σου", "start_ms": 200, "end_ms": 400,
              "confidence": 0.93, "is_final": true, "language": "el" },
            { "text": "<end>", "start_ms": 400, "end_ms": 400,
              "confidence": 1.0, "is_final": true, "language": "el" }
          ],
          "final_audio_proc_ms": 400, "total_audio_proc_ms": 400
        }
        """
        await mock.enqueueIncomingText(greekBatch)

        // Second utterance: English (en) — two tokens, first non-final (partial),
        // second final (flushes buffer as one segment), then <end> (no-op).
        let englishBatch = """
        {
          "tokens": [
            { "text": "Hello", "start_ms": 500, "end_ms": 700,
              "confidence": 0.85, "is_final": false, "language": "en" },
            { "text": " there","start_ms": 700, "end_ms": 900,
              "confidence": 0.94, "is_final": true, "language": "en" },
            { "text": "<end>", "start_ms": 900, "end_ms": 900,
              "confidence": 1.0, "is_final": true, "language": "en" }
          ],
          "final_audio_proc_ms": 900, "total_audio_proc_ms": 900
        }
        """
        await mock.enqueueIncomingText(englishBatch)

        // Terminal envelope.
        await mock.enqueueIncomingText(
            #"{"tokens":[],"finished":true,"final_audio_proc_ms":900,"total_audio_proc_ms":900}"#
        )

        let pipeline = try makePipeline(transport: mock)
        let stream = await pipeline.start()

        try await Task.sleep(for: .milliseconds(150))
        await pipeline.ingest([Float](repeating: 0.0, count: 160), from: .microphone)
        await pipeline.stop()

        let events = await collectPipelineEvents(from: stream)

        let finalized = events.compactMap { evt -> TranscriptSegment? in
            if case .segmentFinalized(_, let seg) = evt { return seg }
            return nil
        }

        XCTAssertEqual(
            finalized.count, 2,
            "expected 2 finalized segments (one Greek, one English) — got \(finalized.count). " +
            "Events: \(events)"
        )

        guard finalized.count == 2 else { return }

        // First segment must be Greek (the aggregator preserves the
        // language of the last non-marker token in the buffer).
        XCTAssertEqual(
            finalized[0].language, "el",
            "first finalized segment must carry language 'el' — got \(String(describing: finalized[0].language))"
        )

        // Second segment must be English.
        XCTAssertEqual(
            finalized[1].language, "en",
            "second finalized segment must carry language 'en' — got \(String(describing: finalized[1].language))"
        )

        // Both segments must identify the model as soniox.
        XCTAssertEqual(finalized[0].model, "soniox")
        XCTAssertEqual(finalized[1].model, "soniox")
    }

    // MARK: - Test 3: Drain on session-finish through the pipeline

    /// Verifies that when the mock is pre-loaded with one non-final token
    /// (and no `<end>` / `<fin>` marker, and no `finished: true`
    /// envelope), calling `pipeline.stop()` causes the session's drain
    /// logic to flush the pending partial as a single `.segmentFinalized`
    /// event in the pipeline's public stream.
    ///
    /// This tests FR-SX-14 (stop drains in-flight provider work) and the
    /// pipeline-level drain call through the full stack.
    func testDrainOnSessionFinishThroughPipeline() async throws {

        let mock = MockWebSocketTransport()

        // One non-final token, no endpoint marker, no `finished` flag.
        // The session will buffer this as a partial and must flush it
        // when finish() is called.
        let partialBatch = """
        {
          "tokens": [
            { "text": "αντίο", "start_ms": 0, "end_ms": 300,
              "confidence": 0.80, "is_final": false, "language": "el" }
          ],
          "final_audio_proc_ms": 300, "total_audio_proc_ms": 300
        }
        """
        await mock.enqueueIncomingText(partialBatch)
        // No further messages — the server will not send a marker or
        // finished flag before we call stop().

        let pipeline = try makePipeline(transport: mock)
        let stream = await pipeline.start()

        // Give the receive loop time to surface the partial.
        try await Task.sleep(for: .milliseconds(200))

        // Stop the pipeline — this calls session.finish() which:
        //   1. Sends the EOS sentinel ("" empty text frame).
        //   2. Waits the finishGracePeriod (production default: 2 s;
        //      using production default here — this test is resilient
        //      because we just stop and collect without asserting exact timing).
        //   3. Calls aggregator.drain() which returns the pending partial
        //      as a `.final` event.
        // The pipeline handler converts that `.final` into a
        // `.segmentFinalized` event on the public stream.
        await pipeline.stop()

        let events = await collectPipelineEvents(from: stream)

        let finalized = events.compactMap { evt -> TranscriptSegment? in
            if case .segmentFinalized(_, let seg) = evt { return seg }
            return nil
        }

        XCTAssertGreaterThanOrEqual(
            finalized.count, 1,
            "drain on session-finish must emit at least one .segmentFinalized — " +
            "got \(finalized.count). All events: \(events)"
        )

        // The drained segment must contain "αντίο" (the buffered token text).
        let drainedText = finalized.map(\.text).joined()
        XCTAssertTrue(
            drainedText.contains("αντίο"),
            "drained segment text must contain 'αντίο' — got '\(drainedText)'"
        )

        // And it must carry the soniox model label.
        XCTAssertEqual(
            finalized.first?.model, "soniox",
            "drained segment model must be 'soniox'"
        )
    }

    // MARK: - Test 4: Transport receive error is non-fatal through the pipeline

    /// Verifies that injecting a transport-level receive error mid-stream
    /// (via `MockWebSocketTransport.enqueueIncomingError`) causes the
    /// pipeline to emit a `.error(detail:)` event rather than crashing or
    /// throwing out of `ingest` or `stop`.
    ///
    /// This tests NFR-SX-1 (recording integrity isolation): any failure
    /// inside the Soniox provider must be non-fatal to the recording
    /// pipeline.  The recording-level caller never sees a thrown error;
    /// the pipeline stays alive after the error event.
    func testTransportReceiveErrorIsNonFatalThroughPipeline() async throws {

        let mock = MockWebSocketTransport()

        // Inject a transport-level receive error — this is what would
        // happen if the network dropped mid-stream or the server closed
        // abruptly.
        struct SimulatedNetworkFailure: Error, Sendable {
            let description = "simulated network failure"
        }
        await mock.enqueueIncomingError(SimulatedNetworkFailure())

        // After the error, enqueue a normal utterance to verify the
        // pipeline can still process any messages that arrive (per the
        // mock's implementation the stream ends after an error, but we
        // want to confirm the pipeline doesn't hard-fault before then).
        // No additional messages needed — the mock will return nil after
        // the error since there are no more scripted events.

        let pipeline = try makePipeline(transport: mock)
        let stream = await pipeline.start()

        // Give the session's receive loop time to hit the injected error
        // and surface the `.error` event.
        try await Task.sleep(for: .milliseconds(200))

        // Ingest audio — this must NOT throw, even though the transport
        // error has occurred.  The pipeline is fire-and-forget.
        await pipeline.ingest([Float](repeating: 0.0, count: 160), from: .microphone)

        // Stop the pipeline cleanly.  This must also NOT throw.
        await pipeline.stop()

        // Collect all pipeline events.
        let events = await collectPipelineEvents(from: stream)

        // Assert: at least one `.error(detail:)` event was emitted.
        let errorEvents = events.compactMap { evt -> String? in
            if case .error(let detail) = evt { return detail }
            return nil
        }
        XCTAssertGreaterThanOrEqual(
            errorEvents.count, 1,
            "transport receive error must surface as .error(detail:) event — " +
            "got none. All events: \(events)"
        )

        // The error detail must reference a receive-level failure so
        // the operator can diagnose it from logs.
        let combinedDetail = errorEvents.joined()
        XCTAssertTrue(
            combinedDetail.lowercased().contains("receive") ||
            combinedDetail.lowercased().contains("network") ||
            combinedDetail.lowercased().contains("failed"),
            "error detail must mention the receive/network failure — got: \(combinedDetail)"
        )

        // Crucially: no `.segmentFinalized` events should have been
        // emitted (the error happened before any utterance completed).
        let finalized = events.filter {
            if case .segmentFinalized = $0 { return true }
            return false
        }
        XCTAssertEqual(
            finalized.count, 0,
            "a mid-stream transport error with no prior utterances must produce " +
            "zero .segmentFinalized events — got \(finalized.count)"
        )
    }
}
