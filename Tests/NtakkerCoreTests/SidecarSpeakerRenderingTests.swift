import Testing
import Foundation
@testable import NtakkerCore

@Suite("Speaker label propagation across all four sidecar formats (Phase A7)")
struct SidecarSpeakerRenderingTests {

    private func sample(speaker: String?) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            timestamp: Date(timeIntervalSince1970: 1_000.230),
            text: "hello world",
            source: .system,
            confidence: 0.9,
            model: "soniox",
            durationSec: 0.88,
            language: "en-US",
            speaker: speaker
        )
    }

    // MARK: - JSONL

    @Test("JSONL includes raw speaker field when present")
    func jsonlIncludesSpeaker() throws {
        let url = try makeTempURL(ext: "jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try JSONLTranscriptWriter(url: url)
        try writer.appendSegment(sample(speaker: "spk:2"))
        try writer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("\"speaker\":\"spk:2\""))
    }

    @Test("JSONL omits speaker field when nil (byte-equiv guarantee)")
    func jsonlOmitsSpeaker() throws {
        let url = try makeTempURL(ext: "jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try JSONLTranscriptWriter(url: url)
        try writer.appendSegment(sample(speaker: nil))
        try writer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(!content.contains("speaker"))
    }

    // MARK: - TXT

    @Test("TXT prefixes line with [S<N>] when speaker present (single mode)")
    func txtPrefixSpeaker() throws {
        let url = try makeTempURL(ext: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TXTTranscriptWriter(url: url)
        try writer.appendSegment(sample(speaker: "spk:1"))
        try writer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("[S1]"))
        #expect(content.contains("hello world"))
    }

    @Test("TXT does NOT include [S?] when speaker is nil")
    func txtNoSpeakerPrefix() throws {
        let url = try makeTempURL(ext: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TXTTranscriptWriter(url: url)
        try writer.appendSegment(sample(speaker: nil))
        try writer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(!content.contains("[S"))
    }

    // MARK: - SRT

    @Test("SRT prefixes cue text with S<N>: when speaker present")
    func srtPrefixSpeaker() throws {
        let url = try makeTempURL(ext: "srt")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SRTTranscriptWriter(url: url)
        try writer.appendSegment(sample(speaker: "spk:3"))
        try writer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("S3: hello world"))
    }

    @Test("SRT cue text is unprefixed when speaker is nil")
    func srtNoSpeakerPrefix() throws {
        let url = try makeTempURL(ext: "srt")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SRTTranscriptWriter(url: url)
        try writer.appendSegment(sample(speaker: nil))
        try writer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(!content.contains("S0:") && !content.contains("S1:") && !content.contains("S2:"))
    }

    // MARK: - VTT

    @Test("VTT wraps cue text in <v S<N>>...</v> when speaker present")
    func vttVoiceTag() throws {
        let url = try makeTempURL(ext: "vtt")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VTTTranscriptWriter(url: url)
        try writer.appendSegment(sample(speaker: "spk:2"))
        try writer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("<v S2>hello world</v>"))
    }

    @Test("VTT cue text is unwrapped when speaker is nil")
    func vttNoVoiceTag() throws {
        let url = try makeTempURL(ext: "vtt")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VTTTranscriptWriter(url: url)
        try writer.appendSegment(sample(speaker: nil))
        try writer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(!content.contains("<v "))
    }

    // MARK: - Helpers

    private func makeTempURL(ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("a7-\(UUID().uuidString).\(ext)")
    }
}
