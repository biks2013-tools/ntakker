// Sources/MacrecCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeTranscriptionProvider.swift —
// plan-007 Phase A2 §A2.2.
//
// `TranscriptionProvider` conformer that vends `AzureOpenAIRealtimeSession`
// instances. Streaming-only (`supportedModes = [.streaming]`); the
// batch surface (`transcribe(samples:source:options:)`) throws a
// configuration-conflict so that `transcribe --transcribe azure-openai-realtime`
// never silently degrades to a chunk-and-batch loop.

import Foundation
import Logging

public final class AzureOpenAIRealtimeTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {

    public let id = "azure-openai-realtime"
    public let displayName = "Azure OpenAI Realtime"
    public let supportedModes: Set<TranscriptionMode> = [.streaming]

    private let config: AzureOpenAIRealtimeConfig
    private let urlSession: URLSession
    private let logger: Logger

    public init(
        config: AzureOpenAIRealtimeConfig,
        urlSession: URLSession = .shared,
        logger: Logger = Logger(label: "macrec.transcription.azure-realtime")
    ) {
        self.config = config
        self.urlSession = urlSession
        self.logger = logger
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        throw MacrecError.transcriptionConfigConflict(
            reason: "Azure realtime provider does not support batch mode; use --transcribe azure for the batch REST variant"
        )
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        let session = AzureOpenAIRealtimeSession(
            config: config,
            urlSession: urlSession,
            logger: logger
        )
        await session.open()
        return session
    }
}
