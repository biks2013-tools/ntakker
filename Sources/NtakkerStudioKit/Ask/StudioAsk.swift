// NtakkerStudioKit/Ask/StudioAsk.swift — plan-024 T5.
//
// Questions and minutes over a whole recording. Uses ntakker's Ask
// configuration (`NTAKKER_ASK_PROVIDER` & co. in
// `~/.tool-agents/ntakker/.env`, loaded into the process at launch) and
// its provider clients; only the prompts are the studio's own.
//
// The transcript goes in as `[hh:mm:ss] Speaker: text` lines, and the
// model is told to cite those timecodes, which the UI turns into links
// that seek the player.

import Foundation
import NtakkerCore

public struct AskExchange: Sendable, Equatable, Codable {
    public let question: String
    public let answer: String
    public let askedAt: Date

    public init(question: String, answer: String, askedAt: Date) {
        self.question = question
        self.answer = answer
        self.askedAt = askedAt
    }
}

public struct StudioAskStream: Sendable {
    public let tokens: AsyncThrowingStream<String, Error>
    public let provider: AskProvider
    public let model: String
}

public enum StudioAsk {

    /// Consecutive lines of one speaker closer than this are merged in
    /// the prompt, which keeps it shorter without losing anything.
    public static let mergeGapSeconds = 3.0
    /// Earlier exchanges included with a follow-up question.
    public static let historyLimit = 6

    public static let qaSystemPrompt = """
    You answer questions about one recorded conversation, using its transcript.
    Each transcript line starts with a timecode [hh:mm:ss] or [mm:ss], then the speaker.
    Rules:
    - Base every statement on the transcript. If it does not contain the answer, say so plainly.
    - Cite the moments you rely on with their timecodes, copied exactly as they appear, e.g. [12:34].
    - The transcript comes from speech recognition and may contain misheard words; read through them.
    - Answer in the language of the question. Be concise; use Markdown lists when they help.
    """

    public static let minutesSystemPrompt = """
    You write meeting minutes from the transcript of one recorded meeting.
    Each transcript line starts with a timecode [hh:mm:ss] or [mm:ss], then the speaker.
    Rules:
    - Use only what the transcript supports; never invent names, numbers, dates or decisions.
    - Cite the moment each item comes from with its timecode, copied exactly, e.g. [12:34].
    - The transcript comes from speech recognition and may contain misheard words; read through them.
    - Output Markdown only, with no preamble.
    """

    /// The minutes request, in the user turn.
    public static func minutesInstruction(language: String?) -> String {
        let lang = language.map { "Write the minutes in \($0)." }
            ?? "Write the minutes in the language mostly spoken in the transcript."
        return """
        Write the minutes of this meeting with these sections:
        # <a short title>
        **Date:** … · **Length:** … · **Participants:** …
        ## Summary — 3 to 6 sentences.
        ## Topics discussed — one bullet per topic, with timecodes.
        ## Decisions — each with its timecode; "None recorded" if there are none.
        ## Action items — "- [ ] owner — task — due date if stated [timecode]"; "None recorded" if there are none.
        ## Open questions — unresolved points, with timecodes.
        \(lang)
        """
    }

    /// `[hh:mm:ss]` for a recording longer than an hour, else `[mm:ss]`.
    public static func timecode(_ seconds: Double, longForm: Bool) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return longForm
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m + h * 60, s)
    }

    /// The transcript as prompt text.
    public static func transcriptText(
        entries: [TranscriptEntry],
        metadata: StudioMetadata,
        duration: Double
    ) -> String {
        let long = duration >= 3600
        var lines: [String] = []
        var current: (start: Double, end: Double, who: String, text: String)?
        func flush() {
            if let c = current { lines.append("[\(timecode(c.start, longForm: long))] \(c.who): \(c.text)") }
        }
        for e in entries {
            let who = speakerLabel(e.segment, metadata: metadata)
            let text = e.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if var c = current, c.who == who, e.start - c.end <= mergeGapSeconds {
                c.text += " " + text
                c.end = max(c.end, e.end)
                current = c
            } else {
                flush()
                current = (e.start, max(e.start, e.end), who, text)
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// Speaker name, else the source ("Microphone" / "System audio").
    public static func speakerLabel(_ segment: TranscriptSegment, metadata: StudioMetadata) -> String {
        if let name = metadata.speakerName(for: segment.speaker) { return name }
        return segment.source == .microphone ? "Microphone" : "System audio"
    }

    static func header(recordingName: String, recordedAt: Date, duration: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return "Recording: \(recordingName)\nRecorded: \(f.string(from: recordedAt))\nLength: \(timecode(duration, longForm: true))"
    }

    // MARK: - Requests

    /// Ask a question. `history` is the earlier exchanges of this session.
    public static func ask(
        question: String,
        transcript: String,
        recordingName: String,
        recordedAt: Date,
        duration: Double,
        history: [AskExchange],
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> StudioAskStream {
        let config = try AskConfigResolver.resolve(env: env)
        var user = header(recordingName: recordingName, recordedAt: recordedAt, duration: duration)
        user += "\n\n<transcript>\n\(transcript)\n</transcript>\n"
        let earlier = history.suffix(historyLimit)
        if !earlier.isEmpty {
            user += "\nEarlier questions in this session:\n"
            for x in earlier { user += "Q: \(x.question)\nA: \(x.answer)\n\n" }
        }
        user += "\nQuestion: \(question.trimmingCharacters(in: .whitespacesAndNewlines))"
        let client = AskClientFactory.make(config: config)
        return StudioAskStream(
            tokens: client.streamChat(system: qaSystemPrompt, user: user),
            provider: config.provider, model: config.model
        )
    }

    /// Generate minutes.
    public static func minutes(
        transcript: String,
        recordingName: String,
        recordedAt: Date,
        duration: Double,
        language: String?,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> StudioAskStream {
        let config = try AskConfigResolver.resolve(env: env)
        var user = header(recordingName: recordingName, recordedAt: recordedAt, duration: duration)
        user += "\n\n<transcript>\n\(transcript)\n</transcript>\n\n"
        user += minutesInstruction(language: language)
        let client = AskClientFactory.make(config: config)
        return StudioAskStream(
            tokens: client.streamChat(system: minutesSystemPrompt, user: user),
            provider: config.provider, model: config.model
        )
    }
}

/// Saving what Ask and minutes produced, next to the recording.
public enum StudioNotes {

    /// Append one exchange to `<stem>.studio-qa.md`.
    public static func appendExchange(_ x: AskExchange, provider: String, model: String, to url: URL) throws {
        let f = ISO8601DateFormatter()
        var text = ""
        if !FileManager.default.fileExists(atPath: url.path) {
            text += "# Questions\n\n"
        }
        text += "## \(x.question)\n\n_\(f.string(from: x.askedAt)) · \(provider) · \(model)_\n\n\(x.answer)\n\n---\n\n"
        try append(text, to: url)
    }

    /// Write `<stem>.minutes.md`, replacing an earlier version.
    public static func writeMinutes(_ markdown: String, provider: String, model: String, generatedAt: Date, to url: URL) throws {
        let f = ISO8601DateFormatter()
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n---\n_Generated by ntakker studio · \(provider) · \(model) · \(f.string(from: generatedAt))_\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func append(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
