// MacrecCore/Asking/AskPromptBuilder.swift — plan-015 Phase 4 (FR-IRQ-6).
// Build the system + user messages that go to the LLM provider:
//   * System prompt — locks the model to "answer briefly using the
//     transcript and your general knowledge; cite which it came from"
//     per FR-IRQ-6.
//   * User message — the captured transcript window (last N minutes,
//     interleaved by source + speaker) followed by the question.
//
// The window is selected by recency: the latest `contextMinutes` of
// transcript content relative to the LAST segment's timestamp. When the
// recording has produced fewer minutes than the requested window, the
// entire transcript is included.
//
// Payload is hard-capped to 32 KB UTF-8 (NFR-IRQ-Transcript-Context).
// Truncation is from the HEAD of the window (oldest segments dropped
// first) with a visible `… (truncated)` marker so the rendering layer
// can audit what was actually sent.

import Foundation

public enum AskPromptBuilder {

    /// Hard cap from NFR-IRQ-Transcript-Context.
    public static let maxTranscriptBytes: Int = 32 * 1024

    /// System prompt locked verbatim per FR-IRQ-6. Exposed so tests can
    /// assert on its content without depending on the build result.
    public static let systemPrompt: String = """
        You are an assistant helping the user during a live recording. \
        Answer briefly using (a) the transcript window provided below \
        and (b) your general knowledge. Cite which source each fact came \
        from inline — `(transcript)` for transcript-derived claims and \
        `(general knowledge)` otherwise. If the transcript window is \
        empty, say so explicitly and answer from general knowledge \
        alone. Prefer 1-3 sentence answers unless the user asks for more.
        """

    /// Result of `buildUserMessage` so the caller can record exactly
    /// which transcript window was sent (for the sidecar header line,
    /// FR-IRQ-15 / FR-IRQ-14).
    public struct BuiltPrompt: Sendable, Equatable {
        public let userMessage: String
        /// Wall-clock start of the included transcript window. `nil`
        /// when no transcript segments were eligible.
        public let windowStart: Date?
        /// Wall-clock end of the included transcript window. `nil`
        /// when no transcript segments were eligible.
        public let windowEnd: Date?
        /// Number of segments actually included in the user message.
        public let segmentsIncluded: Int
        /// True when the payload had to be truncated to fit
        /// `maxTranscriptBytes` (head-truncation, oldest first).
        public let truncated: Bool
    }

    /// Construct the user-message payload for the LLM.
    ///
    /// - Parameters:
    ///   - question: The user's typed question (trimmed by caller).
    ///   - segments: Live transcript segments from
    ///     `RecordingController.transcriptSegments`.
    ///   - contextMinutes: Window length in minutes (1...30).
    public static func buildUserMessage(
        question: String,
        segments: [TranscriptSegment],
        contextMinutes: Int
    ) -> BuiltPrompt {
        let trimmedQ = question.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Select the recency window.
        let windowed: [TranscriptSegment]
        if let lastTs = segments.last?.lastUpdated {
            let cutoff = lastTs.addingTimeInterval(-Double(contextMinutes) * 60.0)
            windowed = segments.filter { $0.lastUpdated >= cutoff }
        } else {
            windowed = []
        }

        // 2. Format each segment as `[mm:ss] (source/speaker) text`.
        let anchor = windowed.first?.timestamp ?? segments.last?.timestamp ?? Date()
        var lines: [String] = windowed.map { seg in
            let offset = seg.timestamp.timeIntervalSince(anchor)
            return formatLine(segment: seg, offsetSeconds: offset)
        }

        // 3. Head-truncate if over 32 KB.
        var truncated = false
        var assembled = lines.joined(separator: "\n")
        while assembled.utf8.count > maxTranscriptBytes && !lines.isEmpty {
            lines.removeFirst()
            truncated = true
            assembled = lines.joined(separator: "\n")
        }

        // 4. Assemble final user message.
        let transcriptBody: String
        if assembled.isEmpty {
            transcriptBody = "(transcript window is empty — no segments captured yet)"
        } else if truncated {
            transcriptBody = "… (truncated)\n" + assembled
        } else {
            transcriptBody = assembled
        }

        let userMessage = """
        Transcript window (last \(contextMinutes) min):
        \(transcriptBody)

        Question:
        \(trimmedQ)
        """

        return BuiltPrompt(
            userMessage: userMessage,
            windowStart: windowed.first?.timestamp,
            windowEnd: windowed.last?.lastUpdated,
            segmentsIncluded: windowed.count,
            truncated: truncated
        )
    }

    // MARK: - Helpers

    private static func formatLine(segment: TranscriptSegment, offsetSeconds: TimeInterval) -> String {
        let secs = Int(max(0, offsetSeconds))
        let mm = secs / 60
        let ss = secs % 60
        let ts = String(format: "[%02d:%02d]", mm, ss)
        let source: String = {
            switch segment.source {
            case .system:     return "system"
            case .microphone: return "mic"
            }
        }()
        let speaker = segment.speaker.map { " \($0)" } ?? ""
        return "\(ts) (\(source)\(speaker)) \(segment.text)"
    }
}
