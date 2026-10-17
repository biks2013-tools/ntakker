import Foundation
import Testing
@testable import NtakkerCore

/// `processAligned` — the file-playback path used by ntakker-studio's
/// echo filter (2026-10-17).
@Suite("SoftwareAECProcessor aligned blocks")
struct SoftwareAECAlignedTests {

    /// Deterministic white noise in -amp…amp.
    private func noise(_ count: Int, seed: UInt64, amp: Float) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amp
        }
    }

    private func power(_ x: ArraySlice<Float>) -> Float {
        x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))
    }

    private func processor(rate: Double) -> SoftwareAECProcessor {
        SoftwareAECProcessor(config: SoftwareAECProcessor.playbackConfiguration(sampleRate: rate, filterLength: 1024))
    }

    @Test("a delayed, attenuated copy of the reference is cancelled by > 10 dB")
    func cancelsEcho() {
        let rate = 16_000.0, seconds = 12, delay = 160
        let ref = noise(Int(rate) * seconds, seed: 7, amp: 0.3)
        let mic = (0..<ref.count).map { i in i >= delay ? 0.5 * ref[i - delay] : 0 }
        let aec = processor(rate: rate)
        var out: [Float] = []
        var i = 0
        while i < ref.count {
            let j = min(ref.count, i + 4096)
            out += aec.processAligned(mic: Array(mic[i..<j]), reference: Array(ref[i..<j]))
            i = j
        }
        #expect(out.count == mic.count)
        let tail = (ref.count - Int(rate) * 2)..<ref.count
        let reduction = 10 * log10(power(mic[tail]) / max(1e-12, power(out[tail])))
        #expect(reduction > 10, "echo reduced by \(reduction) dB")
    }

    @Test("with a silent reference the mic passes through")
    func passesSpeech() {
        let rate = 16_000.0
        let mic = noise(16_000, seed: 3, amp: 0.2)
        let out = processor(rate: rate).processAligned(mic: mic, reference: [Float](repeating: 0, count: mic.count))
        let diff = zip(mic, out).map { abs($0 - $1) }.max() ?? 1
        #expect(diff < 1e-4)
    }

    @Test("a reset keeps the learnt echo path, so cancellation resumes at once")
    func resetKeepsWeights() {
        let rate = 16_000.0, delay = 160
        let ref = noise(Int(rate) * 12, seed: 11, amp: 0.3)
        let mic = (0..<ref.count).map { i in i >= delay ? 0.5 * ref[i - delay] : 0 }
        let aec = processor(rate: rate)
        _ = aec.processAligned(mic: mic, reference: ref)
        aec.resetAlignedTimeline()
        // Jump to a later point in the "file": the first second after the
        // jump should already be cancelled (past the first window).
        let jumpRef = noise(Int(rate), seed: 99, amp: 0.3)
        let jumpMic = (0..<jumpRef.count).map { i in i >= delay ? 0.5 * jumpRef[i - delay] : 0 }
        let out = aec.processAligned(mic: jumpMic, reference: jumpRef)
        let tail = 2_000..<jumpRef.count
        let reduction = 10 * log10(power(jumpMic[tail]) / max(1e-12, power(out[tail])))
        #expect(reduction > 10, "after a reset: \(reduction) dB")
    }
}
