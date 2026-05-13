// macrec-ui/Views/Transcription/SingleTranscriptionControls.swift —
// plan-010 Phase E (Lane L-7); see project-design §DT-8 (UI design)
// "Mode switch + Single sub-view (DT-INV-1 verbatim wrapper)" and
// plan-010 §E.1.
//
// Verbatim wrapper around the four control rows that previously lived
// inline inside `LiveTranscriptionSection`'s `Section` body:
//
//   1. `TranscriptionPicker`         (Transcribe)
//   2. `TranscriptionSourcePicker`   (Source)
//   3. `TranscriptionFormatPicker`   (Transcript format)
//   4. `TranscriptionLanguagePicker` (Language)
//   5. provider-specific API-key row dispatched by the picker provider id
//
// AC-1 hard constraint: this extraction is a pure refactor. Identical
// `@AppStorage` keys, identical defaults, identical labels, identical
// vertical rhythm. The four sub-views are reused verbatim — there is
// no copy / styling / spacing change here. The only behavioural
// difference vs. pre-L-7 is that the rows are now wrapped in this view
// instead of being inlined into `LiveTranscriptionSection`.
//
// Single-mode AppStorage keys consumed transitively (pinned by
// `ControlBarStartTappedKeysRegressionTests` and the new
// `SingleTranscriptionControlsRegressionTests` per plan-010 §E.4):
//
//   - com.macrec.ui.transcribeProvider
//   - com.macrec.ui.transcribeSource
//   - com.macrec.ui.transcriptFormat
//   - com.macrec.ui.transcribeLanguage  (+ secondary `transcribeLanguage2`
//     when the dual-locale toggle is on, via TranscriptionLanguagePicker)
//   - com.macrec.ui.transcribeKeyExpiresAt (provider-key rows)
//
// Per `LiveTranscriptionSection`, the API-key row is dispatched by
// the resolved provider id; Apple Speech / Apple Cloud / WhisperKit /
// "none" do NOT render a key row.

import SwiftUI

/// Live-transcription control set. Wraps the four-row block
/// (Transcribe / Source / Transcript format / Language) plus the
/// per-provider API-key row.
struct SingleTranscriptionControls: View {
    @Environment(\.palette) private var palette

    /// Mirror of `TranscriptionPicker`'s persisted provider id —
    /// used here exclusively to decide which provider-specific
    /// API-key row to render (or none, for on-device / `none`
    /// providers). Same key, same default as the picker itself.
    @AppStorage("com.macrec.ui.transcribeProvider")
    private var providerRaw: String = "apple"

    var body: some View {
        TranscriptionPicker()
        if providerRaw.lowercased() != "none" {
            TranscriptionSourcePicker()
            TranscriptionFormatPicker()
            TranscriptionLanguagePicker()
            apiKeyRow
        }
    }

    /// Provider-specific API-key row. Mirrors the dispatch table that
    /// previously lived inline in `LiveTranscriptionSection.apiKeyRow`.
    /// Apple Speech / Apple Cloud / WhisperKit / `none` do not require
    /// a key and render `EmptyView`.
    @ViewBuilder
    private var apiKeyRow: some View {
        switch providerRaw.lowercased() {
        case "soniox":
            SonioxKeyField()
        case "gemini", "gemini-live":
            GeminiKeyField()
        case "azure":
            ProviderKeyField(
                providerId: "azure",
                envVarName: "AZURE_OPENAI_API_KEY",
                displayLabel: String(localized: "Azure OpenAI API key"),
                helpURL: URL(string: "https://learn.microsoft.com/azure/ai-services/openai/")
            )
        case "azure-openai-realtime":
            ProviderKeyField(
                providerId: "azure-openai-realtime",
                envVarName: "AZURE_OPENAI_API_KEY",
                displayLabel: String(localized: "Azure OpenAI Realtime API key"),
                helpURL: URL(string: "https://learn.microsoft.com/azure/ai-services/openai/")
            )
        case "elevenlabs":
            ProviderKeyField(
                providerId: "elevenlabs",
                envVarName: "ELEVENLABS_API_KEY",
                displayLabel: String(localized: "ElevenLabs API key"),
                helpURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")
            )
        default:
            EmptyView()
        }
    }
}
