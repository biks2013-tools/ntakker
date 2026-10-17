// NtakkerStudioKit/Transcript/TranscriptDocument.swift — plan-024 T3.
//
// One JSONL transcript, loaded into memory, with its lines placed on the
// audio timeline.
//
// Timing. ntakker stamps segments with wall-clock time, not audio
// position, so a line's place in the audio is
//
//     offset = timestamp − audioStart (+ the recording's sync nudge)
//
// where `audioStart` is when the first sample was recorded. Streaming
// providers stamp a final with the start of the utterance, so that is
// exact up to the start estimate. The batch pipeline stamps a segment
// when the provider's answer arrives, after the whole chunk was heard,
// so the chunk's duration is subtracted as well. Transcripts the studio
// writes itself use exact audio positions.

import Foundation
import NtakkerCore

/// A transcript line placed on the audio timeline.
public struct TranscriptEntry: Sendable, Identifiable, Equatable {
    public var id: UUID { segment.id }
    public let segment: TranscriptSegment
    /// Seconds from the start of the audio.
    public let start: Double
    public let end: Double
    /// The transcript file the line came from.
    public let transcriptURL: URL

    public init(segment: TranscriptSegment, start: Double, end: Double, transcriptURL: URL) {
        self.segment = segment
        self.start = start
        self.end = end
        self.transcriptURL = transcriptURL
    }
}

public enum SegmentTiming {
    /// Provider ids whose segment timestamps mark the start of speech.
    public static let streamingProviderIds: Set<String> = [
        "soniox", "apple", "apple-cloud", "azure-openai-realtime", "gemini-live",
    ]

    /// Where `segment` starts and ends in the audio, in seconds.
    public static func placement(
        of segment: TranscriptSegment,
        audioStart: Date,
        exact: Bool,
        syncOffsetSec: Double
    ) -> (start: Double, end: Double) {
        let duration = max(0, segment.durationSec ?? 0)
        var start = segment.timestamp.timeIntervalSince(audioStart)
        if !exact {
            if !streamingProviderIds.contains(segment.model ?? "") {
                start -= duration
            }
            start += syncOffsetSec
        }
        start = max(0, start)
        return (start, start + duration)
    }
}

public final class TranscriptDocument: @unchecked Sendable {
    public let file: TranscriptFile
    public private(set) var segments: [TranscriptSegment]
    public private(set) var isDirty = false

    public init(file: TranscriptFile, segments: [TranscriptSegment]) {
        self.file = file
        self.segments = segments
    }

    /// Load the JSONL at `file.url` (tombstones and rewrites resolved).
    public static func load(_ file: TranscriptFile) -> TranscriptDocument {
        TranscriptDocument(file: file, segments: JSONLTranscriptReader.read(from: file.url))
    }

    /// The lines placed on the timeline, in time order. Empty lines are
    /// dropped.
    public func entries(audioStart: Date, exact: Bool, syncOffsetSec: Double) -> [TranscriptEntry] {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { seg in
                let p = SegmentTiming.placement(of: seg, audioStart: audioStart, exact: exact, syncOffsetSec: syncOffsetSec)
                return TranscriptEntry(segment: seg, start: p.start, end: p.end, transcriptURL: file.url)
            }
            .sorted { $0.start < $1.start }
    }

    /// Replace a line's text. Returns false when the id is unknown.
    @discardableResult
    public func updateText(id: UUID, to text: String) -> Bool {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return false }
        guard segments[i].text != text else { return true }
        segments[i].text = text
        isDirty = true
        return true
    }

    /// Write the segments back to `file.url`. The first save keeps the
    /// untouched original as `<file>.orig`.
    public func save() throws {
        try Self.write(segments, to: file.url, keepingBackup: true)
        isDirty = false
    }

    /// Write `segments` as a JSONL transcript at `url`, replacing any
    /// file there atomically.
    public static func write(_ segments: [TranscriptSegment], to url: URL, keepingBackup: Bool = false) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let writer = try JSONLTranscriptWriter(url: temp)
        do {
            for seg in segments { try writer.appendSegment(seg) }
            try writer.close()
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("orig")
            if keepingBackup, !fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: url, to: backup)
            }
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }
}
