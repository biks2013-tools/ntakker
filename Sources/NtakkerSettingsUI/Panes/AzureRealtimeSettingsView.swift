// ntakker/Settings/Sections/AzureRealtimeSettingsView.swift —
// Settings panel for the Azure OpenAI Realtime (WebSocket) provider —
// plan-007 Phase A2.

import NtakkerCore
import SwiftUI

public struct AzureRealtimeSettingsView: View {
    public init() {}
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Azure OpenAI — realtime")
                    .font(.title2).bold()
                    .padding(.bottom, 4)

                SettingsHelperText(
                    "Used when the popover picker is set to 'Azure OpenAI Realtime (cloud, streaming)'. Sessions cap at 60 minutes; the provider transparently reconnects at 58 min with a 5 s audio replay so longer recordings continue uninterrupted. Close codes 1006 / 1001 / 1011 trigger the same reconnect-with-replay path with up to 3 attempts."
                )

                SettingsSectionHeader("Authentication & resource")
                SettingsHelperText("These four values are shared with the Azure batch provider — change them once and both surfaces use the new values. Edit them under 'Azure OpenAI — batch'.")
                Group {
                    keyValueRow(label: String(localized: "API key"), envVarName: "AZURE_OPENAI_API_KEY", redact: true)
                    keyValueRow(label: String(localized: "Endpoint"), envVarName: "AZURE_OPENAI_ENDPOINT")
                    keyValueRow(label: String(localized: "Deployment"), envVarName: "AZURE_OPENAI_DEPLOYMENT")
                    keyValueRow(label: String(localized: "API version"), envVarName: "AZURE_OPENAI_API_VERSION", fallback: "2025-04-01-preview (default)")
                }

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Voice activity detection")
                SettingsFloatRow(
                    label: String(localized: "VAD threshold"),
                    envVarName: "AZURE_OPENAI_REALTIME_VAD_THRESHOLD",
                    range: 0.0...1.0,
                    helpText: String(localized: "0.0..1.0 (default 0.5). Raise (e.g. 0.7) when recording desktop audio with background noise; lower (0.3) for quiet environments."),
                    defaultValue: 0.5
                )
                SettingsIntRow(
                    label: String(localized: "Prefix padding (ms)"),
                    envVarName: "AZURE_OPENAI_REALTIME_VAD_PREFIX_PADDING_MS",
                    range: 0...5_000,
                    helpText: String(localized: "Audio retained before detected speech start (default 300 ms). Avoids clipping sentence beginnings."),
                    defaultValue: 300
                )
                SettingsIntRow(
                    label: String(localized: "Silence duration (ms)"),
                    envVarName: "AZURE_OPENAI_REALTIME_VAD_SILENCE_MS",
                    range: 0...5_000,
                    helpText: String(localized: "Silence window to mark end of turn (default 200 ms). Raise to ~500 ms for slower speakers."),
                    defaultValue: 200
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Noise reduction & extras")
                SettingsPickerRow(
                    label: String(localized: "Noise reduction"),
                    envVarName: "AZURE_OPENAI_REALTIME_NOISE_REDUCTION",
                    options: [
                        .init(id: "near_field", displayName: String(localized: "Near field (default — headset / built-in mic)")),
                        .init(id: "far_field", displayName: String(localized: "Far field — laptop mic at distance")),
                        .init(id: "none", displayName: String(localized: "None — omit the field"))
                    ],
                    helpText: String(localized: "Profile applied by Azure before transcription."),
                    defaultValue: "near_field"
                )
                SettingsToggleRow(
                    label: String(localized: "Include logprobs"),
                    envVarName: "AZURE_OPENAI_REALTIME_INCLUDE_LOGPROBS",
                    helpText: String(localized: "Diagnostic-only — adds per-token logprobs on delta / completed events. The provider does not currently surface them to the sidecar."),
                    defaultValue: false
                )
                SettingsToggleRow(
                    label: String(localized: "Append &deployment= to URL"),
                    envVarName: "AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL",
                    helpText: String(localized: "ON by default — most Azure tenants reject the parameter-less URL with an immediate WebSocket close (close=1000, 'Socket is not connected'). Flip OFF only if your tenant requires the deployment-less form (rare, matches the early TechCommunity sample)."),
                    defaultValue: true
                )

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Read-only mirror row for values owned by the batch panel.
    @ViewBuilder
    private func keyValueRow(label: String, envVarName: String, redact: Bool = false, fallback: String? = nil) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(minWidth: 140, alignment: .leading)
            Text(displayValue(for: envVarName, redact: redact, fallback: fallback))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func displayValue(for envVarName: String, redact: Bool, fallback: String?) -> String {
        // Prefer the `.env`-stored value over `ProcessInfo` so this
        // panel mirrors the Settings → Azure OpenAI batch panel
        // exactly (single source of truth for the four shared fields).
        let envFileValue = EnvFileStore.read(
            toolName: SettingsConstants.toolAgentsName,
            key: envVarName
        )
        let processValue = ProcessInfo.processInfo.environment[envVarName]
        guard let raw = (envFileValue?.isEmpty == false ? envFileValue : nil)
                ?? (processValue?.isEmpty == false ? processValue : nil)
        else {
            return fallback ?? String(localized: "(not set)")
        }
        if redact {
            guard raw.count >= 10 else { return "(set, \(raw.count) chars)" }
            return "\(raw.prefix(6))…\(raw.suffix(4)) (\(raw.count) chars)"
        }
        return raw
    }
}
