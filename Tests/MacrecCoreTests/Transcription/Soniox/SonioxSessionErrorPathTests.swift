// Tests/MacrecCoreTests/Transcription/Soniox/SonioxSessionErrorPathTests.swift
//
// Plan-006 Phase D / Test-Build (soniox-error-paths): augmentation tests
// for `SonioxStreamingSession` error paths exercised via
// `MockWebSocketTransport`. Complements `SonioxStreamingSessionTests`
// which already covers 401, drain-on-finish, and transport-receive-error
// containment.
//
// New cases exercised here:
//   1. 402 quota exceeded server message → .error(detail:) with "402" / "quota"
//   2. 408 idle timeout server message  → .error(detail:) with "408" / "idle"
//   3. 503 terminate-and-reconnect      → .error(detail:) with "503" / "terminated"
//      (NOT auto-reconnect — design ADR says surface and let user restart)
//   4. tokens:[] + no error_code + no finished → no events emitted (silent batch)
//   5. Server message failing JSON decode → .error(detail:) containing "decode_failed"

import XCTest
@testable import MacrecCore

final class SonioxSessionErrorPathTests: XCTestCase {

    // MARK: - Helpers

    /// Build a session pre-wired to `mock` with a short finish-grace so
    /// tests don't wait the production 2-second drain window.
    private func makeSession(transport: MockWebSocketTransport) -> SonioxStreamingSession {
        let config = SonioxConfigBuilder.build(
            apiKey: "test-key",
            languageHints: ["el", "en"],
            clientReferenceId: "macrec-error-path-test"
        )
        return SonioxStreamingSession(
            transport: transport,
            endpoint: URL(string: "wss://stt-rt.test")!,
            configMessage: config,
            finishGracePeriod: .milliseconds(50)
        )
    }

    /// Collect up to `count` events from `events`, returning whatever
    /// arrives within `timeout`. Terminates early if the stream closes.
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

    // MARK: - Test 1: 402 quota exceeded

    func test402QuotaExceededServerMessageEmitsErrorEvent() async throws {
        // The Soniox server sends {"error_code":402,"tokens":[]} when the
        // account has exhausted its quota. The session must surface this
        // as a `.error(detail:)` event whose detail string references
        // "402" or "quota" — not silently drop it.
        let mock = MockWebSocketTransport()
        let envelope = #"{"tokens":[],"error_code":402,"error_message":"Account quota exceeded"}"#
        await mock.enqueueIncomingText(envelope)

        let session = makeSession(transport: mock)
        try await session.start()

        let events = await collectEvents(from: session.events, upTo: 1, timeout: .seconds(1))
        await session.finish()

        XCTAssertGreaterThanOrEqual(events.count, 1,
                                    "Expected at least one .error event for a 402 quota-exceeded message")
        guard case .error(let detail) = events.first else {
            XCTFail("First event must be .error — got \(String(describing: events.first))")
            return
        }
        let lowerDetail = detail.lowercased()
        XCTAssertTrue(
            lowerDetail.contains("402") || lowerDetail.contains("quota"),
            "Error detail must reference '402' or 'quota' — got: \(detail)"
        )
    }

    // MARK: - Test 2: 408 idle timeout

    func test408IdleTimeoutServerMessageEmitsErrorEvent() async throws {
        // The Soniox server sends error_code 408 when the session has
        // been idle (no audio) for 20 s. The session must surface this
        // as a `.error(detail:)` event referencing "408" or "idle".
        let mock = MockWebSocketTransport()
        let envelope = #"{"tokens":[],"error_code":408,"error_message":"Session idle timeout"}"#
        await mock.enqueueIncomingText(envelope)

        let session = makeSession(transport: mock)
        try await session.start()

        let events = await collectEvents(from: session.events, upTo: 1, timeout: .seconds(1))
        await session.finish()

        XCTAssertGreaterThanOrEqual(events.count, 1,
                                    "Expected at least one .error event for a 408 idle-timeout message")
        guard case .error(let detail) = events.first else {
            XCTFail("First event must be .error — got \(String(describing: events.first))")
            return
        }
        let lowerDetail = detail.lowercased()
        XCTAssertTrue(
            lowerDetail.contains("408") || lowerDetail.contains("idle"),
            "Error detail must reference '408' or 'idle' — got: \(detail)"
        )
    }

    // MARK: - Test 3: 503 terminate-and-reconnect (surface, not auto-reconnect)

    func test503TerminatedReconnectServerMessageEmitsErrorEventWithoutAutoReconnect() async throws {
        // Soniox error_code 503 means the server terminated the session
        // and expects the client to reconnect. Per the design ADR
        // (project-design.md §SX-ADR-reconnect): v1 does NOT auto-
        // reconnect — it surfaces the error as a `.error(detail:)` event
        // and lets the operator decide. The session must NOT silently close
        // and reopen a new transport connection.
        let mock = MockWebSocketTransport()
        let envelope = #"{"tokens":[],"error_code":503,"error_message":"Server terminated. Please reconnect."}"#
        await mock.enqueueIncomingText(envelope)

        let session = makeSession(transport: mock)
        try await session.start()

        let events = await collectEvents(from: session.events, upTo: 1, timeout: .seconds(1))
        await session.finish()

        XCTAssertGreaterThanOrEqual(events.count, 1,
                                    "Expected at least one .error event for a 503 terminate-reconnect message")
        guard case .error(let detail) = events.first else {
            XCTFail("First event must be .error — got \(String(describing: events.first))")
            return
        }
        let lowerDetail = detail.lowercased()
        XCTAssertTrue(
            lowerDetail.contains("503") || lowerDetail.contains("terminat"),
            "Error detail must reference '503' or 'terminated' — got: \(detail)"
        )

        // Verify no auto-reconnect occurred: the transport was only
        // connected once (the initial session.start() call).
        let connectCount = await mock.connectCallCount
        XCTAssertEqual(connectCount, 1,
                       "Session must not auto-reconnect on 503 — connectCallCount must remain 1")
    }

    // MARK: - Test 4: empty token batch — silent (no events emitted)

    func testEmptyTokensBatchWithNoErrorAndNoFinishedEmitsNoEvents() async throws {
        // Per soniox-wire-schema.md, the server may occasionally send
        // {"tokens":[]} with neither error_code nor finished:true — a
        // keepalive-like heartbeat with no transcript content. The session
        // must silently discard these frames and emit no partial/final/error
        // events. (If it did emit an event, consumers would see spurious
        // "empty partial" segments in the sidecar.)
        let mock = MockWebSocketTransport()

        // Enqueue one silent batch, then a normal finished envelope so the
        // stream closes and the test terminates deterministically.
        let silentBatch = #"{"tokens":[]}"#
        let finishedEnvelope = #"{"tokens":[],"finished":true}"#
        await mock.enqueueIncomingText(silentBatch)
        await mock.enqueueIncomingText(finishedEnvelope)

        let session = makeSession(transport: mock)
        try await session.start()

        // Drain all events until the stream closes naturally.
        var collected: [StreamingTranscriptionEvent] = []
        for await evt in session.events {
            collected.append(evt)
        }

        // Only the metrics event from the finished response should appear;
        // the silent batch must not produce any partial / final / error.
        let nonMetricsEvents = collected.filter {
            if case .metrics = $0 { return false }
            return true
        }
        XCTAssertEqual(nonMetricsEvents.count, 0,
                       "A silent {tokens:[]} batch must produce no partial/final/error events — got: \(nonMetricsEvents)")
    }

    // MARK: - Test 5: malformed JSON → decode_failed error event

    func testMalformedServerMessageEmitsDecodeFailedError() async throws {
        // If the Soniox server sends a frame that is not valid JSON (e.g.
        // due to a proxy/network corruption), the session must surface an
        // `.error(detail:)` event whose detail string contains
        // "decode_failed" — mirroring the production code path in
        // `handleTextFrame(_:aggregator:)` — and must NOT propagate the
        // decode error out of the session (recording-integrity isolation).
        let mock = MockWebSocketTransport()

        // Inject a frame that is not valid JSON.
        let garbled = "not valid json {{{"
        await mock.enqueueIncomingText(garbled)

        // Follow with a finished envelope so the stream closes cleanly.
        let finishedEnvelope = #"{"tokens":[],"finished":true}"#
        await mock.enqueueIncomingText(finishedEnvelope)

        let session = makeSession(transport: mock)
        try await session.start()

        // Drain all events until the stream closes.
        var collected: [StreamingTranscriptionEvent] = []
        for await evt in session.events {
            collected.append(evt)
        }

        // There must be at least one error event.
        let errorEvents = collected.filter { if case .error = $0 { return true }; return false }
        XCTAssertGreaterThanOrEqual(errorEvents.count, 1,
                                    "A malformed JSON frame must produce at least one .error event — got: \(collected)")

        // The first error event's detail must contain "decode_failed".
        if case .error(let detail) = errorEvents.first {
            XCTAssertTrue(
                detail.contains("decode_failed"),
                "Error detail for a JSON-decode failure must contain 'decode_failed' — got: \(detail)"
            )
        } else {
            XCTFail("Expected .error event, got \(String(describing: errorEvents.first))")
        }
    }
}
