// NtakkerCore/Asking/AskProvider.swift — plan-015 Phase 4 (FR-IRQ-6,
// FR-IRQ-7). Vendor-canonical identifier surface for the LLM provider
// driving the in-recording Q&A feature. The eight supported providers
// mirror the `convo-coach` TypeScript tool exactly so the user's
// existing `~/.tool-agents/ntakker/.env` keys are reused verbatim.
//
// The enum's `rawValue` is the on-the-wire env-var value of
// `NTAKKER_ASK_PROVIDER`; the matching legacy aliases are accepted in
// `init?(envValue:)` so users carrying older configs keep working.

import Foundation

/// The eight standard LLM providers ntakker-cli's Q&A surface can target.
public enum AskProvider: String, CaseIterable, Sendable, Hashable, Identifiable {
    public var id: String { rawValue }

    case openai
    case anthropic
    case google
    case azureOpenAI       = "azure-openai"
    case azureAIInference  = "azure-ai-inference"
    case ollama
    case litellm
    case mlx

    /// Parse the user-facing string (typically the `NTAKKER_ASK_PROVIDER`
    /// env value) into an `AskProvider`. Lowercases first and accepts
    /// the small set of legacy aliases used by `convo-coach`.
    public init?(envValue raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "openai":                                                    self = .openai
        case "anthropic", "claude":                                       self = .anthropic
        case "google", "gemini":                                          self = .google
        case "azure-openai", "azure_openai", "azure":                     self = .azureOpenAI
        case "azure-ai-inference", "azure_ai_inference", "foundry":       self = .azureAIInference
        case "ollama":                                                    self = .ollama
        case "litellm":                                                   self = .litellm
        case "mlx", "mlx-lm":                                             self = .mlx
        default:                                                          return nil
        }
    }

    /// Human-readable display name used by the privacy disclosure sheet
    /// and the inline-error pane.
    public var displayName: String {
        switch self {
        case .openai:           return "OpenAI"
        case .anthropic:        return "Anthropic"
        case .google:           return "Google Gemini"
        case .azureOpenAI:      return "Azure OpenAI"
        case .azureAIInference: return "Azure AI Foundry"
        case .ollama:           return "Ollama (local)"
        case .litellm:          return "LiteLLM proxy"
        case .mlx:              return "MLX (local)"
        }
    }

    /// Whether sending data to this provider crosses the local boundary.
    /// Used by `FR-IRQ-18` to decide if the first-cloud-call disclosure
    /// sheet must be shown. Per the requirements doc, Ollama and MLX
    /// are local-only by construction; LiteLLM is treated as cloud
    /// because its proxy can target either local or remote backends and
    /// we cannot prove which from configuration alone.
    public var isCloud: Bool {
        switch self {
        case .ollama, .mlx: return false
        default:            return true
        }
    }
}
