// MacrecCore/Asking/QASessionSidecar.swift — plan-015 Phase 4
// (FR-IRQ-14, FR-IRQ-15). Writes a `<basename>.questions.jsonl` file
// next to the audio when the session stops:
//
//   1. First line — header object cross-referencing the transcript
//      sidecar (FR-IRQ-15) and recording the schema version.
//   2. Subsequent lines — one JSON object per Q&A exchange.
//
// Persistence failures MUST NOT block session stop — the writer
// returns an `Error` to the caller instead of throwing into the
// recording lifecycle (FR-IRQ-14).

import Foundation

/// One Q&A exchange in the on-disk JSONL sidecar. Shape locked by
/// FR-IRQ-14.
public struct QASidecarEntry: Codable, Sendable {
    public let ts_recording_ms: Int
    public let ts_wall: String
    public let question: String
    public let answer: String
    public let model: String
    public let provider: String
    public let transcript_window_start_ms: Int?
    public let transcript_window_end_ms: Int?

    public init(
        recordingMs: Int,
        wallClock: Date,
        question: String,
        answer: String,
        model: String,
        provider: String,
        windowStart: Date?,
        windowEnd: Date?
    ) {
        self.ts_recording_ms = recordingMs
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.ts_wall = iso.string(from: wallClock)
        self.question = question
        self.answer = answer
        self.model = model
        self.provider = provider
        self.transcript_window_start_ms = windowStart.map { Int($0.timeIntervalSince1970 * 1000) }
        self.transcript_window_end_ms   = windowEnd  .map { Int($0.timeIntervalSince1970 * 1000) }
    }
}

/// JSONL header line (FR-IRQ-15). Marked with `schema:"qa-sidecar/v1"`
/// so downstream tooling can recognise it.
private struct QASidecarHeader: Codable {
    let schema: String
    let transcript_sidecar: String?
    let recording_basename: String
    let written_at: String
}

public enum QASessionSidecar {

    /// Write a complete sidecar to `<audioURL>.questions.jsonl` (i.e.
    /// `recording-001.m4a` → `recording-001.m4a.questions.jsonl`).
    ///
    /// Conventional sidecar siblings (the transcript sidecar) are
    /// detected from the same directory using the same basename so the
    /// header line can cross-reference them.
    ///
    /// Returns `nil` on success, an `Error` on failure — never throws
    /// into the session lifecycle.
    public static func write(
        audioURL: URL,
        entries: [QASidecarEntry]
    ) -> Error? {
        guard !entries.isEmpty else { return nil }

        let basename = audioURL.lastPathComponent
        let outURL = audioURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(basename).questions.jsonl")

        let header = QASidecarHeader(
            schema: "qa-sidecar/v1",
            transcript_sidecar: detectTranscriptSidecar(audioURL: audioURL),
            recording_basename: basename,
            written_at: iso8601(Date())
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]

            var data = Data()
            data.append(try encoder.encode(header))
            data.append(0x0A) // \n
            for entry in entries {
                data.append(try encoder.encode(entry))
                data.append(0x0A)
            }

            // Atomic temp + rename per project convention.
            let tmpURL = outURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: [.atomic])
            try? FileManager.default.removeItem(at: outURL)
            try FileManager.default.moveItem(at: tmpURL, to: outURL)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Helpers

    /// Look for the most likely transcript sidecar next to the audio
    /// file. Returns a path RELATIVE to the audio file's directory so
    /// the cross-reference stays portable when the user moves the
    /// whole session folder. `nil` when no sibling is present.
    private static func detectTranscriptSidecar(audioURL: URL) -> String? {
        let dir = audioURL.deletingLastPathComponent()
        let basename = audioURL.lastPathComponent
        let candidates = [
            "\(basename).transcript.jsonl",
            "\(basename).transcript.txt",
            "\(basename).transcript.srt",
            "\(basename).transcript.vtt",
            "\(basename).system.transcript.jsonl",
            "\(basename).microphone.transcript.jsonl",
        ]
        for name in candidates {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return name
            }
        }
        return nil
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
