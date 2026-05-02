import Testing
import Foundation
@testable import MacrecCore

@Suite("TranscriptSegment.speaker (Phase A1)")
struct TranscriptSegmentSpeakerFieldTests {

    @Test("speaker defaults to nil when not provided")
    func defaultIsNil() {
        let s = TranscriptSegment(
            timestamp: Date(timeIntervalSince1970: 0),
            text: "hello",
            source: .system
        )
        #expect(s.speaker == nil)
    }

    @Test("speaker round-trips through Codable")
    func codableRoundTrip() throws {
        let s = TranscriptSegment(
            timestamp: Date(timeIntervalSince1970: 0),
            text: "hello",
            source: .microphone,
            speaker: "spk:1"
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        #expect(decoded.speaker == "spk:1")
    }

    @Test("nil speaker is omitted from JSONL line")
    func omitWhenNil() throws {
        let s = TranscriptSegment(
            timestamp: Date(timeIntervalSince1970: 0),
            text: "hello",
            source: .system
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = String(data: try enc.encode(s), encoding: .utf8)!
        #expect(!json.contains("\"speaker\""))
    }
}
