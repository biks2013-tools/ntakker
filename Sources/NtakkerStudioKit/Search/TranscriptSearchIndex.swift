// NtakkerStudioKit/Search/TranscriptSearchIndex.swift — plan-024 T6.
//
// Full-text search over every transcript in the library. Lines are
// folded (case and diacritics, so "συμφωνία" finds "Συμφωνια") once at
// index time; a query matches a line that contains every query word.
// Transcripts are re-read only when their modification date changes.

import Foundation
import NtakkerCore

public struct SearchHit: Sendable, Identifiable, Equatable {
    public var id: String { "\(transcriptURL.path)#\(segmentID)" }
    public let recordingID: String
    public let recordingName: String
    public let recordedAt: Date
    public let transcriptURL: URL
    public let segmentID: UUID
    /// Seconds from the start of the audio.
    public let start: Double
    public let speaker: String
    public let text: String
}

public actor TranscriptSearchIndex {

    struct Line: Sendable {
        let segmentID: UUID
        let start: Double
        let speaker: String
        let text: String
        let folded: String
    }

    struct Indexed: Sendable {
        let modified: Date
        let recordingID: String
        let recordingName: String
        let recordedAt: Date
        let lines: [Line]
    }

    private var byTranscript: [URL: Indexed] = [:]

    public init() {}

    public var lineCount: Int { byTranscript.values.reduce(0) { $0 + $1.lines.count } }

    /// Bring the index in line with `recordings`: new and changed
    /// transcripts are read, removed ones dropped.
    public func update(with recordings: [Recording]) {
        var seen: Set<URL> = []
        for rec in recordings {
            let meta = (try? StudioMetadata.load(from: rec.metadataURL)) ?? StudioMetadata()
            let audioStart = meta.audioStart ?? rec.createdAt
            for t in rec.transcripts {
                seen.insert(t.url)
                let modified = (try? t.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let existing = byTranscript[t.url], existing.modified == modified { continue }
                let exact = meta.exactTimingTranscripts.contains(t.url.lastPathComponent)
                let entries = TranscriptDocument.load(t).entries(audioStart: audioStart, exact: exact, syncOffsetSec: meta.syncOffsetSec)
                let lines = entries.map { e in
                    Line(
                        segmentID: e.segment.id,
                        start: e.start,
                        speaker: StudioAsk.speakerLabel(e.segment, metadata: meta),
                        text: e.segment.text,
                        folded: Self.fold(e.segment.text)
                    )
                }
                byTranscript[t.url] = Indexed(
                    modified: modified, recordingID: rec.id, recordingName: rec.displayName,
                    recordedAt: rec.createdAt, lines: lines
                )
            }
        }
        for url in byTranscript.keys where !seen.contains(url) { byTranscript[url] = nil }
    }

    /// Lines containing every word of `query`, newest recording first,
    /// in time order within a recording.
    public func search(_ query: String, limit: Int = 500) -> [SearchHit] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        let sorted = byTranscript.sorted {
            $0.value.recordedAt != $1.value.recordedAt
                ? $0.value.recordedAt > $1.value.recordedAt
                : $0.key.path < $1.key.path
        }
        for (url, idx) in sorted {
            for line in idx.lines where words.allSatisfy({ line.folded.contains($0) }) {
                hits.append(SearchHit(
                    recordingID: idx.recordingID, recordingName: idx.recordingName,
                    recordedAt: idx.recordedAt, transcriptURL: url, segmentID: line.segmentID,
                    start: line.start, speaker: line.speaker, text: line.text
                ))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Case- and diacritic-insensitive form used for matching.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
