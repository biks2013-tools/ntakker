// Sources/MacrecCore/Transcription/Live/Soniox/SonioxStreamingSession.swift
//
// Plan-006 Phase D / Unit D2: the per-session state machine that owns
// one Soniox WebSocket connection.
//
// Wiring contract (per docs/design/plan-006-soniox-streaming.md §4 and
// project-design.md §SX-3 / §SX-4):
//
//   * `start()`   — connect transport, send the JSON config frame, kick
//                   off the keepalive sender, kick off the receive loop.
//                   Throws ONLY for pre-stream failures (connect / first
//                   text-frame send). Once `start()` returns successfully
//                   every subsequent failure is isolated as a
//                   `.error(detail:)` event on the session's event stream
//                   so the recording itself is never disrupted (NFR-17 /
//                   recording-integrity isolation).
//
//   * `ingest(_:)` — receives Float32 mono samples ALREADY at 16 kHz
//                   (the `StreamingTranscriptionPipeline` runs the
//                   `AudioDownsampler` 48k→16k step before fan-out, and
//                   `AppleSpeechSession`/`AppleSpeechAdapter` consume
//                   the same Float32 16 kHz contract — see
//                   `TranscriptionManager.ingestFrame(_:from:)`). The
//                   session converts Float32 [-1, 1] → Int16 little-
//                   endian PCM bytes and sends a binary frame. All
//                   exceptions are caught and surfaced as `.error`
//                   events.
//
//   * `finish()`  — send the empty text frame end-of-stream sentinel,
//                   wait briefly for the server's `{"finished":true}`
//                   response, drain the aggregator, close the transport,
//                   close the events stream. Idempotent.
//
// Threading model: `actor` so the receive-loop Task and ingest / finish
// callers serialise naturally. The events `AsyncStream` continuation is
// `Sendable` and is held by reference; yielding to it from any
// isolation context is safe.

import Foundation
import Logging

/// Streaming Soniox session. One instance per `(provider, source,
/// recording)` triple. Conforms to `StreamingTranscriptionSession` so
/// the existing `StreamingTranscriptionPipeline` can drive it
/// alongside `AppleSpeechSession`.
public actor SonioxStreamingSession: StreamingTranscriptionSession {

    // MARK: - Stored properties

    private let transport: any WebSocketTransport
    private let endpoint: URL
    private let configMessage: SonioxConfigMessage
    private let aggregator: SonioxTokenAggregator
    private let keepalive: SonioxKeepaliveTimer
    private let logger: Logger?

    /// Grace period the receive loop is given to consume the server's
    /// `{"finished": true}` response after we send the empty-text
    /// end-of-stream sentinel. Tunable via init for tests that want a
    /// shorter shutdown window.
    private let finishGracePeriod: Duration

    private let eventStream: AsyncStream<StreamingTranscriptionEvent>
    private let eventContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation

    private var receiveTask: Task<Void, Never>?
    private var isStarted: Bool = false
    private var isFinished: Bool = false
    private var didFinishContinuation: Bool = false
    private var metrics: StreamingProviderMetrics = StreamingProviderMetrics()

    // MARK: - StreamingTranscriptionSession conformance

    /// `events` is exposed `nonisolated` so callers (including
    /// `StreamingTranscriptionPipeline`) can iterate it without an
    /// `await session.events` hop. The underlying continuation is
    /// `Sendable`.
    public nonisolated var events: AsyncStream<StreamingTranscriptionEvent> { eventStream }

    // MARK: - Init

    public init(
        transport: any WebSocketTransport,
        endpoint: URL,
        configMessage: SonioxConfigMessage,
        aggregator: SonioxTokenAggregator = SonioxTokenAggregator(),
        keepalive: SonioxKeepaliveTimer = SonioxKeepaliveTimer(),
        finishGracePeriod: Duration = .seconds(2),
        logger: Logger? = nil
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.configMessage = configMessage
        self.aggregator = aggregator
        self.keepalive = keepalive
        self.finishGracePeriod = finishGracePeriod
        self.logger = logger

        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        self.eventStream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Connect the transport, send the initial config frame, start the
    /// keepalive timer, start the receive loop. Idempotent: a second
    /// call is a no-op.
    ///
    /// FATAL boundary: the only errors that propagate to the caller are
    /// (a) `transport.connect(...)` failure and (b) failure to send the
    /// initial config text frame. Both occur BEFORE we have anything to
    /// stream so the recording-integrity contract is unaffected — the
    /// caller (the factory) chooses whether to treat them as a hard
    /// configuration error or a soft "start the recording without a
    /// transcript" condition.
    public func start() async throws {
        guard !isStarted else { return }
        isStarted = true

        try await transport.connect(url: endpoint, headers: [:])
        let configJSON = try Self.encode(configMessage)
        try await transport.send(text: configJSON)
        await keepalive.start(transport: transport)
        startReceiveLoop()
    }

    /// `StreamingTranscriptionSession.ingest(_:)` — accepts Float32
    /// mono samples at 16 kHz (the contract the
    /// `StreamingTranscriptionPipeline` already produces). Converts to
    /// Int16 little-endian and sends a binary frame.
    ///
    /// Recording-integrity boundary: any conversion or transport error
    /// is caught and surfaced as `.error(detail:)`. The recording
    /// pipeline never sees a throw out of this method.
    public func ingest(_ samples: [Float]) async {
        guard isStarted, !isFinished else { return }
        guard !samples.isEmpty else { return }

        do {
            let int16Bytes = Self.float32ToInt16LEBytes(samples)
            try await transport.send(data: int16Bytes)
        } catch {
            recordError("soniox.ingest_failed: \(error.localizedDescription)")
        }
    }

    /// `StreamingTranscriptionSession.finish()` — idempotent shutdown.
    /// Sends the empty-text end-of-stream sentinel, waits briefly for
    /// `{"finished":true}`, drains any pending non-final tokens as a
    /// final, closes the transport, finishes the events stream.
    public func finish() async {
        // Pre-start finish: just close the events stream so iteration
        // terminates cleanly.
        guard isStarted else {
            isFinished = true
            finishContinuationIfNeeded()
            return
        }
        guard !isFinished else { return }
        isFinished = true

        await keepalive.stop()

        // End-of-stream sentinel per Soniox v4 protocol — empty text
        // frame tells the server "no more audio is coming".
        do {
            try await transport.send(text: "")
        } catch {
            // Closing anyway; not worth surfacing.
            logger?.debug("soniox.finish: send EOS sentinel failed: \(error.localizedDescription)")
        }

        // Give the receive loop a brief grace period to consume the
        // server's `{"finished": true}` response. We then cancel the
        // loop so finish() always returns in bounded time.
        try? await Task.sleep(for: finishGracePeriod)
        receiveTask?.cancel()
        receiveTask = nil

        // Drain any pending non-final tokens as a final event.
        for evt in await aggregator.drain() {
            yieldAndCount(evt)
        }

        await transport.close(code: .normal, reason: "macrec session ended")
        finishContinuationIfNeeded()
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        // Actors are not class-references; capture `self` strongly and
        // use `isFinished` to terminate cleanly. The Task body inherits
        // this actor's isolation so the `await` calls below resolve to
        // same-actor message sends (no hop, but still fully serialised
        // against `ingest(_:)` and `finish()`).
        let aggregator = self.aggregator
        receiveTask = Task {
            let stream = self.transport.messages()
            do {
                for try await msg in stream {
                    if Task.isCancelled { break }
                    await self.handleIncoming(msg, aggregator: aggregator)
                }
            } catch {
                // Suppress the receive-side error if we already
                // terminated due to a server-side error envelope —
                // otherwise we'd emit a redundant "soniox.receive_failed:
                // Socket is not connected" right after the real cause.
                // The enclosing Task inherits this actor's isolation
                // (see comment above at line ~193) so reading
                // `self.isFinished` is a same-actor access, not an
                // async hop — the `await` was redundant. Compiler
                // started flagging it on Swift 6 with strict
                // concurrency (no-async-in-await diagnostic).
                if self.isFinished { return }
                self.recordError("soniox.receive_failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleIncoming(
        _ msg: WebSocketTransportMessage,
        aggregator: SonioxTokenAggregator
    ) async {
        switch msg {
        case .text(let str):
            await handleTextFrame(str, aggregator: aggregator)
        case .data:
            // Soniox v4 server never sends binary frames on the inbound
            // direction; ignore defensively rather than throwing.
            logger?.debug("soniox: ignoring unexpected binary inbound frame")
        }
    }

    private func handleTextFrame(
        _ text: String,
        aggregator: SonioxTokenAggregator
    ) async {
        let server: SonioxServerMessage
        do {
            server = try Self.decode(SonioxServerMessage.self, from: text)
        } catch {
            recordError("soniox.decode_failed: \(error.localizedDescription)")
            return
        }

        if let code = server.errorCode {
            let mapped = SonioxErrorMapper.map(httpCode: code, message: server.errorMessage)
            recordError("soniox.server_error: \(mapped.errorDescription ?? "code \(code)")")
            // Soniox sent a server-side error envelope and will now close
            // the WebSocket. Terminate the session BEFORE any further
            // audio frames are accepted, so the next `ingest(_:)` calls
            // become no-ops instead of emitting a cascade of
            // "Socket is not connected" errors that hide the real cause.
            await terminate()
            return
        }

        // Forward token batch through the aggregator — its output is the
        // canonical `.partial` / `.final` event sequence.
        if !server.tokens.isEmpty {
            let events = await aggregator.ingest(server.tokens)
            for evt in events {
                yieldAndCount(evt)
            }
        }

        if server.finished == true {
            // Drain anything still buffered, emit a final metrics
            // snapshot, then close the events stream.
            for evt in await aggregator.drain() {
                yieldAndCount(evt)
            }
            yieldAndCount(.metrics(metrics))
            isFinished = true
            finishContinuationIfNeeded()
        }
    }

    // MARK: - Helpers

    private func yieldAndCount(_ event: StreamingTranscriptionEvent) {
        eventContinuation.yield(event)
        switch event {
        case .partial:
            metrics.partialsEmitted &+= 1
        case .final:
            metrics.finalsEmitted &+= 1
        case .error:
            metrics.errorCount &+= 1
        case .metrics:
            break
        }
    }

    private func recordError(_ detail: String) {
        eventContinuation.yield(.error(detail: detail))
        metrics.errorCount &+= 1
    }

    private func finishContinuationIfNeeded() {
        guard !didFinishContinuation else { return }
        didFinishContinuation = true
        eventContinuation.finish()
    }

    /// Terminate the session immediately after a fatal server-side
    /// condition (e.g. a 401 from Soniox in the error envelope). Stops
    /// the keepalive, cancels the receive loop, closes the transport,
    /// and finishes the events stream — all without emitting a
    /// redundant `.error` (the caller already emitted the real cause
    /// just before invoking this).
    ///
    /// Idempotent: a second call is a no-op.
    private func terminate() async {
        guard !isFinished else { return }
        isFinished = true
        await keepalive.stop()
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close(code: .normal, reason: "soniox terminal error")
        finishContinuationIfNeeded()
    }

    /// Convert Float32 mono samples in `[-1, 1]` to little-endian
    /// Int16 PCM bytes. The conversion mirrors the inverse of
    /// `TranscriptionManager.int16BytesToFloat(_:)` so the wire format
    /// matches what the Soniox config message declared
    /// (`audio_format = "pcm_s16le"`, `sample_rate = 16000`,
    /// `num_channels = 1`).
    static func float32ToInt16LEBytes(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let int16Ptr = base.bindMemory(to: Int16.self, capacity: samples.count)
            for i in 0..<samples.count {
                // Clamp to [-1, 1] then scale to Int16 range.
                let clamped = max(-1.0, min(1.0, samples[i]))
                let scaled = clamped < 0
                    ? clamped * Float(Int16.min) * -1   // -1.0 → 32768 → clipped to Int16.min
                    : clamped * Float(Int16.max)
                // Use Int32 intermediate to safely round and clip.
                let asInt = Int32(scaled.rounded())
                let clipped = max(Int32(Int16.min), min(Int32(Int16.max), asInt))
                int16Ptr[i] = Int16(clipped)
            }
        }
        return data
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw SonioxStreamingError.unexpectedServerMessage("invalid utf-8 string")
        }
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
}
