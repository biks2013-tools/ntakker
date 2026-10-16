// Sources/NtakkerCore/Transcription/Live/Soniox/SonioxStreamingSession.swift
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

    /// `var` since F9 (EVAL 2026-06-12): transports are single-use by
    /// design (`URLSessionWebSocketTaskTransport.connect` throws after
    /// `close`), so a reconnect swaps in a fresh instance minted by
    /// `transportFactory`.
    private var transport: any WebSocketTransport
    private let endpoint: URL
    private let configMessage: SonioxConfigMessage
    private let aggregator: SonioxTokenAggregator
    private let keepalive: SonioxKeepaliveTimer
    private let logger: Logger?

    /// F9: mints a fresh transport for reconnect-with-replay after a
    /// mid-session transport drop (network blip, Soniox server
    /// restart/idle close). `nil` disables reconnect — the session
    /// then terminates cleanly on the FIRST transport failure instead
    /// of emitting an error per subsequent ingest.
    private let transportFactory: (@Sendable () -> any WebSocketTransport)?

    /// F9: ring buffer of the most recent outbound PCM chunks, replayed
    /// into a fresh transport after reconnect so the audio spanning the
    /// drop is not lost. Each chunk carries its absolute byte offset in
    /// the session's audio stream (INF-1). Capped at 30 s of 16 kHz
    /// Int16 mono (~960 KB) so it covers the full 0 + 1 + 4 s reconnect
    /// backoff plus connect time.
    private var replayChunks: [(offset: Int, data: Data)] = []
    private var replayBytes: Int = 0
    private static let replayCapBytes: Int = 30 * 16_000 * MemoryLayout<Int16>.size

    /// INF-1: absolute byte offset of the next chunk appended to the ring.
    private var nextAppendOffset: Int = 0

    /// INF-1: absolute byte offset at which the current connection's
    /// audio stream starts. Soniox token timestamps are relative to it.
    private var connectionBaseOffset: Int = 0

    /// INF-1: absolute byte offset up to which audio is covered by final
    /// tokens. A reconnect replays from here, so already-transcribed
    /// audio is not sent (and transcribed) twice.
    private var committedOffset: Int = 0

    /// 16 kHz Int16 mono: bytes per millisecond of audio.
    private static let bytesPerMs: Int = 16 * MemoryLayout<Int16>.size

    private var isReconnecting: Bool = false
    private var reconnectAttempts: Int = 0
    private static let maxReconnectAttempts: Int = 3
    private static let reconnectDelays: [Duration] = [.zero, .seconds(1), .seconds(4)]

    /// Upper bound on how long `finish()` waits for the server's
    /// `{"finished": true}` response after the empty-text end-of-stream
    /// sentinel. `finish()` returns as soon as that frame arrives or
    /// the inbound stream ends (F17); this is only the cap. Tunable via
    /// init for tests that want a shorter shutdown window.
    private let finishGracePeriod: Duration

    /// F17: set when the server's `{"finished": true}` frame arrives.
    private var serverSentFinished: Bool = false

    /// F17: set when the current receive loop's inbound stream ends
    /// (cleanly or with an error) — no `finished` frame can follow.
    private var receiveLoopEnded: Bool = false

    /// F17: identifies the current receive loop so a loop replaced by a
    /// reconnect cannot mark its successor as ended.
    private var receiveGeneration: Int = 0

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
        logger: Logger? = nil,
        transportFactory: (@Sendable () -> any WebSocketTransport)? = nil
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.configMessage = configMessage
        self.aggregator = aggregator
        self.keepalive = keepalive
        self.finishGracePeriod = finishGracePeriod
        self.logger = logger
        self.transportFactory = transportFactory

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

        let int16Bytes = Self.float32ToInt16LEBytes(samples)

        // F9: keep the most recent ~5 s in the replay ring so a
        // reconnect can re-send the audio spanning the transport drop.
        appendToReplayRing(int16Bytes)

        // While a reconnect is in flight the chunk only lands in the
        // ring — the replay after the fresh connect delivers it.
        guard !isReconnecting else { return }

        do {
            try await transport.send(data: int16Bytes)
        } catch {
            // One transport failure triggers ONE reconnect (or one
            // terminal error when reconnect is unavailable) — never an
            // error event per subsequent chunk (F9).
            handleTransportDrop(reason: "soniox.ingest_failed: \(error.localizedDescription)")
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

        // Wait for the server's `{"finished": true}` response (or the
        // end of the inbound stream), capped at `finishGracePeriod`, so
        // a normal stop no longer pays the full grace period (F17). The
        // receive loop runs on this actor and lands frames between the
        // polls. We then cancel the loop so finish() always returns in
        // bounded time.
        let deadline = ContinuousClock.now.advanced(by: finishGracePeriod)
        while !serverSentFinished, !receiveLoopEnded, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        receiveTask?.cancel()
        receiveTask = nil

        // Drain any pending non-final tokens as a final event.
        for evt in await aggregator.drain() {
            yieldAndCount(evt)
        }

        await transport.close(code: .normal, reason: "ntakker-cli session ended")
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
        receiveGeneration += 1
        let generation = receiveGeneration
        receiveLoopEnded = false
        receiveTask = Task {
            let stream = self.transport.messages()
            defer {
                if self.receiveGeneration == generation { self.receiveLoopEnded = true }
            }
            do {
                for try await msg in stream {
                    if Task.isCancelled { break }
                    await self.handleIncoming(msg, aggregator: aggregator)
                }
                // F9: a CLEAN inbound-stream end (no thrown error) is a
                // no-op — exactly as before. It is NOT treated as a
                // transport drop: a mock ends its stream when its script
                // is exhausted, and a graceful WS close during `finish()`
                // also ends the stream here; reconnecting in either case
                // would corrupt the finish-drain. If a real server
                // closes the socket mid-session, the NEXT `ingest`'s
                // `transport.send` throws and triggers the reconnect via
                // `handleTransportDrop` from the ingest path.
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
                if self.isFinished || self.isReconnecting { return }
                // F9: a dead transport used to leave the session in a
                // zombie state — `isFinished` stayed false, so EVERY
                // subsequent ingest emitted a fresh error while
                // transcription was silently dead for the rest of the
                // recording. Now: reconnect when we can, terminate
                // cleanly (one terminal error) when we can't.
                self.handleTransportDrop(reason: "soniox.receive_failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Reconnect (F9, EVAL 2026-06-12)

    /// Bounded append to the replay ring (drops oldest chunks past the
    /// ~5 s cap).
    private func appendToReplayRing(_ chunk: Data) {
        replayChunks.append((offset: nextAppendOffset, data: chunk))
        nextAppendOffset += chunk.count
        replayBytes += chunk.count
        while replayBytes > Self.replayCapBytes, !replayChunks.isEmpty {
            replayBytes -= replayChunks.removeFirst().data.count
        }
    }

    /// Funnel for every mid-session transport failure. Exactly one of:
    ///   * reconnect available → log + kick off `runReconnect()` once;
    ///   * no factory → ONE `.error` event + `terminate()` so every
    ///     subsequent `ingest` is a silent no-op.
    private func handleTransportDrop(reason: String) {
        guard !isFinished, !isReconnecting else { return }
        guard transportFactory != nil else {
            recordError(reason)
            // Block re-entry from subsequent ingests until the async
            // terminate() lands (it sets `isFinished`).
            isReconnecting = true
            Task { await self.terminate() }
            return
        }
        logger?.warning("soniox: transport dropped (\(reason)) — reconnecting")
        // Surface ONE transient diagnostic per drop (mirrors Azure
        // realtime's "reconnecting" event) so the operator sees the
        // drop+reconnect in the event stream and logs. This is
        // non-fatal — transcription resumes after the reconnect — and
        // is emitted per-drop (rare), NOT per-chunk (the error spam the
        // F9 fix eliminated).
        recordError("\(reason) — reconnecting")
        isReconnecting = true
        receiveTask?.cancel()
        receiveTask = nil
        Task { await self.runReconnect(droppedBecause: reason) }
    }

    /// Reconnect-with-replay: mint a fresh transport, re-send the config
    /// frame, replay the audio after the last final token (INF-1), restart
    /// keepalive + receive loop.
    /// Up to `maxReconnectAttempts` attempts with 0 / 1 / 4 s backoff;
    /// exhaustion emits one terminal error and terminates the session.
    private func runReconnect(droppedBecause reason: String) async {
        guard let transportFactory else { return }
        await keepalive.stop()
        await transport.close(code: .normal, reason: "soniox reconnect")

        // INF-1: the fresh connection re-transcribes everything after
        // `committedOffset`, so the provisional (non-final) tokens of the
        // dropped connection are stale. Committed finals still buffered
        // in an unfinished utterance are flushed now — the new
        // connection never sees their audio again.
        for evt in await aggregator.prepareForReconnect() {
            yieldAndCount(evt)
        }

        while reconnectAttempts < Self.maxReconnectAttempts && !isFinished {
            let delay = Self.reconnectDelays[
                min(reconnectAttempts, Self.reconnectDelays.count - 1)
            ]
            reconnectAttempts += 1
            try? await Task.sleep(for: delay)
            guard !isFinished else { return }

            let fresh = transportFactory()
            do {
                try await fresh.connect(url: endpoint, headers: [:])
                try await fresh.send(text: Self.encode(configMessage))
                // INF-1: replay only the audio after the last final
                // token, and keep going until the chunks that arrived
                // during the replay (ingest only buffers them while
                // `isReconnecting`) are sent too.
                let replayFrom = max(committedOffset, replayChunks.first?.offset ?? nextAppendOffset)
                connectionBaseOffset = replayFrom
                var sentUpTo = replayFrom
                while sentUpTo < nextAppendOffset {
                    guard let chunk = replayChunks.first(where: { $0.offset + $0.data.count > sentUpTo }) else { break }
                    let skip = max(0, sentUpTo - chunk.offset)
                    try await fresh.send(data: skip == 0 ? chunk.data : Data(chunk.data.dropFirst(skip)))
                    sentUpTo = chunk.offset + chunk.data.count
                }
                // INF-2: `finish()` may have run during the awaits above.
                // It closed the OLD transport only, so installing the
                // fresh one now would leak a socket, a receive loop and
                // a keepalive loop for the rest of the process.
                guard !isFinished else {
                    await fresh.close(code: .normal, reason: "ntakker-cli session ended during reconnect")
                    return
                }
                transport = fresh
                startReceiveLoop()
                isReconnecting = false
                reconnectAttempts = 0
                await keepalive.start(transport: fresh)
                if isFinished {
                    // finish() interleaved with the keepalive start.
                    await keepalive.stop()
                }
                logger?.info("soniox: reconnected after transport drop (replayed \(sentUpTo - replayFrom) bytes)")
                return
            } catch {
                await fresh.close(code: .normal, reason: "soniox reconnect attempt failed")
                logger?.warning("soniox: reconnect attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts) failed: \(error.localizedDescription)")
            }
        }

        guard !isFinished else { return }
        isReconnecting = false
        recordError("soniox.reconnect_failed: transcription stopped after \(Self.maxReconnectAttempts) reconnect attempts (initial drop: \(reason))")
        await terminate()
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

        // INF-1: advance the committed boundary to the end of the latest
        // final token (timestamps are relative to this connection).
        for token in server.tokens where token.isFinal && !token.isMarker {
            if let endMs = token.endMs {
                committedOffset = max(committedOffset, connectionBaseOffset + endMs * Self.bytesPerMs)
            }
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
            serverSentFinished = true
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
    /// Int16 PCM bytes matching the Soniox config declaration
    /// (`audio_format = "pcm_s16le"`, `sample_rate = 16000`,
    /// `num_channels = 1`). F32 (EVAL 2026-06-12): delegates to the
    /// shared vDSP-backed `PCMConvert` (symmetric 32 767 scale) —
    /// previously one of five scalar copies with three conventions.
    static func float32ToInt16LEBytes(_ samples: [Float]) -> Data {
        PCMConvert.floatToInt16LE(samples)
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
