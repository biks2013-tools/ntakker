// Sources/MacrecCore/Transcription/Live/Soniox/SonioxConfigBuilder.swift
//
// Plan-006 Phase D / Unit D1: builder for the first JSON frame the
// `SonioxStreamingSession` sends after connect. Centralises the
// `macrec` v1 default policy (audio framing, language identification,
// endpoint detection) so the session itself can stay focused on
// transport + state-machine concerns.
//
// Defaults (per docs/design/project-design.md §SX-3.1 and the wire
// schema §2.1):
//   * model:                          "stt-rt-v4"
//   * audio_format:                   "pcm_s16le"
//   * sample_rate:                    16000
//   * num_channels:                   1
//   * language_hints_strict:          false   (bias-without-restriction)
//   * enable_language_identification: true    (FR-SX-10)
//   * enable_endpoint_detection:      true    (clean `<end>` markers)
//   * max_endpoint_delay_ms:          2000    (clean finals over latency)
//   * enable_speaker_diarization:     false   (out of v1 scope)

import Foundation

public enum SonioxConfigBuilder {

    /// Real-time STT model id used by `macrec` v1.
    public static let defaultModel = "stt-rt-v4"

    /// Build a `SonioxConfigMessage` populated with `macrec` v1 defaults.
    /// The caller supplies the API key, language hints (already
    /// normalised — see `SonioxLanguageHintMapper`), and an optional
    /// reference id for Soniox console traceability.
    public static func build(
        apiKey: String,
        model: String = defaultModel,
        languageHints: [String],
        clientReferenceId: String? = nil
    ) -> SonioxConfigMessage {
        return SonioxConfigMessage(
            apiKey: apiKey,
            model: model,
            audioFormat: "pcm_s16le",
            sampleRate: 16_000,
            numChannels: 1,
            languageHints: languageHints,
            languageHintsStrict: false,
            enableLanguageIdentification: true,
            enableEndpointDetection: true,
            maxEndpointDelayMs: 2_000,
            enableSpeakerDiarization: false,
            context: nil,
            clientReferenceId: clientReferenceId,
            keepaliveIntervalMs: nil
        )
    }
}
