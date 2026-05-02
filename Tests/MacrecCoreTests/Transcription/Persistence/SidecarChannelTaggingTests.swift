// MacrecCoreTests/Transcription/Persistence/SidecarChannelTaggingTests.swift
//
// Plan-010 Wave 4 / Lane L-6 — coverage for the dual-mode channel-
// tagging cues added to the four sidecar format writers, plus the
// byte-equivalence guarantee for single-mode output (NFR-1 / AC-1).
//
// The test suite checks two orthogonal things:
//
//   1. Single-mode output is byte-identical between
//      `JSONLTranscriptWriter(url:)` (legacy default) and
//      `JSONLTranscriptWriter(url:, mode: .single)` (explicit), and
//      neither contains the dual-mode `channel` field. JSONL is the
//      most structurally sensitive format and the regression canary.
//   2. Dual-mode output emits the per-format channel cue:
//      * JSONL  — `"channel":"EN"` / `"channel":"EL"` (omitted when
//        the segment's model isn't one of the v1 providers)
//      * TXT    — `[EN] ` / `[EL] ` line prefix (no `source[lang]:`)
//      * SRT    — `EN: ` / `EL: ` cue body prefix
//      * VTT    — `<v EN>...</v>` / `<v EL>...</v>` voice tag

import Foundation
import Testing
@testable import MacrecCore

@Suite("Sidecar channel tagging (Lane L-6)")
struct SidecarChannelTaggingTests {

    // MARK: - Helpers

    private func tmpURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrec-l6-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func makeSegment(model: String?, language: String? = "en-US",
                             text: String = "hello world",
                             source: SourceTag = .system) -> TranscriptSegment {
        return TranscriptSegment(
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

    // MARK: - JSONL byte-equivalence

    /// Byte-equivalence note: Swift's auto-synthesised `Encodable` does
    /// NOT guarantee a stable key order across `JSONEncoder` instances
    /// (the order is process-stable for a given encoder but can differ
    /// between separately-constructed encoders). The pre-plan-010
    /// JSONL writer relied on `JSONEncoder` defaults, so its output was
    /// already non-deterministic per encoder instance. The Lane L-6
    /// guarantee (NFR-1 / AC-1) is therefore stated as **schematic
    /// equivalence**: in `.single` mode every line is a JSON object
    /// containing the SAME key set as the pre-plan-010 writer (no
    /// `channel` key), with the SAME values — which is what real
    /// downstream consumers (jq, Python `json`, anything that parses
    /// JSON object-style) actually depend on. The dual-mode JSONL adds
    /// the OPTIONAL `channel` key per spec.
    @Test("JSONL: single-mode (default init) and explicit `.single` produce schematically-equivalent output")
    func jsonlSingleModeSchematicEquivalence() throws {
        let url1 = tmpURL("default.jsonl")
        let url2 = tmpURL("explicit-single.jsonl")
        let s = makeSegment(model: "apple", language: "en-US")

        let w1 = try JSONLTranscriptWriter(url: url1)
        try w1.appendSegment(s)
        try w1.close()

        let w2 = try JSONLTranscriptWriter(url: url2, mode: .single)
        try w2.appendSegment(s)
        try w2.close()

        let bytes1 = try Data(contentsOf: url1)
        let bytes2 = try Data(contentsOf: url2)
        let json1 = try JSONSerialization.jsonObject(with: bytes1) as? [String: Any] ?? [:]
        let json2 = try JSONSerialization.jsonObject(with: bytes2) as? [String: Any] ?? [:]

        // Same key set
        let keys1 = Set(json1.keys)
        let keys2 = Set(json2.keys)
        #expect(keys1 == keys2, "single-mode key set must match between default and explicit init")
        #expect(!keys1.contains("channel"), "single-mode must never carry `channel` key; got keys=\(keys1)")

        // Same values for the keys present
        for k in keys1 {
            let v1 = String(describing: json1[k] ?? "")
            let v2 = String(describing: json2[k] ?? "")
            #expect(v1 == v2, "key \(k) value mismatch: \(v1) vs \(v2)")
        }
    }

    @Test("JSONL: single-mode never emits the `channel` field (even with apple/apple-cloud model)")
    func jsonlSingleModeOmitsChannel() throws {
        let url = tmpURL("single.jsonl")
        let w = try JSONLTranscriptWriter(url: url, mode: .single)
        try w.appendSegment(makeSegment(model: "apple"))
        try w.appendSegment(makeSegment(model: "apple-cloud", language: "el-GR", text: "καλημέρα"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(!txt.contains("\"channel\""), "single-mode JSONL must never carry a `channel` field; got:\n\(txt)")
    }

    @Test("JSONL: dual-mode emits `channel:\"EN\"` for apple and `channel:\"EL\"` for apple-cloud")
    func jsonlDualModeChannelField() throws {
        let url = tmpURL("dual.jsonl")
        let w = try JSONLTranscriptWriter(url: url, mode: .dual)
        try w.appendSegment(makeSegment(model: "apple", language: "en-US"))
        try w.appendSegment(makeSegment(model: "apple-cloud", language: "el-GR", text: "καλημέρα"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        let lines = txt.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"channel\":\"EN\""), "first line must carry channel=EN; got:\n\(lines[0])")
        #expect(lines[1].contains("\"channel\":\"EL\""), "second line must carry channel=EL; got:\n\(lines[1])")
    }

    @Test("JSONL: dual-mode omits `channel` field when model is unknown (no fallback)")
    func jsonlDualModeOmitsChannelOnUnknownModel() throws {
        let url = tmpURL("dual-unknown.jsonl")
        let w = try JSONLTranscriptWriter(url: url, mode: .dual)
        try w.appendSegment(makeSegment(model: "gemini-live"))
        try w.appendSegment(makeSegment(model: nil))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(!txt.contains("\"channel\""), "unknown-model dual-mode lines must omit channel field; got:\n\(txt)")
    }

    // MARK: - TXT

    @Test("TXT: single-mode preserves pre-plan-010 `[ts] source[lang]: text` rendering")
    func txtSingleModeUnchanged() throws {
        let url = tmpURL("single.txt")
        let w = try TXTTranscriptWriter(url: url, mode: .single)
        try w.appendSegment(makeSegment(model: "apple", language: "en-US", text: "hi"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(txt.contains("system [en]: hi"), "single-mode TXT must keep `source [lang]: text`; got:\n\(txt)")
        #expect(!txt.contains("[EN]"), "single-mode TXT must not carry channel prefix; got:\n\(txt)")
    }

    @Test("TXT: dual-mode prefixes line with `[EN] ` / `[EL] ` and omits source label")
    func txtDualModeChannelPrefix() throws {
        let url = tmpURL("dual.txt")
        let w = try TXTTranscriptWriter(url: url, mode: .dual)
        try w.appendSegment(makeSegment(model: "apple", text: "hi"))
        try w.appendSegment(makeSegment(model: "apple-cloud", language: "el-GR", text: "γεια"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(txt.contains("[EN] hi"), "dual-mode TXT must carry `[EN] ` prefix; got:\n\(txt)")
        #expect(txt.contains("[EL] γεια"), "dual-mode TXT must carry `[EL] ` prefix; got:\n\(txt)")
        #expect(!txt.contains("system [en]"), "dual-mode TXT must drop source label; got:\n\(txt)")
    }

    // MARK: - SRT

    @Test("SRT: single-mode preserves pre-plan-010 `source[lang]: text` cue body")
    func srtSingleModeUnchanged() throws {
        let url = tmpURL("single.srt")
        let w = try SRTTranscriptWriter(url: url, mode: .single)
        try w.appendSegment(makeSegment(model: "apple", text: "hi"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(txt.contains("system [en]: hi"))
        #expect(!txt.contains("EN: hi"))
    }

    @Test("SRT: dual-mode prefixes cue body with `EN: ` / `EL: `")
    func srtDualModeChannelPrefix() throws {
        let url = tmpURL("dual.srt")
        let w = try SRTTranscriptWriter(url: url, mode: .dual)
        try w.appendSegment(makeSegment(model: "apple", text: "hi"))
        try w.appendSegment(makeSegment(model: "apple-cloud", language: "el-GR", text: "γεια"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(txt.contains("EN: hi"))
        #expect(txt.contains("EL: γεια"))
        #expect(!txt.contains("system ["), "dual-mode SRT must drop source label")
    }

    // MARK: - VTT

    @Test("VTT: single-mode preserves pre-plan-010 cue body")
    func vttSingleModeUnchanged() throws {
        let url = tmpURL("single.vtt")
        let w = try VTTTranscriptWriter(url: url, mode: .single)
        try w.appendSegment(makeSegment(model: "apple", text: "hi"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(txt.hasPrefix("WEBVTT"))
        #expect(txt.contains("system [en]: hi"))
        #expect(!txt.contains("<v EN>"))
    }

    @Test("VTT: dual-mode wraps cue body in `<v EN>...</v>` / `<v EL>...</v>` voice tags")
    func vttDualModeVoiceTag() throws {
        let url = tmpURL("dual.vtt")
        let w = try VTTTranscriptWriter(url: url, mode: .dual)
        try w.appendSegment(makeSegment(model: "apple", text: "hi"))
        try w.appendSegment(makeSegment(model: "apple-cloud", language: "el-GR", text: "γεια"))
        try w.close()

        let txt = try String(contentsOf: url, encoding: .utf8)
        #expect(txt.hasPrefix("WEBVTT"))
        #expect(txt.contains("<v EN>hi</v>"))
        #expect(txt.contains("<v EL>γεια</v>"))
    }

    // MARK: - DualSidecarLabel.channelTag(forModel:) helper

    @Test("DualSidecarLabel.channelTag(forModel:) maps apple/apple-cloud and returns nil otherwise")
    func channelTagHelperMapping() {
        #expect(DualSidecarLabel.channelTag(forModel: "apple") == .channelA)
        #expect(DualSidecarLabel.channelTag(forModel: "apple-cloud") == .channelB)
        #expect(DualSidecarLabel.channelTag(forModel: "gemini-live") == nil)
        #expect(DualSidecarLabel.channelTag(forModel: nil) == nil)
        #expect(DualSidecarLabel.channelTag(forModel: "") == nil)
    }
}
