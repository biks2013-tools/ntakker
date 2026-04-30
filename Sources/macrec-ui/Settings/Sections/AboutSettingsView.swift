// macrec-ui/Settings/Sections/AboutSettingsView.swift —
// Static About panel: version, credits, links to docs.

import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("About macrec")
                    .font(.title2).bold()
                    .padding(.bottom, 4)

                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "waveform.circle.fill")
                        .resizable()
                        .frame(width: 64, height: 64)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("macrec / macrec-ui")
                            .font(.headline)
                        Text("macOS dual-source audio recorder with optional live transcription.")
                            .foregroundStyle(.secondary)
                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text(String(localized: "Version \(version)"))
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        if let bundleId = Bundle.main.bundleIdentifier {
                            Text(String(localized: "Bundle id: \(bundleId)"))
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.bottom, 8)

                Divider()

                SettingsSectionHeader("Transcription engines")
                Text("• Apple Speech (on-device)")
                Text("• WhisperKit (on-device, multilingual)")
                Text("• Google Gemini (cloud, REST batch)")
                Text("• Soniox (cloud, streaming)")
                Text("• Azure OpenAI gpt-4o-mini-transcribe (cloud, REST batch)")
                Text("• Azure OpenAI Realtime (cloud, WebSocket streaming)")
                Text("• ElevenLabs Scribe v2 (cloud, REST batch)")

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Storage")
                Text("Configuration: ~/.tool-agents/macrec-ui/.env (mode 0600)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("Logs: ~/.tool-agents/macrec/macrec.log")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("Recordings: ~/Recordings/ (default; configurable in the popover)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
