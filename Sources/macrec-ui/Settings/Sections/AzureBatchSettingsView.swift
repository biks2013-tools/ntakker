// macrec-ui/Settings/Sections/AzureBatchSettingsView.swift —
// Settings panel for the Azure OpenAI batch (REST) provider — plan-007 Phase A1.
//
// All fields persist to ~/.tool-agents/macrec-ui/.env (mode 0600) via
// EnvFileStore so the next Start (CLI or UI) picks them up through the
// standard four-tier resolution chain.

import SwiftUI

struct AzureBatchSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Azure OpenAI — batch")
                    .font(.title2).bold()
                    .padding(.bottom, 4)

                SettingsHelperText(
                    "Used when the popover picker is set to 'Azure OpenAI (cloud, batch)'. The deployment must be backed by gpt-4o-mini-transcribe (or gpt-4o-transcribe) in the Azure portal — chat models like gpt-5.1 are NOT compatible."
                )

                SettingsSectionHeader("Authentication")
                ProviderKeyField(
                    providerId: "azure",
                    envVarName: "AZURE_OPENAI_API_KEY",
                    displayLabel: String(localized: "Azure OpenAI API key"),
                    helpURL: URL(string: "https://learn.microsoft.com/en-us/azure/ai-services/openai/")
                )
                SettingsHelperText("Same key is shared with the Azure realtime provider.")

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Resource")
                SettingsTextRow(
                    label: String(localized: "Endpoint"),
                    envVarName: "AZURE_OPENAI_ENDPOINT",
                    placeholder: "https://my-resource.openai.azure.com",
                    helpText: String(localized: "Resource endpoint URL (no trailing slash). Find it in Azure portal → Resource → Keys & Endpoint.")
                )
                SettingsTextRow(
                    label: String(localized: "Deployment"),
                    envVarName: "AZURE_OPENAI_DEPLOYMENT",
                    placeholder: "gpt-4o-mini-transcribe",
                    helpText: String(localized: "User-chosen deployment name (NOT the model name). Find it in Azure Foundry → Models + endpoints. Must be backed by gpt-4o-mini-transcribe or gpt-4o-transcribe.")
                )
                SettingsTextRow(
                    label: String(localized: "API version"),
                    envVarName: "AZURE_OPENAI_API_VERSION",
                    placeholder: "2025-04-01-preview",
                    helpText: String(localized: "Optional. Documented starter: 2025-04-01-preview (covers both batch and realtime). Older versions like 2024-12-01-preview do NOT support realtime transcription."),
                    defaultValue: "2025-04-01-preview"
                )

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Key expiry (optional)")
                SettingsTextRow(
                    label: String(localized: "Expires at"),
                    envVarName: "AZURE_OPENAI_API_KEY_EXPIRES_AT",
                    placeholder: "2026-12-31",
                    helpText: String(localized: "ISO-8601 date. A warning is logged 7 days before expiry; recording is NOT blocked.")
                )

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
