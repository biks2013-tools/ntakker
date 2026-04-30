// Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift —
// plan-007 Phase A2 §A2.6 / §A2.7 / §A2.8.
//
// Actor-isolated `StreamingTranscriptionSession` driving a Foundation
// `URLSessionWebSocketTask` against the Azure realtime
// `intent=transcription` endpoint. Owns:
//
//   * The WS task + receive-loop child task.
//   * The 16 → 24 kHz resampler.
//   * The 5 s `AudioRingBuffer<Int16>` for replay-on-reconnect.
//   * The accumulating partial-text dictionary keyed by `item_id`.
//   * The reconnect-with-replay state machine (close 1006/1001/1011 → up to 3 attempts).
//   * The 58-min pre-emptive reconnect timer for the 60-min Azure cap.
//   * The `events` `AsyncStream` sink that the caller consumes.
//
// The session does NOT own:
//   * Sidecar writing — `TranscriptionManager` owns the sidecar.
//   * Cost calculation — `TranscriptionMetrics` aggregates per-session.

import Foundation
import Logging

public actor AzureOpenAIRealtimeSession: StreamingTranscriptionSession {

    public let events: AsyncStream<StreamingTranscriptionEvent>
    private let eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation

    private let config: AzureOpenAIRealtimeConfig
    private let logger: Logger
    private let urlSession: URLSession

    private var wsTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var preemptiveReconnectTask: Task<Void, Never>?

    private let resampler = AudioResampler16to24()
    /// 5 s @ 24 kHz mono Int16 = 120,000 samples.
    private var ringBuffer = AudioRingBuffer<Int16>(capacity: 120_000, fill: 0)

    /// Partial text accumulator keyed by `item_id`. Cleared per item
    /// once `transcriptionCompleted` arrives.
    private var partialsByItem: [String: String] = [:]
    /// Per-item utterance UUIDs so the StreamingTranscriptionEvent
    /// stream stays consistent across reconnects (we mint a new UUID
    /// only when we see a new `item_id`).
    private var utteranceIdByItem: [String: UUID] = [:]

    private var metrics = StreamingProviderMetrics()
    private var sessionStart: Date?
    private var isClosed = false
    private var userInitiatedClose = false
    private var reconnectAttempts = 0

    /// Maximum reconnect attempts within a 30 s window (plan-007 §A2.7).
    private static let maxReconnectAttempts = 3
    /// Pre-emptive reconnect lead-time before the 60-min Azure cap.
    private static let preemptiveReconnectAfterSeconds: Double = 58 * 60

    public init(
        config: AzureOpenAIRealtimeConfig,
        urlSession: URLSession = .shared,
        logger: Logger = Logger(label: "macrec.transcription.azure-realtime")
    ) {
        self.config = config
        self.urlSession = urlSession
        self.logger = logger

        var continuationHandle: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        self.events = AsyncStream { continuation in
            continuationHandle = continuation
        }
        self.eventsContinuation = continuationHandle
    }

    // MARK: - StreamingTranscriptionSession

    public func ingest(_ samples: [Float]) async {
        guard !isClosed else { return }

        // Resample 16 kHz Float → 24 kHz Int16 LE for the wire.
        guard let pcm16Bytes = resampler.resample(samples) else {
            logger.error("azure-realtime: resampler failed; dropping chunk")
            await emit(.error(detail: "Azure realtime: resampler failed"))
            return
        }
        guard !pcm16Bytes.isEmpty else { return }

        // Buffer the resampled samples for replay on reconnect.
        let int16Samples = pcm16Bytes.withUnsafeBytes { rawBuf -> [Int16] in
            let bound = rawBuf.bindMemory(to: Int16.self)
            return Array(bound)
        }
        ringBuffer.append(int16Samples)

        // Send to the WS as a JSON envelope carrying base64 audio.
        let base64 = pcm16Bytes.base64EncodedString()
        let envelope = RealtimeWireTypes.InputAudioBufferAppend(audio: base64)
        await sendJSON(envelope)
    }

    public func finish() async {
        guard !isClosed else { return }
        userInitiatedClose = true
        isClosed = true
        await closeWS(code: .normalClosure, reason: nil)
        eventsContinuation.finish()
    }

    // MARK: - Public open

    /// Open the WebSocket and start the receive loop. The provider
    /// calls this immediately after constructing the session.
    public func open() async {
        do {
            try await connectAndConfigure()
        } catch {
            logger.error("azure-realtime: initial connect failed: \(error.localizedDescription)")
            await emit(.error(detail: "Azure realtime: initial connect failed: \(error.localizedDescription)"))
            eventsContinuation.finish()
            isClosed = true
        }
    }

    // MARK: - Connection lifecycle

    private func connectAndConfigure() async throws {
        guard let url = config.websocketURL() else {
            throw AzureOpenAIRealtimeError.audioFormatMismatch(reason: "Could not build WebSocket URL from endpoint")
        }
        var request = URLRequest(url: url)
        request.addValue(config.apiKey, forHTTPHeaderField: "api-key")
        let task = urlSession.webSocketTask(with: request)
        wsTask = task
        sessionStart = Date()
        task.resume()

        // Start the receive loop in a child task so the actor can
        // continue accepting `ingest(_:)` calls.
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // Start the 58-min pre-emptive reconnect timer.
        startPreemptiveReconnectTimer()
    }

    private func receiveLoop() async {
        guard let task = wsTask else { return }
        while !Task.isCancelled, !isClosed {
            do {
                let message = try await task.receive()
                await handleMessage(message)
            } catch {
                // Inspect the close state.
                let code = task.closeCode
                let codeRaw = code.rawValue
                logger.warning("azure-realtime: receive loop exited (close=\(codeRaw), error=\(error.localizedDescription))")
                await handleClose(code: code, error: error)
                return
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .data(let raw):
            data = raw
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            return
        }

        do {
            let event = try JSONDecoder().decode(RealtimeWireTypes.ServerEvent.self, from: data)
            await handleEvent(event)
        } catch {
            // Log but tolerate — protocol drift should never crash the session.
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "(non-utf8)"
            logger.warning("azure-realtime: failed to decode event: \(error.localizedDescription); preview=\(preview)")
        }
    }

    private func handleEvent(_ event: RealtimeWireTypes.ServerEvent) async {
        switch event {
        case .sessionCreated(let payload):
            logger.info("azure-realtime: session.created (id=\(payload.session?.id ?? "?"))")
            await sendSessionConfig()

        case .sessionUpdated:
            logger.debug("azure-realtime: session.updated")

        case .speechStarted(let payload):
            logger.debug("azure-realtime: speech_started item=\(payload.itemId ?? "?")")

        case .speechStopped(let payload):
            logger.debug("azure-realtime: speech_stopped item=\(payload.itemId ?? "?")")

        case .bufferCommitted(let payload):
            logger.debug("azure-realtime: input_audio_buffer.committed item=\(payload.itemId ?? "?")")

        case .transcriptionDelta(let payload):
            // Accumulate per-item; emit a `.partial` snapshot.
            let accumulated = (partialsByItem[payload.itemId] ?? "") + payload.delta
            partialsByItem[payload.itemId] = accumulated
            let utteranceId = utteranceIdFor(itemId: payload.itemId)
            metrics.partialsEmitted += 1
            await emit(.partial(utteranceId: utteranceId, text: accumulated, confidence: nil))

        case .transcriptionCompleted(let payload):
            let utteranceId = utteranceIdFor(itemId: payload.itemId)
            partialsByItem.removeValue(forKey: payload.itemId)
            metrics.finalsEmitted += 1
            let now = Date()
            let language = "" // Azure realtime does not echo language back per item; surface empty.
            await emit(.final(
                utteranceId: utteranceId,
                text: payload.transcript,
                confidence: nil,
                range: now...now,
                language: language
            ))

        case .transcriptionFailed(let payload):
            let detail = payload.error.message ?? "(no message)"
            metrics.errorCount += 1
            await emit(.error(detail: "Azure realtime: item \(payload.itemId) failed: \(detail)"))

        case .sessionError(let payload):
            let errorType = payload.error.type ?? "unknown"
            let message = payload.error.message ?? "(no message)"
            metrics.errorCount += 1
            // RT-1 model-field bug detection.
            if message.lowercased().contains("model") {
                await emit(.error(detail: "Azure realtime: model field appears in session update — RT-1 bug. \(message)"))
            } else {
                await emit(.error(detail: "Azure realtime \(errorType): \(message)"))
            }

        case .rateLimitsUpdated(let payload):
            if let limits = payload.rateLimits {
                let summary = limits.compactMap { rl -> String? in
                    guard let name = rl.name else { return nil }
                    return "\(name)=\(rl.remaining ?? -1)/\(rl.limit ?? -1)"
                }.joined(separator: " ")
                logger.debug("azure-realtime: rate_limits.updated \(summary)")
            }

        case .unknown(let typeName):
            logger.debug("azure-realtime: tolerating unknown event '\(typeName)'")
        }
    }

    /// Send the configured `transcription_session.update` payload.
    private func sendSessionConfig() async {
        let turnDetection = RealtimeWireTypes.TurnDetectionConfig(
            type: "server_vad",
            threshold: config.vadThreshold,
            prefixPaddingMS: config.vadPrefixPaddingMS,
            silenceDurationMS: config.vadSilenceMS,
            createResponse: false,
            interruptResponse: false
        )
        let noiseReduction: RealtimeWireTypes.NoiseReductionConfig? = {
            guard config.noiseReduction != "none" else { return nil }
            return RealtimeWireTypes.NoiseReductionConfig(type: config.noiseReduction)
        }()
        let include: [String]? = config.includeLogprobs
            ? ["item.input_audio_transcription.logprobs"]
            : nil
        let session = RealtimeWireTypes.SessionConfig(
            inputAudioFormat: "pcm16",
            inputAudioTranscription: RealtimeWireTypes.InputAudioTranscriptionConfig(
                language: nil,  // language hint resolved per-call via TranscriptionOptions; provider-level future hook
                prompt: nil
            ),
            turnDetection: turnDetection,
            inputAudioNoiseReduction: noiseReduction,
            include: include
        )
        let envelope = RealtimeWireTypes.TranscriptionSessionUpdate(session: session)
        await sendJSON(envelope)
    }

    // MARK: - Reconnect-with-replay (§A2.7) + 58-min pre-emptive (§A2.8)

    private func handleClose(code: URLSessionWebSocketTask.CloseCode, error: Error) async {
        // Cancel any pending pre-emptive reconnect task to avoid races.
        preemptiveReconnectTask?.cancel()
        preemptiveReconnectTask = nil

        if userInitiatedClose {
            logger.debug("azure-realtime: user-initiated close — done")
            eventsContinuation.finish()
            return
        }

        switch code {
        case .normalClosure:
            // Clean close at < 60 min: end the session. At ≥ 58 min,
            // treat as session-expired and reconnect-with-replay.
            let age = Date().timeIntervalSince(sessionStart ?? Date())
            if age >= Self.preemptiveReconnectAfterSeconds {
                logger.info("azure-realtime: 60-min cap; reconnect-with-replay")
                await attemptReconnectWithReplay(reason: "session expired")
            } else {
                logger.debug("azure-realtime: clean close at \(Int(age))s")
                eventsContinuation.finish()
                isClosed = true
            }

        case .policyViolation:
            logger.error("azure-realtime: policy violation (1008); not retrying")
            await emit(.error(detail: "Azure realtime: auth policy violation (1008); not retrying"))
            eventsContinuation.finish()
            isClosed = true

        default:
            // 1001 / 1006 / 1011 / abnormal — reconnect-with-replay.
            logger.warning("azure-realtime: abnormal close \(code.rawValue); reconnect-with-replay")
            await attemptReconnectWithReplay(reason: "close code \(code.rawValue)")
        }
    }

    private func attemptReconnectWithReplay(reason: String) async {
        reconnectAttempts += 1
        guard reconnectAttempts <= Self.maxReconnectAttempts else {
            await emit(.error(detail: "Azure realtime: reconnect failed after \(Self.maxReconnectAttempts) attempts (\(reason))"))
            eventsContinuation.finish()
            isClosed = true
            return
        }

        // Exponential backoff (0, 1, 4 s) ± 20% jitter.
        let baseDelay: Double = (reconnectAttempts == 1) ? 0.0 : pow(2.0, Double(reconnectAttempts - 1) * 2)
        let jitter = baseDelay == 0 ? 0 : Double.random(in: 0.8...1.2) * baseDelay
        if jitter > 0 {
            try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
        }

        await emit(.error(detail: "Azure realtime: reconnecting (attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts)) — \(reason)"))

        // Drain the ring buffer for replay BEFORE opening a fresh
        // session (the next `ingest(_:)` calls will refill it).
        let replay = ringBuffer.drain()

        do {
            try await connectAndConfigure()
            // Replay the buffered audio in 100 ms chunks (= 2,400
            // Int16 samples per chunk @ 24 kHz).
            let chunkSize = 2_400
            var offset = 0
            while offset < replay.count {
                let end = min(offset + chunkSize, replay.count)
                let chunk = Array(replay[offset..<end])
                let bytes = chunk.withUnsafeBytes { Data($0) }
                let envelope = RealtimeWireTypes.InputAudioBufferAppend(
                    audio: bytes.base64EncodedString()
                )
                await sendJSON(envelope)
                offset = end
            }
            // Reset retry counter after a clean reconnect.
            reconnectAttempts = 0
        } catch {
            logger.warning("azure-realtime: reconnect attempt \(reconnectAttempts) failed: \(error.localizedDescription)")
            // Recurse — `attemptReconnectWithReplay` will exit via
            // the `> maxReconnectAttempts` branch once the budget
            // is exhausted.
            await attemptReconnectWithReplay(reason: "previous attempt failed")
        }
    }

    private func startPreemptiveReconnectTimer() {
        preemptiveReconnectTask?.cancel()
        preemptiveReconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.preemptiveReconnectAfterSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.preemptiveReconnect()
        }
    }

    private func preemptiveReconnect() async {
        guard !isClosed, !userInitiatedClose else { return }
        logger.info("azure-realtime: 58-min pre-emptive reconnect")
        // Close the current WS cleanly so the receive loop exits
        // without retrying via `handleClose` immediately, then start
        // a fresh session. We piggy-back on `attemptReconnectWithReplay`
        // because it correctly drains the ring buffer and re-sends.
        await closeWS(code: .normalClosure, reason: Data("preemptive".utf8))
        await attemptReconnectWithReplay(reason: "pre-emptive 58-min reconnect")
    }

    // MARK: - Wire IO

    private func sendJSON<T: Encodable>(_ payload: T) async {
        guard let task = wsTask else { return }
        do {
            let data = try JSONEncoder().encode(payload)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await task.send(.string(text))
        } catch {
            logger.warning("azure-realtime: send failed: \(error.localizedDescription)")
        }
    }

    private func closeWS(code: URLSessionWebSocketTask.CloseCode, reason: Data?) async {
        guard let task = wsTask else { return }
        task.cancel(with: code, reason: reason)
        wsTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        preemptiveReconnectTask?.cancel()
        preemptiveReconnectTask = nil
    }

    private func emit(_ event: StreamingTranscriptionEvent) async {
        eventsContinuation.yield(event)
    }

    // MARK: - Helpers

    private func utteranceIdFor(itemId: String) -> UUID {
        if let existing = utteranceIdByItem[itemId] {
            return existing
        }
        let fresh = UUID()
        utteranceIdByItem[itemId] = fresh
        return fresh
    }
}
