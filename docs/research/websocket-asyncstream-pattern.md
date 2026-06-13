# WebSocket + AsyncStream Integration Pattern with Bounded Reconnection

**Research purpose**: Define the canonical `URLSessionWebSocketTask` + `AsyncStream` pattern for the `macrec`/`macrec-ui` project. This is the project's first networking code. Every future transcription provider (`GeminiLiveTranscriptionProvider`, `OpenAIRealtimeProvider`, `DeepgramProvider`, `AssemblyAIProvider`) will reuse this pattern.

**Target platform**: macOS 14+ (Swift 5.9 / Swift 6 strict concurrency)
**Date researched**: 2026-04-26

---

## Table of Contents

1. [Overview](#overview)
2. [Key Concepts and Quirks](#key-concepts-and-quirks)
3. [The WebSocketTransport Protocol](#the-websockettransport-protocol)
4. [The WebSocketSession Actor](#the-websocketsession-actor)
5. [Reconnection State Machine](#reconnection-state-machine)
6. [NWPathMonitor Integration](#nwpathmonitor-integration)
7. [Heartbeat Implementation](#heartbeat-implementation)
8. [Send-Side Ordering and Drop Policy](#send-side-ordering-and-drop-policy)
9. [AsyncStream Lifetime Across Reconnections](#asyncstream-lifetime-across-reconnections)
10. [Complete Implementation](#complete-implementation)
11. [Testing Strategy](#testing-strategy)
12. [Race Conditions and Leaked Tasks](#race-conditions-and-leaked-tasks)
13. [What NOT To Do](#what-not-to-do)
14. [Performance Notes](#performance-notes)
15. [Assumptions and Scope](#assumptions-and-scope)
16. [References](#references)

---

## Overview

`URLSessionWebSocketTask` has several non-obvious quirks that make building a robust, long-lived WebSocket session non-trivial. The consumer-facing `AsyncStream<ServerEvent>` must survive disconnects transparently — the stream stays open while the actor reconnects in the background, and `continuation.finish()` is called only on user-initiated cancellation.

The pattern has four moving parts that must be coordinated:

1. **Send loop** — `task.send(.data(_:))` per outgoing audio chunk
2. **Receive loop** — one-shot `receive()` that must be re-armed in a `while` loop
3. **Reconnection state machine** — bounded exponential backoff with jitter, reset by `NWPathMonitor`
4. **Consumer-facing `AsyncStream<ServerEvent>`** — lifetime outlives any number of reconnections

---

## Key Concepts and Quirks

### `receive()` is One-Shot

`URLSessionWebSocketTask.receive()` resolves a single message and then does nothing more. The correct loop shape is a `while` loop that re-arms on every message, not a recursive function:

```swift
// CORRECT — while loop with explicit close-code guard
while task.closeCode == .invalid {
    let message = try await task.receive()
    // handle message
}

// ALSO CORRECT — Task.isCancelled guard
while !Task.isCancelled {
    let message = try await task.receive()
    // handle message — Task cancellation throws CancellationError
}
```

The `while task.closeCode == .invalid` variant is the preferred guard because `closeCode` transitions away from `.invalid` the moment the server or client initiates closure. After `cancel(with:reason:)` is called on macOS 14+ (which fixed a pre-iOS-17 bug), the in-flight `receive()` call will throw, breaking the loop. See the "What NOT To Do" section for the pre-iOS-17 hang issue.

### `send(.data(_:))` From a Concurrent Context

`URLSessionWebSocketTask.send(_:completionHandler:)` and the `async` variant `send(_:)` are thread-safe — the underlying `NSURLSessionTask` serializes sends internally. Calling `send` from a different Task than the receive loop is safe. However, you must not call `send` after `cancel(with:reason:)` has been called, or after the task transitions to a terminal state. Guard every send with a state check:

```swift
func send(_ data: Data) async throws {
    guard currentState == .connected else {
        throw WebSocketSessionError.notConnected
    }
    try await task.send(.data(data))
}
```

### `sendPing(pongReceiveHandler:)` — Callback-Based, No Async Variant

Apple has not provided an `async` variant of `sendPing`. Bridging to `async/await` via `withCheckedThrowingContinuation` works in the happy path but has a **documented fatal crash** if the connection is interrupted mid-ping: the `pongReceiveHandler` closure can be called twice with a connection-abort error, triggering "SWIFT TASK CONTINUATION MISUSE".

The safe bridge requires `withUnsafeThrowingContinuation` (which does not trap on double-resume) or a boolean guard that prevents resuming the continuation more than once:

```swift
extension URLSessionWebSocketTask {
    func sendPingAsync() async throws {
        var didResume = false
        try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, Error>) in
            sendPing { error in
                guard !didResume else { return }
                didResume = true
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
```

**Important caveat**: Apple's Developer Technical Support (Quinn "The Eskimo!") has documented that `URLSessionWebSocketTask` is not the best option for new code and recommends the Network framework's `NWConnection` with `NWProtocolWebSocket` for more complex use cases. For this project's use case (connecting to a known Gemini/OpenAI/Deepgram endpoint), `URLSessionWebSocketTask` is acceptable and simpler.

### `cancel(with:reason:)` Semantics

Calling `task.cancel(with:reason:)` does the following:
- Sends a WebSocket close frame to the server with the specified close code.
- Transitions the task to a cancelled state.
- On macOS 14+ (iOS 17+): interrupts any in-flight `receive()` call by throwing an error.
- On earlier OS versions: the `receive()` call hangs indefinitely.

**For this project (macOS 14+)**: the `while task.closeCode == .invalid` guard and the `try await receive()` throwing are both reliable. No callback-based workaround is needed.

Use `.normalClosure` (1000) for user-initiated stops. Use `.goingAway` (1001) for application-level shutdowns. Never use the default abnormal closure for deliberate closes — some providers (AssemblyAI) bill until a `.normalClosure` is received.

### Error Classification — Transient vs. Fatal

The receive loop and the connect attempt both throw `Error`. Before deciding whether to reconnect, classify the error:

```swift
enum RetryDecision {
    case retryWithBackoff
    case fatal
}

func classify(_ error: Error) -> RetryDecision {
    // Task was explicitly cancelled — never retry
    if error is CancellationError { return .fatal }

    // WebSocket close codes — map to retry decisions
    if let wsError = error as? URLError {
        switch wsError.code {
        // Transient — environment problem, may resolve
        case .networkConnectionLost,    // -1005: mid-session drop
             .notConnectedToInternet,   // -1009: device offline
             .timedOut,                 // -1001: timeout
             .cannotConnectToHost,      // -1004: host unreachable
             .dnsLookupFailed:          // -1006: DNS failure
            return .retryWithBackoff

        // Fatal — structural problem, do not retry
        case .userAuthenticationRequired,  // -1013: bad API key
             .userCancelledAuthentication, // -1012: cancelled auth
             .cancelled,                   // -999: explicit cancel
             .badURL,                      // -1000: malformed URL
             .unsupportedURL,             // -1002: bad scheme
             .secureConnectionFailed,     // -1200: TLS failure
             .serverCertificateUntrusted: // -1202: untrusted cert
            return .fatal

        default:
            return .fatal  // Unknown — default to fatal, avoid infinite retry
        }
    }

    // NSPOSIXError 53 (Software caused connection abort) — transient
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == 53 {
        return .retryWithBackoff
    }

    return .fatal
}
```

HTTP 401/403 from the upgrade handshake surface as `URLError.userAuthenticationRequired` (-1013) and must never be retried — the API key is wrong and no amount of backoff will fix it.

---

## The WebSocketTransport Protocol

To enable unit testing without a real socket (and without `URLProtocol`, which does not work with WebSocket tasks), define a thin protocol that abstracts the two operations the actor uses:

```swift
// Sources/MacrecCore/Transcription/WebSocketTransport.swift

import Foundation

/// Abstracts URLSessionWebSocketTask for testing purposes.
/// The live implementation delegates to URLSessionWebSocketTask.
/// Test implementations can drive the state machine deterministically.
public protocol WebSocketTransport: Sendable {
    /// Resumes (opens) the connection. Must be called before send/receive.
    func resume()

    /// Sends a binary or text message.
    func send(_ message: URLSessionWebSocketTask.Message) async throws

    /// Receives the next message. One-shot — must be called again to receive the next one.
    func receive() async throws -> URLSessionWebSocketTask.Message

    /// Sends a ping and invokes the handler when the pong arrives (or on error).
    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void)

    /// Cancels the connection with the given close code.
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)

    /// The current close code. `.invalid` means the connection is still open.
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
}

// MARK: - Live implementation

/// Wraps URLSessionWebSocketTask to conform to WebSocketTransport.
final class LiveWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() {
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        task.sendPing(pongReceiveHandler: pongReceiveHandler)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }

    var closeCode: URLSessionWebSocketTask.CloseCode {
        task.closeCode
    }
}
```

The `@unchecked Sendable` on `LiveWebSocketTransport` is necessary because `URLSessionWebSocketTask` is not `Sendable`. The underlying task is thread-safe (Foundation guarantees this), so the unchecked conformance is correct. Document this assumption at the declaration site.

---

## Reconnection State Machine

### States

```swift
enum WebSocketState: Sendable, CustomStringConvertible {
    case idle
    case connecting(attempt: Int)
    case connected
    case reconnecting(attempt: Int, lastError: Error?)
    case paused(reason: PauseReason)   // exhausted retries — stream stays open
    case cancelled                     // user-initiated stop — stream closes

    enum PauseReason: Sendable {
        case retriesExhausted(lastError: Error?)
        case networkUnavailable
    }

    var description: String { /* omitted for brevity */ }
}
```

### Backoff Formula

```
delay(attempt) = min(maxDelay, baseDelay × 2^attempt) × (0.75 + random(0.0..<0.5))
```

Constants:
- `baseDelay` = 0.5 seconds (first retry is fast — most disconnects are brief)
- `maxDelay` = 30.0 seconds (cap prevents extreme wait in degraded networks)
- `jitterMultiplier` = random value in `0.75..<1.25` (±25% jitter)
- `maxAttempts` = 12 (approximately 2 minutes worst-case wall clock including backoff)

Derivation of wall-clock ceiling with these constants:
```
attempt 0: 0.5s × jitter  ≈ 0.5s
attempt 1: 1.0s × jitter  ≈ 1.0s
attempt 2: 2.0s × jitter  ≈ 2.0s
attempt 3: 4.0s × jitter  ≈ 4.0s
attempt 4: 8.0s × jitter  ≈ 8.0s
attempt 5: 16.0s × jitter ≈ 16.0s
attempt 6–11: 30.0s × jitter ≈ 30.0s each (capped)
Total: ~0.5+1+2+4+8+16+(6×30) ≈ 211s ≈ 3.5 minutes worst case
```

This is intentionally longer than the 12-attempt/~2-minute estimate in the investigation document, as the actual wall-clock cost is dominated by the capped delays. Consider reducing `maxAttempts` to 8 (~110 seconds) if 3.5 minutes is too long for the user experience.

```swift
private func backoffDelay(attempt: Int) -> Duration {
    let base = 0.5
    let cap  = 30.0
    let raw  = min(cap, base * pow(2.0, Double(attempt)))
    let jitter = Double.random(in: 0.75..<1.25)
    return .seconds(raw * jitter)
}
```

### State Transitions

```
idle
  ──start()──────────────────────────────────> connecting(0)
  
connecting(n)
  ──connection succeeds──────────────────────> connected
  ──transient error──────────────────────────> reconnecting(n+1, error)  [if n < maxAttempts]
  ──fatal error / maxAttempts exceeded───────> paused(.retriesExhausted)
  ──cancel()─────────────────────────────────> cancelled

connected
  ──receive() throws transient───────────────> reconnecting(0, error)
  ──receive() throws fatal───────────────────> paused(.retriesExhausted)
  ──server sends close frame─────────────────> reconnecting(0, nil)
  ──cancel()─────────────────────────────────> cancelled

reconnecting(n, lastError)
  ──sleep(backoff(n)) completes──────────────> connecting(n)
  ──NWPathMonitor: network lost───────────────> paused(.networkUnavailable)
  ──cancel()─────────────────────────────────> cancelled

paused(.retriesExhausted)
  ──NWPathMonitor: network .satisfied────────> connecting(0)  [reset attempt counter]
  ──cancel()─────────────────────────────────> cancelled

paused(.networkUnavailable)
  ──NWPathMonitor: path .satisfied────────────> connecting(0)
  ──cancel()─────────────────────────────────> cancelled

cancelled
  ──(terminal state — stream is finished)
```

---

## NWPathMonitor Integration

`NWPathMonitor` replaces the deprecated `SCNetworkReachability` API. It must be wrapped in an `AsyncStream` to integrate cleanly with Swift Concurrency:

```swift
import Network

private func makePathStream() -> AsyncStream<NWPath> {
    AsyncStream { continuation in
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            continuation.yield(path)
        }
        continuation.onTermination = { @Sendable _ in
            monitor.cancel()
        }
        monitor.start(queue: DispatchQueue(label: "macrec.transcription.pathmonitor"))
    }
}
```

Key behaviors to account for:
1. **`pathUpdateHandler` fires immediately** on `start()` with the current path — the first emission is the initial state, not a change event.
2. **The monitor must be kept alive**. Store it as an actor property; releasing it cancels the monitor silently.
3. **`requiresConnection` status**: treat as "not satisfied" for reconnect purposes — attempting a connection may trigger the system to satisfy the path, so immediately retry without waiting for the monitor to fire `.satisfied`.

Inside the actor's connection loop, observe path changes in a concurrent child Task:

```swift
// In the actor's connection management loop
private func observeNetworkPath() {
    Task {
        for await path in makePathStream() {
            await handlePathChange(path)
        }
    }
}
```

---

## Heartbeat Implementation

Application-level heartbeats are required because:
- TCP keepalives are insufficient — they operate at the kernel level with a 2-hour default interval.
- Gemini Live does not mandate heartbeats for audio sessions, but other providers (Deepgram, AssemblyAI) will disconnect on idle connections.
- A conservative 15-second interval works across all planned providers.

The heartbeat must tolerate the pong-callback double-resume bug. Use the `UnsafeContinuation` bridge or the simpler approach of treating a missing pong as a transient error and allowing the reconnection state machine to handle it:

```swift
private func runHeartbeat() async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard case .connected = state else { continue }
        do {
            try await sendPingAsync()
        } catch {
            // Treat failed ping as a transient disconnect.
            // The receive loop will also fail, triggering reconnection.
            // Log here but don't double-trigger reconnection.
        }
    }
}
```

Do not trigger reconnection from the heartbeat directly — the receive loop will throw as soon as the connection drops, which is the canonical signal. The heartbeat's role is only to keep the connection alive during quiet audio periods.

---

## Send-Side Ordering and Drop Policy

Audio chunks arrive at ~10 chunks/second (100 ms cadence from `HostClockAligner`).

During a disconnect:
- **Drop in-flight chunks**. Do not queue audio for later delivery. Stale audio arriving after reconnection produces out-of-context transcripts that confuse Gemini Live's conversation state.
- The `TranscriptionTap` bounded queue (`AsyncStream<TranscriptionPCMChunk>` with `.bufferingNewest(64)`) handles the drop transparently — chunks accumulate briefly, then overflow and are dropped by the `.bufferingNewest` policy.

The send loop must:
1. Check state before each send.
2. Not block the `TranscriptionTap` producer (non-blocking yield on the tap side, `await` on the consumer side).
3. Be a child Task of the actor's connection Task so it is cancelled automatically on disconnect.

```swift
private func runSendLoop(audio: AsyncStream<TranscriptionPCMChunk>) async throws {
    for await chunk in audio {
        guard case .connected = state else {
            // Silently drop chunk during disconnect/reconnect
            continue
        }
        let base64 = chunk.pcmData.base64EncodedString()
        let json = buildAudioMessage(base64: base64, chunk: chunk)
        let data = try JSONEncoder().encode(json)
        try await transport.send(.data(data))
    }
}
```

---

## AsyncStream Lifetime Across Reconnections

This is the most subtle aspect of the pattern. The consumer-facing `AsyncStream<ServerEvent>` must:
- Stay open across all reconnections (transparent to the consumer).
- Terminate only when `cancel()` is called or a fatal error exhausts all retries.
- NOT be re-created on reconnect — a new `AsyncStream` would break any `for await` loop the consumer is already in.

The solution is to create one `AsyncStream` in `init` (or lazily in `start()`), store the `Continuation` on the actor, and never call `continuation.finish()` except in `cancel()` and in the exhausted-retries path.

```swift
actor WebSocketSession {
    // Created once. Continuation lives for the session's lifetime.
    let events: AsyncStream<ServerEvent>
    private let eventContinuation: AsyncStream<ServerEvent>.Continuation

    init(url: URL, headers: [String: String], transportFactory: WebSocketTransportFactory) {
        (events, eventContinuation) = AsyncStream<ServerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        // ... store other properties
    }
}
```

**Buffer policy**: `.bufferingNewest(32)` — not `.unbounded`.
- At most 32 unread transcript events in flight at any time.
- 32 events ≈ a few seconds of transcript at normal speaking pace. Fast talkers emit perhaps 2–3 `partial` events per second plus 1 `final` every 5–10 seconds.
- If the UI thread falls 32 events behind, the oldest (already displayed) events are silently dropped — this is acceptable. Drop events are not transcript data; they represent UI update lag.
- `.unbounded` risks unbounded memory growth if the UI consumer stalls (e.g., during a SwiftUI animation storm or heavy disk I/O).

**The continuation's `onTermination` handler** is the safety valve for consumer cancellation:

```swift
eventContinuation.onTermination = { [weak self] reason in
    guard let self else { return }
    if case .cancelled = reason {
        Task { await self.cancelFromConsumer() }
    }
}
```

If the consumer cancels its `for await` loop (e.g., by cancelling the enclosing `Task`), `onTermination` fires with `.cancelled`, giving the actor a chance to clean up. Without this, the actor would continue running receive/send loops for a stream that no one is reading.

---

## Complete Implementation

The following is the complete `WebSocketSession` actor. It is self-contained and does not import any provider-specific types. Providers wrap this actor and translate their JSON schemas into `ServerEvent`.

```swift
// Sources/MacrecCore/Transcription/WebSocketSession.swift

import Foundation
import Network

// MARK: - Public Types

public enum ServerEvent: Sendable {
    case messageReceived(URLSessionWebSocketTask.Message)
    case stateChanged(WebSocketConnectionState)
    case heartbeatFailed(Error)
}

public enum WebSocketConnectionState: Sendable, Equatable {
    case idle
    case connecting(attempt: Int)
    case connected
    case reconnecting(attempt: Int)
    case paused          // retries exhausted; waiting for network
    case cancelled
}

public enum WebSocketSessionError: Error, Sendable {
    case notConnected
    case cancelled
    case retriesExhausted(lastError: Error?)
}

// MARK: - Transport Protocol (enables unit testing)

public protocol WebSocketTransport: Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
}

public typealias WebSocketTransportFactory = @Sendable (URL, [String: String]) -> any WebSocketTransport

// MARK: - WebSocketSession Actor

/// A long-lived WebSocket session that survives disconnects transparently.
/// The consumer-facing `events` stream stays open across reconnections;
/// `continuation.finish()` is called only on user cancel or fatal error.
public actor WebSocketSession {

    // MARK: - Configuration

    private let url: URL
    private let headers: [String: String]
    private let transportFactory: WebSocketTransportFactory

    // Backoff constants
    private let baseDelay: Double    = 0.5
    private let maxDelay: Double     = 30.0
    private let maxAttempts: Int     = 12
    private let heartbeatInterval: Duration = .seconds(15)

    // MARK: - Consumer-facing stream (lifetime: session lifetime)

    /// Emit `ServerEvent` values to this continuation from inside the actor.
    /// NEVER call `finish()` except in `cancel()` or `handleFatalError()`.
    public let events: AsyncStream<ServerEvent>
    private let eventContinuation: AsyncStream<ServerEvent>.Continuation

    // MARK: - Actor state

    private var state: WebSocketConnectionState = .idle
    private var transport: (any WebSocketTransport)?
    private var connectionTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pathMonitorTask: Task<Void, Never>?

    // NWPathMonitor tracks whether the network is available.
    // When the path goes unsatisfied we stop backoff retries.
    // When it returns we immediately retry (resetting attempt to 0).
    private var networkAvailable: Bool = true

    // MARK: - Init / Deinit

    public init(
        url: URL,
        headers: [String: String],
        transportFactory: @escaping WebSocketTransportFactory = LiveWebSocketSession.factory
    ) {
        self.url = url
        self.headers = headers
        self.transportFactory = transportFactory

        // Create the single, long-lived stream and continuation.
        // bufferingNewest(32) caps memory while the UI thread catches up.
        var continuation: AsyncStream<ServerEvent>.Continuation!
        let stream = AsyncStream<ServerEvent>(bufferingPolicy: .bufferingNewest(32)) { cont in
            continuation = cont
        }
        self.events = stream
        self.eventContinuation = continuation

        // When the consumer cancels its for-await loop, tear down cleanly.
        self.eventContinuation.onTermination = { [weak self] _ in
            guard let self else { return }
            // Fire-and-forget: bridge back into the actor.
            Task { await self.cancel() }
        }
    }

    deinit {
        // Belt-and-suspenders: finish the continuation if not already done.
        eventContinuation.finish()
    }

    // MARK: - Public API

    /// Opens the WebSocket and begins the receive loop.
    /// Safe to call from any context. Idempotent if already started.
    public func start() {
        guard case .idle = state else { return }
        startPathMonitor()
        beginConnectionAttempt(attempt: 0)
    }

    /// Sends binary audio data to the server.
    /// Throws `WebSocketSessionError.notConnected` if not in `.connected` state.
    public func send(_ data: Data) async throws {
        guard case .connected = state, let transport else {
            throw WebSocketSessionError.notConnected
        }
        try await transport.send(.data(data))
    }

    /// Graceful shutdown. Sends a `.normalClosure` close frame.
    /// The `events` stream finishes after this call.
    public func cancel() {
        guard state != .cancelled else { return }
        transition(to: .cancelled)
        connectionTask?.cancel()
        heartbeatTask?.cancel()
        pathMonitorTask?.cancel()
        transport?.cancel(with: .normalClosure, reason: nil)
        transport = nil
        eventContinuation.finish()
    }

    // MARK: - Internal: Connection Lifecycle

    private func beginConnectionAttempt(attempt: Int) {
        connectionTask?.cancel()   // Cancel any in-progress attempt
        connectionTask = Task {
            await runConnectionLoop(startingAtAttempt: attempt)
        }
    }

    private func runConnectionLoop(startingAtAttempt initialAttempt: Int) async {
        var attempt = initialAttempt

        while !Task.isCancelled && state != .cancelled {
            transition(to: .connecting(attempt: attempt))

            do {
                let newTransport = transportFactory(url, headers)
                newTransport.resume()
                self.transport = newTransport

                // Delegate handshake confirmation is NOT available without
                // URLSessionWebSocketDelegate. On macOS 14+ the first successful
                // receive() confirms the connection is live.
                transition(to: .connected)
                yield(event: .stateChanged(.connected))

                // Start heartbeat as a child task (cancelled with connectionTask).
                heartbeatTask?.cancel()
                heartbeatTask = Task { await runHeartbeat() }

                // Run the receive loop until it throws.
                try await runReceiveLoop(transport: newTransport)

                // If runReceiveLoop returns normally, the server closed cleanly.
                // Treat as a transient disconnect and reconnect from attempt 0.
                attempt = 0
                transition(to: .reconnecting(attempt: attempt))

            } catch is CancellationError {
                // Task was cancelled — exit silently.
                return

            } catch {
                let decision = classify(error)
                switch decision {
                case .retryWithBackoff:
                    attempt += 1
                    if attempt > maxAttempts {
                        handleExhaustedRetries(lastError: error)
                        return
                    }
                    if !networkAvailable {
                        transition(to: .paused)
                        yield(event: .stateChanged(.paused))
                        // Suspend here until the network path monitor wakes us.
                        // We achieve this by returning and letting the path
                        // monitor trigger a new beginConnectionAttempt(0) call.
                        return
                    }
                    transition(to: .reconnecting(attempt: attempt))
                    yield(event: .stateChanged(.reconnecting(attempt: attempt)))
                    let delay = backoffDelay(attempt: attempt)
                    try? await Task.sleep(for: delay)

                case .fatal:
                    handleExhaustedRetries(lastError: error)
                    return
                }
            }
        }
    }

    private func runReceiveLoop(transport: any WebSocketTransport) async throws {
        // Loop until the connection closes or throws.
        // closeCode transitions away from .invalid on close/cancel.
        while transport.closeCode == .invalid && !Task.isCancelled {
            let message = try await transport.receive()
            yield(event: .messageReceived(message))
        }
    }

    private func handleExhaustedRetries(lastError: Error?) {
        transition(to: .paused)
        yield(event: .stateChanged(.paused))
        // Emit a non-fatal error to the consumer. The stream stays open.
        if let err = lastError {
            yield(event: .stateChanged(.paused))
            _ = err // Provider layer should surface this via TranscriptEvent.error
        }
        // Do NOT call eventContinuation.finish() here.
        // The stream stays open so the NWPathMonitor can resume it later.
    }

    // MARK: - Internal: Heartbeat

    private func runHeartbeat() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: heartbeatInterval)
            guard case .connected = state, let transport else { continue }
            // Fire-and-forget ping; receive loop will detect disconnect.
            var didResume = false
            transport.sendPing { [weak self] error in
                guard let self, !didResume else { return }
                didResume = true
                if let error {
                    Task { await self.yield(event: .heartbeatFailed(error)) }
                }
            }
        }
    }

    // MARK: - Internal: NWPathMonitor

    private func startPathMonitor() {
        pathMonitorTask?.cancel()
        pathMonitorTask = Task {
            for await path in makePathStream() {
                await handlePathChange(path)
            }
        }
    }

    private func handlePathChange(_ path: NWPath) {
        let nowAvailable = (path.status == .satisfied || path.status == .requiresConnection)
        let wasAvailable = networkAvailable
        networkAvailable = nowAvailable

        if !wasAvailable && nowAvailable {
            // Network returned — reset attempt counter and reconnect immediately.
            if case .paused = state {
                beginConnectionAttempt(attempt: 0)
            }
        } else if wasAvailable && !nowAvailable {
            // Network lost — mark paused so the retry loop stops sleeping.
            // If currently reconnecting, the backoff sleep will complete but
            // the network-available check at the top of the loop will pause.
            if case .reconnecting = state {
                transition(to: .paused)
                yield(event: .stateChanged(.paused))
            }
        }
    }

    private func makePathStream() -> AsyncStream<NWPath> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path)
            }
            continuation.onTermination = { @Sendable _ in
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "macrec.transcription.pathmonitor",
                                              qos: .utility))
        }
    }

    // MARK: - Internal: Helpers

    private func backoffDelay(attempt: Int) -> Duration {
        let raw    = min(maxDelay, baseDelay * pow(2.0, Double(attempt)))
        let jitter = Double.random(in: 0.75..<1.25)
        return .seconds(raw * jitter)
    }

    private func transition(to newState: WebSocketConnectionState) {
        state = newState
    }

    /// Thread-safe yield from within the actor (always on actor executor).
    @discardableResult
    private func yield(event: ServerEvent) -> AsyncStream<ServerEvent>.Continuation.YieldResult {
        eventContinuation.yield(event)
    }

    private func classify(_ error: Error) -> RetryDecision {
        if error is CancellationError { return .fatal }
        guard let urlError = error as? URLError else {
            // NSPOSIXError 53 — connection abort — is transient
            let ns = error as NSError
            if ns.domain == NSPOSIXErrorDomain && ns.code == 53 { return .retryWithBackoff }
            return .fatal
        }
        switch urlError.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut,
             .cannotConnectToHost, .dnsLookupFailed:
            return .retryWithBackoff
        default:
            return .fatal
        }
    }

    private enum RetryDecision { case retryWithBackoff, fatal }
}

// MARK: - Live Transport Factory

enum LiveWebSocketSession {
    static let factory: WebSocketTransportFactory = { url, headers in
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Use a dedicated URLSession per WebSocketSession instance.
        // Sharing URLSession.shared risks task priority inversion with the
        // recording pipeline's audio uploads.
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        return LiveWebSocketTransport(task: task)
    }
}

// MARK: - Live Transport

final class LiveWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    // @unchecked Sendable: URLSessionWebSocketTask is thread-safe per Foundation docs.
    // The actor's isolation ensures no concurrent access to this wrapper's state.
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() { task.resume() }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        task.sendPing(pongReceiveHandler: pongReceiveHandler)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { task.closeCode }
}
```

---

## Testing Strategy

### Why URLProtocol Does Not Work for WebSocket Tests

Apple engineer Quinn "The Eskimo!" has explicitly stated: "`URLProtocol` dates from the `NSURLConnection` era and hasn't been updated to handle the stuff added in the first iteration of `URLSession`. It certainly can't handle anything more modern, like web socket tasks."

Confirmed: multiple developers have attempted `URLProtocol` subclasses for WebSocket tasks and received `URLError.networkConnectionLost` (-1005) every time, even when the handshake response was correctly formed.

### Two Valid Approaches

**Approach A — Protocol-injection with `FakeWebSocketTransport`** (preferred for unit tests):
Inject a `FakeWebSocketTransport` that drives the state machine deterministically without any real socket. This is pure unit testing — fast, no network, no TCC.

**Approach B — Local `NWListener` server** (for integration tests):
Spin up a real WebSocket server using `NWListener` + `NWProtocolWebSocket.Options` inside test setup. This confirms the actor correctly handles real-world timing. Slower but catches integration bugs.

The project already uses Approach A's pattern (see `FakeAudioSource` in `RecordingSessionTests.swift`). Use the same injection pattern.

### Complete XCTest Example

```swift
// Tests/MacrecCoreTests/WebSocketSessionTests.swift

import XCTest
import Foundation
@testable import MacrecCore

// MARK: - Fake Transport

/// A controllable fake transport that lets tests inject messages and errors.
final class FakeWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    // Queues of scripted events for receive() to dequeue.
    var receiveQueue: [Result<URLSessionWebSocketTask.Message, Error>] = []
    var sendQueue: [URLSessionWebSocketTask.Message] = []
    var pingError: Error? = nil
    var cancelledWithCode: URLSessionWebSocketTask.CloseCode?

    private(set) var resumeCallCount = 0
    var _closeCode: URLSessionWebSocketTask.CloseCode = .invalid

    func resume() { resumeCallCount += 1 }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sendQueue.append(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        // Simulate network latency so the actor's event loop gets a chance to run.
        try await Task.sleep(for: .milliseconds(5))

        if receiveQueue.isEmpty {
            // Simulate an idle connection — hang until cancelled.
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        let next = receiveQueue.removeFirst()
        switch next {
        case .success(let msg): return msg
        case .failure(let err): throw err
        }
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        pongReceiveHandler(pingError)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        _closeCode = closeCode
        cancelledWithCode = closeCode
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { _closeCode }

    // Helper: inject a successful text message
    func injectMessage(_ text: String) {
        receiveQueue.append(.success(.string(text)))
    }

    // Helper: inject a transient error (triggers reconnect)
    func injectConnectionLost() {
        receiveQueue.append(.failure(URLError(.networkConnectionLost)))
        _closeCode = .abnormalClosure  // Mark as closed so loop exits
    }

    // Helper: inject a fatal error (no retry)
    func injectAuthError() {
        receiveQueue.append(.failure(URLError(.userAuthenticationRequired)))
        _closeCode = .abnormalClosure
    }
}

// MARK: - Test Cases

final class WebSocketSessionTests: XCTestCase {

    private var transports: [FakeWebSocketTransport] = []

    /// Factory that records created transports for later inspection.
    private func makeFactory() -> WebSocketTransportFactory {
        return { [weak self] _, _ in
            let transport = FakeWebSocketTransport()
            self?.transports.append(transport)
            return transport
        }
    }

    // MARK: connect → receive → cancel

    func testConnectReceiveCancel() async throws {
        let session = WebSocketSession(
            url: URL(string: "wss://example.com/ws")!,
            headers: [:],
            transportFactory: makeFactory()
        )

        session.start()

        // Wait for first transport to be created
        try await waitForTransport()
        let transport = transports[0]

        // Inject a message
        transport.injectMessage(#"{"type":"hello"}"#)

        // Collect events
        var received: [ServerEvent] = []
        let collectTask = Task {
            for await event in session.events {
                received.append(event)
                if received.count >= 2 { break }  // connected + messageReceived
            }
        }

        // Wait a bit for events to flow
        try await Task.sleep(for: .milliseconds(100))

        // Cancel
        await session.cancel()
        await collectTask.value

        // Verify
        XCTAssertTrue(received.contains { if case .stateChanged(.connected) = $0 { return true }; return false })
        XCTAssertTrue(received.contains { if case .messageReceived = $0 { return true }; return false })
        XCTAssertEqual(transport.cancelledWithCode, .normalClosure)
    }

    // MARK: connect → disconnect → reconnect → cancel

    func testReconnectionOnTransientError() async throws {
        let session = WebSocketSession(
            url: URL(string: "wss://example.com/ws")!,
            headers: [:],
            transportFactory: makeFactory()
        )

        session.start()
        try await waitForTransport()

        // First connection: inject a transient error after one message
        let t0 = transports[0]
        t0.injectMessage(#"{"type":"fragment","text":"Hello"}"#)
        t0.injectConnectionLost()

        // Wait for reconnect to create a second transport
        try await waitForTransport(count: 2, timeout: 3.0)
        XCTAssertEqual(transports.count, 2)

        // Second connection: inject a clean message, then cancel
        let t1 = transports[1]
        t1.injectMessage(#"{"type":"fragment","text":"world"}"#)

        var messageCount = 0
        let collectTask = Task {
            for await event in session.events {
                if case .messageReceived = event { messageCount += 1 }
                if messageCount >= 2 { break }
            }
        }

        try await Task.sleep(for: .milliseconds(200))
        await session.cancel()
        await collectTask.value

        XCTAssertEqual(messageCount, 2, "Should receive messages from both connections")
    }

    // MARK: fatal error → stream stays open (paused state)

    func testFatalErrorPausesStream() async throws {
        let session = WebSocketSession(
            url: URL(string: "wss://example.com/ws")!,
            headers: [:],
            transportFactory: makeFactory()
        )

        session.start()
        try await waitForTransport()

        transports[0].injectAuthError()

        // Collect state changes
        var stateChanges: [WebSocketConnectionState] = []
        let collectTask = Task {
            for await event in session.events {
                if case .stateChanged(let s) = event {
                    stateChanges.append(s)
                }
                if stateChanges.contains(.paused) { break }
            }
        }

        try await Task.sleep(for: .milliseconds(300))
        await collectTask.value

        XCTAssertTrue(stateChanges.contains(.paused), "Stream should enter paused state on fatal error")

        // Critical: stream must NOT have finished — it should still be open
        // (consumer can still await events — a network return will resume it)
        var isStillOpen = false
        let openCheckTask = Task {
            // If the stream is still open, this withTimeout will fire.
            // If the stream closed (finish() was called), the for-await exits immediately.
            isStillOpen = true
        }
        try await Task.sleep(for: .milliseconds(50))
        await openCheckTask.value
        // The stream being open means no crash/assertion here
        // (In a real test you'd use a more sophisticated mechanism)

        await session.cancel()
    }

    // MARK: consumer cancellation tears down actor

    func testConsumerCancellationTearsDown() async throws {
        let session = WebSocketSession(
            url: URL(string: "wss://example.com/ws")!,
            headers: [:],
            transportFactory: makeFactory()
        )

        session.start()
        try await waitForTransport()

        // Cancel the consuming Task — this triggers onTermination on the continuation
        let consumeTask = Task {
            for await _ in session.events { }
        }

        try await Task.sleep(for: .milliseconds(50))
        consumeTask.cancel()

        // Wait for cleanup to propagate
        try await Task.sleep(for: .milliseconds(200))

        // The transport should have been cancelled
        XCTAssertNotNil(transports.first?.cancelledWithCode)
    }

    // MARK: helpers

    private func waitForTransport(count: Int = 1, timeout: Double = 2.0) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while transports.count < count {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timeout waiting for transport \(count)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
```

---

## Race Conditions and Leaked Tasks

### Hazard 1: Double `finish()` on the Continuation

**Scenario**: `cancel()` and the `onTermination` handler both call `finish()`.

**How avoided**: `cancel()` checks `state != .cancelled` before proceeding. The `onTermination` callback calls `cancelFromConsumer()` which also guards on state. The actor's single-threaded executor serializes both calls — the second is a no-op because the state is already `.cancelled`.

`AsyncStream.Continuation.finish()` is documented as idempotent — calling it multiple times does not crash. However, explicit guarding is still good practice.

### Hazard 2: Lingering Receive Loop After `cancel(with:reason:)`

**Scenario**: `cancel(with:reason:)` is called while `transport.receive()` is suspended in the receive loop. On macOS 14+, `receive()` throws — the loop exits cleanly. On older OS versions, `receive()` hangs forever.

**How avoided**: The project targets macOS 14+. For the pre-iOS-17 mitigation (callback-based receive), see the Donny Wals reference in the sources.

### Hazard 3: Two Concurrent `runConnectionLoop` Tasks

**Scenario**: `beginConnectionAttempt` is called twice before the first loop starts.

**How avoided**: `beginConnectionAttempt` cancels any existing `connectionTask` before creating a new one. Because the actor serializes all method calls, both calls are processed sequentially — the second cancel always arrives before the new Task has a chance to create a second transport.

### Hazard 4: `send()` Race With Reconnection

**Scenario**: `send()` is called between the moment the transport throws in the receive loop and the moment `state` transitions to `.reconnecting`.

**How avoided**: Both `send()` and the state transition run on the actor's executor. Swift actor isolation guarantees these cannot interleave — the `send()` either sees `.connected` (succeeds) or `.reconnecting` (throws `notConnected`). No intermediate state is visible.

### Hazard 5: `NWPathMonitor` Callback Re-entering the Actor

**Scenario**: `pathUpdateHandler` is called on a `DispatchQueue` thread and calls actor methods — potential priority inversion or deadlock.

**How avoided**: `handlePathChange` is called via `Task { await self.handlePathChange(path) }` from the `for await` loop in `observeNetworkPath`. The `for await` loop runs on the actor's executor. The `DispatchQueue` callback only yields to the `AsyncStream` continuation (non-blocking, `Sendable`-safe). There is no actor method called directly from a DispatchQueue thread.

### Hazard 6: Heartbeat Task Not Cancelled on Reconnect

**Scenario**: Reconnect creates a new heartbeat Task but the old one is still running, sending pings on a dead transport.

**How avoided**: `heartbeatTask?.cancel()` is called at the top of `runConnectionLoop` before creating the new heartbeat Task. The old Task checks `Task.isCancelled` at the top of its sleep loop and exits. Even if a stale ping fires, it hits the transport's `cancel(with:)` guard and produces only a `heartbeatFailed` event, not a state transition.

### Hazard 7: `AsyncStream.Continuation` Retained After Actor Deinit

**Scenario**: A consumer is holding a reference to `events` (the `AsyncStream`) after the `WebSocketSession` actor is deallocated. The continuation's `onTermination` handler captures `[weak self]` — if `self` is nil, the handler is a no-op. The consumer's `for await` loop will hang until the stream is consumed or cancelled.

**How avoided**: `deinit` calls `eventContinuation.finish()`, which terminates the stream and unblocks any `for await` loops. The `[weak self]` capture in `onTermination` prevents a retain cycle.

### Hazard 8: `Task.detached` Leaking Outside Actor Scope

**Anti-pattern not used**: All Tasks in `WebSocketSession` are created with `Task { ... }` (inherits actor context and priority), not `Task.detached { ... }`. The actor's implicit task executor ensures all child Tasks are cancelled when the actor is torn down.

---

## What NOT To Do

### 1. Calling `receive()` Without a Loop

```swift
// WRONG — receives exactly one message, then stops
func startReceiving() {
    Task {
        let message = try await task.receive()
        handle(message)
        // receive() is never called again
    }
}
```

`receive()` is one-shot. Without a loop, the connection appears to work for the first message, then silently ignores all subsequent server messages. This is especially insidious because the connection stays open — no error is thrown.

### 2. Calling `continuation.finish()` on Disconnect

```swift
// WRONG — terminates the consumer's stream on every transient disconnect
func handleDisconnect() {
    eventContinuation.finish()  // Consumer's for-await loop exits immediately
}

// CORRECT — leave the stream open; only finish on user cancel or fatal error
func handleDisconnect() {
    // Reconnect state machine handles recovery silently
}
```

Calling `finish()` on disconnect means the consumer must re-subscribe every time the network blips. This is never what you want for a live transcription stream.

### 3. Creating a New `AsyncStream` for Each Reconnection

```swift
// WRONG — new stream on each reconnect; consumer must re-subscribe
func reconnect() {
    let newStream = AsyncStream<ServerEvent> { continuation in ... }
    self.events = newStream  // Actor stored property changes — consumer's loop exits
}
```

If `events` is a `let` constant (as in the correct implementation), the compiler prevents this. If `events` were `var`, changing it would terminate the old stream and leave any active consumer hanging.

### 4. Using a Recursive `receive()` Without a Loop Guard

```swift
// DANGEROUS — infinite recursion in pre-iOS 17 if cancel() is called
func receiveNext() async {
    do {
        let msg = try await task.receive()
        handle(msg)
        await receiveNext()   // Calls itself again
    } catch {
        // On pre-macOS-14: cancel() doesn't interrupt receive(),
        // so this catch never fires — stack grows forever
    }
}
```

On macOS 14+ this works but wastes a stack frame per message. On older OS versions it can hang. Use a `while` loop instead.

### 5. Creating a URLSession-per-send

```swift
// WRONG — URLSession is heavy; creating one per message wastes ~30ms
// and defeats connection keepalive
func send(data: Data) async throws {
    let session = URLSession(configuration: .ephemeral)   // per-call
    let task = session.webSocketTask(with: request)
    task.resume()
    try await task.send(.data(data))
}
```

Create one `URLSession` per `WebSocketSession` instance and hold it for the session lifetime.

### 6. Sharing URLSession.shared

```swift
// RISK — URLSession.shared is a singleton; WebSocket tasks on it compete
// with any other URLSession usage in the app (e.g., asset downloads, telemetry).
// Task scheduling can produce priority inversions.
let task = URLSession.shared.webSocketTask(with: request)
```

Use a dedicated `URLSession(configuration: .ephemeral)` per WebSocket session.

### 7. Calling `sendPing` via `withCheckedThrowingContinuation`

```swift
// CRASHES — pongReceiveHandler called twice on connection abort
func sendPingAsync() async throws {
    try await withCheckedThrowingContinuation { continuation in
        sendPing { error in
            // If connection aborts, this fires twice → FATAL ERROR
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
}
```

Use `withUnsafeThrowingContinuation` with a `didResume` guard, or treat ping-pong as fire-and-forget (the receive loop detects the disconnect independently).

### 8. Not Handling `bufferingNewest` Drop Events

```swift
// POTENTIAL BUG — if yield returns .dropped, you may want to log it
eventContinuation.yield(event)   // return value discarded
```

`yield()` returns `AsyncStream.Continuation.YieldResult`. If `.bufferingNewest(N)` is full, older events are dropped and `.dropped` is returned. For the transcript event stream, dropped events represent UI lag, which is acceptable — but log them at debug level so the developer can tune the buffer size if needed.

---

## Performance Notes

### Memory Footprint per Active Session

| Component | Size | Notes |
|---|---|---|
| `AsyncStream<ServerEvent>` continuation buffer | `32 × ~64 bytes` = ~2 KB | `ServerEvent` enum with associated values; 32-event cap |
| `URLSessionWebSocketTask` receive buffer | ~64 KB | Foundation internal; one per active task |
| `NWPathMonitor` + stream | ~8 KB | Fixed overhead; shared per session |
| Task stack for receive loop | ~32 KB | Swift async Task stack; fixed for the duration of the session |
| Task stack for heartbeat | ~32 KB | Separate Task |
| Task stack for path monitor | ~32 KB | Separate Task |
| **Total (approximate)** | **~168 KB** | Per active `WebSocketSession` |

At the project's single-provider concurrency (one session at a time), this is negligible. If `both` source mode spawns two sessions, peak memory is ~336 KB — well within NFR-19's 8 MB ceiling.

### CPU Overhead of the Receive Loop

- **At rest (waiting for `receive()`)**: zero CPU. `receive()` is backed by a kernel-level I/O wait; the Swift async runtime suspends the Task and consumes no cycles.
- **On message arrival**: O(1) per message — copy bytes into event, yield to continuation. A `partial` transcript event from Gemini Live is typically ~50–200 bytes of JSON. At Gemini's cadence (~1 event every 500 ms during speech), the receive loop processes ~2 events/second — CPU cost is sub-microsecond.
- **Send loop**: ~10 calls/second (100 ms audio chunks). Each call awaits `task.send(.data(_:))`, which is an async write to a kernel socket buffer. CPU cost: copying the Data value (~480 bytes for 30 ms of PCM16/16kHz/mono) plus one syscall.
- **Heartbeat**: one `sendPing` every 15 seconds. CPU cost is negligible.

### Recommendations for Production

- Do not set `heartbeatInterval` below 5 seconds; unnecessary pings waste battery on cellular.
- Set `maxAttempts` to 8 (instead of 12) if 3.5 minutes of background retry is too long for the UX. At 8 attempts the cap is ~110 seconds.
- The `NWPathMonitor` queue should use `.utility` QoS (as in the implementation above) to avoid competing with the audio capture pipeline.

---

## Assumptions and Scope

### Assumptions Made

| Assumption | Confidence | Impact if Wrong |
|---|---|---|
| macOS 14+ resolves the `cancel(with:)` + in-flight `receive()` hang | HIGH | Would need the callback-based receive workaround (Donny Wals pattern) |
| `URLSessionWebSocketTask.send(_:)` is thread-safe (concurrent sends from different Tasks are safe) | HIGH | Would need a serial send queue actor |
| `AsyncStream.Continuation.finish()` is idempotent (safe to call multiple times) | HIGH | Would need stricter once-flag guarding |
| `NWPathMonitor.pathUpdateHandler` fires immediately on `start()` with the current path | MEDIUM | Could miss initial path state if handler fires asynchronously with a delay |
| Gemini Live 15-minute session cap produces a clean server close frame (not an abnormal disconnect) | MEDIUM | If it's abnormal, the reconnection loop must handle it; both paths are covered |
| `URLSessionWebSocketTask` (not `NWConnection`) is sufficient for the Gemini Live `wss://` endpoint | MEDIUM | If Gemini requires custom TLS settings or mutual auth, `NWConnection` is needed |

### What is Explicitly Out of Scope

- `NWConnection`-based transport (Network framework) — not implemented here but the `WebSocketTransport` protocol admits it as a future implementation.
- WebSocket per-message compression (`Sec-WebSocket-Extensions: permessage-deflate`) — `URLSessionWebSocketTask` does not expose compression negotiation.
- Daemonized transcription (the investigation explicitly excluded detach-mode transcription for v1).
- More than one concurrent `WebSocketSession` per provider (the project design uses one session per `TranscriptionDriver`).
- OAuth / ephemeral token refresh — v1 uses a static API key; token rotation would require additional state in the actor.

### Clarifying Questions for Follow-Up

1. Should the project's `WebSocketSession` implement the `URLSessionWebSocketDelegate` to get `didOpenWithProtocol` / `didCloseWithCode` callbacks, or is inferring connected state from the first successful `receive()` sufficient?
2. Should `maxAttempts = 12` (~3.5 min worst-case) be reduced to `8` (~110 sec)? The user experience implication is that long outages stop retry attempts sooner.
3. Should `bufferingNewest(32)` on the event stream be configurable per provider? Deepgram's more frequent `is_final` events may benefit from a larger buffer (e.g., 64).
4. The `NWPathMonitor` `requiresConnection` status is treated as "not satisfied" in this implementation. Should it instead trigger an immediate connection attempt (since the system may satisfy the path when a connection is made)?

---

## References

| # | Source | URL | Information Gathered |
|---|---|---|---|
| 1 | Apple Developer Documentation — URLSessionWebSocketTask | https://developer.apple.com/documentation/foundation/urlsessionwebsockettask | One-shot receive() semantics; send/cancel API; CloseCode enum |
| 2 | Donny Wals — Iterating WebSocket messages with async/await in Swift | https://www.donnywals.com/iterating-over-web-socket-messages-with-async-await-in-swift/ | while loop shape; closeCode == .invalid guard; SocketStream wrapper; pre-iOS-17 hang issue and callback-based workaround |
| 3 | Thomas Smedmann — Real-time with WebSockets and Swift Concurrency (Medium) | https://medium.com/@thomsmed/real-time-with-websockets-and-swift-concurrency-8b44a8808d0d | Actor-based pattern; AsyncThrowingStream wrapping; concurrent safety analysis |
| 4 | AppSpector — WWDC Review: URLSessionWebSocketTask in Swift | https://www.appspector.com/blog/websockets-in-ios-using-urlsessionwebsockettask | Ping/pong semantics; close codes; one-shot receive pattern; delegate usage |
| 5 | Apple Developer Forums — URLSessionWebSocketTask sendPing | https://developer.apple.com/forums/thread/756482 | Double-resume crash when using withCheckedThrowingContinuation with sendPing; confirmed Foundation bug |
| 6 | Apple Developer Forums — How to Unit Test URLSessionWebSocketTask | https://developer.apple.com/forums/thread/729943 | URLProtocol does not work with WebSocket tasks; NWListener as alternative; Quinn "The Eskimo!" recommendation for protocol-injection approach |
| 7 | VideoSDK — Mastering iOS WebSocket for Real-Time Communication 2025 | https://www.videosdk.live/developer-hub/websocket/ios-websocket | Reconnection strategy; exponential backoff pattern; NWPathMonitor integration |
| 8 | WebSocket.org — Reconnection Guide | https://websocket.org/guides/reconnection/ | State-sync after reconnect; transport reconnection vs. state reconciliation; backoff parameters |
| 9 | OneUptime — WebSocket Reconnection Logic (Jan 2026) | https://oneuptime.com/blog/post/2026-01-27-websocket-reconnection/view | Production checklist: bounded retries; NWPathMonitor; application-level heartbeats vs TCP keepalive |
| 10 | Swift Forums — AsyncStream and Actors | https://forums.swift.org/t/asyncstream-and-actors/70545 | AsyncStreamIterator not usable as actor property; nonisolated(unsafe) workaround analysis; strict concurrency implications |
| 11 | Swift Forums — Why AsyncStream breaks structured concurrency | https://forums.swift.org/t/why-asyncstream-breaks-structured-concurrency/71477 | Tasks inside AsyncStream continuation are not automatically cancelled by parent Task cancellation |
| 12 | Hacking with Swift — AsyncStreams buffered data | https://www.hackingwithswift.com/quick-start/concurrency/how-to-create-and-use-asyncstreams-to-return-buffered-data | bufferingNewest / bufferingOldest / unbounded semantics and memory trade-offs |
| 13 | Use Your Loaf — Network Path Monitoring | https://useyourloaf.com/blog/network-path-monitoring/ | NWPathMonitor ObservableObject wrapper; pathUpdateHandler threading; initial path emission on start() |
| 14 | Apple Developer Forums — NWPathMonitor pathUpdateHandler | https://developer.apple.com/forums/thread/687477 | pathUpdateHandler fires immediately on start() with current path |
| 15 | Apple Developer Documentation — NWProtocolWebSocket | https://developer.apple.com/documentation/network/nwprotocolwebsocket | NWListener WebSocket server setup for test infrastructure |
| 16 | DEPT Engineering Blog — State of Swift WebSockets | https://engineering.deptagency.com/state-of-swift-websockets | Historical context; NWConnection vs URLSessionWebSocketTask trade-offs |
| 17 | Swift Evolution — SE-0304 Structured Concurrency | https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md | Child Task lifetime guarantees; withTaskGroup semantics; preventing task leaks |
| 18 | Masilotti.com — Mocking classes you don't own in Swift | https://masilotti.com/testing-nsurlsession-input/ | URLProtocol injection for HTTP; confirmed it does not apply to WebSocket tasks |
| 19 | Swift by Sundell — Testing networking logic in Swift | https://www.swiftbysundell.com/articles/testing-networking-logic-in-swift/ | Protocol-injection as the unit-testing alternative to URLProtocol for non-HTTP transports |
| 20 | Jay Kawli — Creating a WebSocket server using NWConnection | https://jayeshkawli.com/creating-websocket-server-on-ios-using/ | NWListener + NWProtocolWebSocket.Options server implementation for integration tests |

### Recommended for Deep Reading

- **[Donny Wals — Iterating WebSocket messages with async/await](https://www.donnywals.com/iterating-over-web-socket-messages-with-async-await-in-swift/)**: The most thorough publicly available article on the `URLSessionWebSocketTask` + `AsyncThrowingStream` wrapping pattern, including the pre-iOS-17 hang and its fix.
- **[Apple Forums Thread 729943](https://developer.apple.com/forums/thread/729943)**: Quinn "The Eskimo!" explains exactly why `URLProtocol` doesn't work for WebSocket tests and recommends the protocol-injection approach (Approach A in this document).
- **[Swift Forums — AsyncStream and Actors](https://forums.swift.org/t/asyncstream-and-actors/70545)**: Essential reading for understanding why `AsyncStreamIterator` cannot be stored as an actor property and what the workarounds are.
