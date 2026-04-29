// Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift
import Foundation
import Logging

public struct TranscriptionProviderFactoryInput: Sendable {
    public let providerId: String
    public let apiKey: String?
    public let modelId: String?
    public let languageHints: [String]
    public let logger: Logger
    public let keyExpiresAt: Date?

    public init(
        providerId: String,
        apiKey: String?,
        modelId: String?,
        languageHints: [String] = [],
        logger: Logger,
        keyExpiresAt: Date?
    ) {
        self.providerId = providerId
        self.apiKey = apiKey
        self.modelId = modelId
        self.languageHints = languageHints
        self.logger = logger
        self.keyExpiresAt = keyExpiresAt
    }
}

public enum TranscriptionProviderFactory {
    /// Build a concrete `TranscriptionProvider` from resolved options.
    /// Honours the `gemini-live` deprecation alias for one release.
    public static func build(_ input: TranscriptionProviderFactoryInput)
        throws -> any TranscriptionProvider
    {
        let normalized: String = {
            switch input.providerId {
            case "gemini-live":
                input.logger.notice("MACREC_TRANSCRIBE=gemini-live is deprecated; use 'gemini'. Resolving to 'gemini'.")
                return "gemini"
            default:
                return input.providerId
            }
        }()

        switch normalized {
        case "none", "":
            return NoOpTranscriptionProvider()
        case "gemini":
            guard let key = input.apiKey, !key.isEmpty else {
                throw MacrecError.transcriptionApiKeyMissing(provider: "gemini")
            }
            let model = input.modelId ?? GeminiRESTTranscriptionProvider.defaultModelId
            if !GeminiRESTTranscriptionProvider.allowedModelIds.contains(model) {
                input.logger.warning("MACREC_TRANSCRIBE_MODEL='\(model)' is not in the allowed list; sending it through as-is. If you see HTTP 4xx errors, fall back to '\(GeminiRESTTranscriptionProvider.knownGoodFallback)'.")
            }
            return GeminiRESTTranscriptionProvider(
                apiKey: key,
                modelId: model,
                urlSession: .shared,
                logger: input.logger
            )
        case "apple":
            // plan-005 Phase G — Apple's on-device SpeechAnalyzer streaming
            // provider. The deployment target is `.v26`, so the
            // `#available` is technically redundant, but the plan uses
            // explicit gating as convention so the symbol-availability
            // contract is visible at every call site.
            if #available(macOS 26.0, *) {
                return AppleSpeechTranscriptionProvider(logger: input.logger)
            } else {
                throw MacrecError.transcriptionConfigConflict(
                    reason: "Apple Speech requires macOS 26+; this build is running on an older OS")
            }
        case "whisperkit":
            // On-device, multilingual fallback for locales whose Apple
            // Speech asset is not downloadable (e.g. el-GR confirmed
            // unavailable on the user's Mac, 2026-04-29). No API key
            // required. Honours `MACREC_TRANSCRIBE_MODEL` for picking
            // a non-default model (e.g. a smaller `tiny` / `base` /
            // `small` variant for lower-RAM machines). Bare model
            // value passes through unchanged — the WhisperKit loader
            // resolves the canonical HuggingFace model id.
            let model = input.modelId ?? WhisperKitTranscriptionProvider.defaultModelName
            return WhisperKitTranscriptionProvider(
                modelName: model,
                logger: input.logger
            )
        default:
            // TODO(plan-004 Phase G): use .transcriptionInvalidConfigValue(field:value:)
            throw MacrecError.transcriptionConfigConflict(reason: "transcribe value '\(normalized)' invalid (allowed: 'none', 'apple', 'gemini', 'whisperkit')")
        }
    }
}
