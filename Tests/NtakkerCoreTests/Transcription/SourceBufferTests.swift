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

/// EVAL-2026-10-16 TR-2 (plan-022 T6): on-device chunks are 10–14 s,
/// cut at a pause.
@Suite("SourceBuffer silence-cut policy")
struct SourceBufferSilenceCutTests {

    private let rate = 16_000

    private func loud(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { sin(Float($0) * 0.05) * 0.3 }
    }

    private func quiet(_ seconds: Double) -> [Float] {
        [Float](repeating: 0.000_1, count: Int(seconds * 16_000))
    }

    @Test("nothing is sent before the target length")
    func waitsForTarget() async {
        let buf = SourceBuffer(source: .system, policy: .onDevice)
        await buf.append(loud(9))
        #expect(await buf.drain(final: false) == nil)
    }

    @Test("the chunk ends inside the first pause after the target")
    func cutsAtPause() async throws {
        let buf = SourceBuffer(source: .system, policy: .onDevice)
        await buf.append(loud(11))
        await buf.append(quiet(0.3))
        await buf.append(loud(2))
        let chunk = try #require(await buf.drain(final: false))
        let seconds = Double(chunk.count) / Double(rate)
        #expect(seconds > 11 && seconds < 11.3, "cut at \(seconds) s, expected inside the 11.0–11.3 s pause")
        let rest = try #require(await buf.drain(final: true))
        #expect(chunk.count + rest.count == Int(13.3 * 16_000), "no audio lost at the cut")
    }

    @Test("without a pause it waits, then cuts by the maximum")
    func forcedCutAtMax() async throws {
        let buf = SourceBuffer(source: .system, policy: .onDevice)
        await buf.append(loud(12))
        #expect(await buf.drain(final: false) == nil, "no pause yet and below the maximum")
        await buf.append(loud(4))
        let chunk = try #require(await buf.drain(final: false))
        #expect(chunk.count <= 14 * rate)
        #expect(chunk.count >= 10 * rate)
    }

    @Test("the overflow cap scales with the maximum chunk")
    func capScales() async {
        let buf = SourceBuffer(source: .system, policy: .onDevice)
        await buf.append(quiet(27))
        #expect(await buf.bufferOverflowCount == 0, "a 28 s cap holds 27 s")
        await buf.append(quiet(2))
        #expect(await buf.bufferOverflowCount == 1)
    }
}
