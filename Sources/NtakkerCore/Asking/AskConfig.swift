// NtakkerCore/Asking/AskConfig.swift — plan-015 Phase 4 (FR-IRQ-7,
// FR-IRQ-19). Single source of truth for the in-recording Q&A
// feature's LLM configuration.
//
// Resolution chain (matches the project's four-tier env-var resolution
// chain — the `~/.tool-agents/ntakker/.env` file is already loaded
// into the process environment at app startup by
// `EnvFileStore.loadIntoProcess(toolName:)`, so `ProcessInfo` reflects
// the merged view):
//
//   1. `NTAKKER_ASK_PROVIDER`   — REQUIRED. One of the eight standard
//                                provider ids. No fallback.
//   2. `NTAKKER_ASK_MODEL`      — Optional. When unset, the provider's
//                                conventional default is used; provider
//                                families that have NO sane default
//                                (azure-ai-inference / ollama / litellm
//                                / mlx) raise `NtakkerError.missingRequiredConfig`.
//   3. Per-provider credentials — REQUIRED per provider. Vendor-canonical
//                                names exactly as documented in
//                                `convo-coach`: `OPENAI_API_KEY`,
//                                `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`
//                                (alias `GEMINI_API_KEY`), `AZURE_OPENAI_*`,
//                                `AZURE_AI_INFERENCE_*`, `OLLAMA_HOST`,
//                                `LITELLM_PROXY_URL` (alias
//                                `LITELLM_API_BASE`), `MLX_BASE_URL`.
//
// The resolver returns a single `AskConfig` struct that downstream
// clients can consume without re-reading the environment, OR throws a
// typed `NtakkerError.missingRequiredConfig` that the UI surfaces inline
// (FR-IRQ-19). The CLAUDE.md no-fallback rule is observed strictly:
// neither the provider selection nor any credential receives a silent
// default.

import Foundation

/// Fully-resolved configuration for one Q&A request. Built by
/// `AskConfig.resolve()` from the process environment.
public struct AskConfig: Sendable, Equatable {
    public let provider: AskProvider
    /// Model identifier passed to the provider. For Azure OpenAI in
    /// deployment-based mode this is the deployment name; for Azure
    /// OpenAI v1 GA this is also the deployment name (Azure routes by
    /// deployment regardless of which URL shape we choose).
    public let model: String
    /// Base URL of the provider's HTTP endpoint. Already includes any
    /// `/openai/v1` or `/v1` prefix the provider needs; clients append
    /// the per-route path (`/chat/completions`, `/messages`, …).
    public let endpoint: URL
    /// Bearer / api-key used for `Authorization` (OpenAI / Anthropic) or
    /// `api-key` (Azure) headers. `nil` for fully unauthenticated local
    /// endpoints (Ollama default).
    public let apiKey: String?
    /// Optional Azure API version (only set for legacy deployment-based
    /// Azure OpenAI URLs).
    public let azureAPIVersion: String?
    /// Maximum number of transcript minutes to include in the prompt
    /// window. Sourced from `NTAKKER_ASK_CONTEXT_MINUTES`, default 5
    /// (FR-IRQ-6, FR-IRQ-17). Clamped to 1...30.
    public let contextMinutes: Int

    public init(
        provider: AskProvider,
        model: String,
        endpoint: URL,
        apiKey: String?,
        azureAPIVersion: String?,
        contextMinutes: Int
    ) {
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.azureAPIVersion = azureAPIVersion
        self.contextMinutes = contextMinutes
    }
}

/// Pure resolver for `AskConfig`. Reads from `ProcessInfo` (which
/// includes the values loaded out of `~/.tool-agents/ntakker/.env`
/// at app startup — see `EnvFileStore.loadIntoProcess`).
public enum AskConfigResolver {

    /// The conventional sources we report in
    /// `NtakkerError.missingRequiredConfig.sourcesChecked` so the inline
    /// error surface can point the user at where to set the missing
    /// key. Matches the four-tier chain described in the project's
    /// CLAUDE.md.
    public static let canonicalSources: [String] = [
        "shell environment",
        "~/.tool-agents/ntakker/.env",
    ]

    /// Resolve a fully-populated `AskConfig` from the process
    /// environment. Throws `NtakkerError.missingRequiredConfig` when a
    /// required slot is unset; the caller is responsible for surfacing
    /// the error inline (FR-IRQ-19).
    public static func resolve(env: [String: String] = ProcessInfo.processInfo.environment) throws -> AskConfig {
        // 1. Provider — required.
        guard let providerRaw = nonEmpty(env["NTAKKER_ASK_PROVIDER"]) else {
            throw NtakkerError.missingRequiredConfig(
                key: "NTAKKER_ASK_PROVIDER",
                sourcesChecked: canonicalSources
            )
        }
        guard let provider = AskProvider(envValue: providerRaw) else {
            throw NtakkerError.invalidConfigValue(
                key: "NTAKKER_ASK_PROVIDER",
                value: providerRaw,
                expected: AskProvider.allCases.map(\.rawValue).joined(separator: " | ")
            )
        }

        // 2. Context-minutes (optional, default 5, clamp 1...30).
        let contextMinutes: Int = {
            guard let raw = nonEmpty(env["NTAKKER_ASK_CONTEXT_MINUTES"]),
                  let n = Int(raw)
            else { return 5 }
            return min(30, max(1, n))
        }()

        // 3. Per-provider resolution.
        switch provider {
        case .openai:
            let key = try required(env, "OPENAI_API_KEY")
            let base = URL(string: nonEmpty(env["OPENAI_BASE_URL"]) ?? "https://api.openai.com/v1")!
            let model = nonEmpty(env["NTAKKER_ASK_MODEL"]) ?? "gpt-4o-mini"
            return AskConfig(
                provider: provider, model: model, endpoint: base,
                apiKey: key, azureAPIVersion: nil, contextMinutes: contextMinutes
            )

        case .anthropic:
            let key = try required(env, "ANTHROPIC_API_KEY")
            let base = URL(string: nonEmpty(env["ANTHROPIC_BASE_URL"]) ?? "https://api.anthropic.com/v1")!
            let model = nonEmpty(env["NTAKKER_ASK_MODEL"]) ?? "claude-haiku-4-5-20251001"
            return AskConfig(
                provider: provider, model: model, endpoint: base,
                apiKey: key, azureAPIVersion: nil, contextMinutes: contextMinutes
            )

        case .google:
            let key = nonEmpty(env["GOOGLE_API_KEY"]) ?? nonEmpty(env["GEMINI_API_KEY"])
            guard let resolved = key else {
                throw NtakkerError.missingRequiredConfig(
                    key: "GOOGLE_API_KEY (or GEMINI_API_KEY)",
                    sourcesChecked: canonicalSources
                )
            }
            let base = URL(string: nonEmpty(env["GOOGLE_BASE_URL"]) ?? "https://generativelanguage.googleapis.com/v1beta")!
            let model = nonEmpty(env["NTAKKER_ASK_MODEL"]) ?? "gemini-2.5-flash"
            return AskConfig(
                provider: provider, model: model, endpoint: base,
                apiKey: resolved, azureAPIVersion: nil, contextMinutes: contextMinutes
            )

        case .azureOpenAI:
            let key = try required(env, "AZURE_OPENAI_API_KEY")
            let endpointRaw = try required(env, "AZURE_OPENAI_ENDPOINT")
            guard let base = URL(string: endpointRaw) else {
                throw NtakkerError.invalidConfigValue(
                    key: "AZURE_OPENAI_ENDPOINT",
                    value: endpointRaw,
                    expected: "absolute URL (e.g. https://<resource>.openai.azure.com)"
                )
            }
            let deployment = try required(env, "AZURE_OPENAI_DEPLOYMENT")
            // Per convo-coach docs: an unset api-version selects the new
            // `v1` GA path; a set value preserves the legacy
            // deployment-based URL pattern.
            let apiVersion = nonEmpty(env["AZURE_OPENAI_API_VERSION"])
            // For Azure, model id == deployment name (the SDK passes it
            // through as the `model` field even in deployment-based URLs).
            let model = nonEmpty(env["NTAKKER_ASK_MODEL"]) ?? deployment
            return AskConfig(
                provider: provider, model: model, endpoint: base,
                apiKey: key, azureAPIVersion: apiVersion, contextMinutes: contextMinutes
            )

        case .azureAIInference:
            let key = nonEmpty(env["AZURE_AI_INFERENCE_KEY"])
                ?? nonEmpty(env["ANTHROPIC_FOUNDRY_API_KEY"])
            guard let resolvedKey = key else {
                throw NtakkerError.missingRequiredConfig(
                    key: "AZURE_AI_INFERENCE_KEY (or ANTHROPIC_FOUNDRY_API_KEY)",
                    sourcesChecked: canonicalSources
                )
            }
            let endpointRaw = nonEmpty(env["AZURE_AI_INFERENCE_ENDPOINT"])
                ?? nonEmpty(env["ANTHROPIC_FOUNDRY_ENDPOINT"])
            guard let raw = endpointRaw, let base = URL(string: raw) else {
                throw NtakkerError.missingRequiredConfig(
                    key: "AZURE_AI_INFERENCE_ENDPOINT (or ANTHROPIC_FOUNDRY_ENDPOINT)",
                    sourcesChecked: canonicalSources
                )
            }
            guard let model = nonEmpty(env["NTAKKER_ASK_MODEL"]) else {
                throw NtakkerError.missingRequiredConfig(
                    key: "NTAKKER_ASK_MODEL",
                    sourcesChecked: canonicalSources
                )
            }
            // Foundry exposes a fixed api-version param on its inference
            // endpoint. Use the documented default but allow override.
            let apiVersion = nonEmpty(env["AZURE_AI_INFERENCE_API_VERSION"]) ?? "2024-05-01-preview"
            return AskConfig(
                provider: provider, model: model, endpoint: base,
                apiKey: resolvedKey, azureAPIVersion: apiVersion, contextMinutes: contextMinutes
            )

        case .ollama:
            let base = URL(string: nonEmpty(env["OLLAMA_HOST"]) ?? "http://127.0.0.1:11434")!
            guard let model = nonEmpty(env["NTAKKER_ASK_MODEL"]) else {
                throw NtakkerError.missingRequiredConfig(
                    key: "NTAKKER_ASK_MODEL",
                    sourcesChecked: canonicalSources
                )
            }
            return AskConfig(
                provider: provider, model: model, endpoint: base,
                apiKey: nil, azureAPIVersion: nil, contextMinutes: contextMinutes
            )

        case .litellm:
            let baseRaw = nonEmpty(env["LITELLM_PROXY_URL"])
                ?? nonEmpty(env["LITELLM_API_BASE"])
            guard let raw = baseRaw, let base = URL(string: raw) else {
                throw NtakkerError.missingRequiredConfig(
                    key: "LITELLM_PROXY_URL (or LITELLM_API_BASE)",
                    sourcesChecked: canonicalSources
                )
            }
            guard let model = nonEmpty(env["NTAKKER_ASK_MODEL"]) else {
                throw NtakkerError.missingRequiredConfig(
                    key: "NTAKKER_ASK_MODEL",
                    sourcesChecked: canonicalSources
                )
            }
            return AskConfig(
                provider: provider, model: model, endpoint: base,
                apiKey: nonEmpty(env["LITELLM_API_KEY"]),
                azureAPIVersion: nil, contextMinutes: contextMinutes
            )

        case .mlx:
            let baseRaw = nonEmpty(env["MLX_BASE_URL"]) ?? "http://127.0.0.1:8080/v1"
            guard let base = URL(string: baseRaw) else {
                throw NtakkerError.invalidConfigValue(
                    key: "MLX_BASE_URL",
                    value: baseRaw,
                    expected: "absolute URL of the local MLX-LM server"
                )
            }
            guard let model = nonEmpty(env["NTAKKER_ASK_MODEL"]) else {
                throw NtakkerError.missingRequiredConfig(
                    key: "NTAKKER_ASK_MODEL",
                    sourcesChecked: canonicalSources
                )
            }
            return AskConfig(
                provider: provider, model: model, endpoint: base,
                apiKey: nil, azureAPIVersion: nil, contextMinutes: contextMinutes
            )
        }
    }

    // MARK: - Helpers

    private static func required(_ env: [String: String], _ key: String) throws -> String {
        guard let v = nonEmpty(env[key]) else {
            throw NtakkerError.missingRequiredConfig(key: key, sourcesChecked: canonicalSources)
        }
        return v
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
