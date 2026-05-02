// macrec-ui/Settings/Sections/SonioxSettingsView.swift —
// Settings panel for the Soniox cloud streaming provider (plan-006).

import SwiftUI

struct SonioxSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Soniox")
                    .font(.title2).bold()
                    .padding(.bottom, 4)

                SettingsSectionHeader("API key")
                ProviderKeyField(
                    providerId: "soniox",
                    envVarName: "SONIOX_API_KEY",
                    displayLabel: String(localized: "Soniox API key"),
                    helpURL: URL(string: "https://console.soniox.com")
                )
                SettingsHelperText("Stored at ~/.tool-agents/macrec-ui/.env (mode 0600). Get a key at https://console.soniox.com.")

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Model")
                SettingsTextRow(
                    label: String(localized: "Model id"),
                    envVarName: "MACREC_TRANSCRIBE_MODEL",
                    placeholder: "stt-rt-v4",
                    helpText: String(localized: "Optional override. Default: stt-rt-v4."),
                    defaultValue: "stt-rt-v4"
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Diarization")
                SettingsToggleRow(
                    label: String(localized: "Diarize speakers"),
                    envVarName: "MACREC_SONIOX_DIARIZE",
                    helpText: String(localized: "Tag each transcript segment with the Soniox-detected speaker (S1, S2, …). On by default; turn off for monologue recordings."),
                    defaultValue: true
                )
                SettingsHelperText("Speaker labels appear in JSONL (raw 'spk:N'), TXT ([S1] prefix), SRT ('S1:' prefix), and VTT (<v S1>...</v>). Sidecar files for non-Soniox providers are unaffected.")

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Endpoint (regional)")
                SettingsPickerRow(
                    label: String(localized: "WebSocket endpoint"),
                    envVarName: "MACREC_SONIOX_ENDPOINT",
                    options: [
                        .init(id: "", displayName: String(localized: "Default (US)")),
                        .init(id: "wss://stt-rt.soniox.com/transcribe-websocket", displayName: "US — wss://stt-rt.soniox.com"),
                        .init(id: "wss://stt-rt.eu.soniox.com/transcribe-websocket", displayName: "EU — wss://stt-rt.eu.soniox.com"),
                        .init(id: "wss://stt-rt.jp.soniox.com/transcribe-websocket", displayName: "Japan — wss://stt-rt.jp.soniox.com")
                    ],
                    helpText: String(localized: "Pin to a region for data residency. Empty = vendor default (US)."),
                    defaultValue: ""
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Key expiry (optional)")
                SettingsTextRow(
                    label: String(localized: "Expires at"),
                    envVarName: "MACREC_SONIOX_KEY_EXPIRES_AT",
                    placeholder: "2026-12-31",
                    helpText: String(localized: "ISO-8601 date. Per-provider override; falls back to MACREC_TRANSCRIBE_KEY_EXPIRES_AT when unset.")
                )

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
