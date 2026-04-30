// macrec-ui/Settings/Sections/GeminiSettingsView.swift —
// Settings panel for the Google Gemini REST batch provider.

import SwiftUI

struct GeminiSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Gemini")
                    .font(.title2).bold()
                    .padding(.bottom, 4)

                SettingsSectionHeader("API key")
                ProviderKeyField(
                    providerId: "gemini",
                    envVarName: "GOOGLE_API_KEY",
                    displayLabel: String(localized: "Google API key"),
                    helpURL: URL(string: "https://aistudio.google.com/app/apikey")
                )
                SettingsHelperText("Stored at ~/.tool-agents/macrec-ui/.env (mode 0600). Used for both Gemini batch and Gemini Live (deprecated alias).")

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Model")
                SettingsTextRow(
                    label: String(localized: "Model id"),
                    envVarName: "MACREC_TRANSCRIBE_MODEL",
                    placeholder: "gemini-3-flash-preview",
                    helpText: String(localized: "Optional override. Default: gemini-3-flash-preview. Allowed: gemini-3.1-flash-live-preview, gemini-3-flash-preview, gemini-2.5-flash, gemini-2.5-pro, gemini-2.0-flash."),
                    defaultValue: "gemini-3-flash-preview"
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Key expiry (optional)")
                SettingsTextRow(
                    label: String(localized: "Expires at"),
                    envVarName: "MACREC_TRANSCRIBE_KEY_EXPIRES_AT",
                    placeholder: "2026-12-31",
                    helpText: String(localized: "ISO-8601 date. A warning is logged 7 days before expiry; recording is NOT blocked. Shared across providers; per-provider overrides exist for Soniox / Azure / ElevenLabs.")
                )

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
