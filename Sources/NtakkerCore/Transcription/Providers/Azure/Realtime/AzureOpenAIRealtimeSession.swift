// Sources/NtakkerCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift —
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

    /// Plan-007 follow-up (2026-04-30): per-call language steering
    /// resolved by `AzureLanguageHints.resolve(...)` at session
    /// construction. Re-applied on every reconnect so language
    /// guidance survives a 1006 close. Captured at init from
    /// `TranscriptionOptions` passed to
    /// `AzureOpenAIRealtimeTranscriptionProvider.openStreamingSession(...)`.
    private let languageHint: String?
    private let promptHint: String?

    /// Transcription model id sent in
    /// `session.input_audio_transcription.model`. REQUIRED on
    /// Azure's transcription intent (field repro 2026-05-01).
    /// Resolved by the provider from `TranscriptionOptions.modelId`
    /// (i.e. `NTAKKER_TRANSCRIBE_MODEL`) or the documented default
    /// (`gpt-4o-mini-transcribe`).
    private let transcriptionModel: String

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
    /// F10 (EVAL 2026-06-12): true only after `session.created` arrived
    /// AND the `transcription_session.update` config envelope was sent
    /// on the current socket. Audio is NEVER sent before this — chunks
    /// land in the ring buffer and are flushed in order right after the
    /// config goes out, so Azure never receives audio for a session
    /// with no transcription model configured.
    private var isConfigured = false
    /// F11 (EVAL 2026-06-12): single-flight latch so the 58-min
    /// pre-emptive reconnect and a racing close-triggered reconnect
    /// can never interleave two reconnect sequences (double replay,
    /// double-counted attempts, leaked WS task).
    private var isReconnecting = false
    /// F10: audio drained from the ring at reconnect time, held until
    /// the NEW session is configured, then flushed (in order, ahead of
    /// any audio that arrived during the reconnect window).
    private var pendingReplay: [Int16] = []
    /// True once Azure's `session.created` server event has arrived.
    /// Used by `handleClose` to distinguish a handshake/upgrade failure
    /// (which Foundation reports as `closeCode == .normalClosure` with
    /// `error == "Socket is not connected"` — see field-repro
    /// 2026-05-01) from a clean session end mid-recording. Reset to
    /// `false` on every fresh `connectAndConfigure(...)` so reconnect
    /// attempts get a clean slate.
    private var didCompleteHandshake = false

    /// Maximum reconnect attempts within a 30 s window (plan-007 §A2.7).
    private static let maxReconnectAttempts = 3
    /// Pre-emptive reconnect lead-time before the 60-min Azure cap.
    private static let preemptiveReconnectAfterSeconds: Double = 58 * 60

    public init(
        config: AzureOpenAIRealtimeConfig,
        transcriptionModel: String,
        languageHint: String? = nil,
        promptHint: String? = nil,
        urlSession: URLSession = .shared,
        logger: Logger = Logger(label: "ntakker-cli.transcription.azure-realtime")
    ) {
        self.config = config
        self.transcriptionModel = transcriptionModel
        self.languageHint = languageHint
        self.promptHint = promptHint
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

        // F10: never send audio before the current session is
        // configured — the chunk stays in the ring and is flushed (in
        // order) right after the config envelope goes out.
        guard isConfigured else { return }

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
        // Surface the WS URL at INFO so the log makes it obvious which
        // shape (with / without `&deployment=`) is being attempted —
        // critical for diagnosing connection-vs-handshake failures
        // (added 2026-05-01 after the `transcription_session.created`
        // discriminator-routing repro).
        logger.info("azure-realtime: opening WS to \(url.absoluteString) (deploymentInUrl=\(config.deploymentInUrl))")
        var request = URLRequest(url: url)
        request.addValue(config.apiKey, forHTTPHeaderField: "api-key")
        let task = urlSession.webSocketTask(with: request)
        wsTask = task
        sessionStart = Date()
        didCompleteHandshake = false
        // F10: the fresh socket has no transcription model configured
        // yet — block audio sends until `session.created` + config.
        isConfigured = false
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
            didCompleteHandshake = true
            await sendSessionConfig()
            // F10: the config envelope is now on the wire AHEAD of any
            // audio (same-socket ordering), so audio may flow. Flush
            // the audio that accumulated while unconfigured: first the
            // pre-drop replay stash, then whatever landed in the ring
            // during the handshake/reconnect window.
            isConfigured = true
            // A completed handshake is the real "success" marker for
            // the reconnect budget (plan-007 §A2.7 30 s window decay).
            reconnectAttempts = 0
            let toFlush = pendingReplay + ringBuffer.drain()
            pendingReplay = []
            if !toFlush.isEmpty {
                await sendAudioChunks(toFlush)
            }

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
            await emit(.partial(utteranceId: utteranceId, text: accumulated, confidence: nil, speaker: nil))

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
                language: language,
                speaker: nil
            ))

        case .transcriptionFailed(let payload):
            let detail = payload.error.message ?? "(no message)"
            metrics.errorCount += 1
            await emit(.error(detail: "Azure realtime: item \(payload.itemId) failed: \(detail)"))

        case .sessionError(let payload):
            let errorType = payload.error.type ?? "unknown"
            let message = payload.error.message ?? "(no message)"
            metrics.errorCount += 1
            // 2026-05-01 field repro retired the RT-1 detection: Azure
            // transcription REQUIRES `input_audio_transcription.model`,
            // so a "Missing required parameter: …model" surface used
            // to be mis-labelled as the (now-debunked) RT-1 bug.
            // Surface the raw Azure error verbatim instead — the
            // message itself is precise and actionable.
            await emit(.error(detail: "Azure realtime \(errorType): \(message)"))

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
        // `create_response` / `interrupt_response` intentionally OMITTED
        // — Azure transcription returns invalid_request_error if either
        // appears under `transcription_session.update` (field repro
        // 2026-05-01). See note in RealtimeWireTypes.TurnDetectionConfig.
        let turnDetection = RealtimeWireTypes.TurnDetectionConfig(
            type: "server_vad",
            threshold: config.vadThreshold,
            prefixPaddingMS: config.vadPrefixPaddingMS,
            silenceDurationMS: config.vadSilenceMS
        )
        let noiseReduction: RealtimeWireTypes.NoiseReductionConfig? = {
            guard config.noiseReduction != "none" else { return nil }
            return RealtimeWireTypes.NoiseReductionConfig(type: config.noiseReduction)
        }()
        let include: [String]? = config.includeLogprobs
            ? ["item.input_audio_transcription.logprobs"]
            : nil
        // Language steering wired through from
        // `AzureOpenAIRealtimeTranscriptionProvider.openStreamingSession(...)`
        // → init. `AzureLanguageHints.resolve(...)` already collapsed
        // the user's hint array (e.g. "en,el") into a single
        // ISO-639-1 code OR a free-form prompt nudge per the
        // OpenAI guide's recommended workaround.
        let session = RealtimeWireTypes.SessionConfig(
            inputAudioFormat: "pcm16",
            inputAudioTranscription: RealtimeWireTypes.InputAudioTranscriptionConfig(
                model: transcriptionModel,
                language: languageHint,
                prompt: promptHint
            ),
            turnDetection: turnDetection,
            inputAudioNoiseReduction: noiseReduction,
            include: include
        )
        logger.info("azure-realtime: setting transcription model='\(transcriptionModel)'")
        if let promptHint, !promptHint.isEmpty {
            logger.info("azure-realtime: sending language prompt hint (\(promptHint.count) chars)")
        }
        if let languageHint {
            logger.info("azure-realtime: pinning language='\(languageHint)'")
        }
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
            // Foundation's `URLSessionWebSocketTask.closeCode` defaults
            // to `.normalClosure` (1000) when the upgrade handshake
            // failed before any close frame ever arrived (field repro
            // 2026-05-01: Azure 4xx during upgrade surfaces as
            // close=1000 + error="Socket is not connected"). Detect
            // that by checking whether `session.created` was ever
            // received — if not, this is a connection failure and we
            // MUST surface it to the user instead of silently finishing
            // the events stream.
            if !didCompleteHandshake {
                // F11: when this socket was opened BY a reconnect cycle
                // (attempt counter is live), a handshake failure is a
                // failed attempt — feed it back into the retry budget
                // instead of terminating the session on the first try.
                if reconnectAttempts > 0 && reconnectAttempts <= Self.maxReconnectAttempts {
                    logger.warning("azure-realtime: handshake failed during reconnect attempt \(reconnectAttempts) — retrying")
                    await attemptReconnectWithReplay(reason: "handshake failed during reconnect")
                    return
                }
                let detail = error.localizedDescription
                logger.error("azure-realtime: handshake failed before session.created — \(detail)")
                metrics.errorCount += 1
                await emit(.error(detail: "Azure realtime: connection failed before handshake completed — \(detail). Common causes: wrong endpoint, missing &deployment= on URL (toggle 'Append &deployment= to URL' in Settings → Azure OpenAI Realtime), wrong api-version, expired API key."))
                eventsContinuation.finish()
                isClosed = true
                return
            }
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
        // F11: single-flight latch. The 58-min pre-emptive reconnect
        // and a racing close-triggered reconnect (the cancelled receive
        // loop's in-flight `task.receive()` can throw before the cancel
        // lands) must never run two reconnect sequences concurrently —
        // that double-drained the ring, double-counted attempts, and
        // leaked the first of two WS tasks.
        guard !isReconnecting else {
            logger.debug("azure-realtime: reconnect already in progress — ignoring (\(reason))")
            return
        }
        isReconnecting = true
        defer { isReconnecting = false }

        // F10: stash the pre-drop audio. It is NOT sent here — the
        // `session.created` handler flushes it right after the config
        // envelope, so Azure never sees audio on an unconfigured
        // session (the replayed 5 s used to be exactly the audio most
        // likely to be rejected).
        if pendingReplay.isEmpty {
            pendingReplay = ringBuffer.drain()
        }

        var attemptReason = reason
        while true {
            reconnectAttempts += 1
            guard reconnectAttempts <= Self.maxReconnectAttempts else {
                await emit(.error(detail: "Azure realtime: reconnect failed after \(Self.maxReconnectAttempts) attempts (\(attemptReason))"))
                eventsContinuation.finish()
                isClosed = true
                return
            }

            // F12: documented backoff schedule 0 / 1 / 4 s ± 20% jitter
            // (the old pow(2, (n-1)*2) formula produced 0 / 4 / 16 s).
            let schedule: [Double] = [0, 1, 4]
            let baseDelay = schedule[min(reconnectAttempts - 1, schedule.count - 1)]
            let jitter = baseDelay == 0 ? 0 : Double.random(in: 0.8...1.2) * baseDelay
            if jitter > 0 {
                try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
            }

            await emit(.error(detail: "Azure realtime: reconnecting (attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts)) — \(attemptReason)"))

            do {
                try await connectAndConfigure()
                // Connection opened; the receive loop + the
                // `session.created` handler now own configuration,
                // attempt-counter reset, and the replay flush.
                return
            } catch {
                logger.warning("azure-realtime: reconnect attempt \(reconnectAttempts) failed: \(error.localizedDescription)")
                attemptReason = "previous attempt failed"
            }
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

    /// F10: send a block of 24 kHz Int16 samples as base64
    /// `input_audio_buffer.append` envelopes in 100 ms chunks (2,400
    /// samples each). Used for the post-configure replay flush.
    private func sendAudioChunks(_ samples: [Int16]) async {
        let chunkSize = 2_400
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            let chunk = Array(samples[offset..<end])
            let bytes = chunk.withUnsafeBytes { Data($0) }
            let envelope = RealtimeWireTypes.InputAudioBufferAppend(
                audio: bytes.base64EncodedString()
            )
            await sendJSON(envelope)
            offset = end
        }
    }

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
