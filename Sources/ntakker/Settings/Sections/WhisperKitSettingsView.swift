// ntakker/Settings/Sections/WhisperKitSettingsView.swift —
// Settings panel for the on-device WhisperKit provider (added 2026-05-02).
//
// All five rows persist to `~/.tool-agents/ntakker/.env`
// (`EnvFileStore`, mode 0600) using the existing
// `Settings*Row` helpers — same auto-save + status-badge UX as every
// cloud-provider section. The four-tier env resolution chain
// (shell env → ~/.tool-agents/ntakker/.env → local .env → CLI flags)
// means a value the user picks here is picked up by the next
// `RecordingSession` start without any app restart.
//
// Each row binds to the matching `NTAKKER_WHISPERKIT_*` env-var key
// declared on `ConfigResolver.Keys`. The resolver validates them
// eagerly and surfaces typos / out-of-range values as
// `NtakkerError.invalidConfigValue(...)` at config-load time (CLAUDE.md
// no-fallback rule). Absent values pass `nil` to the provider, which
// applies its own pinned defaults at construction time.

import SwiftUI

struct WhisperKitSettingsView: View {

    /// Curated WhisperKit model variants. Each id matches the
    /// HuggingFace model-name convention WhisperKit's loader expects.
    /// The `displayName` is the abbreviated label users actually pick.
    /// Sizes are approximate as published by Argmax.
    private let modelOptions: [SettingsPickerRow.PickerOption] = [
        .init(id: "openai_whisper-tiny",
              displayName: "tiny (~75 MB, fastest, lowest quality)"),
        .init(id: "openai_whisper-base",
              displayName: "base (~140 MB)"),
        .init(id: "openai_whisper-small",
              displayName: "small (~460 MB)"),
        .init(id: "openai_whisper-medium",
              displayName: "medium (~1.5 GB)"),
        .init(id: "openai_whisper-large-v3-v20240930_626MB",
              displayName: "large-v3 (~620 MB, default — best quality)"),
        .init(id: "distil-whisper_distil-large-v3",
              displayName: "distil-large-v3 (~1 GB, faster than large-v3)")
    ]

    private let taskOptions: [SettingsPickerRow.PickerOption] = [
        .init(id: "transcribe",
              displayName: "transcribe (text in source language)"),
        .init(id: "translate",
              displayName: "translate (translate to English)")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("WhisperKit (on-device)")
                    .font(.title2).bold()
                    .padding(.bottom, 4)
                Text("On-device transcription via Argmax WhisperKit (OpenAI Whisper, multilingual). The first run downloads the chosen model to ~/Documents/huggingface/ and caches it. No API key required; no audio leaves the device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Model")
                SettingsPickerRow(
                    label: String(localized: "Variant"),
                    envVarName: "NTAKKER_WHISPERKIT_MODEL",
                    options: modelOptions,
                    helpText: String(localized: "Smaller variants are faster and use less RAM but produce lower-quality transcripts. Larger variants are slower / heavier but more accurate. Multilingual coverage is comparable across all variants. Takes precedence over the shared NTAKKER_TRANSCRIBE_MODEL for the WhisperKit provider only."),
                    defaultValue: "openai_whisper-large-v3-v20240930_626MB"
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Language")
                SettingsTextRow(
                    label: String(localized: "Language code"),
                    envVarName: "NTAKKER_WHISPERKIT_LANGUAGE",
                    placeholder: "auto-detect",
                    helpText: String(localized: "Bare ISO-639-1 (e.g. 'en', 'el', 'tr', 'de'). NOT a BCP-47 tag (Whisper's tokenizer uses the bare 2-letter form). Leave empty to let Whisper auto-detect per chunk."),
                    defaultValue: nil
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Decoding task")
                SettingsPickerRow(
                    label: String(localized: "Task"),
                    envVarName: "NTAKKER_WHISPERKIT_TASK",
                    options: taskOptions,
                    helpText: String(localized: "'transcribe' returns text in the source language; 'translate' converts the audio to English text regardless of source language."),
                    defaultValue: "transcribe"
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Decoding tunables")
                SettingsFloatRow(
                    label: String(localized: "Temperature"),
                    envVarName: "NTAKKER_WHISPERKIT_TEMPERATURE",
                    range: 0.0...1.0,
                    helpText: String(localized: "0 (default) = deterministic / verbatim. Higher values diversify decoding. Only useful when the model produces repeated or degenerate text on a tricky chunk."),
                    defaultValue: 0.0
                )
                SettingsToggleRow(
                    label: String(localized: "Word timestamps"),
                    envVarName: "NTAKKER_WHISPERKIT_WORD_TIMESTAMPS",
                    helpText: String(localized: "Request per-word timestamps. Adds ~10-20% extra compute per chunk. Required for accurate SRT / VTT sidecars."),
                    defaultValue: false
                )

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    WhisperKitSettingsView()
        .frame(width: 520, height: 600)
}
