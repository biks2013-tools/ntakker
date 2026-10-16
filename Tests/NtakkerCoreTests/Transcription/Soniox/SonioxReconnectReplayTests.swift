// Tests/NtakkerCoreTests/Transcription/Soniox/SonioxReconnectReplayTests.swift
//
// EVAL-2026-10-16 INF-1 / INF-2: reconnect-with-replay must not resend
// audio the dropped connection already transcribed, and a `finish()`
// that races a reconnect must not leave the fresh socket behind.

import XCTest
@testable import NtakkerCore

final class SonioxReconnectReplayTests: XCTestCase {

    private struct SimulatedDrop: Error, Sendable {}

    private func makeSession(
        transport: any WebSocketTransport,
        factory: @escaping @Sendable () -> any WebSocketTransport,
        keepalive: SonioxKeepaliveTimer = SonioxKeepaliveTimer()
    ) -> SonioxStreamingSession {
        SonioxStreamingSession(
            transport: transport,
            endpoint: URL(string: "wss://stt-rt.test")!,
            configMessage: SonioxConfigBuilder.build(
                apiKey: "test-key",
                languageHints: ["en"],
                clientReferenceId: "ntakker-cli-test"
            ),
            keepalive: keepalive,
            finishGracePeriod: .milliseconds(50),
            transportFactory: factory
        )
    }

    /// 100 ms of 16 kHz audio filled with `value`.
    private func chunk(_ value: Float) -> [Float] {
        [Float](repeating: value, count: 1_600)
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testReplayStartsAfterTheLastFinalToken() async throws {
        let first = MockWebSocketTransport()
        let fresh = MockWebSocketTransport()
        // The first 100 ms are covered by a final token; the drop comes
        // after all three chunks were sent.
        await first.enqueueIncomingText(
            #"{"tokens":[{"text":"hello","is_final":true,"start_ms":0,"end_ms":100}]}"#,
            delay: .milliseconds(100)
        )
        await first.enqueueIncomingText(#"{"tokens":[]}"#, delay: .milliseconds(200))
        await first.enqueueIncomingError(SimulatedDrop())

        let session = makeSession(transport: first, factory: { fresh })
        try await session.start()
        await session.ingest(chunk(0.1))
        await session.ingest(chunk(0.2))
        await session.ingest(chunk(0.3))

        await waitUntil { await !fresh.sentDataFrames.isEmpty }
        let replayed = await fresh.sentDataFrames
        let sentFirst = await first.sentDataFrames

        XCTAssertEqual(sentFirst.count, 3)
        XCTAssertEqual(replayed.reduce(0) { $0 + $1.count }, 2 * 3_200,
                       "only the 200 ms after the final token's end_ms should be replayed")
        XCTAssertEqual(replayed.first, sentFirst[1], "replay must start at chunk 2")
        XCTAssertEqual(replayed.last, sentFirst[2])

        // The committed final reached the event stream exactly once.
        await session.finish()
        var finals: [String] = []
        for await evt in session.events {
            if case let .final(_, text, _, _, _, _) = evt { finals.append(text) }
        }
        XCTAssertEqual(finals, ["hello"])
    }

    func testReplayWithoutFinalsResendsTheWholeRing() async throws {
        let first = MockWebSocketTransport()
        let fresh = MockWebSocketTransport()
        await first.enqueueIncomingText(#"{"tokens":[]}"#, delay: .milliseconds(200))
        await first.enqueueIncomingError(SimulatedDrop())

        let session = makeSession(transport: first, factory: { fresh })
        try await session.start()
        await session.ingest(chunk(0.1))
        await session.ingest(chunk(0.2))

        await waitUntil { await fresh.sentDataFrames.count >= 2 }
        let replayed = await fresh.sentDataFrames
        let original = await first.sentDataFrames
        XCTAssertEqual(replayed, original)
        await session.finish()
    }

    func testAggregatorPrepareForReconnectFlushesFinalsAndDropsNonFinals() async {
        let aggregator = SonioxTokenAggregator()
        _ = await aggregator.ingest([
            SonioxToken(text: "hello ", isFinal: true),
            SonioxToken(text: "wor", isFinal: false),
        ])
        let events = await aggregator.prepareForReconnect()
        guard events.count == 1, case let .final(_, text, _, _, _, _) = events[0] else {
            return XCTFail("expected one final, got \(events)")
        }
        XCTAssertEqual(text, "hello")
        let drained = await aggregator.drain()
        XCTAssertTrue(drained.isEmpty, "non-finals must not survive the reconnect")
    }

    func testAggregatorPrepareForReconnectWithOnlyNonFinalsEmitsNothing() async {
        let aggregator = SonioxTokenAggregator()
        _ = await aggregator.ingest([SonioxToken(text: "wor", isFinal: false)])
        let events = await aggregator.prepareForReconnect()
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - INF-2

    /// Wraps a mock so `connect` takes `delay` — opens the window in
    /// which `finish()` can race a reconnect attempt.
    private actor SlowConnectTransport: WebSocketTransport {
        let inner: MockWebSocketTransport
        let delay: Duration
        init(inner: MockWebSocketTransport, delay: Duration) {
            self.inner = inner
            self.delay = delay
        }
        func connect(url: URL, headers: [String: String]) async throws {
            try? await Task.sleep(for: delay)
            try await inner.connect(url: url, headers: headers)
        }
        func send(text: String) async throws { try await inner.send(text: text) }
        func send(data: Data) async throws { try await inner.send(data: data) }
        func receive() async throws -> WebSocketTransportMessage? { try await inner.receive() }
        func close(code: WebSocketTransportCloseCode, reason: String?) async {
            await inner.close(code: code, reason: reason)
        }
        nonisolated func messages() -> AsyncThrowingStream<WebSocketTransportMessage, Error> {
            inner.messages()
        }
    }

    func testFinishDuringReconnectClosesTheFreshTransport() async throws {
        let first = MockWebSocketTransport()
        let freshInner = MockWebSocketTransport()
        let fresh = SlowConnectTransport(inner: freshInner, delay: .milliseconds(300))
        await first.enqueueIncomingError(SimulatedDrop())

        let session = makeSession(
            transport: first,
            factory: { fresh },
            keepalive: SonioxKeepaliveTimer(interval: .milliseconds(30))
        )
        try await session.start()
        await session.ingest(chunk(0.1))

        // The drop fires immediately; finish while the fresh connect is
        // still sleeping.
        try await Task.sleep(for: .milliseconds(100))
        await session.finish()

        // Let the slow connect + replay complete.
        try await Task.sleep(for: .milliseconds(500))
        let closes = await freshInner.closeCallCount
        XCTAssertGreaterThanOrEqual(closes, 1, "the fresh transport must be closed, not installed")

        let keepalivesBefore = await freshInner.sentTextFrames.filter { $0.contains("keepalive") }.count
        try await Task.sleep(for: .milliseconds(150))
        let keepalivesAfter = await freshInner.sentTextFrames.filter { $0.contains("keepalive") }.count
        XCTAssertEqual(keepalivesBefore, 0)
        XCTAssertEqual(keepalivesAfter, 0, "no keepalive loop may run on a finished session")
    }
}

