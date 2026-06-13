// NtakkerCore/Asking/AskService.swift — plan-015 Phase 4.
// Public entry point the UI calls to ask a question.
//
// Hides the three-step pipeline from the UI:
//   1. Resolve `AskConfig` from the process env  (FR-IRQ-7)
//   2. Build the system + user prompts from the live transcript window
//      (FR-IRQ-6)
//   3. Stream the answer back via the right provider client (FR-IRQ-8)
//
// Errors from step 1 (`NtakkerError.missingRequiredConfig`,
// `.invalidConfigValue`) and step 3 (HTTP / network failures) bubble
// out the same `AsyncThrowingStream` so the UI's error surface only
// has one code path to handle (FR-IRQ-19).

import Foundation

/// Metadata describing the prompt that was actually sent. Captured so
/// the UI can persist a sidecar entry matching FR-IRQ-14.
public struct AskRequestMetadata: Sendable {
    public let provider: AskProvider
    public let model: String
    public let windowStart: Date?
    public let windowEnd: Date?
    public let contextMinutes: Int
}

/// Result of an `AskService.ask(...)` invocation. The caller iterates
/// `tokens` to receive incremental deltas; once the stream completes,
/// `metadata` is the same value that was emitted on first token.
public struct AskAnswerStream: Sendable {
    public let tokens: AsyncThrowingStream<String, Error>
    public let metadata: AskRequestMetadata
}

public enum AskService {

    /// Ask a question against the live transcript. Returns an
    /// `AskAnswerStream` whose `tokens` stream yields incremental
    /// deltas, or throws synchronously when the configuration is
    /// invalid.
    ///
    /// - Parameters:
    ///   - question: The user's typed question (will be trimmed).
    ///   - transcriptSegments: Live transcript segments to use as
    ///     prompt context. Empty arrays are valid — the model answers
    ///     from general knowledge only and is told so by the system
    ///     prompt.
    public static func ask(
        question: String,
        transcriptSegments: [TranscriptSegment],
        window: AskContextWindow? = nil
    ) throws -> AskAnswerStream {
        let config = try AskConfigResolver.resolve()
        // If the caller did not supply an explicit window, fall back to
        // the env-derived `contextMinutes` value so existing flows keep
        // their behaviour. Per-question overrides land via the popover's
        // Asking-pane picker.
        let effectiveWindow: AskContextWindow = window ?? .minutes(config.contextMinutes)
        let prompt = AskPromptBuilder.buildUserMessage(
            question: question,
            segments: transcriptSegments,
            window: effectiveWindow
        )
        let client = AskClientFactory.make(config: config)
        let stream = client.streamChat(
            system: AskPromptBuilder.systemPrompt,
            user: prompt.userMessage
        )
        return AskAnswerStream(
            tokens: stream,
            metadata: AskRequestMetadata(
                provider: config.provider,
                model: config.model,
                windowStart: prompt.windowStart,
                windowEnd: prompt.windowEnd,
                contextMinutes: effectiveWindow.legacyContextMinutes
            )
        )
    }
}
