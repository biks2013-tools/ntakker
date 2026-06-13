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
}
