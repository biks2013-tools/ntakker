// NtakkerCore/Transcription/Persistence/SRTTranscriptWriter.swift
//
// Phase F (plan-004 §"Phase F — Sidecar writers", Task F.5) — SubRip
// (`.srt`) sidecar writer with id-keyed in-place rewrite.
//
// Cue format:
//
//     <seq>
//     hh:mm:ss,fff --> hh:mm:ss,fff
//     <source>: <text>
//                                       ← blank line terminator
//
// Same in-place rewrite model as the JSONL writer (see file comment
// there): short-grow rewrites pad with spaces; long-grow rewrites
// tombstone the old cue with a same-length placeholder body
// `[updated]` (and a 00:00:00 → 00:00:00 timing) and append the new
// rendering at EOF.
//
// Sequence numbers are stable: the cue number assigned at
// `appendSegment(_:)` time is reused for every later
// `updateSegment(_:)`, so a SRT-aware viewer that trusts the number
// keeps its index intact across rewrites.

import Foundation

/// SubRip-format sidecar writer.
public final class SRTTranscriptWriter: TranscriptFormatWriter {

    public var url: URL { file.url }
    private let file: RewritableSegmentFile
    private var sequenceCounter: Int = 0
    private var sequenceForId: [UUID: Int] = [:]
    private let sessionStart: Date

    public init(url: URL,
                sessionStart: Date = Date()) throws {
        self.sessionStart = sessionStart
        self.file = try RewritableSegmentFile(url: url)
    }

    public func appendSegment(_ segment: TranscriptSegment) throws {
        sequenceCounter += 1
        sequenceForId[segment.id] = sequenceCounter
        try file.append(Data(render(seq: sequenceCounter, segment).utf8), for: segment.id)
    }

    public func updateSegment(_ segment: TranscriptSegment) throws {
        guard let seq = sequenceForId[segment.id] else {
            try appendSegment(segment)
            return
        }
        // Padding goes inside the cue body, before the "\n\n"
        // terminator, so cue boundaries stay intact. Long-grow
        // tombstone: the same cue number with a 0 → 0 timing and an
        // `[updated]` body, padded to the old cue's length.
        let terminator = Data([0x0A, 0x0A])
        let rewritten = try file.rewrite(Data(render(seq: seq, segment).utf8), for: segment.id, terminator: terminator) { length in
            RewritableSegmentFile.pad(
                Data("\(seq)\n\(Self.srtTime(0)) --> \(Self.srtTime(0))\n[updated]".utf8),
                to: length, terminator: terminator)
        }
        if !rewritten { try appendSegment(segment) }
    }

    public func close() throws {
        try file.close()
    }

    // MARK: - Rendering

    /// Render a SubRip cue.
    ///
    /// Plan-005 Phase F adds an optional `[lang]` tag derived from the
    /// segment's BCP-47 `language` (e.g. `"en-US"` → `[en]`). The tag
    /// is injected between the source label and the cue text:
    ///
    ///     1
    ///     00:00:01,000 --> 00:00:03,500
    ///     mic [en]: hello world
    ///
    /// When `segment.language` is `nil` (single-locale sessions and the
    /// batch pipeline) no prefix is emitted — preserving the
    /// pre-Phase-F SRT layout.
    ///
    /// Plan-012 Phase A7 — when the segment carries a non-nil
    /// `speaker` (Soniox diarization is on), the cue text is prefixed
    /// with `S<N>: ` (label resolved via `SpeakerSidecarLabel.label(for:)`).
    /// When `speaker` is `nil` every legacy code path is taken textually
    /// unchanged so pre-A7 SRT fixtures stay byte-equivalent.
    private func render(seq: Int, _ segment: TranscriptSegment) -> String {
        let start = segment.timestamp.timeIntervalSince(sessionStart)
        let end = segment.lastUpdated.timeIntervalSince(sessionStart)
        let speakerLabel = SpeakerSidecarLabel.label(for: segment.speaker)
        let langTag = segment.language.map { " [\(Self.shortTag($0))]" } ?? ""
        let body: String
        if let speakerLabel {
            body = "\(segment.source.rawValue)\(langTag): \(speakerLabel): \(segment.text)"
        } else {
            body = "\(segment.source.rawValue)\(langTag): \(segment.text)"
        }
        return "\(seq)\n\(Self.srtTime(start)) --> \(Self.srtTime(end))\n\(body)\n\n"
    }

    /// `"en-US"` → `"en"`, `"el-GR"` → `"el"`. See TXT writer for rationale.
    private static func shortTag(_ bcp47: String) -> String {
        if let dash = bcp47.firstIndex(of: "-") {
            return String(bcp47[..<dash])
        }
        return bcp47
    }

    /// `hh:mm:ss,fff` (SRT — comma decimal separator).
    private static func srtTime(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
