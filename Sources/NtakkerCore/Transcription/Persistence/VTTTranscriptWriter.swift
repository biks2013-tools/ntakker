// NtakkerCore/Transcription/Persistence/VTTTranscriptWriter.swift
//
// Phase F (plan-004 §"Phase F — Sidecar writers", Task F.6) — WebVTT
// (`.vtt`) sidecar writer with id-keyed in-place rewrite.
//
// Same model as the SRT writer but with two spec differences:
//
//   * The file MUST start with the literal `WEBVTT\n\n` header. The
//     header is written eagerly on the first append (also written
//     eagerly inside `init` would be equivalent given that the actor
//     truncates the file before the writer opens it; we keep the
//     header-on-first-append semantics for parity with the SRT writer
//     and so the byte index records valid segment ranges from offset
//     `headerLen` rather than offset 0).
//   * Cue timestamps use `.` (period) as the decimal separator instead
//     of `,` (comma).
//   * Cue identifiers are omitted in v1 — the cue is just the timing
//     line + the body line + a blank line terminator.

import Foundation

/// WebVTT-format sidecar writer.
public final class VTTTranscriptWriter: TranscriptFormatWriter {

    public var url: URL { file.url }
    private let file: RewritableSegmentFile
    private let sessionStart: Date
    private var headerWritten = false

    public init(url: URL,
                sessionStart: Date = Date()) throws {
        self.sessionStart = sessionStart
        self.file = try RewritableSegmentFile(url: url)
    }

    public func appendSegment(_ segment: TranscriptSegment) throws {
        try ensureHeader()
        try file.append(Data(render(segment).utf8), for: segment.id)
    }

    public func updateSegment(_ segment: TranscriptSegment) throws {
        // Same padding and tombstone model as the SRT writer, without
        // the cue number.
        let terminator = Data([0x0A, 0x0A])
        let rewritten = try file.rewrite(Data(render(segment).utf8), for: segment.id, terminator: terminator) { length in
            RewritableSegmentFile.pad(
                Data("\(Self.vttTime(0)) --> \(Self.vttTime(0))\n[updated]".utf8),
                to: length, terminator: terminator)
        }
        if !rewritten { try appendSegment(segment) }
    }

    public func close() throws {
        // FR-corner-case: a session that produced no segments would
        // otherwise leave a zero-byte sidecar. Write the header anyway
        // so the file is a valid (empty-cue-list) WebVTT document.
        try ensureHeader()
        try file.close()
    }

    // MARK: - Helpers

    private func ensureHeader() throws {
        if !headerWritten {
            try file.writeUnindexed(Data("WEBVTT\n\n".utf8))
            headerWritten = true
        }
    }

    /// Render one WebVTT cue.
    ///
    /// Plan-005 Phase F adds an optional `[lang]` tag derived from the
    /// segment's BCP-47 `language` (e.g. `"en-US"` → `[en]`). The tag
    /// is injected between the source label and the cue text:
    ///
    ///     00:00:01.000 --> 00:00:03.500
    ///     mic [en]: hello world
    ///
    /// When `segment.language` is `nil` (single-locale sessions and the
    /// batch pipeline) no prefix is emitted — preserving the
    /// pre-Phase-F WebVTT layout.
    ///
    /// Plan-012 Phase A7 — when the segment carries a non-nil
    /// `speaker` (Soniox diarization is on), the cue text is wrapped
    /// in WebVTT voice tags `<v S<N>>...</v>` (label resolved via
    /// `SpeakerSidecarLabel.label(for:)`). When `speaker` is `nil`
    /// every legacy code path is taken textually unchanged so pre-A7
    /// VTT fixtures stay byte-equivalent.
    private func render(_ segment: TranscriptSegment) -> String {
        let start = segment.timestamp.timeIntervalSince(sessionStart)
        let end = segment.lastUpdated.timeIntervalSince(sessionStart)
        let speakerLabel = SpeakerSidecarLabel.label(for: segment.speaker)
        let langTag = segment.language.map { " [\(Self.shortTag($0))]" } ?? ""
        let body: String
        if let speakerLabel {
            body = "\(segment.source.rawValue)\(langTag): <v \(speakerLabel)>\(segment.text)</v>"
        } else {
            body = "\(segment.source.rawValue)\(langTag): \(segment.text)"
        }
        return "\(Self.vttTime(start)) --> \(Self.vttTime(end))\n\(body)\n\n"
    }

    /// `"en-US"` → `"en"`, `"el-GR"` → `"el"`. See TXT writer for rationale.
    private static func shortTag(_ bcp47: String) -> String {
        if let dash = bcp47.firstIndex(of: "-") {
            return String(bcp47[..<dash])
        }
        return bcp47
    }

    /// `hh:mm:ss.fff` (VTT — period decimal separator).
    private static func vttTime(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
