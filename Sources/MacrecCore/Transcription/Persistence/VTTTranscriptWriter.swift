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
import Logging

/// WebVTT-format sidecar writer.
public final class VTTTranscriptWriter: TranscriptFormatWriter {

    public let url: URL
    private let handle: FileHandle
    private var index: [UUID: Range<UInt64>] = [:]
    private let sessionStart: Date
    private var headerWritten = false
    private let mode: LiveTranscriptionMode
    private let logger = Logger(label: "macrec.transcription.sidecar.vtt")

    /// - Parameters:
    ///   - url: destination sidecar file
    ///   - sessionStart: time origin for cue timestamps
    ///   - mode: persistence mode. `.single` (default) preserves the
    ///     pre-plan-010 cue layout exactly. `.dual` wraps the cue body
    ///     in WebVTT voice tags `<v EN>...</v>` / `<v EL>...</v>` (per
    ///     design §DT-7 / DT-ADR-10) and OMITS the `source[lang]:`
    ///     prefix.
    ///
    ///     Dual-mode cues are NOT re-sorted by start time — they are
    ///     written in arrival order (first-finalised-first-written).
    ///     Cues from the two channels can therefore overlap, which is
    ///     intentional and tolerated by mainstream players.
    public init(url: URL,
                sessionStart: Date = Date(),
                mode: LiveTranscriptionMode = .single) throws {
        self.url = url
        self.sessionStart = sessionStart
        self.mode = mode
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
    /// Plan-010 Lane L-6 — dual mode wraps the cue body in WebVTT voice
    /// tags `<v EN>...</v>` / `<v EL>...</v>` (per design §DT-7 /
    /// DT-ADR-10):
    ///
    ///     00:00:01.230 --> 00:00:02.110
    ///     <v EN>Hello world</v>
    ///
    ///     00:00:01.920 --> 00:00:03.420
    ///     <v EL>Καλημέρα</v>
    ///
    /// Single-mode rendering is byte-equivalent to the pre-plan-010
    /// output (NFR-1 / AC-1). When `mode == .dual` but the segment's
    /// model isn't `"apple"` / `"apple-cloud"`, a warning is logged and
    /// the cue body is emitted without the voice tag.
    private func render(_ segment: TranscriptSegment) -> String {
        let start = segment.timestamp.timeIntervalSince(sessionStart)
        let end = segment.lastUpdated.timeIntervalSince(sessionStart)
        let body: String
        switch mode {
        case .single:
            let langTag = segment.language.map { " [\(Self.shortTag($0))]" } ?? ""
            body = "\(segment.source.rawValue)\(langTag): \(segment.text)"
        case .dual:
            if let tag = DualSidecarLabel.channelTag(forModel: segment.model) {
                let label = DualSidecarLabel.channelLabel(for: tag)
                body = "<v \(label)>\(segment.text)</v>"
            } else {
                logger.warning(
                    """
                    VTT sidecar in dual mode received segment with \
                    unknown model=\(segment.model ?? "nil"); emitting \
                    cue without voice tag. id=\(segment.id.uuidString)
                    """
                )
                body = segment.text
            }
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
