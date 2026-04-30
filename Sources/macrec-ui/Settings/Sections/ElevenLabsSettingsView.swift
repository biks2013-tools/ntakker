// macrec-ui/Settings/Sections/ElevenLabsSettingsView.swift —
// Settings panel for the ElevenLabs Scribe v2 batch (REST) provider —
// plan-007 Phase B.

import SwiftUI

struct ElevenLabsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("ElevenLabs Scribe v2")
                    .font(.title2).bold()
                    .padding(.bottom, 4)

                SettingsHelperText(
                    "Used when the popover picker is set to 'ElevenLabs Scribe v2 (cloud)'. Free / Starter plans cap concurrent STT requests at 8 — see configuration-guide.md §LT-EL for the per-tier table."
                )

                SettingsSectionHeader("API key")
                ProviderKeyField(
                    providerId: "elevenlabs",
                    envVarName: "ELEVENLABS_API_KEY",
                    displayLabel: String(localized: "ElevenLabs API key"),
                    helpURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Model & language")
                SettingsPickerRow(
                    label: String(localized: "Model"),
                    envVarName: "ELEVENLABS_MODEL_ID",
                    options: [
                        .init(id: "scribe_v2", displayName: "scribe_v2 (recommended)"),
                        .init(id: "scribe_v1", displayName: "scribe_v1 (older accounts)")
                    ],
                    helpText: String(localized: "Use scribe_v2 for all new integrations."),
                    defaultValue: "scribe_v2"
                )
                SettingsTextRow(
                    label: String(localized: "Language code"),
                    envVarName: "ELEVENLABS_LANGUAGE_CODE",
                    placeholder: "(auto-detect)",
                    helpText: String(localized: "ISO-639-1 (en, el) or ISO-639-3 (eng, ell). Empty = auto-detect.")
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Diarisation & audio events")
                SettingsToggleRow(
                    label: String(localized: "Diarize"),
                    envVarName: "ELEVENLABS_DIARIZE",
                    helpText: String(localized: "When ON, every word in the response carries speaker_id (up to 32 speakers)."),
                    defaultValue: false
                )
                SettingsIntRow(
                    label: String(localized: "Number of speakers"),
                    envVarName: "ELEVENLABS_NUM_SPEAKERS",
                    range: 1...32,
                    helpText: String(localized: "Optional 1..32 hint when speaker count is known. Empty = model default.")
                )
                SettingsToggleRow(
                    label: String(localized: "Tag audio events"),
                    envVarName: "ELEVENLABS_TAG_AUDIO_EVENTS",
                    helpText: String(localized: "When ON, non-speech events appear inline as (laughter), (music), (footsteps), etc."),
                    defaultValue: true
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Advanced")
                SettingsPickerRow(
                    label: String(localized: "File format"),
                    envVarName: "ELEVENLABS_FILE_FORMAT",
                    options: [
                        .init(id: "pcm_s16le_16", displayName: "pcm_s16le_16 (low-latency fast-path, default)"),
                        .init(id: "other", displayName: "other (any other supported format)")
                    ],
                    helpText: String(localized: "pcm_s16le_16 enables ElevenLabs' lower-latency processing path. Default matches AudioWAVEncoder output exactly."),
                    defaultValue: "pcm_s16le_16"
                )
                SettingsPickerRow(
                    label: String(localized: "Entity detection"),
                    envVarName: "ELEVENLABS_ENTITY_DETECTION",
                    options: [
                        .init(id: "", displayName: String(localized: "Off (no surcharge)")),
                        .init(id: "pii", displayName: "PII (+30%)"),
                        .init(id: "phi", displayName: "PHI (+30%)"),
                        .init(id: "pci", displayName: "PCI (+30%)"),
                        .init(id: "all", displayName: "All categories (+30%)")
                    ],
                    helpText: String(localized: "Enabling entity detection adds +30% to ElevenLabs' per-hour pricing. OFF by default to avoid surprise costs."),
                    defaultValue: ""
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Key expiry (optional)")
                SettingsTextRow(
                    label: String(localized: "Expires at"),
                    envVarName: "ELEVENLABS_API_KEY_EXPIRES_AT",
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
