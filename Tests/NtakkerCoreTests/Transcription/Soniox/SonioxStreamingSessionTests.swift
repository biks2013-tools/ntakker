// Tests/NtakkerCoreTests/Transcription/Soniox/SonioxStreamingSessionTests.swift
//
// Plan-006 Phase D / Unit D2: integration-style tests for
// `SonioxStreamingSession` exercised against `MockWebSocketTransport`.
//
// Coverage:
//   1. Happy path  — config frame sent, audio frame sent, partial +
//                    final + metrics emitted, stream closes on
//                    `{"finished":true}`.
//   2. Server-side 401 error — `error_code` JSON envelope translates
//                    into a `.error(detail:)` event without disrupting
//                    the recording (stream stays open).
//   3. Drain on finish — pending non-final tokens drain as a final
//                    when `finish()` is called (no server `<end>`/`<fin>`
//                    marker arrived).
//   4. Recording-integrity isolation — a transport receive error mid-
//                    stream surfaces as `.error(detail:)` and does NOT
//                    propagate out of the session (the events
//                    AsyncStream is non-throwing).

import XCTest
@testable import NtakkerCore

final class SonioxStreamingSessionTests: XCTestCase {

    // MARK: - Helpers

    /// Build a session pre-wired to `mock` with a short finish-grace so
    /// tests don't pay the production 2-second wait.
    private func makeSession(transport: MockWebSocketTransport) -> SonioxStreamingSession {
        let config = SonioxConfigBuilder.build(
            apiKey: "test-key",
            languageHints: ["el", "en"],
            clientReferenceId: "ntakker-cli-test"
        )
        return SonioxStreamingSession(
            transport: transport,
            endpoint: URL(string: "wss://stt-rt.test")!,
            configMessage: config,
            finishGracePeriod: .milliseconds(50)
        )
    }

    /// Drain at most `count` events from `events`, returning whatever
    /// arrives within `timeout`. Iteration ends early if the stream
    /// closes.
    private func collectEvents(
        from events: AsyncStream<StreamingTranscriptionEvent>,
        upTo count: Int,
        timeout: Duration = .seconds(2)
    ) async -> [StreamingTranscriptionEvent] {
        await withTaskGroup(of: [StreamingTranscriptionEvent].self) { group in
            group.addTask {
                var collected: [StreamingTranscriptionEvent] = []
                for await evt in events {
                    collected.append(evt)
                    if collected.count >= count { break }
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

    // MARK: - Test 1: happy path

    func testHappyPathEmitsPartialFinalAndMetrics() async throws {
        let mock = MockWebSocketTransport()

        // Pre-load a non-final token batch (yields a partial), then a
        // batch with `<end>` marker (yields a final), then the terminal
        // `{"finished":true}` envelope (closes the stream).
        let nonFinalBatch = #"{"tokens":[{"text":"hello","is_final":false,"confidence":0.9,"language":"en"}]}"#
        let finalBatch = #"{"tokens":[{"text":" world","is_final":true,"confidence":0.95,"language":"en"},{"text":"<end>","is_final":true,"confidence":1.0}]}"#
        let finishedEnvelope = #"{"tokens":[],"finished":true}"#
        await mock.enqueueIncomingText(nonFinalBatch)
        await mock.enqueueIncomingText(finalBatch)
        await mock.enqueueIncomingText(finishedEnvelope)

        let session = makeSession(transport: mock)
        try await session.start()

        // Push one small audio buffer (one frame of silence) — exercises
        // the binary send path.
        await session.ingest([Float](repeating: 0.0, count: 160))

        // Drain the events stream until it closes.
        var collected: [StreamingTranscriptionEvent] = []
        for await evt in session.events {
            collected.append(evt)
        }

        // Assert event ordering: partial, final, metrics.
        XCTAssertEqual(collected.count, 3, "expected partial + final + metrics, got \(collected)")
        guard case .partial = collected.first else {
            XCTFail("first event should be .partial — got \(collected.first as Any)"); return
        }
        guard case .final = collected[1] else {
            XCTFail("second event should be .final — got \(collected[1])"); return
        }
        guard case .metrics(let m) = collected[2] else {
            XCTFail("third event should be .metrics — got \(collected[2])"); return
        }
        XCTAssertEqual(m.partialsEmitted, 1)
        XCTAssertEqual(m.finalsEmitted, 1)

        // Assert wire-frame capture.
        let sentText = await mock.sentTextFrames
        XCTAssertGreaterThanOrEqual(sentText.count, 1, "config text frame must be present")
        XCTAssertTrue(sentText[0].contains("\"api_key\""), "first text frame must be the JSON config")
        let sentData = await mock.sentDataFrames
        XCTAssertEqual(sentData.count, 1, "exactly one binary audio frame should have been sent")
        XCTAssertEqual(sentData[0].count, 160 * 2, "160 Float samples → 320 PCM16 bytes")
    }

    // MARK: - Test 2: 401 error path

    func test401ErrorEnvelopeEmitsErrorEvent() async throws {
        let mock = MockWebSocketTransport()
        let errorEnvelope = #"{"tokens":[],"error_code":401,"error_message":"Invalid API key"}"#
        await mock.enqueueIncomingText(errorEnvelope)

        let session = makeSession(transport: mock)
        try await session.start()

        // Wait for at least one event (the error). Stream stays open
        // because Soniox error envelopes do not include `finished:true`.
        let events = await collectEvents(from: session.events, upTo: 1, timeout: .seconds(1))
        await session.finish()

        // After finish() the stream closes; collect anything else but
        // assert an `.error` was the first event seen.
        XCTAssertGreaterThanOrEqual(events.count, 1, "expected at least one .error event")
        guard case .error(let detail) = events.first else {
            XCTFail("first event should be .error — got \(String(describing: events.first))"); return
        }
        XCTAssertTrue(detail.contains("401") || detail.contains("invalid"),
                      "error detail should mention the 401 / invalid api key — got \(detail)")
    }

    // MARK: - Test 3: drain on finish

    func testFinishDrainsPendingNonFinalAsFinal() async throws {
        let mock = MockWebSocketTransport()

        // Single non-final token — no marker, no `finished:true`. The
        // session must produce a partial on receive AND, when finish()
        // is called, drain the buffer as a final.
        let nonFinalBatch = #"{"tokens":[{"text":"draining","is_final":false,"confidence":0.8,"language":"en"}]}"#
        await mock.enqueueIncomingText(nonFinalBatch)

        let session = makeSession(transport: mock)
        try await session.start()

        // Give the receive loop a moment to surface the partial.
        try await Task.sleep(for: .milliseconds(100))

        await session.ingest([Float](repeating: 0.1, count: 16))
        await session.finish()

        // Drain remaining events from the now-closed stream.
        var collected: [StreamingTranscriptionEvent] = []
        for await evt in session.events {
            collected.append(evt)
        }

        var partials = 0
        var finals = 0
        for evt in collected {
            switch evt {
            case .partial: partials += 1
            case .final: finals += 1
            default: break
            }
        }
        XCTAssertGreaterThanOrEqual(partials, 1, "should have emitted ≥1 partial: \(collected)")
        XCTAssertEqual(finals, 1, "drain on finish should produce exactly one final: \(collected)")

        // Transport should have been closed.
        let closeArg = await mock.closeArgument
        XCTAssertNotNil(closeArg, "finish() must close the transport")
        XCTAssertEqual(closeArg?.code, .normal)
    }

    // MARK: - Test 4: recording-integrity isolation on receive error

    func testReceiveErrorSurfacesAsErrorEventAndIsContained() async throws {
        let mock = MockWebSocketTransport()

        // Inject a transport-level receive error — the SUT should NOT
        // re-throw out of the session; it should yield .error(detail:)
        // and continue.
        struct InjectedFailure: Error {}
        await mock.enqueueIncomingError(InjectedFailure())

        let session = makeSession(transport: mock)
        try await session.start()

        // Collect one event. We don't call finish() because we want to
        // verify the stream remains usable (i.e., the error didn't tear
        // down the events continuation prematurely).
        let events = await collectEvents(from: session.events, upTo: 1, timeout: .seconds(1))
        XCTAssertEqual(events.count, 1, "expected one .error event")
        guard case .error(let detail) = events.first else {
            XCTFail("event should be .error — got \(String(describing: events.first))"); return
        }
        XCTAssertTrue(detail.contains("receive_failed"),
                      "error detail should identify it as a receive_failed error — got \(detail)")

        // Cleanly shut down so the test process doesn't leak the
        // background receive Task.
        await session.finish()
    }
}
