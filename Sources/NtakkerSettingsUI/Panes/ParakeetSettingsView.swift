// ntakker/Settings/Sections/ParakeetSettingsView.swift —
// Settings panel for the on-device Parakeet provider (plan-012 Phase B4).
//
// Mirrors WhisperKitSettingsView's pattern: rows persist into
// `~/.tool-agents/ntakker/.env` (`EnvFileStore`, mode 0600) using
// the project's `Settings*Row` helpers, so values land in the
// four-tier resolution chain alongside CLI / shell-env settings.
//
// FluidAudio v0.8.x exposes the model via the `AsrModelVersion` enum,
// not a free-form string, so the model row is informational/free-form
// for forward-compat — the provider clamps to v3 internally regardless.

import SwiftUI

public struct ParakeetSettingsView: View {
    public init() {}
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Parakeet (on-device, multilingual)")
                    .font(.title2).bold()
                    .padding(.bottom, 4)
                Text("On-device transcription via FluidAudio's port of NVIDIA Parakeet TDT V3. Multilingual — supports ~25 European languages including Greek. The first run downloads the model (~600 MB) to Application Support and caches it. No API key required; no audio leaves the device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Model")
                SettingsTextRow(
                    label: String(localized: "Model id"),
                    envVarName: "NTAKKER_PARAKEET_MODEL",
                    placeholder: "parakeet-tdt-0.6b-v3",
                    helpText: String(localized: "FluidAudio v0.8.x ships the multilingual TDT V3 model. The id is informational — leaving this empty selects the v3 multilingual model. Takes precedence over the shared NTAKKER_TRANSCRIBE_MODEL for the Parakeet provider only."),
                    defaultValue: "parakeet-tdt-0.6b-v3"
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Language")
                SettingsTextRow(
                    label: String(localized: "Language hint"),
                    envVarName: "NTAKKER_PARAKEET_LANGUAGE",
                    placeholder: "auto-detect",
                    helpText: String(localized: "Bare ISO-639-1 (e.g. 'en', 'el', 'tr', 'de'). Informational only — the multilingual TDT V3 model auto-detects per chunk. Kept for parity with WhisperKit and for forward-compat with future FluidAudio versions that surface a per-call language API."),
                    defaultValue: nil
                )

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
