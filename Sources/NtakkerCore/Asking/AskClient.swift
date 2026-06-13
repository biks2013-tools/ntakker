// NtakkerCore/Asking/AskClient.swift — plan-015 Phase 4 (FR-IRQ-6,
// FR-IRQ-8). Streaming-chat protocol surface implemented by the three
// provider-family clients (OpenAI-compatible / Anthropic / Gemini).
//
// The protocol intentionally returns an `AsyncThrowingStream<String, Error>`
// of *raw token deltas* — not whole answers. The UI accumulates the
// stream into a single answer string in `AskingSessionStore`, which
// gives the in-progress "streaming…" indicator something to react to
// (FR-IRQ-8) without forcing a richer event surface on every provider.

import Foundation

/// Streaming-chat client. One concrete implementation per provider family.
public protocol AskClient: Sendable {
    /// Stream a chat completion. The returned stream yields incremental
    /// text deltas — concatenate them in order to obtain the full
    /// answer. The stream terminates normally on `[DONE]` / end-of-body
    /// and throws on HTTP-error / parse-error / network failure.
    func streamChat(
        system: String,
        user: String
    ) -> AsyncThrowingStream<String, Error>
}

/// Wire shape for the JSON `{ "role": ..., "content": ... }` field used
/// across all three provider families' chat endpoints. The OpenAI and
/// Foundry-style endpoints accept this exact shape; Anthropic strips
/// the system role into a top-level field; Gemini renames "user" to
/// "user" and "assistant" to "model" but the wire is otherwise similar.
struct AskChatMessage: Encodable {
    let role: String
    let content: String
}
