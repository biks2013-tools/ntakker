// Tests/NtakkerCoreTests/Transcription/Soniox/MockWebSocketTransport.swift —
// see docs/design/plan-006-soniox-streaming.md §11 Phase C and
// docs/design/project-design.md §SX-4.1 (test conformer) / §SX-13
// (C↔D interface contract).
//
// Test double for `WebSocketTransport`. Implemented as an `actor` so
// that scripted message ordering and captured-frame assertions are
// race-free without needing locks at the test layer.
//
// Usage shape (matches both Unit C's own tests and the Phase D session
// tests Unit D will add):
//
//     let mock = MockWebSocketTransport()
//     await mock.enqueueIncoming(.text("{\"finished\":true}"))
//     await mock.enqueueIncoming(.data(Data([0x00])))
//     try await mock.connect(url: URL(string: "wss://example")!, headers: [:])
//     try await mock.send(text: "config")
//     try await mock.send(data: pcm16Bytes)
//     for try await message in mock.messages() { ... }
//     await mock.close(code: .normal, reason: "test")
//
//     let sentText = await mock.sentTextFrames
//     let sentData = await mock.sentDataFrames
//     let closeArg = await mock.closeArgument
//     #expect(sentText == ["config"])
//     #expect(closeArg?.code == .normal)
//
// This file lives in the test target only; production code never
// imports it.

import Foundation
@testable import NtakkerCore

/// In-memory `WebSocketTransport` that lets tests:
///   * pre-load a sequence of incoming messages with optional inter-
///     message delays
///   * inject a connect-time failure
///   * inject a mid-stream receive failure
///   * capture every text / data frame the SUT sent
///   * assert the close code + reason the SUT used
public actor MockWebSocketTransport: WebSocketTransport {

    // MARK: Scripting

    /// One scripted incoming event: either a message (with an optional
    /// delay before yielding it) or a transport-error to throw.
    public enum ScriptedEvent: Sendable {
        case message(WebSocketTransportMessage, delay: Duration = .zero)
        case error(any Error & Sendable)
    }

    /// Captured arguments from a `close(...)` call.
    public struct CloseArgument: Sendable, Equatable {
        public let code: WebSocketTransportCloseCode
        public let reason: String?
    }

    /// Where unhandled connect-time failures are sourced from.
    public struct ConnectFailure: Error, Sendable, Equatable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    // MARK: State

    /// Captured `connect(url:headers:)` arguments (most recent only).
    public private(set) var lastConnectURL: URL?
    public private(set) var lastConnectHeaders: [String: String] = [:]
    public private(set) var connectCallCount: Int = 0

    /// Captured outgoing frames in send order.
    public private(set) var sentTextFrames: [String] = []
    public private(set) var sentDataFrames: [Data] = []

    /// Captured close call (nil until close is invoked).
    public private(set) var closeArgument: CloseArgument?
    public private(set) var closeCallCount: Int = 0

    /// Whether `connect(...)` should throw before recording state.
    private var pendingConnectFailure: (any Error)?

    /// Scripted incoming events. Each call to `receive()` (or each tick
    /// of the `messages()` stream) consumes the head of the queue.
    private var scriptedIncoming: [ScriptedEvent] = []

    /// True once `close(...)` has been called. After this point
    /// `receive()` returns nil and the stream finishes.
    private var isClosed: Bool = false

    /// True if `connect(...)` has succeeded at least once.
    private var isConnected: Bool = false

    // MARK: Init

    public init() {}

    // MARK: Test API — scripting

    /// Make the next `connect(...)` call throw `error`. Cleared on
    /// success.
    public func injectConnectFailure(_ error: any Error) {
        pendingConnectFailure = error
    }

    /// Pre-load a single incoming event (text/data/error) for the SUT
    /// to consume via `receive()` or `messages()`.
    public func enqueueIncoming(_ event: ScriptedEvent) {
        scriptedIncoming.append(event)
    }

    /// Convenience: enqueue a text message with no delay.
    public func enqueueIncomingText(_ text: String, delay: Duration = .zero) {
        scriptedIncoming.append(.message(.text(text), delay: delay))
    }

    /// Convenience: enqueue a binary message with no delay.
    public func enqueueIncomingData(_ data: Data, delay: Duration = .zero) {
        scriptedIncoming.append(.message(.data(data), delay: delay))
    }

    /// Convenience: schedule the next `receive()` to throw `error`.
    public func enqueueIncomingError(_ error: any Error & Sendable) {
        scriptedIncoming.append(.error(error))
    }

    // MARK: WebSocketTransport conformance

    public func connect(url: URL, headers: [String: String]) async throws {
        connectCallCount += 1
        if let failure = pendingConnectFailure {
            pendingConnectFailure = nil
            throw failure
        }
        lastConnectURL = url
        lastConnectHeaders = headers
        isConnected = true
    }

    public func send(text: String) async throws {
        try requireOpen()
        sentTextFrames.append(text)
    }

    public func send(data: Data) async throws {
        try requireOpen()
        sentDataFrames.append(data)
    }

    public func receive() async throws -> WebSocketTransportMessage? {
        if isClosed { return nil }
        guard !scriptedIncoming.isEmpty else {
            // Nothing scripted and not closed — the contract says
            // `receive()` should suspend; in tests we treat that as a
            // clean nil so the iteration loop can exit deterministically.
            return nil
        }
        let next = scriptedIncoming.removeFirst()
        switch next {
        case .message(let message, let delay):
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            return message
        case .error(let error):
            throw error
        }
    }

    public func close(code: WebSocketTransportCloseCode, reason: String?) async {
        closeCallCount += 1
        // First-call wins for assertion semantics; record subsequent
        // calls in `closeCallCount` only.
        if closeArgument == nil {
            closeArgument = CloseArgument(code: code, reason: reason)
        }
        isClosed = true
    }

    public nonisolated func messages() -> AsyncThrowingStream<WebSocketTransportMessage, Error> {
        // Build a stream that drives `receive()` until it returns nil
        // or throws. Mirrors the production adapter's strategy so tests
        // that consume `messages()` and tests that consume `receive()`
        // exercise equivalent code paths.
        return AsyncThrowingStream { continuation in
            let drainTask = Task {
                while !Task.isCancelled {
                    do {
                        guard let message = try await self.receive() else {
                            continuation.finish()
                            return
                        }
                        continuation.yield(message)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                drainTask.cancel()
            }
        }
    }

    // MARK: Internals

    private func requireOpen() throws {
        if isClosed {
            throw URLError(.cancelled, userInfo: [
                NSLocalizedDescriptionKey: "MockWebSocketTransport is closed.",
            ])
        }
        if !isConnected {
            throw URLError(.notConnectedToInternet, userInfo: [
                NSLocalizedDescriptionKey: "MockWebSocketTransport.connect(...) not called.",
            ])
        }
    }
}
