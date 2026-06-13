// Sources/NtakkerCore/Transcription/Live/Soniox/SonioxStreamingTranscriptionProvider.swift
//
// Plan-006 Phase D / Unit D2: the public `TranscriptionProvider`
// conformer that the `TranscriptionProviderFactory` returns when the
// user selects `NTAKKER_TRANSCRIBE=soniox`.
//
// The provider itself is stateless beyond the immutable configuration
// captured at init time (api key, endpoint, model id, language hints
// resolution). Each call to `openStreamingSession(...)` constructs a
// fresh `SonioxStreamingSession` with its own transport instance —
// per the design contract that one Soniox session = one WebSocket
// connection per source per recording.

import Foundation
import Logging

public actor SonioxStreamingTranscriptionProvider: TranscriptionProvider {

    // MARK: - TranscriptionProvider conformance

    public nonisolated let id: String = "soniox"
    public nonisolated let displayName: String = "Soniox (cloud, multilingual)"
    public nonisolated let supportedModes: Set<TranscriptionMode> = [.streaming]

    // MARK: - Defaults

    /// Default real-time WebSocket endpoint per design §SX-5.3 and the
    /// wire schema research note (`docs/research/soniox-wire-schema.md`).
    public nonisolated static let defaultEndpoint: URL = URL(
        string: "wss://stt-rt.soniox.com/transcribe-websocket"
    )!

    // MARK: - Stored properties

    private let apiKey: String
    private let endpoint: URL
    private let model: String
    private let diarize: Bool
    private let logger: Logger?
    private let transportFactory: @Sendable () -> any WebSocketTransport

    // MARK: - Init

    /// - Parameters:
    ///   - apiKey: Soniox long-lived or temporary API key. Required;
    ///     the factory pre-validates non-empty and throws
    ///     `NtakkerError.transcriptionApiKeyMissing(provider: "soniox")`
    ///     before constructing this provider.
    ///   - endpoint: Override the default WebSocket endpoint (tests).
    ///   - model: Soniox model id. Defaults to
    ///     `SonioxConfigBuilder.defaultModel` (`stt-rt-v4`).
    ///   - logger: Optional `swift-log` logger forwarded to the session.
    ///   - transportFactory: Override for tests — return a
    ///     `MockWebSocketTransport` to script connection behavior. The
    ///     production default returns a fresh
    ///     `URLSessionWebSocketTaskTransport` for every session.
    public init(
        apiKey: String,
        endpoint: URL = SonioxStreamingTranscriptionProvider.defaultEndpoint,
        model: String = SonioxConfigBuilder.defaultModel,
        diarize: Bool = SonioxConfigBuilder.defaultDiarize,
        logger: Logger? = nil,
        transportFactory: (@Sendable () -> any WebSocketTransport)? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.diarize = diarize
        self.logger = logger
        self.transportFactory = transportFactory ?? {
            URLSessionWebSocketTaskTransport()
        }
    }

    // MARK: - TranscriptionProvider methods

    /// Soniox is streaming-only. Mirrors Apple Speech's posture: the
    /// batch surface is unsupported — callers must use
    /// `openStreamingSession(...)`.
    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        throw NtakkerError.transcriptionConfigConflict(
            reason: "Soniox is a streaming-only provider; use openStreamingSession(source:options:) instead of transcribe(samples:source:options:)."
        )
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        // Resolve language hints — empty list collapses to the project's
        // documented default (Greek + English, FR-SX-9).
        let mappedHints = options.languageHints.isEmpty
            ? SonioxLanguageHintMapper.defaultHints
            : SonioxLanguageHintMapper.map(options.languageHints)

        let resolvedModel = options.modelId ?? model

        let configMessage = SonioxConfigBuilder.build(
            apiKey: apiKey,
            model: resolvedModel,
            languageHints: mappedHints,
            diarize: diarize,
            clientReferenceId: "ntakker-cli-\(source.rawValue)"
        )

        let transport = transportFactory()
        let session = SonioxStreamingSession(
            transport: transport,
            endpoint: endpoint,
            configMessage: configMessage,
            logger: logger,
            // F9 (EVAL 2026-06-12): hand the session the factory so it
            // can reconnect-with-replay after a mid-session transport
            // drop instead of going dead for the rest of the recording.
            transportFactory: transportFactory
        )

        try await session.start()
        return session
    }

    /// Test-only accessor. Used by Phase A3 plumbing tests.
    internal func currentDiarize() -> Bool { diarize }
}
