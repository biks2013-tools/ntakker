// macrec-ui/Views/Sections/LiveTranscriptionSection.swift —
// plan-008 Unit E (project-design §UR-5).
//
// Body of the Live Transcription section: Engine + Source + Sidecar
// format + Language pickers, plus the per-provider API-key field
// (Soniox / Gemini / Azure / ElevenLabs). The `transcriptionEnabled`
// master switch lives on the section header (UR-ADR-7); when OFF the
// section body collapses to a single hint line so the persisted engine
// + key state survives without consuming popover height.
//
// The API-key row dispatches by provider id:
//   * "soniox"                       → SonioxKeyField()
//   * "gemini" / "gemini-live"       → GeminiKeyField()
//   * "azure" / "azure-openai-realtime" → ProviderKeyField(...)
//   * "elevenlabs"                    → ProviderKeyField(...)
//   * everything else (apple, whisperkit, none) → no key row
//
// Apple Speech / WhisperKit are on-device and do not need a key.
// `none` disables transcription entirely (the picker is the only
// affordance left).

import SwiftUI

/// Body of the Live Transcription section. Wrapped in a `Section` so it
/// composes cleanly inside the parent `Form` (UR-ADR-1).
struct LiveTranscriptionSection: View {
    @Environment(\.palette) private var palette

    @AppStorage("com.macrec.ui.transcribeProvider")
    private var providerRaw: String = "apple"

    @AppStorage("com.macrec.ui.transcriptionEnabled")
    private var transcriptionEnabled: Bool = true

    var body: some View {
        Section {
            if transcriptionEnabled {
                TranscriptionPicker()
                if providerRaw.lowercased() != "none" {
                    TranscriptionSourcePicker()
                    TranscriptionFormatPicker()
                    TranscriptionLanguagePicker()
                    apiKeyRow
                }
            } else {
                Text("Off — toggle on to enable live transcription")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.tertiary)
                    .padding(.vertical, 2)
            }
        }
    }

    /// Provider-specific API-key row. Composes the existing per-provider
    /// key views — Unit D wrapped each one in `ApiKeyStatusRow` so the
    /// rendered surface here matches the locked-in v1.6 chip + dotted
    /// state.
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
