// MacrecCore/Transcription/Live/Soniox/URLSessionWebSocketTaskTransport.swift —
// see docs/design/plan-006-soniox-streaming.md §11 Phase C (Task C.5)
// and docs/design/project-design.md §SX-4.1 (production conformer).
//
// Production `WebSocketTransport` adapter. Wraps a single
// `URLSessionWebSocketTask` per connection cycle on a dedicated
// `URLSession` (NOT `URLSession.shared`, to avoid task-priority
// inversion with the recording pipeline's concurrent uploads — see
// research/websocket-asyncstream-pattern.md §"Live Transport
// Factory" for the same rationale used by Gemini Live's removed
// transport).
//
// Threading model:
//   * `connect(...)` and `close(...)` mutate `task` / `session`. They
//     are serialised by an internal `NSLock`. The lock is held only
//     across reference swaps; no async work is performed under the
//     lock.
//   * `send(text:)` / `send(data:)` snapshot `task` under the lock and
//     then perform the async send unlocked. `URLSessionWebSocketTask`
//     is documented thread-safe by Foundation, so concurrent sends are
//     OK.
//   * `receive()` and `messages()` are read-only with respect to the
//     wrapper's state — they snapshot `task` and call its `receive()`.
//
// The class is `@unchecked Sendable` because the underlying
// `URLSessionWebSocketTask` carries shared mutable state managed by
// Foundation. The wrapper itself only stores immutable references that
// it swaps under the lock.

import Foundation
import Logging

/// Production conformer for `WebSocketTransport`. One instance per
/// connection cycle; the `transportFactory` parameter on
/// `SonioxStreamingTranscriptionProvider` produces a fresh instance per
/// session so per-session URLSession lifetime is bounded.
public final class URLSessionWebSocketTaskTransport: WebSocketTransport, @unchecked Sendable {

    // MARK: Stored state

    /// Per-connection URLSession. Created in `connect(...)`, invalidated
    /// in `close(...)`. Held weakly by the task once started.
    private var session: URLSession?

    /// The active task. `nil` before `connect(...)` and after
    /// `close(...)`. Mutated only under `lock`.
    private var task: URLSessionWebSocketTask?

    /// Set to `true` the first time `close(...)` runs. Subsequent calls
    /// are no-ops (idempotent close).
    private var isClosed: Bool = false

    /// Serialises mutations to `session`, `task`, `isClosed`. Held
    /// only across pointer swaps — no async work is performed inside.
    private let lock = NSLock()

    /// Logger used to surface non-fatal warnings (e.g., custom close
    /// code outside RFC 6455's named set).
    private let logger: Logger

    /// `URLSessionConfiguration` factory. Default values: 60 s
    /// per-request timeout (the Soniox config send / first server
    /// response should arrive well within this) and 300 s resource
    /// timeout. Soniox's session cap is 300 minutes, but the resource
    /// timeout is per-request and the long-lived WebSocket is governed
    /// by the keepalive timer at the application layer, not by the
    /// resource timeout.
    private let configurationFactory: @Sendable () -> URLSessionConfiguration

    // MARK: Init

    /// Initialise with the project's default Logger and configuration.
    /// The factory split lets tests substitute a configuration that
    /// e.g. routes through an `URLProtocol`-style stub for the HTTP
    /// upgrade portion (rare; primarily relevant for integration
    /// tests).
    public init(
        logger: Logger = Logger(label: "macrec.transcription.soniox.transport"),
        configurationFactory: @escaping @Sendable () -> URLSessionConfiguration = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = 300
            cfg.waitsForConnectivity = false
            return cfg
        }
    ) {
        self.logger = logger
        self.configurationFactory = configurationFactory
    }

    deinit {
        // Defensive cleanup: if the owner never called `close(...)`,
        // we cancel the task and invalidate the session here so the
        // file descriptor and thread-pool entry are released. This is
        // a safety net — the contract still requires explicit
        // `close(...)` for deterministic shutdown.
        lock.lock()
        let pendingTask = task
        let pendingSession = session
        task = nil
        session = nil
        lock.unlock()
        pendingTask?.cancel(with: .goingAway, reason: nil)
        pendingSession?.invalidateAndCancel()
    }

    // MARK: WebSocketTransport

    public func connect(url: URL, headers: [String: String]) async throws {
        // Build the URLSession + task synchronously, then call
        // `resume()`. `URLSessionWebSocketTask` opens the connection
        // lazily on the first `receive()` / `send(...)`, so this call
        // does not actually do network I/O — but it MUST throw if the
        // wrapper is being reused after `close(...)`.
        try lock.withLock {
            if isClosed {
                throw URLError(.cancelled, userInfo: [
                    NSLocalizedDescriptionKey: "WebSocketTransport closed; cannot reconnect on the same instance.",
                ])
            }
            if task != nil {
                throw URLError(.badServerResponse, userInfo: [
                    NSLocalizedDescriptionKey: "WebSocketTransport already connected.",
                ])
            }

            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let urlSession = URLSession(configuration: configurationFactory())
            let wsTask = urlSession.webSocketTask(with: request)
            wsTask.resume()

            self.session = urlSession
            self.task = wsTask
        }
    }

    public func send(text: String) async throws {
        let snapshot = try snapshotTask()
        try await snapshot.send(.string(text))
    }

    public func send(data: Data) async throws {
        let snapshot = try snapshotTask()
        try await snapshot.send(.data(data))
    }

    public func receive() async throws -> WebSocketTransportMessage? {
        let snapshot: URLSessionWebSocketTask
        do {
            snapshot = try snapshotTask()
        } catch {
            // After `close(...)`, the contract is that `receive()`
            // returns nil rather than throws — the caller's iteration
            // loop should exit cleanly. But if the session was never
            // connected at all, surface the error.
            if isClosedSnapshot() {
                return nil
            }
            throw error
        }

        do {
            let raw = try await snapshot.receive()
            switch raw {
            case .string(let s): return .text(s)
            case .data(let d): return .data(d)
            @unknown default:
                // Future Foundation cases — treat as a clean close so
                // the iteration loop exits rather than spinning.
                return nil
            }
        } catch {
            // If `close(...)` raced with an in-flight `receive()`, the
            // task throws CancellationError or URLError(.cancelled) —
            // surface that as a clean stream-end rather than as an
            // error.
            if isClosedSnapshot() {
                return nil
            }
            throw error
        }
    }

    public func close(code: WebSocketTransportCloseCode, reason: String?) async {
        // Take ownership of the current task / session under the lock,
        // then perform the cancellation outside. Idempotent — second
        // and later calls are no-ops.
        let (taskToClose, sessionToClose): (URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            if isClosed {
                return (nil, nil)
            }
            isClosed = true
            let t = task
            let s = session
            task = nil
            session = nil
            return (t, s)
        }

        guard let activeTask = taskToClose else {
            return
        }

        if code.isReservedReceiveOnly {
            logger.warning("WebSocketTransport: caller passed reserved close code \(code.rawCode) to close(); will send no close code on the wire.")
        }
        if case .custom(let raw) = code {
            logger.warning("WebSocketTransport: caller passed custom close code \(raw); Foundation does not support sending arbitrary close codes — will send no close code on the wire.")
        }

        let mappedCode = code.toURLSessionCloseCode()
        let reasonData = reason?.data(using: .utf8)
        activeTask.cancel(with: mappedCode, reason: reasonData)

        // Invalidate and finish the URLSession so its delegate queue,
        // thread pool entries, and file descriptors are released.
        // `finishTasksAndInvalidate` waits for the cancellation to
        // propagate; `invalidateAndCancel` is more aggressive but the
        // task is already cancelled so the two are equivalent here.
        sessionToClose?.finishTasksAndInvalidate()
    }

    public func messages() -> AsyncThrowingStream<WebSocketTransportMessage, Error> {
        // Each call returns a fresh stream that drives the same
        // underlying `receive()` loop. Multiple concurrent iterators
        // would compete for messages — the contract is "call once,
        // iterate with `for try await`".
        return AsyncThrowingStream { continuation in
            let drainTask = Task {
                while !Task.isCancelled {
                    do {
                        let next = try await self.receive()
                        guard let message = next else {
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

    // MARK: Helpers

    /// Returns the active task or throws if the transport is not in a
    /// usable state. Held briefly under `lock`.
    private func snapshotTask() throws -> URLSessionWebSocketTask {
        try lock.withLock {
            if isClosed {
                throw URLError(.cancelled, userInfo: [
                    NSLocalizedDescriptionKey: "WebSocketTransport is closed.",
                ])
            }
            guard let t = task else {
                throw URLError(.notConnectedToInternet, userInfo: [
                    NSLocalizedDescriptionKey: "WebSocketTransport.connect(url:headers:) was never called.",
                ])
            }
            return t
        }
    }

    /// Whether `close(...)` has been observed. Used to convert
    /// post-close errors into clean stream-end signals.
    private func isClosedSnapshot() -> Bool {
        lock.withLock { isClosed }
    }
}

// MARK: - NSLock convenience

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
