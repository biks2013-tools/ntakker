import Foundation
import Testing
@testable import NtakkerCore

@Suite("SegmentCoalescer")
struct SegmentCoalescerTests {

    @Test("first merge always creates a new segment")
    func firstMergeCreates() {
        var c = SegmentCoalescer()
        let result = c.merge(text: "hello", source: .microphone, at: Date(timeIntervalSince1970: 0))
        if case .created(let idx) = result {
            #expect(idx == 0)
        } else {
            Issue.record("expected .created, got \(result)")
        }
        #expect(c.segments.count == 1)
        #expect(c.segments[0].text == "hello")
    }

    @Test("same source within window appends in place")
    func sameSourceWithinWindowAppends() {
        var c = SegmentCoalescer()
        _ = c.merge(text: "hello", source: .microphone, at: Date(timeIntervalSince1970: 0))
        let result = c.merge(text: "world", source: .microphone, at: Date(timeIntervalSince1970: 5))
        if case .appended(let idx) = result {
            #expect(idx == 0)
        } else {
            Issue.record("expected .appended, got \(result)")
        }
        #expect(c.segments.count == 1)
        #expect(c.segments[0].text == "hello world")
    }

    @Test("different source creates a new segment")
    func differentSourceCreates() {
        var c = SegmentCoalescer()
        _ = c.merge(text: "alpha", source: .microphone, at: Date(timeIntervalSince1970: 0))
        let result = c.merge(text: "beta", source: .system, at: Date(timeIntervalSince1970: 1))
        if case .created(let idx) = result {
            #expect(idx == 1)
        } else {
            Issue.record("expected .created")
        }
    }

    @Test("sentence-end punctuation forces a new segment")
    func sentenceEndForcesCreate() {
        var c = SegmentCoalescer()
        _ = c.merge(text: "hello.", source: .microphone, at: Date(timeIntervalSince1970: 0))
        let result = c.merge(text: "world", source: .microphone, at: Date(timeIntervalSince1970: 1))
        if case .created = result { } else {
            Issue.record("expected .created after sentence-end")
        }
    }

    @Test("window expiry forces a new segment")
    func windowExpiryCreates() {
        var c = SegmentCoalescer()
        _ = c.merge(text: "hello", source: .microphone, at: Date(timeIntervalSince1970: 0))
        let result = c.merge(text: "world", source: .microphone,
                             at: Date(timeIntervalSince1970: SegmentCoalescer.coalesceWindowSeconds + 1))
        if case .created = result { } else {
            Issue.record("expected .created after window expiry")
        }
    }
}
