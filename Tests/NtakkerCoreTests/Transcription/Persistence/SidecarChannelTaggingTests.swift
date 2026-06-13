// NtakkerCoreTests/Transcription/Persistence/SidecarChannelTaggingTests.swift
//
// Single-mode sidecar regression — verifies the per-format writers
// produce the expected line / cue layout. (The plan-010 dual-mode
// channel-tagging variants were removed when dual transcription was
// retired.)

import Foundation
import Testing
@testable import NtakkerCore

@Suite("Sidecar single-mode rendering")
struct SidecarChannelTaggingTests {

    private func tmpURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntakker-cli-sidecar-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func makeSegment(model: String?, language: String? = "en-US",
                             text: String = "hello world",
                             source: SourceTag = .system) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_001),
            text: text,
            source: source,
            model: model,
            durationSec: 1.0,
            language: language
        )
    }

    // MARK: - JSONL

    @Test("JSONL: never emits a `channel` field")
    func jsonlOmitsChannel() throws {
        let url = tmpURL("a.jsonl")
        let w = try JSONLTranscriptWriter(url: url)
        try w.appendSegment(makeSegment(model: "apple"))
        try w.appendSegment(makeSegment(model: "apple-cloud", language: "el-GR", text: "καλημέρα"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(!txt.contains("\"channel\""), "JSONL must never carry a `channel` field; got:\n\(txt)")
    }

    // MARK: - TXT

    @Test("TXT: `[ts] source[lang]: text` rendering")
    func txtRendering() throws {
        let url = tmpURL("a.txt")
        let w = try TXTTranscriptWriter(url: url)
        try w.appendSegment(makeSegment(model: "apple", language: "en-US", text: "hi"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(txt.contains("system [en]: hi"))
        #expect(!txt.contains("[EN]"))
    }

    // MARK: - SRT

    @Test("SRT: `source[lang]: text` cue body")
    func srtRendering() throws {
        let url = tmpURL("a.srt")
        let w = try SRTTranscriptWriter(url: url)
        try w.appendSegment(makeSegment(model: "apple", text: "hi"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(txt.contains("system [en]: hi"))
        #expect(!txt.contains("EN: hi"))
    }

    // MARK: - VTT

    @Test("VTT: pre-plan-010 cue body, no voice tag")
    func vttRendering() throws {
        let url = tmpURL("a.vtt")
        let w = try VTTTranscriptWriter(url: url)
        try w.appendSegment(makeSegment(model: "apple", text: "hi"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(txt.hasPrefix("WEBVTT"))
        #expect(txt.contains("system [en]: hi"))
        #expect(!txt.contains("<v EN>"))
    }
}
