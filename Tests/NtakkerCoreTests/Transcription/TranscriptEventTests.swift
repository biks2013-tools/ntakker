import Foundation
import Testing
@testable import NtakkerCore

@Suite("TranscriptionEvent")
struct TranscriptionEventTests {

    @Test("segmentAppended round-trips through Codable")
    func segmentAppendedCodable() throws {
        let seg = TranscriptSegment(timestamp: Date(timeIntervalSince1970: 0),
                                    text: "hi", source: .microphone)
        let event: TranscriptionEvent = .segmentAppended(index: 0, segment: seg)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(TranscriptionEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test("metricsTick increments fields independently")
    func metricsTickFields() {
        var m = TranscriptionMetrics()
        m.chunksSent = 3
        m.billableSeconds = 7.5
        m.lastRttMs = 412
        m.errorCount = 1
        let event: TranscriptionEvent = .metricsTick(metrics: m)
        if case .metricsTick(let read) = event {
            #expect(read.chunksSent == 3)
            #expect(read.billableSeconds == 7.5)
            #expect(read.lastRttMs == 412)
            #expect(read.errorCount == 1)
        } else {
            Issue.record("expected .metricsTick")
        }
    }
}
