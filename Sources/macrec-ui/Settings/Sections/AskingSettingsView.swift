// macrec-ui/Settings/Sections/AskingSettingsView.swift —
// plan-015 Phase 4 Settings surface. Configures the in-recording Q&A
// (Asking) feature — provider selection, model override, transcript
// context window, and per-provider credentials.
//
// All values persist to `~/.tool-agents/macrec-ui/.env` (mode 0600)
// via `EnvFileStore` so the next app launch reads them through the
// standard four-tier resolution chain. The view re-renders its
// credentials region whenever the provider picker changes so the
// user only sees the fields that matter for the active selection.
//
// Reused infrastructure:
//   * `SettingsTextRow` / `SettingsIntRow` / `SettingsSectionHeader` /
//     `SettingsHelperText` — from `SettingsRowHelpers.swift`.
//   * `ProviderKeyField` — from `Views/Transcription/ProviderKeyField.swift`
//     for secret keys (debounce-free, paste-only commit, masked display).
//
// The Azure OpenAI and Gemini credential fields are intentionally NOT
// duplicated here — they live in their dedicated panels
// (`AzureBatchSettingsView`, `GeminiSettingsView`) and are shared
// with the transcription side. This view links the user to those
// panels via inline help text.

import MacrecCore
import SwiftUI

struct AskingSettingsView: View {

    /// Mirrors `MACREC_ASK_PROVIDER` so the conditional credential
    /// sub-section can re-render when the user changes the picker.
    @State private var provider: String = ""

    private static let providerOptions: [(id: String, label: String)] = [
        ("",                   String(localized: "— Not configured —")),
        ("azure-openai",       AskProvider.azureOpenAI.displayName),
        ("openai",             AskProvider.openai.displayName),
        ("anthropic",          AskProvider.anthropic.displayName),
        ("google",             AskProvider.google.displayName),
        ("azure-ai-inference", AskProvider.azureAIInference.displayName),
        ("ollama",             AskProvider.ollama.displayName),
        ("litellm",            AskProvider.litellm.displayName),
        ("mlx",                AskProvider.mlx.displayName),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ------------------------------------------------------
                // Header
                // ------------------------------------------------------
                Text("Asking — in-recording Q&A")
                    .font(.title2).bold()
                    .padding(.bottom, 4)

                SettingsHelperText(
                    "Configures the Asking pane in the popover. Each question you submit, together with the last N minutes of your live transcript, is sent to the selected LLM provider over HTTPS. macrec stores no chat history server-side — answers are streamed locally and persisted only in the Q&A sidecar next to the audio file."
                )

                // ------------------------------------------------------
                // Provider + tuning
                // ------------------------------------------------------
                SettingsSectionHeader("Provider")

                HStack(spacing: 12) {
                    Text(String(localized: "LLM provider"))
                        .frame(minWidth: 140, alignment: .leading)
                    Spacer()
                    Picker("", selection: $provider) {
                        ForEach(Self.providerOptions, id: \.id) { opt in
                            Text(opt.label).tag(opt.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: provider) { _, newValue in
                        commitProvider(newValue)
                    }
                }

                if let macrec = provider.isEmpty ? nil : AskProvider(envValue: provider) {
                    Text(macrec.isCloud
                         ? String(localized: "Cloud provider — first question opens a one-time privacy disclosure.")
                         : String(localized: "Local provider — no data leaves your machine."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "Required. Without a provider the Asking pane shows an inline configuration error."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsTextRow(
                    label: String(localized: "Model override"),
                    envVarName: "MACREC_ASK_MODEL",
                    placeholder: modelPlaceholder,
                    helpText: modelHelpText
                )

                SettingsIntRow(
                    label: String(localized: "Context window (min)"),
                    envVarName: "MACREC_ASK_CONTEXT_MINUTES",
                    range: 1...30,
                    helpText: String(localized: "How many minutes of the recent transcript to include with every question. Larger windows give better answers but cost more tokens and slow first-token latency."),
                    defaultValue: 5
                )

                // ------------------------------------------------------
                // Credentials (provider-conditional)
                // ------------------------------------------------------
                if !provider.isEmpty,
                   let resolved = AskProvider(envValue: provider)
                {
                    Divider().padding(.vertical, 4)
                    credentialsSection(for: resolved)
                }

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reload)
    }

    // MARK: - Credentials sub-section

    @ViewBuilder
    private func credentialsSection(for resolved: AskProvider) -> some View {
        SettingsSectionHeader("Credentials")

        switch resolved {
        case .openai:
            ProviderKeyField(
                providerId: "openai",
                envVarName: "OPENAI_API_KEY",
                displayLabel: String(localized: "OpenAI API key"),
                helpURL: URL(string: "https://platform.openai.com/api-keys")
            )
            SettingsTextRow(
                label: String(localized: "Base URL"),
                envVarName: "OPENAI_BASE_URL",
                placeholder: "https://api.openai.com/v1",
                helpText: String(localized: "Optional. Override only when routing through an OpenAI-compatible proxy.")
            )

        case .anthropic:
            ProviderKeyField(
                providerId: "anthropic",
                envVarName: "ANTHROPIC_API_KEY",
                displayLabel: String(localized: "Anthropic API key"),
                helpURL: URL(string: "https://console.anthropic.com/settings/keys")
            )
            SettingsTextRow(
                label: String(localized: "Base URL"),
                envVarName: "ANTHROPIC_BASE_URL",
                placeholder: "https://api.anthropic.com/v1",
                helpText: String(localized: "Optional. Override only when using Anthropic's region-specific or proxy endpoints.")
            )
            SettingsTextRow(
                label: String(localized: "API version"),
                envVarName: "ANTHROPIC_VERSION",
                placeholder: "2023-06-01",
                helpText: String(localized: "Optional. Pinned by Anthropic; only change when migrating to a new version.")
            )

        case .google:
            ProviderKeyField(
                providerId: "gemini",
                envVarName: "GOOGLE_API_KEY",
                displayLabel: String(localized: "Google AI API key"),
                helpURL: URL(string: "https://aistudio.google.com/app/apikey")
            )
            SettingsHelperText("Shared with the Gemini transcription provider. `GEMINI_API_KEY` is also accepted as an alias.")
            SettingsTextRow(
                label: String(localized: "Base URL"),
                envVarName: "GOOGLE_BASE_URL",
                placeholder: "https://generativelanguage.googleapis.com/v1beta",
                helpText: String(localized: "Optional. Override only for region-specific endpoints.")
            )

        case .azureOpenAI:
            SettingsHelperText("Uses the same `AZURE_OPENAI_*` credentials as the Azure OpenAI transcription provider — manage them in the **Azure OpenAI** section in the sidebar. If your transcription deployment is a chat model (e.g. `gpt-5.1`), it works for Q&A as-is. If it's a transcription model (e.g. `gpt-4o-mini-transcribe`), set **Model override** above to point Q&A at a chat-capable deployment.")
            keyStatusRow(
                label: String(localized: "AZURE_OPENAI_API_KEY"),
                envVarName: "AZURE_OPENAI_API_KEY"
            )
            keyStatusRow(
                label: String(localized: "AZURE_OPENAI_ENDPOINT"),
                envVarName: "AZURE_OPENAI_ENDPOINT"
            )
            keyStatusRow(
                label: String(localized: "AZURE_OPENAI_DEPLOYMENT"),
                envVarName: "AZURE_OPENAI_DEPLOYMENT"
            )
            keyStatusRow(
                label: String(localized: "AZURE_OPENAI_API_VERSION"),
                envVarName: "AZURE_OPENAI_API_VERSION",
                hint: String(localized: "When set, uses the legacy deployment-based URL. When unset, uses the v1 GA path (recommended for current models).")
            )

        case .azureAIInference:
            ProviderKeyField(
                providerId: "azure-ai-inference",
                envVarName: "AZURE_AI_INFERENCE_KEY",
                displayLabel: String(localized: "Azure AI Foundry key"),
                helpURL: URL(string: "https://ai.azure.com/")
            )
            SettingsTextRow(
                label: String(localized: "Endpoint"),
                envVarName: "AZURE_AI_INFERENCE_ENDPOINT",
                placeholder: "https://<resource>.services.ai.azure.com/models",
                helpText: String(localized: "Foundry inference endpoint, ending in `/models`. Find it in the Foundry portal → Deployment → Endpoint.")
            )
            SettingsTextRow(
                label: String(localized: "API version"),
                envVarName: "AZURE_AI_INFERENCE_API_VERSION",
                placeholder: "2024-05-01-preview",
                helpText: String(localized: "Optional. Defaults to 2024-05-01-preview when unset."),
                defaultValue: "2024-05-01-preview"
            )

        case .ollama:
            SettingsTextRow(
                label: String(localized: "Host"),
                envVarName: "OLLAMA_HOST",
                placeholder: "http://127.0.0.1:11434",
                helpText: String(localized: "Optional. Defaults to localhost when unset. Ollama must be running and the model loaded.")
            )

        case .litellm:
            SettingsTextRow(
                label: String(localized: "Proxy URL"),
                envVarName: "LITELLM_PROXY_URL",
                placeholder: "https://litellm.example.com",
                helpText: String(localized: "Required. Base URL of your LiteLLM proxy. `LITELLM_API_BASE` is also accepted as an alias.")
            )
            ProviderKeyField(
                providerId: "litellm",
                envVarName: "LITELLM_API_KEY",
                displayLabel: String(localized: "Proxy API key"),
                helpURL: URL(string: "https://docs.litellm.ai/")
            )
            SettingsHelperText("Optional. Sent as `Bearer` token to your LiteLLM proxy. Leave blank for unauthenticated local proxies.")

        case .mlx:
            SettingsTextRow(
                label: String(localized: "Base URL"),
                envVarName: "MLX_BASE_URL",
                placeholder: "http://127.0.0.1:8080/v1",
                helpText: String(localized: "Required. Base URL of your local `mlx_lm.server`. Start it with `mlx_lm.server --model <model-id>`.")
            )
        }
    }

    /// Read-only status row for env vars whose canonical edit surface
    /// lives on another Settings panel (e.g. Azure OpenAI batch). We
    /// show the user that the value IS present without letting them
    /// edit it from two places.
    @ViewBuilder
    private func keyStatusRow(label: String, envVarName: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 220, alignment: .leading)
                Spacer()
                if let value = EnvFileStore.read(toolName: SettingsConstants.toolAgentsName, key: envVarName),
                   !value.isEmpty
                {
                    Label(String(localized: "Configured"), systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label(String(localized: "Not set"), systemImage: "circle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Reactive labels

    private var modelPlaceholder: String {
        guard let p = AskProvider(envValue: provider) else { return "(default)" }
        switch p {
        case .openai:           return "gpt-4o-mini"
        case .anthropic:        return "claude-haiku-4-5-20251001"
        case .google:           return "gemini-2.5-flash"
        case .azureOpenAI:      return String(localized: "(falls back to AZURE_OPENAI_DEPLOYMENT)")
        case .azureAIInference: return String(localized: "(required for Foundry)")
        case .ollama:           return "llama3.1:8b"
        case .litellm:          return "gpt-4o"
        case .mlx:              return "mlx-community/…"
        }
    }

    private var modelHelpText: String {
        guard let p = AskProvider(envValue: provider) else {
            return String(localized: "Optional. Provider-specific defaults are used when unset.")
        }
        switch p {
        case .openai, .anthropic, .google:
            return String(localized: "Optional. Falls back to the provider's documented default when unset.")
        case .azureOpenAI:
            return String(localized: "Optional. Defaults to your AZURE_OPENAI_DEPLOYMENT. Set this when your transcription deployment is NOT a chat model and you have a separate chat-capable deployment.")
        case .azureAIInference, .ollama, .litellm, .mlx:
            return String(localized: "Required. No fallback — without an explicit model the Asking pane raises a configuration error.")
        }
    }

    // MARK: - Provider commit / reload

    private func reload() {
        let stored = EnvFileStore.read(
            toolName: SettingsConstants.toolAgentsName,
            key: "MACREC_ASK_PROVIDER"
        ) ?? ""
        let normalised = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept the same legacy aliases as `AskProvider.init(envValue:)`
        // so an `azure` or `gemini` value displays as the canonical option.
        if let canonical = AskProvider(envValue: normalised) {
            provider = canonical.rawValue
        } else {
            provider = ""
        }
    }

    private func commitProvider(_ newValue: String) {
        try? EnvFileStore.upsert(
            toolName: SettingsConstants.toolAgentsName,
            key: "MACREC_ASK_PROVIDER",
            value: newValue
        )
    }
}
