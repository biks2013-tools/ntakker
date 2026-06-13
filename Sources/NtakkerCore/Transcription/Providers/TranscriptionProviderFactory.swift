// Sources/NtakkerCore/Transcription/Providers/TranscriptionProviderFactory.swift
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
    public let elevenLabsKeyterms: [String]?
    public let elevenLabsApiKeyExpiresAt: Date?

    // -- Soniox (cloud) fields (plan-012 Phase A5) --
    /// Optional Soniox speaker-diarization toggle. `nil` →
    /// `SonioxConfigBuilder.defaultDiarize` (true). `false` reverts to
    /// the pre-plan-012 single-speaker transcript form.
    public let sonioxDiarize: Bool?

    // -- WhisperKit (on-device) fields (added 2026-05-02) --
    /// WhisperKit-only model id override. Takes precedence over the
    /// shared `modelId` for the WhisperKit dispatch arm only. `nil` →
    /// provider default.
    public let whisperKitModel: String?
    /// Whisper bare ISO-639-1 language code. `nil` → auto-detect.
    public let whisperKitLanguage: String?
    /// `transcribe` (default) or `translate`. `nil` → `transcribe`.
    public let whisperKitTask: String?
    /// Decoding temperature `0.0...1.0`. `nil` → 0.
    public let whisperKitTemperature: Float?
    /// Word-level timestamps toggle. `nil` → false.
    public let whisperKitWordTimestamps: Bool?

    // -- Parakeet (on-device, multilingual) fields (plan-012 Phase B3) --
    /// Parakeet-only model id override. Wins over the shared `modelId`.
    /// `nil` → provider default (`parakeet-tdt-0.6b-v3`).
    public let parakeetModel: String?
    /// Optional language hint (bare ISO-639-1, e.g. `el`). Informational
    /// only — FluidAudio v0.8.x has no per-call language hint API; the
    /// multilingual TDT V3 model auto-detects.
    public let parakeetLanguage: String?

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
        elevenLabsKeyterms: [String]? = nil,
        elevenLabsApiKeyExpiresAt: Date? = nil,
        sonioxDiarize: Bool? = nil,
        whisperKitModel: String? = nil,
        whisperKitLanguage: String? = nil,
        whisperKitTask: String? = nil,
        whisperKitTemperature: Float? = nil,
        whisperKitWordTimestamps: Bool? = nil,
        parakeetModel: String? = nil,
        parakeetLanguage: String? = nil
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
        self.elevenLabsKeyterms = elevenLabsKeyterms
        self.elevenLabsApiKeyExpiresAt = elevenLabsApiKeyExpiresAt
        self.sonioxDiarize = sonioxDiarize
        self.whisperKitModel = whisperKitModel
        self.whisperKitLanguage = whisperKitLanguage
        self.whisperKitTask = whisperKitTask
        self.whisperKitTemperature = whisperKitTemperature
        self.whisperKitWordTimestamps = whisperKitWordTimestamps
        self.parakeetModel = parakeetModel
        self.parakeetLanguage = parakeetLanguage
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
                input.logger.notice("NTAKKER_TRANSCRIBE=gemini-live is deprecated; use 'gemini'. Resolving to 'gemini'.")
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
                throw NtakkerError.transcriptionApiKeyMissing(provider: "gemini")
            }
            let model = input.modelId ?? GeminiRESTTranscriptionProvider.defaultModelId
            if !GeminiRESTTranscriptionProvider.allowedModelIds.contains(model) {
                input.logger.warning("NTAKKER_TRANSCRIBE_MODEL='\(model)' is not in the allowed list; sending it through as-is. If you see HTTP 4xx errors, fall back to '\(GeminiRESTTranscriptionProvider.knownGoodFallback)'.")
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
                throw NtakkerError.transcriptionConfigConflict(
                    reason: "Apple Speech requires macOS 26+; this build is running on an older OS")
            }
        case "apple-cloud":
            // 2026-05-01 — Apple's CLOUD Speech-to-Text path via
            // `SFSpeechRecognizer` with `requiresOnDeviceRecognition =
            // false`. Available on macOS 14+, supports Greek (`el-GR`)
            // and ~57 other locales the on-device SpeechAnalyzer
            // doesn't ship assets for. Audio leaves the device — see
            // `docs/reference/apple-cloud-stt-investigation-2026-05.md`.
            // Per-task audio cap ~60s (we rotate at 55s); device-wide
            // 1000 req/hr quota.
            return AppleCloudTranscriptionProvider(logger: input.logger)
        case "whisperkit":
            // On-device, multilingual fallback for locales whose Apple
            // Speech asset is not downloadable (e.g. el-GR confirmed
            // unavailable on the user's Mac, 2026-04-29). No API key
            // required.
            //
            // Model resolution precedence (added 2026-05-02):
            //   1. WhisperKit-specific override `whisperKitModel`
            //      (`NTAKKER_WHISPERKIT_MODEL`).
            //   2. Shared `modelId` (`NTAKKER_TRANSCRIBE_MODEL`).
            //   3. Provider default (`large-v3-v20240930_626MB`).
            //
            // The four other tunables (`language`, `task`, `temperature`,
            // `wordTimestamps`) are forwarded as-is — the provider
            // applies its own defaults when each is `nil`.
            let model = input.whisperKitModel
                ?? input.modelId
                ?? WhisperKitTranscriptionProvider.defaultModelName
            return WhisperKitTranscriptionProvider(
                modelName: model,
                language: input.whisperKitLanguage,
                task: input.whisperKitTask,
                temperature: input.whisperKitTemperature,
                wordTimestamps: input.whisperKitWordTimestamps,
                logger: input.logger
            )
        case "parakeet":
            // plan-012 Phase B — On-device multilingual ASR via
            // FluidAudio's Parakeet TDT V3 wrapper. No API key.
            // Model-resolution precedence mirrors WhisperKit:
            //   1. Parakeet-specific override `parakeetModel`
            //      (`NTAKKER_PARAKEET_MODEL` / `--parakeet-model`).
            //   2. Shared `modelId` (`NTAKKER_TRANSCRIBE_MODEL`).
            //   3. Provider default (`parakeet-tdt-0.6b-v3`,
            //      multilingual, ~25 European languages incl. Greek).
            //
            // Language hint is informational only — see provider doc.
            let parakeetModel = input.parakeetModel
                ?? input.modelId
                ?? ParakeetTranscriptionProvider.defaultModelName
            return ParakeetTranscriptionProvider(
                modelName: parakeetModel,
                language: input.parakeetLanguage,
                logger: input.logger
            )
        case "soniox":
            // plan-006 Phase D / Unit D2 — Soniox cloud streaming
            // provider. Requires a non-empty API key (carried in the
            // first JSON config frame, NEVER on the URL — see
            // SonioxConfigMessage). Honours `NTAKKER_TRANSCRIBE_MODEL`
            // for picking a non-default real-time model id; defaults
            // to `SonioxConfigBuilder.defaultModel` (`stt-rt-v4`).
            guard let key = input.apiKey, !key.isEmpty else {
                throw NtakkerError.transcriptionApiKeyMissing(provider: "soniox")
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
            // plan-012 Phase A5: forward the optional diarization toggle
            // (default true via `SonioxConfigBuilder.defaultDiarize`) so
            // the user can revert to single-speaker output via
            // `NTAKKER_SONIOX_DIARIZE=false` / `--soniox-diarize false`.
            return SonioxStreamingTranscriptionProvider(
                apiKey: key,
                model: input.modelId ?? SonioxConfigBuilder.defaultModel,
                diarize: input.sonioxDiarize ?? SonioxConfigBuilder.defaultDiarize,
                logger: input.logger
            )
        case "azure":
            // plan-007 Phase A1 §A.6 — Azure OpenAI batch (REST)
            // provider. All four required fields enforce the
            // no-fallback rule at construction time.
            guard let key = input.apiKey, !key.isEmpty else {
                throw NtakkerError.transcriptionApiKeyMissing(provider: "azure")
            }
            guard let endpoint = input.azureOpenAIEndpoint else {
                throw NtakkerError.transcriptionConfigConflict(
                    reason: "Azure provider requires AZURE_OPENAI_ENDPOINT (e.g. https://my-resource.openai.azure.com)"
                )
            }
            guard let deployment = input.azureOpenAIDeployment, !deployment.isEmpty else {
                throw NtakkerError.transcriptionConfigConflict(
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
                throw NtakkerError.transcriptionApiKeyMissing(provider: "azure-openai-realtime")
            }
            guard let endpoint = input.azureOpenAIEndpoint else {
                throw NtakkerError.transcriptionConfigConflict(
                    reason: "Azure realtime provider requires AZURE_OPENAI_ENDPOINT (e.g. https://my-resource.openai.azure.com)"
                )
            }
            guard let deployment = input.azureOpenAIDeployment, !deployment.isEmpty else {
                throw NtakkerError.transcriptionConfigConflict(
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
                throw NtakkerError.transcriptionApiKeyMissing(provider: "elevenlabs")
            }
            input.logger.info("elevenlabs: building provider for model '\(input.elevenLabsModelId ?? ElevenLabsConfig.defaultModelId)'")
            // 2026-05-01 — `diarize` default flipped to true so the
            // user gets per-speaker turn markers out of the box; the
            // visible "wall of text" bug was the dominant complaint.
            // Users on a deployment that does not support diarization
            // can opt out via `ELEVENLABS_DIARIZE=false`.
            let elConfig = try ElevenLabsConfig(
                apiKey: key,
                modelId: input.elevenLabsModelId ?? ElevenLabsConfig.defaultModelId,
                languageCode: input.elevenLabsLanguageCode,
                diarize: input.elevenLabsDiarize ?? true,
                tagAudioEvents: input.elevenLabsTagAudioEvents ?? true,
                numSpeakers: input.elevenLabsNumSpeakers,
                fileFormat: input.elevenLabsFileFormat ?? "pcm_s16le_16",
                entityDetection: input.elevenLabsEntityDetection,
                keyterms: input.elevenLabsKeyterms ?? [],
                apiKeyExpiresAt: input.elevenLabsApiKeyExpiresAt ?? input.keyExpiresAt
            )
            return ElevenLabsTranscriptionProvider(
                config: elConfig,
                logger: input.logger
            )
        default:
            // TODO(plan-004 Phase G): use .transcriptionInvalidConfigValue(field:value:)
            throw NtakkerError.transcriptionConfigConflict(reason: "transcribe value '\(normalized)' invalid (allowed: 'none', 'apple', 'apple-cloud', 'gemini', 'whisperkit', 'parakeet', 'soniox', 'azure', 'azure-openai-realtime', 'elevenlabs')")
        }
    }
}
