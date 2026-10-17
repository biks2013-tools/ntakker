// NtakkerCore/Transcription/Providers/TranscriptionProviderFactoryInput+Options.swift
//
// plan-024 T7 — the mapping from resolved `RecordingOptions` to the
// provider factory's input. It lived inline in
// `RecordingSession.resolveTranscriptionProvider()`; ntakker-studio's
// re-transcription builds providers from the same options, so it is
// shared here.

import Foundation
import Logging

extension TranscriptionProviderFactoryInput {
    public init(options: RecordingOptions, logger: Logger) {
        self.init(
            providerId: options.transcriptionProviderId ?? "none",
            apiKey: options.transcriptionApiKey,
            modelId: options.transcriptionModelId,
            languageHints: options.transcriptionLanguageHints,
            logger: logger,
            keyExpiresAt: options.transcriptionKeyExpiresAt,
            // Plan-007 Phase A1 / A2 — Azure OpenAI fields.
            azureOpenAIEndpoint: options.azureOpenAIEndpoint,
            azureOpenAIDeployment: options.azureOpenAIDeployment,
            azureOpenAIApiVersion: options.azureOpenAIApiVersion,
            azureOpenAIApiKeyExpiresAt: options.azureOpenAIApiKeyExpiresAt,
            azureOpenAIRealtimeVADThreshold: options.azureOpenAIRealtimeVADThreshold,
            azureOpenAIRealtimeVADPrefixPaddingMS: options.azureOpenAIRealtimeVADPrefixPaddingMS,
            azureOpenAIRealtimeVADSilenceMS: options.azureOpenAIRealtimeVADSilenceMS,
            azureOpenAIRealtimeNoiseReduction: options.azureOpenAIRealtimeNoiseReduction,
            azureOpenAIRealtimeIncludeLogprobs: options.azureOpenAIRealtimeIncludeLogprobs,
            azureOpenAIRealtimeDeploymentInUrl: options.azureOpenAIRealtimeDeploymentInUrl,
            // Plan-007 Phase B — ElevenLabs fields.
            elevenLabsModelId: options.elevenLabsModelId,
            elevenLabsLanguageCode: options.elevenLabsLanguageCode,
            elevenLabsDiarize: options.elevenLabsDiarize,
            elevenLabsTagAudioEvents: options.elevenLabsTagAudioEvents,
            elevenLabsNumSpeakers: options.elevenLabsNumSpeakers,
            elevenLabsFileFormat: options.elevenLabsFileFormat,
            elevenLabsEntityDetection: options.elevenLabsEntityDetection,
            elevenLabsKeyterms: options.elevenLabsKeyterms,
            elevenLabsApiKeyExpiresAt: options.elevenLabsApiKeyExpiresAt,
            // Plan-012 Phase A5 — Soniox speaker-diarization toggle.
            sonioxDiarize: options.sonioxDiarize,
            // WhisperKit on-device tunables (added 2026-05-02).
            whisperKitModel: options.whisperKitModel,
            whisperKitLanguage: options.whisperKitLanguage,
            whisperKitTask: options.whisperKitTask,
            whisperKitTemperature: options.whisperKitTemperature,
            whisperKitWordTimestamps: options.whisperKitWordTimestamps,
            // Parakeet on-device tunables (plan-012 Phase B3).
            parakeetModel: options.parakeetModel,
            parakeetLanguage: options.parakeetLanguage
        )
    }
}
