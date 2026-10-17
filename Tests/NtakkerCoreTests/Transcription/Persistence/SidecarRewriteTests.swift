// NtakkerCoreTests/Transcription/Persistence/SidecarRewriteTests.swift
//
// Phase F (plan-004 §"Phase F — Sidecar writers", Task F.8) — coverage
// for the id-keyed in-place rewrite (tombstone-and-append) implemented
// by `JSONLTranscriptWriter`. Two cases:
//
//   * Short-grow: the new line fits within the slot of the original
//     append. The writer pads with whitespace; every line in the file
//     must remain valid JSON.
//   * Long-grow: the new line is bigger than the original slot. The
//     writer overwrites the original slot with a `_tombstone` line of
//     matching length and appends the new rendering at EOF.
//
// The other three writers (TXT/SRT/VTT) follow the same pattern; the
// JSONL test is the canonical one and exercises the byte-index
// bookkeeping that all four writers share.

import Foundation
import Testing
@testable import NtakkerCore

@Suite("Sidecar rewrite")
struct SidecarRewriteTests {

    // MARK: - Helpers

    private func tmpURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntakker-cli-sidecar-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    // MARK: - Tests

    @Test("JSONL: short-grow rewrite keeps file valid line-by-line")
    func jsonlShortGrow() throws {
        let url = tmpURL("test.jsonl")
        let w = try JSONLTranscriptWriter(url: url)
        let id = UUID()
        let now = Date()
        let s1 = TranscriptSegment(
            id: id,
            timestamp: now,
            text: "this is a longer line",
            source: .microphone
        )
        let s2 = TranscriptSegment(
            id: id,
            timestamp: now,
            lastUpdated: now,
            text: "short",
            source: .microphone
        )
        try w.appendSegment(s1)
        try w.updateSegment(s2)
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        let lines = txt.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where !line.isEmpty {
            #expect(
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil,
                "invalid JSON on line: \(line)"
            )
        }
    }

    @Test("JSONL: long-grow rewrite emits tombstone + appended new line")
    func jsonlLongGrow() throws {
        let url = tmpURL("test.jsonl")
        let w = try JSONLTranscriptWriter(url: url)
        let id = UUID()
        let now = Date()
        let s1 = TranscriptSegment(
            id: id,
            timestamp: now,
            text: "x",
            source: .microphone
        )
        let s2 = TranscriptSegment(
            id: id,
            timestamp: now,
            lastUpdated: now,
            text: String(repeating: "y", count: 200),
            source: .microphone
        )
        try w.appendSegment(s1)
        try w.updateSegment(s2)
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(txt.contains("_tombstone"))
        #expect(txt.contains(String(repeating: "y", count: 200)))

        let lines = txt.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where !line.isEmpty {
            #expect(
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil,
                "invalid JSON on line: \(line)"
            )
        }
    }

    // MARK: - TXT / SRT / VTT (F33: all four share RewritableSegmentFile)

    private func segments(longFirst: Bool) -> (TranscriptSegment, TranscriptSegment, UUID) {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        let long = String(repeating: "y", count: 120)
        let first = TranscriptSegment(id: id, timestamp: start, lastUpdated: start.addingTimeInterval(1),
                                      text: longFirst ? long : "x", source: .system)
        let second = TranscriptSegment(id: id, timestamp: start, lastUpdated: start.addingTimeInterval(1),
                                       text: longFirst ? "short" : long, source: .system)
        return (first, second, id)
    }

    private func roundTrip(
        _ make: (URL) throws -> any TranscriptFormatWriter,
        ext: String,
        longFirst: Bool
    ) throws -> (afterAppend: String, final: String) {
        let url = tmpURL("test.\(ext)")
        let w = try make(url)
        let (a, b, _) = segments(longFirst: longFirst)
        try w.appendSegment(a)
        let afterAppend = try String(contentsOf: url, encoding: .utf8)
        try w.updateSegment(b)
        try w.close()
        return (afterAppend, try String(contentsOf: url, encoding: .utf8))
    }

    @Test("TXT: short-grow pads in place; long-grow blanks the slot and appends")
    func txtRewrite() throws {
        let short = try roundTrip({ try TXTTranscriptWriter(url: $0) }, ext: "txt", longFirst: true)
        #expect(short.final.utf8.count == short.afterAppend.utf8.count, "short-grow keeps the size")
        #expect(short.final.contains("system: short   "))
        #expect(short.final.hasSuffix(" \n"))

        let long = try roundTrip({ try TXTTranscriptWriter(url: $0) }, ext: "txt", longFirst: false)
        let lines = long.final.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3, "blank tombstone line, new line, trailing empty")
        #expect(lines[0].allSatisfy { $0 == " " } && lines[0].utf8.count + 1 == long.afterAppend.utf8.count)
        #expect(lines[1].hasSuffix(String(repeating: "y", count: 120)))
    }

    @Test("SRT: rewrites keep the cue number; long-grow tombstones with [updated]")
    func srtRewrite() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let short = try roundTrip({ try SRTTranscriptWriter(url: $0, sessionStart: start) }, ext: "srt", longFirst: true)
        #expect(short.final.utf8.count == short.afterAppend.utf8.count)
        #expect(short.final.hasPrefix("1\n00:00:00,000 --> 00:00:01,000\nsystem: short "))
        #expect(short.final.hasSuffix(" \n\n"))

        let long = try roundTrip({ try SRTTranscriptWriter(url: $0, sessionStart: start) }, ext: "srt", longFirst: false)
        let oldLength = long.afterAppend.utf8.count
        let tomb = String(long.final.utf8.prefix(oldLength))!
        #expect(tomb.hasPrefix("1\n00:00:00,000 --> 00:00:00,000\n[updated]"))
        #expect(tomb.hasSuffix("\n\n"))
        #expect(long.final.hasSuffix("1\n00:00:00,000 --> 00:00:01,000\nsystem: \(String(repeating: "y", count: 120))\n\n"))
    }

    @Test("VTT: header once; same rewrite model without cue numbers")
    func vttRewrite() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let short = try roundTrip({ try VTTTranscriptWriter(url: $0, sessionStart: start) }, ext: "vtt", longFirst: true)
        #expect(short.final.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nsystem: short "))
        #expect(short.final.utf8.count == short.afterAppend.utf8.count)

        let long = try roundTrip({ try VTTTranscriptWriter(url: $0, sessionStart: start) }, ext: "vtt", longFirst: false)
        #expect(long.final.components(separatedBy: "WEBVTT").count == 2, "exactly one header")
        #expect(long.final.contains("00:00:00.000 --> 00:00:00.000\n[updated]"))
        #expect(long.final.hasSuffix("system: \(String(repeating: "y", count: 120))\n\n"))
    }
}
