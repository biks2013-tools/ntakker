// NtakkerCore/Transcription/Persistence/TXTTranscriptWriter.swift
//
// Phase F (plan-004 §"Phase F — Sidecar writers", Task F.4) — plain
// text sidecar writer with id-keyed in-place rewrite.
//
// Format: one line per segment, shaped as:
//
//     [HH:MM:SS] source: text
//
// Same in-place rewrite model as the JSONL writer (see file comment
// there): short-grow rewrites pad with spaces; long-grow rewrites
// tombstone the old slot with a blank line of matching length and
// append the new rendering at EOF.

import Foundation

/// Plain-text sidecar writer.
public final class TXTTranscriptWriter: TranscriptFormatWriter {

    public var url: URL { file.url }
    private let file: RewritableSegmentFile

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public init(url: URL) throws {
        self.file = try RewritableSegmentFile(url: url)
    }

    public func appendSegment(_ segment: TranscriptSegment) throws {
        try file.append(Data(render(segment).utf8), for: segment.id)
    }

    public func updateSegment(_ segment: TranscriptSegment) throws {
        // Long-grow tombstone: a blank line of matching length.
        let rewritten = try file.rewrite(Data(render(segment).utf8), for: segment.id, terminator: Data([0x0A])) { length in
            RewritableSegmentFile.pad(Data(), to: length, terminator: Data([0x0A]))
        }
        if !rewritten { try appendSegment(segment) }
    }

    public func close() throws {
        try file.close()
    }

    // MARK: - Rendering

    /// Render a segment as one TXT line.
    ///
    /// Plan-005 Phase F adds an optional `[lang]` tag derived from the
    /// segment's BCP-47 `language` (e.g. `"en-US"` → `[en]`). The tag
    /// is injected between the source and the colon, so a multilingual
    /// utterance from the microphone reads:
    ///
    ///     [12:34:56] mic [en]: hello world
    ///
    /// When `segment.language` is `nil` (single-locale sessions and the
    /// batch pipeline) the prefix is omitted entirely — no empty
    /// `[]` is emitted — preserving the pre-Phase-F format.
    ///
    /// Plan-012 Phase A7 — when the segment carries a non-nil
    /// `speaker` (Soniox diarization is on), an extra `[S<N>]` tag is
    /// inserted using `SpeakerSidecarLabel.label(for:)` between the
    /// language tag and the colon. When `speaker` is `nil` every legacy
    /// code path is taken textually unchanged so existing snapshot
    /// fixtures stay byte-equivalent.
    private func render(_ segment: TranscriptSegment) -> String {
        let ts = Self.timeFormatter.string(from: segment.timestamp)
        let speakerLabel = SpeakerSidecarLabel.label(for: segment.speaker)
        let langTag = segment.language.map { " [\(Self.shortTag($0))]" } ?? ""
        if let speakerLabel {
            return "[\(ts)] \(segment.source.rawValue)\(langTag) [\(speakerLabel)]: \(segment.text)\n"
        }
        return "[\(ts)] \(segment.source.rawValue)\(langTag): \(segment.text)\n"
    }

    /// `"en-US"` → `"en"`, `"el-GR"` → `"el"`. Keeps the BCP-47 primary
    /// language subtag for compactness; consumers that need the region
    /// tag can read the JSONL sidecar instead.
    private static func shortTag(_ bcp47: String) -> String {
        if let dash = bcp47.firstIndex(of: "-") {
            return String(bcp47[..<dash])
        }
        return bcp47
    }
}
