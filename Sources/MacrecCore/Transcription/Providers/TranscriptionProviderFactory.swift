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

    // -- Plan-007 Phase A1 / A2 §A.6 / §A2.4 — Azure OpenAI fields --
    /// Azure resource endpoint (e.g.
    /// `https://my-resource.openai.azure.com`). Required when
    /// `providerId == "azure"` or `"azure-openai-realtime"`.
    public let azureOpenAIEndpoint: URL?
    /// Azure deployment name (NOT model name). Required for both
    /// Azure surfaces.
    public let azureOpenAIDeployment: String?
    /// Azure api-version. Optional; provider applies the documented
    /// starter (`AzureOpenAIConfig.defaultApiVersion`) when nil.
    public let azureOpenAIApiVersion: String?
    /// Per-provider expiry override (falls back to `keyExpiresAt`).
    public let azureOpenAIApiKeyExpiresAt: Date?
    /// Realtime-only — VAD threshold (0.0..1.0; default 0.5).
    public let azureOpenAIRealtimeVADThreshold: Float?
    /// Realtime-only — VAD prefix-padding ms (default 300).
    public let azureOpenAIRealtimeVADPrefixPaddingMS: Int?
    /// Realtime-only — VAD silence ms (default 200).
    public let azureOpenAIRealtimeVADSilenceMS: Int?
    /// Realtime-only — `near_field` / `far_field` / `none` (default
    /// `near_field`).
    public let azureOpenAIRealtimeNoiseReduction: String?
    /// Realtime-only — request logprobs (default false).
    public let azureOpenAIRealtimeIncludeLogprobs: Bool?
    /// Realtime-only — append `&deployment={name}` to URL (default
    /// true after 2026-05-01 field repro; OQ-A2-2's original `false`
    /// caused immediate close=1000 on most tenants).
    public let azureOpenAIRealtimeDeploymentInUrl: Bool?

    // -- Plan-007 Phase B §B.7 — ElevenLabs fields --
    public let elevenLabsModelId: String?
    public let elevenLabsLanguageCode: String?
    public let elevenLabsDiarize: Bool?
    public let elevenLabsTagAudioEvents: Bool?
    public let elevenLabsNumSpeakers: Int?
    public let elevenLabsFileFormat: String?
    public let elevenLabsEntityDetection: String?
    public let elevenLabsApiKeyExpiresAt: Date?

    public init(
        providerId: String,
        apiKey: String?,
        modelId: String?,
        languageHints: [String] = [],
        logger: Logger,
        keyExpiresAt: Date?,
        azureOpenAIEndpoint: URL? = nil,
        azureOpenAIDeployment: String? = nil,
        azureOpenAIApiVersion: String? = nil,
        azureOpenAIApiKeyExpiresAt: Date? = nil,
        azureOpenAIRealtimeVADThreshold: Float? = nil,
        azureOpenAIRealtimeVADPrefixPaddingMS: Int? = nil,
        azureOpenAIRealtimeVADSilenceMS: Int? = nil,
        azureOpenAIRealtimeNoiseReduction: String? = nil,
        azureOpenAIRealtimeIncludeLogprobs: Bool? = nil,
        azureOpenAIRealtimeDeploymentInUrl: Bool? = nil,
        elevenLabsModelId: String? = nil,
        elevenLabsLanguageCode: String? = nil,
        elevenLabsDiarize: Bool? = nil,
        elevenLabsTagAudioEvents: Bool? = nil,
        elevenLabsNumSpeakers: Int? = nil,
        elevenLabsFileFormat: String? = nil,
        elevenLabsEntityDetection: String? = nil,
        elevenLabsApiKeyExpiresAt: Date? = nil
    ) {
        self.providerId = providerId
        self.apiKey = apiKey
        self.modelId = modelId
        self.languageHints = languageHints
        self.logger = logger
        self.keyExpiresAt = keyExpiresAt
        self.azureOpenAIEndpoint = azureOpenAIEndpoint
        self.azureOpenAIDeployment = azureOpenAIDeployment
        self.azureOpenAIApiVersion = azureOpenAIApiVersion
        self.azureOpenAIApiKeyExpiresAt = azureOpenAIApiKeyExpiresAt
        self.azureOpenAIRealtimeVADThreshold = azureOpenAIRealtimeVADThreshold
        self.azureOpenAIRealtimeVADPrefixPaddingMS = azureOpenAIRealtimeVADPrefixPaddingMS
        self.azureOpenAIRealtimeVADSilenceMS = azureOpenAIRealtimeVADSilenceMS
        self.azureOpenAIRealtimeNoiseReduction = azureOpenAIRealtimeNoiseReduction
        self.azureOpenAIRealtimeIncludeLogprobs = azureOpenAIRealtimeIncludeLogprobs
        self.azureOpenAIRealtimeDeploymentInUrl = azureOpenAIRealtimeDeploymentInUrl
        self.elevenLabsModelId = elevenLabsModelId
        self.elevenLabsLanguageCode = elevenLabsLanguageCode
        self.elevenLabsDiarize = elevenLabsDiarize
        self.elevenLabsTagAudioEvents = elevenLabsTagAudioEvents
        self.elevenLabsNumSpeakers = elevenLabsNumSpeakers
        self.elevenLabsFileFormat = elevenLabsFileFormat
        self.elevenLabsEntityDetection = elevenLabsEntityDetection
        self.elevenLabsApiKeyExpiresAt = elevenLabsApiKeyExpiresAt
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
        case "soniox":
            // plan-006 Phase D / Unit D2 — Soniox cloud streaming
            // provider. Requires a non-empty API key (carried in the
            // first JSON config frame, NEVER on the URL — see
            // SonioxConfigMessage). Honours `MACREC_TRANSCRIBE_MODEL`
            // for picking a non-default real-time model id; defaults
            // to `SonioxConfigBuilder.defaultModel` (`stt-rt-v4`).
            guard let key = input.apiKey, !key.isEmpty else {
                throw MacrecError.transcriptionApiKeyMissing(provider: "soniox")
            }
            // Diagnostic: log the key fingerprint (prefix + suffix only,
            // never the full secret) so the user can verify the running
            // app is sending the same key that's in their .env file.
            // Helps diagnose stale-process / wrong-env-var issues.
            let fingerprint: String = {
                guard key.count >= 10 else { return "(short, \(key.count) chars)" }
                return "\(key.prefix(6))…\(key.suffix(4)) (\(key.count) chars)"
            }()
            input.logger.info("soniox: using API key fingerprint \(fingerprint)")
            return SonioxStreamingTranscriptionProvider(
                apiKey: key,
                model: input.modelId ?? SonioxConfigBuilder.defaultModel,
                logger: input.logger
            )
        case "azure":
            // plan-007 Phase A1 §A.6 — Azure OpenAI batch (REST)
            // provider. All four required fields enforce the
            // no-fallback rule at construction time.
            guard let key = input.apiKey, !key.isEmpty else {
                throw MacrecError.transcriptionApiKeyMissing(provider: "azure")
            }
            guard let endpoint = input.azureOpenAIEndpoint else {
                throw MacrecError.transcriptionConfigConflict(
                    reason: "Azure provider requires AZURE_OPENAI_ENDPOINT (e.g. https://my-resource.openai.azure.com)"
                )
            }
            guard let deployment = input.azureOpenAIDeployment, !deployment.isEmpty else {
                throw MacrecError.transcriptionConfigConflict(
                    reason: "Azure provider requires AZURE_OPENAI_DEPLOYMENT (the deployment name backing gpt-4o-mini-transcribe)"
                )
            }
            let apiVersion = input.azureOpenAIApiVersion ?? AzureOpenAIConfig.defaultApiVersion
            input.logger.info("azure: building provider for deployment '\(deployment)' on \(endpoint.host ?? "?") (api-version=\(apiVersion))")
            let config = try AzureOpenAIConfig(
                endpoint: endpoint,
                deployment: deployment,
                apiVersion: apiVersion,
                apiKey: key,
                apiKeyExpiresAt: input.azureOpenAIApiKeyExpiresAt ?? input.keyExpiresAt
            )
            return AzureOpenAITranscriptionProvider(
                config: config,
                logger: input.logger
            )
        case "azure-openai-realtime":
            // plan-007 Phase A2 §A2 — Azure OpenAI realtime WebSocket
            // (`intent=transcription`). Same auth + endpoint + deployment
            // surface as the batch path; adds VAD / noise-reduction
            // tuning knobs from §A2.4.
            guard let key = input.apiKey, !key.isEmpty else {
                throw MacrecError.transcriptionApiKeyMissing(provider: "azure-openai-realtime")
            }
            guard let endpoint = input.azureOpenAIEndpoint else {
                throw MacrecError.transcriptionConfigConflict(
                    reason: "Azure realtime provider requires AZURE_OPENAI_ENDPOINT (e.g. https://my-resource.openai.azure.com)"
                )
            }
            guard let deployment = input.azureOpenAIDeployment, !deployment.isEmpty else {
                throw MacrecError.transcriptionConfigConflict(
                    reason: "Azure realtime provider requires AZURE_OPENAI_DEPLOYMENT (the deployment name backing gpt-4o-mini-transcribe)"
                )
            }
            let apiVersion = input.azureOpenAIApiVersion ?? AzureOpenAIConfig.defaultApiVersion
            input.logger.info("azure-openai-realtime: building provider for deployment '\(deployment)' on \(endpoint.host ?? "?") (api-version=\(apiVersion))")
            let realtimeConfig = try AzureOpenAIRealtimeConfig(
                endpoint: endpoint,
                deployment: deployment,
                apiVersion: apiVersion,
                apiKey: key,
                apiKeyExpiresAt: input.azureOpenAIApiKeyExpiresAt ?? input.keyExpiresAt,
                vadThreshold: input.azureOpenAIRealtimeVADThreshold,
                vadPrefixPaddingMS: input.azureOpenAIRealtimeVADPrefixPaddingMS,
                vadSilenceMS: input.azureOpenAIRealtimeVADSilenceMS,
                noiseReduction: input.azureOpenAIRealtimeNoiseReduction,
                includeLogprobs: input.azureOpenAIRealtimeIncludeLogprobs,
                deploymentInUrl: input.azureOpenAIRealtimeDeploymentInUrl
            )
            return AzureOpenAIRealtimeTranscriptionProvider(
                config: realtimeConfig,
                logger: input.logger
            )
        case "elevenlabs":
            // plan-007 Phase B §B.6 — ElevenLabs Scribe v2 batch.
            guard let key = input.apiKey, !key.isEmpty else {
                throw MacrecError.transcriptionApiKeyMissing(provider: "elevenlabs")
            }
            input.logger.info("elevenlabs: building provider for model '\(input.elevenLabsModelId ?? ElevenLabsConfig.defaultModelId)'")
            let elConfig = try ElevenLabsConfig(
                apiKey: key,
                modelId: input.elevenLabsModelId ?? ElevenLabsConfig.defaultModelId,
                languageCode: input.elevenLabsLanguageCode,
                diarize: input.elevenLabsDiarize ?? false,
                tagAudioEvents: input.elevenLabsTagAudioEvents ?? true,
                numSpeakers: input.elevenLabsNumSpeakers,
                fileFormat: input.elevenLabsFileFormat ?? "pcm_s16le_16",
                entityDetection: input.elevenLabsEntityDetection,
                apiKeyExpiresAt: input.elevenLabsApiKeyExpiresAt ?? input.keyExpiresAt
            )
            return ElevenLabsTranscriptionProvider(
                config: elConfig,
                logger: input.logger
            )
        default:
            // TODO(plan-004 Phase G): use .transcriptionInvalidConfigValue(field:value:)
            throw MacrecError.transcriptionConfigConflict(reason: "transcribe value '\(normalized)' invalid (allowed: 'none', 'apple', 'gemini', 'whisperkit', 'soniox', 'azure', 'azure-openai-realtime', 'elevenlabs')")
        }
    }
}
