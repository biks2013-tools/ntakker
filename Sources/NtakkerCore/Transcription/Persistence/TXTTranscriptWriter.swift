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

    public let url: URL
    private let handle: FileHandle
    private var index: [UUID: Range<UInt64>] = [:]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    public func appendSegment(_ segment: TranscriptSegment) throws {
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
            // Short-grow — pad with spaces between content and newline.
            var padded = Data(newRendering.dropLast().utf8) // strip trailing "\n"
            padded.append(Data(repeating: 0x20, count: oldLen - newBytes.count))
            padded.append(0x0A)
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: padded)
            try handle.seekToEnd()
        } else {
            // Long-grow — tombstone is a blank line of matching length,
            // then append the new rendering at EOF.
            var tomb = Data(repeating: 0x20, count: oldLen - 1)
            tomb.append(0x0A)
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
        try handle.close()
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
