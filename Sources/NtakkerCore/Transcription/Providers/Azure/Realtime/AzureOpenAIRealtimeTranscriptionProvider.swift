// Sources/NtakkerCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeTranscriptionProvider.swift —
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

    /// Documented default Azure transcription model. Used when
    /// `TranscriptionOptions.modelId` (i.e. `NTAKKER_TRANSCRIBE_MODEL`)
    /// is unset. Field-confirmed compatible with `intent=transcription`
    /// 2026-05-01.
    public static let defaultTranscriptionModel = "gpt-4o-mini-transcribe"

    /// Allowed `input_audio_transcription.model` values per Azure docs.
    /// Used only for an info-level mismatch warning — the value is
    /// passed through to Azure regardless so newer models work without
    /// a code change.
    public static let knownTranscriptionModels: Set<String> = [
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe",
        "whisper-1",
    ]

    private let config: AzureOpenAIRealtimeConfig
    private let urlSession: URLSession
    private let logger: Logger

    public init(
        config: AzureOpenAIRealtimeConfig,
        urlSession: URLSession = .shared,
        logger: Logger = Logger(label: "ntakker-cli.transcription.azure-realtime")
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
        throw NtakkerError.transcriptionConfigConflict(
            reason: "Azure realtime provider does not support batch mode; use --transcribe azure for the batch REST variant"
        )
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        // Plan-007 follow-up (2026-04-30): translate the project's
        // `[String]` language-hint array (e.g. "en,el") into Azure's
        // single-string `language` + free-form `prompt` shape using
        // the shared resolver. This is what unlocks bilingual
        // transcription on `gpt-4o-mini-transcribe` via the prompt
        // workaround documented in the OpenAI speech-to-text guide.
        let resolved = AzureLanguageHints.resolve(
            hints: options.languageHints,
            customInstruction: options.customSystemInstruction
        )
        // Resolve the transcription model (field-required 2026-05-01).
        // Precedence: explicit `NTAKKER_TRANSCRIBE_MODEL` > documented
        // default. We log at warning if the value is not in the known
        // set, but we still pass it through — Azure may add new
        // transcription models the constant list has not been updated
        // for yet.
        let trimmedExplicit = options.modelId?.trimmingCharacters(in: .whitespaces)
        let resolvedModel: String
        if let trimmedExplicit, !trimmedExplicit.isEmpty {
            resolvedModel = trimmedExplicit
        } else {
            resolvedModel = Self.defaultTranscriptionModel
        }
        if !Self.knownTranscriptionModels.contains(resolvedModel) {
            logger.warning("azure-openai-realtime: NTAKKER_TRANSCRIBE_MODEL='\(resolvedModel)' is not in the known set \(Self.knownTranscriptionModels); passing through as-is.")
        }
        let session = AzureOpenAIRealtimeSession(
            config: config,
            transcriptionModel: resolvedModel,
            languageHint: resolved.language,
            promptHint: resolved.prompt,
            urlSession: urlSession,
            logger: logger
        )
        await session.open()
        return session
    }
}
