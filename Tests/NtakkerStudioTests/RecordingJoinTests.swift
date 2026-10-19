import AVFoundation
import Foundation
import NtakkerCore
import Testing
@testable import NtakkerStudioKit

/// Joining recordings (the parts of a paused session) into one
/// (2026-10-19).
@Suite("Joining recordings")
struct RecordingJoinTests {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A split-layout part `<stem>.partNN` in `folder`: mic and system
    /// tracks of the given lengths filled with `level`, a mic transcript
    /// with lines at the given offsets, and its audio start.
    private func part(_ folder: URL, _ n: Int, start: Date, mic: Double, system: Double, level: Float,
                      lines: [(String, Double)], speakerNames: [String: String] = [:], rate: Double = 16_000) {
        let stem = String(format: "recording-x.part%02d", n)
        StudioFixtures.writeWAV(folder.appendingPathComponent("\(stem).mic.wav"), seconds: mic, rate: rate) { _ in level }
        StudioFixtures.writeWAV(folder.appendingPathComponent("\(stem).system.wav"), seconds: system, rate: rate) { _ in level }
        let segs = lines.map { StudioFixtures.segment($0.0, at: start.addingTimeInterval($0.1), duration: 0.5, speaker: "1") }
        try! TranscriptDocument.write(segs, to: folder.appendingPathComponent("\(stem).microphone.transcript.jsonl"))
        try! StudioMetadata(audioStart: start, speakerNames: speakerNames)
            .save(to: folder.appendingPathComponent("\(stem).studio.json"))
    }

    private func parts(in folder: URL) throws -> [JoinPart] {
        try RecordingLibraryScanner.recordings(inFolder: folder).map(JoinPart.load)
    }

    private func samples(_ url: URL) -> (rate: Double, values: [Float]) {
        let f = try! AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try! f.read(into: buf)
        return (f.processingFormat.sampleRate, Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))))
    }

    @Test("parts are joined end to end in the order recorded, pauses left out, transcripts re-timed")
    func joinsParts() throws {
        let root = StudioFixtures.tempDir("join")
        let session = root.appendingPathComponent("Daily", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        // Part 2 is listed first on purpose; its system track is shorter.
        part(session, 2, start: t0.addingTimeInterval(60), mic: 3, system: 2.5, level: -0.5,
             lines: [("second", 0.5)], speakerNames: ["1": "Bob", "2": "Carol"])
        part(session, 1, start: t0, mic: 2, system: 2, level: 0.25,
             lines: [("first", 0.2), ("again", 1.0)], speakerNames: ["1": "Anna"])

        let plan = try RecordingJoiner.plan(try parts(in: session).sorted { $0.audioStart > $1.audioStart })
        #expect(plan.items.map(\.part.recording.partNumber) == [1, 2])
        #expect(plan.items.map(\.offset) == [0, 2])
        #expect(plan.items[1].pauseBefore == 58)
        #expect(plan.duration == 5)
        #expect(plan.stem == "recording-x")
        #expect(plan.transcriptLabels == ["microphone"])

        let r = try RecordingJoiner.join(plan, now: t0)
        // The session folder holds only the parts → a sibling folder.
        #expect(r.folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(r.folder.lastPathComponent.hasPrefix("Daily-joined-"))
        let joined = RecordingLibraryScanner.recordings(inFolder: r.folder)
        #expect(joined.count == 1)
        let rec = try #require(joined.first)
        #expect(rec.stem == "recording-x")
        #expect(Set(rec.tracks.map(\.url.lastPathComponent)) == ["recording-x.mic.wav", "recording-x.system.wav"])

        for track in rec.tracks {
            let (rate, v) = samples(track.url)
            #expect(v.count == Int(5 * rate))
            #expect(abs(v[Int(1.5 * rate)] - 0.25) < 0.01)   // part 1
            #expect(abs(v[Int(2.2 * rate)] + 0.5) < 0.01)    // part 2
            if track.role == .system {
                #expect(abs(v[Int(4.8 * rate)]) < 0.001)     // padded: part 2's system is 2.5 s
            }
        }

        let meta = try StudioMetadata.load(from: rec.metadataURL)
        #expect(meta.audioStart == t0)
        #expect(meta.speakerNames == ["1": "Anna", "2": "Carol"])
        #expect(meta.exactTimingTranscripts == ["recording-x.microphone.transcript.jsonl"])
        let entries = TranscriptDocument.load(rec.transcripts[0]).entries(audioStart: t0, exact: true, syncOffsetSec: 0)
        #expect(entries.map(\.segment.text) == ["first", "again", "second"])
        #expect(entries.map { ($0.start * 10).rounded() / 10 } == [0.2, 1.0, 2.5])
        #expect(r.lines == 3 && r.parts == 2)
    }

    @Test("a part in another sample rate is converted")
    func convertsRate() throws {
        let folder = StudioFixtures.tempDir("join-rate")
        part(folder, 1, start: t0, mic: 1, system: 1, level: 0.25, lines: [])
        part(folder, 2, start: t0.addingTimeInterval(5), mic: 2, system: 2, level: 0.25, lines: [], rate: 8_000)
        let r = try RecordingJoiner.join(try RecordingJoiner.plan(try parts(in: folder)), now: t0)
        let rec = try #require(RecordingLibraryScanner.recordings(inFolder: r.folder).first)
        let (rate, v) = samples(rec.tracks[0].url)
        #expect(rate == 16_000)
        #expect(abs(v.count - 3 * 16_000) <= 16)
        #expect(abs(v[Int(2.0 * rate)] - 0.25) < 0.02)
    }

    @Test("recordings with different tracks, or fewer than two, are refused")
    func refuses() throws {
        let folder = StudioFixtures.tempDir("join-layout")
        part(folder, 1, start: t0, mic: 1, system: 1, level: 0.1, lines: [])
        StudioFixtures.writeWAV(folder.appendingPathComponent("recording-x.part02.system.wav"), seconds: 1)
        let all = try parts(in: folder)
        #expect(throws: RecordingJoinError.self) { try RecordingJoiner.plan(all) }
        #expect(throws: RecordingJoinError.tooFew) { try RecordingJoiner.plan(Array(all.prefix(1))) }
    }

    @Test("a folder shared with other recordings gets a subfolder")
    func sharedFolder() throws {
        let folder = StudioFixtures.tempDir("join-shared")
        part(folder, 1, start: t0, mic: 1, system: 1, level: 0.1, lines: [])
        part(folder, 2, start: t0.addingTimeInterval(2), mic: 1, system: 1, level: 0.1, lines: [])
        StudioFixtures.writeWAV(folder.appendingPathComponent("other.wav"), seconds: 1)
        let joinable = try parts(in: folder).filter { $0.recording.partNumber != nil }
        let r = try RecordingJoiner.join(try RecordingJoiner.plan(joinable), now: t0)
        #expect(r.folder.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(r.folder.lastPathComponent.hasPrefix("recording-x-joined-"))
        #expect(RecordingJoiner.baseStem("a.b.part07") == "a.b")
        #expect(RecordingJoiner.baseStem("a.b") == "a.b")
    }
}
