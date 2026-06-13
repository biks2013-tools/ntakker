import Foundation
import Testing
@testable import NtakkerCore

@Suite("SourceBuffer")
struct SourceBufferTests {

    @Test("drain returns nil when below minSamples")
    func drainBelowMin() async {
        let buf = SourceBuffer(source: .microphone)
        await buf.append(Array(repeating: Float(0), count: 1_000))
        let result = await buf.drain(final: false)
        #expect(result == nil)
    }

    @Test("drain returns the accumulator when ≥ minSamples")
    func drainAboveMin() async {
        let buf = SourceBuffer(source: .microphone)
        await buf.append(Array(repeating: Float(0.1), count: 7_000))
        let result = await buf.drain(final: false)
        #expect(result?.count == 7_000)
        let after = await buf.drain(final: false)
        #expect(after == nil)
    }

    @Test("drain with final: true flushes any non-empty residue")
    func drainFinalReturnsResidue() async {
        let buf = SourceBuffer(source: .microphone)
        await buf.append(Array(repeating: Float(0.1), count: 100))
        let result = await buf.drain(final: true)
        #expect(result?.count == 100)
    }

    @Test("overflow drops oldest half when buffer exceeds 2 × chunkSamples")
    func overflowDropsOldestHalf() async {
        let chunkSamples = Int(2.5 * 16_000)
        let buf = SourceBuffer(source: .microphone)
        await buf.append(Array(repeating: Float(0.1), count: 2 * chunkSamples + 1))
        let count = await buf.bufferOverflowCount
        #expect(count == 1)
    }
}
