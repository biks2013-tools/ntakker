// MacrecCore/Transcription/Persistence/VTTTranscriptWriter.swift
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

    public let url: URL
    private let handle: FileHandle
    private var index: [UUID: Range<UInt64>] = [:]
    private let sessionStart: Date
    private var headerWritten = false

    public init(url: URL,
                sessionStart: Date = Date()) throws {
        self.url = url
        self.sessionStart = sessionStart
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    public func appendSegment(_ segment: TranscriptSegment) throws {
        try ensureHeader()
        let bytes = Data(render(segment).utf8)
        let start = try handle.offset()
        try handle.write(contentsOf: bytes)
        let end = try handle.offset()
        index[segment.id] = start..<end
    }

    public func updateSegment(_ segment: TranscriptSegment) throws {
        guard let range = index[segment.id] else {
            try appendSegment(segment)
            return
        }
        let oldLen = Int(range.upperBound - range.lowerBound)
        let newRendering = render(segment)
        let newBytes = Data(newRendering.utf8)

        if newBytes.count <= oldLen {
            // Short-grow — pad inside the cue body before the trailing
            // "\n\n" so the cue boundaries stay intact.
            var padded = Data(newRendering.dropLast(2).utf8)
            padded.append(Data(repeating: 0x20, count: oldLen - newBytes.count))
            padded.append(contentsOf: [0x0A, 0x0A])
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: padded)
            try handle.seekToEnd()
        } else {
            // Long-grow — tombstone old cue with a placeholder body of
            // matching length, append the new cue at EOF.
            let tombHead = "\(Self.vttTime(0)) --> \(Self.vttTime(0))\n[updated]"
            var tomb = Data(tombHead.utf8)
            if tomb.count + 2 < oldLen {
                tomb.append(Data(repeating: 0x20, count: oldLen - tomb.count - 2))
            }
            tomb.append(contentsOf: [0x0A, 0x0A])
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: tomb)
            try handle.seekToEnd()
            let start = try handle.offset()
            try handle.write(contentsOf: newBytes)
            let end = try handle.offset()
            index[segment.id] = start..<end
        }
    }

    public func close() throws {
        // FR-corner-case: a session that produced no segments would
        // otherwise leave a zero-byte sidecar. Write the header anyway
        // so the file is a valid (empty-cue-list) WebVTT document.
        try ensureHeader()
        try handle.close()
    }

    // MARK: - Helpers

    private func ensureHeader() throws {
        if !headerWritten {
            try handle.write(contentsOf: Data("WEBVTT\n\n".utf8))
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
