import Foundation
import Testing
@testable import NtakkerCore

/// The reader must return the newest rendering of every segment the
/// writer produced, including segments rewritten via tombstone-and-
/// append (they share the tombstone's id).
@Suite("JSONLTranscriptReader round-trip")
struct JSONLTranscriptReaderTests {

    @Test("a segment that grew past its slot survives the round-trip")
    func longGrowSurvives() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rec.transcript.jsonl")

        let writer = try JSONLTranscriptWriter(url: url)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var grown = TranscriptSegment(timestamp: t0, text: "hi", source: .microphone)
        let short = TranscriptSegment(timestamp: t0.addingTimeInterval(5), text: "ok then", source: .system)
        try writer.appendSegment(grown)
        try writer.appendSegment(short)
        // Long-grow: forces tombstone + append.
        grown = TranscriptSegment(
            id: grown.id, timestamp: t0,
            text: "hi there, this sentence is now much longer than the original slot",
            source: .microphone
        )
        try writer.updateSegment(grown)
        // Short-grow on the other segment: rewritten in place.
        try writer.updateSegment(TranscriptSegment(id: short.id, timestamp: short.timestamp, text: "ok", source: .system))
        try writer.close()

        #expect(try String(contentsOf: url, encoding: .utf8).contains("_tombstone"))
        let read = JSONLTranscriptReader.read(from: url)
        #expect(read.count == 2)
        #expect(read.first(where: { $0.id == grown.id })?.text == grown.text)
        #expect(read.first(where: { $0.id == short.id })?.text == "ok")
    }
}
