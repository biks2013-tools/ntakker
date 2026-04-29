// MacrecCore/Transcription/Persistence/SRTTranscriptWriter.swift
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

    public let url: URL
    private let handle: FileHandle
    private var index: [UUID: Range<UInt64>] = [:]
    private var sequenceCounter: Int = 0
    private var sequenceForId: [UUID: Int] = [:]
    private let sessionStart: Date

    public init(url: URL, sessionStart: Date = Date()) throws {
        self.url = url
        self.sessionStart = sessionStart
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    public func appendSegment(_ segment: TranscriptSegment) throws {
        sequenceCounter += 1
        sequenceForId[segment.id] = sequenceCounter
        let bytes = Data(render(seq: sequenceCounter, segment).utf8)
        let start = try handle.offset()
        try handle.write(contentsOf: bytes)
        let end = try handle.offset()
        index[segment.id] = start..<end
    }

    public func updateSegment(_ segment: TranscriptSegment) throws {
        guard let range = index[segment.id], let seq = sequenceForId[segment.id] else {
            try appendSegment(segment)
            return
        }
        let oldLen = Int(range.upperBound - range.lowerBound)
        let newRendering = render(seq: seq, segment)
        let newBytes = Data(newRendering.utf8)

        if newBytes.count <= oldLen {
            // Short-grow — pad inside the cue body before the trailing
            // "\n\n" so the cue boundaries stay intact.
            var padded = Data(newRendering.dropLast(2).utf8) // drop "\n\n"
            padded.append(Data(repeating: 0x20, count: oldLen - newBytes.count))
            padded.append(contentsOf: [0x0A, 0x0A])
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: padded)
            try handle.seekToEnd()
        } else {
            // Long-grow — tombstone the old cue with a placeholder
            // body of matching length, append the new cue at EOF, and
            // update the byte-range index.
            let tombHead = "\(seq)\n\(Self.srtTime(0)) --> \(Self.srtTime(0))\n[updated]"
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
        try handle.close()
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
    private func render(seq: Int, _ segment: TranscriptSegment) -> String {
        let start = segment.timestamp.timeIntervalSince(sessionStart)
        let end = segment.lastUpdated.timeIntervalSince(sessionStart)
        let langTag = segment.language.map { " [\(Self.shortTag($0))]" } ?? ""
        return "\(seq)\n\(Self.srtTime(start)) --> \(Self.srtTime(end))\n\(segment.source.rawValue)\(langTag): \(segment.text)\n\n"
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
