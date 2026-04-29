// MacrecCoreTests/Transcription/Persistence/WriterLanguagePrefixTests.swift
//
// Plan-005 Phase F (Task F.6) — coverage for the per-writer language
// rendering rules. Confirms:
//
//   * `JSONLTranscriptWriter` emits a `"language":"<bcp47>"` key when
//     `TranscriptSegment.language` is non-nil, and omits the key
//     entirely when nil (Swift's default `Encodable` behaviour for an
//     `Optional<String>` field).
//   * `TXTTranscriptWriter` injects a `[<short-tag>]` prefix between
//     the source label and the colon when language is non-nil
//     (`"en-US"` → `[en]`), and emits no prefix when language is nil.
//   * `SRTTranscriptWriter` and `VTTTranscriptWriter` follow the same
//     prefix rule on their cue body line.
//
// These tests don't exercise the streaming-vs-batch sidecar policy —
// that is covered separately by the writer-policy dispatch in
// `TranscriptSidecarWriter`. Here we drive the per-format writers
// directly so the language behaviour is isolated from the actor /
// policy layer.

import Foundation
import Testing
@testable import MacrecCore

@Suite("Writer language prefix")
struct WriterLanguagePrefixTests {

    // MARK: - Helpers

    private func tmpURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "macrec-langtest-\(UUID().uuidString)",
                isDirectory: true
            )
        try! FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir.appendingPathComponent(name)
    }

    // MARK: - JSONL

    @Test("JSONL emits language field when non-nil")
    func jsonlEmitsLanguage() throws {
        let url = tmpURL("t.jsonl")
        let w = try JSONLTranscriptWriter(url: url)
        let seg = TranscriptSegment(
            timestamp: Date(),
            text: "hello",
            source: .microphone,
            language: "en-US"
        )
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("\"language\":\"en-US\""))
    }

    @Test("JSONL omits language key when nil (no \"language\":null)")
    func jsonlOmitsLanguageWhenNil() throws {
        let url = tmpURL("t-nil.jsonl")
        let w = try JSONLTranscriptWriter(url: url)
        let seg = TranscriptSegment(
            timestamp: Date(),
            text: "hi",
            source: .microphone,
            language: nil
        )
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(!body.contains("\"language\""))
        #expect(!body.contains("null"))

        // The line must still be valid JSON.
        let line = body.split(separator: "\n").first.map(String.init) ?? ""
        #expect(
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil,
            "JSONL line is not valid JSON: \(line)"
        )
    }

    // MARK: - TXT

    @Test("TXT prefixes [lang] when language is set")
    func txtPrefixesLanguage() throws {
        let url = tmpURL("t.txt")
        let w = try TXTTranscriptWriter(url: url)
        let seg = TranscriptSegment(
            timestamp: Date(),
            text: "hello",
            source: .microphone,
            language: "en-US"
        )
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("[en]"))
        #expect(body.contains("hello"))
    }

    @Test("TXT omits [lang] when language is nil (single-locale or batch)")
    func txtOmitsLanguageWhenNil() throws {
        let url = tmpURL("t2.txt")
        let w = try TXTTranscriptWriter(url: url)
        let seg = TranscriptSegment(
            timestamp: Date(),
            text: "hi",
            source: .microphone,
            language: nil
        )
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url, encoding: .utf8)
        // No empty `[]` prefix — only the timestamp brackets are
        // allowed; everything past the source label is plain.
        #expect(!body.contains("[]"))
        #expect(!body.contains("[en]"))
        #expect(body.contains("hi"))
        // Sanity: the only `[` characters in this file should be the
        // timestamp prefix, opening exactly once.
        let openCount = body.filter { $0 == "[" }.count
        #expect(openCount == 1, "expected exactly one `[` (timestamp), got \(openCount)")
    }

    // MARK: - SRT

    @Test("SRT prefixes [lang] when language is set")
    func srtPrefixesLanguage() throws {
        let url = tmpURL("t.srt")
        let now = Date()
        let w = try SRTTranscriptWriter(url: url, sessionStart: now)
        let seg = TranscriptSegment(
            timestamp: now,
            text: "hello",
            source: .microphone,
            language: "el-GR"
        )
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("[el]"))
        #expect(body.contains("hello"))
    }

    @Test("SRT omits [lang] when language is nil")
    func srtOmitsLanguageWhenNil() throws {
        let url = tmpURL("t-nil.srt")
        let now = Date()
        let w = try SRTTranscriptWriter(url: url, sessionStart: now)
        let seg = TranscriptSegment(
            timestamp: now,
            text: "hi",
            source: .microphone,
            language: nil
        )
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(!body.contains("["))
        #expect(body.contains("hi"))
    }

    // MARK: - VTT

    @Test("VTT prefixes [lang] when language is set")
    func vttPrefixesLanguage() throws {
        let url = tmpURL("t.vtt")
        let now = Date()
        let w = try VTTTranscriptWriter(url: url, sessionStart: now)
        let seg = TranscriptSegment(
            timestamp: now,
            text: "hello",
            source: .microphone,
            language: "en-US"
        )
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.hasPrefix("WEBVTT"))
        #expect(body.contains("[en]"))
        #expect(body.contains("hello"))
    }

    @Test("VTT omits [lang] when language is nil")
    func vttOmitsLanguageWhenNil() throws {
        let url = tmpURL("t-nil.vtt")
        let now = Date()
        let w = try VTTTranscriptWriter(url: url, sessionStart: now)
        let seg = TranscriptSegment(
            timestamp: now,
            text: "hi",
            source: .microphone,
            language: nil
        )
        try w.appendSegment(seg)
        try w.close()
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.hasPrefix("WEBVTT"))
        #expect(!body.contains("["))
        #expect(body.contains("hi"))
    }
}
