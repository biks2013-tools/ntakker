import AVFoundation
import Foundation
import NtakkerCore
import Testing
@testable import NtakkerStudioKit

/// Silencing one channel of a split recording (2026-10-21).
@Suite("Silencing a channel")
struct ChannelSilenceTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func samples(_ url: URL) -> (rate: Double, values: [Float]) {
        let f = try! AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try! f.read(into: buf)
        return (f.processingFormat.sampleRate, Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))))
    }

    @Test("ranges merge per channel; the gain is 0 inside, 1 outside, with short fades at the edges")
    func rangesAndGain() {
        var s = ChannelSilence()
        #expect(s.isEmpty)
        s.add(CutRange(start: 1, end: 2), to: .microphone, duration: 10)
        s.add(CutRange(start: 1.5, end: 3), to: .microphone, duration: 10)
        s.add(CutRange(start: 9, end: 20), to: .system, duration: 10)
        #expect(s.ranges(for: .microphone) == [CutRange(start: 1, end: 3)])
        #expect(s.ranges(for: .system) == [CutRange(start: 9, end: 10)], "clamped to the recording")
        #expect(s.silencedDuration(for: .microphone) == 2)

        let rate = 1_000.0, r = [CutRange(start: 1, end: 3)]
        #expect(SilenceGain.gain(at: 500, ranges: r, rate: rate) == 1)
        #expect(SilenceGain.gain(at: 1_000, ranges: r, rate: rate) == 1, "fade starts at the edge")
        #expect(SilenceGain.gain(at: 1_005, ranges: r, rate: rate) == 0.5)
        #expect(SilenceGain.gain(at: 2_000, ranges: r, rate: rate) == 0)
        #expect(SilenceGain.gain(at: 2_995, ranges: r, rate: rate) == 0.5)
        #expect(SilenceGain.gain(at: 3_000, ranges: r, rate: rate) == 1)

        var chans: [[Float]] = [[Float](repeating: 1, count: 100)]
        SilenceGain.apply(r, to: &chans, startFrame: 1_950, rate: rate)
        #expect(chans[0].allSatisfy { $0 == 0 }, "a block inside the range is silenced")
        s.remove(CutRange(start: 1, end: 3), from: .microphone)
        s.clear()
        #expect(s.isEmpty)
    }

    @Test("Export Copy silences the range on one channel only, together with a cut")
    func exportSilencesOneChannel() throws {
        let root = StudioFixtures.tempDir("silence")
        let folder = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        StudioFixtures.writeWAV(folder.appendingPathComponent("rec.mic.wav"), seconds: 6) { _ in 0.25 }
        StudioFixtures.writeWAV(folder.appendingPathComponent("rec.system.wav"), seconds: 6) { _ in -0.5 }
        let mic = folder.appendingPathComponent("rec.mic.wav")
        let before = try Data(contentsOf: mic)
        let rec = RecordingLibraryScanner.scan(root: root)[0]

        var silence = ChannelSilence()
        silence.add(CutRange(start: 1, end: 2), to: .microphone, duration: 6)
        let result = try RecordingCutExporter.export(
            recording: rec, plan: CutPlan(ranges: [CutRange(start: 4, end: 5)], duration: 6),
            entriesByTranscript: [:], audioStart: t0, metadata: StudioMetadata(), silence: silence, now: t0
        )
        #expect(result.folder.lastPathComponent.hasPrefix("session-cut-silenced-"))
        #expect(result.silencedSeconds == [.microphone: 1])
        #expect(try Data(contentsOf: mic) == before, "the original is not changed")

        let (rate, m) = samples(result.folder.appendingPathComponent("rec.mic.wav"))
        let (_, sys) = samples(result.folder.appendingPathComponent("rec.system.wav"))
        #expect(m.count == Int(5 * rate) && sys.count == m.count, "the cut removed 1 s from both")
        #expect(abs(m[Int(0.5 * rate)] - 0.25) < 0.01, "before the silence: the mic")
        #expect(m[Int(1.1 * rate)..<Int(1.9 * rate)].allSatisfy { abs($0) < 0.0001 }, "inside: silence")
        #expect(abs(m[Int(2.5 * rate)] - 0.25) < 0.01, "after: the mic again")
        #expect(sys.allSatisfy { abs($0 + 0.5) < 0.01 }, "the system track is untouched")
    }

    @Test("silences alone are something to export")
    func silenceOnlyExports() throws {
        let root = StudioFixtures.tempDir("silence-only")
        StudioFixtures.writeWAV(root.appendingPathComponent("rec.mic.wav"), seconds: 2) { _ in 0.25 }
        StudioFixtures.writeWAV(root.appendingPathComponent("rec.system.wav"), seconds: 2) { _ in 0.25 }
        let rec = RecordingLibraryScanner.scan(root: root)[0]
        var silence = ChannelSilence()
        silence.add(CutRange(start: 0, end: 2), to: .system, duration: 2)
        let result = try RecordingCutExporter.export(
            recording: rec, plan: CutPlan(ranges: [], duration: 2),
            entriesByTranscript: [:], audioStart: t0, metadata: StudioMetadata(), silence: silence, now: t0
        )
        let (_, sys) = samples(result.folder.appendingPathComponent("rec.system.wav"))
        let (_, m) = samples(result.folder.appendingPathComponent("rec.mic.wav"))
        #expect(sys.dropFirst(200).dropLast(200).allSatisfy { abs($0) < 0.0001 }, "whole system track silenced")
        #expect(m.allSatisfy { abs($0 - 0.25) < 0.01 })
    }
}
