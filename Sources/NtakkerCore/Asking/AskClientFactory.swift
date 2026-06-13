// NtakkerCore/Asking/AskClientFactory.swift — plan-015 Phase 4.
// Pick the right concrete `AskClient` implementation for the resolved
// `AskConfig.provider`. Centralised so `AskService` (and any future
// caller — e.g. the floating Ask overlay in Phase 5) can dispatch in a
// single line.

import Foundation

public enum AskClientFactory {

    /// Build a streaming chat client for the resolved config. The
    /// concrete type is internal to NtakkerCore so callers never see
    /// the provider-family distinction.
    public static func make(config: AskConfig, urlSession: URLSession = .shared) -> AskClient {
        switch config.provider {
        case .openai, .azureOpenAI, .azureAIInference, .ollama, .litellm, .mlx:
            return OpenAICompatibleAskClient(config: config, urlSession: urlSession)
        case .anthropic:
            return AnthropicAskClient(config: config, urlSession: urlSession)
        case .google:
            return GoogleGeminiAskClient(config: config, urlSession: urlSession)
        }
    }
}
