// Tests/NtakkerCoreTests/Transcription/Soniox/WebSocketTransportTests.swift —
// see docs/design/plan-006-soniox-streaming.md §11 Phase C (Task C.6)
// and docs/design/project-design.md §SX-4.1 (test seam coverage).
//
// Verifies:
//   1. WebSocketTransportCloseCode.rawCode returns the expected RFC
//      6455 integer for each named case.
//   2. URLSessionWebSocketTaskTransport.connect(...) succeeds against a
//      public echo server (gated on NTAKKER_RUN_NETWORK_TESTS=1 so the
//      default `swift test` run is hermetic).
//   3. MockWebSocketTransport: pre-loaded text + binary messages are
//      yielded in order via messages().
//   4. MockWebSocketTransport: send / close arguments are captured
//      faithfully for SUT assertions.
//   5. MockWebSocketTransport: a scripted mid-stream error throws
//      AFTER prior messages have been yielded.

import Foundation
import Testing
@testable import NtakkerCore

@Suite("WebSocketTransport")
struct WebSocketTransportTests {

    // MARK: - 1. Close-code raw values

    @Test("WebSocketTransportCloseCode.rawCode returns RFC 6455 integers")
    func rawCloseCodeMapping() {
        #expect(WebSocketTransportCloseCode.normal.rawCode == 1000)
        #expect(WebSocketTransportCloseCode.goingAway.rawCode == 1001)
        #expect(WebSocketTransportCloseCode.protocolError.rawCode == 1002)
        #expect(WebSocketTransportCloseCode.unsupportedData.rawCode == 1003)
        #expect(WebSocketTransportCloseCode.noStatus.rawCode == 1005)
        #expect(WebSocketTransportCloseCode.abnormalClosure.rawCode == 1006)
        #expect(WebSocketTransportCloseCode.invalidFramePayload.rawCode == 1007)
        #expect(WebSocketTransportCloseCode.policyViolation.rawCode == 1008)
        #expect(WebSocketTransportCloseCode.messageTooLarge.rawCode == 1009)
        #expect(WebSocketTransportCloseCode.mandatoryExtensionMissing.rawCode == 1010)
        #expect(WebSocketTransportCloseCode.internalServerError.rawCode == 1011)
        #expect(WebSocketTransportCloseCode.tlsHandshake.rawCode == 1015)
        #expect(WebSocketTransportCloseCode.custom(4001).rawCode == 4001)
    }

    @Test("WebSocketTransportCloseCode.isReservedReceiveOnly flags 1005/1006/1015")
    func reservedCloseCodes() {
        #expect(WebSocketTransportCloseCode.noStatus.isReservedReceiveOnly)
        #expect(WebSocketTransportCloseCode.abnormalClosure.isReservedReceiveOnly)
        #expect(WebSocketTransportCloseCode.tlsHandshake.isReservedReceiveOnly)
        #expect(!WebSocketTransportCloseCode.normal.isReservedReceiveOnly)
        #expect(!WebSocketTransportCloseCode.goingAway.isReservedReceiveOnly)
        #expect(!WebSocketTransportCloseCode.custom(4001).isReservedReceiveOnly)
    }

    // MARK: - 2. Production adapter integration test (gated)

    @Test(
        "URLSessionWebSocketTaskTransport connects to a public echo server",
        .enabled(if: ProcessInfo.processInfo.environment["NTAKKER_RUN_NETWORK_TESTS"] == "1")
    )
    func productionAdapterConnectsToEchoServer() async throws {
        // wss://echo.websocket.events echoes any frame back to the
        // sender. The handshake is what this test really checks — the
        // wrapper does not throw, then we cleanly close.
        let transport = URLSessionWebSocketTaskTransport()
        let url = URL(string: "wss://echo.websocket.events")!
        try await transport.connect(url: url, headers: [:])
        try await transport.send(text: "hello")

        // Echo servers prepend a greeting frame; just confirm we can
        // receive at least one message without throwing.
        let first = try await transport.receive()
        #expect(first != nil)

        await transport.close(code: .normal, reason: "test complete")
    }

    // MARK: - 3. Mock — messages() yields scripted messages in order

    @Test("MockWebSocketTransport.messages() yields text + data in order")
    func mockYieldsScriptedMessages() async throws {
        let mock = MockWebSocketTransport()
        await mock.enqueueIncomingText("first")
        await mock.enqueueIncomingData(Data([0x01, 0x02, 0x03]))
        try await mock.connect(url: URL(string: "wss://example")!, headers: [:])

        var collected: [WebSocketTransportMessage] = []
        for try await message in mock.messages() {
            collected.append(message)
            if collected.count == 2 { break }
        }

        #expect(collected.count == 2)
        #expect(collected[0] == .text("first"))
        #expect(collected[1] == .data(Data([0x01, 0x02, 0x03])))
    }

    // MARK: - 4. Mock — send + close capture

    @Test("MockWebSocketTransport captures sent frames and close arguments")
    func mockCapturesSendAndClose() async throws {
        let mock = MockWebSocketTransport()
        try await mock.connect(url: URL(string: "wss://example")!, headers: ["X-Custom": "v"])

        try await mock.send(text: "config")
        try await mock.send(text: "keepalive")
        try await mock.send(text: "")  // Soniox end-of-stream sentinel

        let chunkA = Data(repeating: 0xAA, count: 64)
        let chunkB = Data(repeating: 0xBB, count: 32)
        try await mock.send(data: chunkA)
        try await mock.send(data: chunkB)

        await mock.close(code: .normal, reason: "test")

        let sentText = await mock.sentTextFrames
        let sentData = await mock.sentDataFrames
        let closeArg = await mock.closeArgument
        let connectURL = await mock.lastConnectURL
        let connectHeaders = await mock.lastConnectHeaders

        #expect(sentText == ["config", "keepalive", ""])
        #expect(sentData == [chunkA, chunkB])
        #expect(closeArg?.code == .normal)
        #expect(closeArg?.reason == "test")
        #expect(connectURL == URL(string: "wss://example"))
        #expect(connectHeaders == ["X-Custom": "v"])
    }

    // MARK: - 5. Mock — mid-stream error throws after prior messages

    @Test("MockWebSocketTransport mid-stream error throws after prior messages")
    func mockMidStreamErrorThrows() async throws {
        struct InjectedError: Error, Equatable {}

        let mock = MockWebSocketTransport()
        await mock.enqueueIncomingText("ok-1")
        await mock.enqueueIncomingText("ok-2")
        await mock.enqueueIncomingError(InjectedError())
        try await mock.connect(url: URL(string: "wss://example")!, headers: [:])

        var collected: [String] = []
        var caughtError: (any Error)?
        do {
            for try await message in mock.messages() {
                if case .text(let s) = message {
                    collected.append(s)
                }
            }
        } catch {
            caughtError = error
        }

        #expect(collected == ["ok-1", "ok-2"])
        #expect(caughtError is InjectedError)
    }

    // MARK: - Bonus — connect-failure injection (covers the same path
    // that Unit D's session tests will rely on).

    @Test("MockWebSocketTransport.injectConnectFailure throws on next connect")
    func mockConnectFailure() async {
        let mock = MockWebSocketTransport()
        let injected = MockWebSocketTransport.ConnectFailure(message: "TLS handshake failed")
        await mock.injectConnectFailure(injected)

        do {
            try await mock.connect(url: URL(string: "wss://example")!, headers: [:])
            Issue.record("expected connect to throw")
        } catch let e as MockWebSocketTransport.ConnectFailure {
            #expect(e == injected)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        // Confirm a SECOND connect (with no fresh injected failure)
        // succeeds — the failure is one-shot.
        try? await mock.connect(url: URL(string: "wss://example")!, headers: [:])
        let count = await mock.connectCallCount
        #expect(count == 2)
    }
}
