// Tests/NtakkerCoreTests/Transcription/Soniox/SonioxKeepaliveTimerTests.swift
//
// Plan-006 Phase D / Unit D1: timer-cadence smoke test for
// `SonioxKeepaliveTimer` against the in-memory `MockWebSocketTransport`.

import XCTest
@testable import NtakkerCore

final class SonioxKeepaliveTimerTests: XCTestCase {

    func testStartEmitsKeepaliveFramesUntilStopped() async throws {
        let mock = MockWebSocketTransport()
        try await mock.connect(url: URL(string: "wss://test.example")!, headers: [:])

        let timer = SonioxKeepaliveTimer(interval: .milliseconds(50))
        await timer.start(transport: mock)

        // Wait long enough to fire at least 2-3 keepalives (sleep 200 ms,
        // interval 50 ms).
        try await Task.sleep(for: .milliseconds(200))
        await timer.stop()

        let sentText = await mock.sentTextFrames
        XCTAssertGreaterThanOrEqual(sentText.count, 1, "Expected at least one keepalive frame")
        for frame in sentText {
            XCTAssertTrue(
                frame.contains("\"keepalive\""),
                "Expected each frame to be a keepalive control message; got \(frame)"
            )
        }
    }
}
