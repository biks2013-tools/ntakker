// NtakkerCore/Transcription/Persistence/JSONLTranscriptWriter.swift
//
// Phase F (plan-004 §"Phase F — Sidecar writers", Task F.3) — JSONL
// sidecar writer with id-keyed in-place rewrite (tombstone-and-append).
//
// One JSON object per line, terminated by `\n`. Each segment carries:
//
//     {"durationSec":1.42,"id":"…UUID…","model":"gemini-…",
//      "source":"system","text":"hello world","timestamp":"2026-04-…"}
//
// (Field order is JSONEncoder default — not pinned because Phase F
// rewrites lines in place and the byte layout has to stay stable
// across `appendSegment(_:)` and `updateSegment(_:)` calls; the
// `_tombstone` line below intentionally stays a single concise
// shape the consumer can filter.)
//
// In-place rewrite (project-design §LT — and plan-004 §5.2):
//
//   * `appendSegment(_:)` writes a fresh line at end-of-file and
//     records the byte range it occupies, keyed by `TranscriptSegment.id`.
//   * `updateSegment(_:)` looks up the byte range. If the new line
//     fits within the old slot it is short-grow rewritten in place,
//     padded with trailing whitespace before the newline so the line
//     count of the file is preserved. If the new line is longer the
//     old slot is overwritten with a `_tombstone` line of matching
//     length and the new rendering is appended at end-of-file; the
//     byte index is updated so subsequent updates target the new
//     location.
//
// Concurrency: `TranscriptSidecarWriter` (the owning actor) is the
// only caller, so no internal locking is required. The writer is a
// `final class` because it carries the mutable byte-index map.

import Foundation

/// JSONL (newline-delimited JSON) sidecar writer.
public final class JSONLTranscriptWriter: TranscriptFormatWriter {

    public let url: URL
    private let handle: FileHandle
    private var index: [UUID: Range<UInt64>] = [:]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    public func appendSegment(_ segment: TranscriptSegment) throws {
        let line = try encode(segment) + "\n"
        let bytes = Data(line.utf8)
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
        let oldByteLen = Int(range.upperBound - range.lowerBound)
        let newLine = try encode(segment) + "\n"
        let newBytes = Data(newLine.utf8)

        if newBytes.count <= oldByteLen {
            // Short-grow — pad with spaces (JSON ignores trailing
            // whitespace before the newline, so the line stays valid).
            var padded = Data(newLine.dropLast().utf8) // strip trailing "\n"
            padded.append(Data(repeating: 0x20, count: oldByteLen - newBytes.count))
            padded.append(0x0A) // "\n"
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: padded)
            try handle.seekToEnd()
        } else {
            // Long-grow — tombstone the old slot, append the new line
            // at EOF, update the byte-range index so future updates
            // target the new location.
            let tombstoneObj = #"{"_tombstone":true,"id":"\#(segment.id.uuidString)"}"#
            var tomb = Data(tombstoneObj.utf8)
            // The tombstone line itself MUST be `oldByteLen` bytes
            // long (object + trailing newline). Pad with spaces inside
            // the JSON object's whitespace allowance.
            if tomb.count + 1 < oldByteLen {
                tomb.append(Data(repeating: 0x20, count: oldByteLen - tomb.count - 1))
            }
            tomb.append(0x0A) // "\n"
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

    // MARK: - Encoding

    /// Encode a single segment as a one-line JSON object (no trailing
    /// newline — `appendSegment` / `updateSegment` add it themselves).
    ///
    /// Plan-005 Phase F adds the BCP-47 `language` tag (e.g. `"en-US"`,
    /// `"el-GR"`) to the wire format. The field is `String?`: when the
    /// underlying `TranscriptSegment.language` is `nil` (single-locale
    /// sessions and the batch pipeline) Swift's default `Encodable`
    /// behaviour omits the key entirely, so existing JSONL consumers
    /// see no schema change. When non-nil the field appears as
    /// `"language":"<bcp47>"`.
    ///
    /// Plan-012 Phase A7 adds the OPTIONAL `speaker` field that carries
    /// the RAW provider value (e.g. Soniox `"spk:1"`) — JSONL is the
    /// authoritative machine-readable sidecar, so we keep the unmodified
    /// provider id rather than the human-friendly `S1` display label
    /// (the human-readable formats — TXT/SRT/VTT — translate via
    /// `SpeakerSidecarLabel.label(for:)`). When `segment.speaker` is
    /// `nil` (every non-diarized provider, every pre-A7 fixture) the
    /// `Encodable` synthesis omits the key so the JSONL byte layout
    /// stays equivalent (DT-INV).
    private func encode(_ segment: TranscriptSegment) throws -> String {
        struct Wire: Encodable {
            let id: String
            let timestamp: String
            let source: String
            let text: String
            let model: String?
            let durationSec: Double?
            let language: String?
            let speaker: String?
        }
        let wire = Wire(
            id: segment.id.uuidString,
            timestamp: Self.isoFormatter.string(from: segment.timestamp),
            source: segment.source.rawValue,
            text: segment.text,
            model: segment.model,
            durationSec: segment.durationSec,
            language: segment.language,
            speaker: segment.speaker
        )
        let data = try JSONEncoder().encode(wire)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
